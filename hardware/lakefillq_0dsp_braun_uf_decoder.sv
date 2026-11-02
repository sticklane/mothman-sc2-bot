// =============================================================================
// lakefillq_0dsp_braun_uf_decoder.sv
// =============================================================================
// Synthesizable Multiplierless (0-DSP) SystemVerilog RTL for LakefillQ
// QPhysGrade Grade Phi1 Inner Fast-Feedback Syndrome Decoder Core (500 MHz, 2.0 ns)
//
// Strictly 0-DSP combinational operators:
//   bitwise (&, |, ^, ~), shifts (<<, >>), ternary muxes (? :),
//   concatenations ({}), bit slices, and ripple/LUT adders (+, -).
//   Zero hardware multipliers, dividers, modulo operators, or DSP48 primitives.
// =============================================================================

module lakefillq_braun_popcount16 (
  input  wire [15:0] syn16,
  output wire [4:0]  wt16
);
  wire [1:0] l1_0;
  wire [1:0] l1_1;
  wire [1:0] l1_2;
  wire [1:0] l1_3;
  wire [1:0] l1_4;
  wire [1:0] l1_5;
  wire [1:0] l1_6;
  wire [1:0] l1_7;
  wire [2:0] l2_0;
  wire [2:0] l2_1;
  wire [2:0] l2_2;
  wire [2:0] l2_3;
  wire [3:0] l3_0;
  wire [3:0] l3_1;

  assign l1_0 = {1'b0, syn16[0]}  + {1'b0, syn16[1]};
  assign l1_1 = {1'b0, syn16[2]}  + {1'b0, syn16[3]};
  assign l1_2 = {1'b0, syn16[4]}  + {1'b0, syn16[5]};
  assign l1_3 = {1'b0, syn16[6]}  + {1'b0, syn16[7]};
  assign l1_4 = {1'b0, syn16[8]}  + {1'b0, syn16[9]};
  assign l1_5 = {1'b0, syn16[10]} + {1'b0, syn16[11]};
  assign l1_6 = {1'b0, syn16[12]} + {1'b0, syn16[13]};
  assign l1_7 = {1'b0, syn16[14]} + {1'b0, syn16[15]};

  assign l2_0 = {1'b0, l1_0} + {1'b0, l1_1};
  assign l2_1 = {1'b0, l1_2} + {1'b0, l1_3};
  assign l2_2 = {1'b0, l1_4} + {1'b0, l1_5};
  assign l2_3 = {1'b0, l1_6} + {1'b0, l1_7};

  assign l3_0 = {1'b0, l2_0} + {1'b0, l2_1};
  assign l3_1 = {1'b0, l2_2} + {1'b0, l2_3};

  assign wt16 = {1'b0, l3_0} + {1'b0, l3_1};
endmodule

module lakefillq_braun_popcount24 (
  input  wire [23:0] syn24,
  output wire [4:0]  wt24
);
  wire [4:0] wt_lo16;
  wire [1:0] h1_0;
  wire [1:0] h1_1;
  wire [1:0] h1_2;
  wire [1:0] h1_3;
  wire [2:0] h2_0;
  wire [2:0] h2_1;
  wire [3:0] wt_hi8;

  lakefillq_braun_popcount16 u_lo16 (
    .syn16(syn24[15:0]),
    .wt16(wt_lo16)
  );

  assign h1_0   = {1'b0, syn24[16]} + {1'b0, syn24[17]};
  assign h1_1   = {1'b0, syn24[18]} + {1'b0, syn24[19]};
  assign h1_2   = {1'b0, syn24[20]} + {1'b0, syn24[21]};
  assign h1_3   = {1'b0, syn24[22]} + {1'b0, syn24[23]};
  assign h2_0   = {1'b0, h1_0} + {1'b0, h1_1};
  assign h2_1   = {1'b0, h1_2} + {1'b0, h1_3};
  assign wt_hi8 = {1'b0, h2_0} + {1'b0, h2_1};
  assign wt24   = wt_lo16 + {1'b0, wt_hi8};
endmodule

module lakefillq_ingress_xor_bypass24 (
  input  wire [23:0] cur_syn,
  input  wire [23:0] prev_syn,
  input  wire [1:0]  autdec_shift_sel,
  output wire [23:0] delta_syn,
  output wire [4:0]  defect_weight,
  output wire        zero_defect_bypass
);
  wire [23:0] raw_delta;
  wire [23:0] rot_s1;
  wire [23:0] rot_s2;
  wire [23:0] rot_s3;

  assign raw_delta = cur_syn ^ prev_syn;
  assign rot_s1    = {raw_delta[5:0],  raw_delta[23:6]};
  assign rot_s2    = {raw_delta[11:0], raw_delta[23:12]};
  assign rot_s3    = {raw_delta[2:0],  raw_delta[23:3]};

  assign delta_syn = (autdec_shift_sel == 2'd0) ? raw_delta :
                     ((autdec_shift_sel == 2'd1) ? rot_s1 :
                     ((autdec_shift_sel == 2'd2) ? rot_s2 : rot_s3));

  lakefillq_braun_popcount24 u_pop24 (
    .syn24(delta_syn),
    .wt24(defect_weight)
  );

  assign zero_defect_bypass = (defect_weight == 5'd0) ? 1'b1 : 1'b0;
endmodule

module lakefillq_bit_mux12 (
  input  wire [11:0] vec12,
  input  wire [3:0]  idx,
  output wire        bit_out
);
  wire b01   = idx[0] ? vec12[1]  : vec12[0];
  wire b23   = idx[0] ? vec12[3]  : vec12[2];
  wire b45   = idx[0] ? vec12[5]  : vec12[4];
  wire b67   = idx[0] ? vec12[7]  : vec12[6];
  wire b89   = idx[0] ? vec12[9]  : vec12[8];
  wire b1011 = idx[0] ? vec12[11] : vec12[10];
  wire q0    = idx[1] ? b23       : b01;
  wire q1    = idx[1] ? b67       : b45;
  wire q2    = idx[1] ? b1011     : b89;
  wire h0    = idx[2] ? q1        : q0;
  wire h1    = idx[2] ? 1'b0      : q2;
  assign bit_out = idx[3] ? h1 : h0;
endmodule

module lakefillq_mux12_u4 (
  input  wire [3:0] v0,
  input  wire [3:0] v1,
  input  wire [3:0] v2,
  input  wire [3:0] v3,
  input  wire [3:0] v4,
  input  wire [3:0] v5,
  input  wire [3:0] v6,
  input  wire [3:0] v7,
  input  wire [3:0] v8,
  input  wire [3:0] v9,
  input  wire [3:0] v10,
  input  wire [3:0] v11,
  input  wire [3:0] idx,
  output wire [3:0] out_u4
);
  wire [3:0] m01   = idx[0] ? v1    : v0;
  wire [3:0] m23   = idx[0] ? v3    : v2;
  wire [3:0] m45   = idx[0] ? v5    : v4;
  wire [3:0] m67   = idx[0] ? v7    : v6;
  wire [3:0] m89   = idx[0] ? v9    : v8;
  wire [3:0] m1011 = idx[0] ? v11   : v10;
  wire [3:0] q0    = idx[1] ? m23   : m01;
  wire [3:0] q1    = idx[1] ? m67   : m45;
  wire [3:0] q2    = idx[1] ? m1011 : m89;
  wire [3:0] h0    = idx[2] ? q1    : q0;
  wire [3:0] h1    = idx[2] ? idx   : q2;
  assign out_u4    = idx[3] ? h1    : h0;
endmodule

module lakefillq_onehot12_u4 (
  input  wire [3:0]  r,
  output wire [11:0] oh
);
  assign oh = {
    (r == 4'd11), (r == 4'd10), (r == 4'd9), (r == 4'd8),
    (r == 4'd7),  (r == 4'd6),  (r == 4'd5), (r == 4'd4),
    (r == 4'd3),  (r == 4'd2),  (r == 4'd1), (r == 4'd0)
  };
endmodule

module lakefillq_ffs12_u4 (
  input  wire [11:0] m,
  output wire [3:0]  min_idx
);
  wire       has_0_1 = m[0] | m[1];
  wire [3:0] i01     = m[0] ? 4'd0 : 4'd1;
  wire       has_2_3 = m[2] | m[3];
  wire [3:0] i23     = m[2] ? 4'd2 : 4'd3;
  wire       has_4_5 = m[4] | m[5];
  wire [3:0] i45     = m[4] ? 4'd4 : 4'd5;
  wire       has_6_7 = m[6] | m[7];
  wire [3:0] i67     = m[6] ? 4'd6 : 4'd7;
  wire       has_8_9 = m[8] | m[9];
  wire [3:0] i89     = m[8] ? 4'd8 : 4'd9;
  wire [3:0] i1011   = m[10] ? 4'd10 : 4'd11;

  wire       has_0_3 = has_0_1 | has_2_3;
  wire [3:0] i03     = has_0_1 ? i01 : i23;
  wire       has_4_7 = has_4_5 | has_6_7;
  wire [3:0] i47     = has_4_5 ? i45 : i67;
  wire [3:0] i811    = has_8_9 ? i89 : i1011;

  wire       has_0_7 = has_0_3 | has_4_7;
  wire [3:0] i07     = has_0_3 ? i03 : i47;
  assign min_idx     = has_0_7 ? i07 : i811;
endmodule

module lakefillq_braun_or12_u12 (
  input  wire [11:0] x0,
  input  wire [11:0] x1,
  input  wire [11:0] x2,
  input  wire [11:0] x3,
  input  wire [11:0] x4,
  input  wire [11:0] x5,
  input  wire [11:0] x6,
  input  wire [11:0] x7,
  input  wire [11:0] x8,
  input  wire [11:0] x9,
  input  wire [11:0] x10,
  input  wire [11:0] x11,
  output wire [11:0] or_u12
);
  wire [11:0] o01   = x0  | x1;
  wire [11:0] o23   = x2  | x3;
  wire [11:0] o45   = x4  | x5;
  wire [11:0] o67   = x6  | x7;
  wire [11:0] o89   = x8  | x9;
  wire [11:0] o1011 = x10 | x11;
  wire [11:0] o03   = o01 | o23;
  wire [11:0] o47   = o45 | o67;
  wire [11:0] o811  = o89 | o1011;
  wire [11:0] o07   = o03 | o47;
  assign or_u12     = o07 | o811;
endmodule

module lakefillq_sat2_edge_inc (
  input  wire [1:0] cur2,
  input  wire       a,
  input  wire       b,
  output wire [1:0] nxt2
);
  wire [1:0] inc2;
  wire [2:0] sum3;
  assign inc2 = {1'b0, a} + {1'b0, b};
  assign sum3 = {1'b0, cur2} + {1'b0, inc2};
  assign nxt2 = (sum3 >= 3'd2) ? 2'd2 : sum3[1:0];
endmodule

module lakefillq_sat2_bnd_inc (
  input  wire [1:0] cur2,
  input  wire       a,
  output wire [1:0] nxt2
);
  wire [2:0] sum3;
  assign sum3 = {1'b0, cur2} + {2'b00, a};
  assign nxt2 = (sum3 >= 3'd2) ? 2'd2 : sum3[1:0];
endmodule

module lakefillq_uf_half_edge_grow12 (
  input  wire [47:0] root_vec,
  input  wire [11:0] cluster_odd,
  input  wire [11:0] boundary_hit,
  input  wire [29:0] elen_vec,
  input  wire [11:0] blen_vec,
  output wire [29:0] elen_next,
  output wire [11:0] blen_next,
  output wire [14:0] full_edge,
  output wire [11:0] active_mask
);
  wire odd_r0, odd_r1, odd_r2, odd_r3, odd_r4, odd_r5;
  wire odd_r6, odd_r7, odd_r8, odd_r9, odd_r10, odd_r11;
  wire bh_r0, bh_r1, bh_r2, bh_r3, bh_r4, bh_r5;
  wire bh_r6, bh_r7, bh_r8, bh_r9, bh_r10, bh_r11;
  wire a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11;
  wire [1:0] ne0, ne1, ne2, ne3, ne4, ne5, ne6, ne7, ne8, ne9, ne10, ne11, ne12, ne13, ne14;
  wire [1:0] nb0, nb1, nb2, nb3, nb4, nb5;

  lakefillq_bit_mux12 u_od0  (.vec12(cluster_odd),  .idx(root_vec[3:0]),   .bit_out(odd_r0));
  lakefillq_bit_mux12 u_od1  (.vec12(cluster_odd),  .idx(root_vec[7:4]),   .bit_out(odd_r1));
  lakefillq_bit_mux12 u_od2  (.vec12(cluster_odd),  .idx(root_vec[11:8]),  .bit_out(odd_r2));
  lakefillq_bit_mux12 u_od3  (.vec12(cluster_odd),  .idx(root_vec[15:12]), .bit_out(odd_r3));
  lakefillq_bit_mux12 u_od4  (.vec12(cluster_odd),  .idx(root_vec[19:16]), .bit_out(odd_r4));
  lakefillq_bit_mux12 u_od5  (.vec12(cluster_odd),  .idx(root_vec[23:20]), .bit_out(odd_r5));
  lakefillq_bit_mux12 u_od6  (.vec12(cluster_odd),  .idx(root_vec[27:24]), .bit_out(odd_r6));
  lakefillq_bit_mux12 u_od7  (.vec12(cluster_odd),  .idx(root_vec[31:28]), .bit_out(odd_r7));
  lakefillq_bit_mux12 u_od8  (.vec12(cluster_odd),  .idx(root_vec[35:32]), .bit_out(odd_r8));
  lakefillq_bit_mux12 u_od9  (.vec12(cluster_odd),  .idx(root_vec[39:36]), .bit_out(odd_r9));
  lakefillq_bit_mux12 u_od10 (.vec12(cluster_odd),  .idx(root_vec[43:40]), .bit_out(odd_r10));
  lakefillq_bit_mux12 u_od11 (.vec12(cluster_odd),  .idx(root_vec[47:44]), .bit_out(odd_r11));

  lakefillq_bit_mux12 u_bh0  (.vec12(boundary_hit), .idx(root_vec[3:0]),   .bit_out(bh_r0));
  lakefillq_bit_mux12 u_bh1  (.vec12(boundary_hit), .idx(root_vec[7:4]),   .bit_out(bh_r1));
  lakefillq_bit_mux12 u_bh2  (.vec12(boundary_hit), .idx(root_vec[11:8]),  .bit_out(bh_r2));
  lakefillq_bit_mux12 u_bh3  (.vec12(boundary_hit), .idx(root_vec[15:12]), .bit_out(bh_r3));
  lakefillq_bit_mux12 u_bh4  (.vec12(boundary_hit), .idx(root_vec[19:16]), .bit_out(bh_r4));
  lakefillq_bit_mux12 u_bh5  (.vec12(boundary_hit), .idx(root_vec[23:20]), .bit_out(bh_r5));
  lakefillq_bit_mux12 u_bh6  (.vec12(boundary_hit), .idx(root_vec[27:24]), .bit_out(bh_r6));
  lakefillq_bit_mux12 u_bh7  (.vec12(boundary_hit), .idx(root_vec[31:28]), .bit_out(bh_r7));
  lakefillq_bit_mux12 u_bh8  (.vec12(boundary_hit), .idx(root_vec[35:32]), .bit_out(bh_r8));
  lakefillq_bit_mux12 u_bh9  (.vec12(boundary_hit), .idx(root_vec[39:36]), .bit_out(bh_r9));
  lakefillq_bit_mux12 u_bh10 (.vec12(boundary_hit), .idx(root_vec[43:40]), .bit_out(bh_r10));
  lakefillq_bit_mux12 u_bh11 (.vec12(boundary_hit), .idx(root_vec[47:44]), .bit_out(bh_r11));

  assign a0  = odd_r0  & (~bh_r0);
  assign a1  = odd_r1  & (~bh_r1);
  assign a2  = odd_r2  & (~bh_r2);
  assign a3  = odd_r3  & (~bh_r3);
  assign a4  = odd_r4  & (~bh_r4);
  assign a5  = odd_r5  & (~bh_r5);
  assign a6  = odd_r6  & (~bh_r6);
  assign a7  = odd_r7  & (~bh_r7);
  assign a8  = odd_r8  & (~bh_r8);
  assign a9  = odd_r9  & (~bh_r9);
  assign a10 = odd_r10 & (~bh_r10);
  assign a11 = odd_r11 & (~bh_r11);

  lakefillq_sat2_edge_inc u_e0  (.cur2(elen_vec[1:0]),   .a(a0), .b(a8),  .nxt2(ne0));
  lakefillq_sat2_edge_inc u_e1  (.cur2(elen_vec[3:2]),   .a(a0), .b(a2),  .nxt2(ne1));
  lakefillq_sat2_edge_inc u_e2  (.cur2(elen_vec[5:4]),   .a(a1), .b(a2),  .nxt2(ne2));
  lakefillq_sat2_edge_inc u_e3  (.cur2(elen_vec[7:6]),   .a(a1), .b(a3),  .nxt2(ne3));
  lakefillq_sat2_edge_inc u_e4  (.cur2(elen_vec[9:8]),   .a(a3), .b(a10), .nxt2(ne4));
  lakefillq_sat2_edge_inc u_e5  (.cur2(elen_vec[11:10]), .a(a4), .b(a8),  .nxt2(ne5));
  lakefillq_sat2_edge_inc u_e6  (.cur2(elen_vec[13:12]), .a(a2), .b(a4),  .nxt2(ne6));
  lakefillq_sat2_edge_inc u_e7  (.cur2(elen_vec[15:14]), .a(a2), .b(a5),  .nxt2(ne7));
  lakefillq_sat2_edge_inc u_e8  (.cur2(elen_vec[17:16]), .a(a3), .b(a5),  .nxt2(ne8));
  lakefillq_sat2_edge_inc u_e9  (.cur2(elen_vec[19:18]), .a(a3), .b(a11), .nxt2(ne9));
  lakefillq_sat2_edge_inc u_e10 (.cur2(elen_vec[21:20]), .a(a4), .b(a9),  .nxt2(ne10));
  lakefillq_sat2_edge_inc u_e11 (.cur2(elen_vec[23:22]), .a(a4), .b(a6),  .nxt2(ne11));
  lakefillq_sat2_edge_inc u_e12 (.cur2(elen_vec[25:24]), .a(a5), .b(a6),  .nxt2(ne12));
  lakefillq_sat2_edge_inc u_e13 (.cur2(elen_vec[27:26]), .a(a5), .b(a7),  .nxt2(ne13));
  lakefillq_sat2_edge_inc u_e14 (.cur2(elen_vec[29:28]), .a(a7), .b(a11), .nxt2(ne14));

  lakefillq_sat2_bnd_inc u_b0 (.cur2(blen_vec[1:0]),   .a(a0),  .nxt2(nb0));
  lakefillq_sat2_bnd_inc u_b1 (.cur2(blen_vec[3:2]),   .a(a1),  .nxt2(nb1));
  lakefillq_sat2_bnd_inc u_b2 (.cur2(blen_vec[5:4]),   .a(a6),  .nxt2(nb2));
  lakefillq_sat2_bnd_inc u_b3 (.cur2(blen_vec[7:6]),   .a(a7),  .nxt2(nb3));
  lakefillq_sat2_bnd_inc u_b4 (.cur2(blen_vec[9:8]),   .a(a9),  .nxt2(nb4));
  lakefillq_sat2_bnd_inc u_b5 (.cur2(blen_vec[11:10]), .a(a10), .nxt2(nb5));

  assign elen_next = {ne14, ne13, ne12, ne11, ne10, ne9, ne8, ne7, ne6, ne5, ne4, ne3, ne2, ne1, ne0};
  assign blen_next = {nb5, nb4, nb3, nb2, nb1, nb0};
  assign full_edge = {
    (ne14 == 2'd2), (ne13 == 2'd2), (ne12 == 2'd2), (ne11 == 2'd2), (ne10 == 2'd2),
    (ne9  == 2'd2), (ne8  == 2'd2), (ne7  == 2'd2), (ne6  == 2'd2), (ne5  == 2'd2),
    (ne4  == 2'd2), (ne3  == 2'd2), (ne2  == 2'd2), (ne1  == 2'd2), (ne0  == 2'd2)
  };
  assign active_mask = {a11, a10, a9, a8, a7, a6, a5, a4, a3, a2, a1, a0};
endmodule

module lakefillq_sv_hook_step12 (
  input  wire [47:0] root_vec,
  input  wire [14:0] full_edge,
  output wire [47:0] root_next
);
  wire [3:0] r0  = root_vec[3:0];
  wire [3:0] r1  = root_vec[7:4];
  wire [3:0] r2  = root_vec[11:8];
  wire [3:0] r3  = root_vec[15:12];
  wire [3:0] r4  = root_vec[19:16];
  wire [3:0] r5  = root_vec[23:20];
  wire [3:0] r6  = root_vec[27:24];
  wire [3:0] r7  = root_vec[31:28];
  wire [3:0] r8  = root_vec[35:32];
  wire [3:0] r9  = root_vec[39:36];
  wire [3:0] r10 = root_vec[43:40];
  wire [3:0] r11 = root_vec[47:44];

  wire [11:0] oh0, oh1, oh2, oh3, oh4, oh5, oh6, oh7, oh8, oh9, oh10, oh11;
  lakefillq_onehot12_u4 u_o0  (.r(r0),  .oh(oh0));
  lakefillq_onehot12_u4 u_o1  (.r(r1),  .oh(oh1));
  lakefillq_onehot12_u4 u_o2  (.r(r2),  .oh(oh2));
  lakefillq_onehot12_u4 u_o3  (.r(r3),  .oh(oh3));
  lakefillq_onehot12_u4 u_o4  (.r(r4),  .oh(oh4));
  lakefillq_onehot12_u4 u_o5  (.r(r5),  .oh(oh5));
  lakefillq_onehot12_u4 u_o6  (.r(r6),  .oh(oh6));
  lakefillq_onehot12_u4 u_o7  (.r(r7),  .oh(oh7));
  lakefillq_onehot12_u4 u_o8  (.r(r8),  .oh(oh8));
  lakefillq_onehot12_u4 u_o9  (.r(r9),  .oh(oh9));
  lakefillq_onehot12_u4 u_o10 (.r(r10), .oh(oh10));
  lakefillq_onehot12_u4 u_o11 (.r(r11), .oh(oh11));

  wire [11:0] nm0  = oh0  | ((full_edge[0]  ? oh8  : 12'd0) | (full_edge[1]  ? oh2  : 12'd0));
  wire [11:0] nm1  = oh1  | ((full_edge[2]  ? oh2  : 12'd0) | (full_edge[3]  ? oh3  : 12'd0));
  wire [11:0] nm2  = (oh2 | (full_edge[1]   ? oh0  : 12'd0)) | ((full_edge[2]  ? oh1 : 12'd0) | ((full_edge[6]  ? oh4 : 12'd0) | (full_edge[7]  ? oh5  : 12'd0)));
  wire [11:0] nm3  = (oh3 | (full_edge[3]   ? oh1  : 12'd0)) | ((full_edge[4]  ? oh10: 12'd0) | ((full_edge[8]  ? oh5 : 12'd0) | (full_edge[9]  ? oh11 : 12'd0)));
  wire [11:0] nm4  = (oh4 | (full_edge[5]   ? oh8  : 12'd0)) | ((full_edge[6]  ? oh2 : 12'd0) | ((full_edge[10] ? oh9 : 12'd0) | (full_edge[11] ? oh6  : 12'd0)));
  wire [11:0] nm5  = (oh5 | (full_edge[7]   ? oh2  : 12'd0)) | ((full_edge[8]  ? oh3 : 12'd0) | ((full_edge[12] ? oh6 : 12'd0) | (full_edge[13] ? oh7  : 12'd0)));
  wire [11:0] nm6  = oh6  | ((full_edge[11] ? oh4  : 12'd0) | (full_edge[12] ? oh5  : 12'd0));
  wire [11:0] nm7  = oh7  | ((full_edge[13] ? oh5  : 12'd0) | (full_edge[14] ? oh11 : 12'd0));
  wire [11:0] nm8  = oh8  | ((full_edge[0]  ? oh0  : 12'd0) | (full_edge[5]  ? oh4  : 12'd0));
  wire [11:0] nm9  = oh9  | (full_edge[10]  ? oh4  : 12'd0);
  wire [11:0] nm10 = oh10 | (full_edge[4]   ? oh3  : 12'd0);
  wire [11:0] nm11 = oh11 | ((full_edge[9]  ? oh3  : 12'd0) | (full_edge[14] ? oh7  : 12'd0));

  wire [11:0] cm0, cm1, cm2, cm3, cm4, cm5, cm6, cm7, cm8, cm9, cm10, cm11;
  lakefillq_braun_or12_u12 u_c0  (.x0(oh0[0]?nm0:12'd1),     .x1(oh1[0]?nm1:12'd0),     .x2(oh2[0]?nm2:12'd0),     .x3(oh3[0]?nm3:12'd0),     .x4(oh4[0]?nm4:12'd0),     .x5(oh5[0]?nm5:12'd0),     .x6(oh6[0]?nm6:12'd0),     .x7(oh7[0]?nm7:12'd0),     .x8(oh8[0]?nm8:12'd0),     .x9(oh9[0]?nm9:12'd0),     .x10(oh10[0]?nm10:12'd0),     .x11(oh11[0]?nm11:12'd0),     .or_u12(cm0));
  lakefillq_braun_or12_u12 u_c1  (.x0(oh0[1]?nm0:12'd2),     .x1(oh1[1]?nm1:12'd0),     .x2(oh2[1]?nm2:12'd0),     .x3(oh3[1]?nm3:12'd0),     .x4(oh4[1]?nm4:12'd0),     .x5(oh5[1]?nm5:12'd0),     .x6(oh6[1]?nm6:12'd0),     .x7(oh7[1]?nm7:12'd0),     .x8(oh8[1]?nm8:12'd0),     .x9(oh9[1]?nm9:12'd0),     .x10(oh10[1]?nm10:12'd0),     .x11(oh11[1]?nm11:12'd0),     .or_u12(cm1));
  lakefillq_braun_or12_u12 u_c2  (.x0(oh0[2]?nm0:12'd4),     .x1(oh1[2]?nm1:12'd0),     .x2(oh2[2]?nm2:12'd0),     .x3(oh3[2]?nm3:12'd0),     .x4(oh4[2]?nm4:12'd0),     .x5(oh5[2]?nm5:12'd0),     .x6(oh6[2]?nm6:12'd0),     .x7(oh7[2]?nm7:12'd0),     .x8(oh8[2]?nm8:12'd0),     .x9(oh9[2]?nm9:12'd0),     .x10(oh10[2]?nm10:12'd0),     .x11(oh11[2]?nm11:12'd0),     .or_u12(cm2));
  lakefillq_braun_or12_u12 u_c3  (.x0(oh0[3]?nm0:12'd8),     .x1(oh1[3]?nm1:12'd0),     .x2(oh2[3]?nm2:12'd0),     .x3(oh3[3]?nm3:12'd0),     .x4(oh4[3]?nm4:12'd0),     .x5(oh5[3]?nm5:12'd0),     .x6(oh6[3]?nm6:12'd0),     .x7(oh7[3]?nm7:12'd0),     .x8(oh8[3]?nm8:12'd0),     .x9(oh9[3]?nm9:12'd0),     .x10(oh10[3]?nm10:12'd0),     .x11(oh11[3]?nm11:12'd0),     .or_u12(cm3));
  lakefillq_braun_or12_u12 u_c4  (.x0(oh0[4]?nm0:12'd16),    .x1(oh1[4]?nm1:12'd0),    .x2(oh2[4]?nm2:12'd0),    .x3(oh3[4]?nm3:12'd0),    .x4(oh4[4]?nm4:12'd0),    .x5(oh5[4]?nm5:12'd0),    .x6(oh6[4]?nm6:12'd0),    .x7(oh7[4]?nm7:12'd0),    .x8(oh8[4]?nm8:12'd0),    .x9(oh9[4]?nm9:12'd0),    .x10(oh10[4]?nm10:12'd0),    .x11(oh11[4]?nm11:12'd0),    .or_u12(cm4));
  lakefillq_braun_or12_u12 u_c5  (.x0(oh0[5]?nm0:12'd32),    .x1(oh1[5]?nm1:12'd0),    .x2(oh2[5]?nm2:12'd0),    .x3(oh3[5]?nm3:12'd0),    .x4(oh4[5]?nm4:12'd0),    .x5(oh5[5]?nm5:12'd0),    .x6(oh6[5]?nm6:12'd0),    .x7(oh7[5]?nm7:12'd0),    .x8(oh8[5]?nm8:12'd0),    .x9(oh9[5]?nm9:12'd0),    .x10(oh10[5]?nm10:12'd0),    .x11(oh11[5]?nm11:12'd0),    .or_u12(cm5));
  lakefillq_braun_or12_u12 u_c6  (.x0(oh0[6]?nm0:12'd64),    .x1(oh1[6]?nm1:12'd0),    .x2(oh2[6]?nm2:12'd0),    .x3(oh3[6]?nm3:12'd0),    .x4(oh4[6]?nm4:12'd0),    .x5(oh5[6]?nm5:12'd0),    .x6(oh6[6]?nm6:12'd0),    .x7(oh7[6]?nm7:12'd0),    .x8(oh8[6]?nm8:12'd0),    .x9(oh9[6]?nm9:12'd0),    .x10(oh10[6]?nm10:12'd0),    .x11(oh11[6]?nm11:12'd0),    .or_u12(cm6));
  lakefillq_braun_or12_u12 u_c7  (.x0(oh0[7]?nm0:12'd128),   .x1(oh1[7]?nm1:12'd0),   .x2(oh2[7]?nm2:12'd0),   .x3(oh3[7]?nm3:12'd0),   .x4(oh4[7]?nm4:12'd0),   .x5(oh5[7]?nm5:12'd0),   .x6(oh6[7]?nm6:12'd0),   .x7(oh7[7]?nm7:12'd0),   .x8(oh8[7]?nm8:12'd0),   .x9(oh9[7]?nm9:12'd0),   .x10(oh10[7]?nm10:12'd0),   .x11(oh11[7]?nm11:12'd0),   .or_u12(cm7));
  lakefillq_braun_or12_u12 u_c8  (.x0(oh0[8]?nm0:12'd256),   .x1(oh1[8]?nm1:12'd0),   .x2(oh2[8]?nm2:12'd0),   .x3(oh3[8]?nm3:12'd0),   .x4(oh4[8]?nm4:12'd0),   .x5(oh5[8]?nm5:12'd0),   .x6(oh6[8]?nm6:12'd0),   .x7(oh7[8]?nm7:12'd0),   .x8(oh8[8]?nm8:12'd0),   .x9(oh9[8]?nm9:12'd0),   .x10(oh10[8]?nm10:12'd0),   .x11(oh11[8]?nm11:12'd0),   .or_u12(cm8));
  lakefillq_braun_or12_u12 u_c9  (.x0(oh0[9]?nm0:12'd512),   .x1(oh1[9]?nm1:12'd0),   .x2(oh2[9]?nm2:12'd0),   .x3(oh3[9]?nm3:12'd0),   .x4(oh4[9]?nm4:12'd0),   .x5(oh5[9]?nm5:12'd0),   .x6(oh6[9]?nm6:12'd0),   .x7(oh7[9]?nm7:12'd0),   .x8(oh8[9]?nm8:12'd0),   .x9(oh9[9]?nm9:12'd0),   .x10(oh10[9]?nm10:12'd0),   .x11(oh11[9]?nm11:12'd0),   .or_u12(cm9));
  lakefillq_braun_or12_u12 u_c10 (.x0(oh0[10]?nm0:12'd1024), .x1(oh1[10]?nm1:12'd0), .x2(oh2[10]?nm2:12'd0), .x3(oh3[10]?nm3:12'd0), .x4(oh4[10]?nm4:12'd0), .x5(oh5[10]?nm5:12'd0), .x6(oh6[10]?nm6:12'd0), .x7(oh7[10]?nm7:12'd0), .x8(oh8[10]?nm8:12'd0), .x9(oh9[10]?nm9:12'd0), .x10(oh10[10]?nm10:12'd0), .x11(oh11[10]?nm11:12'd0), .or_u12(cm10));
  lakefillq_braun_or12_u12 u_c11 (.x0(oh0[11]?nm0:12'd2048), .x1(oh1[11]?nm1:12'd0), .x2(oh2[11]?nm2:12'd0), .x3(oh3[11]?nm3:12'd0), .x4(oh4[11]?nm4:12'd0), .x5(oh5[11]?nm5:12'd0), .x6(oh6[11]?nm6:12'd0), .x7(oh7[11]?nm7:12'd0), .x8(oh8[11]?nm8:12'd0), .x9(oh9[11]?nm9:12'd0), .x10(oh10[11]?nm10:12'd0), .x11(oh11[11]?nm11:12'd0), .or_u12(cm11));

  wire [3:0] hk0, hk1, hk2, hk3, hk4, hk5, hk6, hk7, hk8, hk9, hk10, hk11;
  lakefillq_ffs12_u4 u_f0  (.m(cm0  | 12'd1),    .min_idx(hk0));
  lakefillq_ffs12_u4 u_f1  (.m(cm1  | 12'd2),    .min_idx(hk1));
  lakefillq_ffs12_u4 u_f2  (.m(cm2  | 12'd4),    .min_idx(hk2));
  lakefillq_ffs12_u4 u_f3  (.m(cm3  | 12'd8),    .min_idx(hk3));
  lakefillq_ffs12_u4 u_f4  (.m(cm4  | 12'd16),   .min_idx(hk4));
  lakefillq_ffs12_u4 u_f5  (.m(cm5  | 12'd32),   .min_idx(hk5));
  lakefillq_ffs12_u4 u_f6  (.m(cm6  | 12'd64),   .min_idx(hk6));
  lakefillq_ffs12_u4 u_f7  (.m(cm7  | 12'd128),  .min_idx(hk7));
  lakefillq_ffs12_u4 u_f8  (.m(cm8  | 12'd256),  .min_idx(hk8));
  lakefillq_ffs12_u4 u_f9  (.m(cm9  | 12'd512),  .min_idx(hk9));
  lakefillq_ffs12_u4 u_f10 (.m(cm10 | 12'd1024), .min_idx(hk10));
  lakefillq_ffs12_u4 u_f11 (.m(cm11 | 12'd2048), .min_idx(hk11));

  wire [3:0] nr0, nr1, nr2, nr3, nr4, nr5, nr6, nr7, nr8, nr9, nr10, nr11;
  lakefillq_mux12_u4 u_nr0  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r0),  .out_u4(nr0));
  lakefillq_mux12_u4 u_nr1  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r1),  .out_u4(nr1));
  lakefillq_mux12_u4 u_nr2  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r2),  .out_u4(nr2));
  lakefillq_mux12_u4 u_nr3  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r3),  .out_u4(nr3));
  lakefillq_mux12_u4 u_nr4  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r4),  .out_u4(nr4));
  lakefillq_mux12_u4 u_nr5  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r5),  .out_u4(nr5));
  lakefillq_mux12_u4 u_nr6  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r6),  .out_u4(nr6));
  lakefillq_mux12_u4 u_nr7  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r7),  .out_u4(nr7));
  lakefillq_mux12_u4 u_nr8  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r8),  .out_u4(nr8));
  lakefillq_mux12_u4 u_nr9  (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r9),  .out_u4(nr9));
  lakefillq_mux12_u4 u_nr10 (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r10), .out_u4(nr10));
  lakefillq_mux12_u4 u_nr11 (.v0(hk0), .v1(hk1), .v2(hk2), .v3(hk3), .v4(hk4), .v5(hk5), .v6(hk6), .v7(hk7), .v8(hk8), .v9(hk9), .v10(hk10), .v11(hk11), .idx(r11), .out_u4(nr11));

  assign root_next = {nr11, nr10, nr9, nr8, nr7, nr6, nr5, nr4, nr3, nr2, nr1, nr0};
endmodule

module lakefillq_cluster_xor_id (
  input  wire [47:0] jr_vec,
  input  wire [11:0] syn12,
  input  wire [3:0]  target,
  output wire        odd_out
);
  wire t0  = (jr_vec[3:0]   == target) ? syn12[0]  : 1'b0;
  wire t1  = (jr_vec[7:4]   == target) ? syn12[1]  : 1'b0;
  wire t2  = (jr_vec[11:8]  == target) ? syn12[2]  : 1'b0;
  wire t3  = (jr_vec[15:12] == target) ? syn12[3]  : 1'b0;
  wire t4  = (jr_vec[19:16] == target) ? syn12[4]  : 1'b0;
  wire t5  = (jr_vec[23:20] == target) ? syn12[5]  : 1'b0;
  wire t6  = (jr_vec[27:24] == target) ? syn12[6]  : 1'b0;
  wire t7  = (jr_vec[31:28] == target) ? syn12[7]  : 1'b0;
  wire t8  = (jr_vec[35:32] == target) ? syn12[8]  : 1'b0;
  wire t9  = (jr_vec[39:36] == target) ? syn12[9]  : 1'b0;
  wire t10 = (jr_vec[43:40] == target) ? syn12[10] : 1'b0;
  wire t11 = (jr_vec[47:44] == target) ? syn12[11] : 1'b0;
  assign odd_out = ((t0 ^ t1) ^ (t2 ^ t3)) ^ ((t4 ^ t5) ^ (t6 ^ t7)) ^ ((t8 ^ t9) ^ (t10 ^ t11));
endmodule

module lakefillq_cluster_bhit_id (
  input  wire [47:0] jr_vec,
  input  wire [5:0]  bf_vec,
  input  wire [3:0]  target,
  output wire        bhit_out
);
  wire h0 = (jr_vec[3:0]   == target) ? bf_vec[0] : 1'b0;
  wire h1 = (jr_vec[7:4]   == target) ? bf_vec[1] : 1'b0;
  wire h2 = (jr_vec[27:24] == target) ? bf_vec[2] : 1'b0;
  wire h3 = (jr_vec[31:28] == target) ? bf_vec[3] : 1'b0;
  wire h4 = (jr_vec[39:36] == target) ? bf_vec[4] : 1'b0;
  wire h5 = (jr_vec[43:40] == target) ? bf_vec[5] : 1'b0;
  assign bhit_out = (h0 | h1 | h2) | (h3 | h4 | h5);
endmodule

module lakefillq_sv_pointer_jump_parity12 (
  input  wire [47:0] root_vec,
  input  wire [11:0] syn12,
  input  wire [11:0] blen_vec,
  output wire [47:0] root_jump,
  output wire [11:0] cluster_odd,
  output wire [11:0] boundary_hit
);
  wire [3:0] r0  = root_vec[3:0];
  wire [3:0] r1  = root_vec[7:4];
  wire [3:0] r2  = root_vec[11:8];
  wire [3:0] r3  = root_vec[15:12];
  wire [3:0] r4  = root_vec[19:16];
  wire [3:0] r5  = root_vec[23:20];
  wire [3:0] r6  = root_vec[27:24];
  wire [3:0] r7  = root_vec[31:28];
  wire [3:0] r8  = root_vec[35:32];
  wire [3:0] r9  = root_vec[39:36];
  wire [3:0] r10 = root_vec[43:40];
  wire [3:0] r11 = root_vec[47:44];

  wire [3:0] jr0, jr1, jr2, jr3, jr4, jr5, jr6, jr7, jr8, jr9, jr10, jr11;
  wire [5:0] bf_vec;

  lakefillq_mux12_u4 u_j0  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r0),  .out_u4(jr0));
  lakefillq_mux12_u4 u_j1  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r1),  .out_u4(jr1));
  lakefillq_mux12_u4 u_j2  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r2),  .out_u4(jr2));
  lakefillq_mux12_u4 u_j3  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r3),  .out_u4(jr3));
  lakefillq_mux12_u4 u_j4  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r4),  .out_u4(jr4));
  lakefillq_mux12_u4 u_j5  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r5),  .out_u4(jr5));
  lakefillq_mux12_u4 u_j6  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r6),  .out_u4(jr6));
  lakefillq_mux12_u4 u_j7  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r7),  .out_u4(jr7));
  lakefillq_mux12_u4 u_j8  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r8),  .out_u4(jr8));
  lakefillq_mux12_u4 u_j9  (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r9),  .out_u4(jr9));
  lakefillq_mux12_u4 u_j10 (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r10), .out_u4(jr10));
  lakefillq_mux12_u4 u_j11 (.v0(r0), .v1(r1), .v2(r2), .v3(r3), .v4(r4), .v5(r5), .v6(r6), .v7(r7), .v8(r8), .v9(r9), .v10(r10), .v11(r11), .idx(r11), .out_u4(jr11));

  assign root_jump = {jr11, jr10, jr9, jr8, jr7, jr6, jr5, jr4, jr3, jr2, jr1, jr0};
  assign bf_vec = {
    (blen_vec[11:10] == 2'd2), (blen_vec[9:8] == 2'd2), (blen_vec[7:6] == 2'd2),
    (blen_vec[5:4]   == 2'd2), (blen_vec[3:2] == 2'd2), (blen_vec[1:0] == 2'd2)
  };

  lakefillq_cluster_xor_id u_ox0  (.jr_vec(root_jump), .syn12(syn12), .target(4'd0),  .odd_out(cluster_odd[0]));
  lakefillq_cluster_xor_id u_ox1  (.jr_vec(root_jump), .syn12(syn12), .target(4'd1),  .odd_out(cluster_odd[1]));
  lakefillq_cluster_xor_id u_ox2  (.jr_vec(root_jump), .syn12(syn12), .target(4'd2),  .odd_out(cluster_odd[2]));
  lakefillq_cluster_xor_id u_ox3  (.jr_vec(root_jump), .syn12(syn12), .target(4'd3),  .odd_out(cluster_odd[3]));
  lakefillq_cluster_xor_id u_ox4  (.jr_vec(root_jump), .syn12(syn12), .target(4'd4),  .odd_out(cluster_odd[4]));
  lakefillq_cluster_xor_id u_ox5  (.jr_vec(root_jump), .syn12(syn12), .target(4'd5),  .odd_out(cluster_odd[5]));
  lakefillq_cluster_xor_id u_ox6  (.jr_vec(root_jump), .syn12(syn12), .target(4'd6),  .odd_out(cluster_odd[6]));
  lakefillq_cluster_xor_id u_ox7  (.jr_vec(root_jump), .syn12(syn12), .target(4'd7),  .odd_out(cluster_odd[7]));
  lakefillq_cluster_xor_id u_ox8  (.jr_vec(root_jump), .syn12(syn12), .target(4'd8),  .odd_out(cluster_odd[8]));
  lakefillq_cluster_xor_id u_ox9  (.jr_vec(root_jump), .syn12(syn12), .target(4'd9),  .odd_out(cluster_odd[9]));
  lakefillq_cluster_xor_id u_ox10 (.jr_vec(root_jump), .syn12(syn12), .target(4'd10), .odd_out(cluster_odd[10]));
  lakefillq_cluster_xor_id u_ox11 (.jr_vec(root_jump), .syn12(syn12), .target(4'd11), .odd_out(cluster_odd[11]));

  lakefillq_cluster_bhit_id u_ob0  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd0),  .bhit_out(boundary_hit[0]));
  lakefillq_cluster_bhit_id u_ob1  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd1),  .bhit_out(boundary_hit[1]));
  lakefillq_cluster_bhit_id u_ob2  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd2),  .bhit_out(boundary_hit[2]));
  lakefillq_cluster_bhit_id u_ob3  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd3),  .bhit_out(boundary_hit[3]));
  lakefillq_cluster_bhit_id u_ob4  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd4),  .bhit_out(boundary_hit[4]));
  lakefillq_cluster_bhit_id u_ob5  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd5),  .bhit_out(boundary_hit[5]));
  lakefillq_cluster_bhit_id u_ob6  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd6),  .bhit_out(boundary_hit[6]));
  lakefillq_cluster_bhit_id u_ob7  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd7),  .bhit_out(boundary_hit[7]));
  lakefillq_cluster_bhit_id u_ob8  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd8),  .bhit_out(boundary_hit[8]));
  lakefillq_cluster_bhit_id u_ob9  (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd9),  .bhit_out(boundary_hit[9]));
  lakefillq_cluster_bhit_id u_ob10 (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd10), .bhit_out(boundary_hit[10]));
  lakefillq_cluster_bhit_id u_ob11 (.jr_vec(root_jump), .bf_vec(bf_vec), .target(4'd11), .bhit_out(boundary_hit[11]));
endmodule

module lakefillq_seed_for_cluster (
  input  wire [47:0] root_vec,
  input  wire [5:0]  bf_vec,
  input  wire [3:0]  cid,
  output wire [3:0]  seed_v
);
  assign seed_v = ((root_vec[3:0]   == cid) & bf_vec[0]) ? 4'd0  :
                  ((root_vec[7:4]   == cid) & bf_vec[1]) ? 4'd1  :
                  ((root_vec[27:24] == cid) & bf_vec[2]) ? 4'd6  :
                  ((root_vec[31:28] == cid) & bf_vec[3]) ? 4'd7  :
                  ((root_vec[39:36] == cid) & bf_vec[4]) ? 4'd9  :
                  ((root_vec[43:40] == cid) & bf_vec[5]) ? 4'd10 : cid;
endmodule

module lakefillq_bfs_seed_init12 (
  input  wire [47:0] root_vec,
  input  wire [11:0] blen_vec,
  output wire [11:0] vis_init
);
  wire [5:0] bf_vec;
  wire [3:0] sd0, sd1, sd2, sd3, sd4, sd5, sd6, sd7, sd8, sd9, sd10, sd11;
  wire [3:0] ms0, ms1, ms2, ms3, ms4, ms5, ms6, ms7, ms8, ms9, ms10, ms11;

  assign bf_vec = {
    (blen_vec[11:10] == 2'd2), (blen_vec[9:8] == 2'd2), (blen_vec[7:6] == 2'd2),
    (blen_vec[5:4]   == 2'd2), (blen_vec[3:2] == 2'd2), (blen_vec[1:0] == 2'd2)
  };

  lakefillq_seed_for_cluster u_sd0  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd0),  .seed_v(sd0));
  lakefillq_seed_for_cluster u_sd1  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd1),  .seed_v(sd1));
  lakefillq_seed_for_cluster u_sd2  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd2),  .seed_v(sd2));
  lakefillq_seed_for_cluster u_sd3  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd3),  .seed_v(sd3));
  lakefillq_seed_for_cluster u_sd4  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd4),  .seed_v(sd4));
  lakefillq_seed_for_cluster u_sd5  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd5),  .seed_v(sd5));
  lakefillq_seed_for_cluster u_sd6  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd6),  .seed_v(sd6));
  lakefillq_seed_for_cluster u_sd7  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd7),  .seed_v(sd7));
  lakefillq_seed_for_cluster u_sd8  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd8),  .seed_v(sd8));
  lakefillq_seed_for_cluster u_sd9  (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd9),  .seed_v(sd9));
  lakefillq_seed_for_cluster u_sd10 (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd10), .seed_v(sd10));
  lakefillq_seed_for_cluster u_sd11 (.root_vec(root_vec), .bf_vec(bf_vec), .cid(4'd11), .seed_v(sd11));

  lakefillq_mux12_u4 u_m0  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[3:0]),   .out_u4(ms0));
  lakefillq_mux12_u4 u_m1  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[7:4]),   .out_u4(ms1));
  lakefillq_mux12_u4 u_m2  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[11:8]),  .out_u4(ms2));
  lakefillq_mux12_u4 u_m3  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[15:12]), .out_u4(ms3));
  lakefillq_mux12_u4 u_m4  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[19:16]), .out_u4(ms4));
  lakefillq_mux12_u4 u_m5  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[23:20]), .out_u4(ms5));
  lakefillq_mux12_u4 u_m6  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[27:24]), .out_u4(ms6));
  lakefillq_mux12_u4 u_m7  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[31:28]), .out_u4(ms7));
  lakefillq_mux12_u4 u_m8  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[35:32]), .out_u4(ms8));
  lakefillq_mux12_u4 u_m9  (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[39:36]), .out_u4(ms9));
  lakefillq_mux12_u4 u_m10 (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[43:40]), .out_u4(ms10));
  lakefillq_mux12_u4 u_m11 (.v0(sd0), .v1(sd1), .v2(sd2), .v3(sd3), .v4(sd4), .v5(sd5), .v6(sd6), .v7(sd7), .v8(sd8), .v9(sd9), .v10(sd10), .v11(sd11), .idx(root_vec[47:44]), .out_u4(ms11));

  assign vis_init = {
    (ms11 == 4'd11), (ms10 == 4'd10), (ms9 == 4'd9), (ms8 == 4'd8),
    (ms7  == 4'd7),  (ms6  == 4'd6),  (ms5 == 4'd5), (ms4 == 4'd4),
    (ms3  == 4'd3),  (ms2  == 4'd2),  (ms1 == 4'd1), (ms0 == 4'd0)
  };
endmodule

module lakefillq_bfs_vertex_deg4 (
  input  wire       vis_self,
  input  wire [3:0] cur_pe,
  input  wire [3:0] cur_pv,
  input  wire [2:0] cur_lv,
  input  wire [2:0] cur_lvl,
  input  wire       c0,
  input  wire [3:0] e0,
  input  wire [3:0] nb0,
  input  wire       c1,
  input  wire [3:0] e1,
  input  wire [3:0] nb1,
  input  wire       c2,
  input  wire [3:0] e2,
  input  wire [3:0] nb2,
  input  wire       c3,
  input  wire [3:0] e3,
  input  wire [3:0] nb3,
  output wire       nxt_vis,
  output wire [3:0] nxt_pe,
  output wire [3:0] nxt_pv,
  output wire [2:0] nxt_lv
);
  assign nxt_vis = vis_self ? 1'b1   : (c0 ? 1'b1    : (c1 ? 1'b1    : (c2 ? 1'b1    : (c3 ? 1'b1    : 1'b0))));
  assign nxt_pe  = vis_self ? cur_pe : (c0 ? e0      : (c1 ? e1      : (c2 ? e2      : (c3 ? e3      : cur_pe))));
  assign nxt_pv  = vis_self ? cur_pv : (c0 ? nb0     : (c1 ? nb1     : (c2 ? nb2     : (c3 ? nb3     : cur_pv))));
  assign nxt_lv  = vis_self ? cur_lv : (c0 ? cur_lvl : (c1 ? cur_lvl : (c2 ? cur_lvl : (c3 ? cur_lvl : cur_lv))));
endmodule

module lakefillq_bfs_forest_step12 (
  input  wire [11:0] vis,
  input  wire [47:0] pe_vec,
  input  wire [47:0] pv_vec,
  input  wire [35:0] lv_vec,
  input  wire [14:0] full_edge,
  input  wire [2:0]  cur_lvl,
  output wire [11:0] vis_next,
  output wire [47:0] pe_next,
  output wire [47:0] pv_next,
  output wire [35:0] lv_next
);
  lakefillq_bfs_vertex_deg4 u_bf0  (.vis_self(vis[0]),  .cur_pe(pe_vec[3:0]),   .cur_pv(pv_vec[3:0]),   .cur_lv(lv_vec[2:0]),   .cur_lvl(cur_lvl), .c0(full_edge[0]&vis[8]),   .e0(4'd0),  .nb0(4'd8),  .c1(full_edge[1]&vis[2]),   .e1(4'd1),  .nb1(4'd2),  .c2(1'b0),                 .e2(4'd0),  .nb2(4'd0),  .c3(1'b0),                 .e3(4'd0),  .nb3(4'd0),  .nxt_vis(vis_next[0]),  .nxt_pe(pe_next[3:0]),   .nxt_pv(pv_next[3:0]),   .nxt_lv(lv_next[2:0]));
  lakefillq_bfs_vertex_deg4 u_bf1  (.vis_self(vis[1]),  .cur_pe(pe_vec[7:4]),   .cur_pv(pv_vec[7:4]),   .cur_lv(lv_vec[5:3]),   .cur_lvl(cur_lvl), .c0(full_edge[2]&vis[2]),   .e0(4'd2),  .nb0(4'd2),  .c1(full_edge[3]&vis[3]),   .e1(4'd3),  .nb1(4'd3),  .c2(1'b0),                 .e2(4'd0),  .nb2(4'd1),  .c3(1'b0),                 .e3(4'd0),  .nb3(4'd1),  .nxt_vis(vis_next[1]),  .nxt_pe(pe_next[7:4]),   .nxt_pv(pv_next[7:4]),   .nxt_lv(lv_next[5:3]));
  lakefillq_bfs_vertex_deg4 u_bf2  (.vis_self(vis[2]),  .cur_pe(pe_vec[11:8]),  .cur_pv(pv_vec[11:8]),  .cur_lv(lv_vec[8:6]),   .cur_lvl(cur_lvl), .c0(full_edge[1]&vis[0]),   .e0(4'd1),  .nb0(4'd0),  .c1(full_edge[2]&vis[1]),   .e1(4'd2),  .nb1(4'd1),  .c2(full_edge[6]&vis[4]),  .e2(4'd6),  .nb2(4'd4),  .c3(full_edge[7]&vis[5]),  .e3(4'd7),  .nb3(4'd5),  .nxt_vis(vis_next[2]),  .nxt_pe(pe_next[11:8]),  .nxt_pv(pv_next[11:8]),  .nxt_lv(lv_next[8:6]));
  lakefillq_bfs_vertex_deg4 u_bf3  (.vis_self(vis[3]),  .cur_pe(pe_vec[15:12]), .cur_pv(pv_vec[15:12]), .cur_lv(lv_vec[11:9]),  .cur_lvl(cur_lvl), .c0(full_edge[3]&vis[1]),   .e0(4'd3),  .nb0(4'd1),  .c1(full_edge[4]&vis[10]),  .e1(4'd4),  .nb1(4'd10), .c2(full_edge[8]&vis[5]),  .e2(4'd8),  .nb2(4'd5),  .c3(full_edge[9]&vis[11]), .e3(4'd9),  .nb3(4'd11), .nxt_vis(vis_next[3]),  .nxt_pe(pe_next[15:12]), .nxt_pv(pv_next[15:12]), .nxt_lv(lv_next[11:9]));
  lakefillq_bfs_vertex_deg4 u_bf4  (.vis_self(vis[4]),  .cur_pe(pe_vec[19:16]), .cur_pv(pv_vec[19:16]), .cur_lv(lv_vec[14:12]), .cur_lvl(cur_lvl), .c0(full_edge[5]&vis[8]),   .e0(4'd5),  .nb0(4'd8),  .c1(full_edge[6]&vis[2]),   .e1(4'd6),  .nb1(4'd2),  .c2(full_edge[10]&vis[9]), .e2(4'd10), .nb2(4'd9),  .c3(full_edge[11]&vis[6]), .e3(4'd11), .nb3(4'd6),  .nxt_vis(vis_next[4]),  .nxt_pe(pe_next[19:16]), .nxt_pv(pv_next[19:16]), .nxt_lv(lv_next[14:12]));
  lakefillq_bfs_vertex_deg4 u_bf5  (.vis_self(vis[5]),  .cur_pe(pe_vec[23:20]), .cur_pv(pv_vec[23:20]), .cur_lv(lv_vec[17:15]), .cur_lvl(cur_lvl), .c0(full_edge[7]&vis[2]),   .e0(4'd7),  .nb0(4'd2),  .c1(full_edge[8]&vis[3]),   .e1(4'd8),  .nb1(4'd3),  .c2(full_edge[12]&vis[6]), .e2(4'd12), .nb2(4'd6),  .c3(full_edge[13]&vis[7]), .e3(4'd13), .nb3(4'd7),  .nxt_vis(vis_next[5]),  .nxt_pe(pe_next[23:20]), .nxt_pv(pv_next[23:20]), .nxt_lv(lv_next[17:15]));
  lakefillq_bfs_vertex_deg4 u_bf6  (.vis_self(vis[6]),  .cur_pe(pe_vec[27:24]), .cur_pv(pv_vec[27:24]), .cur_lv(lv_vec[20:18]), .cur_lvl(cur_lvl), .c0(full_edge[11]&vis[4]),  .e0(4'd11), .nb0(4'd4),  .c1(full_edge[12]&vis[5]),  .e1(4'd12), .nb1(4'd5),  .c2(1'b0),                 .e2(4'd0),  .nb2(4'd6),  .c3(1'b0),                 .e3(4'd0),  .nb3(4'd6),  .nxt_vis(vis_next[6]),  .nxt_pe(pe_next[27:24]), .nxt_pv(pv_next[27:24]), .nxt_lv(lv_next[20:18]));
  lakefillq_bfs_vertex_deg4 u_bf7  (.vis_self(vis[7]),  .cur_pe(pe_vec[31:28]), .cur_pv(pv_vec[31:28]), .cur_lv(lv_vec[23:21]), .cur_lvl(cur_lvl), .c0(full_edge[13]&vis[5]),  .e0(4'd13), .nb0(4'd5),  .c1(full_edge[14]&vis[11]), .e1(4'd14), .nb1(4'd11), .c2(1'b0),                 .e2(4'd0),  .nb2(4'd7),  .c3(1'b0),                 .e3(4'd0),  .nb3(4'd7),  .nxt_vis(vis_next[7]),  .nxt_pe(pe_next[31:28]), .nxt_pv(pv_next[31:28]), .nxt_lv(lv_next[23:21]));
  lakefillq_bfs_vertex_deg4 u_bf8  (.vis_self(vis[8]),  .cur_pe(pe_vec[35:32]), .cur_pv(pv_vec[35:32]), .cur_lv(lv_vec[26:24]), .cur_lvl(cur_lvl), .c0(full_edge[0]&vis[0]),   .e0(4'd0),  .nb0(4'd0),  .c1(full_edge[5]&vis[4]),   .e1(4'd5),  .nb1(4'd4),  .c2(1'b0),                 .e2(4'd0),  .nb2(4'd8),  .c3(1'b0),                 .e3(4'd0),  .nb3(4'd8),  .nxt_vis(vis_next[8]),  .nxt_pe(pe_next[35:32]), .nxt_pv(pv_next[35:32]), .nxt_lv(lv_next[26:24]));
  lakefillq_bfs_vertex_deg4 u_bf9  (.vis_self(vis[9]),  .cur_pe(pe_vec[39:36]), .cur_pv(pv_vec[39:36]), .cur_lv(lv_vec[29:27]), .cur_lvl(cur_lvl), .c0(full_edge[10]&vis[4]),  .e0(4'd10), .nb0(4'd4),  .c1(1'b0),                  .e1(4'd0),  .nb1(4'd9),  .c2(1'b0),                 .e2(4'd0),  .nb2(4'd9),  .c3(1'b0),                 .e3(4'd0),  .nb3(4'd9),  .nxt_vis(vis_next[9]),  .nxt_pe(pe_next[39:36]), .nxt_pv(pv_next[39:36]), .nxt_lv(lv_next[29:27]));
  lakefillq_bfs_vertex_deg4 u_bf10 (.vis_self(vis[10]), .cur_pe(pe_vec[43:40]), .cur_pv(pv_vec[43:40]), .cur_lv(lv_vec[32:30]), .cur_lvl(cur_lvl), .c0(full_edge[4]&vis[3]),   .e0(4'd4),  .nb0(4'd3),  .c1(1'b0),                  .e1(4'd0),  .nb1(4'd10), .c2(1'b0),                 .e2(4'd0),  .nb2(4'd10), .c3(1'b0),                 .e3(4'd0),  .nb3(4'd10), .nxt_vis(vis_next[10]), .nxt_pe(pe_next[43:40]), .nxt_pv(pv_next[43:40]), .nxt_lv(lv_next[32:30]));
  lakefillq_bfs_vertex_deg4 u_bf11 (.vis_self(vis[11]), .cur_pe(pe_vec[47:44]), .cur_pv(pv_vec[47:44]), .cur_lv(lv_vec[35:33]), .cur_lvl(cur_lvl), .c0(full_edge[9]&vis[3]),   .e0(4'd9),  .nb0(4'd3),  .c1(full_edge[14]&vis[7]),  .e1(4'd14), .nb1(4'd7),  .c2(1'b0),                 .e2(4'd0),  .nb2(4'd11), .c3(1'b0),                 .e3(4'd0),  .nb3(4'd11), .nxt_vis(vis_next[11]), .nxt_pe(pe_next[47:44]), .nxt_pv(pv_next[47:44]), .nxt_lv(lv_next[35:33]));
endmodule

module lakefillq_peel_level_step12 (
  input  wire [11:0] rem_syn,
  input  wire [24:0] corr,
  input  wire [47:0] pe_vec,
  input  wire [47:0] pv_vec,
  input  wire [35:0] lv_vec,
  input  wire [2:0]  cur_lvl,
  output wire [11:0] rem_syn_next,
  output wire [24:0] corr_next
);
  wire pa0  = (lv_vec[2:0]   == cur_lvl) & rem_syn[0];
  wire pa1  = (lv_vec[5:3]   == cur_lvl) & rem_syn[1];
  wire pa2  = (lv_vec[8:6]   == cur_lvl) & rem_syn[2];
  wire pa3  = (lv_vec[11:9]  == cur_lvl) & rem_syn[3];
  wire pa4  = (lv_vec[14:12] == cur_lvl) & rem_syn[4];
  wire pa5  = (lv_vec[17:15] == cur_lvl) & rem_syn[5];
  wire pa6  = (lv_vec[20:18] == cur_lvl) & rem_syn[6];
  wire pa7  = (lv_vec[23:21] == cur_lvl) & rem_syn[7];
  wire pa8  = (lv_vec[26:24] == cur_lvl) & rem_syn[8];
  wire pa9  = (lv_vec[29:27] == cur_lvl) & rem_syn[9];
  wire pa10 = (lv_vec[32:30] == cur_lvl) & rem_syn[10];
  wire pa11 = (lv_vec[35:33] == cur_lvl) & rem_syn[11];

  wire ef0  = (pa0  & (pe_vec[3:0]   == 4'd0))  | (pa8  & (pe_vec[35:32] == 4'd0));
  wire ef1  = (pa0  & (pe_vec[3:0]   == 4'd1))  | (pa2  & (pe_vec[11:8]  == 4'd1));
  wire ef2  = (pa1  & (pe_vec[7:4]   == 4'd2))  | (pa2  & (pe_vec[11:8]  == 4'd2));
  wire ef3  = (pa1  & (pe_vec[7:4]   == 4'd3))  | (pa3  & (pe_vec[15:12] == 4'd3));
  wire ef4  = (pa3  & (pe_vec[15:12] == 4'd4))  | (pa10 & (pe_vec[43:40] == 4'd4));
  wire ef5  = (pa4  & (pe_vec[19:16] == 4'd5))  | (pa8  & (pe_vec[35:32] == 4'd5));
  wire ef6  = (pa2  & (pe_vec[11:8]  == 4'd6))  | (pa4  & (pe_vec[19:16] == 4'd6));
  wire ef7  = (pa2  & (pe_vec[11:8]  == 4'd7))  | (pa5  & (pe_vec[23:20] == 4'd7));
  wire ef8  = (pa3  & (pe_vec[15:12] == 4'd8))  | (pa5  & (pe_vec[23:20] == 4'd8));
  wire ef9  = (pa3  & (pe_vec[15:12] == 4'd9))  | (pa11 & (pe_vec[47:44] == 4'd9));
  wire ef10 = (pa4  & (pe_vec[19:16] == 4'd10)) | (pa9  & (pe_vec[39:36] == 4'd10));
  wire ef11 = (pa4  & (pe_vec[19:16] == 4'd11)) | (pa6  & (pe_vec[27:24] == 4'd11));
  wire ef12 = (pa5  & (pe_vec[23:20] == 4'd12)) | (pa6  & (pe_vec[27:24] == 4'd12));
  wire ef13 = (pa5  & (pe_vec[23:20] == 4'd13)) | (pa7  & (pe_vec[31:28] == 4'd13));
  wire ef14 = (pa7  & (pe_vec[31:28] == 4'd14)) | (pa11 & (pe_vec[47:44] == 4'd14));

  wire ns0  = rem_syn[0]  ^ pa0  ^ (pa8 & (pv_vec[35:32] == 4'd0))  ^ (pa2  & (pv_vec[11:8]  == 4'd0));
  wire ns1  = rem_syn[1]  ^ pa1  ^ (pa2 & (pv_vec[11:8]  == 4'd1))  ^ (pa3  & (pv_vec[15:12] == 4'd1));
  wire ns2  = rem_syn[2]  ^ pa2  ^ (pa0 & (pv_vec[3:0]   == 4'd2))  ^ (pa1  & (pv_vec[7:4]   == 4'd2)) ^ (pa4 & (pv_vec[19:16] == 4'd2)) ^ (pa5  & (pv_vec[23:20] == 4'd2));
  wire ns3  = rem_syn[3]  ^ pa3  ^ (pa1 & (pv_vec[7:4]   == 4'd3))  ^ (pa10 & (pv_vec[43:40] == 4'd3)) ^ (pa5 & (pv_vec[23:20] == 4'd3)) ^ (pa11 & (pv_vec[47:44] == 4'd3));
  wire ns4  = rem_syn[4]  ^ pa4  ^ (pa8 & (pv_vec[35:32] == 4'd4))  ^ (pa2  & (pv_vec[11:8]  == 4'd4)) ^ (pa9 & (pv_vec[39:36] == 4'd4)) ^ (pa6  & (pv_vec[27:24] == 4'd4));
  wire ns5  = rem_syn[5]  ^ pa5  ^ (pa2 & (pv_vec[11:8]  == 4'd5))  ^ (pa3  & (pv_vec[15:12] == 4'd5)) ^ (pa6 & (pv_vec[27:24] == 4'd5)) ^ (pa7  & (pv_vec[31:28] == 4'd5));
  wire ns6  = rem_syn[6]  ^ pa6  ^ (pa4 & (pv_vec[19:16] == 4'd6))  ^ (pa5  & (pv_vec[23:20] == 4'd6));
  wire ns7  = rem_syn[7]  ^ pa7  ^ (pa5 & (pv_vec[23:20] == 4'd7))  ^ (pa11 & (pv_vec[47:44] == 4'd7));
  wire ns8  = rem_syn[8]  ^ pa8  ^ (pa0 & (pv_vec[3:0]   == 4'd8))  ^ (pa4  & (pv_vec[19:16] == 4'd8));
  wire ns9  = rem_syn[9]  ^ pa9  ^ (pa4 & (pv_vec[19:16] == 4'd9));
  wire ns10 = rem_syn[10] ^ pa10 ^ (pa3 & (pv_vec[15:12] == 4'd10));
  wire ns11 = rem_syn[11] ^ pa11 ^ (pa3 & (pv_vec[15:12] == 4'd11)) ^ (pa7  & (pv_vec[31:28] == 4'd11));

  assign rem_syn_next = {ns11, ns10, ns9, ns8, ns7, ns6, ns5, ns4, ns3, ns2, ns1, ns0};
  assign corr_next = {
    corr[24:20],
    (corr[19] ^ ef14), (corr[18] ^ ef13), (corr[17] ^ ef12), (corr[16] ^ ef11), (corr[15] ^ ef10),
    (corr[14] ^ ef9),  (corr[13] ^ ef8),  (corr[12] ^ ef7),  (corr[11] ^ ef6),  (corr[10] ^ ef5),
    (corr[9]  ^ ef4),  (corr[8]  ^ ef3),  (corr[7]  ^ ef2),  (corr[6]  ^ ef1),  (corr[5]  ^ ef0),
    corr[4:0]
  };
endmodule

module lakefillq_peel_boundary_egress12 (
  input  wire [11:0] rem_syn,
  input  wire [24:0] corr,
  output wire [11:0] residual_syn,
  output wire [24:0] corr_final,
  output wire        logical_flip
);
  wire q0  = corr[0]  ^ rem_syn[0];
  wire q1  = corr[1];
  wire q2  = corr[2]  ^ rem_syn[1];
  wire q3  = corr[3];
  wire q4  = corr[4]  ^ rem_syn[10];
  wire q20 = corr[20] ^ rem_syn[9];
  wire q21 = corr[21] ^ rem_syn[6];
  wire q22 = corr[22];
  wire q23 = corr[23] ^ rem_syn[7];
  wire q24 = corr[24];

  assign corr_final   = {q24, q23, q22, q21, q20, corr[19:5], q4, q3, q2, q1, q0};
  assign residual_syn = {rem_syn[11], 1'b0, 1'b0, rem_syn[8], 1'b0, 1'b0, rem_syn[5:2], 1'b0, 1'b0};
  assign logical_flip = (q0 ^ q1) ^ (q2 ^ q3) ^ q4;
endmodule

// =============================================================================
// Top-Level Cycle-Accurate 500 MHz (2.0 ns) LakefillQ 0-DSP Decoder Core
// =============================================================================
module lakefillq_0dsp_braun_uf_decoder (
  input  wire        clk,
  input  wire        rst,
  input  wire        in_valid,
  input  wire [23:0] cur_syn,
  input  wire [23:0] prev_syn,
  input  wire [1:0]  prev_pauli_frame,
  input  wire [1:0]  code_mode,
  input  wire [1:0]  autdec_shift_sel,
  output wire        out_valid,
  output wire [1:0]  pauli_frame_flip,
  output wire [24:0] corr_z_out,
  output wire [24:0] corr_x_out,
  output wire [4:0]  defect_weight_out,
  output wire        zero_bypass_out,
  output wire [5:0]  core_clocks_used
);
  localparam [3:0] OP_IDLE       = 4'd0;
  localparam [3:0] OP_UF_GROW    = 4'd1;
  localparam [3:0] OP_SV_HOOK    = 4'd2;
  localparam [3:0] OP_SV_PJUMP   = 4'd3;
  localparam [3:0] OP_BFS_SEED   = 4'd4;
  localparam [3:0] OP_BFS_STEP   = 4'd5;
  localparam [3:0] OP_PEEL_STEP  = 4'd6;
  localparam [3:0] OP_SEAM_ALIGN = 4'd7;
  localparam [3:0] OP_EGRESS     = 4'd8;

  localparam [47:0] ROOT_IDENTITY = {
    4'd11, 4'd10, 4'd9, 4'd8, 4'd7, 4'd6,
    4'd5,  4'd4,  4'd3, 4'd2, 4'd1, 4'd0
  };

  // Ingress XOR differential & BraunTree popcount fast bypass
  wire [23:0] ing_delta_syn;
  wire [4:0]  ing_defect_wt;
  wire        ing_zero_bypass;

  lakefillq_ingress_xor_bypass24 u_ingress (
    .cur_syn(cur_syn),
    .prev_syn(prev_syn),
    .autdec_shift_sel(autdec_shift_sel),
    .delta_syn(ing_delta_syn),
    .defect_weight(ing_defect_wt),
    .zero_defect_bypass(ing_zero_bypass)
  );

  // Synchronous pipe_reg state elements (500 MHz)
  reg [3:0]  fsm_pipe_reg;
  reg [1:0]  mode_pipe_reg;
  reg [1:0]  prev_pf_pipe_reg;
  reg [4:0]  wt_pipe_reg;
  reg [2:0]  grow_iter_pipe_reg;
  reg [1:0]  hook_cnt_pipe_reg;
  reg [2:0]  lvl_pipe_reg;
  reg [1:0]  seam_cnt_pipe_reg;
  reg [5:0]  clk_cnt_pipe_reg;

  reg [11:0] z_syn_pipe_reg,  x_syn_pipe_reg;
  reg [47:0] z_root_pipe_reg, x_root_pipe_reg;
  reg [11:0] z_odd_pipe_reg,  x_odd_pipe_reg;
  reg [11:0] z_bhit_pipe_reg, x_bhit_pipe_reg;
  reg [29:0] z_elen_pipe_reg, x_elen_pipe_reg;
  reg [11:0] z_blen_pipe_reg, x_blen_pipe_reg;
  reg [14:0] z_full_pipe_reg, x_full_pipe_reg;
  reg [11:0] z_vis_pipe_reg,  x_vis_pipe_reg;
  reg [47:0] z_pe_pipe_reg,   x_pe_pipe_reg;
  reg [47:0] z_pv_pipe_reg,   x_pv_pipe_reg;
  reg [35:0] z_lv_pipe_reg,   x_lv_pipe_reg;
  reg [11:0] z_rem_pipe_reg,  x_rem_pipe_reg;
  reg [24:0] z_corr_pipe_reg, x_corr_pipe_reg;

  reg        out_valid_pipe_reg;
  reg [1:0]  pauli_frame_pipe_reg;
  reg [24:0] corr_z_pipe_reg;
  reg [24:0] corr_x_pipe_reg;
  reg [4:0]  wt_out_pipe_reg;
  reg        zero_byp_pipe_reg;
  reg [5:0]  clks_used_pipe_reg;

  // Dual-basis Z & X combinational datapath instances
  wire [29:0] z_elen_nxt, x_elen_nxt;
  wire [11:0] z_blen_nxt, x_blen_nxt;
  wire [14:0] z_full_nxt, x_full_nxt;
  wire [11:0] z_act_mask, x_act_mask;

  lakefillq_uf_half_edge_grow12 u_z_grow (
    .root_vec(z_root_pipe_reg), .cluster_odd(z_odd_pipe_reg), .boundary_hit(z_bhit_pipe_reg),
    .elen_vec(z_elen_pipe_reg), .blen_vec(z_blen_pipe_reg),
    .elen_next(z_elen_nxt), .blen_next(z_blen_nxt), .full_edge(z_full_nxt), .active_mask(z_act_mask)
  );
  lakefillq_uf_half_edge_grow12 u_x_grow (
    .root_vec(x_root_pipe_reg), .cluster_odd(x_odd_pipe_reg), .boundary_hit(x_bhit_pipe_reg),
    .elen_vec(x_elen_pipe_reg), .blen_vec(x_blen_pipe_reg),
    .elen_next(x_elen_nxt), .blen_next(x_blen_nxt), .full_edge(x_full_nxt), .active_mask(x_act_mask)
  );

  wire [47:0] z_root_hk, x_root_hk;
  lakefillq_sv_hook_step12 u_z_hook (.root_vec(z_root_pipe_reg), .full_edge(z_full_pipe_reg), .root_next(z_root_hk));
  lakefillq_sv_hook_step12 u_x_hook (.root_vec(x_root_pipe_reg), .full_edge(x_full_pipe_reg), .root_next(x_root_hk));

  wire [47:0] z_root_jp, x_root_jp;
  wire [11:0] z_odd_jp,  x_odd_jp;
  wire [11:0] z_bhit_jp, x_bhit_jp;
  lakefillq_sv_pointer_jump_parity12 u_z_pjump (
    .root_vec(z_root_pipe_reg), .syn12(z_syn_pipe_reg), .blen_vec(z_blen_pipe_reg),
    .root_jump(z_root_jp), .cluster_odd(z_odd_jp), .boundary_hit(z_bhit_jp)
  );
  lakefillq_sv_pointer_jump_parity12 u_x_pjump (
    .root_vec(x_root_pipe_reg), .syn12(x_syn_pipe_reg), .blen_vec(x_blen_pipe_reg),
    .root_jump(x_root_jp), .cluster_odd(x_odd_jp), .boundary_hit(x_bhit_jp)
  );

  wire [11:0] z_vis_seed, x_vis_seed;
  lakefillq_bfs_seed_init12 u_z_seed (.root_vec(z_root_pipe_reg), .blen_vec(z_blen_pipe_reg), .vis_init(z_vis_seed));
  lakefillq_bfs_seed_init12 u_x_seed (.root_vec(x_root_pipe_reg), .blen_vec(x_blen_pipe_reg), .vis_init(x_vis_seed));

  wire [11:0] z_vis_nxt, x_vis_nxt;
  wire [47:0] z_pe_nxt,  x_pe_nxt;
  wire [47:0] z_pv_nxt,  x_pv_nxt;
  wire [35:0] z_lv_nxt,  x_lv_nxt;
  lakefillq_bfs_forest_step12 u_z_bfs (
    .vis(z_vis_pipe_reg), .pe_vec(z_pe_pipe_reg), .pv_vec(z_pv_pipe_reg), .lv_vec(z_lv_pipe_reg),
    .full_edge(z_full_pipe_reg), .cur_lvl(lvl_pipe_reg),
    .vis_next(z_vis_nxt), .pe_next(z_pe_nxt), .pv_next(z_pv_nxt), .lv_next(z_lv_nxt)
  );
  lakefillq_bfs_forest_step12 u_x_bfs (
    .vis(x_vis_pipe_reg), .pe_vec(x_pe_pipe_reg), .pv_vec(x_pv_pipe_reg), .lv_vec(x_lv_pipe_reg),
    .full_edge(x_full_pipe_reg), .cur_lvl(lvl_pipe_reg),
    .vis_next(x_vis_nxt), .pe_next(x_pe_nxt), .pv_next(x_pv_nxt), .lv_next(x_lv_nxt)
  );

  wire [11:0] z_rem_nxt,  x_rem_nxt;
  wire [24:0] z_corr_nxt, x_corr_nxt;
  lakefillq_peel_level_step12 u_z_peel (
    .rem_syn(z_rem_pipe_reg), .corr(z_corr_pipe_reg), .pe_vec(z_pe_pipe_reg),
    .pv_vec(z_pv_pipe_reg), .lv_vec(z_lv_pipe_reg), .cur_lvl(lvl_pipe_reg),
    .rem_syn_next(z_rem_nxt), .corr_next(z_corr_nxt)
  );
  lakefillq_peel_level_step12 u_x_peel (
    .rem_syn(x_rem_pipe_reg), .corr(x_corr_pipe_reg), .pe_vec(x_pe_pipe_reg),
    .pv_vec(x_pv_pipe_reg), .lv_vec(x_lv_pipe_reg), .cur_lvl(lvl_pipe_reg),
    .rem_syn_next(x_rem_nxt), .corr_next(x_corr_nxt)
  );

  wire [11:0] z_res_syn,  x_res_syn;
  wire [24:0] z_corr_fin, x_corr_fin;
  wire        z_log_flip, x_log_flip;
  lakefillq_peel_boundary_egress12 u_z_egress (
    .rem_syn(z_rem_pipe_reg), .corr(z_corr_pipe_reg),
    .residual_syn(z_res_syn), .corr_final(z_corr_fin), .logical_flip(z_log_flip)
  );
  lakefillq_peel_boundary_egress12 u_x_egress (
    .rem_syn(x_rem_pipe_reg), .corr(x_corr_pipe_reg),
    .residual_syn(x_res_syn), .corr_final(x_corr_fin), .logical_flip(x_log_flip)
  );

  wire [2:0] max_bfs_lvl = (mode_pipe_reg == 2'd0) ? 3'd3 : 3'd7;
  wire [2:0] max_grow_it = (mode_pipe_reg == 2'd0) ? 3'd2 : 3'd4;
  wire       any_active  = ((z_act_mask | x_act_mask) != 12'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      fsm_pipe_reg         <= OP_IDLE;
      mode_pipe_reg        <= 2'd0;
      prev_pf_pipe_reg     <= 2'd0;
      wt_pipe_reg          <= 5'd0;
      grow_iter_pipe_reg   <= 3'd0;
      hook_cnt_pipe_reg    <= 2'd0;
      lvl_pipe_reg         <= 3'd0;
      seam_cnt_pipe_reg    <= 2'd0;
      clk_cnt_pipe_reg     <= 6'd0;
      z_syn_pipe_reg       <= 12'd0;
      x_syn_pipe_reg       <= 12'd0;
      z_root_pipe_reg      <= ROOT_IDENTITY;
      x_root_pipe_reg      <= ROOT_IDENTITY;
      z_odd_pipe_reg       <= 12'd0;
      x_odd_pipe_reg       <= 12'd0;
      z_bhit_pipe_reg      <= 12'd0;
      x_bhit_pipe_reg      <= 12'd0;
      z_elen_pipe_reg      <= 30'd0;
      x_elen_pipe_reg      <= 30'd0;
      z_blen_pipe_reg      <= 12'd0;
      x_blen_pipe_reg      <= 12'd0;
      z_full_pipe_reg      <= 15'd0;
      x_full_pipe_reg      <= 15'd0;
      z_vis_pipe_reg       <= 12'd0;
      x_vis_pipe_reg       <= 12'd0;
      z_pe_pipe_reg        <= 48'd0;
      x_pe_pipe_reg        <= 48'd0;
      z_pv_pipe_reg        <= ROOT_IDENTITY;
      x_pv_pipe_reg        <= ROOT_IDENTITY;
      z_lv_pipe_reg        <= 36'd0;
      x_lv_pipe_reg        <= 36'd0;
      z_rem_pipe_reg       <= 12'd0;
      x_rem_pipe_reg       <= 12'd0;
      z_corr_pipe_reg      <= 25'd0;
      x_corr_pipe_reg      <= 25'd0;
      out_valid_pipe_reg   <= 1'b0;
      pauli_frame_pipe_reg <= 2'd0;
      corr_z_pipe_reg      <= 25'd0;
      corr_x_pipe_reg      <= 25'd0;
      wt_out_pipe_reg      <= 5'd0;
      zero_byp_pipe_reg    <= 1'b0;
      clks_used_pipe_reg   <= 6'd0;
    end else begin
      out_valid_pipe_reg <= 1'b0;
      if (fsm_pipe_reg == OP_IDLE) begin
        if (in_valid) begin
          if (ing_zero_bypass) begin
            // 1-clock (2.0 ns) zero-defect fast bypass
            out_valid_pipe_reg   <= 1'b1;
            pauli_frame_pipe_reg <= prev_pauli_frame;
            corr_z_pipe_reg      <= 25'd0;
            corr_x_pipe_reg      <= 25'd0;
            wt_out_pipe_reg      <= 5'd0;
            zero_byp_pipe_reg    <= 1'b1;
            clks_used_pipe_reg   <= 6'd1;
          end else begin
            mode_pipe_reg      <= code_mode;
            prev_pf_pipe_reg   <= prev_pauli_frame;
            wt_pipe_reg        <= ing_defect_wt;
            grow_iter_pipe_reg <= 3'd0;
            clk_cnt_pipe_reg   <= 6'd1;
            z_syn_pipe_reg     <= ing_delta_syn[11:0];
            x_syn_pipe_reg     <= ing_delta_syn[23:12];
            z_root_pipe_reg    <= ROOT_IDENTITY;
            x_root_pipe_reg    <= ROOT_IDENTITY;
            z_odd_pipe_reg     <= ing_delta_syn[11:0];
            x_odd_pipe_reg     <= ing_delta_syn[23:12];
            z_bhit_pipe_reg    <= 12'd0;
            x_bhit_pipe_reg    <= 12'd0;
            z_elen_pipe_reg    <= 30'd0;
            x_elen_pipe_reg    <= 30'd0;
            z_blen_pipe_reg    <= 12'd0;
            x_blen_pipe_reg    <= 12'd0;
            z_full_pipe_reg    <= 15'd0;
            x_full_pipe_reg    <= 15'd0;
            fsm_pipe_reg       <= OP_UF_GROW;
          end
        end
      end else if (fsm_pipe_reg == OP_UF_GROW) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        if ((grow_iter_pipe_reg >= max_grow_it) | (~any_active)) begin
          fsm_pipe_reg <= OP_BFS_SEED;
        end else begin
          z_elen_pipe_reg   <= z_elen_nxt;
          x_elen_pipe_reg   <= x_elen_nxt;
          z_blen_pipe_reg   <= z_blen_nxt;
          x_blen_pipe_reg   <= x_blen_nxt;
          z_full_pipe_reg   <= z_full_nxt;
          x_full_pipe_reg   <= x_full_nxt;
          hook_cnt_pipe_reg <= 2'd0;
          fsm_pipe_reg      <= OP_SV_HOOK;
        end
      end else if (fsm_pipe_reg == OP_SV_HOOK) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        z_root_pipe_reg  <= z_root_hk;
        x_root_pipe_reg  <= x_root_hk;
        if (hook_cnt_pipe_reg == 2'd2) begin
          fsm_pipe_reg <= OP_SV_PJUMP;
        end else begin
          hook_cnt_pipe_reg <= hook_cnt_pipe_reg + 2'd1;
        end
      end else if (fsm_pipe_reg == OP_SV_PJUMP) begin
        clk_cnt_pipe_reg   <= clk_cnt_pipe_reg + 6'd1;
        z_root_pipe_reg    <= z_root_jp;
        x_root_pipe_reg    <= x_root_jp;
        z_odd_pipe_reg     <= z_odd_jp;
        x_odd_pipe_reg     <= x_odd_jp;
        z_bhit_pipe_reg    <= z_bhit_jp;
        x_bhit_pipe_reg    <= x_bhit_jp;
        grow_iter_pipe_reg <= grow_iter_pipe_reg + 3'd1;
        if ((grow_iter_pipe_reg + 3'd1) >= max_grow_it) begin
          fsm_pipe_reg <= OP_BFS_SEED;
        end else begin
          fsm_pipe_reg <= OP_UF_GROW;
        end
      end else if (fsm_pipe_reg == OP_BFS_SEED) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        z_vis_pipe_reg   <= z_vis_seed;
        x_vis_pipe_reg   <= x_vis_seed;
        z_pe_pipe_reg    <= 48'd0;
        x_pe_pipe_reg    <= 48'd0;
        z_pv_pipe_reg    <= ROOT_IDENTITY;
        x_pv_pipe_reg    <= ROOT_IDENTITY;
        z_lv_pipe_reg    <= 36'd0;
        x_lv_pipe_reg    <= 36'd0;
        lvl_pipe_reg     <= 3'd1;
        fsm_pipe_reg     <= OP_BFS_STEP;
      end else if (fsm_pipe_reg == OP_BFS_STEP) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        z_vis_pipe_reg   <= z_vis_nxt;
        x_vis_pipe_reg   <= x_vis_nxt;
        z_pe_pipe_reg    <= z_pe_nxt;
        x_pe_pipe_reg    <= x_pe_nxt;
        z_pv_pipe_reg    <= z_pv_nxt;
        x_pv_pipe_reg    <= x_pv_nxt;
        z_lv_pipe_reg    <= z_lv_nxt;
        x_lv_pipe_reg    <= x_lv_nxt;
        if (lvl_pipe_reg == max_bfs_lvl) begin
          z_rem_pipe_reg  <= z_syn_pipe_reg;
          x_rem_pipe_reg  <= x_syn_pipe_reg;
          z_corr_pipe_reg <= 25'd0;
          x_corr_pipe_reg <= 25'd0;
          lvl_pipe_reg    <= max_bfs_lvl;
          fsm_pipe_reg    <= OP_PEEL_STEP;
        end else begin
          lvl_pipe_reg <= lvl_pipe_reg + 3'd1;
        end
      end else if (fsm_pipe_reg == OP_PEEL_STEP) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        z_rem_pipe_reg   <= z_rem_nxt;
        x_rem_pipe_reg   <= x_rem_nxt;
        z_corr_pipe_reg  <= z_corr_nxt;
        x_corr_pipe_reg  <= x_corr_nxt;
        if (lvl_pipe_reg == 3'd1) begin
          if (mode_pipe_reg == 2'd2) begin
            seam_cnt_pipe_reg <= 2'd2;
            fsm_pipe_reg      <= OP_SEAM_ALIGN;
          end else if (mode_pipe_reg == 2'd3) begin
            seam_cnt_pipe_reg <= 2'd0;
            fsm_pipe_reg      <= OP_SEAM_ALIGN;
          end else begin
            fsm_pipe_reg <= OP_EGRESS;
          end
        end else begin
          lvl_pipe_reg <= lvl_pipe_reg - 3'd1;
        end
      end else if (fsm_pipe_reg == OP_SEAM_ALIGN) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        if (seam_cnt_pipe_reg == 2'd0) begin
          fsm_pipe_reg <= OP_EGRESS;
        end else begin
          seam_cnt_pipe_reg <= seam_cnt_pipe_reg - 2'd1;
        end
      end else begin
        out_valid_pipe_reg   <= 1'b1;
        pauli_frame_pipe_reg <= prev_pf_pipe_reg ^ {x_log_flip, z_log_flip};
        corr_z_pipe_reg      <= z_corr_fin;
        corr_x_pipe_reg      <= x_corr_fin;
        wt_out_pipe_reg      <= wt_pipe_reg;
        zero_byp_pipe_reg    <= 1'b0;
        clks_used_pipe_reg   <= clk_cnt_pipe_reg + 6'd1;
        fsm_pipe_reg         <= OP_IDLE;
      end
    end
  end

  assign out_valid         = out_valid_pipe_reg;
  assign pauli_frame_flip  = pauli_frame_pipe_reg;
  assign corr_z_out        = corr_z_pipe_reg;
  assign corr_x_out        = corr_x_pipe_reg;
  assign defect_weight_out = wt_out_pipe_reg;
  assign zero_bypass_out   = zero_byp_pipe_reg;
  assign core_clocks_used  = clks_used_pipe_reg;
endmodule

// =============================================================================
// 8. Optimization 5: Zero-DSP Hierarchical OR-Tree Popcount + Direct XOR-Address
//    Sparse-Syndrome Fast-Path (1-Cycle w=0, 2-Cycle Isolated w<=2 Fast-Path)
// =============================================================================
module lakefillq_ortree_xor_sparse_fastpath12 (
  input  wire [11:0] syn12,
  input  wire        is_mode0,
  output wire [3:0]  wt12,
  output wire        is_zero,
  output wire        is_adj_wt2,
  output wire        fast_hit,
  output wire [3:0]  xor_edge_sig,
  output wire [24:0] corr_fast,
  output wire        logical_flip_fast
);
  // 1. 4-Level Hierarchical OR-Tree Zero-Defect Detector (w = 0 in 1 clock cycle)
  wire or_l1_0 = syn12[0]  | syn12[1];
  wire or_l1_1 = syn12[2]  | syn12[3];
  wire or_l1_2 = syn12[4]  | syn12[5];
  wire or_l1_3 = syn12[6]  | syn12[7];
  wire or_l1_4 = syn12[8]  | syn12[9];
  wire or_l1_5 = syn12[10] | syn12[11];

  wire or_l2_0 = or_l1_0 | or_l1_1;
  wire or_l2_1 = or_l1_2 | or_l1_3;
  wire or_l2_2 = or_l1_4 | or_l1_5;

  wire or_l3_0    = or_l2_0 | or_l2_1;
  wire any_defect = or_l3_0 | or_l2_2;
  assign is_zero  = ~any_defect;

  // 2. Balanced 0-DSP Braun-Tree 12-Bit Popcount Reducer
  wire [1:0] p1_0 = {1'b0, syn12[0]}  + {1'b0, syn12[1]};
  wire [1:0] p1_1 = {1'b0, syn12[2]}  + {1'b0, syn12[3]};
  wire [1:0] p1_2 = {1'b0, syn12[4]}  + {1'b0, syn12[5]};
  wire [1:0] p1_3 = {1'b0, syn12[6]}  + {1'b0, syn12[7]};
  wire [1:0] p1_4 = {1'b0, syn12[8]}  + {1'b0, syn12[9]};
  wire [1:0] p1_5 = {1'b0, syn12[10]} + {1'b0, syn12[11]};

  wire [2:0] p2_0 = {1'b0, p1_0} + {1'b0, p1_1};
  wire [2:0] p2_1 = {1'b0, p1_2} + {1'b0, p1_3};
  wire [2:0] p2_2 = {1'b0, p1_4} + {1'b0, p1_5};

  wire [3:0] p3_0 = {1'b0, p2_0} + {1'b0, p2_1};
  assign wt12     = p3_0 + {1'b0, p2_2};

  // 3. Dual Priority Encoders (idx_lo, idx_hi) & Direct XOR-Address Signature (idx_lo ^ idx_hi)
  wire [3:0] idx_lo;
  lakefillq_ffs12_u4 u_ffs_lo (.m(syn12), .min_idx(idx_lo));

  wire [11:0] rev_syn12 = {
    syn12[0], syn12[1], syn12[2], syn12[3], syn12[4], syn12[5],
    syn12[6], syn12[7], syn12[8], syn12[9], syn12[10], syn12[11]
  };
  wire [3:0] rev_idx;
  lakefillq_ffs12_u4 u_ffs_hi (.m(rev_syn12), .min_idx(rev_idx));
  wire [3:0] idx_hi = 4'd11 - rev_idx;
  assign xor_edge_sig = idx_lo ^ idx_hi;

  // 4. Direct Bitwise XOR-Address Comparison for 15 Interior Stabilizer Edges e0..e14
  wire adj_e0  = ((syn12 ^ 12'd257)  == 12'd0);
  wire adj_e1  = ((syn12 ^ 12'd5)    == 12'd0);
  wire adj_e2  = ((syn12 ^ 12'd6)    == 12'd0);
  wire adj_e3  = ((syn12 ^ 12'd10)   == 12'd0);
  wire adj_e4  = ((syn12 ^ 12'd1032) == 12'd0);
  wire adj_e5  = ((syn12 ^ 12'd272)  == 12'd0);
  wire adj_e6  = ((syn12 ^ 12'd20)   == 12'd0);
  wire adj_e7  = ((syn12 ^ 12'd36)   == 12'd0);
  wire adj_e8  = ((syn12 ^ 12'd40)   == 12'd0);
  wire adj_e9  = ((syn12 ^ 12'd2056) == 12'd0);
  wire adj_e10 = ((syn12 ^ 12'd528)  == 12'd0);
  wire adj_e11 = ((syn12 ^ 12'd80)   == 12'd0);
  wire adj_e12 = ((syn12 ^ 12'd96)   == 12'd0);
  wire adj_e13 = ((syn12 ^ 12'd160)  == 12'd0);
  wire adj_e14 = ((syn12 ^ 12'd2176) == 12'd0);

  // 5. Direct XOR-Address Comparison for 12 Weight-1 Single-Defect Syndromes s1_0..s1_11
  wire s1_0  = ((syn12 ^ 12'd1)    == 12'd0);
  wire s1_1  = ((syn12 ^ 12'd2)    == 12'd0);
  wire s1_2  = ((syn12 ^ 12'd4)    == 12'd0);
  wire s1_3  = ((syn12 ^ 12'd8)    == 12'd0);
  wire s1_4  = ((syn12 ^ 12'd16)   == 12'd0);
  wire s1_5  = ((syn12 ^ 12'd32)   == 12'd0);
  wire s1_6  = ((syn12 ^ 12'd64)   == 12'd0);
  wire s1_7  = ((syn12 ^ 12'd128)  == 12'd0);
  wire s1_8  = ((syn12 ^ 12'd256)  == 12'd0);
  wire s1_9  = ((syn12 ^ 12'd512)  == 12'd0);
  wire s1_10 = ((syn12 ^ 12'd1024) == 12'd0);
  wire s1_11 = ((syn12 ^ 12'd2048) == 12'd0);

  wire adj_g0 = (adj_e0  | adj_e1)  | (adj_e2  | adj_e3);
  wire adj_g1 = (adj_e4  | adj_e5)  | (adj_e6  | adj_e7);
  wire adj_g2 = (adj_e8  | adj_e9)  | (adj_e10 | adj_e11);
  wire adj_g3 = (adj_e12 | adj_e13) | adj_e14;
  assign is_adj_wt2 = (adj_g0 | adj_g1) | (adj_g2 | adj_g3);

  wire is_wt1 = (wt12 == 4'd1);
  assign fast_hit = is_zero | is_wt1 | is_adj_wt2;

  // 6. Direct 25-Bit Pauli Edge Correction & Logical Flip Synthesis (0-DSP)
  wire c0  = s1_0 | s1_2 | s1_8;
  wire c1  = 1'b0;
  wire c2  = s1_1 | s1_3;
  wire c3  = 1'b0;
  wire c4  = s1_10;
  wire c5  = adj_e0  | s1_8;
  wire c6  = adj_e1  | s1_2;
  wire c7  = adj_e2;
  wire c8  = adj_e3  | s1_3;
  wire c9  = adj_e4;
  wire c10 = adj_e5;
  wire c11 = adj_e6  | (s1_4  & is_mode0);
  wire c12 = adj_e7  | (s1_5  & is_mode0);
  wire c13 = adj_e8;
  wire c14 = adj_e9  | (s1_11 & is_mode0);
  wire c15 = adj_e10;
  wire c16 = adj_e11 | (s1_4  & (~is_mode0));
  wire c17 = adj_e12 | (s1_5  & (~is_mode0));
  wire c18 = adj_e13;
  wire c19 = adj_e14 | (s1_11 & (~is_mode0));
  wire c20 = s1_9;
  wire c21 = s1_6 | (s1_4 & (~is_mode0)) | (s1_5 & (~is_mode0));
  wire c22 = 1'b0;
  wire c23 = s1_7 | (s1_11 & (~is_mode0));
  wire c24 = 1'b0;

  assign corr_fast = {
    c24, c23, c22, c21, c20,
    c19, c18, c17, c16, c15, c14, c13, c12, c11, c10, c9, c8, c7, c6, c5,
    c4,  c3,  c2,  c1,  c0
  };
  assign logical_flip_fast = (c0 ^ c1) ^ (c2 ^ c3) ^ c4;
endmodule

module lakefillq_ortree_xor_sparse_fastpath24 (
  input  wire [23:0] cur_syn,
  input  wire [23:0] prev_syn,
  input  wire [1:0]  prev_pauli_frame,
  input  wire [1:0]  code_mode,
  input  wire [1:0]  autdec_shift_sel,
  output wire [23:0] delta_syn,
  output wire [4:0]  defect_weight,
  output wire        zero_cycle1_bypass,
  output wire        sparse_cycle2_fastpath,
  output wire [24:0] corr_z_fast,
  output wire [24:0] corr_x_fast,
  output wire [1:0]  pauli_frame_fast
);
  wire ing_zero_byp;
  lakefillq_ingress_xor_bypass24 u_ing24 (
    .cur_syn(cur_syn),
    .prev_syn(prev_syn),
    .autdec_shift_sel(autdec_shift_sel),
    .delta_syn(delta_syn),
    .defect_weight(defect_weight),
    .zero_defect_bypass(ing_zero_byp)
  );

  wire is_mode0 = (code_mode == 2'd0);

  wire [3:0] z_wt12, x_wt12;
  wire       z_zero, x_zero;
  wire       z_adj2, x_adj2;
  wire       z_hit,  x_hit;
  wire [3:0] z_xsig, x_xsig;
  wire       z_lflip, x_lflip;

  lakefillq_ortree_xor_sparse_fastpath12 u_fp_z (
    .syn12(delta_syn[11:0]),
    .is_mode0(is_mode0),
    .wt12(z_wt12),
    .is_zero(z_zero),
    .is_adj_wt2(z_adj2),
    .fast_hit(z_hit),
    .xor_edge_sig(z_xsig),
    .corr_fast(corr_z_fast),
    .logical_flip_fast(z_lflip)
  );

  lakefillq_ortree_xor_sparse_fastpath12 u_fp_x (
    .syn12(delta_syn[23:12]),
    .is_mode0(is_mode0),
    .wt12(x_wt12),
    .is_zero(x_zero),
    .is_adj_wt2(x_adj2),
    .fast_hit(x_hit),
    .xor_edge_sig(x_xsig),
    .corr_fast(corr_x_fast),
    .logical_flip_fast(x_lflip)
  );

  assign zero_cycle1_bypass     = z_zero & x_zero;
  assign sparse_cycle2_fastpath = (~zero_cycle1_bypass) & z_hit & x_hit & (defect_weight <= 5'd2);
  assign pauli_frame_fast       = prev_pauli_frame ^ {x_lflip, z_lflip};
endmodule

module lakefillq_0dsp_hybrid_fastpath_uf_decoder (
  input  wire        clk,
  input  wire        rst,
  input  wire        in_valid,
  input  wire [23:0] cur_syn,
  input  wire [23:0] prev_syn,
  input  wire [1:0]  prev_pauli_frame,
  input  wire [1:0]  code_mode,
  input  wire [1:0]  autdec_shift_sel,
  output wire        out_valid,
  output wire [1:0]  pauli_frame_flip,
  output wire [24:0] corr_z_out,
  output wire [24:0] corr_x_out,
  output wire [4:0]  defect_weight_out,
  output wire        zero_bypass_out,
  output wire        sparse_wt2_bypass_out,
  output wire [5:0]  core_clocks_used
);
  localparam [3:0] OP_IDLE       = 4'd0;
  localparam [3:0] OP_UF_GROW    = 4'd1;
  localparam [3:0] OP_SV_HOOK    = 4'd2;
  localparam [3:0] OP_SV_PJUMP   = 4'd3;
  localparam [3:0] OP_BFS_SEED   = 4'd4;
  localparam [3:0] OP_BFS_STEP   = 4'd5;
  localparam [3:0] OP_PEEL_STEP  = 4'd6;
  localparam [3:0] OP_SEAM_ALIGN = 4'd7;
  localparam [3:0] OP_EGRESS     = 4'd8;
  localparam [3:0] OP_FAST_WT2   = 4'd9;

  localparam [47:0] ROOT_IDENTITY = {
    4'd11, 4'd10, 4'd9, 4'd8, 4'd7, 4'd6,
    4'd5,  4'd4,  4'd3, 4'd2, 4'd1, 4'd0
  };

  wire [23:0] fp_delta_syn;
  wire [4:0]  fp_defect_wt;
  wire        fp_zero_byp;
  wire        fp_sparse_wt2;
  wire [24:0] fp_corr_z;
  wire [24:0] fp_corr_x;
  wire [1:0]  fp_pf_fast;

  lakefillq_ortree_xor_sparse_fastpath24 u_fastpath24 (
    .cur_syn(cur_syn),
    .prev_syn(prev_syn),
    .prev_pauli_frame(prev_pauli_frame),
    .code_mode(code_mode),
    .autdec_shift_sel(autdec_shift_sel),
    .delta_syn(fp_delta_syn),
    .defect_weight(fp_defect_wt),
    .zero_cycle1_bypass(fp_zero_byp),
    .sparse_cycle2_fastpath(fp_sparse_wt2),
    .corr_z_fast(fp_corr_z),
    .corr_x_fast(fp_corr_x),
    .pauli_frame_fast(fp_pf_fast)
  );

  reg [3:0]  fsm_pipe_reg;
  reg [1:0]  mode_pipe_reg;
  reg [1:0]  prev_pf_pipe_reg;
  reg [4:0]  wt_pipe_reg;
  reg [2:0]  grow_iter_pipe_reg;
  reg [1:0]  hook_cnt_pipe_reg;
  reg [2:0]  lvl_pipe_reg;
  reg [1:0]  seam_cnt_pipe_reg;
  reg [5:0]  clk_cnt_pipe_reg;

  reg [11:0] z_syn_pipe_reg,  x_syn_pipe_reg;
  reg [47:0] z_root_pipe_reg, x_root_pipe_reg;
  reg [11:0] z_odd_pipe_reg,  x_odd_pipe_reg;
  reg [11:0] z_bhit_pipe_reg, x_bhit_pipe_reg;
  reg [29:0] z_elen_pipe_reg, x_elen_pipe_reg;
  reg [11:0] z_blen_pipe_reg, x_blen_pipe_reg;
  reg [14:0] z_full_pipe_reg, x_full_pipe_reg;
  reg [11:0] z_vis_pipe_reg,  x_vis_pipe_reg;
  reg [47:0] z_pe_pipe_reg,   x_pe_pipe_reg;
  reg [47:0] z_pv_pipe_reg,   x_pv_pipe_reg;
  reg [35:0] z_lv_pipe_reg,   x_lv_pipe_reg;
  reg [11:0] z_rem_pipe_reg,  x_rem_pipe_reg;
  reg [24:0] z_corr_pipe_reg, x_corr_pipe_reg;

  reg [24:0] fast_cz_pipe_reg, fast_cx_pipe_reg;
  reg [1:0]  fast_pf_pipe_reg;

  reg        out_valid_pipe_reg;
  reg [1:0]  pauli_frame_pipe_reg;
  reg [24:0] corr_z_pipe_reg;
  reg [24:0] corr_x_pipe_reg;
  reg [4:0]  wt_out_pipe_reg;
  reg        zero_byp_pipe_reg;
  reg        sparse_byp_pipe_reg;
  reg [5:0]  clks_used_pipe_reg;

  wire [29:0] z_elen_nxt, x_elen_nxt;
  wire [11:0] z_blen_nxt, x_blen_nxt;
  wire [14:0] z_full_nxt, x_full_nxt;
  wire [11:0] z_act_mask, x_act_mask;

  lakefillq_uf_half_edge_grow12 u_hz_grow (
    .root_vec(z_root_pipe_reg), .cluster_odd(z_odd_pipe_reg), .boundary_hit(z_bhit_pipe_reg),
    .elen_vec(z_elen_pipe_reg), .blen_vec(z_blen_pipe_reg),
    .elen_next(z_elen_nxt), .blen_next(z_blen_nxt), .full_edge(z_full_nxt), .active_mask(z_act_mask)
  );
  lakefillq_uf_half_edge_grow12 u_hx_grow (
    .root_vec(x_root_pipe_reg), .cluster_odd(x_odd_pipe_reg), .boundary_hit(x_bhit_pipe_reg),
    .elen_vec(x_elen_pipe_reg), .blen_vec(x_blen_pipe_reg),
    .elen_next(x_elen_nxt), .blen_next(x_blen_nxt), .full_edge(x_full_nxt), .active_mask(x_act_mask)
  );

  wire [47:0] z_root_hk, x_root_hk;
  lakefillq_sv_hook_step12 u_hz_hook (.root_vec(z_root_pipe_reg), .full_edge(z_full_pipe_reg), .root_next(z_root_hk));
  lakefillq_sv_hook_step12 u_hx_hook (.root_vec(x_root_pipe_reg), .full_edge(x_full_pipe_reg), .root_next(x_root_hk));

  wire [47:0] z_root_jp, x_root_jp;
  wire [11:0] z_odd_jp,  x_odd_jp;
  wire [11:0] z_bhit_jp, x_bhit_jp;
  lakefillq_sv_pointer_jump_parity12 u_hz_pjump (
    .root_vec(z_root_pipe_reg), .syn12(z_syn_pipe_reg), .blen_vec(z_blen_pipe_reg),
    .root_jump(z_root_jp), .cluster_odd(z_odd_jp), .boundary_hit(z_bhit_jp)
  );
  lakefillq_sv_pointer_jump_parity12 u_hx_pjump (
    .root_vec(x_root_pipe_reg), .syn12(x_syn_pipe_reg), .blen_vec(x_blen_pipe_reg),
    .root_jump(x_root_jp), .cluster_odd(x_odd_jp), .boundary_hit(x_bhit_jp)
  );

  wire [11:0] z_vis_seed, x_vis_seed;
  lakefillq_bfs_seed_init12 u_hz_seed (.root_vec(z_root_pipe_reg), .blen_vec(z_blen_pipe_reg), .vis_init(z_vis_seed));
  lakefillq_bfs_seed_init12 u_hx_seed (.root_vec(x_root_pipe_reg), .blen_vec(x_blen_pipe_reg), .vis_init(x_vis_seed));

  wire [11:0] z_vis_nxt, x_vis_nxt;
  wire [47:0] z_pe_nxt,  x_pe_nxt;
  wire [47:0] z_pv_nxt,  x_pv_nxt;
  wire [35:0] z_lv_nxt,  x_lv_nxt;
  lakefillq_bfs_forest_step12 u_hz_bfs (
    .vis(z_vis_pipe_reg), .pe_vec(z_pe_pipe_reg), .pv_vec(z_pv_pipe_reg), .lv_vec(z_lv_pipe_reg),
    .full_edge(z_full_pipe_reg), .cur_lvl(lvl_pipe_reg),
    .vis_next(z_vis_nxt), .pe_next(z_pe_nxt), .pv_next(z_pv_nxt), .lv_next(z_lv_nxt)
  );
  lakefillq_bfs_forest_step12 u_hx_bfs (
    .vis(x_vis_pipe_reg), .pe_vec(x_pe_pipe_reg), .pv_vec(x_pv_pipe_reg), .lv_vec(x_lv_pipe_reg),
    .full_edge(x_full_pipe_reg), .cur_lvl(lvl_pipe_reg),
    .vis_next(x_vis_nxt), .pe_next(x_pe_nxt), .pv_next(x_pv_nxt), .lv_next(x_lv_nxt)
  );

  wire [11:0] z_rem_nxt,  x_rem_nxt;
  wire [24:0] z_corr_nxt, x_corr_nxt;
  lakefillq_peel_level_step12 u_hz_peel (
    .rem_syn(z_rem_pipe_reg), .corr(z_corr_pipe_reg), .pe_vec(z_pe_pipe_reg),
    .pv_vec(z_pv_pipe_reg), .lv_vec(z_lv_pipe_reg), .cur_lvl(lvl_pipe_reg),
    .rem_syn_next(z_rem_nxt), .corr_next(z_corr_nxt)
  );
  lakefillq_peel_level_step12 u_hx_peel (
    .rem_syn(x_rem_pipe_reg), .corr(x_corr_pipe_reg), .pe_vec(x_pe_pipe_reg),
    .pv_vec(x_pv_pipe_reg), .lv_vec(x_lv_pipe_reg), .cur_lvl(lvl_pipe_reg),
    .rem_syn_next(x_rem_nxt), .corr_next(x_corr_nxt)
  );

  wire [11:0] z_res_syn,  x_res_syn;
  wire [24:0] z_corr_fin, x_corr_fin;
  wire        z_log_flip, x_log_flip;
  lakefillq_peel_boundary_egress12 u_hz_egress (
    .rem_syn(z_rem_pipe_reg), .corr(z_corr_pipe_reg),
    .residual_syn(z_res_syn), .corr_final(z_corr_fin), .logical_flip(z_log_flip)
  );
  lakefillq_peel_boundary_egress12 u_hx_egress (
    .rem_syn(x_rem_pipe_reg), .corr(x_corr_pipe_reg),
    .residual_syn(x_res_syn), .corr_final(x_corr_fin), .logical_flip(x_log_flip)
  );

  wire [2:0] max_bfs_lvl = (mode_pipe_reg == 2'd0) ? 3'd3 : 3'd7;
  wire [2:0] max_grow_it = (mode_pipe_reg == 2'd0) ? 3'd2 : 3'd4;
  wire       any_active  = ((z_act_mask | x_act_mask) != 12'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      fsm_pipe_reg         <= OP_IDLE;
      mode_pipe_reg        <= 2'd0;
      prev_pf_pipe_reg     <= 2'd0;
      wt_pipe_reg          <= 5'd0;
      grow_iter_pipe_reg   <= 3'd0;
      hook_cnt_pipe_reg    <= 2'd0;
      lvl_pipe_reg         <= 3'd0;
      seam_cnt_pipe_reg    <= 2'd0;
      clk_cnt_pipe_reg     <= 6'd0;
      z_syn_pipe_reg       <= 12'd0;
      x_syn_pipe_reg       <= 12'd0;
      z_root_pipe_reg      <= ROOT_IDENTITY;
      x_root_pipe_reg      <= ROOT_IDENTITY;
      z_odd_pipe_reg       <= 12'd0;
      x_odd_pipe_reg       <= 12'd0;
      z_bhit_pipe_reg      <= 12'd0;
      x_bhit_pipe_reg      <= 12'd0;
      z_elen_pipe_reg      <= 30'd0;
      x_elen_pipe_reg      <= 30'd0;
      z_blen_pipe_reg      <= 12'd0;
      x_blen_pipe_reg      <= 12'd0;
      z_full_pipe_reg      <= 15'd0;
      x_full_pipe_reg      <= 15'd0;
      z_vis_pipe_reg       <= 12'd0;
      x_vis_pipe_reg       <= 12'd0;
      z_pe_pipe_reg        <= 48'd0;
      x_pe_pipe_reg        <= 48'd0;
      z_pv_pipe_reg        <= ROOT_IDENTITY;
      x_pv_pipe_reg        <= ROOT_IDENTITY;
      z_lv_pipe_reg        <= 36'd0;
      x_lv_pipe_reg        <= 36'd0;
      z_rem_pipe_reg       <= 12'd0;
      x_rem_pipe_reg       <= 12'd0;
      z_corr_pipe_reg      <= 25'd0;
      x_corr_pipe_reg      <= 25'd0;
      fast_cz_pipe_reg     <= 25'd0;
      fast_cx_pipe_reg     <= 25'd0;
      fast_pf_pipe_reg     <= 2'd0;
      out_valid_pipe_reg   <= 1'b0;
      pauli_frame_pipe_reg <= 2'd0;
      corr_z_pipe_reg      <= 25'd0;
      corr_x_pipe_reg      <= 25'd0;
      wt_out_pipe_reg      <= 5'd0;
      zero_byp_pipe_reg    <= 1'b0;
      sparse_byp_pipe_reg  <= 1'b0;
      clks_used_pipe_reg   <= 6'd0;
    end else begin
      out_valid_pipe_reg <= 1'b0;
      if (fsm_pipe_reg == OP_IDLE) begin
        if (in_valid) begin
          if (fp_zero_byp) begin
            // 1-clock (2.5 ns @ 400 MHz / 2.0 ns @ 500 MHz) hierarchical OR-tree w=0 bypass
            out_valid_pipe_reg   <= 1'b1;
            pauli_frame_pipe_reg <= prev_pauli_frame;
            corr_z_pipe_reg      <= 25'd0;
            corr_x_pipe_reg      <= 25'd0;
            wt_out_pipe_reg      <= 5'd0;
            zero_byp_pipe_reg    <= 1'b1;
            sparse_byp_pipe_reg  <= 1'b0;
            clks_used_pipe_reg   <= 6'd1;
          end else if (fp_sparse_wt2) begin
            // 2-clock (5.0 ns @ 400 MHz / 4.0 ns @ 500 MHz) direct XOR-address w<=2 fast-path
            wt_pipe_reg         <= fp_defect_wt;
            fast_cz_pipe_reg    <= fp_corr_z;
            fast_cx_pipe_reg    <= fp_corr_x;
            fast_pf_pipe_reg    <= fp_pf_fast;
            clk_cnt_pipe_reg    <= 6'd1;
            fsm_pipe_reg        <= OP_FAST_WT2;
          end else begin
            // Weight > 2 (or non-adjacent w=2): full deterministic Union-Find + shift-add path
            mode_pipe_reg      <= code_mode;
            prev_pf_pipe_reg   <= prev_pauli_frame;
            wt_pipe_reg        <= fp_defect_wt;
            grow_iter_pipe_reg <= 3'd0;
            clk_cnt_pipe_reg   <= 6'd1;
            z_syn_pipe_reg     <= fp_delta_syn[11:0];
            x_syn_pipe_reg     <= fp_delta_syn[23:12];
            z_root_pipe_reg    <= ROOT_IDENTITY;
            x_root_pipe_reg    <= ROOT_IDENTITY;
            z_odd_pipe_reg     <= fp_delta_syn[11:0];
            x_odd_pipe_reg     <= fp_delta_syn[23:12];
            z_bhit_pipe_reg    <= 12'd0;
            x_bhit_pipe_reg    <= 12'd0;
            z_elen_pipe_reg    <= 30'd0;
            x_elen_pipe_reg    <= 30'd0;
            z_blen_pipe_reg    <= 12'd0;
            x_blen_pipe_reg    <= 12'd0;
            z_full_pipe_reg    <= 15'd0;
            x_full_pipe_reg    <= 15'd0;
            fsm_pipe_reg       <= OP_UF_GROW;
          end
        end
      end else if (fsm_pipe_reg == OP_FAST_WT2) begin
        out_valid_pipe_reg   <= 1'b1;
        pauli_frame_pipe_reg <= fast_pf_pipe_reg;
        corr_z_pipe_reg      <= fast_cz_pipe_reg;
        corr_x_pipe_reg      <= fast_cx_pipe_reg;
        wt_out_pipe_reg      <= wt_pipe_reg;
        zero_byp_pipe_reg    <= 1'b0;
        sparse_byp_pipe_reg  <= 1'b1;
        clks_used_pipe_reg   <= 6'd2;
        fsm_pipe_reg         <= OP_IDLE;
      end else if (fsm_pipe_reg == OP_UF_GROW) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        if ((grow_iter_pipe_reg >= max_grow_it) | (~any_active)) begin
          fsm_pipe_reg <= OP_BFS_SEED;
        end else begin
          z_elen_pipe_reg   <= z_elen_nxt;
          x_elen_pipe_reg   <= x_elen_nxt;
          z_blen_pipe_reg   <= z_blen_nxt;
          x_blen_pipe_reg   <= x_blen_nxt;
          z_full_pipe_reg   <= z_full_nxt;
          x_full_pipe_reg   <= x_full_nxt;
          hook_cnt_pipe_reg <= 2'd0;
          fsm_pipe_reg      <= OP_SV_HOOK;
        end
      end else if (fsm_pipe_reg == OP_SV_HOOK) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        z_root_pipe_reg  <= z_root_hk;
        x_root_pipe_reg  <= x_root_hk;
        if (hook_cnt_pipe_reg == 2'd2) begin
          fsm_pipe_reg <= OP_SV_PJUMP;
        end else begin
          hook_cnt_pipe_reg <= hook_cnt_pipe_reg + 2'd1;
        end
      end else if (fsm_pipe_reg == OP_SV_PJUMP) begin
        clk_cnt_pipe_reg   <= clk_cnt_pipe_reg + 6'd1;
        z_root_pipe_reg    <= z_root_jp;
        x_root_pipe_reg    <= x_root_jp;
        z_odd_pipe_reg     <= z_odd_jp;
        x_odd_pipe_reg     <= x_odd_jp;
        z_bhit_pipe_reg    <= z_bhit_jp;
        x_bhit_pipe_reg    <= x_bhit_jp;
        grow_iter_pipe_reg <= grow_iter_pipe_reg + 3'd1;
        if ((grow_iter_pipe_reg + 3'd1) >= max_grow_it) begin
          fsm_pipe_reg <= OP_BFS_SEED;
        end else begin
          fsm_pipe_reg <= OP_UF_GROW;
        end
      end else if (fsm_pipe_reg == OP_BFS_SEED) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        z_vis_pipe_reg   <= z_vis_seed;
        x_vis_pipe_reg   <= x_vis_seed;
        z_pe_pipe_reg    <= 48'd0;
        x_pe_pipe_reg    <= 48'd0;
        z_pv_pipe_reg    <= ROOT_IDENTITY;
        x_pv_pipe_reg    <= ROOT_IDENTITY;
        z_lv_pipe_reg    <= 36'd0;
        x_lv_pipe_reg    <= 36'd0;
        lvl_pipe_reg     <= 3'd1;
        fsm_pipe_reg     <= OP_BFS_STEP;
      end else if (fsm_pipe_reg == OP_BFS_STEP) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        z_vis_pipe_reg   <= z_vis_nxt;
        x_vis_pipe_reg   <= x_vis_nxt;
        z_pe_pipe_reg    <= z_pe_nxt;
        x_pe_pipe_reg    <= x_pe_nxt;
        z_pv_pipe_reg    <= z_pv_nxt;
        x_pv_pipe_reg    <= x_pv_nxt;
        z_lv_pipe_reg    <= z_lv_nxt;
        x_lv_pipe_reg    <= x_lv_nxt;
        if (lvl_pipe_reg == max_bfs_lvl) begin
          z_rem_pipe_reg  <= z_syn_pipe_reg;
          x_rem_pipe_reg  <= x_syn_pipe_reg;
          z_corr_pipe_reg <= 25'd0;
          x_corr_pipe_reg <= 25'd0;
          lvl_pipe_reg    <= max_bfs_lvl;
          fsm_pipe_reg    <= OP_PEEL_STEP;
        end else begin
          lvl_pipe_reg <= lvl_pipe_reg + 3'd1;
        end
      end else if (fsm_pipe_reg == OP_PEEL_STEP) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        z_rem_pipe_reg   <= z_rem_nxt;
        x_rem_pipe_reg   <= x_rem_nxt;
        z_corr_pipe_reg  <= z_corr_nxt;
        x_corr_pipe_reg  <= x_corr_nxt;
        if (lvl_pipe_reg == 3'd1) begin
          if (mode_pipe_reg == 2'd2) begin
            seam_cnt_pipe_reg <= 2'd2;
            fsm_pipe_reg      <= OP_SEAM_ALIGN;
          end else if (mode_pipe_reg == 2'd3) begin
            seam_cnt_pipe_reg <= 2'd0;
            fsm_pipe_reg      <= OP_SEAM_ALIGN;
          end else begin
            fsm_pipe_reg <= OP_EGRESS;
          end
        end else begin
          lvl_pipe_reg <= lvl_pipe_reg - 3'd1;
        end
      end else if (fsm_pipe_reg == OP_SEAM_ALIGN) begin
        clk_cnt_pipe_reg <= clk_cnt_pipe_reg + 6'd1;
        if (seam_cnt_pipe_reg == 2'd0) begin
          fsm_pipe_reg <= OP_EGRESS;
        end else begin
          seam_cnt_pipe_reg <= seam_cnt_pipe_reg - 2'd1;
        end
      end else begin
        out_valid_pipe_reg   <= 1'b1;
        pauli_frame_pipe_reg <= prev_pf_pipe_reg ^ {x_log_flip, z_log_flip};
        corr_z_pipe_reg      <= z_corr_fin;
        corr_x_pipe_reg      <= x_corr_fin;
        wt_out_pipe_reg      <= wt_pipe_reg;
        zero_byp_pipe_reg    <= 1'b0;
        sparse_byp_pipe_reg  <= 1'b0;
        clks_used_pipe_reg   <= clk_cnt_pipe_reg + 6'd1;
        fsm_pipe_reg         <= OP_IDLE;
      end
    end
  end

  assign out_valid             = out_valid_pipe_reg;
  assign pauli_frame_flip      = pauli_frame_pipe_reg;
  assign corr_z_out            = corr_z_pipe_reg;
  assign corr_x_out            = corr_x_pipe_reg;
  assign defect_weight_out     = wt_out_pipe_reg;
  assign zero_bypass_out       = zero_byp_pipe_reg;
  assign sparse_wt2_bypass_out = sparse_byp_pipe_reg;
  assign core_clocks_used      = clks_used_pipe_reg;
endmodule

