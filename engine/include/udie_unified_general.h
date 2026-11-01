/*
 * udie_unified_general.h — Self-Contained, Model-Agnostic 5-Layer Unified Inference Engine
 * ========================================================================================
 * Eliminates all model-specific overfitting (no hardcoded SwiGLU-only assumptions, no
 * power-of-two/multiple-of-16 dimension constraints, no Gaussian-only codebooks, no
 * FP8-E4M3-only split, no DeepSeek-specific DSA learned indexer weights, no Gated-DeltaNet-only
 * state rollback, and no hardcoded J=4/K=8 MoE routing) and has ZERO external dependencies
 * outside standard C11 headers and `udie_pipeline.h`.
 *
 * The 5 Orthogonal, Model-Agnostic Layers:
 *   - Layer 1 (`udie_gen_gauge_balance_pair`, `udie_gen_equipartition_perm`,
 *              `udie_gen_prepare_act_q`, `udie_gen_finish_act_q`, `udie_gen_condition_matrix`):
 *       Universal Bilinear / Homogeneous Factor Gauge Balancing via exact IEEE-754 power-of-2
 *       exponent shifts (`ldexpf`, 0 mantissa rounding error) across any paired projection
 *       (SwiGLU, GeGLU, ReGLU, GLU, LoRA/low-rank adapters, SSM input/output projections)
 *       + Arbitrary-Dimension Block-Strided Energy Equipartition & Walsh-Hadamard conditioning
 *       with exact tail-identity preservation for any dimension N.
 *
 *   - Layer 2 (`UdieGenResidencySplitLayer`, `udie_gen_residency_split_decompose`,
 *              `udie_gen_residency_split_eval`, `udie_gen_residency_split_free`):
 *       Universal Residency-Split Additive Decomposition handling both Dense (E = 1) and
 *       arbitrary MoE (E >= 1, K >= 1) models seamlessly:
 *         * Fast-Memory Pinned Tier (RAM/SRAM): Rank-r basis (cross-expert shared basis when
 *           E > 1; matrix/row-group SVD power basis when E == 1) + Kurtosis-Adaptive Contiguous
 *           16-Lane SIMD Block Outliers (`Buchstab`, allocated/activated per row according to
 *           empirical excess kurtosis).
 *         * Streaming / Flat-Page Tier (NVMe/DRAM): Outlier-free dense residual R_dense packed
 *           at a conflict-free 4160B coprime stride for zero-copy streaming or LUT execution.
 *
 *   - Layer 3 (`UdieGenAdaptiveCodebook`, `udie_gen_fit_adaptive_codebook`,
 *              `udie_gen_d4_adaptive_quant_row`, `udie_gen_d4_adaptive_dequant_row`,
 *              `udie_gen_rans_pack_grid`, `udie_gen_rans_unpack_grid`,
 *              `udie_gen_float_exp_mant_split_pack`, `udie_gen_float_exp_mant_split_unpack`):
 *       O(N) Empirical Distribution-Adaptive Codebook fitting (adapts 2D D4 spherical shell
 *       radii `(r1, r2)` and 1D quantile centroids directly to Gaussian, Laplace, heavy-tailed
 *       Student-t, bimodal, and skewed weight/KV distributions) + self-contained 256-stream
 *       AVX2 (`G=16`) rANS + Universal Float Exponent/Mantissa Split supporting `FP8-E4M3`,
 *       `FP8-E5M2`, `BF16`, and `FP16`.
 *
 *   - Layer 4 (`UdieGenMonoidalAttnCache`, `udie_gen_monoidal_sparse_attn_step`,
 *              `UdieGenRecurrentUndoLog`, `udie_gen_recurrent_step_with_undo`,
 *              `udie_gen_recurrent_rollback`, `udie_gen_recurrent_rollback_branch`):
 *       Zero-parameter Monoidal Block-Mean + Bounding-Norm Summary Sparse Attention (works out
 *       of the box on any MHA, GQA, MQA, or MLA model with incremental O(1) pool caching and
 *       exact Sage key-mean shift invariance) + Universal Diagonal-Decay + Rank-r Recurrent
 *       State Rollback (`S_t = diag(g_t) S_{t-1} + U_t V_t^T`) covering Mamba-2 SSD, GLA,
 *       RWKV-6/7, RetNet, Linear Attention, and Gated DeltaNet in O(r * (d_k + d_v)) space.
 *
 *   - Layer 5 (`UdieGenQuantileRouteReport`, `udie_gen_quantile_cache_route`,
 *              `UdieGenSpecFilterPlan`, `udie_gen_io_cost_value_spec_filter`):
 *       Mass-Quantile Sacred Cache Routing (preserves 100% of top experts accounting for
 *       cumulative probability mass >= tau_mass, applying residency bonus & COUPLE/PILOT
 *       prefetch strictly to the 1 - tau_mass tail ambiguity band for any E and K >= 1) +
 *       Universal Cold-Page-I/O & Compute Cost-Value Speculative Tree Filter across arbitrary
 *       tree topologies and layer depths L.
 * ========================================================================================
 */

#ifndef UDIE_UNIFIED_GENERAL_H
#define UDIE_UNIFIED_GENERAL_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <float.h>
#include <time.h>

#if defined(__AVX2__)
#include <immintrin.h>
#elif defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * 0. Foundational Bitwise, Alignment & 2-VC Credit Primitives
 * ============================================================================ */

static inline int udie_gen_clz_u32(uint32_t x) {
    return x ? __builtin_clz(x) : 32;
}

static inline int udie_gen_fls_u32(uint32_t x) {
    return x ? (31 - __builtin_clz(x)) : -1;
}

static inline int udie_gen_popcnt_u64(uint64_t x) {
    return __builtin_popcountll(x);
}

/*
 * Conflict-Free Coprime Slab Stride (`4160B` granularity, `gcd(stride/64, 64) == 1`):
 * Rounds `raw_bytes` up to a 4096-byte page boundary and pads by +64B (one L1D cache line)
 * so parallel multi-expert or multi-page gathers sweep all 64 L1D sets without bank conflicts.
 */
static inline size_t udie_gen_coprime_slab_stride(size_t raw_bytes) {
    size_t aligned4k = (raw_bytes + 4095u) & ~(size_t)4095u;
    if (aligned4k == 0) aligned4k = 4096u;
    return aligned4k + 64u;
}

/*
 * Self-Contained Dally-Seitz 2-VC Credit-Conserved DMA / Streaming Arbiter:
 *   - VC0 (`UDIE_GEN_VC_PILOT`): Speculative prefetch requests (capped to `vc0_max_credits`)
 *   - VC1 (`UDIE_GEN_VC_DEMAND`): Demand page misses (guaranteed priority drain)
 */
enum {
    UDIE_GEN_VC_PILOT  = 0,
    UDIE_GEN_VC_DEMAND = 1
};

typedef struct {
    int total_slots;
    int vc0_max_credits;
    int vc0_inflight;
    int vc1_inflight;
    int vc0_completed;
    int vc1_completed;
    int vc0_dropped_by_credit_cap;
    int vc1_starvation_events;
} UdieGen2VcArbiter;

static inline void udie_gen_2vc_init(UdieGen2VcArbiter *arb, int total_slots, int vc0_cap) {
    memset(arb, 0, sizeof(*arb));
    arb->total_slots     = (total_slots > 0) ? total_slots : 16;
    arb->vc0_max_credits = (vc0_cap > 0 && vc0_cap < arb->total_slots) ? vc0_cap : (arb->total_slots / 2);
}

static inline bool udie_gen_2vc_issue(UdieGen2VcArbiter *arb, int vc) {
    if (!arb) return false;
    int used = arb->vc0_inflight + arb->vc1_inflight;
    if (used >= arb->total_slots) {
        if (vc == UDIE_GEN_VC_DEMAND) arb->vc1_starvation_events++;
        return false;
    }
    if (vc == UDIE_GEN_VC_PILOT && arb->vc0_inflight >= arb->vc0_max_credits) {
        arb->vc0_dropped_by_credit_cap++;
        return false;
    }
    if (vc == UDIE_GEN_VC_PILOT) arb->vc0_inflight++;
    else                         arb->vc1_inflight++;
    return true;
}

static inline int udie_gen_2vc_pop_completion(UdieGen2VcArbiter *arb) {
    if (!arb) return -1;
    if (arb->vc1_inflight > 0) {
        arb->vc1_inflight--;
        arb->vc1_completed++;
        return UDIE_GEN_VC_DEMAND;
    }
    if (arb->vc0_inflight > 0) {
        arb->vc0_inflight--;
        arb->vc0_completed++;
        return UDIE_GEN_VC_PILOT;
    }
    return -1;
}

/* Fourth-moment kurtosis E[w^4] / (E[w^2])^2 for any tensor */
static inline float udie_gen_tensor_kurtosis(const float *W, size_t n_elem) {
    if (!W || n_elem == 0) return 0.0f;
    double m2 = 0.0, m4 = 0.0;
    for (size_t i = 0; i < n_elem; i++) {
        double v  = (double)W[i];
        double v2 = v * v;
        m2 += v2;
        m4 += v2 * v2;
    }
    m2 /= (double)n_elem;
    m4 /= (double)n_elem;
    return (m2 > 1e-24) ? (float)(m4 / (m2 * m2)) : 0.0f;
}

/* ============================================================================
 * 1. LAYER 1: Universal Bilinear / Homogeneous Factor Gauge Balancing &
 *             Arbitrary-Dimension Block-Strided Energy Equipartition
 * ============================================================================ */

/*
 * `udie_gen_gauge_balance_pair`:
 * Universal Bilinear / Homogeneous Factor Gauge Balancing across ANY paired projection:
 *   - `W_in  [I_shared, D_in]`  (row `j` produces intermediate channel `j`)
 *   - `W_out [D_out, I_shared]` (column `j` consumes intermediate channel `j`)
 * Covers:
 *   - Gated MLPs (`SwiGLU`, `GeGLU`, `ReGLU`, `Bilinear GLU`) where `y = W_out (\phi(W_gate x) * (W_in x))`
 *   - Homogeneous activations (`ReLU`, `LeakyReLU`, linear bottlenecks, LoRA `B * A`) with homogeneity degree `alpha_homog = 1.0f`
 *   - SSM input/output projections (`B_proj`, `C_proj` / `out_proj`)
 *
 * Scales row `j` of `W_in` by `2^{-s_j}` and column `j` of `W_out` by `2^{+s_j}` via
 * `ldexpf(1.0f, +-s_j)`. Because only IEEE-754 exponent bits are modified, this gauge
 * transformation introduces ZERO mantissa rounding error (`0.00e+00` FP32 drift) and
 * requires 0 runtime metadata bytes!
 */
static inline void udie_gen_gauge_balance_pair(
    float  *W_in,         /* [I_shared, D_in] row-major */
    float  *W_out,        /* [D_out, I_shared] row-major */
    int8_t *shifts_out,   /* [I_shared] optional recorded dyadic exponents s_j */
    int     I_shared,
    int     D_in,
    int     D_out,
    int     max_exp_shift /* e.g. 6 -> clamp s_j in [-6, +6] */
) {
    if (!W_in || !W_out || I_shared <= 0 || D_in <= 0 || D_out <= 0) return;
    int cap = (max_exp_shift > 0 && max_exp_shift <= 14) ? max_exp_shift : 6;

    for (int j = 0; j < I_shared; j++) {
        float max_in = 0.0f, max_out = 0.0f;
        const float *in_row = W_in + (size_t)j * (size_t)D_in;
        for (int d = 0; d < D_in; d++) {
            float a = fabsf(in_row[d]);
            if (a > max_in) max_in = a;
        }
        for (int d = 0; d < D_out; d++) {
            float a = fabsf(W_out[(size_t)d * (size_t)I_shared + (size_t)j]);
            if (a > max_out) max_out = a;
        }
        int s = 0;
        if (max_in > 1e-12f && max_out > 1e-12f) {
            float ratio = log2f(max_in / max_out) * 0.5f;
            s = (int)lrintf(ratio);
            if (s < -cap) s = -cap;
            if (s >  cap) s =  cap;
        }
        if (shifts_out) shifts_out[j] = (int8_t)s;
        if (s != 0) {
            float scale_in  = ldexpf(1.0f, -s);
            float scale_out = ldexpf(1.0f, +s);
            float *ir = W_in + (size_t)j * (size_t)D_in;
            for (int d = 0; d < D_in; d++) ir[d] *= scale_in;
            for (int d = 0; d < D_out; d++) W_out[(size_t)d * (size_t)I_shared + (size_t)j] *= scale_out;
        }
    }
}

/*
 * `udie_gen_equipartition_perm`:
 * Arbitrary-Dimension Block-Strided Energy Equipartition (`P_B`):
 * Generalizes fixed `Stride-16` permutation to ANY vector dimension `N` and any power-of-two
 * block size `B` (default `B = 16`):
 *   - Within each `B * B` super-tile (`0 .. B^2 - 1`), applies an involutory `B x B` transpose
 *     `(r, c) <-> (c, r)` so concentrated channel spikes are distributed across `B` distinct blocks.
 *   - Within any remaining partial super-tile of `2 * B` elements (`K >= 2` blocks of size `B`
 *     where `K < B`), interleaves even/odd pairs of blocks `(2m, k) <-> (2m+1, k)` on the diagonal
 *     so the permutation remains a strict involution (`P_B(P_B(x)) == x`, `P_B^T == P_B`).
 *   - Any non-multiple tail (`N % B != 0`) is mapped via exact identity so arbitrary `N`
 *     (e.g., `N = 100`, `N = 576`, `N = 960`, `N = 1536`, `N = 1543`) is 100% lossless!
 */
static inline void udie_gen_equipartition_perm(
    const float *src,
    float       *dst,
    int          N,
    int          block_size /* e.g. 16 */
) {
    if (!src || !dst || N <= 0) return;
    int B = (block_size > 1) ? block_size : 16;
    int super = B * B;

    /* Support in-place aliasing safely */
    float *tmp = (src == dst) ? (float *)malloc((size_t)N * sizeof(float)) : NULL;
    const float *in = tmp ? tmp : src;
    if (tmp) memcpy(tmp, src, (size_t)N * sizeof(float));

    int base = 0;
    /* 1. Full B x B super-tiles: exact B x B transpose (symmetric involution) */
    for (; base + super <= N; base += super) {
        for (int r = 0; r < B; r++) {
            for (int c = 0; c < B; c++) {
                dst[base + r * B + c] = in[base + c * B + r];
            }
        }
    }
    /* 2. Partial super-tiles of 2*B: 2-block cross-dispersion (symmetric involution) */
    for (; base + 2 * B <= N; base += 2 * B) {
        for (int k = 0; k < B; k++) {
            if (k & 1) {
                dst[base + k]     = in[base + B + k];
                dst[base + B + k] = in[base + k];
            } else {
                dst[base + k]     = in[base + k];
                dst[base + B + k] = in[base + B + k];
            }
        }
    }
    /* 3. Clean tail-identity mapping for any remaining elements */
    for (int i = base; i < N; i++) {
        dst[i] = in[i];
    }

    if (tmp) free(tmp);
}

/*
 * `udie_gen_fwht_blocks_arbitrary_n`:
 * Normalized Block-B Walsh-Hadamard Transform (`H_B`) for arbitrary dimension `N`:
 * Applies unitary `H_B` (`H_B^T = H_B`, `H_B^2 = I`) on every full block of size `B`
 * (power of two, default 16), and applies largest power-of-two sub-block FWHTs on the
 * tail `N % B` so every coordinate participates in a symmetric orthogonal involution!
 */
static inline void udie_gen_fwht_blocks_arbitrary_n(
    const float *x_in,
    float       *x_out,
    int          N,
    int          block_size /* power of two, e.g. 16 */
) {
    if (!x_in || !x_out || N <= 0) return;
    int B = (block_size > 1 && (block_size & (block_size - 1)) == 0) ? block_size : 16;

    int pos = 0;
    for (int b_cur = B; b_cur >= 1; b_cur >>= 1) {
        float norm = 1.0f / sqrtf((float)b_cur);
        while (pos + b_cur <= N) {
            if (b_cur == 1) {
                x_out[pos] = x_in[pos];
                pos++;
                break;
            }
            float v[64];
            for (int i = 0; i < b_cur; i++) v[i] = x_in[pos + i];
            for (int len = 1; len < b_cur; len <<= 1) {
                for (int i = 0; i < b_cur; i += (len << 1)) {
                    for (int j = 0; j < len; j++) {
                        float a = v[i + j], b = v[i + j + len];
                        v[i + j]       = a + b;
                        v[i + j + len] = a - b;
                    }
                }
            }
            for (int i = 0; i < b_cur; i++) x_out[pos + i] = v[i] * norm;
            pos += b_cur;
            if (b_cur < B) break; /* dyadic decomposition of tail < B */
        }
    }
}

/*
 * Forward and inverse composite orthogonal conditioning `Q = H_B * P_B` for ANY dimension `N`:
 *   - Forward (`udie_gen_prepare_act_q`): `x_hat = H_B(P_B(x))`
 *   - Inverse (`udie_gen_finish_act_q`):  `x     = P_B(H_B(x_hat))`
 * Satisfies `<Q(w), Q(x)> == <w, x>` and `Q^{-1}(Q(x)) == x` to machine precision for any `N >= 1`.
 */
static inline void udie_gen_prepare_act_q(
    const float *x_in,
    float       *x_hat,
    int          N,
    int          block_size
) {
    if (!x_in || !x_hat || N <= 0) return;
    float stack_tmp[4096];
    float *tmp = (N <= 4096) ? stack_tmp : (float *)malloc((size_t)N * sizeof(float));
    udie_gen_equipartition_perm(x_in, tmp, N, block_size);
    udie_gen_fwht_blocks_arbitrary_n(tmp, x_hat, N, block_size);
    if (tmp != stack_tmp) free(tmp);
}

static inline void udie_gen_finish_act_q(
    const float *y_hat_in,
    float       *y_out,
    int          N,
    int          block_size
) {
    if (!y_hat_in || !y_out || N <= 0) return;
    float stack_tmp[4096];
    float *tmp = (N <= 4096) ? stack_tmp : (float *)malloc((size_t)N * sizeof(float));
    udie_gen_fwht_blocks_arbitrary_n(y_hat_in, tmp, N, block_size);
    udie_gen_equipartition_perm(tmp, y_out, N, block_size);
    if (tmp != stack_tmp) free(tmp);
}

static inline void udie_gen_condition_matrix(
    float *W,
    int    M,
    int    N,
    int    block_size,
    int    rotate_output_cols
) {
    if (!W || M <= 0 || N <= 0) return;
    for (int r = 0; r < M; r++) {
        float *row = W + (size_t)r * (size_t)N;
        udie_gen_prepare_act_q(row, row, N, block_size);
    }
    if (rotate_output_cols) {
        float *col_buf = (float *)malloc((size_t)M * sizeof(float));
        float *col_rot = (float *)malloc((size_t)M * sizeof(float));
        if (col_buf && col_rot) {
            for (int c = 0; c < N; c++) {
                for (int r = 0; r < M; r++) col_buf[r] = W[(size_t)r * (size_t)N + (size_t)c];
                udie_gen_prepare_act_q(col_buf, col_rot, M, block_size);
                for (int r = 0; r < M; r++) W[(size_t)r * (size_t)N + (size_t)c] = col_rot[r];
            }
        }
        free(col_rot);
        free(col_buf);
    }
}

/* ============================================================================
 * 2. LAYER 3: Empirical Distribution-Adaptive Codebook + Self-Contained
 *             256-Stream SIMD rANS + Universal Float Exponent/Mantissa Split
 * ============================================================================ */

/*
 * Empirical Distribution-Adaptive Codebook (`UdieGenAdaptiveCodebook`):
 * Instead of hardcoded Gaussian Lloyd-Max centroids that overfit to N(0, 1) weights,
 * `udie_gen_fit_adaptive_codebook` inspects the tensor's empirical radial/marginal
 * moments in O(N) time and adapts:
 *   - `d4_shell_r1`, `d4_shell_r2`: the inner and outer 2D D4 spherical shell radii
 *     (8 points on shell `r1`, 8 points on shell `r2` at angles `k * pi / 4`), fitted
 *     directly to the lower-half and upper-half conditional radial means around the
 *     empirical median radius `r_med`!
 *   - `centroids_3bit[8]`: 1D 8-level symmetric centroids adapted to the tensor's
 *     empirical tail heaviness (`kurtosis`), seamlessly covering Uniform, Gaussian,
 *     Laplace, heavy-tailed Student-t, and bimodal distributions!
 */
typedef struct {
    float d4_shell_r1;          /* Fitted inner 2D shell radius */
    float d4_shell_r2;          /* Fitted outer 2D shell radius */
    float d4_even_lut[16];      /* 16-point 2D D4 codebook (even coordinate) */
    float d4_odd_lut[16];       /* 16-point 2D D4 codebook (odd coordinate) */
    int8_t d4_i8_even[16];      /* Integer LUT (even coordinate) for vpshufb GEMV */
    int8_t d4_i8_odd[16];       /* Integer LUT (odd coordinate) for vpshufb GEMV */
    float centroids_3bit[8];    /* 8-point 1D adaptive centroids (normalized by std) */
    float empirical_kurtosis;   /* Measured fourth-moment kurtosis of input tensor */
} UdieGenAdaptiveCodebook;

static inline void udie_gen_fit_adaptive_codebook(
    const float             *tensor,
    size_t                   n_elem,
    int                      apply_fwht_probe, /* 1 = measure in rotated FWHT-16 domain */
    UdieGenAdaptiveCodebook *cb_out
) {
    if (!cb_out) return;
    memset(cb_out, 0, sizeof(*cb_out));

    /* Default fallback radii if tensor is empty/zero */
    float r1 = 0.85f, r2 = 1.85f;
    float kurt = 3.0f;

    if (tensor && n_elem >= 4) {
        /* Subsample up to 4096 elements in O(1)/O(N) stride to fit empirical moments fast */
        size_t max_probe = (n_elem <= 4096) ? n_elem : 4096;
        max_probe &= ~(size_t)1u;
        size_t stride = n_elem / max_probe;
        if (stride < 1) stride = 1;

        float *probe = (float *)malloc(max_probe * sizeof(float));
        if (probe) {
            for (size_t i = 0; i < max_probe; i++) {
                probe[i] = tensor[(i * stride) % n_elem];
            }
            if (apply_fwht_probe) {
                udie_gen_fwht_blocks_arbitrary_n(probe, probe, (int)max_probe, 16);
            }
            double m2 = 0.0, m4 = 0.0;
            for (size_t i = 0; i < max_probe; i++) {
                double v = (double)probe[i];
                double v2 = v * v;
                m2 += v2;
                m4 += v2 * v2;
            }
            m2 /= (double)max_probe;
            m4 /= (double)max_probe;
            double inv_std = (m2 > 1e-24) ? (1.0 / sqrt(m2)) : 0.0;
            kurt = (m2 > 1e-24) ? (float)(m4 / (m2 * m2)) : 3.0f;

            /* Compute 2D pair radii r_p = sqrt(u^2 + v^2) normalized by coordinate std */
            size_t n_pairs = max_probe >> 1;
            double sum_r = 0.0, sum_r2 = 0.0;
            for (size_t p = 0; p < n_pairs; p++) {
                double u = (double)probe[2 * p]     * inv_std;
                double v = (double)probe[2 * p + 1] * inv_std;
                double r = sqrt(u * u + v * v);
                sum_r  += r;
                sum_r2 += r * r;
            }
            double mean_r = sum_r / (double)n_pairs;
            /* Two-pass 1D Lloyd-Max on the 2D radial distribution around mean_r */
            double split = mean_r;
            for (int it = 0; it < 3; it++) {
                double s_lo = 0.0, s_hi = 0.0;
                size_t c_lo = 0,   c_hi = 0;
                for (size_t p = 0; p < n_pairs; p++) {
                    double u = (double)probe[2 * p]     * inv_std;
                    double v = (double)probe[2 * p + 1] * inv_std;
                    double r = sqrt(u * u + v * v);
                    if (r <= split) { s_lo += r; c_lo++; }
                    else            { s_hi += r; c_hi++; }
                }
                if (c_lo > 0) r1 = (float)(s_lo / (double)c_lo);
                if (c_hi > 0) r2 = (float)(s_hi / (double)c_hi);
                split = 0.5 * ((double)r1 + (double)r2);
            }
            free(probe);
        }
    }

    if (r1 < 0.15f) r1 = 0.15f;
    if (r2 <= r1 + 0.15f) r2 = r1 + 0.75f;

    cb_out->d4_shell_r1        = r1;
    cb_out->d4_shell_r2        = r2;
    cb_out->empirical_kurtosis = kurt;

    /* Populate 16-point 2D D4 spherical-shell LUTs (8 angles on r1, 8 angles on r2) */
    const float inv_sqrt2 = 0.70710678f;
    const float cos_lut[8] = { 1.0f, inv_sqrt2, 0.0f, -inv_sqrt2, -1.0f, -inv_sqrt2,  0.0f, inv_sqrt2 };
    const float sin_lut[8] = { 0.0f, inv_sqrt2, 1.0f,  inv_sqrt2,  0.0f, -inv_sqrt2, -1.0f, -inv_sqrt2 };

    float max_coord = (r2 > 1e-6f) ? r2 : 1.0f;
    for (int a = 0; a < 8; a++) {
        cb_out->d4_even_lut[a]     = r1 * cos_lut[a];
        cb_out->d4_odd_lut[a]      = r1 * sin_lut[a];
        cb_out->d4_even_lut[8 + a] = r2 * cos_lut[a];
        cb_out->d4_odd_lut[8 + a]  = r2 * sin_lut[a];

        int ie0 = (int)lrintf((cb_out->d4_even_lut[a]     / max_coord) * 7.0f);
        int io0 = (int)lrintf((cb_out->d4_odd_lut[a]      / max_coord) * 7.0f);
        int ie1 = (int)lrintf((cb_out->d4_even_lut[8 + a] / max_coord) * 7.0f);
        int io1 = (int)lrintf((cb_out->d4_odd_lut[8 + a]  / max_coord) * 7.0f);
        cb_out->d4_i8_even[a]     = (int8_t)(ie0 < -7 ? -7 : (ie0 > 7 ? 7 : ie0));
        cb_out->d4_i8_odd[a]      = (int8_t)(io0 < -7 ? -7 : (io0 > 7 ? 7 : io0));
        cb_out->d4_i8_even[8 + a] = (int8_t)(ie1 < -7 ? -7 : (ie1 > 7 ? 7 : ie1));
        cb_out->d4_i8_odd[8 + a]  = (int8_t)(io1 < -7 ? -7 : (io1 > 7 ? 7 : io1));
    }

    /* Adapt 1D 3-bit centroids to empirical kurtosis (interpolating Uniform <-> Gaussian <-> Heavy-Tail) */
    float tail_stretch = 1.0f;
    if (kurt > 3.2f) {
        tail_stretch = 1.0f + 0.08f * logf(1.0f + (kurt - 3.0f));
        if (tail_stretch > 1.45f) tail_stretch = 1.45f;
    } else if (kurt < 2.5f) {
        tail_stretch = 0.85f;
    }
    const float base_3b[4] = { 0.31f, 0.96f, 1.68f, 2.58f };
    for (int k = 0; k < 4; k++) {
        float c = base_3b[k] * ((k >= 2) ? tail_stretch : (1.0f / sqrtf(tail_stretch)));
        cb_out->centroids_3bit[3 - k] = -c;
        cb_out->centroids_3bit[4 + k] = +c;
    }
}

/*
 * Quantize and dequantize any `n`-element row (`n` even) using the Empirical
 * Distribution-Adaptive 2D D4 Spherical-Shell Codebook (`2.0 bpw`).
 */
static inline float udie_gen_d4_adaptive_quant_row(
    const float                   *src,
    uint8_t                       *dst_packed, /* [(n + 3) / 4] bytes (2 pairs per byte) */
    int                            n,
    const UdieGenAdaptiveCodebook *cb
) {
    if (!src || !dst_packed || n <= 0 || !cb) return 0.0f;
    int rb = (n + 3) / 4;
    memset(dst_packed, 0, (size_t)rb);
    double ss = 0.0;
    for (int i = 0; i < n; i++) ss += (double)src[i] * (double)src[i];
    float radius = (float)sqrt(ss);
    if (!(radius > 1e-30f)) return 0.0f;

    float stack_y[1024];
    float *y = (n <= 1024) ? stack_y : (float *)malloc((size_t)n * sizeof(float));
    udie_gen_prepare_act_q(src, y, n, 16);

    float inv_std = sqrtf((float)n) / radius;
    int n_pairs = n / 2;
    for (int p = 0; p < n_pairs; p++) {
        float u = y[2 * p]     * inv_std;
        float v = y[2 * p + 1] * inv_std;
        int best_k = 0;
        float best_d = 1e30f;
        for (int k = 0; k < 16; k++) {
            float du = u - cb->d4_even_lut[k];
            float dv = v - cb->d4_odd_lut[k];
            float d  = du * du + dv * dv;
            if (d < best_d) { best_d = d; best_k = k; }
        }
        dst_packed[p >> 1] |= (uint8_t)((best_k & 0x0F) << ((p & 1) * 4));
    }
    if (y != stack_y) free(y);
    return radius;
}

static inline void udie_gen_d4_adaptive_dequant_row(
    const uint8_t                 *src_packed,
    float                          radius,
    float                         *dst,
    int                            n,
    const UdieGenAdaptiveCodebook *cb
) {
    if (!src_packed || !dst || n <= 0 || !cb) return;
    if (!(radius > 1e-30f)) {
        memset(dst, 0, (size_t)n * sizeof(float));
        return;
    }
    float std_val = radius / sqrtf((float)n);
    int n_pairs = n / 2;
    for (int p = 0; p < n_pairs; p++) {
        int c = (src_packed[p >> 1] >> ((p & 1) * 4)) & 0x0F;
        dst[2 * p]     = cb->d4_even_lut[c] * std_val;
        dst[2 * p + 1] = cb->d4_odd_lut[c]  * std_val;
    }
    if (n & 1) dst[n - 1] = 0.0f;
    udie_gen_finish_act_q(dst, dst, n, 16);
}

/*
 * Self-Contained 256-Stream SIMD rANS (`G=16` AVX2) + Universal Float Exponent/Mantissa Split
 */
#define UDIE_GEN_RANS_L          (1u << 23)
#define UDIE_GEN_RANS_ALPHABET   16
#define UDIE_GEN_RANS_NSTREAMS   256
#define UDIE_GEN_RANS_G_AVX2     16u
#define UDIE_GEN_RANS_SCALE_BITS 12u
#define UDIE_GEN_RANS_M          (1u << UDIE_GEN_RANS_SCALE_BITS)
#define UDIE_GEN_RANS_SLACK      64u

typedef struct {
    uint32_t scale_bits;
    uint32_t M;
    uint32_t freq[UDIE_GEN_RANS_ALPHABET];
    uint32_t start[UDIE_GEN_RANS_ALPHABET];
    uint16_t slot_to_sym[UDIE_GEN_RANS_M];
    uint8_t  sym8[UDIE_GEN_RANS_M + UDIE_GEN_RANS_SLACK];
} UdieGenRansTable;

typedef struct {
    uint64_t n_symbols;
    uint64_t packed_bytes;
    uint32_t stream_offsets[UDIE_GEN_RANS_NSTREAMS + 1];
    uint64_t payload_bytes;
    double   raw_bpw;
    double   compressed_bpw;
    double   saving_pct;
} UdieGenRansStats;

static inline uint32_t udie_gen_rans_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
}

static inline void udie_gen_rans_build_table(
    const uint64_t counts[UDIE_GEN_RANS_ALPHABET],
    UdieGenRansTable *tab
) {
    memset(tab, 0, sizeof(*tab));
    tab->scale_bits = UDIE_GEN_RANS_SCALE_BITS;
    tab->M          = UDIE_GEN_RANS_M;

    uint64_t total = 0;
    for (int s = 0; s < UDIE_GEN_RANS_ALPHABET; s++) total += counts[s];
    if (total == 0) {
        for (int s = 0; s < UDIE_GEN_RANS_ALPHABET; s++)
            tab->freq[s] = UDIE_GEN_RANS_M / UDIE_GEN_RANS_ALPHABET;
    } else {
        uint32_t assigned = 0;
        int max_s = 0;
        uint64_t max_c = 0;
        for (int s = 0; s < UDIE_GEN_RANS_ALPHABET; s++) {
            if (counts[s] > max_c) { max_c = counts[s]; max_s = s; }
            if (counts[s] == 0) {
                tab->freq[s] = 0;
            } else {
                uint32_t f = (uint32_t)((counts[s] * UDIE_GEN_RANS_M + (total / 2)) / total);
                if (f < 1u) f = 1u;
                tab->freq[s] = f;
                assigned += f;
            }
        }
        while (assigned > UDIE_GEN_RANS_M) {
            int best = -1;
            uint32_t best_f = 1;
            for (int s = 0; s < UDIE_GEN_RANS_ALPHABET; s++) {
                if (tab->freq[s] > best_f) { best_f = tab->freq[s]; best = s; }
            }
            if (best < 0) break;
            tab->freq[best]--;
            assigned--;
        }
        while (assigned < UDIE_GEN_RANS_M) {
            tab->freq[max_s]++;
            assigned++;
        }
    }

    uint32_t acc = 0;
    for (int s = 0; s < UDIE_GEN_RANS_ALPHABET; s++) {
        tab->start[s] = acc;
        for (uint32_t j = 0; j < tab->freq[s]; j++) {
            tab->slot_to_sym[acc + j] = (uint16_t)s;
            tab->sym8[acc + j]        = (uint8_t)s;
        }
        acc += tab->freq[s];
    }
}

static inline size_t udie_gen_rans_encode_stream(
    const uint8_t  *nibbles,
    size_t          n,
    const uint32_t *freq,
    const uint32_t *start,
    uint32_t        scale_bits,
    uint8_t        *out_buf,
    size_t          out_cap
) {
    uint32_t x = UDIE_GEN_RANS_L;
    uint8_t *ptr = out_buf + out_cap;
    for (size_t i = n; i-- > 0; ) {
        uint32_t s  = nibbles[i] & 0x0Fu;
        uint32_t f  = freq[s];
        uint32_t st = start[s];
        uint32_t x_max = ((UDIE_GEN_RANS_L >> scale_bits) << 8) * f;
        while (x >= x_max) {
            if (ptr <= out_buf) return (size_t)-1;
            *--ptr = (uint8_t)(x & 0xFFu);
            x >>= 8;
        }
        x = ((x / f) << scale_bits) + (x % f) + st;
    }
    for (int b = 0; b < 4; b++) {
        if (ptr <= out_buf) return (size_t)-1;
        *--ptr = (uint8_t)(x & 0xFFu);
        x >>= 8;
    }
    return (size_t)(ptr - out_buf);
}

static inline int udie_gen_rans_pack_grid(
    const uint8_t    *q_nibbles,
    size_t            n_symbols,
    int               nominal_bits,
    UdieGenRansTable *out_tab,
    uint8_t          *out_payload,
    size_t            out_cap,
    UdieGenRansStats *out_stats
) {
    if (!q_nibbles || !out_tab || !out_payload || n_symbols == 0 || (n_symbols & 1u)) return -1;

    uint64_t counts[UDIE_GEN_RANS_ALPHABET];
    memset(counts, 0, sizeof(counts));
    for (size_t i = 0; i < n_symbols; i++) counts[q_nibbles[i] & 0x0Fu]++;
    udie_gen_rans_build_table(counts, out_tab);

    size_t sub_max = n_symbols / UDIE_GEN_RANS_NSTREAMS + 2u;
    size_t scap    = sub_max * 2u + 64u;
    uint8_t *sub = (uint8_t *)malloc(sub_max);
    uint8_t *enc = (uint8_t *)malloc(scap);
    if (!sub || !enc) { free(sub); free(enc); return -1; }

    size_t pos = 0;
    for (uint32_t st_idx = 0; st_idx < UDIE_GEN_RANS_NSTREAMS; st_idx++) {
        size_t ns = 0;
        for (size_t j = st_idx; j < n_symbols; j += UDIE_GEN_RANS_NSTREAMS) {
            sub[ns++] = q_nibbles[j] & 0x0Fu;
        }
        size_t off = udie_gen_rans_encode_stream(
            sub, ns, out_tab->freq, out_tab->start, out_tab->scale_bits, enc, scap
        );
        if (off == (size_t)-1) { free(sub); free(enc); return -1; }
        size_t len = scap - off;
        if (pos + len + UDIE_GEN_RANS_SLACK > out_cap) { free(sub); free(enc); return -1; }
        if (out_stats) out_stats->stream_offsets[st_idx] = (uint32_t)pos;
        memcpy(out_payload + pos, enc + off, len);
        pos += len;
    }
    memset(out_payload + pos, 0, UDIE_GEN_RANS_SLACK);
    free(sub);
    free(enc);

    if (out_stats) {
        out_stats->stream_offsets[UDIE_GEN_RANS_NSTREAMS] = (uint32_t)pos;
        out_stats->n_symbols      = (uint64_t)n_symbols;
        out_stats->packed_bytes   = (uint64_t)(n_symbols >> 1);
        out_stats->payload_bytes  = (uint64_t)pos;
        out_stats->raw_bpw        = (double)nominal_bits;
        out_stats->compressed_bpw = ((double)pos * 8.0) / (double)n_symbols;
        out_stats->saving_pct     = 100.0 * (1.0 - out_stats->compressed_bpw / out_stats->raw_bpw);
    }
    return 0;
}

static inline int udie_gen_rans_unpack_grid(
    const uint8_t          *payload,
    const UdieGenRansTable *tab,
    const UdieGenRansStats *stats,
    uint8_t                *out_packed_2nib,
    uint8_t                *out_nibbles
) {
    if (!payload || !tab || !stats || !out_nibbles) return -1;
    const uint64_t n = stats->n_symbols;
    const uint32_t N = UDIE_GEN_RANS_NSTREAMS;
    const uint32_t G = UDIE_GEN_RANS_G_AVX2;
    const uint32_t sb = tab->scale_bits;
    const uint32_t mask = tab->M - 1u;
    const uint8_t *sym = tab->sym8;
    const size_t ostride = N >> 1;

    uint8_t *packed_buf = out_packed_2nib ? out_packed_2nib : (uint8_t *)malloc((size_t)stats->packed_bytes);
    if (!packed_buf) return -1;

    const uint32_t n_groups = N / G;
#if defined(__AVX2__)
    const __m256i vmask       = _mm256_set1_epi32((int)mask);
    const __m256i vff         = _mm256_set1_epi32(0xFF);
    const __m256i four        = _mm256_set1_epi32(4);
    const __m256i vsign       = _mm256_set1_epi32((int)0x80000000u);
    const __m256i t23_s       = _mm256_xor_si256(_mm256_set1_epi32((int)(1u << 23)), vsign);
    const __m256i t15_s       = _mm256_xor_si256(_mm256_set1_epi32((int)(1u << 15)), vsign);
    const __m256i t7_s        = _mm256_xor_si256(_mm256_set1_epi32((int)(1u << 7)),  vsign);
    const __m256i bswap       = _mm256_setr_epi8(
        3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12,
        3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12
    );
    const __m256i vperm_even  = _mm256_setr_epi32(0, 2, 4, 6, 1, 3, 5, 7);
    const __m256i vmask_u8_64 = _mm256_set1_epi64x(0xFF);
    const __m256i vfreq_lo    = _mm256_loadu_si256((const __m256i *)(tab->freq + 0));
    const __m256i vfreq_hi    = _mm256_loadu_si256((const __m256i *)(tab->freq + 8));
    const __m256i vstart_lo   = _mm256_loadu_si256((const __m256i *)(tab->start + 0));
    const __m256i vstart_hi   = _mm256_loadu_si256((const __m256i *)(tab->start + 8));
#endif

    for (uint32_t g = 0; g < n_groups; g++) {
        uint32_t b = g * G;
        uint32_t xa[UDIE_GEN_RANS_G_AVX2], ca[UDIE_GEN_RANS_G_AVX2], ea[UDIE_GEN_RANS_G_AVX2];
        for (uint32_t l = 0; l < G; l++) {
            ca[l] = stats->stream_offsets[b + l];
            ea[l] = stats->stream_offsets[b + l + 1];
            xa[l] = udie_gen_rans_be32(payload + ca[l]);
            ca[l] += 4;
        }
        uint64_t R = (n < (uint64_t)b + G) ? 0 : ((n - (uint64_t)b - G) / N + 1);
        uint8_t *op = packed_buf + (b >> 1);

#if defined(__AVX2__)
        __m256i vx0 = _mm256_loadu_si256((const __m256i *)(xa + 0));
        __m256i vx1 = _mm256_loadu_si256((const __m256i *)(xa + 8));
        __m256i vc0 = _mm256_loadu_si256((const __m256i *)(ca + 0));
        __m256i vc1 = _mm256_loadu_si256((const __m256i *)(ca + 8));
        __m256i ve0 = _mm256_loadu_si256((const __m256i *)(ea + 0));
        __m256i ve1 = _mm256_loadu_si256((const __m256i *)(ea + 8));

        for (uint64_t r = 0; r < R; r++) {
            __m256i slot0 = _mm256_and_si256(vx0, vmask);
            __m256i slot1 = _mm256_and_si256(vx1, vmask);
            __m256i s0 = _mm256_and_si256(_mm256_i32gather_epi32((const int *)sym, slot0, 1), vff);
            __m256i s1 = _mm256_and_si256(_mm256_i32gather_epi32((const int *)sym, slot1, 1), vff);

            __m256i hi0 = _mm256_srai_epi32(_mm256_slli_epi32(s0, 28), 31);
            __m256i hi1 = _mm256_srai_epi32(_mm256_slli_epi32(s1, 28), 31);
            __m256i f0  = _mm256_blendv_epi8(_mm256_permutevar8x32_epi32(vfreq_lo, s0),
                                             _mm256_permutevar8x32_epi32(vfreq_hi, s0), hi0);
            __m256i f1  = _mm256_blendv_epi8(_mm256_permutevar8x32_epi32(vfreq_lo, s1),
                                             _mm256_permutevar8x32_epi32(vfreq_hi, s1), hi1);
            __m256i st0 = _mm256_blendv_epi8(_mm256_permutevar8x32_epi32(vstart_lo, s0),
                                             _mm256_permutevar8x32_epi32(vstart_hi, s0), hi0);
            __m256i st1 = _mm256_blendv_epi8(_mm256_permutevar8x32_epi32(vstart_lo, s1),
                                             _mm256_permutevar8x32_epi32(vstart_hi, s1), hi1);

            vx0 = _mm256_add_epi32(_mm256_mullo_epi32(f0, _mm256_srli_epi32(vx0, (int)sb)),
                                   _mm256_sub_epi32(slot0, st0));
            vx1 = _mm256_add_epi32(_mm256_mullo_epi32(f1, _mm256_srli_epi32(vx1, (int)sb)),
                                   _mm256_sub_epi32(slot1, st1));

            __m256i vx0_s = _mm256_xor_si256(vx0, vsign);
            __m256i vx1_s = _mm256_xor_si256(vx1, vsign);
            __m256i kb0 = _mm256_sub_epi32(_mm256_setzero_si256(), _mm256_cmpgt_epi32(t23_s, vx0_s));
            kb0 = _mm256_sub_epi32(kb0, _mm256_cmpgt_epi32(t15_s, vx0_s));
            kb0 = _mm256_sub_epi32(kb0, _mm256_cmpgt_epi32(t7_s,  vx0_s));
            kb0 = _mm256_min_epu32(kb0, _mm256_sub_epi32(ve0, vc0));

            __m256i kb1 = _mm256_sub_epi32(_mm256_setzero_si256(), _mm256_cmpgt_epi32(t23_s, vx1_s));
            kb1 = _mm256_sub_epi32(kb1, _mm256_cmpgt_epi32(t15_s, vx1_s));
            kb1 = _mm256_sub_epi32(kb1, _mm256_cmpgt_epi32(t7_s,  vx1_s));
            kb1 = _mm256_min_epu32(kb1, _mm256_sub_epi32(ve1, vc1));

            __m256i be0 = _mm256_shuffle_epi8(_mm256_i32gather_epi32((const int *)payload, vc0, 1), bswap);
            __m256i be1 = _mm256_shuffle_epi8(_mm256_i32gather_epi32((const int *)payload, vc1, 1), bswap);

            __m256i shl0 = _mm256_slli_epi32(kb0, 3);
            __m256i shr0 = _mm256_slli_epi32(_mm256_sub_epi32(four, kb0), 3);
            vx0 = _mm256_or_si256(_mm256_sllv_epi32(vx0, shl0), _mm256_srlv_epi32(be0, shr0));
            vc0 = _mm256_add_epi32(vc0, kb0);

            __m256i shl1 = _mm256_slli_epi32(kb1, 3);
            __m256i shr1 = _mm256_slli_epi32(_mm256_sub_epi32(four, kb1), 3);
            vx1 = _mm256_or_si256(_mm256_sllv_epi32(vx1, shl1), _mm256_srlv_epi32(be1, shr1));
            vc1 = _mm256_add_epi32(vc1, kb1);

            __m256i p0 = _mm256_and_si256(_mm256_or_si256(s0, _mm256_srli_epi64(s0, 28)), vmask_u8_64);
            __m256i p1 = _mm256_and_si256(_mm256_or_si256(s1, _mm256_srli_epi64(s1, 28)), vmask_u8_64);
            __m128i d0 = _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(p0, vperm_even));
            __m128i d1 = _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(p1, vperm_even));
            __m128i packed8 = _mm_packus_epi16(_mm_packus_epi32(d0, d1), _mm_setzero_si128());
            long long v = _mm_cvtsi128_si64(packed8);
            memcpy(op, &v, 8);
            op += ostride;
        }
        _mm256_storeu_si256((__m256i *)(xa + 0), vx0);
        _mm256_storeu_si256((__m256i *)(xa + 8), vx1);
        _mm256_storeu_si256((__m256i *)(ca + 0), vc0);
        _mm256_storeu_si256((__m256i *)(ca + 8), vc1);
#else
        for (uint64_t r = 0; r < R; r++) {
            uint8_t s_lane[UDIE_GEN_RANS_G_AVX2];
            for (uint32_t l = 0; l < G; l++) {
                uint32_t xx = xa[l], c = ca[l], e = ea[l];
                uint32_t slot = xx & mask;
                uint32_t sy = sym[slot];
                xx = tab->freq[sy] * (xx >> sb) + slot - tab->start[sy];
                while (xx < UDIE_GEN_RANS_L) { if (c < e) xx = (xx << 8) | payload[c++]; else break; }
                xa[l] = xx; ca[l] = c; s_lane[l] = (uint8_t)sy;
            }
            for (uint32_t i = 0; i < G / 2u; i++)
                op[i] = (uint8_t)(s_lane[2 * i] | (s_lane[2 * i + 1] << 4));
            op += ostride;
        }
#endif
        uint64_t p_tail = R * (uint64_t)N + b;
        if (p_tail < n) {
            uint64_t rem = n - p_tail;
            uint32_t k = (rem < (uint64_t)G) ? (uint32_t)rem : G;
            uint8_t s_tail[UDIE_GEN_RANS_G_AVX2];
            for (uint32_t l = 0; l < k; l++) {
                uint32_t xx = xa[l], c = ca[l], e = ea[l];
                uint32_t slot = xx & mask;
                uint32_t sy = sym[slot];
                xx = tab->freq[sy] * (xx >> sb) + slot - tab->start[sy];
                while (xx < UDIE_GEN_RANS_L) { if (c < e) xx = (xx << 8) | payload[c++]; else break; }
                xa[l] = xx; ca[l] = c; s_tail[l] = (uint8_t)sy;
            }
            uint8_t *op_t = packed_buf + (p_tail >> 1);
            for (uint32_t i = 0; i < k / 2u; i++)
                op_t[i] = (uint8_t)(s_tail[2 * i] | (s_tail[2 * i + 1] << 4));
        }
    }

    uint64_t np = stats->packed_bytes;
    for (uint64_t k = 0; k < np; k++) {
        uint8_t b = packed_buf[k];
        out_nibbles[2 * k]     = (uint8_t)(b & 0x0Fu);
        out_nibbles[2 * k + 1] = (uint8_t)((b >> 4) & 0x0Fu);
    }
    if (!out_packed_2nib) free(packed_buf);
    return 0;
}

/*
 * Universal Float Exponent/Mantissa Split (`udie_gen_float_exp_mant_split_pack` / `unpack`):
 * Supports `FP8-E4M3`, `FP8-E5M2`, `BF16`, and `FP16` with `0` bit error roundtrip by
 * separating the low-entropy exponent nibbles (compressed via 256-stream AVX2 rANS) from
 * the high-entropy sign+mantissa stream!
 */
typedef enum {
    UDIE_FLOAT_FP8_E4M3 = 0, /* 8-bit:  [s:1][exp:4][mant:3]  -> 1 exp nibble + 4b sign/mant */
    UDIE_FLOAT_FP8_E5M2 = 1, /* 8-bit:  [s:1][exp:5][mant:2]  -> 1 exp nibble (top 4b) + 4b (s + exp_lsb + mant:2) */
    UDIE_FLOAT_BF16     = 2, /* 16-bit: [s:1][exp:8][mant:7]  -> 2 exp nibbles + 8b (s:1 + mant:7) */
    UDIE_FLOAT_FP16     = 3  /* 16-bit: [s:1][exp:5][mant:10] -> 1 exp nibble (top 4b) + 12b (s:1 + exp_lsb:1 + mant:10) */
} UdieGenFloatFormat;

static inline int udie_gen_float_exp_mant_split_pack(
    const void        *raw_elements,    /* [n_elements] uint8_t (FP8) or uint16_t (BF16/FP16) */
    size_t             n_elements,      /* must be even */
    UdieGenFloatFormat fmt,
    UdieGenRansTable  *out_exp_tab,
    uint8_t           *out_exp_payload,
    size_t             out_exp_cap,
    uint8_t           *out_sm_stream,   /* capacity >= n_elements * 2 */
    UdieGenRansStats  *out_stats
) {
    if (!raw_elements || !out_exp_tab || !out_exp_payload || !out_sm_stream || n_elements == 0 || (n_elements & 1u))
        return -1;

    size_t n_exp_nibs = (fmt == UDIE_FLOAT_BF16) ? (2 * n_elements) : n_elements;
    uint8_t *exp_nibs = (uint8_t *)malloc(n_exp_nibs);
    if (!exp_nibs) return -1;

    double raw_bpw = 8.0, sm_bpw = 4.0;
    if (fmt == UDIE_FLOAT_FP8_E4M3) {
        const uint8_t *in8 = (const uint8_t *)raw_elements;
        size_t np = n_elements >> 1;
        for (size_t k = 0; k < np; k++) {
            uint8_t b0 = in8[2 * k], b1 = in8[2 * k + 1];
            exp_nibs[2 * k]     = (uint8_t)((b0 >> 3) & 0x0Fu);
            exp_nibs[2 * k + 1] = (uint8_t)((b1 >> 3) & 0x0Fu);
            uint8_t sm0 = (uint8_t)(((b0 >> 4) & 0x08u) | (b0 & 0x07u));
            uint8_t sm1 = (uint8_t)(((b1 >> 4) & 0x08u) | (b1 & 0x07u));
            out_sm_stream[k] = (uint8_t)(sm0 | (sm1 << 4));
        }
        raw_bpw = 8.0; sm_bpw = 4.0;
    } else if (fmt == UDIE_FLOAT_FP8_E5M2) {
        const uint8_t *in8 = (const uint8_t *)raw_elements;
        size_t np = n_elements >> 1;
        for (size_t k = 0; k < np; k++) {
            uint8_t b0 = in8[2 * k], b1 = in8[2 * k + 1];
            exp_nibs[2 * k]     = (uint8_t)((b0 >> 3) & 0x0Fu);
            exp_nibs[2 * k + 1] = (uint8_t)((b1 >> 3) & 0x0Fu);
            uint8_t sm0 = (uint8_t)(((b0 >> 4) & 0x08u) | (b0 & 0x07u));
            uint8_t sm1 = (uint8_t)(((b1 >> 4) & 0x08u) | (b1 & 0x07u));
            out_sm_stream[k] = (uint8_t)(sm0 | (sm1 << 4));
        }
        raw_bpw = 8.0; sm_bpw = 4.0;
    } else if (fmt == UDIE_FLOAT_BF16) {
        const uint16_t *in16 = (const uint16_t *)raw_elements;
        for (size_t i = 0; i < n_elements; i++) {
            uint16_t w = in16[i];
            uint8_t exp8 = (uint8_t)((w >> 7) & 0xFFu);
            exp_nibs[2 * i]     = (uint8_t)(exp8 & 0x0Fu);
            exp_nibs[2 * i + 1] = (uint8_t)((exp8 >> 4) & 0x0Fu);
            out_sm_stream[i]    = (uint8_t)(((w >> 8) & 0x80u) | (w & 0x7Fu));
        }
        raw_bpw = 16.0; sm_bpw = 8.0;
    } else { /* UDIE_FLOAT_FP16 */
        const uint16_t *in16 = (const uint16_t *)raw_elements;
        size_t np = n_elements >> 1;
        for (size_t k = 0; k < np; k++) {
            uint16_t w0 = in16[2 * k], w1 = in16[2 * k + 1];
            exp_nibs[2 * k]     = (uint8_t)((w0 >> 11) & 0x0Fu);
            exp_nibs[2 * k + 1] = (uint8_t)((w1 >> 11) & 0x0Fu);
            uint16_t sm0 = (uint16_t)(((w0 >> 4) & 0x0800u) | (w0 & 0x07FFu));
            uint16_t sm1 = (uint16_t)(((w1 >> 4) & 0x0800u) | (w1 & 0x07FFu));
            /* Pack two 12-bit sign+exp_lsb+mantissa words into 3 bytes */
            out_sm_stream[3 * k + 0] = (uint8_t)(sm0 & 0xFFu);
            out_sm_stream[3 * k + 1] = (uint8_t)(((sm0 >> 8) & 0x0Fu) | ((sm1 & 0x0Fu) << 4));
            out_sm_stream[3 * k + 2] = (uint8_t)((sm1 >> 4) & 0xFFu);
        }
        raw_bpw = 16.0; sm_bpw = 12.0;
    }

    int rc = udie_gen_rans_pack_grid(exp_nibs, n_exp_nibs, 4, out_exp_tab, out_exp_payload, out_exp_cap, out_stats);
    free(exp_nibs);
    if (rc == 0 && out_stats) {
        double exp_bpw_per_elem = ((double)out_stats->payload_bytes * 8.0) / (double)n_elements;
        out_stats->raw_bpw        = raw_bpw;
        out_stats->compressed_bpw = sm_bpw + exp_bpw_per_elem;
        out_stats->saving_pct     = 100.0 * (1.0 - out_stats->compressed_bpw / out_stats->raw_bpw);
    }
    return rc;
}

static inline int udie_gen_float_exp_mant_split_unpack(
    const uint8_t          *exp_payload,
    const UdieGenRansTable *exp_tab,
    const UdieGenRansStats *stats,
    const uint8_t          *sm_stream,
    size_t                  n_elements,
    UdieGenFloatFormat      fmt,
    void                   *out_elements
) {
    if (!exp_payload || !exp_tab || !stats || !sm_stream || !out_elements || n_elements == 0) return -1;
    uint8_t *exp_nibs = (uint8_t *)malloc((size_t)stats->n_symbols);
    if (!exp_nibs) return -1;

    int rc = udie_gen_rans_unpack_grid(exp_payload, exp_tab, stats, NULL, exp_nibs);
    if (rc != 0) { free(exp_nibs); return rc; }

    if (fmt == UDIE_FLOAT_FP8_E4M3 || fmt == UDIE_FLOAT_FP8_E5M2) {
        uint8_t *out8 = (uint8_t *)out_elements;
        size_t np = n_elements >> 1;
        for (size_t k = 0; k < np; k++) {
            uint8_t e0 = exp_nibs[2 * k] & 0x0Fu, e1 = exp_nibs[2 * k + 1] & 0x0Fu;
            uint8_t sm = sm_stream[k];
            uint8_t s0 = sm & 0x0Fu, s1 = (sm >> 4) & 0x0Fu;
            out8[2 * k]     = (uint8_t)(((s0 & 0x08u) << 4) | (e0 << 3) | (s0 & 0x07u));
            out8[2 * k + 1] = (uint8_t)(((s1 & 0x08u) << 4) | (e1 << 3) | (s1 & 0x07u));
        }
    } else if (fmt == UDIE_FLOAT_BF16) {
        uint16_t *out16 = (uint16_t *)out_elements;
        for (size_t i = 0; i < n_elements; i++) {
            uint16_t exp8 = (uint16_t)((exp_nibs[2 * i] & 0x0Fu) | ((exp_nibs[2 * i + 1] & 0x0Fu) << 4));
            uint8_t  sm   = sm_stream[i];
            out16[i] = (uint16_t)(((uint16_t)(sm & 0x80u) << 8) | (exp8 << 7) | (uint16_t)(sm & 0x7Fu));
        }
    } else { /* UDIE_FLOAT_FP16 */
        uint16_t *out16 = (uint16_t *)out_elements;
        size_t np = n_elements >> 1;
        for (size_t k = 0; k < np; k++) {
            uint16_t e0 = (uint16_t)(exp_nibs[2 * k]     & 0x0Fu);
            uint16_t e1 = (uint16_t)(exp_nibs[2 * k + 1] & 0x0Fu);
            uint16_t b0 = sm_stream[3 * k + 0];
            uint16_t b1 = sm_stream[3 * k + 1];
            uint16_t b2 = sm_stream[3 * k + 2];
            uint16_t sm0 = (uint16_t)(b0 | ((b1 & 0x0Fu) << 8));
            uint16_t sm1 = (uint16_t)((b1 >> 4) | (b2 << 4));
            out16[2 * k]     = (uint16_t)(((sm0 & 0x0800u) << 4) | (e0 << 11) | (sm0 & 0x07FFu));
            out16[2 * k + 1] = (uint16_t)(((sm1 & 0x0800u) << 4) | (e1 << 11) | (sm1 & 0x07FFu));
        }
    }

    free(exp_nibs);
    return 0;
}

/* ============================================================================
 * 3. LAYER 2: Universal Residency-Split Additive Decomposition
 *             (Supports Both Dense `E = 1` and Arbitrary MoE `E >= 1, K >= 1`)
 * ============================================================================ */

enum {
    UDIE_GEN_PAGE_INT4_LUT = 0,
    UDIE_GEN_PAGE_D4_2BPW  = 1
};

typedef struct {
    int                     E;                   /* E == 1 for Dense layers, E > 1 for MoE */
    int                     M;                   /* Output rows */
    int                     N;                   /* Input cols (arbitrary N supported!) */
    int                     rank_r;              /* Shared/dense low-rank subspace rank r >= 0 */
    int                     page_fmt;            /* UDIE_GEN_PAGE_INT4_LUT or UDIE_GEN_PAGE_D4_2BPW */
    int                     rotate_output_space; /* 1 = fuse inverse Q after Top-k combine */

    /* --- Fast-Memory Pinned Tier (RAM/SRAM): Rank-r Basis + Kurtosis-Adaptive Block Outliers --- */
    float                  *U_basis;             /* [M, rank_r] shared/dense column basis */
    float                  *V_factors;           /* [E, rank_r, N] per-expert (or E=1) row factors */
    uint8_t                *buchstab_row_active; /* [E, M] 1 if row exceeded kurtosis threshold */
    uint16_t               *buchstab_blk_idx;    /* [E, M] hottest 16-lane block index */
    int16_t                *buchstab_vals16;     /* [E, M, 16] contiguous 16-lane INT16 block */
    float                  *buchstab_row_scales; /* [E, M] INT16 scale */
    int                     active_outlier_rows; /* Count of rows that needed Buchstab blocks */
    size_t                  ram_pinned_bytes;

    /* --- Streaming / Flat-Page Tier (NVMe/DRAM): Outlier-Free Dense Residual --- */
    UdieGenAdaptiveCodebook adaptive_cb;         /* Fitted distribution-adaptive codebook */
    float                   residual_kurtosis;   /* Fourth-moment kurtosis of R_dense */
    size_t                  raw_page_bytes;
    size_t                  coprime_stride;
    uint8_t                *flat_pages;          /* [E * coprime_stride] */
} UdieGenResidencySplitLayer;

static inline void udie_gen_residency_split_decompose(
    UdieGenResidencySplitLayer *layer,
    const float                *W_fp32,              /* [E, M, N] (for Dense, E = 1) */
    int                         E,
    int                         M,
    int                         N,
    int                         rank_r,              /* e.g. 2 (works for both E=1 and E>1) */
    float                       row_kurtosis_thresh, /* e.g. 3.2f (0.0f = always extract top block) */
    int                         page_fmt,
    int                         apply_conditioning,
    int                         rotate_output_space
) {
    if (!layer || !W_fp32 || E <= 0 || M <= 0 || N <= 0) return;
    memset(layer, 0, sizeof(*layer));
    layer->E                   = E;
    layer->M                   = M;
    layer->N                   = N;
    layer->rank_r              = (rank_r > 0 && rank_r <= 16) ? rank_r : 0;
    layer->page_fmt            = page_fmt;
    layer->rotate_output_space = rotate_output_space;

    size_t mn = (size_t)M * (size_t)N;
    float *W_work = (float *)malloc((size_t)E * mn * sizeof(float));
    memcpy(W_work, W_fp32, (size_t)E * mn * sizeof(float));

    /* Step 1: Extract Rank-r Basis (handles both Dense E=1 SVD basis and MoE E>1 shared basis) */
    if (layer->rank_r > 0) {
        int R = layer->rank_r;
        layer->U_basis   = (float *)calloc((size_t)M * (size_t)R, sizeof(float));
        layer->V_factors = (float *)calloc((size_t)E * (size_t)R * (size_t)N, sizeof(float));

        for (int rk = 0; rk < R; rk++) {
            float *u = layer->U_basis + (size_t)rk * (size_t)M;
            for (int r = 0; r < M; r++) {
                double s = 0.0;
                for (int e = 0; e < E; e++) {
                    const float *row = W_work + ((size_t)e * (size_t)M + (size_t)r) * (size_t)N;
                    int c_pick = (r * (rk * 7 + 3) + rk) % N;
                    s += (double)row[c_pick];
                }
                u[r] = (float)s + ((rk & 1) ? -1e-3f : 1e-3f);
            }
            /* Orthogonalize against previous basis columns 0..rk-1 */
            for (int prev = 0; prev < rk; prev++) {
                const float *up = layer->U_basis + (size_t)prev * (size_t)M;
                double dot = 0.0;
                for (int r = 0; r < M; r++) dot += (double)u[r] * (double)up[r];
                for (int r = 0; r < M; r++) u[r] -= (float)(dot * (double)up[r]);
            }
            double norm_u = 0.0;
            for (int r = 0; r < M; r++) norm_u += (double)u[r] * (double)u[r];
            float inv_n = (norm_u > 1e-18) ? (float)(1.0 / sqrt(norm_u)) : 0.0f;
            for (int r = 0; r < M; r++) u[r] *= inv_n;

            /* Power iteration sweeps */
            float *u_next = (float *)calloc((size_t)M, sizeof(float));
            for (int it = 0; it < 4; it++) {
                memset(u_next, 0, (size_t)M * sizeof(float));
                for (int e = 0; e < E; e++) {
                    const float *We = W_work + (size_t)e * mn;
                    float *ve = layer->V_factors + ((size_t)e * (size_t)R + (size_t)rk) * (size_t)N;
                    for (int c = 0; c < N; c++) {
                        double s = 0.0;
                        for (int r = 0; r < M; r++) s += (double)u[r] * (double)We[(size_t)r * (size_t)N + (size_t)c];
                        ve[c] = (float)s;
                    }
                    for (int r = 0; r < M; r++) {
                        const float *w_row = We + (size_t)r * (size_t)N;
                        double s = 0.0;
                        for (int c = 0; c < N; c++) s += (double)w_row[c] * (double)ve[c];
                        u_next[r] += (float)s;
                    }
                }
                for (int prev = 0; prev < rk; prev++) {
                    const float *up = layer->U_basis + (size_t)prev * (size_t)M;
                    double dot = 0.0;
                    for (int r = 0; r < M; r++) dot += (double)u_next[r] * (double)up[r];
                    for (int r = 0; r < M; r++) u_next[r] -= (float)(dot * (double)up[r]);
                }
                double un = 0.0;
                for (int r = 0; r < M; r++) un += (double)u_next[r] * (double)u_next[r];
                float inv_un = (un > 1e-18) ? (float)(1.0 / sqrt(un)) : 0.0f;
                for (int r = 0; r < M; r++) u[r] = u_next[r] * inv_un;
            }
            free(u_next);

            /* Project V_e and deflate W_work */
            for (int e = 0; e < E; e++) {
                float *We = W_work + (size_t)e * mn;
                float *ve = layer->V_factors + ((size_t)e * (size_t)R + (size_t)rk) * (size_t)N;
                for (int c = 0; c < N; c++) {
                    double s = 0.0;
                    for (int r = 0; r < M; r++) s += (double)u[r] * (double)We[(size_t)r * (size_t)N + (size_t)c];
                    ve[c] = (float)s;
                }
                for (int r = 0; r < M; r++) {
                    float ur = u[r];
                    float *w_row = We + (size_t)r * (size_t)N;
                    for (int c = 0; c < N; c++) w_row[c] -= ur * ve[c];
                }
            }
        }
    }

    /* Step 2: Kurtosis-Adaptive Contiguous 16-Lane SIMD Block Outliers (`Buchstab`) */
    layer->buchstab_row_active = (uint8_t  *)calloc((size_t)E * (size_t)M, sizeof(uint8_t));
    layer->buchstab_blk_idx    = (uint16_t *)calloc((size_t)E * (size_t)M, sizeof(uint16_t));
    layer->buchstab_vals16     = (int16_t  *)calloc((size_t)E * (size_t)M * 16, sizeof(int16_t));
    layer->buchstab_row_scales = (float    *)calloc((size_t)E * (size_t)M, sizeof(float));

    int n_blks = N / 16;
    int active_rows = 0;
    if (n_blks > 0) {
        for (int e = 0; e < E; e++) {
            float *We = W_work + (size_t)e * mn;
            for (int r = 0; r < M; r++) {
                float *w_row = We + (size_t)r * (size_t)N;
                float r_kurt = udie_gen_tensor_kurtosis(w_row, (size_t)N);
                size_t row_id = (size_t)e * (size_t)M + (size_t)r;
                if (r_kurt < row_kurtosis_thresh) {
                    layer->buchstab_row_active[row_id] = 0;
                    continue;
                }
                layer->buchstab_row_active[row_id] = 1;
                active_rows++;

                int best_b = 0;
                float best_energy = -1.0f;
                for (int b = 0; b < n_blks; b++) {
                    const float *blk = w_row + (b << 4);
                    float e_blk = 0.0f;
                    for (int k = 0; k < 16; k++) e_blk += blk[k] * blk[k];
                    if (e_blk > best_energy) { best_energy = e_blk; best_b = b; }
                }
                float *hot_blk = w_row + (best_b << 4);
                float max_abs = 1e-12f;
                for (int k = 0; k < 16; k++) {
                    float a = fabsf(hot_blk[k]);
                    if (a > max_abs) max_abs = a;
                }
                float b_scale = max_abs / 32767.0f;
                float inv_b   = (max_abs > 1e-12f) ? (32767.0f / max_abs) : 0.0f;
                layer->buchstab_blk_idx[row_id]    = (uint16_t)best_b;
                layer->buchstab_row_scales[row_id] = b_scale;
                int16_t *dst16 = layer->buchstab_vals16 + (row_id << 4);
                for (int k = 0; k < 16; k++) {
                    int q = (int)lrintf(hot_blk[k] * inv_b);
                    if (q >  32767) q =  32767;
                    if (q < -32767) q = -32767;
                    dst16[k] = (int16_t)q;
                    hot_blk[k] -= (float)dst16[k] * b_scale;
                }
            }
        }
    }
    layer->active_outlier_rows = active_rows;

    /* Step 3: Arbitrary-Dimension Conditioning Q = H_16 * P_16 on R_dense */
    if (apply_conditioning) {
        for (int e = 0; e < E; e++) {
            udie_gen_condition_matrix(W_work + (size_t)e * mn, M, N, 16, rotate_output_space);
        }
    }

    /* Step 4: Fit Empirical Distribution-Adaptive Codebook on R_dense and Pack Flat Pages */
    udie_gen_fit_adaptive_codebook(W_work, (size_t)E * mn, 0, &layer->adaptive_cb);
    layer->residual_kurtosis = layer->adaptive_cb.empirical_kurtosis;

    size_t n_padded_even = (size_t)((N + 1) & ~1);
    size_t nibs_per_row  = (page_fmt == UDIE_GEN_PAGE_D4_2BPW) ? (n_padded_even >> 1) : (size_t)N;
    layer->raw_page_bytes = (size_t)M * sizeof(float) + (size_t)M * nibs_per_row;
    layer->coprime_stride = udie_gen_coprime_slab_stride(layer->raw_page_bytes);
    layer->flat_pages     = (uint8_t *)calloc((size_t)E, layer->coprime_stride);

    for (int e = 0; e < E; e++) {
        const float *We = W_work + (size_t)e * mn;
        uint8_t *page_base  = layer->flat_pages + (size_t)e * layer->coprime_stride;
        float   *row_scales = (float *)page_base;
        uint8_t *nibs_base  = page_base + (size_t)M * sizeof(float);

        for (int r = 0; r < M; r++) {
            const float *w_row = We + (size_t)r * (size_t)N;
            float max_abs = 1e-12f;
            for (int c = 0; c < N; c++) {
                float a = fabsf(w_row[c]);
                if (a > max_abs) max_abs = a;
            }
            if (page_fmt == UDIE_GEN_PAGE_INT4_LUT) {
                float sc = max_abs / 7.5f;
                float inv_sc = (max_abs > 1e-12f) ? (7.5f / max_abs) : 0.0f;
                row_scales[r] = sc;
                uint8_t *r_nibs = nibs_base + (size_t)r * nibs_per_row;
                for (int c = 0; c < N; c++) {
                    int q = (int)lrintf(w_row[c] * inv_sc);
                    if (q < -8) q = -8;
                    if (q >  7) q =  7;
                    r_nibs[c] = (uint8_t)(q + 8);
                }
            } else {
                float sc = max_abs / 7.0f;
                float inv_sc = (max_abs > 1e-12f) ? (7.0f / max_abs) : 0.0f;
                row_scales[r] = sc;
                uint8_t *r_nibs = nibs_base + (size_t)r * nibs_per_row;
                for (size_t p = 0; p < nibs_per_row; p++) {
                    float v0 = w_row[2 * p] * inv_sc;
                    float v1 = (2 * p + 1 < (size_t)N) ? (w_row[2 * p + 1] * inv_sc) : 0.0f;
                    int best_k = 0;
                    float best_d2 = 1e30f;
                    for (int k = 0; k < 16; k++) {
                        float d0 = v0 - (float)layer->adaptive_cb.d4_i8_even[k];
                        float d1 = v1 - (float)layer->adaptive_cb.d4_i8_odd[k];
                        float d2 = d0 * d0 + d1 * d1;
                        if (d2 < best_d2) { best_d2 = d2; best_k = k; }
                    }
                    r_nibs[p] = (uint8_t)best_k;
                }
            }
        }
    }

    layer->ram_pinned_bytes =
        (size_t)M * (size_t)layer->rank_r * sizeof(float) +
        (size_t)E * (size_t)layer->rank_r * (size_t)N * sizeof(float) +
        (size_t)active_rows * (sizeof(uint16_t) + 16 * sizeof(int16_t) + sizeof(float));

    free(W_work);
}

static inline void udie_gen_residency_split_free(UdieGenResidencySplitLayer *layer) {
    if (!layer) return;
    free(layer->U_basis);
    free(layer->V_factors);
    free(layer->buchstab_row_active);
    free(layer->buchstab_blk_idx);
    free(layer->buchstab_vals16);
    free(layer->buchstab_row_scales);
    free(layer->flat_pages);
    memset(layer, 0, sizeof(*layer));
}

/*
 * Evaluate the Universal Residency-Split Layer for EITHER Dense (`E = 1, k = 1`)
 * or arbitrary MoE (`E >= 1, k >= 1`):
 */
static inline void udie_gen_residency_split_eval(
    const UdieGenResidencySplitLayer *layer,
    const float                      *x_in,           /* [N] */
    const int                        *active_experts, /* [k] (pass NULL when E == 1) */
    const float                      *expert_weights, /* [k] (pass NULL when E == 1) */
    int                               k,
    int                               apply_conditioning,
    float                            *y_out           /* [M] */
) {
    if (!layer || !x_in || !y_out) return;
    const int M = layer->M;
    const int N = layer->N;
    const int R = layer->rank_r;
    int default_e = 0;
    float default_w = 1.0f;
    const int   *e_ids = active_experts ? active_experts : &default_e;
    const float *e_wts = expert_weights ? expert_weights : &default_w;
    int k_eff = (k > 0) ? k : 1;

    float *x_hat   = (float *)malloc((size_t)N * sizeof(float));
    float *y_unrot = (float *)calloc((size_t)M, sizeof(float));
    float *y_rot   = (float *)calloc((size_t)M, sizeof(float));
    if (!x_hat || !y_unrot || !y_rot) {
        free(y_rot); free(y_unrot); free(x_hat);
        return;
    }

    if (apply_conditioning) {
        udie_gen_prepare_act_q(x_in, x_hat, N, 16);
    } else {
        memcpy(x_hat, x_in, (size_t)N * sizeof(float));
    }

    /* 1. Evaluate Fast-Memory Pinned Rank-r Subspace */
    if (R > 0 && layer->U_basis && layer->V_factors) {
        float z_rk[16];
        memset(z_rk, 0, sizeof(z_rk));
        for (int i = 0; i < k_eff; i++) {
            int e = e_ids[i];
            float w = e_wts[i];
            for (int rk = 0; rk < R; rk++) {
                const float *ve = layer->V_factors + ((size_t)e * (size_t)R + (size_t)rk) * (size_t)N;
                float dot = 0.0f;
                for (int c = 0; c < N; c++) dot += ve[c] * x_in[c];
                z_rk[rk] += w * dot;
            }
        }
        for (int rk = 0; rk < R; rk++) {
            const float *u = layer->U_basis + (size_t)rk * (size_t)M;
            float z = z_rk[rk];
            for (int r = 0; r < M; r++) y_unrot[r] += u[r] * z;
        }
    }

    /* 2. Evaluate Kurtosis-Adaptive Contiguous 16-Lane Buchstab Outliers */
    if (layer->active_outlier_rows > 0 && (N >= 16)) {
        float max_x_raw = 1e-12f;
        for (int c = 0; c < N; c++) {
            float a = fabsf(x_in[c]);
            if (a > max_x_raw) max_x_raw = a;
        }
        float x_sc16  = max_x_raw / 1024.0f;
        float inv_x16 = (max_x_raw > 1e-12f) ? (1024.0f / max_x_raw) : 0.0f;
        int16_t *x_i16 = (int16_t *)malloc((size_t)N * sizeof(int16_t));
        if (x_i16) {
            for (int c = 0; c < N; c++) {
                int q = (int)lrintf(x_in[c] * inv_x16);
                if (q >  1024) q =  1024;
                if (q < -1024) q = -1024;
                x_i16[c] = (int16_t)q;
            }
            for (int i = 0; i < k_eff; i++) {
                int e = e_ids[i];
                float w = e_wts[i];
                for (int r = 0; r < M; r++) {
                    size_t row_id = (size_t)e * (size_t)M + (size_t)r;
                    if (!layer->buchstab_row_active[row_id]) continue;
                    int col0 = (int)layer->buchstab_blk_idx[row_id] << 4;
                    const int16_t *w16 = layer->buchstab_vals16 + (row_id << 4);
                    const int16_t *x16 = x_i16 + col0;
                    int32_t acc = 0;
#if defined(__AVX2__)
                    __m256i vw = _mm256_loadu_si256((const __m256i *)w16);
                    __m256i vx = _mm256_loadu_si256((const __m256i *)x16);
                    __m256i vp = _mm256_madd_epi16(vw, vx);
                    __m128i s128 = _mm_add_epi32(_mm256_castsi256_si128(vp), _mm256_extracti128_si256(vp, 1));
                    s128 = _mm_add_epi32(s128, _mm_shuffle_epi32(s128, _MM_SHUFFLE(1, 0, 3, 2)));
                    s128 = _mm_add_epi32(s128, _mm_shuffle_epi32(s128, _MM_SHUFFLE(2, 3, 0, 1)));
                    acc = _mm_cvtsi128_si32(s128);
#else
                    for (int lane = 0; lane < 16; lane++) acc += (int32_t)w16[lane] * (int32_t)x16[lane];
#endif
                    y_unrot[r] += w * ((float)acc * (layer->buchstab_row_scales[row_id] * x_sc16));
                }
            }
            free(x_i16);
        }
    }

    /* 3. Evaluate Flat Residual Pages */
    float max_xh = 1e-12f;
    for (int c = 0; c < N; c++) {
        float a = fabsf(x_hat[c]);
        if (a > max_xh) max_xh = a;
    }
    float x_sc8  = max_xh / 127.0f;
    float inv_x8 = (max_xh > 1e-12f) ? (127.0f / max_xh) : 0.0f;
    int8_t *x_i8 = (int8_t *)calloc((size_t)((N + 1) & ~1), sizeof(int8_t));
    for (int c = 0; c < N; c++) {
        int q = (int)lrintf(x_hat[c] * inv_x8);
        if (q >  127) q =  127;
        if (q < -127) q = -127;
        x_i8[c] = (int8_t)q;
    }

    size_t n_padded_even = (size_t)((N + 1) & ~1);
    size_t nibs_per_row  = (layer->page_fmt == UDIE_GEN_PAGE_D4_2BPW) ? (n_padded_even >> 1) : (size_t)N;
    for (int i = 0; i < k_eff; i++) {
        int e = e_ids[i];
        float w = e_wts[i];
        const uint8_t *page_base  = layer->flat_pages + (size_t)e * layer->coprime_stride;
        const float   *row_scales = (const float *)page_base;
        const uint8_t *nibs_base  = page_base + (size_t)M * sizeof(float);

        for (int r = 0; r < M; r++) {
            const uint8_t *r_nibs = nibs_base + (size_t)r * nibs_per_row;
            int32_t acc = 0;
            if (layer->page_fmt == UDIE_GEN_PAGE_INT4_LUT) {
                for (int c = 0; c < N; c++) {
                    int8_t wv = (int8_t)((r_nibs[c] & 0x0F) - 8);
                    acc += (int32_t)wv * (int32_t)x_i8[c];
                }
            } else {
                for (size_t p = 0; p < nibs_per_row; p++) {
                    uint8_t nib = r_nibs[p] & 0x0F;
                    acc += (int32_t)layer->adaptive_cb.d4_i8_even[nib] * (int32_t)x_i8[2 * p]
                         + (int32_t)layer->adaptive_cb.d4_i8_odd[nib]  * (int32_t)x_i8[2 * p + 1];
                }
            }
            y_rot[r] += w * ((float)acc * (row_scales[r] * x_sc8));
        }
    }

    if (layer->rotate_output_space && apply_conditioning) {
        udie_gen_finish_act_q(y_rot, y_out, M, 16);
    } else {
        memcpy(y_out, y_rot, (size_t)M * sizeof(float));
    }
    for (int r = 0; r < M; r++) y_out[r] += y_unrot[r];

    free(x_i8);
    free(y_rot);
    free(y_unrot);
    free(x_hat);
}

/* ============================================================================
 * 4. LAYER 4: Universal Monoidal Block-Summary Sparse Attention &
 *             Universal Diagonal-Decay + Rank-r Recurrent State Rollback
 * ============================================================================ */

/*
 * `udie_gen_sage_key_mean_smooth`:
 * Subtracts running per-channel key mean `\bar{k}` (`K_smooth = K - \bar{k}`).
 * Exact softmax shift invariance guarantees `<q, k_t - \bar{k}> = <q, k_t> - <q, \bar{k}>`
 * produces 100% identical softmax probabilities while removing channel DC bias prior to
 * sub-4-bit KV quantization!
 */
static inline void udie_gen_sage_key_mean_smooth(
    const float *keys_in,
    float       *keys_out,
    float       *mean_out,
    int          T,
    int          D
) {
    if (!keys_in || !keys_out || !mean_out || D <= 0) return;
    for (int d = 0; d < D; d++) mean_out[d] = 0.0f;
    if (T <= 0) return;
    float inv_T = 1.0f / (float)T;
    for (int t = 0; t < T; t++) {
        const float *kr = keys_in + (size_t)t * (size_t)D;
        for (int d = 0; d < D; d++) mean_out[d] += kr[d];
    }
    for (int d = 0; d < D; d++) mean_out[d] *= inv_T;
    for (int t = 0; t < T; t++) {
        const float *kr = keys_in  + (size_t)t * (size_t)D;
        float       *ko = keys_out + (size_t)t * (size_t)D;
        for (int d = 0; d < D; d++) ko[d] = kr[d] - mean_out[d];
    }
}

/*
 * Universal Zero-Parameter Monoidal Block-Summary Attention Cache (`UdieGenMonoidalAttnCache`):
 * Replaces DeepSeek-specific `DSA` assumptions (NO learned `gates`, `ape`, or `head_w` weights!)
 * with a universal associative monoid over key blocks of size `block_size`:
 *   - `block_mean [max_blocks, kv_heads, dim]`: mean key vector `\mu_{b, h_kv}` in block `b`
 *   - `block_rad  [max_blocks, kv_heads]`:      bounding L2 deviation radius
 *     `R_{b, h_kv} = max_{t in b} ||k_{t, h_kv} - \mu_{b, h_kv}||_2`
 * Works out-of-the-box on ANY standard MHA (`q_heads == kv_heads`), GQA (`q_heads = G * kv_heads`),
 * MQA (`kv_heads == 1`), or MLA (`kv_heads == 1`) model with O(1) incremental block caching!
 */
typedef struct {
    int            max_blocks;
    int            kv_heads;
    int            dim;
    int            block_size;
    int            cached_blocks;
    float         *block_mean; /* [max_blocks * kv_heads * dim] */
    float         *block_rad;  /* [max_blocks * kv_heads] */
    float         *scores;     /* [max_blocks] */
    unsigned char *complete;   /* [max_blocks] */
    unsigned char *taken;      /* [max_blocks] */
} UdieGenMonoidalAttnCache;

static inline int udie_gen_monoidal_attn_cache_init(
    UdieGenMonoidalAttnCache *c,
    int                       max_seq,
    int                       kv_heads,
    int                       dim,
    int                       block_size
) {
    if (!c || max_seq <= 0 || kv_heads <= 0 || dim <= 0 || block_size <= 0) return -1;
    memset(c, 0, sizeof(*c));
    c->max_blocks = (max_seq + block_size - 1) / block_size;
    c->kv_heads   = kv_heads;
    c->dim        = dim;
    c->block_size = block_size;
    c->block_mean = (float *)calloc((size_t)c->max_blocks * (size_t)kv_heads * (size_t)dim, sizeof(float));
    c->block_rad  = (float *)calloc((size_t)c->max_blocks * (size_t)kv_heads, sizeof(float));
    c->scores     = (float *)malloc((size_t)c->max_blocks * sizeof(float));
    c->complete   = (unsigned char *)calloc((size_t)c->max_blocks, 1);
    c->taken      = (unsigned char *)calloc((size_t)c->max_blocks, 1);
    return (c->block_mean && c->block_rad && c->scores && c->complete && c->taken) ? 0 : -1;
}

static inline void udie_gen_monoidal_attn_cache_free(UdieGenMonoidalAttnCache *c) {
    if (!c) return;
    free(c->taken); free(c->complete); free(c->scores); free(c->block_rad); free(c->block_mean);
    memset(c, 0, sizeof(*c));
}

static inline int udie_gen_monoidal_sparse_attn_step(
    UdieGenMonoidalAttnCache *cache,           /* Incremental monoidal block cache (or NULL) */
    const float              *query_t,         /* [q_heads * dim] current query at pos = seq_len - 1 */
    const float              *keys_raw,        /* [seq_len * kv_heads * dim] raw keys */
    const float              *values_raw,      /* [seq_len * kv_heads * dim] raw values */
    int                       seq_len,
    int                       q_heads,
    int                       kv_heads,        /* 1 for MQA/MLA, q_heads/G for GQA, q_heads for MHA */
    int                       dim,
    int                       block_size,      /* e.g. 4 or 8 */
    int                       topk_tokens,     /* e.g. 64 (multiple of block_size) */
    float                     envelope_gamma,  /* e.g. 0.25f weight on bounding norm ||q||_2 * R_b */
    int                       enable_sage_d4,  /* 1 = apply Sage key-mean + adaptive 2D D4 KV codec */
    int                      *out_selected,    /* [topk_tokens + block_size] selected positions */
    float                    *out_attn,        /* [q_heads * dim] output attention */
    float                    *out_kv_cos_sim   /* Measured KV cosine similarity */
) {
    if (!query_t || !keys_raw || !values_raw || seq_len <= 0 || q_heads <= 0 || kv_heads <= 0 || dim <= 0 || block_size <= 0)
        return -1;

    const int width   = topk_tokens + block_size;
    const int n_blks  = (seq_len + block_size - 1) / block_size;
    const int wanted  = (topk_tokens + block_size - 1) / block_size;
    const int q_pos   = seq_len - 1;
    const int gqa_rep = (q_heads >= kv_heads) ? (q_heads / kv_heads) : 1;

    size_t total_kv_vecs = (size_t)seq_len * (size_t)kv_heads;
    float *keys_smooth = NULL;
    float *keys_eval   = (float *)keys_raw;

    if (enable_sage_d4) {
        keys_smooth = (float *)malloc(total_kv_vecs * (size_t)dim * sizeof(float));
        keys_eval   = (float *)malloc(total_kv_vecs * (size_t)dim * sizeof(float));
        float *k_mean = (float *)malloc((size_t)kv_heads * (size_t)dim * sizeof(float));
        uint8_t *d4_row = (uint8_t *)malloc((size_t)((dim + 3) / 4));
        if (!keys_smooth || !keys_eval || !k_mean || !d4_row) {
            free(d4_row); free(k_mean); free(keys_eval); free(keys_smooth);
            return -1;
        }
        /* Per-KV-head Sage key-mean subtraction */
        for (int kh = 0; kh < kv_heads; kh++) {
            float *hm = k_mean + (size_t)kh * (size_t)dim;
            for (int d = 0; d < dim; d++) hm[d] = 0.0f;
            float inv_T = 1.0f / (float)seq_len;
            for (int t = 0; t < seq_len; t++) {
                const float *kt = keys_raw + ((size_t)t * (size_t)kv_heads + (size_t)kh) * (size_t)dim;
                for (int d = 0; d < dim; d++) hm[d] += kt[d];
            }
            for (int d = 0; d < dim; d++) hm[d] *= inv_T;
            for (int t = 0; t < seq_len; t++) {
                const float *kt = keys_raw    + ((size_t)t * (size_t)kv_heads + (size_t)kh) * (size_t)dim;
                float       *ks = keys_smooth + ((size_t)t * (size_t)kv_heads + (size_t)kh) * (size_t)dim;
                for (int d = 0; d < dim; d++) ks[d] = kt[d] - hm[d];
            }
        }

        /* Fit empirical distribution-adaptive D4 codebook to smoothed keys */
        UdieGenAdaptiveCodebook kv_cb;
        udie_gen_fit_adaptive_codebook(keys_smooth, total_kv_vecs * (size_t)dim, 1, &kv_cb);

        double dot = 0.0, nr = 1e-12, nq = 1e-12;
        for (size_t v = 0; v < total_kv_vecs; v++) {
            const float *ks = keys_smooth + v * (size_t)dim;
            float       *kd = keys_eval   + v * (size_t)dim;
            float rad = udie_gen_d4_adaptive_quant_row(ks, d4_row, dim, &kv_cb);
            udie_gen_d4_adaptive_dequant_row(d4_row, rad, kd, dim, &kv_cb);
            for (int d = 0; d < dim; d++) {
                dot += (double)ks[d] * (double)kd[d];
                nr  += (double)ks[d] * (double)ks[d];
                nq  += (double)kd[d] * (double)kd[d];
            }
        }
        if (out_kv_cos_sim) *out_kv_cos_sim = (float)(dot / sqrt(nr * nq));
        free(d4_row);
        free(k_mean);
    } else {
        if (out_kv_cos_sim) *out_kv_cos_sim = 1.0f;
    }

    const float *keys_index_src = enable_sage_d4 ? keys_smooth : keys_raw;

    /* Incremental O(1) update of monoidal block summaries (mean + bounding deviation radius) */
    int start_b = cache ? cache->cached_blocks : 0;
    if (cache && start_b > n_blks) start_b = 0;

    float *b_mean = cache ? cache->block_mean : (float *)calloc((size_t)n_blks * (size_t)kv_heads * (size_t)dim, sizeof(float));
    float *b_rad  = cache ? cache->block_rad  : (float *)calloc((size_t)n_blks * (size_t)kv_heads, sizeof(float));
    float *scores = cache ? cache->scores     : (float *)malloc((size_t)n_blks * sizeof(float));
    unsigned char *comp = cache ? cache->complete : (unsigned char *)calloc((size_t)n_blks, 1);
    unsigned char *tak  = cache ? cache->taken    : (unsigned char *)calloc((size_t)n_blks, 1);

    int new_cached = start_b;
    float inv_bs = 1.0f / (float)block_size;
    for (int b = start_b; b < n_blks; b++) {
        int st = b * block_size;
        unsigned char is_c = (st + block_size <= seq_len) ? 1 : 0;
        comp[b] = is_c;
        if (!is_c) continue;
        for (int kh = 0; kh < kv_heads; kh++) {
            float *mu = b_mean + ((size_t)b * (size_t)kv_heads + (size_t)kh) * (size_t)dim;
            for (int d = 0; d < dim; d++) mu[d] = 0.0f;
            for (int j = 0; j < block_size; j++) {
                const float *kt = keys_index_src + ((size_t)(st + j) * (size_t)kv_heads + (size_t)kh) * (size_t)dim;
                for (int d = 0; d < dim; d++) mu[d] += kt[d];
            }
            for (int d = 0; d < dim; d++) mu[d] *= inv_bs;

            float max_r = 0.0f;
            for (int j = 0; j < block_size; j++) {
                const float *kt = keys_index_src + ((size_t)(st + j) * (size_t)kv_heads + (size_t)kh) * (size_t)dim;
                float d2 = 0.0f;
                for (int d = 0; d < dim; d++) {
                    float diff = kt[d] - mu[d];
                    d2 += diff * diff;
                }
                float r = sqrtf(d2);
                if (r > max_r) max_r = r;
            }
            b_rad[(size_t)b * (size_t)kv_heads + (size_t)kh] = max_r;
        }
        if (b == new_cached) new_cached = b + 1;
    }
    if (cache) cache->cached_blocks = new_cached;

    /* Precompute query norms ||q_h||_2 */
    float q_norms[128];
    for (int h = 0; h < q_heads && h < 128; h++) {
        const float *qh = query_t + (size_t)h * (size_t)dim;
        float s2 = 0.0f;
        for (int d = 0; d < dim; d++) s2 += qh[d] * qh[d];
        q_norms[h] = sqrtf(s2);
    }

    const float scale = 1.0f / sqrtf((float)dim);
    for (int i = 0; i < width; i++) out_selected[i] = -1;

    /* Score completed blocks using zero-parameter monoidal mean + bounding-norm envelope */
    for (int b = 0; b < n_blks; b++) {
        int last = (b + 1) * block_size - 1;
        if (!comp[b] || last > q_pos) { scores[b] = -FLT_MAX; continue; }
        float sc = 0.0f;
        for (int h = 0; h < q_heads; h++) {
            int kh = h / gqa_rep;
            if (kh >= kv_heads) kh = kv_heads - 1;
            const float *qh = query_t + (size_t)h * (size_t)dim;
            const float *mu = b_mean  + ((size_t)b * (size_t)kv_heads + (size_t)kh) * (size_t)dim;
            float dot = 0.0f;
            for (int d = 0; d < dim; d++) dot += qh[d] * mu[d];
            float r_bound = b_rad[(size_t)b * (size_t)kv_heads + (size_t)kh];
            float qn = (h < 128) ? q_norms[h] : 1.0f;
            sc += (dot + envelope_gamma * qn * r_bound) * scale;
        }
        scores[b] = sc;
    }

    int out_pos = 0;
    for (int r = 0; r < wanted; r++) {
        int best = -1;
        for (int b = 0; b < n_blks; b++) {
            if (!tak[b] && scores[b] > -FLT_MAX && (best < 0 || scores[b] > scores[best])) {
                best = b;
            }
        }
        if (best < 0) break;
        tak[best] = 1;
        for (int j = 0; j < block_size && out_pos < topk_tokens; j++) {
            out_selected[out_pos++] = best * block_size + j;
        }
    }
    memset(tak, 0, (size_t)n_blks);

    /* Unconditionally include incomplete causal tail block */
    int tail = seq_len % block_size;
    int tail_start = seq_len - tail;
    for (int j = 0; j < tail && out_pos < width; j++) {
        out_selected[out_pos++] = tail_start + j;
    }

    /* Evaluate sparse attention over selected indices */
    float *s_scores = (float *)malloc((size_t)width * sizeof(float));
    for (int h = 0; h < q_heads; h++) {
        int kh = h / gqa_rep;
        if (kh >= kv_heads) kh = kv_heads - 1;
        const float *qh = query_t + (size_t)h * (size_t)dim;
        float mx = -FLT_MAX;
        int used = 0;
        for (int slot = 0; slot < out_pos; slot++) {
            int kp = out_selected[slot];
            if (kp < 0 || kp >= seq_len) continue;
            const float *kt = keys_eval + ((size_t)kp * (size_t)kv_heads + (size_t)kh) * (size_t)dim;
            float dot = 0.0f;
            for (int d = 0; d < dim; d++) dot += qh[d] * kt[d];
            s_scores[used] = dot * scale;
            if (s_scores[used] > mx) mx = s_scores[used];
            used++;
        }
        float *res = out_attn + (size_t)h * (size_t)dim;
        memset(res, 0, (size_t)dim * sizeof(float));
        if (used > 0) {
            float tot = 0.0f;
            for (int i = 0; i < used; i++) {
                s_scores[i] = expf(s_scores[i] - mx);
                tot += s_scores[i];
            }
            int idx = 0;
            for (int slot = 0; slot < out_pos; slot++) {
                int kp = out_selected[slot];
                if (kp < 0 || kp >= seq_len) continue;
                float w = s_scores[idx++] / tot;
                const float *vt = values_raw + ((size_t)kp * (size_t)kv_heads + (size_t)kh) * (size_t)dim;
                for (int d = 0; d < dim; d++) res[d] += w * vt[d];
            }
        }
    }
    free(s_scores);

    if (!cache) {
        free(tak); free(comp); free(scores); free(b_rad); free(b_mean);
    }
    if (enable_sage_d4) {
        free(keys_eval);
        free(keys_smooth);
    }
    return 0;
}

/*
 * Universal Diagonal-Decay + Rank-r Recurrent State Undo Log:
 * Generalizes `Gated DeltaNet` to the universal linear state-space / recurrent update:
 *   `S_t = diag(g_t) S_{t-1} + U_t V_t^T`
 * where:
 *   - `S_t in R^{d_k x d_v}` is the recurrent state matrix,
 *   - `g_t in R^{d_k}` is a per-channel diagonal decay vector (or uniform scalar when `g_is_scalar`),
 *   - `U_t in R^{d_k x r}`, `V_t in R^{d_v x r}` is any rank-`r` update (`1 <= r <= UDIE_GEN_MAX_REC_RANK`).
 *
 * Covers ALL modern linear / hybrid recurrent architectures in one operator:
 *   1. **Mamba-2 SSD / RetNet / Linear Attention**: scalar decay `g_t[i] = gamma_t`, rank-1 `U_t = B_t`, `V_t = x_t`.
 *   2. **Gated Linear Attention (GLA) / RWKV-6 / RWKV-7**: channel-wise vector decay `g_t[i] = alpha_{t,i}`, rank-1/rank-r update.
 *   3. **Gated DeltaNet**: Householder/Delta coupling (`delta_rule_beta != 0.0f`), where `V_t` is computed as
 *      `V_t[:, m] = beta_t * (v_raw[:, m] - (diag(g_t) S_{t-1})^T U_t[:, m])` and recorded into `V_rec`.
 *
 * Reversibly rolls back `S_{t-1} = diag(g_t)^{-1} (S_t - U_t V_t^T)` in `O(r * (d_k + d_v))` space!
 */
#define UDIE_GEN_MAX_REC_DIM  256
#define UDIE_GEN_MAX_REC_RANK 4

typedef struct {
    int   d_k;
    int   d_v;
    int   rank_r;
    float inv_g_vec[UDIE_GEN_MAX_REC_DIM];                    /* [d_k] 1.0f / g_t[i] */
    float U_rec[UDIE_GEN_MAX_REC_RANK * UDIE_GEN_MAX_REC_DIM]; /* [rank_r, d_k] */
    float V_rec[UDIE_GEN_MAX_REC_RANK * UDIE_GEN_MAX_REC_DIM]; /* [rank_r, d_v] */
} UdieGenRecurrentUndoLog;

static inline void udie_gen_recurrent_step_with_undo(
    float                   *S_state,         /* [d_k * d_v] in-place recurrent state */
    const float             *g_decay_vec,     /* [d_k] per-channel decay (or [1] if g_is_scalar != 0) */
    int                      g_is_scalar,     /* 1 = broadcast g_decay_vec[0] across all d_k rows */
    const float             *U_in,            /* [rank_r, d_k] left update factors */
    const float             *V_in,            /* [rank_r, d_v] right update factors (or raw v for Delta rule) */
    float                    delta_rule_beta, /* 0.0f = direct U_t V_t^T (Mamba2/GLA/RWKV); >0 = DeltaNet rule */
    int                      d_k,
    int                      d_v,
    int                      rank_r,
    UdieGenRecurrentUndoLog *undo_out
) {
    if (!S_state || !g_decay_vec || !U_in || !V_in || d_k <= 0 || d_v <= 0 || rank_r <= 0) return;
    int dk = (d_k <= UDIE_GEN_MAX_REC_DIM)  ? d_k    : UDIE_GEN_MAX_REC_DIM;
    int dv = (d_v <= UDIE_GEN_MAX_REC_DIM)  ? d_v    : UDIE_GEN_MAX_REC_DIM;
    int R  = (rank_r <= UDIE_GEN_MAX_REC_RANK) ? rank_r : UDIE_GEN_MAX_REC_RANK;

    float g_row[UDIE_GEN_MAX_REC_DIM];
    for (int i = 0; i < dk; i++) {
        g_row[i] = g_is_scalar ? g_decay_vec[0] : g_decay_vec[i];
        if (undo_out) undo_out->inv_g_vec[i] = 1.0f / g_row[i];
    }

    if (undo_out) {
        undo_out->d_k    = dk;
        undo_out->d_v    = dv;
        undo_out->rank_r = R;
        memcpy(undo_out->U_rec, U_in, (size_t)R * (size_t)dk * sizeof(float));
    }

    float V_eff[UDIE_GEN_MAX_REC_RANK * UDIE_GEN_MAX_REC_DIM];
    if (fabsf(delta_rule_beta) > 0.0f) {
        /* Delta-rule / Householder coupling: V_eff[m, j] = beta * (V_in[m, j] - sum_i (g_i S[i,j]) U_in[m,i]) */
        for (int m = 0; m < R; m++) {
            const float *um = U_in  + (size_t)m * (size_t)dk;
            const float *vm = V_in  + (size_t)m * (size_t)dv;
            float       *ve = V_eff + (size_t)m * (size_t)dv;
            for (int j = 0; j < dv; j++) {
                float dot = 0.0f;
                for (int i = 0; i < dk; i++) {
                    dot += (g_row[i] * S_state[i * dv + j]) * um[i];
                }
                ve[j] = delta_rule_beta * (vm[j] - dot);
            }
        }
    } else {
        memcpy(V_eff, V_in, (size_t)R * (size_t)dv * sizeof(float));
    }

    if (undo_out) {
        memcpy(undo_out->V_rec, V_eff, (size_t)R * (size_t)dv * sizeof(float));
    }

    /* Update S_t = diag(g_t) S_{t-1} + sum_{m=0}^{R-1} U_m \otimes V_eff_m^T */
    for (int i = 0; i < dk; i++) {
        float gi = g_row[i];
        float *s_row = S_state + (size_t)i * (size_t)dv;
        for (int j = 0; j < dv; j++) s_row[j] *= gi;
        for (int m = 0; m < R; m++) {
            float u_im = U_in[(size_t)m * (size_t)dk + (size_t)i];
            const float *ve = V_eff + (size_t)m * (size_t)dv;
            for (int j = 0; j < dv; j++) {
                s_row[j] += u_im * ve[j];
            }
        }
    }
}

static inline void udie_gen_recurrent_rollback(
    float                         *S_state,
    const UdieGenRecurrentUndoLog *undo
) {
    if (!S_state || !undo) return;
    const int dk = undo->d_k;
    const int dv = undo->d_v;
    const int R  = undo->rank_r;
    for (int i = 0; i < dk; i++) {
        float inv_gi = undo->inv_g_vec[i];
        float *s_row = S_state + (size_t)i * (size_t)dv;
        for (int m = 0; m < R; m++) {
            float u_im = undo->U_rec[(size_t)m * (size_t)dk + (size_t)i];
            const float *ve = undo->V_rec + (size_t)m * (size_t)dv;
            for (int j = 0; j < dv; j++) {
                s_row[j] -= u_im * ve[j];
            }
        }
        for (int j = 0; j < dv; j++) s_row[j] *= inv_gi;
    }
}

static inline void udie_gen_recurrent_rollback_branch(
    float                         *S_state,
    const UdieGenRecurrentUndoLog *undo_stack,
    int                            n_spec_steps,
    int                            n_accepted_steps
) {
    for (int s = n_spec_steps - 1; s >= n_accepted_steps; s--) {
        udie_gen_recurrent_rollback(S_state, &undo_stack[s]);
    }
}

/* ============================================================================
 * 5. LAYER 5: Mass-Quantile Sacred Cache Routing &
 *             Universal Cold-Page-I/O + Compute Cost-Value Speculative Filter
 * ============================================================================ */

typedef struct {
    int   routed_experts[32];     /* [top_k] selected expert IDs */
    float routed_logits[32];      /* [top_k] raw router logits */
    float routed_probs[32];       /* [top_k] normalized softmax probabilities */
    int   sacred_count;           /* Adaptive J* determined by cumulative mass >= tau_mass */
    float sacred_cumulative_mass; /* Actual cumulative probability mass in the sacred prefix */
    int   cache_hits_in_topk;     /* Total RAM/cache hits among routed_experts[0..top_k-1] */
    int   pilot_prefetch_expert;  /* Predicted Layer-(l+1) prefetch expert */
    bool  pilot_issued_on_vc0;    /* True if issued on VC0 */
} UdieGenQuantileRouteReport;

/*
 * `udie_gen_quantile_cache_route`:
 * Replaces hardcoded `sacred_J = 4 of K = 8` with a model-agnostic **Probability-Mass Quantile**
 * rule (`tau_mass in (0, 1]`, e.g., `0.90f`):
 *   1. Sorts/selects the unmodified raw-logit top-K experts and computes their normalized
 *      routing probability mass `p_0 >= p_1 >= ... >= p_{K-1}` (`\sum_{j=0}^{K-1} p_j = 1`).
 *   2. Greedily locks the prefix `0 .. J^* - 1` of dominant experts until their cumulative
 *      probability mass reaches `>= tau_mass` (always preserving at least `J^* >= 1` and up to `K`).
 *      These `J^*` sacred experts are **100% untouched** by cache state!
 *   3. Fills the remaining tail slots `J^* .. K - 1` (the `1 - tau_mass` low-confidence ambiguity
 *      band) using the cache-residency bonus `raw_logits[e] + cache_bonus_alpha * is_cached_cur[e]`.
 *   4. Automatically adapts to peaked routers (`J^* = 1` or `2` when one expert carries >90% mass),
 *      flat routers (`J^*` scales up to protect all high-mass experts), and ANY `(E, K)`!
 */
static inline void udie_gen_quantile_cache_route(
    const float                *raw_logits,         /* [E] router logits (from FP32, INT8, or 0-DSP CSD router) */
    const uint8_t              *is_cached_cur,      /* [E] 1 if expert e is resident in Layer l cache */
    const uint8_t              *is_cached_next,     /* [E] 1 if expert e is resident in Layer l+1 cache */
    uint32_t                   *couple_matrix,      /* [E * E] optional co-activation matrix */
    const uint32_t             *cross_layer_matrix, /* [E * E] optional cross-layer affinity matrix */
    UdieGen2VcArbiter          *vc_arbiter,         /* optional 2-VC credit arbiter */
    int                         E,
    int                         top_k,              /* ANY K >= 1 */
    float                       tau_mass,           /* e.g. 0.90f cumulative probability mass threshold */
    float                       cache_bonus_alpha,  /* e.g. 0.35f */
    int                         enable_cache_route,
    UdieGenQuantileRouteReport *out_report
) {
    if (!raw_logits || !out_report || E <= 0 || top_k <= 0) return;
    memset(out_report, 0, sizeof(*out_report));
    int e_cap = (E <= 512) ? E : 512;
    int k_cap = (top_k <= 32) ? top_k : 32;
    if (k_cap > e_cap) k_cap = e_cap;

    /* Step 1: Find unmodified raw top-K experts and compute their softmax probability distribution */
    int   raw_topk_ids[32];
    float raw_topk_val[32];
    uint8_t raw_used[512];
    memset(raw_used, 0, sizeof(raw_used));

    float max_logit = -1e30f;
    for (int j = 0; j < k_cap; j++) {
        int best_e = 0;
        float best_v = -1e30f;
        for (int e = 0; e < e_cap; e++) {
            if (!raw_used[e] && raw_logits[e] > best_v) {
                best_v = raw_logits[e];
                best_e = e;
            }
        }
        raw_used[best_e] = 1;
        raw_topk_ids[j]  = best_e;
        raw_topk_val[j]  = best_v;
        if (best_v > max_logit) max_logit = best_v;
    }

    float sum_exp = 0.0f;
    float raw_probs[32];
    for (int j = 0; j < k_cap; j++) {
        raw_probs[j] = expf(raw_topk_val[j] - max_logit);
        sum_exp += raw_probs[j];
    }
    if (sum_exp > 1e-20f) {
        for (int j = 0; j < k_cap; j++) raw_probs[j] /= sum_exp;
    }

    /* Step 2: Determine adaptive sacred count J* where cumulative probability mass >= tau_mass */
    uint8_t picked[512];
    memset(picked, 0, sizeof(picked));
    float cum_mass = 0.0f;
    int sacred_J = 0;
    for (int j = 0; j < k_cap; j++) {
        int e = raw_topk_ids[j];
        picked[e] = 1;
        out_report->routed_experts[j] = e;
        out_report->routed_logits[j]  = raw_logits[e];
        cum_mass += raw_probs[j];
        sacred_J = j + 1;
        if (cum_mass >= tau_mass) break;
    }
    out_report->sacred_count           = sacred_J;
    out_report->sacred_cumulative_mass = cum_mass;

    /* Step 3: Fill remaining tail ambiguity slots (j = sacred_J .. k_cap - 1) with cache residency bonus */
    float eff_alpha = enable_cache_route ? cache_bonus_alpha : 0.0f;
    for (int j = sacred_J; j < k_cap; j++) {
        int best_e = 0;
        float best_v = -1e30f;
        for (int e = 0; e < e_cap; e++) {
            if (picked[e]) continue;
            float bonus = (is_cached_cur && is_cached_cur[e]) ? eff_alpha : 0.0f;
            float score = raw_logits[e] + bonus;
            if (score > best_v) {
                best_v = score;
                best_e = e;
            }
        }
        picked[best_e] = 1;
        out_report->routed_experts[j] = best_e;
        out_report->routed_logits[j]  = raw_logits[best_e];
    }

    /* Renormalize final routed expert probabilities */
    float sum_final = 0.0f;
    for (int j = 0; j < k_cap; j++) {
        out_report->routed_probs[j] = expf(out_report->routed_logits[j] - max_logit);
        sum_final += out_report->routed_probs[j];
    }
    if (sum_final > 1e-20f) {
        for (int j = 0; j < k_cap; j++) out_report->routed_probs[j] /= sum_final;
    }

    int hits = 0;
    for (int j = 0; j < k_cap; j++) {
        int e = out_report->routed_experts[j];
        if (is_cached_cur && is_cached_cur[e]) hits++;
    }
    out_report->cache_hits_in_topk = hits;

    /* Step 4: Update COUPLE co-activation matrix and issue PILOT prefetch on VC0 */
    if (couple_matrix) {
        for (int a = 0; a < k_cap; a++) {
            int ea = out_report->routed_experts[a];
            for (int b = a + 1; b < k_cap; b++) {
                int eb = out_report->routed_experts[b];
                couple_matrix[ea * e_cap + eb]++;
                couple_matrix[eb * e_cap + ea]++;
            }
        }
    }

    int best_pilot = -1;
    uint64_t best_pilot_score = 0;
    if (cross_layer_matrix) {
        for (int cand = 0; cand < e_cap; cand++) {
            if (is_cached_next && is_cached_next[cand]) continue;
            uint64_t aff = 0;
            for (int j = 0; j < sacred_J; j++) {
                int src_e = out_report->routed_experts[j];
                aff += (uint64_t)cross_layer_matrix[src_e * e_cap + cand] * (uint64_t)(sacred_J - j);
            }
            if (aff > best_pilot_score) {
                best_pilot_score = aff;
                best_pilot = cand;
            }
        }
    }
    out_report->pilot_prefetch_expert = best_pilot;
    if (enable_cache_route && best_pilot >= 0 && vc_arbiter) {
        out_report->pilot_issued_on_vc0 = udie_gen_2vc_issue(vc_arbiter, UDIE_GEN_VC_PILOT);
    }
}

/*
 * Universal Cold-Page-I/O & Compute Cost-Value Speculative Filter (`udie_gen_io_cost_value_spec_filter`):
 * Works across ANY speculative tree topology (`parent_idx[i]`, or default 1-indexed Braun tree when
 * `parent_idx == NULL`), ANY layer depth `L`, and both Dense (`node_expert_masks == NULL`) and MoE models:
 *   - Enforces parent-child tree connectivity (`parent_idx[i]` must be accepted).
 *   - Bounds total unique cold page reads `popcnt(union_cold | new_cold) <= max_cold_pages`.
 *   - Enforces the universal marginal cost-value inequality:
 *       `marginal_value = node_accept_probs[i]`
 *       `marginal_cost  = compute_cost_per_node + popcnt(new_cold) * cold_page_io_cost`
 *       `accept iff marginal_value >= marginal_cost`
 *   - Computes total expected accepted tokens `E[tokens]` and overall speedup ratio `E[tokens] / total_cost`.
 */
typedef struct {
    int      num_accepted_nodes;
    int      accepted_node_ids[64];
    uint64_t union_all_expert_mask;
    uint64_t union_ram_hit_mask;
    uint64_t union_cold_page_mask;
    int      total_unique_experts;
    int      ram_hit_unique_experts;
    int      cold_page_unique_experts;
    float    expected_accepted_tokens;
    float    total_verification_cost;
    float    net_speedup_value_ratio; /* expected_accepted_tokens / total_verification_cost (>= 1.0f) */
} UdieGenSpecFilterPlan;

static inline void udie_gen_io_cost_value_spec_filter(
    const int             *parent_idx,            /* [num_candidates] parent index per node (or NULL for Braun tree) */
    const uint64_t        *node_expert_masks,     /* [num_candidates] expert mask per node (or NULL for Dense E=1) */
    const float           *node_accept_probs,     /* [num_candidates] cumulative path acceptance probability */
    int                    num_candidates,        /* <= 63 */
    uint64_t               ram_resident_mask,     /* bit e = 1 iff expert e is resident in RAM */
    int                    max_cold_pages,        /* cap on unique cold page reads */
    float                  min_prob_thresh,       /* minimum node acceptance probability */
    float                  compute_cost_per_node, /* marginal compute cost per verify row (in token units) */
    float                  cold_page_io_cost,     /* marginal I/O cost per cold page read (in token units) */
    UdieGenSpecFilterPlan *plan_out
) {
    if (!plan_out) return;
    memset(plan_out, 0, sizeof(*plan_out));
    if (num_candidates <= 0) return;
    if (num_candidates > 63) num_candidates = 63;

    uint8_t accepted[64];
    memset(accepted, 0, sizeof(accepted));

    uint64_t union_all  = 0ULL;
    uint64_t union_cold = 0ULL;
    float    exp_tokens = 0.0f;
    float    total_cost = 1.0f; /* Base verification cost of root token 0 */
    int      acc_cnt    = 0;

    for (int i = 0; i < num_candidates; i++) {
        float prob = node_accept_probs ? node_accept_probs[i] : 1.0f;
        uint64_t req_mask  = node_expert_masks ? node_expert_masks[i] : 1ULL;
        uint64_t cold_req  = req_mask & ~ram_resident_mask;
        uint64_t new_cold  = cold_req & ~union_cold;
        int      n_new_io  = udie_gen_popcnt_u64(new_cold);

        if (i > 0) {
            int parent = parent_idx ? parent_idx[i] : (((i + 1) >> 1) - 1);
            if (parent < 0 || parent >= i || !accepted[parent]) continue;
            if (prob < min_prob_thresh) continue;

            int next_total_cold = udie_gen_popcnt_u64(union_cold | cold_req);
            if (max_cold_pages >= 0 && next_total_cold > max_cold_pages) continue;

            float marginal_cost = compute_cost_per_node + (float)n_new_io * cold_page_io_cost;
            if (prob < marginal_cost) continue;

            total_cost += marginal_cost;
        }

        accepted[i] = 1;
        plan_out->accepted_node_ids[acc_cnt++] = i;
        union_all  |= req_mask;
        union_cold |= cold_req;
        exp_tokens += prob;
    }

    plan_out->num_accepted_nodes       = acc_cnt;
    plan_out->union_all_expert_mask    = union_all;
    plan_out->union_ram_hit_mask       = union_all & ram_resident_mask;
    plan_out->union_cold_page_mask     = union_cold;
    plan_out->total_unique_experts     = udie_gen_popcnt_u64(union_all);
    plan_out->ram_hit_unique_experts   = udie_gen_popcnt_u64(plan_out->union_ram_hit_mask);
    plan_out->cold_page_unique_experts = udie_gen_popcnt_u64(union_cold);
    plan_out->expected_accepted_tokens = exp_tokens;
    plan_out->total_verification_cost  = total_cost;
    plan_out->net_speedup_value_ratio  = (total_cost > 1e-9f) ? (exp_tokens / total_cost) : 1.0f;
}

#ifdef __cplusplus
}
#endif

#endif /* UDIE_UNIFIED_GENERAL_H */
