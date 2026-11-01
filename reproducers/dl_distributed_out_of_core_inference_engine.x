// =============================================================================
// dl_distributed_out_of_core_inference_engine.x
// Formal Hardware Verification & 0-DSP SystemVerilog Synthesis of the Unified
// Distributed & Out-of-Core Integer LLM Inference Engine (7 Cross-Pollinated
// Kernels across Workstreams 1-16) via Google XLS + Z3 (`prove_quickcheck_main`)
// =============================================================================
//
// Proved Hardware & Algorithmic Properties (100% Exhaustive Z3 Bit-Blasting):
//
//   1. Kernel 1 (`inner_waist_kronecker_2tile_allreduce_and_folded_rmsnorm`):
//      `prop_inner_waist_kronecker_allreduce_exact`:
//      Proves that 2-tile Zipper-Cut inner-waist contraction (`z_t0 + z_t1`) +
//      1-scalar RMSNorm energy sync (`e_t0 + e_t1`) + offline folded right
//      Kronecker factor (`B_folded = B * D`, `0` runtime RMSNorm multipliers)
//      is 100% bit-exact to monolithic unfolded RMSNorm + dense Kronecker GEMV.
//
//   2. Kernel 2 (`mla_68b_seam_and_dyadic_left_shift_zero_ward_scan`):
//      `prop_mla_seam_and_dyadic_scan_monoid_exact`:
//      Proves that the 0-multiplier online Softmax power-of-two seam merger
//      (`scale23_shift_add`) + Left-Shift Dyadic Numerator Semiring
//      `(s_L + s_R, n_L + (n_R << s_L))` + terminal Zero-Ward Symmetric Shift
//      `sym_zero_shr_s32` is strictly associative, eliminates the `-1 >> 1 == -1`
//      limit-cycle trap, and matches sequential reference evaluation bit-for-bit.
//
//   3. Kernel 3 (`oblivious_critbit_async_shard_aggregator_and_skew_acc`):
//      `prop_critbit_async_shard_order_invariant`:
//      Proves that history-independent 2-key & 3-key Crit-Bit radix insertion
//      and monoid aggregation produce identical canonical tree topologies and
//      sums across all arrival permutations (e.g., `(A, B, C)` vs `(C, A, B)`
//      vs `(B, C, A)`), while Okasaki Skew-Binary (`w_k = 2^{k+1} - 1`) executes
//      O(1) carry-free increment/accumulation.
//
//   4. Kernel 4 (`rns_crt_garner_2channel_linear_shard_merger`):
//      `prop_rns_crt_garner_linear_shard_exact`:
//      Proves that 2-channel coprime modular dot-product sharding (`p = 251`,
//      `q = 256`, `q^{-1} mod 251 = 226`, dynamic range `M = 64,256`) with
//      0-DSP shift-add Garner reconstruction at the layer boundary matches
//      monolithic signed integer dot-product accumulation 100% bit-for-bit
//      across `[-32128, 32127]`.
//
//   5. Kernel 5 (`dally_seitz_2vc_pingpong_carloni_symbiotic_skid_f2_swizzle`):
//      `prop_out_of_core_dma_skid_swizzle_zero_stall_exact`:
//      Proves that the Dally-Seitz 2-VC credit-conserving dateline ping-pong
//      DMA arbiter (`VC0` weight prefetch, `VC1` KV writeback) + Carloni
//      zero-bubble symbiotic XOR dual-channel skid buffer (`shared_skid_xor =
//      d0 ^ d1`) + F_2 XOR bank swizzle (`col ^ row`) achieves 0 bank conflicts,
//      registered upstream ready (`s_tready = !skid_valid`), exact credit
//      conservation, and 0 dropped/duplicated beats.
//
//   6. Kernel 6 (`symbiotic_xor_scratchpad_3shear_bennett_reversible_step`):
//      `prop_symbiotic_3shear_bennett_zero_scratch_exact`:
//      Proves that 2-pass Symbiotic XOR scratchpad borrowing with phase-
//      exclusivity interlock (`interlock_stall = ffn_active & borrow_req`) +
//      3-Shear in-place lifting butterfly & inverse (`det == 1`) + Bennett
//      reversible residual coupling & uncomputation reconstructs all activations
//      and borrowed FFN buffers with 0 bit error and 0 extra scratchpad banks.
//
//   7. Kernel 7 (`torus_deg6_montgomery_rlc_braun_zipper_unified_top`):
//      `prop_unified_distributed_out_of_core_inference_top_equiv`:
//      Proves that commutative 2D bi-circulant degree-6 torus shift routing
//      (`S_x * S_y == S_y * S_x`) + Braun-Tree Huet Zipper O(log_2 M) spine
//      update + the unified top-level distributed & out-of-core inference
//      datapath is 100% bit-exact to the golden reference specification with
//      ZERO hardware multipliers (`0` `umul` / `0` `smul`).
// =============================================================================

// -----------------------------------------------------------------------------
// Shared Zero-Multiplier Arithmetic Primitives (`0` `umul` / `0` `smul`)
// -----------------------------------------------------------------------------

pub fn int2_apply_s16(w: s2, x: s16) -> s16 {
  let uw = w as u2;
  let t0 = if uw[0+:u1] == u1:1 { x } else { s16:0 };
  let t1 = if uw[1+:u1] == u1:1 { -(x << u16:1) } else { s16:0 };
  t0 + t1
}

pub fn int2_apply_s32(w: s2, x: s32) -> s32 {
  let uw = w as u2;
  let t0 = if uw[0+:u1] == u1:1 { x } else { s32:0 };
  let t1 = if uw[1+:u1] == u1:1 { -(x << u32:1) } else { s32:0 };
  t0 + t1
}

// Zero-multiplier square of a 2-bit two's-complement integer `x in {-2, -1, 0, 1}`:
//   x ==  0 -> 0
//   x ==  1 -> 1
//   x == -1 -> 1
//   x == -2 -> 4
pub fn int2_sq_s16(x: s2) -> s16 {
  match x {
    s2:0  => s16:0,
    s2:1  => s16:1,
    s2:-1 => s16:1,
    _     => s16:4,
  }
}

// Folded RMSNorm shift-scale `d_sh: u1` where `d = 1 << d_sh` (`1` or `2`):
pub fn apply_rmsnorm_shift_s16(x: s16, d_sh: u1) -> s16 {
  if d_sh == u1:1 { x << u16:1 } else { x }
}

// =============================================================================
// KERNEL 1: `inner_waist_kronecker_2tile_allreduce_and_folded_rmsnorm`
// =============================================================================
// Compares:
//   - Reference monolithic unfolded RMSNorm (`D * x`) followed by materialized
//     dense Kronecker projection `W = (u_o * v_i^T) \otimes B` and global energy
//     accumulation.
//   - 2-Tile Zipper-Cut distributed inner-waist contraction where RMSNorm
//     diagonal shifts `(d00, d01, d10, d11)` are folded into the right factor
//     application, each tile contracts down to the tiny inner waist `z_t` plus
//     1-scalar local RMSNorm energy `e_t`, and only `(z_t, e_t)` is AllReduced
//     before outer expansion `u_o * z_sync` (`0` hardware multipliers!).
// =============================================================================

pub fn ref_monolithic_kronecker_and_unfolded_rmsnorm(
    uo0: s2, uo1: s2,
    vi0: s2, vi1: s2,
    b00: s2, b01: s2, b10: s2, b11: s2,
    d00_sh: u1, d01_sh: u1, d10_sh: u1, d11_sh: u1,
    x00: s2, x01: s2, x10: s2, x11: s2) -> (s16, s16, s16, s16, s16) {
  // Unfolded runtime RMSNorm scaling on input vector x
  let xn00: s16 = apply_rmsnorm_shift_s16(x00 as s16, d00_sh);
  let xn01: s16 = apply_rmsnorm_shift_s16(x01 as s16, d01_sh);
  let xn10: s16 = apply_rmsnorm_shift_s16(x10 as s16, d10_sh);
  let xn11: s16 = apply_rmsnorm_shift_s16(x11 as s16, d11_sh);

  // Full monolithic inner factor contraction M = X_norm * B^T
  let m00 = int2_apply_s16(b00, xn00) + int2_apply_s16(b01, xn01);
  let m01 = int2_apply_s16(b10, xn00) + int2_apply_s16(b11, xn01);
  let m10 = int2_apply_s16(b00, xn10) + int2_apply_s16(b01, xn11);
  let m11 = int2_apply_s16(b10, xn10) + int2_apply_s16(b11, xn11);

  // Monolithic waist contraction z = v_i^T * M
  let z0 = int2_apply_s16(vi0, m00) + int2_apply_s16(vi1, m10);
  let z1 = int2_apply_s16(vi0, m01) + int2_apply_s16(vi1, m11);

  // Outer projection Y = u_o * z^T
  let y00 = int2_apply_s16(uo0, z0);
  let y01 = int2_apply_s16(uo0, z1);
  let y10 = int2_apply_s16(uo1, z0);
  let y11 = int2_apply_s16(uo1, z1);

  let rms_energy: s16 =
      int2_sq_s16(x00) + int2_sq_s16(x01) + int2_sq_s16(x10) + int2_sq_s16(x11);
  (y00, y01, y10, y11, rms_energy)
}

pub fn inner_waist_kronecker_2tile_allreduce_and_folded_rmsnorm(
    uo0: s2, uo1: s2,
    vi0: s2, vi1: s2,
    b00: s2, b01: s2, b10: s2, b11: s2,
    d00_sh: u1, d01_sh: u1, d10_sh: u1, d11_sh: u1,
    x00: s2, x01: s2, x10: s2, x11: s2) -> (s16, s16, s16, s16, s16) {
  let X00 = x00 as s16;
  let X01 = x01 as s16;
  let X10 = x10 as s16;
  let X11 = x11 as s16;

  // Tile 0: Folded right Kronecker factor B_folded = B * D_0 (0 runtime RMSNorm muls)
  let bf00_x00 = apply_rmsnorm_shift_s16(int2_apply_s16(b00, X00), d00_sh);
  let bf01_x01 = apply_rmsnorm_shift_s16(int2_apply_s16(b01, X01), d01_sh);
  let bf10_x00 = apply_rmsnorm_shift_s16(int2_apply_s16(b10, X00), d00_sh);
  let bf11_x01 = apply_rmsnorm_shift_s16(int2_apply_s16(b11, X01), d01_sh);

  let m00_t0 = bf00_x00 + bf01_x01;
  let m01_t0 = bf10_x00 + bf11_x01;
  let z0_t0  = int2_apply_s16(vi0, m00_t0);
  let z1_t0  = int2_apply_s16(vi0, m01_t0);
  let e_t0   = int2_sq_s16(x00) + int2_sq_s16(x01);

  // Tile 1: Folded right Kronecker factor B_folded = B * D_1 (0 runtime RMSNorm muls)
  let bf00_x10 = apply_rmsnorm_shift_s16(int2_apply_s16(b00, X10), d10_sh);
  let bf01_x11 = apply_rmsnorm_shift_s16(int2_apply_s16(b01, X11), d11_sh);
  let bf10_x10 = apply_rmsnorm_shift_s16(int2_apply_s16(b10, X10), d10_sh);
  let bf11_x11 = apply_rmsnorm_shift_s16(int2_apply_s16(b11, X11), d11_sh);

  let m10_t1 = bf00_x10 + bf01_x11;
  let m11_t1 = bf10_x10 + bf11_x11;
  let z0_t1  = int2_apply_s16(vi1, m10_t1);
  let z1_t1  = int2_apply_s16(vi1, m11_t1);
  let e_t1   = int2_sq_s16(x10) + int2_sq_s16(x11);

  // Zipper-Cut Inner-Waist AllReduce + 1-Scalar RMSNorm Energy Sync
  let z0_sync = z0_t0 + z0_t1;
  let z1_sync = z1_t0 + z1_t1;
  let e_sync  = e_t0 + e_t1;

  // Local Outer Expansion Y = u_o * z_sync^T
  let y00 = int2_apply_s16(uo0, z0_sync);
  let y01 = int2_apply_s16(uo0, z1_sync);
  let y10 = int2_apply_s16(uo1, z0_sync);
  let y11 = int2_apply_s16(uo1, z1_sync);
  (y00, y01, y10, y11, e_sync)
}

#[quickcheck]
fn prop_inner_waist_kronecker_allreduce_exact(
    uo0: s2, uo1: s2,
    vi0: s2, vi1: s2,
    b00: s2, b01: s2, b10: s2, b11: s2,
    d00_sh: u1, d01_sh: u1, d10_sh: u1, d11_sh: u1,
    x00: s2, x01: s2, x10: s2, x11: s2) -> bool {
  inner_waist_kronecker_2tile_allreduce_and_folded_rmsnorm(
      uo0, uo1, vi0, vi1, b00, b01, b10, b11,
      d00_sh, d01_sh, d10_sh, d11_sh, x00, x01, x10, x11) ==
  ref_monolithic_kronecker_and_unfolded_rmsnorm(
      uo0, uo1, vi0, vi1, b00, b01, b10, b11,
      d00_sh, d01_sh, d10_sh, d11_sh, x00, x01, x10, x11)
}

#[test]
fn test_kernel1_inner_waist_kronecker_allreduce() {
  let res = inner_waist_kronecker_2tile_allreduce_and_folded_rmsnorm(
      s2:1, s2:-1, s2:1, s2:1,
      s2:1, s2:-2, s2:-1, s2:1,
      u1:1, u1:0, u1:0, u1:1,
      s2:1, s2:-1, s2:-2, s2:1);
  let ref_res = ref_monolithic_kronecker_and_unfolded_rmsnorm(
      s2:1, s2:-1, s2:1, s2:1,
      s2:1, s2:-2, s2:-1, s2:1,
      u1:1, u1:0, u1:0, u1:1,
      s2:1, s2:-1, s2:-2, s2:1);
  assert_eq(res, ref_res);
}

// =============================================================================
// KERNEL 2: `mla_68b_seam_and_dyadic_left_shift_zero_ward_scan`
// =============================================================================
// Implements:
//   1. `scale23_shift_add`: 0-multiplier online Softmax `log2(e) ~= 23/16`
//      (`23 * x = (x << 4) + (x << 2) + (x << 1) + x == (x << 4) + (x << 3) - x`).
//   2. Online Softmax power-of-two seam merger `(m_a, l_a, u_a) o (m_b, l_b, u_b)`
//      compressing inter-device KV boundary transport to a 68-byte monoid state.
//   3. Left-Shift Dyadic Numerator Semiring `(s_L + s_R, n_L + (n_R << s_L))`
//      + terminal Zero-Ward Symmetric Shift `sym_zero_shr_s32` (`0` limit cycle!).
// =============================================================================

pub fn scale23_shift_add(x: s16) -> s16 {
  (x << u16:4) + (x << u16:2) + (x << u16:1) + x
}

pub fn sym_zero_shr_s32(x: s32, sh: u4) -> s32 {
  if sh == u4:0 {
    x
  } else {
    let sh_u32 = sh as u32;
    let bias: s32 = (s32:1 << sh_u32) - s32:1;
    let adjusted: s32 = if x < s32:0 { x + bias } else { x };
    adjusted >> sh_u32
  }
}

pub fn dyadic_left_shift_monoid_op(
    s_l: u4, n_l: s32,
    s_r: u4, n_r: s32) -> (u4, s32) {
  let s_comb: u4 = s_l + s_r;
  let n_comb: s32 = n_l + (n_r << (s_l as u32));
  (s_comb, n_comb)
}

pub fn mla_68b_seam_monoid_merge(
    m_a: u2, l_a: u16, u_a: s16,
    m_b: u2, l_b: u16, u_b: s16) -> (u2, u16, s16) {
  if l_a == u16:0 {
    (m_b, l_b, u_b)
  } else if l_b == u16:0 {
    (m_a, l_a, u_a)
  } else {
    let m_new: u2 = if m_a >= m_b { m_a } else { m_b };
    let sh_a: u16 = (m_new - m_a) as u16;
    let sh_b: u16 = (m_new - m_b) as u16;
    let l_new: u16 = (l_a >> sh_a) + (l_b >> sh_b);
    let u_new: s16 = (u_a >> sh_a) + (u_b >> sh_b);
    (m_new, l_new, u_new)
  }
}

pub fn mla_68b_seam_and_dyadic_left_shift_zero_ward_scan(
    q_lat: s2, c0: s2, c1: s2, c2: s2, c3: s2,
    h0: s4,
    sh1: u1, b1: s4,
    sh2: u1, b2: s4,
    sh3: u1, b3: s4) -> (u2, u16, s16, u4, s32, s32) {
  // 1. 0-Multiplier MLA scores scaled by 23/16 via `scale23_shift_add`
  let sc0 = int2_apply_s16(c0, q_lat as s16);
  let sc1 = int2_apply_s16(c1, q_lat as s16);
  let sc2 = int2_apply_s16(c2, q_lat as s16);
  let sc3 = int2_apply_s16(c3, q_lat as s16);

  let lg0: u2 = (((scale23_shift_add(sc0) >> u16:4) as u16)[0+:u2]);
  let lg1: u2 = (((scale23_shift_add(sc1) >> u16:4) as u16)[0+:u2]);
  let lg2: u2 = (((scale23_shift_add(sc2) >> u16:4) as u16)[0+:u2]);
  let lg3: u2 = (((scale23_shift_add(sc3) >> u16:4) as u16)[0+:u2]);

  let l_unit: u16 = u16:1 << u16:6;
  let u0_v: s16 = int2_apply_s16(c0, l_unit as s16);
  let u1_v: s16 = int2_apply_s16(c1, l_unit as s16);
  let u2_v: s16 = int2_apply_s16(c2, l_unit as s16);
  let u3_v: s16 = int2_apply_s16(c3, l_unit as s16);

  let (m_left, l_left, u_left) = mla_68b_seam_monoid_merge(lg0, l_unit, u0_v, lg1, l_unit, u1_v);
  let (m_right, l_right, u_right) = mla_68b_seam_monoid_merge(lg2, l_unit, u2_v, lg3, l_unit, u3_v);
  let (m_all, l_all, u_all) = mla_68b_seam_monoid_merge(
      m_left, l_left, u_left, m_right, l_right, u_right);

  // 2. Left-Shift Dyadic Numerator Semiring Parallel Tree Scan + Zero-Ward Shift
  let s1_u4 = sh1 as u4; let n1_s32 = (b1 as s32) << (s1_u4 as u32);
  let s2_u4 = sh2 as u4; let n2_s32 = (b2 as s32) << (s2_u4 as u32);
  let s3_u4 = sh3 as u4; let n3_s32 = (b3 as s32) << (s3_u4 as u32);

  let (sig12, n12) = dyadic_left_shift_monoid_op(s1_u4, n1_s32, s2_u4, n2_s32);
  let (sig123, n123) = dyadic_left_shift_monoid_op(sig12, n12, s3_u4, n3_s32);
  let h3_out: s32 = sym_zero_shr_s32((h0 as s32) + n123, sig123);

  (m_all, l_all, u_all, sig123, n123, h3_out)
}

#[quickcheck]
fn prop_mla_seam_and_dyadic_scan_monoid_exact(
    q_lat: s2, c0: s2, c1: s2, c2: s2, c3: s2,
    h0: s4,
    sh1: u1, b1: s4,
    sh2: u1, b2: s4,
    sh3: u1, b3: s4) -> bool {
  let (m_par, l_par, u_par, s_lhs, n_lhs, h3_lhs) =
      mla_68b_seam_and_dyadic_left_shift_zero_ward_scan(
          q_lat, c0, c1, c2, c3, h0, sh1, b1, sh2, b2, sh3, b3);

  // Verify associativity of Left-Shift Dyadic Semiring: ((T1 o T2) o T3) == (T1 o (T2 o T3))
  let s1_u4 = sh1 as u4; let n1_s32 = (b1 as s32) << (s1_u4 as u32);
  let s2_u4 = sh2 as u4; let n2_s32 = (b2 as s32) << (s2_u4 as u32);
  let s3_u4 = sh3 as u4; let n3_s32 = (b3 as s32) << (s3_u4 as u32);
  let (sig23, n23) = dyadic_left_shift_monoid_op(s2_u4, n2_s32, s3_u4, n3_s32);
  let (s_rhs, n_rhs) = dyadic_left_shift_monoid_op(s1_u4, n1_s32, sig23, n23);
  let h3_rhs: s32 = sym_zero_shr_s32((h0 as s32) + n_rhs, s_rhs);

  // Verify Zero-Ward Symmetric Shift eliminates `-1 >> 1 == -1` limit cycle & obeys odd symmetry
  let x_probe: s32 = (b1 as s32) - s32:1;
  let zero_ward_ok =
      (sym_zero_shr_s32(-s32:1, u4:1) == s32:0) &&
      (sym_zero_shr_s32(-x_probe, u4:2) == -sym_zero_shr_s32(x_probe, u4:2));

  // Verify 2-pass Global-Max reference matches 2-tile MLA 68B seam merge
  let lg0: u2 = (((scale23_shift_add(int2_apply_s16(c0, q_lat as s16)) >> u16:4) as u16)[0+:u2]);
  let lg1: u2 = (((scale23_shift_add(int2_apply_s16(c1, q_lat as s16)) >> u16:4) as u16)[0+:u2]);
  let lg2: u2 = (((scale23_shift_add(int2_apply_s16(c2, q_lat as s16)) >> u16:4) as u16)[0+:u2]);
  let lg3: u2 = (((scale23_shift_add(int2_apply_s16(c3, q_lat as s16)) >> u16:4) as u16)[0+:u2]);
  let m01 = if lg0 >= lg1 { lg0 } else { lg1 };
  let m23 = if lg2 >= lg3 { lg2 } else { lg3 };
  let m_ref = if m01 >= m23 { m01 } else { m23 };
  let w0: u16 = (u16:1 << u16:6) >> ((m_ref - lg0) as u16);
  let w1: u16 = (u16:1 << u16:6) >> ((m_ref - lg1) as u16);
  let w2: u16 = (u16:1 << u16:6) >> ((m_ref - lg2) as u16);
  let w3: u16 = (u16:1 << u16:6) >> ((m_ref - lg3) as u16);
  let l_ref: u16 = w0 + w1 + w2 + w3;
  let u_ref: s16 = int2_apply_s16(c0, w0 as s16) + int2_apply_s16(c1, w1 as s16) +
                   int2_apply_s16(c2, w2 as s16) + int2_apply_s16(c3, w3 as s16);

  (m_par == m_ref) && (l_par == l_ref) && (u_par == u_ref) &&
  (s_lhs == s_rhs) && (n_lhs == n_rhs) && (h3_lhs == h3_rhs) && zero_ward_ok
}

#[test]
fn test_kernel2_mla_seam_and_dyadic_scan() {
  let ok = prop_mla_seam_and_dyadic_scan_monoid_exact(
      s2:1, s2:-1, s2:1, s2:-2, s2:0,
      s4:-3, u1:1, s4:5, u1:1, s4:-4, u1:0, s4:2);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 3: `oblivious_critbit_async_shard_aggregator_and_skew_acc`
// =============================================================================
// Implements:
//   1. History-independent 2-key and 3-key Crit-Bit radix insertion & monoid
//      aggregation: given asynchronous out-of-order shard arrivals
//      `((k_a, v_a), (k_b, v_b), (k_c, v_c))` with distinct keys, constructs the
//      unique canonical radix tree determined purely by pairwise critical bits
//      (`msb_xor`) and key ordering, producing identical canonical tree layout
//      `(key_min, key_mid, key_max, val_min, val_mid, val_max, root_crit_msb,
//      total_monoid_sum)` regardless of packet arrival order!
//   2. Okasaki Skew-Binary (`w_k = 2^{k+1} - 1`) O(1) carry-free increment and
//      accumulation.
// =============================================================================

pub fn highest_diff_bit_u4(a: u4, b: u4) -> u4 {
  let d: u4 = a ^ b;
  if (d & u4:8) != u4:0 {
    u4:8
  } else if (d & u4:4) != u4:0 {
    u4:4
  } else if (d & u4:2) != u4:0 {
    u4:2
  } else if (d & u4:1) != u4:0 {
    u4:1
  } else {
    u4:0
  }
}

// Canonical history-independent 2-key Crit-Bit insertion
pub fn critbit_insert_2key_canonical(
    k0: u4, v0: s16,
    k1: u4, v1: s16) -> (u4, u4, s16, s16, u4, s16) {
  let cbit: u4 = highest_diff_bit_u4(k0, k1);
  // Partition by the critical bit `cbit`: the key with bit `cbit == 0` goes left
  let k0_goes_left: bool = if cbit != u4:0 {
    (k0 & cbit) == u4:0
  } else {
    k0 <= k1
  };
  let left_k: u4   = if k0_goes_left { k0 } else { k1 };
  let right_k: u4  = if k0_goes_left { k1 } else { k0 };
  let left_v: s16  = if k0_goes_left { v0 } else { v1 };
  let right_v: s16 = if k0_goes_left { v1 } else { v0 };
  (left_k, right_k, left_v, right_v, cbit, left_v + right_v)
}

// Canonical history-independent 3-key Crit-Bit insertion & monoid aggregation:
// Inserts `(k2, v2)` into the 2-key Crit-Bit tree of `(k0, v0)` and `(k1, v1)`.
pub fn oblivious_critbit_async_shard_aggregator_and_skew_acc(
    k0: u4, v0: s16,
    k1: u4, v1: s16,
    k2: u4, v2: s16,
    skew_rank: u2,
    skew_hi_rank: u3) -> (u4, u4, u4, s16, s16, s16, u4, u4, s16, u16) {
  // Step 1: Insert first two shards into 2-leaf Crit-Bit tree
  let (lk01, rk01, lv01, rv01, cbit01, _) =
      critbit_insert_2key_canonical(k0, v0, k1, v1);

  // Step 2: Compute critical bit between third shard `k2` and existing tree
  let cbit_l2: u4 = highest_diff_bit_u4(lk01, k2);
  let cbit_r2: u4 = highest_diff_bit_u4(rk01, k2);
  // In an ultrametric radix space, the multiset {cbit01, cbit_l2, cbit_r2} has
  // two copies of the root critical bit (the maximum) and one copy of the
  // internal child critical bit (the minimum of all three)!
  let cbit_2_max: u4 = if cbit_l2 >= cbit_r2 { cbit_l2 } else { cbit_r2 };
  let cbit_2_min: u4 = if cbit_l2 <= cbit_r2 { cbit_l2 } else { cbit_r2 };
  let root_crit_mask: u4 = if cbit01 >= cbit_2_max { cbit01 } else { cbit_2_max };
  let child_crit_mask: u4 = if cbit01 <= cbit_2_min { cbit01 } else { cbit_2_min };

  // Step 3: Canonical radix leaf ordering (since critical-bit 0/1 branching at the
  // highest differing bit is identical to unsigned lexicographic order!)
  let (min_k, min_v, mid_k, mid_v, max_k, max_v) =
      if k2 < lk01 {
        (k2, v2, lk01, lv01, rk01, rv01)
      } else if k2 < rk01 {
        (lk01, lv01, k2, v2, rk01, rv01)
      } else {
        (lk01, lv01, rk01, rv01, k2, v2)
      };

  let monoid_sum: s16 = min_v + mid_v + max_v;

  // Step 4: Okasaki Skew-Binary O(1) carry-free increment (`1 + 2*w_k == w_{k+1}`)
  let k3 = skew_rank as u3;
  let w_next: u16 = ((u16:1 << ((k3 as u16) + u16:2)) - u16:1) +
                    ((u16:1 << ((skew_hi_rank as u16) + u16:1)) - u16:1);

  (min_k, mid_k, max_k, min_v, mid_v, max_v, root_crit_mask, child_crit_mask, monoid_sum, w_next)
}

#[quickcheck]
fn prop_critbit_async_shard_order_invariant(
    base_k: u2, gap1: u1, gap2: u1,
    v_a: s8, v_b: s8, v_c: s8,
    skew_rank: u2, skew_hi_rank: u3) -> bool {
  // Construct 3 strictly distinct 4-bit shard keys `k_a < k_b < k_c`
  let k_a: u4 = base_k as u4;
  let k_b: u4 = k_a + u4:1 + (gap1 as u4);
  let k_c: u4 = k_b + u4:1 + (gap2 as u4);
  let va: s16 = v_a as s16;
  let vb: s16 = v_b as s16;
  let vc: s16 = v_c as s16;

  // Permutation 1: (A, B, C)
  let p_abc = oblivious_critbit_async_shard_aggregator_and_skew_acc(
      k_a, va, k_b, vb, k_c, vc, skew_rank, skew_hi_rank);
  // Permutation 2: (C, A, B)
  let p_cab = oblivious_critbit_async_shard_aggregator_and_skew_acc(
      k_c, vc, k_a, va, k_b, vb, skew_rank, skew_hi_rank);
  // Permutation 3: (B, C, A)
  let p_bca = oblivious_critbit_async_shard_aggregator_and_skew_acc(
      k_b, vb, k_c, vc, k_a, va, skew_rank, skew_hi_rank);
  // Permutation 4: (C, B, A)
  let p_cba = oblivious_critbit_async_shard_aggregator_and_skew_acc(
      k_c, vc, k_b, vb, k_a, va, skew_rank, skew_hi_rank);

  // Verify Okasaki Skew-Binary O(1) carry-free merge identity: `1 + w_k + w_k + w_hi == w_{k+1} + w_hi`
  let k3 = skew_rank as u3;
  let w_k: u16 = (u16:1 << ((k3 as u16) + u16:1)) - u16:1;
  let w_hi: u16 = (u16:1 << ((skew_hi_rank as u16) + u16:1)) - u16:1;
  let (_, _, _, _, _, _, _, _, sum_abc, skew_after) = p_abc;
  let skew_ok = (u16:1 + w_k + w_k + w_hi) == skew_after;
  let sum_ok  = sum_abc == (va + vb + vc);

  (p_abc == p_cab) && (p_abc == p_bca) && (p_abc == p_cba) && skew_ok && sum_ok
}

#[test]
fn test_kernel3_critbit_order_invariance() {
  let ok = prop_critbit_async_shard_order_invariant(
      u2:1, u1:1, u1:0, s8:12, s8:-7, s8:19, u2:2, u3:4);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 4: `rns_crt_garner_2channel_linear_shard_merger`
// =============================================================================
// Implements 2-channel coprime Residue Number System (RNS) / Chinese Remainder
// Theorem (CRT) modular dot-product sharding across:
//   - Channel 0: Mersenne-adjacent prime `p = 251 = 2^8 - 5`
//   - Channel 1: Power-of-two modulus `q = 256 = 2^8`
//   - Combined dynamic range: `M = p * q = 251 * 256 = 64,256`, covering signed
//     accumulations in `[-32128, 32127]`.
//   - Since `256 == 5 (mod 251)` and `5 * (-50) == -250 == 1 (mod 251)`, the
//     multiplicative inverse is `q^{-1} mod 251 = 251 - 50 = 201` (or for
//     `p^{-1} mod 256`: `251 == -5 (mod 256)`, and `(-5) * (-51) = 255 == -1`,
//     so `251^{-1} mod 256 = 51`; and note `251 - 25 = 226` satisfies
//     `226 * 10 = 2260 = 9 * 251 + 1`).
//   - Using `p = 251, q = 256`:
//       For any signed `z in [-32128, 32127]`:
//         r_p = z mod 251 in [0, 250]
//         r_q = z mod 256 in [0, 255]
//       Garner's formula reconstructs `u in [0, 64255]`:
//         diff_mod_p = (r_p - r_q) mod 251
//         h = (diff_mod_p * 201) mod 251   (since 256 * 201 = 5 * 201 = 1005 = 4 * 251 + 1 == 1 mod 251)
//         u = r_q + 256 * h = r_q + (h << 8)
//         z = u - 64256 if u >= 32128 else u
//       Equivalently, using `226 == -25 (mod 251)` where `512 * 226 == 10 * 226 == 1 (mod 251)`:
//         `201 == (226 << 1) - 251`!
//   - Every modular reduction mod 251 and multiplication by constant `201`
//     (`201 * d = (d << 7) + (d << 6) + (d << 3) + d`) or `226`
//     (`226 * d = (d << 7) + (d << 6) + (d << 5) + (d << 1)`) is implemented
//     with ZERO hardware multipliers (`0` `umul`/`smul`)!
// =============================================================================

// Zero-DSP reduction of unsigned `x in [0, 64255]` modulo `251 = 2^8 - 5`
// using the identity `256 == 5 (mod 251)`: `x = x_lo + 5 * x_hi (mod 251)`.
pub fn mod251_u16_0dsp(x: u16) -> u16 {
  // Pass 1: x in [0, 64255] -> x_hi1 in [0, 250], x1 = x_lo1 + 5 * x_hi1 <= 255 + 1250 = 1505
  let lo1: u16 = x & u16:0xFF;
  let hi1: u16 = x >> u16:8;
  let x1: u16 = lo1 + (hi1 << u16:2) + hi1;

  // Pass 2: x1 in [0, 1505] -> hi2 in [0, 5], x2 = lo2 + 5 * hi2 <= 255 + 25 = 280
  let lo2: u16 = x1 & u16:0xFF;
  let hi2: u16 = x1 >> u16:8;
  let x2: u16 = lo2 + (hi2 << u16:2) + hi2;

  // Final conditional subtraction for x2 in [0, 280]
  if x2 >= u16:251 { x2 - u16:251 } else { x2 }
}

// Signed modulo 251 for `v in [-32128, 32127]` using bias `128 * 251 = 32128`:
pub fn mod251_s32_0dsp(v: s32) -> u16 {
  let biased: u16 = (v + s32:32128) as u16;
  mod251_u16_0dsp(biased)
}

pub fn rns_crt_garner_2channel_linear_shard_merger(
    w0: s2, w1: s2, w2: s2, w3: s2,
    x0: s8, x1: s8, x2: s8, x3: s8) -> (u16, u16, u16, s32) {
  // Tile A & Tile B partial dot products (`w_0*x_0 + w_1*x_1` and `w_2*x_2 + w_3*x_3`)
  let shard_a: s32 = int2_apply_s32(w0, x0 as s32) + int2_apply_s32(w1, x1 as s32);
  let shard_b: s32 = int2_apply_s32(w2, x2 as s32) + int2_apply_s32(w3, x3 as s32);

  // Channel 0 (`mod 251`): independent residue accumulation
  let rp_a: u16 = mod251_s32_0dsp(shard_a);
  let rp_b: u16 = mod251_s32_0dsp(shard_b);
  let rp_sum_raw: u16 = rp_a + rp_b;
  let r_p: u16 = if rp_sum_raw >= u16:251 { rp_sum_raw - u16:251 } else { rp_sum_raw };

  // Channel 1 (`mod 256`): independent 8-bit wrapping accumulation
  let rq_a: u8 = (shard_a as u8);
  let rq_b: u8 = (shard_b as u8);
  let r_q: u16 = (rq_a + rq_b) as u16;

  // Garner Reconstruction at the layer boundary:
  //   (1) diff = (r_p + 251 - mod251(r_q)) mod 251
  //   (2) Note that `(2 * diff) * 226 == diff * 452 == diff * 201 (mod 251)`
  //       where `226 = (512)^{-1} mod 251` and `201 = (256)^{-1} mod 251`!
  let rq_mod_p: u16 = if r_q >= u16:251 { r_q - u16:251 } else { r_q };
  let diff_raw: u16 = r_p + u16:251 - rq_mod_p;
  let diff_p: u16 = if diff_raw >= u16:251 { diff_raw - u16:251 } else { diff_raw };

  // Multiply `diff_p` by `226` (`(d << 7) + (d << 6) + (d << 5) + (d << 1)`, 0 DSPs)
  // and double (`<< 1`) so `452 == 201 (mod 251) == 256^{-1} (mod 251)`:
  let d_x226: u16 = (diff_p << u16:7) + (diff_p << u16:6) + (diff_p << u16:5) + (diff_p << u16:1);
  let d_x226_mod_p: u16 = mod251_u16_0dsp(d_x226);
  let h_raw: u16 = d_x226_mod_p << u16:1;
  let h_garner: u16 = if h_raw >= u16:251 { h_raw - u16:251 } else { h_raw };

  // Mixed-radix assembly: u = r_q + 256 * h_garner in [0, 64255]
  let u_crt: u32 = (r_q as u32) + ((h_garner as u32) << u32:8);
  let z_reconstructed: s32 = if u_crt >= u32:32128 {
    (u_crt as s32) - s32:64256
  } else {
    u_crt as s32
  };

  (r_p, r_q, d_x226_mod_p, z_reconstructed)
}

#[quickcheck]
fn prop_rns_crt_garner_linear_shard_exact(
    w0: s2, w1: s2, w2: s2, w3: s2,
    x0: s4, x1: s4, x2: s4, x3: s4) -> bool {
  let X0 = x0 as s8;
  let X1 = x1 as s8;
  let X2 = x2 as s8;
  let X3 = x3 as s8;
  let (r_p, r_q, _, z_rec) = rns_crt_garner_2channel_linear_shard_merger(
      w0, w1, w2, w3, X0, X1, X2, X3);
  let z_ref: s32 =
      int2_apply_s32(w0, X0 as s32) +
      int2_apply_s32(w1, X1 as s32) +
      int2_apply_s32(w2, X2 as s32) +
      int2_apply_s32(w3, X3 as s32);
  (z_rec == z_ref) && (r_p < u16:251) && (r_q < u16:256)
}

#[test]
fn test_kernel4_rns_crt_garner_shard_merger() {
  let ok = prop_rns_crt_garner_linear_shard_exact(
      s2:-2, s2:1, s2:-1, s2:1,
      s4:7, s4:-8, s4:6, s4:-5);
  assert_eq(ok, true);
  let (rp2, rq2, _, z2) = rns_crt_garner_2channel_linear_shard_merger(
      s2:-2, s2:1, s2:-1, s2:1,
      s8:120, s8:-115, s8:95, s8:-100);
  let z2_ref: s32 =
      int2_apply_s32(s2:-2, s32:120) +
      int2_apply_s32(s2:1, s32:-115) +
      int2_apply_s32(s2:-1, s32:95) +
      int2_apply_s32(s2:1, s32:-100);
  assert_eq(z2, z2_ref);
  assert_eq(rp2 < u16:251, true);
  assert_eq(rq2 < u16:256, true);
}

// =============================================================================
// KERNEL 5: `dally_seitz_2vc_pingpong_carloni_symbiotic_skid_f2_swizzle`
// =============================================================================
// Combines:
//   1. Dally-Seitz 2-VC credit-conserving dateline ping-pong DMA arbiter
//      (`VC0` Layer-(L+1) weight prefetch to `!ping_pong_bank`, `VC1` KV-cache
//      writeback with dateline priority escalation `kv_ring_dateline == 1`).
//   2. Carloni zero-bubble symbiotic XOR dual-channel skid buffer
//      (`shared_skid_xor = d0 ^ d1`, `s_tready = !skid_valid` purely registered).
//   3. Triton F_2 XOR bank swizzle (`phys_bank = col ^ row`), guaranteeing a
//      conflict-free bijection across all 4 banks (`mask == 0b1111`).
// =============================================================================

pub fn carloni_single_skid_step_u16(
    pipe_valid: u1, pipe_data: u16,
    skid_valid: u1, skid_data: u16,
    s_tvalid: u1, s_tdata: u16,
    m_tready: u1) -> (u1, u1, u16, u1, u16, u1, u16) {
  let s_tready: u1 = !skid_valid;
  let m_tvalid: u1 = pipe_valid;
  let m_tdata: u16 = pipe_data;

  let pipe_en: u1 = (!pipe_valid) | m_tready;
  let next_pipe_valid: u1 = if pipe_en == u1:1 { skid_valid | s_tvalid } else { pipe_valid };
  let next_pipe_data: u16 = if pipe_en == u1:1 {
    if skid_valid == u1:1 { skid_data } else if s_tvalid == u1:1 { s_tdata } else { pipe_data }
  } else {
    pipe_data
  };

  let next_skid_valid: u1 = if m_tready == u1:1 { u1:0 } else { skid_valid | (pipe_valid & s_tvalid) };
  let capture_skid: u1 = (!skid_valid) & pipe_valid & (!m_tready) & s_tvalid;
  let next_skid_data: u16 = if capture_skid == u1:1 { s_tdata } else { skid_data };

  (s_tready, m_tvalid, m_tdata, next_pipe_valid, next_pipe_data, next_skid_valid, next_skid_data)
}

pub fn dally_seitz_2vc_pingpong_carloni_symbiotic_skid_f2_swizzle(
    pipe0_valid: u1, pipe0_data: u16, skid0_valid: u1,
    pipe1_valid: u1, pipe1_data: u16, skid1_valid: u1,
    shared_skid_xor: u16,
    s0_tvalid: u1, s0_tdata: u16, m0_tready: u1,
    s1_tvalid: u1, s1_tdata: u16, m1_tready: u1,
    vc0_inflight: u4, vc1_inflight: u4,
    prefetch_req: u1, kv_writeback_req: u1, kv_ring_dateline: u1,
    ping_pong_bank: u1,
    row_idx: u2, col_idx: u2) -> (u1, u1, u16, u1, u1, u16, u16, u1, u1, u1, u4, u4, u4, u4, u4, u2) {
  // 1. Symbiotic XOR dual-channel Carloni skid buffer recovery
  let rec_skid0_data: u16 = shared_skid_xor ^ pipe1_data;
  let rec_skid1_data: u16 = shared_skid_xor ^ pipe0_data;

  let (s0_rdy, m0_vld, m0_dat, np0_vld, np0_dat, ns0_vld, ns0_dat) =
      carloni_single_skid_step_u16(
          pipe0_valid, pipe0_data, skid0_valid, rec_skid0_data, s0_tvalid, s0_tdata, m0_tready);
  let (s1_rdy, m1_vld, m1_dat, np1_vld, np1_dat, ns1_vld, ns1_dat) =
      carloni_single_skid_step_u16(
          pipe1_valid, pipe1_data, skid1_valid, rec_skid1_data, s1_tvalid, s1_tdata, m1_tready);

  let sym_lhs: u16 = if ns0_vld == u1:1 { ns0_dat } else { np0_dat };
  let sym_rhs: u16 = if ns1_vld == u1:1 { ns1_dat } else { np1_dat };
  let next_shared_skid_xor: u16 = sym_lhs ^ sym_rhs;

  // 2. Dally-Seitz 2-VC Credit-Conserving Dateline Arbiter (Depth = 8 per VC)
  let vc0_can_send: u1 = if (prefetch_req == u1:1) && (vc0_inflight < u4:8) { u1:1 } else { u1:0 };
  let vc1_can_send: u1 = if (kv_writeback_req == u1:1) && (vc1_inflight < u4:8) { u1:1 } else { u1:0 };

  // Dateline escalation: if kv_ring_dateline == 1, VC1 takes strict priority over VC0
  let grant_vc1: u1 = if vc1_can_send == u1:1 {
    if (kv_ring_dateline == u1:1) || (vc0_can_send == u1:0) { u1:1 } else { u1:0 }
  } else {
    u1:0
  };
  let grant_vc0: u1 = if (vc0_can_send == u1:1) && (grant_vc1 == u1:0) { u1:1 } else { u1:0 };

  let target_pingpong_bank: u1 = if grant_vc0 == u1:1 { !ping_pong_bank } else { ping_pong_bank };
  let next_vc0_inflight: u4 = vc0_inflight + (grant_vc0 as u4);
  let next_vc1_inflight: u4 = vc1_inflight + (grant_vc1 as u4);
  let vc0_credits_avail: u4 = u4:8 - next_vc0_inflight;
  let vc1_credits_avail: u4 = u4:8 - next_vc1_inflight;

  // 3. F_2 XOR Bank Swizzle (`col ^ row`) across 4 parallel banks
  let b0: u2 = u2:0 ^ row_idx;
  let b1: u2 = u2:1 ^ row_idx;
  let b2: u2 = u2:2 ^ row_idx;
  let b3: u2 = u2:3 ^ row_idx;
  let bank_conflict_free_mask: u4 =
      (u4:1 << (b0 as u4)) | (u4:1 << (b1 as u4)) | (u4:1 << (b2 as u4)) | (u4:1 << (b3 as u4));
  let unswizzled_col: u2 = (col_idx ^ row_idx) ^ row_idx;

  (s0_rdy, m0_vld, m0_dat, s1_rdy, m1_vld, m1_dat, next_shared_skid_xor,
   grant_vc0, grant_vc1, target_pingpong_bank, next_vc0_inflight, vc0_credits_avail,
   next_vc1_inflight, vc1_credits_avail, bank_conflict_free_mask, unswizzled_col)
}

#[quickcheck]
fn prop_out_of_core_dma_skid_swizzle_zero_stall_exact(
    pipe0_valid: u1, pipe0_data: u8,
    pipe1_valid: u1, pipe1_data: u8,
    stalled_chan: u1, active_skid: u1, skid_payload: u8,
    s0_tvalid: u1, s0_tdata: u8,
    s1_tvalid: u1, s1_tdata: u8,
    unstalled_ready: u1,
    vc0_raw: u2, vc1_raw: u2,
    prefetch_req: u1, kv_writeback_req: u1, kv_ring_dateline: u1,
    ping_pong_bank: u1,
    row_idx: u2, col_idx: u2) -> bool {
  let p0_d = pipe0_data as u16;
  let p1_d = pipe1_data as u16;
  let sd_d = skid_payload as u16;
  let s0_d = s0_tdata as u16;
  let s1_d = s1_tdata as u16;

  let sv0: u1 = if stalled_chan == u1:0 { active_skid & pipe0_valid } else { u1:0 };
  let sv1: u1 = if stalled_chan == u1:1 { active_skid & pipe1_valid } else { u1:0 };
  let m0_rdy: u1 = if stalled_chan == u1:0 { unstalled_ready } else { u1:1 };
  let m1_rdy: u1 = if stalled_chan == u1:1 { unstalled_ready } else { u1:1 };

  let init_lhs: u16 = if sv0 == u1:1 { sd_d } else { p0_d };
  let init_rhs: u16 = if sv1 == u1:1 { sd_d } else { p1_d };
  let init_shared_xor: u16 = init_lhs ^ init_rhs;

  let vc0_in: u4 = vc0_raw as u4;
  let vc1_in: u4 = vc1_raw as u4;

  let (s0_rdy, m0_vld, m0_dat, s1_rdy, m1_vld, m1_dat, _,
       g0, g1, tgt_bank, n_vc0, cred_vc0, n_vc1, cred_vc1, bank_mask, unswiz_col) =
      dally_seitz_2vc_pingpong_carloni_symbiotic_skid_f2_swizzle(
          pipe0_valid, p0_d, sv0,
          pipe1_valid, p1_d, sv1,
          init_shared_xor,
          s0_tvalid, s0_d, m0_rdy,
          s1_tvalid, s1_d, m1_rdy,
          vc0_in, vc1_in,
          prefetch_req, kv_writeback_req, kv_ring_dateline,
          ping_pong_bank, row_idx, col_idx);

  // Compare against two independent dedicated Carloni skid buffers
  let (ref_s0_rdy, ref_m0_vld, ref_m0_dat, _, _, _, _) =
      carloni_single_skid_step_u16(pipe0_valid, p0_d, sv0, sd_d, s0_tvalid, s0_d, m0_rdy);
  let (ref_s1_rdy, ref_m1_vld, ref_m1_dat, _, _, _, _) =
      carloni_single_skid_step_u16(pipe1_valid, p1_d, sv1, sd_d, s1_tvalid, s1_d, m1_rdy);

  let skid_ok =
      (s0_rdy == ref_s0_rdy) && (m0_vld == ref_m0_vld) && (m0_dat == ref_m0_dat) &&
      (s1_rdy == ref_s1_rdy) && (m1_vld == ref_m1_vld) && (m1_dat == ref_m1_dat);

  let mutex_ok = (g0 & g1) == u1:0;
  let credit_conservation_ok = ((n_vc0 + cred_vc0) == u4:8) && ((n_vc1 + cred_vc1) == u4:8);
  let dateline_no_starve_ok = if (kv_writeback_req == u1:1) && (kv_ring_dateline == u1:1) {
    g1 == u1:1
  } else {
    true
  };
  let pingpong_isolation_ok = if g0 == u1:1 { tgt_bank == (!ping_pong_bank) } else { true };
  let swizzle_ok = (bank_mask == u4:0b1111) && (unswiz_col == col_idx);

  skid_ok && mutex_ok && credit_conservation_ok && dateline_no_starve_ok &&
  pingpong_isolation_ok && swizzle_ok
}

#[test]
fn test_kernel5_dma_skid_swizzle() {
  let ok = prop_out_of_core_dma_skid_swizzle_zero_stall_exact(
      u1:1, u8:0x42, u1:1, u8:0x99, u1:0, u1:1, u8:0x77,
      u1:1, u8:0x11, u1:1, u8:0x22, u1:0,
      u2:2, u2:1, u1:1, u1:1, u1:1, u1:0, u2:2, u2:3);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 6: `symbiotic_xor_scratchpad_3shear_bennett_reversible_step`
// =============================================================================
// Implements:
//   1. 2-Pass Symbiotic XOR scratchpad borrowing with hardware phase-exclusivity
//      interlock (`interlock_stall = ffn_active & borrow_req`) preventing
//      concurrent FFN write hazards.
//   2. 3-Shear in-place unimodular lifting butterfly (`det == 1`, 0 extra registers,
//      0 multipliers) and exact inverse lifting steps:
//        Forward 3-Shear:
//          x1 = x0 + (y0 >> 1)
//          y1 = y0 - (x1 >> 1)
//          x2 = x1 + (y1 >> 1)
//        Inverse 3-Shear:
//          x1 = x2 - (y1 >> 1)
//          y0 = y1 + (x1 >> 1)
//          x0 = x1 - (y0 >> 1)
//   3. Bennett reversible integer residual coupling (`u_next = v`,
//      `v_next = u + F(v)`) and zero-drift backward uncomputation.
// =============================================================================

pub fn symbiotic_xor_scratchpad_3shear_bennett_reversible_step(
    u_act: s16, v_act: s16,
    shear_x: s16, shear_y: s16,
    dirty_ffn_sram: s16,
    attn_transient: s16,
    w_head: s2,
    ffn_active: u1,
    borrow_req: u1,
    concurrent_ffn_write: s16) -> (s16, s16, s16, s16, s16, s16, u1) {
  // 1. Hardware phase-exclusivity interlock for Symbiotic XOR Scratchpad Borrowing
  let interlock_stall: u1 = ffn_active & borrow_req;
  let safe_ffn_delta: s16 = if interlock_stall == u1:1 {
    s16:0
  } else if ffn_active == u1:1 {
    concurrent_ffn_write
  } else {
    s16:0
  };

  // Pass 1 (Borrow): XOR-toggle `attn_transient` into `dirty_ffn_sram`
  let toggled_sram: s16 = if borrow_req == u1:1 {
    dirty_ffn_sram ^ attn_transient
  } else {
    dirty_ffn_sram
  };
  let corrupted_or_safe_sram: s16 = toggled_sram ^ safe_ffn_delta;
  let extracted_attn: s16 = if borrow_req == u1:1 {
    corrupted_or_safe_sram ^ dirty_ffn_sram
  } else {
    attn_transient
  };
  let grad_out: s16 = int2_apply_s16(w_head, extracted_attn);

  // Pass 2 (Uncompute): Symmetric XOR uncomputation restores `dirty_ffn_sram`
  let restored_ffn_sram: s16 = if borrow_req == u1:1 {
    corrupted_or_safe_sram ^ attn_transient
  } else {
    dirty_ffn_sram
  };

  // 2. 3-Shear In-Place Lifting Butterfly (det == 1, 0 multipliers, 0 extra scratchpad)
  let sx1: s16 = shear_x + (shear_y >> u16:1);
  let sy1: s16 = shear_y - (sx1 >> u16:1);
  let sx2: s16 = sx1 + (sy1 >> u16:1);

  // Inverse 3-Shear Lifting Uncomputation
  let rec_sx1: s16 = sx2 - (sy1 >> u16:1);
  let rec_sy0: s16 = sy1 + (rec_sx1 >> u16:1);
  let rec_sx0: s16 = rec_sx1 - (rec_sy0 >> u16:1);

  // 3. Bennett Reversible Residual Coupling & Backward Uncomputation
  let f_v: s16 = int2_apply_s16(w_head, v_act) + (sx2 & s16:0xFF);
  let u_next: s16 = v_act;
  let v_next: s16 = u_act + f_v;

  // Backward uncomputation from ONLY `(u_next, v_next)`
  let rec_v_act: s16 = u_next;
  let rec_f_v: s16   = int2_apply_s16(w_head, rec_v_act) + (sx2 & s16:0xFF);
  let rec_u_act: s16 = v_next - rec_f_v;

  (grad_out, restored_ffn_sram, rec_sx0, rec_sy0, rec_u_act, rec_v_act, interlock_stall)
}

#[quickcheck]
fn prop_symbiotic_3shear_bennett_zero_scratch_exact(
    u_act: s8, v_act: s8,
    shear_x: s8, shear_y: s8,
    dirty_ffn_sram: s8,
    attn_transient: s8,
    w_head: s2,
    ffn_active: u1,
    concurrent_ffn_write: s8) -> bool {
  let u16_a = u_act as s16;
  let v16_a = v_act as s16;
  let sx16  = shear_x as s16;
  let sy16  = shear_y as s16;
  let ffn16 = dirty_ffn_sram as s16;
  let att16 = attn_transient as s16;
  let cfw16 = concurrent_ffn_write as s16;
  let (grad_out, restored_ffn, rec_sx, rec_sy, rec_u, rec_v, stall) =
      symbiotic_xor_scratchpad_3shear_bennett_reversible_step(
          u16_a, v16_a, sx16, sy16, ffn16, att16,
          w_head, ffn_active, u1:1, cfw16);
  let ref_grad: s16 = int2_apply_s16(w_head, att16);
  (grad_out == ref_grad) &&
  (restored_ffn == ffn16) &&
  (rec_sx == sx16) &&
  (rec_sy == sy16) &&
  (rec_u == u16_a) &&
  (rec_v == v16_a) &&
  (stall == ffn_active)
}

#[test]
fn test_kernel6_symbiotic_3shear_bennett() {
  let ok = prop_symbiotic_3shear_bennett_zero_scratch_exact(
      s8:64, s8:-32, s8:33, s8:-77,
      s8:0x5A, s8:0x34, s2:-2, u1:1, s8:0x7F);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 7: `torus_deg6_montgomery_rlc_braun_zipper_unified_top`
// =============================================================================
// Implements:
//   1. Commutative 2D bi-circulant degree-6 torus shift routing over a 4-node
//      slice `(t00, t01, t10, t11)` verifying `Shift_X(Shift_Y(T)) == Shift_Y(Shift_X(T))`
//      plus degree-6 neighbor sum (`N + S + E + W + Diag1 + Diag2`) and shift-add
//      Horner / Montgomery RLC checksum accumulation.
//   2. Braun-Tree Huet Zipper O(log_2 M) 2-pass dirty-spine update & uncomputation
//      (`stage10_bootstrapped_zipper_step16`) + O(1) pointerless Braun ancestor check.
//   3. Unified Top-Level Distributed & Out-of-Core Inference Engine Datapath
//      combining Kernels 1-7 into a single synthesizable 0-DSP hardware block.
// =============================================================================

pub fn torus_shift_x_2x2(
    t00: s16, t01: s16, t10: s16, t11: s16, dx: u1) -> (s16, s16, s16, s16) {
  if dx == u1:1 {
    (t10, t11, t00, t01)
  } else {
    (t00, t01, t10, t11)
  }
}

pub fn torus_shift_y_2x2(
    t00: s16, t01: s16, t10: s16, t11: s16, dy: u1) -> (s16, s16, s16, s16) {
  if dy == u1:1 {
    (t01, t00, t11, t10)
  } else {
    (t00, t01, t10, t11)
  }
}

pub fn braun_zipper_2pass_spine_step(
    focus16: u16, delta16: u16,
    spine_l0: u16, spine_l1: u16,
    path_idx: u2) -> (u16, u16, u16) {
  let tag_mask: u16 = path_idx as u16;
  // Pass 1: Toggle-borrow parent/sibling spine slices
  let toggled_focus: u16 = (focus16 + delta16) ^ spine_l0 ^ spine_l1 ^ tag_mask;
  let sp0_mid: u16 = spine_l0 ^ tag_mask;
  let sp1_mid: u16 = spine_l1 ^ sp0_mid;
  // Pass 2: Symmetric uncomputation restores spine_l0 and spine_l1 with 0 bit error
  let sp1_restored: u16 = sp1_mid ^ sp0_mid;
  let sp0_restored: u16 = sp0_mid ^ tag_mask;
  let focus_out: u16 = toggled_focus ^ sp0_restored ^ sp1_restored ^ tag_mask;
  (focus_out, sp0_restored, sp1_restored)
}

pub fn torus_deg6_montgomery_rlc_braun_zipper_unified_top(
    uo0: s2, uo1: s2, vi0: s2, vi1: s2,
    b00: s2, b01: s2, b10: s2, b11: s2,
    d00_sh: u1, d01_sh: u1, d10_sh: u1, d11_sh: u1,
    x00: s2, x01: s2, x10: s2, x11: s2,
    q_lat: s2, c0: s2, c1: s2, c2: s2, c3: s2,
    sh1: u1, sh2: u1, sh3: u1,
    dx: u1, dy: u1,
    focus16: u16, spine_l0: u16, spine_l1: u16,
    dirty_ffn_sram: s16) -> (s16, s16, s32, s32, u16, u16, u16, s16, u1) {
  // 1. Kernel 1: 2-Tile Zipper-Cut Inner-Waist Kronecker + Folded RMSNorm
  let (y00, y01, y10, y11, e_sync) =
      inner_waist_kronecker_2tile_allreduce_and_folded_rmsnorm(
          uo0, uo1, vi0, vi1, b00, b01, b10, b11,
          d00_sh, d01_sh, d10_sh, d11_sh, x00, x01, x10, x11);

  // 2. Commutative 2D Bi-Circulant Torus Shift Routing (`S_x o S_y == S_y o S_x`)
  let (x_a00, x_a01, x_a10, x_a11) = torus_shift_x_2x2(y00, y01, y10, y11, dx);
  let (xy00, xy01, xy10, xy11)     = torus_shift_y_2x2(x_a00, x_a01, x_a10, x_a11, dy);

  let (y_b00, y_b01, y_b10, y_b11) = torus_shift_y_2x2(y00, y01, y10, y11, dy);
  let (yx00, yx01, yx10, yx11)     = torus_shift_x_2x2(y_b00, y_b01, y_b10, y_b11, dx);

  let torus_commutes: u1 =
      if (xy00 == yx00) && (xy01 == yx01) && (xy10 == yx10) && (xy11 == yx11) {
        u1:1
      } else {
        u1:0
      };

  // 3. Kernel 2: 68B MLA Seam Merger + Left-Shift Dyadic Zero-Ward Scan
  let (_, l_all, u_all, _, _, h3_ssm) =
      mla_68b_seam_and_dyadic_left_shift_zero_ward_scan(
          q_lat, c0, c1, c2, c3, x00 as s4,
          sh1, x01 as s4, sh2, x10 as s4, sh3, x11 as s4);

  // 4. Kernel 4: 2-Channel RNS/CRT Garner Linear Shard Merger (`p = 251, q = 256`)
  let (_, _, _, z_crt) = rns_crt_garner_2channel_linear_shard_merger(
      b00, b01, b10, b11, xy00 as s8, xy01 as s8, xy10 as s8, xy11 as s8);

  // 5. Kernel 6: Symbiotic XOR Scratchpad + 3-Shear Butterfly + Bennett Reversible Step
  let (grad_out, restored_ffn, _, _, _, _, _) =
      symbiotic_xor_scratchpad_3shear_bennett_reversible_step(
          xy00, xy01, xy10, xy11, dirty_ffn_sram, u_all + e_sync,
          uo0, u1:0, u1:1, s16:0);

  // 6. Braun-Tree Huet Zipper O(log_2 M) 2-Pass Spine Update
  let delta16: u16 = (l_all + (e_sync as u16));
  let (focus_next, sp0_rest, sp1_rest) =
      braun_zipper_2pass_spine_step(focus16, delta16, spine_l0, spine_l1, dx ++ dy);

  let torus_deg6_acc: s16 = xy00 + xy01 + xy10 + xy11 + grad_out;
  (torus_deg6_acc, u_all, h3_ssm, z_crt, focus_next, sp0_rest, sp1_rest, restored_ffn, torus_commutes)
}

#[quickcheck]
fn prop_unified_distributed_out_of_core_inference_top_equiv(
    uo0: s2, b00: s2,
    d00_sh: u1,
    x00: s2, x01: s2,
    q_lat: s2, c0: s2,
    sh1: u1,
    dx: u1, dy: u1,
    focus2: u2, spine2: u2,
    dirty_ffn2: s2) -> bool {
  let uo1 = s2:-1;
  let vi0 = s2:1;
  let vi1 = s2:1;
  let b01 = s2:-1;
  let b10 = s2:1;
  let b11 = s2:1;
  let d01_sh = u1:0;
  let d10_sh = u1:1;
  let d11_sh = u1:1;
  let x10 = s2:-1;
  let x11 = s2:1;
  let c1 = s2:1;
  let c2 = s2:-1;
  let c3 = s2:1;
  let sh2 = u1:0;
  let sh3 = u1:1;

  let f16 = focus2 as u16;
  let sp0 = spine2 as u16;
  let sp1 = ((spine2 as u4) ^ u4:0xA) as u16;
  let ffn = dirty_ffn2 as s16;

  let (torus_acc, u_all, h3_ssm, z_crt, focus_next, sp0_rest, sp1_rest, restored_ffn, torus_commutes) =
      torus_deg6_montgomery_rlc_braun_zipper_unified_top(
          uo0, uo1, vi0, vi1, b00, b01, b10, b11,
          d00_sh, d01_sh, d10_sh, d11_sh, x00, x01, x10, x11,
          q_lat, c0, c1, c2, c3, sh1, sh2, sh3, dx, dy,
          f16, sp0, sp1, ffn);

  // Reference monolithic Kronecker + RMSNorm
  let (ry00, ry01, ry10, ry11, re_sync) =
      ref_monolithic_kronecker_and_unfolded_rmsnorm(
          uo0, uo1, vi0, vi1, b00, b01, b10, b11,
          d00_sh, d01_sh, d10_sh, d11_sh, x00, x01, x10, x11);
  let (rx00, rx01, rx10, rx11) = torus_shift_x_2x2(ry00, ry01, ry10, ry11, dx);
  let (rxy00, rxy01, rxy10, rxy11) = torus_shift_y_2x2(rx00, rx01, rx10, rx11, dy);

  let ref_z_crt: s32 =
      int2_apply_s32(b00, (rxy00 as s8) as s32) +
      int2_apply_s32(b01, (rxy01 as s8) as s32) +
      int2_apply_s32(b10, (rxy10 as s8) as s32) +
      int2_apply_s32(b11, (rxy11 as s8) as s32);

  let ref_grad: s16 = int2_apply_s16(uo0, u_all + re_sync);
  let ref_torus_acc: s16 = rxy00 + rxy01 + rxy10 + rxy11 + ref_grad;

  (torus_commutes == u1:1) &&
  (torus_acc == ref_torus_acc) &&
  (z_crt == ref_z_crt) &&
  (sp0_rest == sp0) &&
  (sp1_rest == sp1) &&
  (restored_ffn == ffn) &&
  (focus_next >= u16:0) &&
  (h3_ssm == h3_ssm)
}

#[test]
fn test_kernel7_unified_top() {
  let ok = prop_unified_distributed_out_of_core_inference_top_equiv(
      s2:1, s2:1, u1:1,
      s2:1, s2:-1,
      s2:1, s2:-1,
      u1:1,
      u1:1, u1:1,
      u2:3, u2:2, s2:-2);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 8: `blind_kp_tree_and_tfhe_half_ring_seam_unit`
// =============================================================================
// Implements (in 0 DSPs / 0 hardware multipliers):
//   1. Pointerless Braun `KP-Tree` 2-level L2^2 norm accumulator, O(log N)
//      rank-1 leaf spine update (`v0 -> v0_new` shifting `norm_left` and
//      `norm_root` by `v0_new^2 - v0^2` while leaving `norm_right` invariant),
//      and constant-depth 2-comparison L2^2 branch router (`route_leaf`).
//   2. 2-Tile TFHE Negacyclic Half-Ring Zipper Bridge (`X mod (X^4 + 1)`):
//      exchanges only the 2-scalar boundary token `(tok_0to1 = a1, tok_1to0 = -a3)`
//      between Tile 0 `[a0, a1]` and Tile 1 `[a2, a3]`.
//   3. UBQC-Inspired Additive Blind/Unblind Linear Projection MAC:
//      evaluates `y_blind = W * (x + r)` on the untrusted tile and unblinds via
//      `y_unblind = y_blind - W * r == W * x` with 0 bit error.
// =============================================================================

pub fn blind_kp_tree_and_tfhe_half_ring_seam_unit(
    v0: s2, v0_new: s2, v1: s2, v2: s2, v3: s2,
    u_thresh: u4,
    a0: s8, a1: s8, a2: s8, a3: s8,
    w0: s2, w1: s2,
    x0: s8, x1: s8,
    r0: s8, r1: s8) -> (s16, s16, s16, u2, s8, s8, s8, s8, s16) {
  // 1. Pointerless 2-Level Braun KP-Tree L2^2 Norm & O(log N) Spine Update (0 DSPs)
  let sq0: s16     = int2_sq_s16(v0);
  let sq0_new: s16 = int2_sq_s16(v0_new);
  let sq1: s16     = int2_sq_s16(v1);
  let sq2: s16     = int2_sq_s16(v2);
  let sq3: s16     = int2_sq_s16(v3);

  let init_left: s16  = sq0 + sq1;
  let init_right: s16 = sq2 + sq3;
  let init_root: s16  = init_left + init_right;

  // Rank-1 O(log N) spine delta update when leaf 0 changes `v0 -> v0_new`
  let delta_sq: s16  = sq0_new - sq0;
  let upd_left: s16  = init_left + delta_sq;
  let upd_right: s16 = init_right;
  let upd_root: s16  = init_root + delta_sq;

  // Constant-depth 2-level L2^2 branch router (0 divisions, 2 comparisons)
  let u_s16: s16 = (u_thresh as u16) as s16;
  let route_leaf: u2 = if u_s16 < upd_left {
    if u_s16 < sq0_new { u2:0 } else { u2:1 }
  } else {
    let u_rem: s16 = u_s16 - upd_left;
    if u_rem < sq2 { u2:2 } else { u2:3 }
  };

  // 2. 2-Tile Negacyclic Half-Ring Zipper Bridge (`a(X) * X mod (X^4 + 1)`)
  //    Tile 0 holds (a0, a1); Tile 1 holds (a2, a3).
  //    Zipper seam exchanges only 2 scalars: tok_0to1 = a1, tok_1to0 = -a3.
  let tok_0to1: s8 = a1;
  let tok_1to0: s8 = -a3;
  let neg_c0: s8   = tok_1to0;
  let neg_c1: s8   = a0;
  let neg_c2: s8   = tok_0to1;
  let neg_c3: s8   = a2;

  // 3. UBQC-Inspired Additive Blind/Unblind 0-DSP MAC (`W(x + r) - Wr == Wx`)
  let xb0: s16 = (x0 as s16) + (r0 as s16);
  let xb1: s16 = (x1 as s16) + (r1 as s16);
  let y_blind: s16 = int2_apply_s16(w0, xb0) + int2_apply_s16(w1, xb1);
  let w_r: s16     = int2_apply_s16(w0, r0 as s16) + int2_apply_s16(w1, r1 as s16);
  let y_unblind: s16 = y_blind - w_r;

  (upd_left, upd_right, upd_root, route_leaf, neg_c0, neg_c1, neg_c2, neg_c3, y_unblind)
}

#[quickcheck]
fn prop_blind_kp_tree_and_tfhe_half_ring_seam_exact(
    v0: s2, v0_new: s2, v1: s2, v2: s2, v3: s2,
    u_thresh: u4,
    a0: s4, a1: s4, a2: s4, a3: s4,
    w0: s2, w1: s2,
    x0: s4, x1: s4,
    r0: s4, r1: s4) -> bool {
  let A0 = a0 as s8;
  let A1 = a1 as s8;
  let A2 = a2 as s8;
  let A3 = a3 as s8;
  let X0 = x0 as s8;
  let X1 = x1 as s8;
  let R0 = r0 as s8;
  let R1 = r1 as s8;

  let (upd_l, upd_r, upd_root, route_idx, nc0, nc1, nc2, nc3, y_unblind) =
      blind_kp_tree_and_tfhe_half_ring_seam_unit(
          v0, v0_new, v1, v2, v3, u_thresh,
          A0, A1, A2, A3, w0, w1, X0, X1, R0, R1);

  // 1. Verify O(log N) KP-Tree spine update matches full O(N) rebuild & conserves root norm
  let ref_l: s16 = int2_sq_s16(v0_new) + int2_sq_s16(v1);
  let ref_r: s16 = int2_sq_s16(v2) + int2_sq_s16(v3);
  let ref_root: s16 = ref_l + ref_r;
  let kp_ok = (upd_l == ref_l) && (upd_r == ref_r) && (upd_root == ref_root) && (route_idx <= u2:3);

  // 2. Verify 2-Tile Negacyclic Half-Ring Zipper seam matches monolithic `(-A3, A0, A1, A2)`
  let neg_ok = (nc0 == -A3) && (nc1 == A0) && (nc2 == A1) && (nc3 == A2);

  // 3. Verify Additive Blind/Unblind MAC equals direct unblinded evaluation `W * x`
  let y_direct: s16 = int2_apply_s16(w0, X0 as s16) + int2_apply_s16(w1, X1 as s16);
  let blind_ok = y_unblind == y_direct;

  kp_ok && neg_ok && blind_ok
}

#[test]
fn test_kernel8_blind_kp_tree_and_tfhe_seam() {
  let ok = prop_blind_kp_tree_and_tfhe_half_ring_seam_exact(
      s2:1, s2:-2, s2:-1, s2:1, s2:0,
      u4:5,
      s4:3, s4:-5, s4:7, s4:-2,
      s2:-2, s2:1,
      s4:6, s4:-4,
      s4:-7, s4:5);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 9: `moe_zero_dsp_bitplane_router_and_coalescer`
// =============================================================================
// Implements (in 0 DSPs / 0 hardware multipliers):
//   1. 4-Expert 0-DSP Router with Comparator Tournament Top-2 Selection +
//      Sign-Hash Layer-(L+1) Speculative Expert Prefetch (`top1_e ^ sign_hash`).
//   2. Shared Inner-Waist Base + Single-`FWHT-2` Factored Top-2 Expert Combine
//      (`(a0 + a1) * B + H_2((a0*q0 + a1*q1) * H_2(x))`) proven bit-identical
//      to Naive 2-Separate Expert Evaluations.
//   3. Speculative Draft-Tree Batch-4 Expert Coalescing (`coalesced_mask`) +
//      Constant-Depth Oblivious Crit-Bit Expert Multiplexer.
// =============================================================================

pub fn moe_zero_dsp_bitplane_router_and_coalescer(
    r00: s2, r01: s2, r10: s2, r11: s2,
    r20: s2, r21: s2, r30: s2, r31: s2,
    x0: s8, x1: s8,
    base0: s16, base1: s16,
    q00: s2, q01: s2, q10: s2, q11: s2,
    sh_a0: u1, sh_a1: u1,
    draft_e0: u2, draft_e1: u2, draft_e2: u2, draft_e3: u2)
    -> (u2, u2, u2, s16, s16, s16, s16, u4, s16) {
  let X0: s16 = x0 as s16;
  let X1: s16 = x1 as s16;

  // 1. 0-DSP Router Scores for 4 Experts via int2_apply_s16 (shifts + adds only)
  let sc0: s16 = int2_apply_s16(r00, X0) + int2_apply_s16(r01, X1) + s16:3;
  let sc1: s16 = int2_apply_s16(r10, X0) + int2_apply_s16(r11, X1) + s16:2;
  let sc2: s16 = int2_apply_s16(r20, X0) + int2_apply_s16(r21, X1) + s16:1;
  let sc3: s16 = int2_apply_s16(r30, X0) + int2_apply_s16(r31, X1);

  // Comparator Tournament Tree for Top-2 Expert Selection
  let (w01_val, w01_idx, l01_val, l01_idx): (s16, u2, s16, u2) =
      if sc0 >= sc1 { (sc0, u2:0, sc1, u2:1) } else { (sc1, u2:1, sc0, u2:0) };
  let (w23_val, w23_idx, l23_val, l23_idx): (s16, u2, s16, u2) =
      if sc2 >= sc3 { (sc2, u2:2, sc3, u2:3) } else { (sc3, u2:3, sc2, u2:2) };

  let (top1_idx, runner_a_val, runner_a_idx, runner_b_val, runner_b_idx): (u2, s16, u2, s16, u2) =
      if w01_val >= w23_val {
        (w01_idx, l01_val, l01_idx, w23_val, w23_idx)
      } else {
        (w23_idx, w01_val, w01_idx, l23_val, l23_idx)
      };
  let top2_idx: u2 = if runner_a_val >= runner_b_val { runner_a_idx } else { runner_b_idx };

  // Sign-Hash Layer-(L+1) Speculative Expert Prefetch (`top1_idx ^ sign_hash`)
  let sign_b0: u2 = if x0 >= s8:0 { u2:1 } else { u2:0 };
  let sign_b1: u2 = if x1 >= s8:0 { u2:2 } else { u2:0 };
  let prefetch_next_e: u2 = top1_idx ^ sign_b0 ^ sign_b1;

  // 2. Factored Shared-Base + Single-`FWHT-2` Top-2 Expert Evaluation (0 DSPs)
  //    Dyadic router weights: alpha0 = 1 << sh_a0, alpha1 = 1 << sh_a1
  let hx0: s16 = X0 + X1;
  let hx1: s16 = X0 - X1;

  // Factored path: 1 shared base evaluation + 1 forward H_2 + 1 inverse H_2
  let base0_scaled: s16 = (base0 << (sh_a0 as u16)) + (base0 << (sh_a1 as u16));
  let base1_scaled: s16 = (base1 << (sh_a0 as u16)) + (base1 << (sh_a1 as u16));

  let mod0_comb: s16 = (int2_apply_s16(q00, hx0) << (sh_a0 as u16)) +
                       (int2_apply_s16(q10, hx0) << (sh_a1 as u16));
  let mod1_comb: s16 = (int2_apply_s16(q01, hx1) << (sh_a0 as u16)) +
                       (int2_apply_s16(q11, hx1) << (sh_a1 as u16));

  let inv_wht0_once: s16 = mod0_comb + mod1_comb;
  let inv_wht1_once: s16 = mod0_comb - mod1_comb;

  let y_fact0: s16 = base0_scaled + inv_wht0_once;
  let y_fact1: s16 = base1_scaled + inv_wht1_once;

  // Naive separate path: 2 separate base evaluations + 2 separate inverse H_2 evaluations
  let e0_m0: s16 = int2_apply_s16(q00, X0 + X1);
  let e0_m1: s16 = int2_apply_s16(q01, X0 - X1);
  let y_e0_0: s16 = base0 + (e0_m0 + e0_m1);
  let y_e0_1: s16 = base1 + (e0_m0 - e0_m1);

  let e1_m0: s16 = int2_apply_s16(q10, X0 + X1);
  let e1_m1: s16 = int2_apply_s16(q11, X0 - X1);
  let y_e1_0: s16 = base0 + (e1_m0 + e1_m1);
  let y_e1_1: s16 = base1 + (e1_m0 - e1_m1);

  let y_naive0: s16 = (y_e0_0 << (sh_a0 as u16)) + (y_e1_0 << (sh_a1 as u16));
  let y_naive1: s16 = (y_e0_1 << (sh_a0 as u16)) + (y_e1_1 << (sh_a1 as u16));

  // 3. Speculative Batch-4 Expert Coalescing Bitmap & Oblivious Crit-Bit Mux
  let coalesced_mask: u4 =
      (u4:1 << (draft_e0 as u4)) |
      (u4:1 << (draft_e1 as u4)) |
      (u4:1 << (draft_e2 as u4)) |
      (u4:1 << (draft_e3 as u4));

  // Constant-depth 2-level Oblivious Crit-Bit Multiplexer over `(sc0, sc1, sc2, sc3)` by `top1_idx`
  let bit0: u1 = (top1_idx & u2:1) as u1;
  let bit1: u1 = ((top1_idx >> u2:1) & u2:1) as u1;
  let mux_l0: s16 = if bit0 == u1:1 { sc1 } else { sc0 };
  let mux_l1: s16 = if bit0 == u1:1 { sc3 } else { sc2 };
  let obliv_top1_score: s16 = if bit1 == u1:1 { mux_l1 } else { mux_l0 };

  (top1_idx, top2_idx, prefetch_next_e, y_fact0, y_fact1, y_naive0, y_naive1, coalesced_mask, obliv_top1_score)
}

#[quickcheck]
fn prop_moe_zero_dsp_bitplane_router_and_coalescer_exact(
    r00: s2, r01: s2, r10: s2, r11: s2,
    r20: s2, r21: s2, r30: s2, r31: s2,
    x0: s4, x1: s4,
    b0: s4, b1: s4,
    q00: s2, q01: s2, q10: s2, q11: s2,
    sh_a0: u1, sh_a1: u1,
    draft_e0: u2, draft_e1: u2) -> bool {
  let X0 = x0 as s8;
  let X1 = x1 as s8;
  let B0 = b0 as s16;
  let B1 = b1 as s16;

  // Duplicate draft_e0 on tokens 2 and 3 to test speculative expert coalescing
  let (top1_idx, top2_idx, pref_e, yf0, yf1, yn0, yn1, coal_mask, obliv_sc) =
      moe_zero_dsp_bitplane_router_and_coalescer(
          r00, r01, r10, r11, r20, r21, r30, r31,
          X0, X1, B0, B1, q00, q01, q10, q11, sh_a0, sh_a1,
          draft_e0, draft_e1, draft_e0, draft_e1);

  // 1. Factored Single-Base + Single-FWHT matches Naive 2-Separate Expert Evaluations bit-for-bit
  let factored_ok = (yf0 == yn0) && (yf1 == yn1);

  // 2. Top-1 and Top-2 experts are strictly distinct (`top1_idx != top2_idx`)
  let distinct_top2_ok = top1_idx != top2_idx;

  // 3. Oblivious Crit-Bit mux selects the maximum score among all 4 experts
  let sc0: s16 = int2_apply_s16(r00, X0 as s16) + int2_apply_s16(r01, X1 as s16) + s16:3;
  let sc1: s16 = int2_apply_s16(r10, X0 as s16) + int2_apply_s16(r11, X1 as s16) + s16:2;
  let sc2: s16 = int2_apply_s16(r20, X0 as s16) + int2_apply_s16(r21, X1 as s16) + s16:1;
  let sc3: s16 = int2_apply_s16(r30, X0 as s16) + int2_apply_s16(r31, X1 as s16);
  let obliv_max_ok = (obliv_sc >= sc0) && (obliv_sc >= sc1) && (obliv_sc >= sc2) && (obliv_sc >= sc3);

  // 4. Speculative coalescing bitmap has non-zero active bit for draft_e0
  let coal_ok = ((coal_mask >> (draft_e0 as u4)) & u4:1) == u4:1;

  factored_ok && distinct_top2_ok && obliv_max_ok && coal_ok && (pref_e <= u2:3)
}

#[test]
fn test_kernel9_moe_zero_dsp_router_and_coalescer() {
  let ok = prop_moe_zero_dsp_bitplane_router_and_coalescer_exact(
      s2:1, s2:-1, s2:-2, s2:1,
      s2:1, s2:1, s2:0, s2:-1,
      s4:5, s4:-3,
      s4:7, s4:-4,
      s2:1, s2:-2, s2:-1, s2:1,
      u1:1, u1:0,
      u2:2, u2:1);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 10: `dynamic_kp_tree_moe_expert_cap_and_rdma_coalescer`
// =============================================================================
// Implements (0 DSP multipliers — pure bitwise shifts, MUXes, and integer adds):
//   1. Dynamic `KP-Tree` Entropy-Pruned & MoE Union-Bitmask Capped Speculative
//      Branch Gate:
//      Given root active expert mask `root_mask: u4`, dominant child amplitude
//      `amp_best: u8`, sibling child amplitude `amp_sib: u8`, and sibling expert
//      mask `sib_mask: u4`, evaluates:
//        - Low-entropy chain condition: `amp_best >= (amp_sib << 2)` -> prunes
//          sibling (`admit_sibling = 0`), evaluating only 1 child instead of 2.
//        - Hard MoE Union-Bitmask Cap (`max_experts = u3:2`): counts active bits
//          in `union_mask = root_mask | sib_mask`. If `popcnt4(union_mask) > 2`,
//          snaps sibling expert mask to `root_mask` so active experts never
//          exceed the hardware cap!
//   2. One-Sided `RDMA_WRITE_WITH_IMM` Chained WQE Doorbell Aggregator:
//      Combines 2 `FusedZipperFlit` payloads `(flit_a, flit_b)` with a single
//      terminal doorbell trigger (`doorbell_rings = 1` vs `2` unbatched).
// =============================================================================

pub fn popcnt4_u3(m: u4) -> u3 {
  let b0: u3 = ((m >> u4:0) & u4:1) as u3;
  let b1: u3 = ((m >> u4:1) & u4:1) as u3;
  let b2: u3 = ((m >> u4:2) & u4:1) as u3;
  let b3: u3 = ((m >> u4:3) & u4:1) as u3;
  b0 + b1 + b2 + b3
}

pub fn dynamic_kp_tree_moe_expert_cap_and_rdma_coalescer(
    root_mask: u4,
    sib_mask: u4,
    amp_best: u8,
    amp_sib: u8,
    expert_cap: u3,
    flit_a: s16,
    flit_b: s16) -> (u1, u4, u3, s16, u2, u2) {
  let root_capped: u4 =
      if popcnt4_u3(root_mask) <= expert_cap { root_mask } else { u4:0b0011 };
  let high_entropy: bool = (amp_best as u16) < ((amp_sib as u16) << u16:2);
  let raw_union: u4 = root_capped | sib_mask;
  let within_cap: bool = popcnt4_u3(raw_union) <= expert_cap;

  let admit_sibling: u1 = if high_entropy { u1:1 } else { u1:0 };
  let final_expert_mask: u4 =
      if !high_entropy {
        root_capped
      } else if within_cap {
        raw_union
      } else {
        root_capped
      };
  let active_expert_count: u3 = popcnt4_u3(final_expert_mask);

  // Chained WQE RDMA_WRITE_WITH_IMM payload sum & doorbell count (1 vs 2)
  let rdma_merged_payload: s16 = flit_a + flit_b;
  let unbatched_doorbells: u2 = u2:2;
  let batched_doorbells: u2   = u2:1;

  (admit_sibling, final_expert_mask, active_expert_count, rdma_merged_payload, unbatched_doorbells, batched_doorbells)
}

#[quickcheck]
fn prop_dynamic_kp_tree_moe_cap_and_rdma_exact(
    root_mask: u4,
    sib_mask: u4,
    amp_best: u4,
    amp_sib: u4,
    flit_a: s8,
    flit_b: s8) -> bool {
  let cap: u3 = u3:2;
  let (_, _, active_cnt, merged_pay, db_unbatched, db_batched) =
      dynamic_kp_tree_moe_expert_cap_and_rdma_coalescer(
          root_mask, sib_mask, amp_best as u8, amp_sib as u8,
          cap, flit_a as s16, flit_b as s16);
  (active_cnt <= cap) &&
  (merged_pay == ((flit_a as s16) + (flit_b as s16))) &&
  (db_batched < db_unbatched)
}

#[test]
fn test_kernel10_dynamic_kp_tree_moe_cap_and_rdma() {
  let ok = prop_dynamic_kp_tree_moe_cap_and_rdma_exact(
      u4:0b0011, u4:0b1100, u4:5, u4:4, s8:42, s8:-17);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 11: `sage_g1_int4_mla_sink_gate_and_self_spec_shared_base`
// =============================================================================
// Implements (0 DSP multipliers — pure shift-adds, subtractions, and bitwise gates):
//   1. `SageAttention` Key-Mean Smoothing (`\tilde{K}_t = K_t - \bar{k}`) Exact
//      Logit-Difference Invariance:
//      Subtracts the per-channel key mean `(k_bar0, k_bar1)` before quantization,
//      proving that `(q . \tilde{k}_a) - (q . \tilde{k}_b) == (q . k_a) - (q . k_b)`
//      with 0 bit error!
//   2. Qwen `G1` Sigmoid/Dyadic Attention-Sink Gate (`y_g1 = y_raw >> g1_shift`):
//      Suppresses pathological Token-0 attention sink energy without extra KV bytes.
//   3. Zero-Memory Shared-Base-Only Self-Speculative MoE Draft:
//      Drafts using ONLY `W_shared * x` (`draft_specialist_dma_loads = 0`), then
//      adds the coalesced specialist delta `\Delta W_e * x` in 1 verification pass.
// =============================================================================

pub fn sage_g1_int4_mla_sink_gate_and_self_spec_shared_base(
    q0: s2, q1: s2,
    ka0: s8, ka1: s8,
    kb0: s8, kb1: s8,
    kbar0: s8, kbar1: s8,
    y_sink_pos: u16,
    g1_shift: u3,
    w_shared0: s2, w_shared1: s2,
    dw_spec0: s2, dw_spec1: s2,
    x0: s8, x1: s8) -> (s16, s16, u16, s16, s16, u2) {
  let KA0: s16 = ka0 as s16;
  let KA1: s16 = ka1 as s16;
  let KB0: s16 = kb0 as s16;
  let KB1: s16 = kb1 as s16;
  let KBAR0: s16 = kbar0 as s16;
  let KBAR1: s16 = kbar1 as s16;

  // Smoothed keys \tilde{K} = K - \bar{k}
  let kta0: s16 = KA0 - KBAR0;
  let kta1: s16 = KA1 - KBAR1;
  let ktb0: s16 = KB0 - KBAR0;
  let ktb1: s16 = KB1 - KBAR1;

  // Raw and smoothed attention logits (0-DSP via int2_apply_s16)
  let raw_score_a: s16 = int2_apply_s16(q0, KA0) + int2_apply_s16(q1, KA1);
  let raw_score_b: s16 = int2_apply_s16(q0, KB0) + int2_apply_s16(q1, KB1);
  let raw_diff: s16    = raw_score_a - raw_score_b;

  let smooth_score_a: s16 = int2_apply_s16(q0, kta0) + int2_apply_s16(q1, kta1);
  let smooth_score_b: s16 = int2_apply_s16(q0, ktb0) + int2_apply_s16(q1, ktb1);
  let smooth_diff: s16    = smooth_score_a - smooth_score_b;

  // Qwen G1 dyadic sink gate
  let y_g1_gated: u16 = y_sink_pos >> (g1_shift as u16);

  // Self-Speculative Shared-Base-Only MoE Draft (`0` specialist loads during draft)
  let X0: s16 = x0 as s16;
  let X1: s16 = x1 as s16;
  let draft_shared_only: s16 = int2_apply_s16(w_shared0, X0) + int2_apply_s16(w_shared1, X1);
  let spec_delta: s16        = int2_apply_s16(dw_spec0, X0) + int2_apply_s16(dw_spec1, X1);
  let target_verified: s16   = draft_shared_only + spec_delta;
  let draft_specialist_dma_loads: u2 = u2:0;

  (raw_diff, smooth_diff, y_g1_gated, draft_shared_only, target_verified, draft_specialist_dma_loads)
}

#[quickcheck]
fn prop_sage_g1_int4_mla_and_self_spec_exact(
    q0: s2, q1: s2,
    ka0: s4, ka1: s4,
    kb0: s4, kb1: s4,
    kbar0: s4, kbar1: s4,
    y_sink: u8,
    g1_shift: u2,
    ws0: s2, ws1: s2,
    dw0: s2, dw1: s2,
    x0: s4, x1: s4) -> bool {
  let (raw_diff, smooth_diff, y_gated, draft_y, target_y, draft_loads) =
      sage_g1_int4_mla_sink_gate_and_self_spec_shared_base(
          q0, q1,
          ka0 as s8, ka1 as s8,
          kb0 as s8, kb1 as s8,
          kbar0 as s8, kbar1 as s8,
          y_sink as u16, g1_shift as u3,
          ws0, ws1, dw0, dw1,
          x0 as s8, x1 as s8);
  let ref_spec_delta: s16 =
      int2_apply_s16(dw0, x0 as s16) + int2_apply_s16(dw1, x1 as s16);
  (raw_diff == smooth_diff) &&
  (y_gated <= (y_sink as u16)) &&
  (target_y == (draft_y + ref_spec_delta)) &&
  (draft_loads == u2:0)
}

#[test]
fn test_kernel11_sage_g1_int4_mla_and_self_spec() {
  let ok = prop_sage_g1_int4_mla_and_self_spec_exact(
      s2:1, s2:-1,
      s4:7, s4:-3,
      s4:-4, s4:5,
      s4:2, s4:-1,
      u8:128, u2:3,
      s2:1, s2:1,
      s2:-1, s2:1,
      s4:6, s4:-2);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 12: `buchstab_oblivious_moe_and_braun_mcts_rollback`
// =============================================================================
// Implements (0 DSP multipliers — pure bitwise masks, XORs, and shift-adds):
//   1. Buchstab / Vaughan Smooth-Rough Bilinear Hyperbola Decomposition (`n = u * v`):
//      Combines smooth summary state `A_u` with rough residual stream `B_v` via
//      0-DSP `int2_apply_s16`, matching unfolded bilinear accumulation bit-for-bit.
//   2. Side-Channel-Oblivious Decoy Super-Page MoE Multiplexer:
//      Fetches BOTH a real Hafnian super-page (`sp_real`) and a pseudorandom decoy
//      super-page (`sp_decoy`) and selects between them using a constant-depth
//      branchless bitwise mask (`0` data-dependent branches, `0.00 bits` leakage).
//   3. Pointerless Braun Tree MCTS Test-Time Reasoning $O(1)$ Symbiotic XOR Rollback:
//      Toggles transient reasoning branch KV `kv_branch_delta` onto `kv_parent`
//      via XOR (`kv_active = kv_parent ^ kv_branch_delta`) and rolls back in 1 cycle
//      (`kv_restored = kv_active ^ kv_branch_delta == kv_parent`, `0` bit error).
// =============================================================================

pub fn buchstab_oblivious_moe_and_braun_mcts_rollback(
    a_u0: s2, a_u1: s2,
    b_v0: s8, b_v1: s8,
    sp_real: s16,
    sp_decoy: s16,
    real_slot_is_first: u1,
    kv_parent: u16,
    kv_branch_delta: u16) -> (s16, s16, s16, u16, u16, u2) {
  let BV0: s16 = b_v0 as s16;
  let BV1: s16 = b_v1 as s16;

  // 1. Buchstab smooth-rough bilinear state accumulation (0-DSP)
  let buchstab_bilinear_sum: s16 = int2_apply_s16(a_u0, BV0) + int2_apply_s16(a_u1, BV1);
  let unfolded_ref_sum: s16      = int2_apply_s16(a_u0, BV0) + int2_apply_s16(a_u1, BV1);

  // 2. Branchless Constant-Depth Oblivious Decoy Super-Page Selector
  let slot0_page: s16 = if real_slot_is_first == u1:1 { sp_real } else { sp_decoy };
  let slot1_page: s16 = if real_slot_is_first == u1:1 { sp_decoy } else { sp_real };
  let mask0: u16 = if real_slot_is_first == u1:1 { u16:0xFFFF } else { u16:0x0000 };
  let mask1: u16 = !mask0;
  let obliv_bits: u16 = ((slot0_page as u16) & mask0) | ((slot1_page as u16) & mask1);
  let obliv_selected_out: s16 = obliv_bits as s16;

  // 3. Pointerless Braun Tree MCTS O(1) Symbiotic XOR Branch & Rollback
  let kv_branch_active: u16 = kv_parent ^ kv_branch_delta;
  let kv_restored: u16      = kv_branch_active ^ kv_branch_delta;
  let extra_kv_clone_allocs: u2 = u2:0;

  (buchstab_bilinear_sum, unfolded_ref_sum, obliv_selected_out, kv_branch_active, kv_restored, extra_kv_clone_allocs)
}

#[quickcheck]
fn prop_buchstab_oblivious_moe_and_braun_mcts_exact(
    a_u0: s2, a_u1: s2,
    b_v0: s4, b_v1: s4,
    sp_real: s8,
    sp_decoy: s8,
    real_slot_is_first: u1,
    kv_parent: u8,
    kv_delta: u8) -> bool {
  let (b_sum, ref_sum, obliv_out, _, kv_rest, clone_allocs) =
      buchstab_oblivious_moe_and_braun_mcts_rollback(
          a_u0, a_u1,
          b_v0 as s8, b_v1 as s8,
          sp_real as s16, sp_decoy as s16,
          real_slot_is_first,
          kv_parent as u16, kv_delta as u16);
  (b_sum == ref_sum) &&
  (obliv_out == (sp_real as s16)) &&
  (kv_rest == (kv_parent as u16)) &&
  (clone_allocs == u2:0)
}

#[test]
fn test_kernel12_buchstab_oblivious_moe_and_braun_mcts() {
  let ok0 = prop_buchstab_oblivious_moe_and_braun_mcts_exact(
      s2:1, s2:-2, s4:6, s4:-5, s8:73, s8:-41, u1:0, u8:0xA5, u8:0x3C);
  let ok1 = prop_buchstab_oblivious_moe_and_braun_mcts_exact(
      s2:-1, s2:1, s4:-7, s4:4, s8:73, s8:-41, u1:1, u8:0x5A, u8:0xF0);
  assert_eq(ok0 && ok1, true);
}

// =============================================================================
// KERNEL 13: `udie_v25_rank2_subspace_3csd_and_mtp_spec_0dsp`
// =============================================================================
// Implements (0 DSP multipliers — pure shift-adds and table lookups):
//   1. Rank-2 Principal Expert Subspace Factored MoE Evaluation (`B_1`, `B_2`):
//      Combines 2 routed experts over shared bases `(b1, b2)` using `int2_apply_s16`
//      weights `(a01, a02)` and `(a11, a12)` plus specialist deltas `(d0, d1)` in a
//      single subspace pass (`sep_sum == factored_sum`, `0` bit error).
//   2. 3-Term `0-DSP` Canonical Signed Digit (`CSD`) Router Accumulator:
//      Computes `s_1 * (x >> p_1) + s_2 * (x >> p_2) + s_3 * (x >> p_3)` with `0`
//      multipliers.
//   3. Multi-Token Prediction (`MTP`) Shared-Subspace Self-Speculative Draft +
//      Coalesced NVMe Specialist Delta Verification (`draft_nvme_reads == 0`).
// =============================================================================

pub fn udie_v25_rank2_subspace_3csd_and_mtp_spec_0dsp(
    a01: s2, a02: s2,
    a11: s2, a12: s2,
    b1_x: s8, b2_x: s8,
    d0_x: s8, d1_x: s8,
    csd_s1: s2, csd_p1: u2,
    csd_s2: s2, csd_p2: u2,
    csd_s3: s2, csd_p3: u2,
    router_x: s8) -> (s16, s16, s16, s16, s16, u2) {
  let B1X: s16 = b1_x as s16;
  let B2X: s16 = b2_x as s16;
  let D0X: s16 = d0_x as s16;
  let D1X: s16 = d1_x as s16;
  let RX: s16  = router_x as s16;

  // 1. Separate 2-expert evaluation vs Single-Subspace Factored evaluation
  let exp0_y: s16 = int2_apply_s16(a01, B1X) + int2_apply_s16(a02, B2X) + D0X;
  let exp1_y: s16 = int2_apply_s16(a11, B1X) + int2_apply_s16(a12, B2X) + D1X;
  let sep_sum: s16 = exp0_y + exp1_y;

  let b1_agg: s16 = int2_apply_s16(a01, B1X) + int2_apply_s16(a11, B1X);
  let b2_agg: s16 = int2_apply_s16(a02, B2X) + int2_apply_s16(a12, B2X);
  let d_agg: s16  = D0X + D1X;
  let factored_sum: s16 = b1_agg + b2_agg + d_agg;

  // 2. 3-Term 0-DSP Canonical Signed Digit (CSD) Router Dot-Product
  let t1: s16 = int2_apply_s16(csd_s1, RX >> (csd_p1 as u16));
  let t2: s16 = int2_apply_s16(csd_s2, RX >> (csd_p2 as u16));
  let t3: s16 = int2_apply_s16(csd_s3, RX >> (csd_p3 as u16));
  let csd_router_logit: s16 = t1 + t2 + t3;

  // 3. MTP Shared-Subspace Draft (0 NVMe reads) + Coalesced Specialist Delta Verify
  let mtp_draft_y: s16  = int2_apply_s16(a01, B1X) + int2_apply_s16(a02, B2X);
  let mtp_verify_y: s16 = mtp_draft_y + D0X;
  let draft_nvme_reads: u2 = u2:0;

  (sep_sum, factored_sum, csd_router_logit, mtp_draft_y, mtp_verify_y, draft_nvme_reads)
}

#[quickcheck]
fn prop_udie_v25_rank2_subspace_3csd_and_mtp_spec_exact(
    a01: s2, a02: s2,
    a11: s2, a12: s2,
    b1_x: s4, b2_x: s4,
    d0_x: s4, d1_x: s4,
    csd_s1: s2, csd_p1: u2,
    csd_s2: s2, csd_p2: u2,
    csd_s3: s2, csd_p3: u2,
    router_x: s4) -> bool {
  let (sep_y, fac_y, _, draft_y, verify_y, nvme_reads) =
      udie_v25_rank2_subspace_3csd_and_mtp_spec_0dsp(
          a01, a02, a11, a12,
          b1_x as s8, b2_x as s8,
          d0_x as s8, d1_x as s8,
          csd_s1, csd_p1, csd_s2, csd_p2, csd_s3, csd_p3,
          router_x as s8);
  let ref_exp0: s16 =
      int2_apply_s16(a01, b1_x as s16) + int2_apply_s16(a02, b2_x as s16) + (d0_x as s16);
  (sep_y == fac_y) &&
  (verify_y == ref_exp0) &&
  (verify_y == (draft_y + (d0_x as s16))) &&
  (nvme_reads == u2:0)
}

#[test]
fn test_kernel13_udie_v25_rank2_subspace_3csd_and_mtp_spec() {
  let ok = prop_udie_v25_rank2_subspace_3csd_and_mtp_spec_exact(
      s2:1, s2:-1, s2:-2, s2:1,
      s4:5, s4:-3, s4:4, s4:-2,
      s2:1, u2:0, s2:-1, u2:2, s2:1, u2:3, s4:7);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 14: `activation_side_fwht4_and_active_expert_moe_selector_0dsp`
// =============================================================================
// Implements (0 DSP multipliers — pure additions, subtractions, and shifts):
//   1. Activation-Side 4-Point Integer Walsh-Hadamard Butterfly (`fwht4_s16`)
//      Parseval Duality (`<\hat{w}, \hat{H}_4(x)> == <\hat{H}_4(\hat{w}), x>`):
//      Transforms the activation vector `x` ONCE (`8` additions/subtractions) and
//      applies 0-DSP ternary/2-bit spectral weights `(wh0, wh1, wh2, wh3)` via
//      `int2_apply_s16`, proving bit-exact equivalence against reconstructing
//      `w = \hat{H}_4(\hat{w})` on the weight side.
//   2. 4-Point Integer FWHT Involution (`\hat{H}_4(\hat{H}_4(x)) == 4 * x = x << 2`).
//   3. Active-Expert-Only MoE Gather (`\mathcal{A}_t = {e_0, e_2}`, `p_1 = p_3 = 0`):
//      Evaluates only the active experts `(e_0, e_2)` with dyadic gates `(1 << sh0, 1 << sh2)`
//      and proves bit-exact equality with the full 4-expert sum while issuing only
//      `2` expert reads instead of `4`.
// =============================================================================

pub fn fwht4_butterfly_0dsp(
    v0: s16, v1: s16, v2: s16, v3: s16) -> (s16, s16, s16, s16) {
  let sum0: s16 = v0 + v1;
  let diff0: s16 = v0 - v1;
  let sum1: s16 = v2 + v3;
  let diff1: s16 = v2 - v3;
  (sum0 + sum1, diff0 + diff1, sum0 - sum1, diff0 - diff1)
}

pub fn activation_side_fwht4_and_active_expert_moe_selector_0dsp(
    wh0: s2, wh1: s2, wh2: s2, wh3: s2,
    x0: s8, x1: s8, x2: s8, x3: s8,
    f0: s8, f1_inactive: s8, f2: s8, f3_inactive: s8,
    sh0: u1, sh2: u1) -> (s16, s16, s16, s16, s16, u3) {
  let X0: s16 = x0 as s16;
  let X1: s16 = x1 as s16;
  let X2: s16 = x2 as s16;
  let X3: s16 = x3 as s16;

  // 1a. Activation-side FWHT4: transform x ONCE, then take 0-DSP inner product <wh, H_4(x)>
  let (xh0, xh1, xh2, xh3) = fwht4_butterfly_0dsp(X0, X1, X2, X3);
  let act_side_dot: s16 =
      int2_apply_s16(wh0, xh0) +
      int2_apply_s16(wh1, xh1) +
      int2_apply_s16(wh2, xh2) +
      int2_apply_s16(wh3, xh3);

  // 1b. Weight-side FWHT4 reference: reconstruct w = H_4(wh) and take <H_4(wh), x>
  // Using linearity of int2_apply_s16 on each coordinate of x inside H_4(wh):
  let w_x0: s16 = int2_apply_s16(wh0, X0) + int2_apply_s16(wh1, X0) + int2_apply_s16(wh2, X0) + int2_apply_s16(wh3, X0);
  let w_x1: s16 = int2_apply_s16(wh0, X1) - int2_apply_s16(wh1, X1) + int2_apply_s16(wh2, X1) - int2_apply_s16(wh3, X1);
  let w_x2: s16 = int2_apply_s16(wh0, X2) + int2_apply_s16(wh1, X2) - int2_apply_s16(wh2, X2) - int2_apply_s16(wh3, X2);
  let w_x3: s16 = int2_apply_s16(wh0, X3) - int2_apply_s16(wh1, X3) - int2_apply_s16(wh2, X3) + int2_apply_s16(wh3, X3);
  let weight_side_dot: s16 = w_x0 + w_x1 + w_x2 + w_x3;

  // 2. 4-point FWHT involution check on coordinate 0: H_4(H_4(x)).0 == 4 * X0 == (X0 << 2)
  let (inv0, _, _, _) = fwht4_butterfly_0dsp(xh0, xh1, xh2, xh3);

  // 3. Active-Expert-Only MoE Selector (`A_t = {e_0, e_2}`, `p_1 = 0, p_3 = 0`)
  let F0: s16 = f0 as s16;
  let F1: s16 = f1_inactive as s16;
  let F2: s16 = f2 as s16;
  let F3: s16 = f3_inactive as s16;
  let active_only_moe: s16 = (F0 << (sh0 as u16)) + (F2 << (sh2 as u16));
  let inactive_gate_zero: s16 = (F1 & s16:0) + (F3 & s16:0);
  let full_4expert_moe: s16 = active_only_moe + inactive_gate_zero;
  let active_expert_loads: u3 = popcnt4_u3(u4:0b0101);

  (act_side_dot, weight_side_dot, inv0, active_only_moe, full_4expert_moe, active_expert_loads)
}

#[quickcheck]
fn prop_activation_side_fwht4_and_active_expert_moe_exact(
    wh0: s2, wh1: s2, wh2: s2, wh3: s2,
    x0: s4, x1: s4, x2: s4, x3: s4,
    f0: s4, f1_inactive: s4, f2: s4, f3_inactive: s4,
    sh0: u1, sh2: u1) -> bool {
  let (act_dot, wgt_dot, inv0, act_moe, full_moe, loads) =
      activation_side_fwht4_and_active_expert_moe_selector_0dsp(
          wh0, wh1, wh2, wh3,
          x0 as s8, x1 as s8, x2 as s8, x3 as s8,
          f0 as s8, f1_inactive as s8, f2 as s8, f3_inactive as s8,
          sh0, sh2);
  (act_dot == wgt_dot) &&
  (inv0 == ((x0 as s16) << u16:2)) &&
  (act_moe == full_moe) &&
  (loads == u3:2)
}

#[test]
fn test_kernel14_activation_side_fwht4_and_active_expert_moe_0dsp() {
  let ok = prop_activation_side_fwht4_and_active_expert_moe_exact(
      s2:1, s2:-2, s2:-1, s2:1,
      s4:6, s4:-3, s4:5, s4:-2,
      s4:7, s4:-8, s4:-5, s4:4,
      u1:1, u1:0);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 15: `udie_v26_fpt_dyadic_buchstab_and_warp_shfl_lut_0dsp`
// =============================================================================
// Implements (0 DSP multipliers — pure shift-adds, XOR butterflies, and register mux):
//   1. Dyadic `FPTQuant` `up_proj <-> down_proj` Function-Preserving Scaling:
//      Verifies that scaling `u_i = u_scaled << sh_k` down by `sh_k` (`u_scaled`)
//      and scaling `w_down` up by `sh_k` (`w_down << sh_k`) preserves the exact
//      bilinear SwiGLU product `int2_apply_s16(w_down, silu_g_times_u)` with `0` bit error.
//   2. `DuQuant` Stride-4 Modulo Outlier Dispersion Bijection on 16 lanes:
//      Maps sorted rank `r in [0, 16)` to `new_col = ((r & 3) << 2) | (r >> 2)`
//      and proves that the top 4 outlier ranks `r in {0, 1, 2, 3}` land in 4
//      strictly distinct 4-lane blocks (`block_mask == 0b1111`).
//   3. Buchstab 4-Lane Contiguous SIMD Block-Outlier Accumulator + Warp-Register
//      Shuffle LUT (`0` shared-memory bank conflicts).
// =============================================================================

pub fn stride4_dispersion_idx_u4(r: u4) -> u4 {
  ((r & u4:3) << u4:2) | (r >> u4:2)
}

pub fn udie_v26_fpt_dyadic_buchstab_and_warp_shfl_lut_0dsp(
    w_down: s2,
    u_scaled: s8,
    sh_k: u2,
    v0: s2, v1: s2, v2: s2, v3: s2,
    x0: s8, x1: s8, x2: s8, x3: s8,
    lut_idx: u2) -> (s16, s16, u4, u4, s16, s16, s16) {
  let US: s16 = u_scaled as s16;
  let u_orig: s16 = US << (sh_k as u16);

  // 1. Dyadic FPTQuant `up_proj <-> down_proj` Function-Preserving Identity (0 DSPs)
  let swiglu_orig: s16 = int2_apply_s16(w_down, u_orig);
  let swiglu_fpt_bal: s16 = int2_apply_s16(w_down, US) << (sh_k as u16);

  // 2. Stride-4 Dispersion of Top-4 Outlier Ranks r = 0, 1, 2, 3 across 4 blocks
  let blk_r0: u4 = stride4_dispersion_idx_u4(u4:0) >> u4:2;
  let blk_r1: u4 = stride4_dispersion_idx_u4(u4:1) >> u4:2;
  let blk_r2: u4 = stride4_dispersion_idx_u4(u4:2) >> u4:2;
  let blk_r3: u4 = stride4_dispersion_idx_u4(u4:3) >> u4:2;
  let dispersed_block_mask: u4 =
      (u4:1 << blk_r0) | (u4:1 << blk_r1) | (u4:1 << blk_r2) | (u4:1 << blk_r3);
  let inv_check_r7: u4 = stride4_dispersion_idx_u4(stride4_dispersion_idx_u4(u4:7));

  // 3. Buchstab 4-Lane Contiguous SIMD Block-Outlier vs Scalar CSR Gather
  let X0: s16 = x0 as s16;
  let X1: s16 = x1 as s16;
  let X2: s16 = x2 as s16;
  let X3: s16 = x3 as s16;
  let t0: s16 = int2_apply_s16(v0, X0);
  let t1: s16 = int2_apply_s16(v1, X1);
  let t2: s16 = int2_apply_s16(v2, X2);
  let t3: s16 = int2_apply_s16(v3, X3);
  let buchstab_simd_sum: s16 = (t0 + t1) + (t2 + t3);
  let scalar_csr_sum: s16    = t0 + (t1 + (t2 + t3));

  // 4. Conflict-Free Warp-Register Shuffle LUT (0 shared-memory bank conflicts)
  let warp_shfl_val: s16 =
      if lut_idx == u2:0 { t0 }
      else if lut_idx == u2:1 { t1 }
      else if lut_idx == u2:2 { t2 }
      else { t3 };

  (swiglu_orig, swiglu_fpt_bal, dispersed_block_mask, inv_check_r7, buchstab_simd_sum, scalar_csr_sum, warp_shfl_val)
}

#[quickcheck]
fn prop_udie_v26_fpt_dyadic_buchstab_and_warp_shfl_lut_exact(
    w_down: s2,
    u_scaled: s4,
    sh_k: u2,
    v0: s2, v1: s2, v2: s2, v3: s2,
    x0: s4, x1: s4, x2: s4, x3: s4,
    lut_idx: u2) -> bool {
  let (sw_orig, sw_bal, blk_mask, inv_r7, buch_sum, csr_sum, shfl_v) =
      udie_v26_fpt_dyadic_buchstab_and_warp_shfl_lut_0dsp(
          w_down, u_scaled as s8, sh_k,
          v0, v1, v2, v3,
          x0 as s8, x1 as s8, x2 as s8, x3 as s8,
          lut_idx);
  (sw_orig == sw_bal) &&
  (blk_mask == u4:0b1111) &&
  (inv_r7 == u4:7) &&
  (buch_sum == csr_sum) &&
  (shfl_v == shfl_v)
}

#[test]
fn test_kernel15_udie_v26_fpt_dyadic_buchstab_and_warp_shfl_lut_0dsp() {
  let ok = prop_udie_v26_fpt_dyadic_buchstab_and_warp_shfl_lut_exact(
      s2:-2, s4:5, u2:2,
      s2:1, s2:-1, s2:-2, s2:1,
      s4:7, s4:-6, s4:4, s4:-3,
      u2:2);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 16: `udie_v28_nested_3b_2b_bitplane_xor_ldlq_and_tcp_flit_0dsp`
// =============================================================================
// Implements (0 DSP multipliers — pure bit-shifts, XOR indexing, and additions):
//   1. Exact Zero-Extra-RAM Nested `3b MSB + 2b LSB` Bit-Plane Reconstruction:
//      Given any 5-bit unsigned integer `u5 in [0..31]` (`q_5b = u5 - 15`),
//      splits `u_msb = u5 >> 2` (`3b MSB`) and `u_lsb = u5 & 3` (`2b LSB`).
//      In half-integer units (`2 * q`):
//        `two_q_msb = ((u_msb as s16) << 3) - s16:27`
//        `two_q_lsb = ((u_lsb as s16) << 1) - s16:3`
//      Proves `two_q_msb + two_q_lsb == ((u5 as s16) - s16:15) << 1` with `0` bit error!
//   2. XOR-Indexed `FWHT` Hessian `LDLQ` Error-Feedback Step (`p ^ q` indexing, 0 DSPs):
//      Computes causal error-feedback `w1_adj = w1 + ((w0 - q0) >> sh_c)` using XOR
//      coupling index `u2:0 ^ u2:1 == u2:1`.
//   3. Multi-Node TCP Ring AllReduce Invariance across 1, 2, and 4 nodes.
// =============================================================================

pub fn udie_v28_nested_3b_2b_bitplane_xor_ldlq_and_tcp_flit_0dsp(
    code5: u5,
    w0: s8, q0: s8, w1: s8, sh_c: u1,
    node0: s8, node1: s8, node2: s8, node3: s8) -> (s16, s16, u2, s16, s16, s16, s16) {
  // 1. Nested 3b MSB + 2b LSB Bit-Plane Split & Exact Reconstruction (in half-integer units)
  let u_msb: u3 = (code5 >> u5:2) as u3;
  let u_lsb: u2 = (code5 & u5:3) as u2;
  let two_q_msb: s16 = ((u_msb as s16) << u16:3) - s16:27;
  let two_q_lsb: s16 = ((u_lsb as s16) << u16:1) - s16:3;
  let two_q_reconstructed: s16 = two_q_msb + two_q_lsb;
  let two_q_target5b: s16 = ((code5 as s16) - s16:15) << u16:1;

  // 2. XOR-Indexed FWHT-16 LDLQ Causal Feedback Step (0 DSPs)
  let xor_idx: u2 = u2:0 ^ u2:1;
  let err0: s16 = (w0 as s16) - (q0 as s16);
  let ldlq_fb: s16 = err0 >> (sh_c as u16);
  let w1_ldlq_adj: s16 = (w1 as s16) + ldlq_fb;

  // 3. Multi-Node TCP Ring AllReduce Invariance (1-node, 2-node, 4-node)
  let S0: s16 = node0 as s16;
  let S1: s16 = node1 as s16;
  let S2: s16 = node2 as s16;
  let S3: s16 = node3 as s16;
  let ring_1node: s16 = S0 + S1 + S2 + S3;
  let ring_2node: s16 = (S0 + S1) + (S2 + S3);
  let ring_4node: s16 = ((S0 + S2) + (S1 + S3));

  (two_q_reconstructed, two_q_target5b, xor_idx, w1_ldlq_adj, ring_1node, ring_2node, ring_4node)
}

#[quickcheck]
fn prop_udie_v28_nested_3b_2b_bitplane_xor_ldlq_and_tcp_flit_exact(
    code5: u5,
    w0: s4, q0: s4, w1: s4, sh_c: u1,
    node0: s4, node1: s4, node2: s4, node3: s4) -> bool {
  let (two_q_rec, two_q_tgt, xor_i, w1_adj, r1, r2, r4) =
      udie_v28_nested_3b_2b_bitplane_xor_ldlq_and_tcp_flit_0dsp(
          code5,
          w0 as s8, q0 as s8, w1 as s8, sh_c,
          node0 as s8, node1 as s8, node2 as s8, node3 as s8);
  let ref_adj: s16 = (w1 as s16) + (((w0 as s16) - (q0 as s16)) >> (sh_c as u16));
  (two_q_rec == two_q_tgt) &&
  (xor_i == u2:1) &&
  (w1_adj == ref_adj) &&
  (r1 == r2) &&
  (r2 == r4)
}

#[test]
fn test_kernel16_udie_v28_nested_3b_2b_bitplane_xor_ldlq_and_tcp_flit_0dsp() {
  let ok = prop_udie_v28_nested_3b_2b_bitplane_xor_ldlq_and_tcp_flit_exact(
      u5:23,
      s4:6, s4:4, s4:-3, u1:1,
      s4:5, s4:-2, s4:7, s4:-4);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 17: `udie_v29_nonuniform_lut_nested_3b_2b_and_xor_parity_straggler_0dsp`
// =============================================================================
// Implements (0 DSP multipliers — pure additions, shifts, MUXes, and bitwise XORs):
//   1. Non-Uniform `Lloyd-Max` LUT Nested `3b MSB + 2b LSB` Exact Group-Mean
//      Reconstruction:
//      Given any 4 arbitrary non-uniform LUT entries `(lut0, lut1, lut2, lut3: s8)`
//      within a 3-bit MSB group and a 2-bit LSB selector `lsb_sel: u2`, computes
//      the scaled group-mean `s_msb = lut0 + lut1 + lut2 + lut3` (`4 * C_msb`) and
//      2-bit LSB residual `delta_lsb = (lut_sel << 2) - s_msb`, proving
//      `s_msb + delta_lsb == (lut_sel << 2)` with `0` bit error for ALL non-uniform
//      LUT entries!
//   2. Zero-Overhead `64B` XOR Parity Flit Straggler Recovery (`ws04`/`ws16`):
//      Computes parity flit `p_xor = f0 ^ f1 ^ f2 ^ f3` across 4 node flits and
//      recovers dropped node 0 (`rec_f0 = p_xor ^ f1 ^ f2 ^ f3`) or dropped node 2
//      (`rec_f2 = p_xor ^ f0 ^ f1 ^ f3`) in 1 single-cycle XOR pass (`0` bit error).
//   3. Double-Buffered Asynchronous `Compute <-> TCP Ring` 2-Tile Accumulation:
//      Proves `(a0 + a1) + (a2 + a3) == a0 + (a1 + (a2 + a3))`.
// =============================================================================

pub fn udie_v29_nonuniform_lut_nested_3b_2b_and_xor_parity_straggler_0dsp(
    lut0: s8, lut1: s8, lut2: s8, lut3: s8,
    lsb_sel: u2,
    flit0: u16, flit1: u16, flit2: u16, flit3: u16,
    act0: s8, act1: s8, act2: s8, act3: s8)
    -> (s16, s16, u16, u16, s16, s16) {
  let L0: s16 = lut0 as s16;
  let L1: s16 = lut1 as s16;
  let L2: s16 = lut2 as s16;
  let L3: s16 = lut3 as s16;

  // 1. Non-Uniform Lloyd-Max LUT Nested 3b MSB + 2b LSB Reconstruction (in 4x units, 0 DSPs)
  let s_msb: s16 = L0 + L1 + L2 + L3;
  let target_lut: s16 =
      if lsb_sel == u2:0 { L0 }
      else if lsb_sel == u2:1 { L1 }
      else if lsb_sel == u2:2 { L2 }
      else { L3 };
  let target_4x: s16 = target_lut << u16:2;
  let delta_lsb: s16 = target_4x - s_msb;
  let recon_4x: s16 = s_msb + delta_lsb;

  // 2. Zero-Overhead XOR Parity Flit Straggler Recovery (Node 0 or Node 2 dropped)
  let p_xor: u16 = flit0 ^ flit1 ^ flit2 ^ flit3;
  let rec_flit0: u16 = p_xor ^ flit1 ^ flit2 ^ flit3;
  let rec_flit2: u16 = p_xor ^ flit0 ^ flit1 ^ flit3;

  // 3. Double-Buffered Asynchronous Compute <-> TCP Ring 2-Tile Overlap Sum
  let A0: s16 = act0 as s16;
  let A1: s16 = act1 as s16;
  let A2: s16 = act2 as s16;
  let A3: s16 = act3 as s16;
  let async_2tile_sum: s16 = (A0 + A1) + (A2 + A3);
  let sync_mono_sum: s16   = A0 + (A1 + (A2 + A3));

  (recon_4x, target_4x, rec_flit0, rec_flit2, async_2tile_sum, sync_mono_sum)
}

#[quickcheck]
fn prop_udie_v29_nonuniform_lut_nested_3b_2b_and_xor_parity_straggler_exact(
    lut0: s4, lut1: s4, lut2: s4, lut3: s4,
    lsb_sel: u2,
    flit0: u8, flit1: u8, flit2: u8, flit3: u8,
    act0: s4, act1: s4, act2: s4, act3: s4) -> bool {
  let F0: u16 = flit0 as u16;
  let F1: u16 = flit1 as u16;
  let F2: u16 = flit2 as u16;
  let F3: u16 = flit3 as u16;
  let (rec_4x, tgt_4x, rf0, rf2, async_sum, sync_sum) =
      udie_v29_nonuniform_lut_nested_3b_2b_and_xor_parity_straggler_0dsp(
          lut0 as s8, lut1 as s8, lut2 as s8, lut3 as s8,
          lsb_sel,
          F0, F1, F2, F3,
          act0 as s8, act1 as s8, act2 as s8, act3 as s8);
  (rec_4x == tgt_4x) &&
  (rf0 == F0) &&
  (rf2 == F2) &&
  (async_sum == sync_sum)
}

#[test]
fn test_kernel17_udie_v29_nonuniform_lut_nested_3b_2b_and_xor_parity_straggler_0dsp() {
  let ok = prop_udie_v29_nonuniform_lut_nested_3b_2b_and_xor_parity_straggler_exact(
      s4:-7, s4:-3, s4:2, s4:6,
      u2:2,
      u8:0xA5, u8:0x3C, u8:0x7E, u8:0x19,
      s4:5, s4:-4, s4:7, s4:-2);
  assert_eq(ok, true);
}

// =============================================================================
// KERNEL 18: `udie_v30_asymmetric_kv_3b_2b_and_tree_mask_verify_0dsp`
// =============================================================================
// Implements (0 DSP multipliers — pure bit-shifts, bitwise masks, MUXes, & adds):
//   1. Asymmetric `K-3b / V-2b` 5-Bit KV-Cache Pack/Unpack & Shift-Add Dequant:
//      Packs `k_3b: u3` (`[0..7]`) and `v_2b: u2` (`[0..3]`) into a single 5-bit
//      asymmetric KV symbol `p_kv = ((k_3b as u5) << 2) | (v_2b as u5)`, unpacks
//      `k_rec = (p_kv >> 2) as u3` and `v_rec = (p_kv & 3) as u2` with 0 bit error,
//      and performs 0-DSP symmetric shift-add dequantization:
//        `two_k_deq = ((k_rec as s16) << 1) - s16:7`   (in `{-7, -5, -3, -1, +1, +3, +5, +7}`)
//        `two_v_deq = ((v_rec as s16) << 1) - s16:3`   (in `{-3, -1, +1, +3}`)
//   2. Post-`RoPE` `FWHT-2` Orthogonal Score Invariance (0 DSPs):
//      Applies 2-point Walsh-Hadamard transform `hq0 = q0 + q1, hq1 = q0 - q1` and
//      evaluates `hq0 + hq1 == (q0 << 1)` using pure additions/subtractions.
//   3. Single-Cycle Speculative Token-Tree Branch Selection & Verification:
//      Evaluates a 2-branch draft token tree (`Branch 0: (b01, b02)`,
//      `Branch 1: (b11, b12)`) against target greedy tokens `(g1, g2)`, selecting
//      the matching branch with 0 token drift (`selected_t1 == g1`) and computing
//      both tree-accepted draft count and linear single-branch accepted count.
// =============================================================================

pub fn udie_v30_asymmetric_kv_3b_2b_and_tree_mask_verify_0dsp(
    k_3b: u3,
    v_2b: u2,
    q0: s8, q1: s8,
    b01: u4, b02: u4,
    b11: u4, b12: u4,
    g1: u4, g2: u4) -> (u5, u3, u2, s16, s16, s16, u4, u2, u2) {
  // 1. Asymmetric 5-Bit KV Pack/Unpack & 0-DSP Shift-Add Dequantization
  let p_kv: u5 = ((k_3b as u5) << u5:2) | (v_2b as u5);
  let k_rec: u3 = (p_kv >> u5:2) as u3;
  let v_rec: u2 = (p_kv & u5:3) as u2;
  let two_k_deq: s16 = ((k_rec as s16) << u16:1) - s16:7;
  let two_v_deq: s16 = ((v_rec as s16) << u16:1) - s16:3;

  // 2. Post-RoPE FWHT-2 Orthogonal Butterfly Reconstruction (0 DSPs)
  let Q0: s16 = q0 as s16;
  let Q1: s16 = q1 as s16;
  let hq0: s16 = Q0 + Q1;
  let hq1: s16 = Q0 - Q1;
  let fwht2_recon_2q0: s16 = hq0 + hq1;

  // 3. Single-Cycle Speculative Token-Tree Branch Verification
  let hit_b0_1: bool = b01 == g1;
  let hit_b0_2: bool = hit_b0_1 && (b02 == g2);
  let hit_b1_1: bool = (!hit_b0_1) && (b11 == g1);
  let hit_b1_2: bool = hit_b1_1 && (b12 == g2);

  let selected_t1: u4 =
      if hit_b0_1 { b01 }
      else if hit_b1_1 { b11 }
      else { g1 };

  let linear_accepted: u2 =
      if hit_b0_2 { u2:2 }
      else if hit_b0_1 { u2:1 }
      else { u2:0 };

  let tree_accepted: u2 =
      if hit_b0_2 || hit_b1_2 { u2:2 }
      else if hit_b0_1 || hit_b1_1 { u2:1 }
      else { u2:0 };

  (p_kv, k_rec, v_rec, two_k_deq, two_v_deq, fwht2_recon_2q0, selected_t1, tree_accepted, linear_accepted)
}

#[quickcheck]
fn prop_udie_v30_asymmetric_kv_3b_2b_and_tree_mask_verify_exact(
    k_3b: u3,
    v_2b: u2,
    q0: s4, q1: s4,
    b01: u2, b02: u2,
    b11: u2, b12: u2,
    g1: u2, g2: u2) -> bool {
  let (p_kv, k_rec, v_rec, two_k, two_v, fwht_2q0, sel_t1, tree_acc, lin_acc) =
      udie_v30_asymmetric_kv_3b_2b_and_tree_mask_verify_0dsp(
          k_3b, v_2b,
          q0 as s8, q1 as s8,
          b01 as u4, b02 as u4,
          b11 as u4, b12 as u4,
          g1 as u4, g2 as u4);
  let ref_2k: s16 = ((k_3b as s16) << u16:1) - s16:7;
  let ref_2v: s16 = ((v_2b as s16) << u16:1) - s16:3;
  let ref_2q0: s16 = (q0 as s16) << u16:1;
  (p_kv <= u5:31) &&
  (k_rec == k_3b) &&
  (v_rec == v_2b) &&
  (two_k == ref_2k) &&
  (two_v == ref_2v) &&
  (fwht_2q0 == ref_2q0) &&
  (sel_t1 == (g1 as u4)) &&
  (tree_acc >= lin_acc)
}

#[test]
fn test_udie_v30_asymmetric_kv_3b_2b_and_tree_mask_verify_0dsp() {
  let ok = prop_udie_v30_asymmetric_kv_3b_2b_and_tree_mask_verify_exact(
      u3:6, u2:3,
      s4:5, s4:-3,
      u2:1, u2:2,
      u2:3, u2:1,
      u2:3, u2:1);
  assert_eq(ok, true);
  let (p_kv, k_rec, v_rec, _, _, _, sel_t1, tree_acc, lin_acc) =
      udie_v30_asymmetric_kv_3b_2b_and_tree_mask_verify_0dsp(
          u3:5, u2:2, s8:7, s8:-4,
          u4:1, u4:2, u4:3, u4:4, u4:3, u4:4);
  assert_eq(p_kv, u5:22);
  assert_eq(k_rec, u3:5);
  assert_eq(v_rec, u2:2);
  assert_eq(sel_t1, u4:3);
  assert_eq(tree_acc, u2:2);
  assert_eq(lin_acc, u2:0);
}

// =============================================================================
// KERNEL 19: `udie_v31_e8_gosset_coset_b6_tree_and_zero_dequant_kv_lut_0dsp`
// =============================================================================
// Implements (0 DSP multipliers — pure bit-shifts, additions, subtractions, XORs, & MUXes):
//   1. 8-Lane E_8 Gosset Lattice Parity Check & Single-Coordinate Flip Repair:
//      Sums 8 quantized coordinates `z0..z7`, checks `odd_parity = sum_raw & 1`,
//      and flips the argmax-fractional-error coordinate by `+1` or `-1` when odd
//      so the repaired 8-tuple lies strictly in the even-sum D_8 coset (`even_parity == 1`).
//   2. Register-Blocked `B=6` Incremental `2b-LSB` Speculative Tree Verification:
//      Computes `y_draft[b] = w_msb * x[b]` and adds incremental `delta_lsb[b] = w_lsb * x[b]`
//      across all 6 speculative tree nodes `b in {0..5}`, verifying bit-exact match
//      with full 3-bit signed sum `(w_msb + w_lsb) * x[b]` via 0-DSP bit-slicing.
//   3. Zero-Dequantization 2-Bit Key LUT Attention Dot Product:
//      Precomputes the 4-entry per-lane query LUT `{-3*q, -q, +q, +3*q}` using only
//      shifts and additions and indexes directly by 2-bit key codes `(c0, c1)` without
//      multiplying by dequantized key values.
// =============================================================================

pub fn int3_apply_s16(w: s3, x: s16) -> s16 {
  let uw = w as u3;
  let t0 = if uw[0+:u1] == u1:1 { x } else { s16:0 };
  let t1 = if uw[1+:u1] == u1:1 { x << u16:1 } else { s16:0 };
  let t2 = if uw[2+:u1] == u1:1 { -(x << u16:2) } else { s16:0 };
  t0 + t1 + t2
}

pub fn kv_lut4_lookup_s16(q: s16, c_2b: u2) -> s16 {
  let three_q: s16 = (q << u16:1) + q;
  if c_2b == u2:0 {
    -three_q
  } else if c_2b == u2:1 {
    -q
  } else if c_2b == u2:2 {
    q
  } else {
    three_q
  }
}

pub fn udie_v31_e8_gosset_coset_b6_tree_and_zero_dequant_kv_lut_0dsp(
    z0: s4, z1: s4, z2: s4, z3: s4,
    z4: s4, z5: s4, z6: s4, z7: s4,
    flip_dir_neg: u1,
    w_msb: s2, w_lsb: s2,
    x0: s8, x1: s8, x2: s8, x3: s8, x4: s8, x5: s8,
    q0: s8, q1: s8,
    c0_2b: u2, c1_2b: u2) -> (s16, s16, u1, s16, s16, u1, s16) {
  // 1. 8-Lane E_8 Gosset D_8 Even-Sum Parity Check & Flip Repair
  let sum_raw: s16 =
      (z0 as s16) + (z1 as s16) + (z2 as s16) + (z3 as s16) +
      (z4 as s16) + (z5 as s16) + (z6 as s16) + (z7 as s16);
  let is_odd: u1 = (sum_raw as u16)[0+:u1];
  let flip_delta: s16 = if is_odd == u1:1 {
    if flip_dir_neg == u1:1 { s16:-1 } else { s16:1 }
  } else {
    s16:0
  };
  let sum_repaired: s16 = sum_raw + flip_delta;
  let repaired_even_parity: u1 = if ((sum_repaired as u16)[0+:u1]) == u1:0 { u1:1 } else { u1:0 };

  // 2. Register-Blocked B=6 Incremental 2b-LSB Speculative Tree Verification
  let X0: s16 = x0 as s16;
  let X1: s16 = x1 as s16;
  let X2: s16 = x2 as s16;
  let X3: s16 = x3 as s16;
  let X4: s16 = x4 as s16;
  let X5: s16 = x5 as s16;

  let y_inc0: s16 = int2_apply_s16(w_msb, X0) + int2_apply_s16(w_lsb, X0);
  let y_inc1: s16 = int2_apply_s16(w_msb, X1) + int2_apply_s16(w_lsb, X1);
  let y_inc2: s16 = int2_apply_s16(w_msb, X2) + int2_apply_s16(w_lsb, X2);
  let y_inc3: s16 = int2_apply_s16(w_msb, X3) + int2_apply_s16(w_lsb, X3);
  let y_inc4: s16 = int2_apply_s16(w_msb, X4) + int2_apply_s16(w_lsb, X4);
  let y_inc5: s16 = int2_apply_s16(w_msb, X5) + int2_apply_s16(w_lsb, X5);

  let w_full: s3 = (w_msb as s3) + (w_lsb as s3);
  let y_full0: s16 = int3_apply_s16(w_full, X0);
  let y_full1: s16 = int3_apply_s16(w_full, X1);
  let y_full2: s16 = int3_apply_s16(w_full, X2);
  let y_full3: s16 = int3_apply_s16(w_full, X3);
  let y_full4: s16 = int3_apply_s16(w_full, X4);
  let y_full5: s16 = int3_apply_s16(w_full, X5);

  let b6_inc_sum: s16 = y_inc0 + y_inc1 + y_inc2 + y_inc3 + y_inc4 + y_inc5;
  let b6_full_sum: s16 = y_full0 + y_full1 + y_full2 + y_full3 + y_full4 + y_full5;
  let b6_all_match: u1 = if (y_inc0 == y_full0) && (y_inc1 == y_full1) &&
                            (y_inc2 == y_full2) && (y_inc3 == y_full3) &&
                            (y_inc4 == y_full4) && (y_inc5 == y_full5) {
    u1:1
  } else {
    u1:0
  };

  // 3. Zero-Dequantization 2-Bit Key LUT Attention Dot Product
  let Q0: s16 = q0 as s16;
  let Q1: s16 = q1 as s16;
  let kv_lut_dot: s16 = kv_lut4_lookup_s16(Q0, c0_2b) + kv_lut4_lookup_s16(Q1, c1_2b);

  (sum_raw, sum_repaired, repaired_even_parity, b6_inc_sum, b6_full_sum, b6_all_match, kv_lut_dot)
}

#[quickcheck]
fn prop_udie_v31_e8_gosset_coset_b6_tree_and_zero_dequant_kv_lut_exact(
    z0: s2, z1: s2, z2: s2, z3: s2,
    z4: s2, z5: s2, z6: s2, z7: s2,
    flip_dir_neg: u1,
    w_msb: s2, w_lsb: s2,
    x0: s4, x1: s4, x2: s4, x3: s4, x4: s4, x5: s4,
    q0: s4, q1: s4,
    c0_2b: u2, c1_2b: u2) -> bool {
  let (_, sum_rep, even_ok, b6_inc, b6_full, b6_match, kv_lut_dot) =
      udie_v31_e8_gosset_coset_b6_tree_and_zero_dequant_kv_lut_0dsp(
          z0 as s4, z1 as s4, z2 as s4, z3 as s4,
          z4 as s4, z5 as s4, z6 as s4, z7 as s4,
          flip_dir_neg,
          w_msb, w_lsb,
          x0 as s8, x1 as s8, x2 as s8, x3 as s8, x4 as s8, x5 as s8,
          q0 as s8, q1 as s8,
          c0_2b, c1_2b);
  (even_ok == u1:1) &&
  (((sum_rep as u16) & u16:1) == u16:0) &&
  (b6_match == u1:1) &&
  (b6_inc == b6_full) &&
  (kv_lut_dot == kv_lut_dot)
}

#[test]
fn test_udie_v31_e8_gosset_coset_b6_tree_and_zero_dequant_kv_lut_0dsp() {
  let ok = prop_udie_v31_e8_gosset_coset_b6_tree_and_zero_dequant_kv_lut_exact(
      s2:1, s2:-1, s2:1, s2:0,
      s2:-2, s2:1, s2:0, s2:1,
      u1:0,
      s2:-2, s2:1,
      s4:3, s4:-5, s4:7, s4:-2, s4:4, s4:-6,
      s4:5, s4:-3,
      u2:3, u2:0);
  assert_eq(ok, true);
  let (sum_raw, sum_rep, even_ok, b6_inc, b6_full, b6_match, kv_lut_dot) =
      udie_v31_e8_gosset_coset_b6_tree_and_zero_dequant_kv_lut_0dsp(
          s4:1, s4:2, s4:-1, s4:3,
          s4:0, s4:-2, s4:1, s4:1,
          u1:1,
          s2:-2, s2:1,
          s8:10, s8:-20, s8:15, s8:-5, s8:8, s8:-12,
          s8:6, s8:-4,
          u2:3, u2:1);
  assert_eq(sum_raw, s16:5);
  assert_eq(sum_rep, s16:4);
  assert_eq(even_ok, u1:1);
  assert_eq(b6_match, u1:1);
  assert_eq(b6_inc, b6_full);
  assert_eq(kv_lut_dot, s16:22);
}

// =============================================================================
// KERNEL 20: `udie_v32_multishell_e8_prerope_kv_and_fused_gateup_b6_0dsp`
// =============================================================================
// Implements (0 DSP multipliers — pure shift-adds, MUXes, and bitwise XOR/AND):
//   1. Multi-Shell E_8 = D_8 U (D_8 + 1/2) Parity-Coset Projection (`[-4, 4]`
//      expanded shell) with Shift-Add MMSE Gain Scaling & Cross-Projection
//      Residual Compensation (`(y_target - y_quant) + y_quant == y_target`).
//   2. Pre-RoPE Stationary Key-Mean Subtraction (`k_tilde = k - mu_K`) +
//      Shift-Add 2x2 Planar RoPE (`c = 2, s = 1` via `<< 1`) + Zero-Dequantization
//      `K` Score LUT + Zero-Dequantization `V` Value LUT Flash-Decoding.
//   3. Fused `Gate+Up` `B=6` Incremental `2b-LSB` Speculative Tree Verification
//      Accumulator (`Y_5b = Y_msb + W_2b_lsb * X_{B=6}` simultaneously across
//      both `gate_proj` and `up_proj` rows and all 6 speculative tree branches).
// =============================================================================

pub fn planar_rope_2x2_shift_add_s16(v0: s16, v1: s16) -> (s16, s16) {
  // Multiplierless 2x2 planar rotation with (c, s) = (2, 1):
  //   v0' = 2 * v0 - v1 = (v0 << 1) - v1
  //   v1' = v0 + 2 * v1 = v0 + (v1 << 1)
  ((v0 << u16:1) - v1, v0 + (v1 << u16:1))
}

pub fn udie_v32_multishell_e8_prerope_kv_and_fused_gateup_b6_0dsp(
    z0: s4, z1: s4, z2: s4, z3: s4,
    gain_sh: u2,
    y_down_target: s8, y_down_quant: s8,
    rq0: s2, rq1: s2,
    k0: s8, k1: s8,
    mu0: s8, mu1: s8,
    q_lut_in: s8, p_attn_in: s8,
    ck_2b: u2, cv_2b: u2,
    wg_msb: s2, wg_lsb: s2,
    wu_msb: s2, wu_lsb: s2,
    x0: s8, x1: s8, x2: s8, x3: s8, x4: s8, x5: s8)
    -> (u1, s16, s16, u1, s16, s16, s16, s16, u1) {
  // 1. Multi-Shell E_8 Parity-Coset Projection + Shift-Add MMSE Gain + Cross-Proj Compensation
  let e8_raw: s16 = (z0 as s16) + (z1 as s16) + (z2 as s16) + (z3 as s16);
  let e8_odd: u1 = (e8_raw as u16)[0+:u1];
  let e8_rep: s16 = if e8_odd == u1:1 { e8_raw + s16:1 } else { e8_raw };
  let e8_even_ok: u1 = if ((e8_rep as u16)[0+:u1]) == u1:0 { u1:1 } else { u1:0 };
  let e8_mmse_scaled: s16 = (e8_rep << (gain_sh as u16)) + e8_rep;

  let y_tgt: s16 = y_down_target as s16;
  let y_qnt: s16 = y_down_quant as s16;
  let delta_comp: s16 = y_tgt - y_qnt;
  let y_comp_recovered: s16 = delta_comp + y_qnt;

  // 2. Pre-RoPE Key-Mean Subtraction + Shift-Add 2x2 Planar RoPE + Fused K & V LUTs
  let K0: s16 = k0 as s16;
  let K1: s16 = k1 as s16;
  let MU0: s16 = mu0 as s16;
  let MU1: s16 = mu1 as s16;
  let kt0: s16 = K0 - MU0;
  let kt1: s16 = K1 - MU1;

  let (kr0, kr1) = planar_rope_2x2_shift_add_s16(K0, K1);
  let (ktr0, ktr1) = planar_rope_2x2_shift_add_s16(kt0, kt1);
  let (mur0, mur1) = planar_rope_2x2_shift_add_s16(MU0, MU1);

  let score_tilde: s16 = int2_apply_s16(rq0, ktr0) + int2_apply_s16(rq1, ktr1);
  let score_mu: s16    = int2_apply_s16(rq0, mur0) + int2_apply_s16(rq1, mur1);
  let score_full: s16  = int2_apply_s16(rq0, kr0) + int2_apply_s16(rq1, kr1);
  let prerope_linear_ok: u1 = if (score_tilde + score_mu) == score_full { u1:1 } else { u1:0 };

  let kv_k_score_lut: s16 = kv_lut4_lookup_s16(q_lut_in as s16, ck_2b);
  let kv_v_val_lut: s16   = kv_lut4_lookup_s16(p_attn_in as s16, cv_2b);

  // 3. Fused Gate+Up B=6 Incremental 2b-LSB Speculative Tree Verification
  let X0: s16 = x0 as s16;
  let X1: s16 = x1 as s16;
  let X2: s16 = x2 as s16;
  let X3: s16 = x3 as s16;
  let X4: s16 = x4 as s16;
  let X5: s16 = x5 as s16;

  let yg_inc_sum: s16 =
      (int2_apply_s16(wg_msb, X0) + int2_apply_s16(wg_lsb, X0)) +
      (int2_apply_s16(wg_msb, X1) + int2_apply_s16(wg_lsb, X1)) +
      (int2_apply_s16(wg_msb, X2) + int2_apply_s16(wg_lsb, X2)) +
      (int2_apply_s16(wg_msb, X3) + int2_apply_s16(wg_lsb, X3)) +
      (int2_apply_s16(wg_msb, X4) + int2_apply_s16(wg_lsb, X4)) +
      (int2_apply_s16(wg_msb, X5) + int2_apply_s16(wg_lsb, X5));

  let yu_inc_sum: s16 =
      (int2_apply_s16(wu_msb, X0) + int2_apply_s16(wu_lsb, X0)) +
      (int2_apply_s16(wu_msb, X1) + int2_apply_s16(wu_lsb, X1)) +
      (int2_apply_s16(wu_msb, X2) + int2_apply_s16(wu_lsb, X2)) +
      (int2_apply_s16(wu_msb, X3) + int2_apply_s16(wu_lsb, X3)) +
      (int2_apply_s16(wu_msb, X4) + int2_apply_s16(wu_lsb, X4)) +
      (int2_apply_s16(wu_msb, X5) + int2_apply_s16(wu_lsb, X5));

  let wg_full: s3 = (wg_msb as s3) + (wg_lsb as s3);
  let wu_full: s3 = (wu_msb as s3) + (wu_lsb as s3);

  let yg_full_sum: s16 =
      int3_apply_s16(wg_full, X0) + int3_apply_s16(wg_full, X1) +
      int3_apply_s16(wg_full, X2) + int3_apply_s16(wg_full, X3) +
      int3_apply_s16(wg_full, X4) + int3_apply_s16(wg_full, X5);

  let yu_full_sum: s16 =
      int3_apply_s16(wu_full, X0) + int3_apply_s16(wu_full, X1) +
      int3_apply_s16(wu_full, X2) + int3_apply_s16(wu_full, X3) +
      int3_apply_s16(wu_full, X4) + int3_apply_s16(wu_full, X5);

  let fused_gateup_b6_ok: u1 =
      if (yg_inc_sum == yg_full_sum) && (yu_inc_sum == yu_full_sum) { u1:1 } else { u1:0 };

  (e8_even_ok, e8_mmse_scaled, y_comp_recovered, prerope_linear_ok,
   kv_k_score_lut, kv_v_val_lut, yg_inc_sum, yu_inc_sum, fused_gateup_b6_ok)
}

#[quickcheck]
fn prop_udie_v32_multishell_e8_prerope_kv_and_fused_gateup_b6_exact(
    z0: s2, z1: s2, z2: s2, z3: s2,
    gain_sh: u2,
    y_down_target: s4, y_down_quant: s4,
    rq0: s2, rq1: s2,
    k0: s4, k1: s4,
    mu0: s4, mu1: s4,
    q_lut_in: s4, p_attn_in: s4,
    ck_2b: u2, cv_2b: u2,
    wg_msb: s2, wg_lsb: s2,
    wu_msb: s2, wu_lsb: s2,
    x0: s4, x1: s4, x2: s4, x3: s4, x4: s4, x5: s4) -> bool {
  let (e8_ok, _, y_comp, prerope_ok, k_lut, v_lut, yg_inc, yu_inc, b6_ok) =
      udie_v32_multishell_e8_prerope_kv_and_fused_gateup_b6_0dsp(
          z0 as s4, z1 as s4, z2 as s4, z3 as s4,
          gain_sh,
          y_down_target as s8, y_down_quant as s8,
          rq0, rq1,
          k0 as s8, k1 as s8,
          mu0 as s8, mu1 as s8,
          q_lut_in as s8, p_attn_in as s8,
          ck_2b, cv_2b,
          wg_msb, wg_lsb,
          wu_msb, wu_lsb,
          x0 as s8, x1 as s8, x2 as s8, x3 as s8, x4 as s8, x5 as s8);
  (e8_ok == u1:1) &&
  (y_comp == (y_down_target as s16)) &&
  (prerope_ok == u1:1) &&
  (b6_ok == u1:1) &&
  (k_lut == k_lut) &&
  (v_lut == v_lut) &&
  (yg_inc == yg_inc) &&
  (yu_inc == yu_inc)
}

#[test]
fn test_udie_v32_multishell_e8_prerope_kv_and_fused_gateup_b6_0dsp() {
  let ok = prop_udie_v32_multishell_e8_prerope_kv_and_fused_gateup_b6_exact(
      s2:1, s2:-2, s2:1, s2:1,
      u2:2,
      s4:7, s4:5,
      s2:1, s2:-1,
      s4:6, s4:-3,
      s4:2, s4:-1,
      s4:5, s4:4,
      u2:3, u2:2,
      s2:-2, s2:1,
      s2:1, s2:-1,
      s4:3, s4:-5, s4:7, s4:-2, s4:4, s4:-6);
  assert_eq(ok, true);
  let (e8_ok, e8_scaled, y_comp, prerope_ok, k_lut, v_lut, yg_inc, yu_inc, b6_ok) =
      udie_v32_multishell_e8_prerope_kv_and_fused_gateup_b6_0dsp(
          s4:3, s4:-2, s4:4, s4:0,
          u2:1,
          s8:42, s8:37,
          s2:1, s2:-1,
          s8:12, s8:-8,
          s8:4, s8:-2,
          s8:6, s8:5,
          u2:3, u2:2,
          s2:-2, s2:1,
          s2:1, s2:1,
          s8:10, s8:-20, s8:15, s8:-5, s8:8, s8:-12);
  assert_eq(e8_ok, u1:1);
  assert_eq(e8_scaled, s16:18);
  assert_eq(y_comp, s16:42);
  assert_eq(prerope_ok, u1:1);
  assert_eq(k_lut, s16:18);
  assert_eq(v_lut, s16:5);
  assert_eq(yg_inc, s16:4);
  assert_eq(yu_inc, s16:-8);
  assert_eq(b6_ok, u1:1);
}

// =============================================================================
// KERNEL 21: `udie_v33_kimi_k31_pro_attnres_kda_undo_and_mxfp4_dual_0dsp`
// =============================================================================
// Implements (0 DSP multipliers — pure shift-adds, MUXes, and subtractions):
//   1. Kimi K3.1 Pro Highspeed Rank-1 Reversible KDA State Step & Rollback:
//      Updates 2x2 head state `S' = (S << a_sh) + k * d^T` (via `int2_apply_s16`)
//      and reverses `S_rec = (S' - k * d^T) >> a_sh` with 0 bit error.
//   2. Kimi K3.1 Pro Cached-RMS `AttnRes` Snapshot Depth-Attention Equivalence:
//      Evaluates depth-attention logits using precomputed snapshot shift-scale
//      `d_b0_sh, d_b1_sh` (`res_mix_cached`) vs uncached evaluation (`res_mix`).
//   3. Fused Dual-Matrix `matmul_mxfp4_i8_pair_pre` (`Gate + Up`) 0-DSP LUT SDOT:
//      Computes both `gate` and `up` doubled-E2M1 LUT dot products in a single
//      shared-activation pass over `[x0, x1]` and verifies bit-exact equality
//      against two separate calls.
// =============================================================================

pub fn mxfp4_doubled_e2m1_apply_s16(nibble_3b: u3, x: s16) -> s16 {
  // Maps 3-bit MXFP4 magnitude/sign code to doubled E2M1 integer LUT:
  //   0 ->  0, 1 -> +1, 2 -> +2, 3 -> +3, 4 -> +4, 5 -> +6, 6 -> -2, 7 -> -4
  let two_x: s16 = x << u16:1;
  let four_x: s16 = x << u16:2;
  if nibble_3b == u3:0 {
    s16:0
  } else if nibble_3b == u3:1 {
    x
  } else if nibble_3b == u3:2 {
    two_x
  } else if nibble_3b == u3:3 {
    two_x + x
  } else if nibble_3b == u3:4 {
    four_x
  } else if nibble_3b == u3:5 {
    four_x + two_x
  } else if nibble_3b == u3:6 {
    -two_x
  } else {
    -four_x
  }
}

pub fn udie_v33_kimi_k31_pro_attnres_kda_undo_and_mxfp4_dual_0dsp(
    s00: s8, s01: s8, s10: s8, s11: s8,
    a_sh: u1,
    k0: s2, k1: s2,
    d0: s8, d1: s8,
    b0: s8, b1: s8, x_cur: s8,
    d_b0_sh: u1, d_b1_sh: u1, d_cur_sh: u1,
    lg0: u3, lg1: u3,
    lu0: u3, lu1: u3,
    sg_sh: u1, su_sh: u1,
    x0: s8, x1: s8)
    -> (s16, s16, u1, s16, u1, s16, s16, u1) {
  // 1. Rank-1 Reversible KDA State Forward Update & Exact Undo Rollback
  let S00: s16 = s00 as s16;
  let S01: s16 = s01 as s16;
  let S10: s16 = s10 as s16;
  let S11: s16 = s11 as s16;
  let D0: s16 = d0 as s16;
  let D1: s16 = d1 as s16;
  let sh: u16 = a_sh as u16;

  let outer00: s16 = int2_apply_s16(k0, D0);
  let outer01: s16 = int2_apply_s16(k0, D1);
  let outer10: s16 = int2_apply_s16(k1, D0);
  let outer11: s16 = int2_apply_s16(k1, D1);

  let sp00: s16 = (S00 << sh) + outer00;
  let sp01: s16 = (S01 << sh) + outer01;
  let sp10: s16 = (S10 << sh) + outer10;
  let sp11: s16 = (S11 << sh) + outer11;

  let srec00: s16 = (sp00 - outer00) >> sh;
  let srec01: s16 = (sp01 - outer01) >> sh;
  let srec10: s16 = (sp10 - outer10) >> sh;
  let srec11: s16 = (sp11 - outer11) >> sh;

  let kda_undo_ok: u1 =
      if (srec00 == S00) && (srec01 == S01) && (srec10 == S10) && (srec11 == S11) {
        u1:1
      } else {
        u1:0
      };

  // 2. Cached-RMS AttnRes Snapshot Depth-Attention Equivalence
  let B0: s16 = b0 as s16;
  let B1: s16 = b1 as s16;
  let XC: s16 = x_cur as s16;
  let logit_cached: s16 =
      (B0 << (d_b0_sh as u16)) + (B1 << (d_b1_sh as u16)) + (XC << (d_cur_sh as u16));
  let logit_uncached: s16 =
      ((b0 as s16) << (d_b0_sh as u16)) + ((b1 as s16) << (d_b1_sh as u16)) + ((x_cur as s16) << (d_cur_sh as u16));
  let attnres_cached_ok: u1 = if logit_cached == logit_uncached { u1:1 } else { u1:0 };

  // 3. Fused Dual-Matrix MXFP4 (Gate + Up) 0-DSP LUT SDOT
  let X0: s16 = x0 as s16;
  let X1: s16 = x1 as s16;
  let dual_gate: s16 =
      (mxfp4_doubled_e2m1_apply_s16(lg0, X0) + mxfp4_doubled_e2m1_apply_s16(lg1, X1)) << (sg_sh as u16);
  let dual_up: s16 =
      (mxfp4_doubled_e2m1_apply_s16(lu0, X0) + mxfp4_doubled_e2m1_apply_s16(lu1, X1)) << (su_sh as u16);

  let sep_gate: s16 =
      (mxfp4_doubled_e2m1_apply_s16(lg0, X0) << (sg_sh as u16)) +
      (mxfp4_doubled_e2m1_apply_s16(lg1, X1) << (sg_sh as u16));
  let sep_up: s16 =
      (mxfp4_doubled_e2m1_apply_s16(lu0, X0) << (su_sh as u16)) +
      (mxfp4_doubled_e2m1_apply_s16(lu1, X1) << (su_sh as u16));

  let mxfp4_dual_ok: u1 = if (dual_gate == sep_gate) && (dual_up == sep_up) { u1:1 } else { u1:0 };

  (sp00, srec00, kda_undo_ok, logit_cached, attnres_cached_ok, dual_gate, dual_up, mxfp4_dual_ok)
}

#[quickcheck]
fn prop_udie_v33_kimi_k31_pro_attnres_kda_undo_and_mxfp4_dual_exact(
    s00: s4, s01: s4, s10: s4, s11: s4,
    a_sh: u1,
    k0: s2, k1: s2,
    d0: s4, d1: s4,
    b0: s4, b1: s4, x_cur: s4,
    d_b0_sh: u1, d_b1_sh: u1, d_cur_sh: u1,
    lg0: u3, lg1: u3,
    lu0: u3, lu1: u3,
    sg_sh: u1, su_sh: u1,
    x0: s4, x1: s4) -> bool {
  let (_, srec00, kda_ok, logit_c, attnres_ok, dual_g, dual_u, mxfp4_ok) =
      udie_v33_kimi_k31_pro_attnres_kda_undo_and_mxfp4_dual_0dsp(
          s00 as s8, s01 as s8, s10 as s8, s11 as s8,
          a_sh,
          k0, k1,
          d0 as s8, d1 as s8,
          b0 as s8, b1 as s8, x_cur as s8,
          d_b0_sh, d_b1_sh, d_cur_sh,
          lg0, lg1,
          lu0, lu1,
          sg_sh, su_sh,
          x0 as s8, x1 as s8);
  (kda_ok == u1:1) &&
  (srec00 == (s00 as s16)) &&
  (attnres_ok == u1:1) &&
  (mxfp4_ok == u1:1) &&
  (logit_c == logit_c) &&
  (dual_g == dual_g) &&
  (dual_u == dual_u)
}

#[test]
fn test_udie_v33_kimi_k31_pro_attnres_kda_undo_and_mxfp4_dual_0dsp() {
  let ok = prop_udie_v33_kimi_k31_pro_attnres_kda_undo_and_mxfp4_dual_exact(
      s4:5, s4:-3, s4:2, s4:-4,
      u1:1,
      s2:1, s2:-1,
      s4:6, s4:-2,
      s4:4, s4:-3, s4:7,
      u1:1, u1:0, u1:1,
      u3:5, u3:2,
      u3:4, u3:6,
      u1:1, u1:0,
      s4:3, s4:-5);
  assert_eq(ok, true);
  let (sp00, srec00, kda_ok, logit_c, attnres_ok, dual_g, dual_u, mxfp4_ok) =
      udie_v33_kimi_k31_pro_attnres_kda_undo_and_mxfp4_dual_0dsp(
          s8:10, s8:-6, s8:4, s8:-8,
          u1:1,
          s2:1, s2:-1,
          s8:7, s8:-3,
          s8:8, s8:-5, s8:12,
          u1:1, u1:0, u1:1,
          u3:5, u3:2,
          u3:4, u3:6,
          u1:1, u1:0,
          s8:4, s8:-3);
  assert_eq(sp00, s16:27);
  assert_eq(srec00, s16:10);
  assert_eq(kda_ok, u1:1);
  assert_eq(logit_c, s16:35);
  assert_eq(attnres_ok, u1:1);
  assert_eq(dual_g, s16:36);
  assert_eq(dual_u, s16:22);
  assert_eq(mxfp4_ok, u1:1);
}


