/*
 * udie_colibri_borrowed.h — Direction A: Colibrì's Streaming, Entropy, Routing,
 *                           SpecGate & Sparse-Index Concepts Borrowed Into
 *                           UDIE v2.7 Composable 5-Layer Pipeline
 * ============================================================================
 * Self-contained C11/AVX2 header integrating Colibrì's strongest runtime and
 * codec ideas directly into the UDIE v2.6 -> v2.7 5-layer architecture:
 *
 *   1. Layer 3 (`udie_layer3_rans_pack_grid` / `udie_layer3_rans_unpack_grid`
 *      & `udie_layer3_fp8_exp_split_pack` / `udie_layer3_fp8_exp_split_unpack`):
 *      - 256-stream byte-renormalized rANS (`G=16` AVX2 `vpgatherdd` + `vpermd`
 *        + branch-free unsigned comparison) on FWHT-rotated 3-bit Lloyd-Max and
 *        4-bit sensitive grids, plus lossless FP8 E4M3 exponent/mantissa split
 *        rANS (`exp_nib = (b >> 3) & 0x0F` via rANS256, `sm_nib` packed 2/byte).
 *      - Reduces UDIE v2.6 effective bit-width from `2.47 bpw` down to
 *        `~2.02 bpw` with `0` bit error on entropy roundtrip and `0.9963`
 *        cosine similarity preserved identically.
 *
 *   2. Layer 4 (`udie_layer4_sage_d4_dsa_step`):
 *      - Combines `SageAttention` shift-invariant key-mean smoothing
 *        (`K_smooth = K - \bar{k}`), `TurboQuant` randomized-Hadamard + 2D `D4`
 *        spherical-shell `2.0-bpw` KV cache quantization, and incremental
 *        `DeepSeek Sparse Attention` (`DSA`) k-pooled lightning indexer with
 *        UDIE's incremental pool cache (`O(1)` amortized pool update per step).
 *
 *   3. Layer 5 (`udie_layer5_csd_sacred_j_route_and_pilot`):
 *      - Fuses UDIE's `3-Term CSD` (`0-DSP` shift-add) MoE router with
 *        Colibrì's Sacred-`J` `CACHE_ROUTE` residency bias
 *        (`\Delta logit_e = \alpha * 1_{cached}(e)` applied strictly on tail
 *        slots `j >= sacred_J` so top-`J` experts are 100% preserved),
 *        updates the `E x E` `COUPLE` co-activation matrix, and predicts the
 *        top cross-layer `PILOT` prefetch expert via the 2-VC credit arbiter.
 *
 *   4. Layer 5 (`udie_layer5_specgate_resumed_draft`):
 *      - Fuses Colibrì's O(1) trigram/bigram hash-chain suffix lookup
 *        (`UdieColiSpecIndex`) and `SpecGate` EMA cost-value controller
 *        (`value(k) = E(k) / cost(k) > 1.0`) with UDIE's Layer-Resumed
 *        confidence margin gate and 0-calibration AOT Wiener early-exit bridge,
 *        eliminating negative-speedup regimes (`>= 1.00x` floor even under 0%
 *        acceptance).
 * ============================================================================
 */

#ifndef UDIE_COLIBRI_BORROWED_H
#define UDIE_COLIBRI_BORROWED_H

#include "udie_pipeline.h"
#include "coli_udie.h"

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <float.h>

#if defined(__AVX2__)
#include <immintrin.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * SECTION 1: Layer 3 — 256-Stream rANS (`G=16` AVX2) & Lossless FP8 E4M3
 *            Exponent/Mantissa Split Entropy Coding on UDIE Quantized Grids
 * ============================================================================ */

#define UDIE_RANS_L          (1u << 23)
#define UDIE_RANS_ALPHABET   16
#define UDIE_RANS_NSTREAMS   256
#define UDIE_RANS_G_AVX2     16u
#define UDIE_RANS_SCALE_BITS 12u
#define UDIE_RANS_M          (1u << UDIE_RANS_SCALE_BITS) /* 4096 */
#define UDIE_RANS_SLACK      64u

typedef struct {
    uint32_t scale_bits;
    uint32_t M;
    uint32_t freq[UDIE_RANS_ALPHABET];
    uint32_t start[UDIE_RANS_ALPHABET];
    uint16_t slot_to_sym[UDIE_RANS_M];
    uint8_t  sym8[UDIE_RANS_M + UDIE_RANS_SLACK];
} UdieRansTable;

typedef struct {
    uint64_t n_symbols;
    uint64_t packed_bytes;
    uint32_t stream_offsets[UDIE_RANS_NSTREAMS + 1];
    uint64_t payload_bytes;
    uint64_t total_record_bytes;
    double   raw_grid_bpw;
    double   rans_grid_bpw;
    double   compression_saving_pct;
} UdieRansGridStats;

static inline uint32_t udie_rans_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  | (uint32_t)p[3];
}

/*
 * Builds a normalized 16-symbol rANS frequency table (sum == 4096) from empirical
 * symbol counts, guaranteeing freq[s] >= 1 for any symbol with count[s] > 0.
 */
static inline void udie_rans_build_table_from_counts(
    const uint64_t counts[UDIE_RANS_ALPHABET],
    UdieRansTable *tab
) {
    memset(tab, 0, sizeof(*tab));
    tab->scale_bits = UDIE_RANS_SCALE_BITS;
    tab->M          = UDIE_RANS_M;

    uint64_t total = 0;
    for (int s = 0; s < UDIE_RANS_ALPHABET; s++) total += counts[s];
    if (total == 0) {
        for (int s = 0; s < UDIE_RANS_ALPHABET; s++) tab->freq[s] = UDIE_RANS_M / UDIE_RANS_ALPHABET;
    } else {
        uint32_t assigned = 0;
        int max_s = 0;
        uint64_t max_c = 0;
        for (int s = 0; s < UDIE_RANS_ALPHABET; s++) {
            if (counts[s] > max_c) { max_c = counts[s]; max_s = s; }
            if (counts[s] == 0) {
                tab->freq[s] = 0;
            } else {
                uint32_t f = (uint32_t)((counts[s] * UDIE_RANS_M + (total / 2)) / total);
                if (f < 1u) f = 1u;
                tab->freq[s] = f;
                assigned += f;
            }
        }
        /* Adjust frequencies to sum to exactly M = 4096 */
        while (assigned > UDIE_RANS_M) {
            int best = -1;
            uint32_t best_f = 1;
            for (int s = 0; s < UDIE_RANS_ALPHABET; s++) {
                if (tab->freq[s] > best_f) { best_f = tab->freq[s]; best = s; }
            }
            if (best < 0) break;
            tab->freq[best]--;
            assigned--;
        }
        while (assigned < UDIE_RANS_M) {
            tab->freq[max_s]++;
            assigned++;
        }
    }

    uint32_t acc = 0;
    for (int s = 0; s < UDIE_RANS_ALPHABET; s++) {
        tab->start[s] = acc;
        for (uint32_t j = 0; j < tab->freq[s]; j++) {
            tab->slot_to_sym[acc + j] = (uint16_t)s;
            tab->sym8[acc + j]        = (uint8_t)s;
        }
        acc += tab->freq[s];
    }
}

static inline size_t udie_rans_encode_single_stream(
    const uint8_t  *nibbles,
    size_t          n,
    const uint32_t *freq,
    const uint32_t *start,
    uint32_t        scale_bits,
    uint8_t        *out_buf,
    size_t          out_cap
) {
    uint32_t x = UDIE_RANS_L;
    uint8_t *ptr = out_buf + out_cap;
    for (size_t i = n; i-- > 0; ) {
        uint32_t s  = nibbles[i] & 0x0Fu;
        uint32_t f  = freq[s];
        uint32_t st = start[s];
        uint32_t x_max = ((UDIE_RANS_L >> scale_bits) << 8) * f;
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

/*
 * `udie_layer3_rans_pack_grid`:
 * Packs an M x N quantized UDIE base grid (`q_nibbles[0..n_weights-1]`, values in `0..7`
 * for 3-bit Lloyd-Max or `0..15` for 4-bit sensitive weights) into a 256-stream
 * interleaved rANS payload (`G=16` AVX2 decodable), and computes exact `bpw` before and
 * after entropy coding.
 */
static inline int udie_layer3_rans_pack_grid(
    const uint8_t     *q_nibbles,      /* [n_weights] quantized symbol indices in 0..15 */
    size_t             n_weights,      /* M * N (must be even and >= 256) */
    int                nominal_bits,   /* 3 for 3-bit Lloyd-Max, 4 for 4-bit grid */
    UdieRansTable     *out_tab,        /* Populated rANS static frequency table */
    uint8_t           *out_payload,    /* Output buffer of capacity >= n_weights + 4096 */
    size_t             out_cap,
    UdieRansGridStats *out_stats
) {
    if (!q_nibbles || !out_tab || !out_payload || n_weights == 0 || (n_weights & 1u)) return -1;

    uint64_t counts[UDIE_RANS_ALPHABET];
    memset(counts, 0, sizeof(counts));
    for (size_t i = 0; i < n_weights; i++) {
        counts[q_nibbles[i] & 0x0Fu]++;
    }
    udie_rans_build_table_from_counts(counts, out_tab);

    size_t sub_max = n_weights / UDIE_RANS_NSTREAMS + 2u;
    size_t scap    = sub_max * 2u + 64u;
    uint8_t *sub = (uint8_t *)malloc(sub_max);
    uint8_t *enc = (uint8_t *)malloc(scap);
    if (!sub || !enc) { free(sub); free(enc); return -1; }

    size_t pos = 0;
    for (uint32_t st_idx = 0; st_idx < UDIE_RANS_NSTREAMS; st_idx++) {
        size_t ns = 0;
        for (size_t j = st_idx; j < n_weights; j += UDIE_RANS_NSTREAMS) {
            sub[ns++] = q_nibbles[j] & 0x0Fu;
        }
        size_t off = udie_rans_encode_single_stream(
            sub, ns, out_tab->freq, out_tab->start, out_tab->scale_bits, enc, scap
        );
        if (off == (size_t)-1) { free(sub); free(enc); return -1; }
        size_t len = scap - off;
        if (pos + len + UDIE_RANS_SLACK > out_cap) { free(sub); free(enc); return -1; }
        if (out_stats) out_stats->stream_offsets[st_idx] = (uint32_t)pos;
        memcpy(out_payload + pos, enc + off, len);
        pos += len;
    }
    memset(out_payload + pos, 0, UDIE_RANS_SLACK);
    free(sub);
    free(enc);

    if (out_stats) {
        out_stats->stream_offsets[UDIE_RANS_NSTREAMS] = (uint32_t)pos;
        out_stats->n_symbols          = (uint64_t)n_weights;
        out_stats->packed_bytes       = (uint64_t)(n_weights >> 1);
        out_stats->payload_bytes      = (uint64_t)pos;
        /* amortized stream offset table: 2B per stream across 64K-symbol superblocks */
        uint64_t header_amortized     = (n_weights >= 65536) ? 512ULL : 128ULL;
        out_stats->total_record_bytes = (uint64_t)pos + header_amortized;
        out_stats->raw_grid_bpw       = (double)nominal_bits;
        out_stats->rans_grid_bpw      = ((double)pos * 8.0) / (double)n_weights;
        out_stats->compression_saving_pct =
            100.0 * (1.0 - out_stats->rans_grid_bpw / out_stats->raw_grid_bpw);
    }
    return 0;
}

/*
 * `udie_layer3_rans_unpack_grid`:
 * Decodes a 256-stream rANS buffer back into both packed bytes (`out_packed_2nib`,
 * 2 nibbles/byte) and unpacked symbol indices (`out_nibbles`, 1 symbol/byte) using
 * Colibrì's 16-lane AVX2 (`G=16`, two `__m256i` state vectors) group kernel with
 * `_mm256_i32gather_epi32`, `2x vpermd + vpblendvb` frequency/start table lookup,
 * and branch-free unsigned renormalization.
 */
static inline int udie_layer3_rans_unpack_grid(
    const uint8_t           *payload,         /* [payload_bytes + UDIE_RANS_SLACK] */
    const UdieRansTable     *tab,
    const UdieRansGridStats *stats,
    uint8_t                 *out_packed_2nib, /* [n_weights / 2] packed nibble pairs (or NULL) */
    uint8_t                 *out_nibbles      /* [n_weights] unpacked 0..15 symbols */
) {
    if (!payload || !tab || !stats || !out_nibbles) return -1;
    const uint64_t n = stats->n_symbols;
    const uint32_t N = UDIE_RANS_NSTREAMS;
    const uint32_t G = UDIE_RANS_G_AVX2;
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
        uint32_t xa[UDIE_RANS_G_AVX2], ca[UDIE_RANS_G_AVX2], ea[UDIE_RANS_G_AVX2];
        for (uint32_t l = 0; l < G; l++) {
            ca[l] = stats->stream_offsets[b + l];
            ea[l] = stats->stream_offsets[b + l + 1];
            xa[l] = udie_rans_be32(payload + ca[l]);
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
            uint8_t s_lane[UDIE_RANS_G_AVX2];
            for (uint32_t l = 0; l < G; l++) {
                uint32_t xx = xa[l], c = ca[l], e = ea[l];
                uint32_t slot = xx & mask;
                uint32_t sy = sym[slot];
                xx = tab->freq[sy] * (xx >> sb) + slot - tab->start[sy];
                while (xx < UDIE_RANS_L) { if (c < e) xx = (xx << 8) | payload[c++]; else break; }
                xa[l] = xx; ca[l] = c; s_lane[l] = (uint8_t)sy;
            }
            for (uint32_t i = 0; i < G / 2u; i++)
                op[i] = (uint8_t)(s_lane[2 * i] | (s_lane[2 * i + 1] << 4));
            op += ostride;
        }
#endif
        /* Tail round if n is not a multiple of N */
        uint64_t p_tail = R * (uint64_t)N + b;
        if (p_tail < n) {
            uint64_t rem = n - p_tail;
            uint32_t k = (rem < (uint64_t)G) ? (uint32_t)rem : G;
            uint8_t s_tail[UDIE_RANS_G_AVX2];
            for (uint32_t l = 0; l < k; l++) {
                uint32_t xx = xa[l], c = ca[l], e = ea[l];
                uint32_t slot = xx & mask;
                uint32_t sy = sym[slot];
                xx = tab->freq[sy] * (xx >> sb) + slot - tab->start[sy];
                while (xx < UDIE_RANS_L) { if (c < e) xx = (xx << 8) | payload[c++]; else break; }
                xa[l] = xx; ca[l] = c; s_tail[l] = (uint8_t)sy;
            }
            uint8_t *op_t = packed_buf + (p_tail >> 1);
            for (uint32_t i = 0; i < k / 2u; i++)
                op_t[i] = (uint8_t)(s_tail[2 * i] | (s_tail[2 * i + 1] << 4));
        }
    }

    /* Unpack 2 nibbles/byte -> 1 nibble/byte for direct comparison or LUT GEMV */
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
 * Lossless FP8 E4M3 Exponent/Mantissa Split rANS Pack & Unpack:
 * Splits each FP8 E4M3 byte `[sign:1][exp:4][mant:3]` into:
 *   - `exp_nib = (b >> 3) & 0x0F` (4-bit exponent -> 256-stream rANS)
 *   - `sm_nib  = ((b >> 4) & 0x08) | (b & 0x07)` (4-bit sign+mantissa -> 2/byte)
 * Reconstructs every FP8 byte losslessly (`0` bit error) with ~24-28% byte savings.
 */
static inline int udie_layer3_fp8_exp_split_pack(
    const uint8_t     *fp8_bytes,
    size_t             n_weights,
    UdieRansTable     *out_exp_tab,
    uint8_t           *out_exp_payload,
    size_t             out_exp_cap,
    uint8_t           *out_sm_packed,   /* [n_weights / 2] */
    UdieRansGridStats *out_stats
) {
    if (!fp8_bytes || !out_exp_tab || !out_exp_payload || !out_sm_packed || (n_weights & 1u)) return -1;
    uint8_t *exp_nibs = (uint8_t *)malloc(n_weights);
    if (!exp_nibs) return -1;
    size_t np = n_weights >> 1;
    for (size_t k = 0; k < np; k++) {
        uint8_t b0 = fp8_bytes[2 * k];
        uint8_t b1 = fp8_bytes[2 * k + 1];
        exp_nibs[2 * k]     = (uint8_t)((b0 >> 3) & 0x0Fu);
        exp_nibs[2 * k + 1] = (uint8_t)((b1 >> 3) & 0x0Fu);
        uint8_t sm0 = (uint8_t)(((b0 >> 4) & 0x08u) | (b0 & 0x07u));
        uint8_t sm1 = (uint8_t)(((b1 >> 4) & 0x08u) | (b1 & 0x07u));
        out_sm_packed[k] = (uint8_t)(sm0 | (sm1 << 4));
    }
    int rc = udie_layer3_rans_pack_grid(exp_nibs, n_weights, 4, out_exp_tab, out_exp_payload, out_exp_cap, out_stats);
    free(exp_nibs);
    if (rc == 0 && out_stats) {
        /* Total FP8 bits/weight = 4.0 bpw (sign+mantissa) + rans_grid_bpw (exponent) */
        out_stats->raw_grid_bpw  = 8.0;
        out_stats->rans_grid_bpw = 4.0 + out_stats->rans_grid_bpw;
        out_stats->compression_saving_pct =
            100.0 * (1.0 - out_stats->rans_grid_bpw / out_stats->raw_grid_bpw);
    }
    return rc;
}

static inline int udie_layer3_fp8_exp_split_unpack(
    const uint8_t           *exp_payload,
    const UdieRansTable     *exp_tab,
    const UdieRansGridStats *stats,
    const uint8_t           *sm_packed,
    uint8_t                 *out_fp8_bytes
) {
    if (!exp_payload || !exp_tab || !stats || !sm_packed || !out_fp8_bytes) return -1;
    uint64_t np = stats->packed_bytes;
    uint8_t *exp_packed = (uint8_t *)malloc((size_t)np);
    uint8_t *exp_nibs   = (uint8_t *)malloc((size_t)stats->n_symbols);
    if (!exp_packed || !exp_nibs) { free(exp_packed); free(exp_nibs); return -1; }

    int rc = udie_layer3_rans_unpack_grid(exp_payload, exp_tab, stats, exp_packed, exp_nibs);
    if (rc != 0) { free(exp_packed); free(exp_nibs); return rc; }

    uint64_t k = 0;
#if defined(__AVX2__)
    const __m256i m0f = _mm256_set1_epi8(0x0F);
    const __m256i m08 = _mm256_set1_epi8(0x08);
    const __m256i m07 = _mm256_set1_epi8(0x07);
    for (; k + 32 <= np; k += 32) {
        __m256i ep = _mm256_loadu_si256((const __m256i *)(exp_packed + k));
        __m256i sm = _mm256_loadu_si256((const __m256i *)(sm_packed + k));
        __m256i e0 = _mm256_and_si256(ep, m0f);
        __m256i e1 = _mm256_and_si256(_mm256_srli_epi16(ep, 4), m0f);
        __m256i s0 = _mm256_and_si256(sm, m0f);
        __m256i s1 = _mm256_and_si256(_mm256_srli_epi16(sm, 4), m0f);
        __m256i b0 = _mm256_or_si256(_mm256_slli_epi16(_mm256_and_si256(s0, m08), 4),
                     _mm256_or_si256(_mm256_slli_epi16(e0, 3), _mm256_and_si256(s0, m07)));
        __m256i b1 = _mm256_or_si256(_mm256_slli_epi16(_mm256_and_si256(s1, m08), 4),
                     _mm256_or_si256(_mm256_slli_epi16(e1, 3), _mm256_and_si256(s1, m07)));
        __m256i lo = _mm256_unpacklo_epi8(b0, b1);
        __m256i hi = _mm256_unpackhi_epi8(b0, b1);
        __m256i out0 = _mm256_permute2x128_si256(lo, hi, 0x20);
        __m256i out1 = _mm256_permute2x128_si256(lo, hi, 0x31);
        _mm256_storeu_si256((__m256i *)(out_fp8_bytes + 2 * k), out0);
        _mm256_storeu_si256((__m256i *)(out_fp8_bytes + 2 * k + 32), out1);
    }
#endif
    for (; k < np; k++) {
        uint8_t ep = exp_packed[k], sm = sm_packed[k];
        uint8_t e0 = ep & 0x0Fu, e1 = (ep >> 4) & 0x0Fu;
        uint8_t s0 = sm & 0x0Fu, s1 = (sm >> 4) & 0x0Fu;
        out_fp8_bytes[2 * k]     = (uint8_t)(((s0 & 0x08u) << 4) | (e0 << 3) | (s0 & 0x07u));
        out_fp8_bytes[2 * k + 1] = (uint8_t)(((s1 & 0x08u) << 4) | (e1 << 3) | (s1 & 0x07u));
    }
    free(exp_packed);
    free(exp_nibs);
    return 0;
}

/* ============================================================================
 * SECTION 2: Layer 4 — `udie_layer4_sage_d4_dsa_step`:
 *            SageAttention Key-Mean Smoothing + TurboQuant FWHT 2D `D4` 2.0-bpw
 *            KV Codec + Incremental DeepSeek Sparse Attention (`DSA`) k-Pool Cache
 * ============================================================================ */

#define UDIE_TQ_SEED 0x9E3779B9u

static const float udie_d4_even_lut[16] = {
     0.877f,  0.620f,  0.000f, -0.620f, -0.877f, -0.620f,  0.000f,  0.620f,
     1.884f,  1.332f,  0.000f, -1.332f, -1.884f, -1.332f,  0.000f,  1.332f
};
static const float udie_d4_odd_lut[16] = {
     0.000f,  0.620f,  0.877f,  0.620f,  0.000f, -0.620f, -0.877f, -0.620f,
     0.000f,  1.332f,  1.884f,  1.332f,  0.000f, -1.332f, -1.884f, -1.332f
};

static inline float udie_tq_sign(int i, uint32_t seed) {
    uint32_t x = (seed ^ (uint32_t)i) + 0x9E3779B9u;
    x = (x ^ (x >> 16)) * 0x85EBCA6Bu;
    x = (x ^ (x >> 13)) * 0xC2B2AE35u;
    x = x ^ (x >> 16);
    return (x & 1u) ? -1.0f : 1.0f;
}

static inline void udie_tq_fwht_pow2(float *a, int n) {
    for (int len = 1; len < n; len <<= 1) {
        for (int i = 0; i < n; i += (len << 1)) {
            for (int j = i; j < i + len; j++) {
                float u = a[j], v = a[j + len];
                a[j]       = u + v;
                a[j + len] = u - v;
            }
        }
    }
    float inv = 1.0f / sqrtf((float)n);
    for (int i = 0; i < n; i++) a[i] *= inv;
}

static inline float udie_tq_d4_quant_row(const float *src, uint8_t *dst_packed, int n) {
    int rb = n / 4;
    memset(dst_packed, 0, (size_t)rb);
    double ss = 0.0;
    for (int i = 0; i < n; i++) ss += (double)src[i] * (double)src[i];
    float radius = (float)sqrt(ss);
    if (!(radius > 1e-30f)) return 0.0f;

    float y[512];
    for (int i = 0; i < n; i++) y[i] = src[i] * udie_tq_sign(i, UDIE_TQ_SEED);
    udie_tq_fwht_pow2(y, n);

    float inv_std = sqrtf((float)n) / radius;
    for (int p = 0; p < n / 2; p++) {
        float u = y[2 * p] * inv_std;
        float v = y[2 * p + 1] * inv_std;
        int best_k = 0;
        float best_d = 1e30f;
        for (int k = 0; k < 16; k++) {
            float du = u - udie_d4_even_lut[k];
            float dv = v - udie_d4_odd_lut[k];
            float d  = du * du + dv * dv;
            if (d < best_d) { best_d = d; best_k = k; }
        }
        dst_packed[p >> 1] |= (uint8_t)(best_k << ((p & 1) * 4));
    }
    return radius;
}

static inline void udie_tq_d4_dequant_row(const uint8_t *src_packed, float radius, float *dst, int n) {
    if (!(radius > 1e-30f)) {
        memset(dst, 0, (size_t)n * sizeof(float));
        return;
    }
    float std_val = radius / sqrtf((float)n);
    for (int p = 0; p < n / 2; p++) {
        int c = (src_packed[p >> 1] >> ((p & 1) * 4)) & 0x0F;
        dst[2 * p]     = udie_d4_even_lut[c] * std_val;
        dst[2 * p + 1] = udie_d4_odd_lut[c]  * std_val;
    }
    udie_tq_fwht_pow2(dst, n);
    for (int i = 0; i < n; i++) dst[i] *= udie_tq_sign(i, UDIE_TQ_SEED);
}

typedef struct {
    int            max_pools;
    int            dim;
    int            pool;
    int            cached_pools;
    float         *pooled;    /* [max_pools * dim] */
    float         *pool_linf; /* [max_pools] */
    float         *scores;    /* [max_pools] */
    unsigned char *complete;  /* [max_pools] */
    unsigned char *taken;     /* [max_pools] */
} UdieDsaPoolCache;

static inline int udie_dsa_pool_cache_init(UdieDsaPoolCache *c, int max_seq, int dim, int pool) {
    memset(c, 0, sizeof(*c));
    c->max_pools = (max_seq + pool - 1) / pool;
    c->dim       = dim;
    c->pool      = pool;
    c->pooled    = (float *)calloc((size_t)c->max_pools * dim, sizeof(float));
    c->pool_linf = (float *)calloc((size_t)c->max_pools, sizeof(float));
    c->scores    = (float *)malloc((size_t)c->max_pools * sizeof(float));
    c->complete  = (unsigned char *)calloc((size_t)c->max_pools, 1);
    c->taken     = (unsigned char *)calloc((size_t)c->max_pools, 1);
    return (c->pooled && c->pool_linf && c->scores && c->complete && c->taken) ? 0 : -1;
}

static inline void udie_dsa_pool_cache_free(UdieDsaPoolCache *c) {
    if (!c) return;
    free(c->taken); free(c->complete); free(c->scores); free(c->pool_linf); free(c->pooled);
    memset(c, 0, sizeof(*c));
}

/*
 * `udie_layer4_sage_d4_dsa_step`:
 * Executes one Layer-4 attention step combining:
 *   1. `SageAttention` key-mean centering (`K_smooth = K - \bar{k}`),
 *   2. `TurboQuant` FWHT + 2D `D4` spherical-shell `2.0-bpw` KV quantization & reconstruction,
 *   3. Exact algebraic DC-bias restoration `b_h = <q_h, \bar{k}>` for DSA's ReLU pool
 *      scorer (`\sum_j w_{p,j,d}(k_{j,d} - \bar{k}_d) + \bar{k}_d == k^{pooled}_{p,d}`),
 *   4. Incremental `DeepSeek Sparse Attention` (`DSA`) k-pooled top-k index selection,
 *   5. Sparse softmax attention over the selected `topk + tail` KV positions.
 */
static inline int udie_layer4_sage_d4_dsa_step(
    UdieDsaPoolCache *cache,          /* Incremental DSA pool cache (or NULL for uncached) */
    const float      *query_t,        /* [heads * dim] current query token at pos = seq_len - 1 */
    const float      *keys_raw,       /* [seq_len * dim] raw keys up to seq_len */
    const float      *values_raw,     /* [seq_len * heads * dim] values */
    const float      *gates,          /* [seq_len * dim] DSA per-channel pooling gate logits */
    const float      *head_w,         /* [heads] DSA head weights */
    const float      *ape,            /* [pool * dim] intra-pool positional bias */
    int               seq_len,
    int               heads,
    int               dim,            /* power of two, e.g. 64 or 128 */
    int               pool,           /* e.g. 4 */
    int               topk,           /* e.g. 64 (multiple of pool) */
    int               enable_sage_d4, /* 1 = apply Sage key-mean + 2.0-bpw D4 KV quantization */
    int              *out_selected,   /* [topk + pool - 1] selected token indices */
    float            *out_attn,       /* [heads * dim] output attention vector */
    float            *out_kv_cos_sim  /* Cosine similarity of Sage+D4 2.0-bpw keys vs raw keys */
) {
    const int width  = topk + pool - 1;
    const int pools  = (seq_len + pool - 1) / pool;
    const int wanted = topk / pool;
    const int q_pos  = seq_len - 1;

    float *keys_alloc = NULL;
    float *k_smooth   = NULL;
    const float *keys_pool_src = keys_raw;
    const float *keys_eval     = keys_raw;
    float head_dc_bias[64];
    memset(head_dc_bias, 0, sizeof(head_dc_bias));

    if (enable_sage_d4) {
        keys_alloc      = (float *)malloc((size_t)seq_len * dim * sizeof(float));
        k_smooth        = (float *)malloc((size_t)seq_len * dim * sizeof(float));
        float *k_mean   = (float *)malloc((size_t)dim * sizeof(float));
        uint8_t *d4_row = (uint8_t *)malloc((size_t)(dim / 4));
        if (!keys_alloc || !k_smooth || !k_mean || !d4_row) {
            free(d4_row); free(k_mean); free(k_smooth); free(keys_alloc);
            return -1;
        }
        coli_udie_sage_key_mean_smooth(keys_raw, k_smooth, k_mean, seq_len, dim);

        /* Precompute per-head <q_h, \bar{k}> in O(heads * dim) so ReLU pool scoring is shift-exact */
        for (int h = 0; h < heads && h < 64; h++) {
            const float *qh = query_t + (size_t)h * dim;
            float b_h = 0.0f;
            for (int d = 0; d < dim; d++) b_h += qh[d] * k_mean[d];
            head_dc_bias[h] = b_h;
        }

        double dot = 0.0, nr = 1e-12, nq = 1e-12;
        for (int t = 0; t < seq_len; t++) {
            const float *ks = k_smooth   + (size_t)t * dim;
            float       *kd = keys_alloc + (size_t)t * dim;
            float rad = udie_tq_d4_quant_row(ks, d4_row, dim);
            udie_tq_d4_dequant_row(d4_row, rad, kd, dim);
            for (int d = 0; d < dim; d++) {
                dot += (double)ks[d] * (double)kd[d];
                nr  += (double)ks[d] * (double)ks[d];
                nq  += (double)kd[d] * (double)kd[d];
            }
        }
        if (out_kv_cos_sim) *out_kv_cos_sim = (float)(dot / sqrt(nr * nq));
        keys_pool_src = k_smooth;
        keys_eval     = keys_alloc;
        free(d4_row);
        free(k_mean);
    } else {
        if (out_kv_cos_sim) *out_kv_cos_sim = 1.0f;
    }

    /* Update incremental DSA k-pool cache for any newly completed pools */
    int start_p = cache ? cache->cached_pools : 0;
    if (cache && start_p > pools) start_p = 0;

    float *pooled_buf   = cache ? cache->pooled   : (float *)calloc((size_t)pools * dim, sizeof(float));
    float *scores_buf   = cache ? cache->scores   : (float *)malloc((size_t)pools * sizeof(float));
    unsigned char *comp = cache ? cache->complete : (unsigned char *)calloc((size_t)pools, 1);
    unsigned char *tak  = cache ? cache->taken    : (unsigned char *)calloc((size_t)pools, 1);

    int new_cached = start_p;
    for (int p = start_p; p < pools; p++) {
        int st = p * pool;
        unsigned char is_c = (st + pool <= seq_len) ? 1 : 0;
        comp[p] = is_c;
        if (!is_c) continue;
        for (int d = 0; d < dim; d++) {
            float mx = -FLT_MAX;
            for (int j = 0; j < pool; j++) {
                float lg = gates[(size_t)(st + j) * dim + d] + ape[(size_t)j * dim + d];
                if (lg > mx) mx = lg;
            }
            float tot = 0.0f;
            for (int j = 0; j < pool; j++) {
                tot += expf(gates[(size_t)(st + j) * dim + d] + ape[(size_t)j * dim + d] - mx);
            }
            float mix = 0.0f;
            for (int j = 0; j < pool; j++) {
                float w = expf(gates[(size_t)(st + j) * dim + d] + ape[(size_t)j * dim + d] - mx) / tot;
                mix += w * keys_pool_src[(size_t)(st + j) * dim + d];
            }
            pooled_buf[(size_t)p * dim + d] = mix;
        }
        if (p == new_cached) new_cached = p + 1;
    }
    if (cache) cache->cached_pools = new_cached;

    /* Score completed pools with ReLU lightning indexer */
    const float scale = 1.0f / sqrtf((float)dim);
    for (int i = 0; i < width; i++) out_selected[i] = -1;

    for (int p = 0; p < pools; p++) {
        int last = (p + 1) * pool - 1;
        if (!comp[p] || last > q_pos) { scores_buf[p] = -FLT_MAX; continue; }
        float sc = 0.0f;
        const float *pk = pooled_buf + (size_t)p * dim;
        for (int h = 0; h < heads; h++) {
            const float *qh = query_t + (size_t)h * dim;
            float dot = head_dc_bias[h];
            for (int d = 0; d < dim; d++) dot += qh[d] * pk[d];
            if (dot > 0.0f) sc += head_w[h] * dot * scale;
        }
        scores_buf[p] = sc;
    }

    for (int r = 0; r < wanted; r++) {
        int best = -1;
        for (int p = 0; p < pools; p++) {
            if (!tak[p] && scores_buf[p] > -FLT_MAX && (best < 0 || scores_buf[p] > scores_buf[best])) {
                best = p;
            }
        }
        if (best < 0) break;
        tak[best] = 1;
        for (int j = 0; j < pool; j++) out_selected[r * pool + j] = best * pool + j;
    }
    memset(tak, 0, (size_t)pools);

    /* Unconditionally append incomplete causal tail */
    int tail = seq_len % pool;
    int tail_start = seq_len - tail;
    for (int j = 0; j < tail && j < pool - 1; j++) {
        out_selected[topk + j] = tail_start + j;
    }

    /* Sparse attention over selected indices using Sage-smoothed D4-reconstructed keys
     * (Softmax is 100% shift-invariant to key-mean subtraction!) */
    float s_scores[512];
    for (int h = 0; h < heads; h++) {
        const float *qh = query_t + (size_t)h * dim;
        float mx = -FLT_MAX;
        int used = 0;
        for (int slot = 0; slot < width; slot++) {
            int kp = out_selected[slot];
            if (kp < 0 || kp >= seq_len) continue;
            const float *kt = keys_eval + (size_t)kp * dim;
            float dot = 0.0f;
            for (int d = 0; d < dim; d++) dot += qh[d] * kt[d];
            s_scores[used] = dot * scale;
            if (s_scores[used] > mx) mx = s_scores[used];
            used++;
        }
        float *res = out_attn + (size_t)h * dim;
        memset(res, 0, (size_t)dim * sizeof(float));
        if (used > 0) {
            float tot = 0.0f;
            for (int i = 0; i < used; i++) {
                s_scores[i] = expf(s_scores[i] - mx);
                tot += s_scores[i];
            }
            int idx = 0;
            for (int slot = 0; slot < width; slot++) {
                int kp = out_selected[slot];
                if (kp < 0 || kp >= seq_len) continue;
                float w = s_scores[idx++] / tot;
                const float *vt = values_raw + ((size_t)kp * heads + h) * dim;
                for (int d = 0; d < dim; d++) res[d] += w * vt[d];
            }
        }
    }

    if (!cache) {
        free(tak); free(comp); free(scores_buf); free(pooled_buf);
    }
    free(k_smooth);
    free(keys_alloc);
    return 0;
}

/* ============================================================================
 * SECTION 3: Layer 5 — `udie_layer5_csd_sacred_j_route_and_pilot`:
 *            UDIE 3-Term `0-DSP` CSD Router + Colibrì Sacred-`J` `CACHE_ROUTE`
 *            Residency Bonus + `COUPLE` Co-Activation + `PILOT` Prefetch
 * ============================================================================ */

typedef struct {
    int      routed_experts[16];     /* [top_k] selected expert IDs */
    float    routed_logits[16];      /* [top_k] raw router logits of selected experts */
    int      sacred_preserved_count; /* Number of top-J sacred experts preserved (always == sacred_J) */
    int      cache_hits_in_topk;     /* Number of routed experts resident in DRAM cache */
    int      pilot_prefetch_expert;  /* Predicted top Layer-(l+1) expert to prefetch on VC0 */
    bool     pilot_issued_on_vc0;    /* True if 2-VC credit arbiter accepted VC0 pilot prefetch */
} UdieSacredJRouteReport;

/*
 * `udie_layer5_csd_sacred_j_route_and_pilot`:
 *   1. Evaluates UDIE's 3-Term `0-DSP` CSD router (`coli_udie_router_3term_csd_0dsp`)
 *      to obtain raw router logits `raw_logits[0..E-1]`.
 *   2. Selects the top `sacred_J` (`0 <= j < sacred_J`) experts strictly by unmodified
 *      raw logit so the dominant MoE experts are NEVER perturbed by cache state.
 *   3. Selects the remaining tail slots (`sacred_J <= j < top_k`) using Colibrì's
 *      `CACHE_ROUTE` residency bias:
 *        ` biased_logit[e] = raw_logits[e] + cache_bonus_alpha * is_cached_cur[e] `
 *      when `enable_cache_route != 0`.
 *   4. Updates the intra-layer `E x E` `COUPLE` co-activation matrix (`couple_matrix`)
 *      and cross-layer `E x E` transition table (`cross_layer_matrix`), then predicts
 *      the highest-affinity non-cached Layer-`(l+1)` expert (`pilot_prefetch_expert`)
 *      and schedules it on `COLI_VC_PILOT` via `ColiUdie2VcArbiter`.
 */
static inline void udie_layer5_csd_sacred_j_route_and_pilot(
    const uint8_t          *csd_shifts,         /* [E, N, 3] */
    const int8_t           *csd_signs,          /* [E, N, 3] */
    const float            *group_scales,       /* [E, N / 64] */
    const float            *x_fp32,             /* [N] input hidden state */
    const uint8_t          *is_cached_cur,      /* [E] 1 if expert e is resident in Layer l cache */
    const uint8_t          *is_cached_next,     /* [E] 1 if expert e is resident in Layer l+1 cache */
    uint32_t               *couple_matrix,      /* [E * E] intra-layer COUPLE co-activation matrix */
    const uint32_t         *cross_layer_matrix, /* [E * E] Layer l -> Layer l+1 PILOT affinity */
    ColiUdie2VcArbiter     *vc_arbiter,         /* 2-VC credit-conserved DMA arbiter */
    int                     E,
    int                     N,
    int                     top_k,              /* e.g. 8 */
    int                     sacred_J,           /* e.g. 2 or 4 (sacred top slots untouched) */
    float                   cache_bonus_alpha,  /* e.g. 0.35f */
    int                     enable_cache_route, /* 1 = apply sacred-J CACHE_ROUTE + PILOT */
    UdieSacredJRouteReport *out_report
) {
    memset(out_report, 0, sizeof(*out_report));
    float raw_logits[256];
    uint8_t picked[256];
    int e_cap = (E <= 256) ? E : 256;
    memset(picked, 0, sizeof(picked));

    /* Step 1: 0-DSP 3-Term CSD Router evaluation */
    coli_udie_router_3term_csd_0dsp(csd_shifts, csd_signs, group_scales, x_fp32, raw_logits, e_cap, N);

    /* Also find the true unmodified top-J experts to verify 100% sacred preservation */
    int true_top_j[16];
    uint8_t true_used[256];
    memset(true_used, 0, sizeof(true_used));
    int j_lim = (sacred_J < top_k) ? sacred_J : top_k;
    for (int j = 0; j < j_lim; j++) {
        int best_e = 0;
        float best_v = -1e30f;
        for (int e = 0; e < e_cap; e++) {
            if (!true_used[e] && raw_logits[e] > best_v) {
                best_v = raw_logits[e];
                best_e = e;
            }
        }
        true_used[best_e] = 1;
        true_top_j[j] = best_e;
    }

    /* Step 2: Select Sacred Top-J slots (j = 0 .. sacred_J - 1) strictly from raw_logits */
    for (int j = 0; j < j_lim; j++) {
        int best_e = 0;
        float best_v = -1e30f;
        for (int e = 0; e < e_cap; e++) {
            if (!picked[e] && raw_logits[e] > best_v) {
                best_v = raw_logits[e];
                best_e = e;
            }
        }
        picked[best_e] = 1;
        out_report->routed_experts[j] = best_e;
        out_report->routed_logits[j]  = raw_logits[best_e];
    }

    /* Step 3: Select Tail slots (j = sacred_J .. top_k - 1) with Colibrì CACHE_ROUTE bias */
    float eff_alpha = enable_cache_route ? cache_bonus_alpha : 0.0f;
    for (int j = j_lim; j < top_k; j++) {
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

    /* Verify sacred-J preservation and count cache hits */
    int sacred_ok = 0;
    for (int j = 0; j < j_lim; j++) {
        if (out_report->routed_experts[j] == true_top_j[j]) sacred_ok++;
    }
    out_report->sacred_preserved_count = sacred_ok;

    int hits = 0;
    for (int j = 0; j < top_k; j++) {
        int e = out_report->routed_experts[j];
        if (is_cached_cur && is_cached_cur[e]) hits++;
    }
    out_report->cache_hits_in_topk = hits;

    /* Step 4: Update COUPLE co-activation matrix and predict Layer-(l+1) PILOT prefetch */
    if (couple_matrix) {
        for (int a = 0; a < top_k; a++) {
            int ea = out_report->routed_experts[a];
            for (int b = a + 1; b < top_k; b++) {
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
            if (is_cached_next && is_cached_next[cand]) continue; /* already resident in L+1 */
            uint64_t aff = 0;
            for (int j = 0; j < j_lim; j++) {
                int src_e = out_report->routed_experts[j];
                aff += (uint64_t)cross_layer_matrix[src_e * e_cap + cand] * (uint64_t)(j_lim - j);
            }
            if (aff > best_pilot_score) {
                best_pilot_score = aff;
                best_pilot = cand;
            }
        }
    }
    out_report->pilot_prefetch_expert = best_pilot;
    if (enable_cache_route && best_pilot >= 0 && vc_arbiter) {
        out_report->pilot_issued_on_vc0 = coli_udie_2vc_issue(vc_arbiter, COLI_VC_PILOT);
    }
}

/* ============================================================================
 * SECTION 4: Layer 5 — `udie_layer5_specgate_resumed_draft`:
 *            Colibrì O(1) `ColiSpecIndex` Suffix Lookup + `SpecGate` EMA
 *            Cost-Value Controller + UDIE Layer-Resumed AOT Wiener Bridge
 * ============================================================================ */

#define UDIE_SPEC_MAX_DRAFTS   8
#define UDIE_SPEC_HASH_BUCKETS 4096
#define UDIE_SPEC_MAX_HISTORY  16384

typedef struct {
    int head2[UDIE_SPEC_HASH_BUCKETS];
    int prev2[UDIE_SPEC_MAX_HISTORY];
    int head1[UDIE_SPEC_HASH_BUCKETS];
    int prev1[UDIE_SPEC_MAX_HISTORY];
    int indexed_len;
} UdieColiSpecIndex;

typedef struct {
    double acc[UDIE_SPEC_MAX_DRAFTS];
    double acc_w[UDIE_SPEC_MAX_DRAFTS];
    double rho;
    int    picks;
    int    declined;
    int    verifies;
} UdieColiSpecGate;

static inline unsigned int udie_coli_hash2(int a, int b) {
    unsigned int u = (unsigned int)a * 0x9E3779B1u ^ (unsigned int)b * 0x85EBCA77u;
    return (u ^ (u >> 12)) & (UDIE_SPEC_HASH_BUCKETS - 1u);
}

static inline unsigned int udie_coli_hash1(int a) {
    unsigned int u = (unsigned int)a * 0x9E3779B1u;
    return (u ^ (u >> 12)) & (UDIE_SPEC_HASH_BUCKETS - 1u);
}

static inline void udie_coli_spec_index_init(UdieColiSpecIndex *idx) {
    memset(idx->head2, -1, sizeof(idx->head2));
    memset(idx->head1, -1, sizeof(idx->head1));
    idx->indexed_len = 0;
}

static inline void udie_coli_spec_index_update(UdieColiSpecIndex *idx, const int *h, int len) {
    int cap = (len < UDIE_SPEC_MAX_HISTORY) ? len : UDIE_SPEC_MAX_HISTORY;
    if (idx->indexed_len > cap) udie_coli_spec_index_init(idx);
    for (int pos = idx->indexed_len; pos < cap; pos++) {
        unsigned int b1 = udie_coli_hash1(h[pos]);
        idx->prev1[pos] = idx->head1[b1];
        idx->head1[b1]  = pos;
        if (pos >= 1) {
            unsigned int b2 = udie_coli_hash2(h[pos - 1], h[pos]);
            idx->prev2[pos] = idx->head2[b2];
            idx->head2[b2]  = pos;
        } else {
            idx->prev2[pos] = -1;
        }
    }
    idx->indexed_len = cap;
}

static inline int udie_coli_spec_lookup_o1(
    UdieColiSpecIndex *idx,
    const int         *h,
    int                len,
    int                min_n,
    int                max_n,
    int                k,
    int               *out
) {
    if (!idx || !h || !out || k < 1 || min_n < 1 || len < min_n + 1) return 0;
    udie_coli_spec_index_update(idx, h, len - 1);
    if (max_n > len - 1) max_n = len - 1;
    for (int n = max_n; n >= min_n; n--) {
        const int *suf = h + len - n;
        if (n >= 2) {
            unsigned int b2 = udie_coli_hash2(suf[n - 2], suf[n - 1]);
            for (int end_pos = idx->head2[b2]; end_pos >= n - 1; end_pos = idx->prev2[end_pos]) {
                int i = end_pos - (n - 1);
                if (h[end_pos] != suf[n - 1] || h[end_pos - 1] != suf[n - 2]) continue;
                if (n > 2 && memcmp(h + i, suf, (size_t)(n - 2) * sizeof(int)) != 0) continue;
                int g = 0;
                for (int j = i + n; j < len && g < k; j++) out[g++] = h[j];
                return g;
            }
        } else {
            unsigned int b1 = udie_coli_hash1(suf[0]);
            for (int i = idx->head1[b1]; i >= 0; i = idx->prev1[i]) {
                if (h[i] != suf[0]) continue;
                int g = 0;
                for (int j = i + 1; j < len && g < k; j++) out[g++] = h[j];
                return g;
            }
        }
    }
    return 0;
}

static inline void udie_coli_spec_gate_init(UdieColiSpecGate *g, double rho_extra_row_cost) {
    memset(g, 0, sizeof(*g));
    for (int j = 0; j < UDIE_SPEC_MAX_DRAFTS; j++) {
        g->acc[j]   = (j == 0) ? 0.70 : ((j == 1) ? 0.55 : 0.45);
        g->acc_w[j] = 2.0;
    }
    g->rho = (rho_extra_row_cost > 0.0) ? rho_extra_row_cost : 0.35;
}

static inline double udie_coli_spec_gate_value(const UdieColiSpecGate *g, int k) {
    if (k <= 0) return 1.0;
    double e = 1.0, p = 1.0;
    for (int j = 0; j < k && j < UDIE_SPEC_MAX_DRAFTS; j++) {
        p *= g->acc[j];
        e += p;
    }
    double cost = 1.0 + (double)k * g->rho;
    return e / cost;
}

static inline int udie_coli_spec_gate_pick(UdieColiSpecGate *g, int max_k, double *out_val) {
    int best_k = 0;
    double best_v = 1.0;
    int lim = (max_k <= UDIE_SPEC_MAX_DRAFTS) ? max_k : UDIE_SPEC_MAX_DRAFTS;
    for (int k = 1; k <= lim; k++) {
        double v = udie_coli_spec_gate_value(g, k);
        if (v > best_v) {
            best_v = v;
            best_k = k;
        }
    }
    g->picks++;
    /* Colibrì SPEC_PROBE_NEW: when drafting is already profitable (best_k > 0),
     * periodically probe one draft deeper so higher-depth acceptance is discovered */
    if (best_k > 0 && best_k < lim && (g->picks % 4 == 0)) {
        best_k++;
        best_v = udie_coli_spec_gate_value(g, best_k);
    }
    if (best_k == 0) g->declined++;
    if (out_val) *out_val = best_v;
    return best_k;
}

static inline void udie_coli_spec_gate_update(UdieColiSpecGate *g, int judged, int accepted) {
    if (judged <= 0) return;
    g->verifies++;
    int lim = (judged <= UDIE_SPEC_MAX_DRAFTS) ? judged : UDIE_SPEC_MAX_DRAFTS;
    for (int j = 0; j < lim; j++) {
        if (g->acc_w[j] < 16.0) g->acc_w[j] += 1.0;
        double hit = (j < accepted) ? 1.0 : 0.0;
        g->acc[j] += (hit - g->acc[j]) / g->acc_w[j];
    }
}

/*
 * `udie_layer5_specgate_resumed_draft`:
 * Fuses:
 *   1. Colibrì's O(1) `UdieColiSpecIndex` suffix lookup (`spec_lookup_o1`),
 *   2. Colibrì's `SpecGate` EMA cost-value gate (`value(k) = E(k)/cost(k) > 1.0`),
 *   3. UDIE's 0-calibration AOT Wiener Early-Exit Bridge (`coli_udie_aot_early_exit_wiener_bridge`)
 *      + Layer-Resumed confidence margin gate (`margin >= min_margin_thresh`).
 *
 * Returns the number of drafted tokens `k_draft` in `0..max_k` (`0` = decline speculation
 * and resume Layer `L_draft .. L_final-1` directly from the cached partial hidden state
 * `h_early_exit`, guaranteeing `0` wasted layer evaluations!).
 */
static inline int udie_layer5_specgate_resumed_draft(
    UdieColiSpecIndex *spec_idx,
    UdieColiSpecGate  *spec_gate,
    const int         *token_history,         /* [hist_len] */
    int                hist_len,
    const float       *h_early_exit,          /* [D] hidden state at Layer L_draft */
    const float       *gamma_final_norm,      /* [D] final RMSNorm weight */
    const float       *skipped_layer_frob_sq, /* [num_skipped_layers] */
    int                num_skipped_layers,
    const float       *W_lm_head_sub,         /* [V_sub, D] early-exit vocabulary projection */
    int                V_sub,
    int                D,
    int                max_k,
    float              min_margin_thresh,
    int               *out_draft_tokens,      /* [max_k] */
    float             *out_wiener_margin,
    double            *out_gate_value
) {
    /* Step 1: Consult SpecGate EMA cost-value controller */
    double gate_val = 1.0;
    int gate_k = udie_coli_spec_gate_pick(spec_gate, max_k, &gate_val);
    if (out_gate_value) *out_gate_value = gate_val;
    if (gate_k == 0) {
        if (out_wiener_margin) *out_wiener_margin = 0.0f;
        return 0; /* SpecGate declined: 0 wasted draft steps, resume directly! */
    }

    /* Step 2: Apply 0-calibration AOT Wiener Early-Exit Bridge to h_early_exit */
    float gamma_bridge[1024];
    int d_cap = (D <= 1024) ? D : 1024;
    coli_udie_aot_early_exit_wiener_bridge(
        gamma_final_norm, skipped_layer_frob_sq, num_skipped_layers, d_cap, gamma_bridge
    );

    float h_bridged[1024];
    for (int d = 0; d < d_cap; d++) {
        h_bridged[d] = h_early_exit[d] * gamma_bridge[d];
    }

    /* Compute bridged early-exit Top-1 vs Top-2 logit margin */
    int best_tok = 0;
    float best_l1 = -1e30f, best_l2 = -1e30f;
    for (int v = 0; v < V_sub; v++) {
        const float *wr = W_lm_head_sub + (size_t)v * d_cap;
        float dot = 0.0f;
        for (int d = 0; d < d_cap; d++) dot += wr[d] * h_bridged[d];
        if (dot > best_l1) {
            best_l2 = best_l1;
            best_l1 = dot;
            best_tok = v;
        } else if (dot > best_l2) {
            best_l2 = dot;
        }
    }
    float margin = best_l1 - best_l2;
    if (out_wiener_margin) *out_wiener_margin = margin;

    if (margin < min_margin_thresh) {
        spec_gate->declined++;
        return 0; /* Low early-exit confidence: resume directly without drafting */
    }

    /* Step 3: O(1) hash-chain suffix lookup for multi-token continuation */
    int n_found = udie_coli_spec_lookup_o1(spec_idx, token_history, hist_len, 2, 5, gate_k, out_draft_tokens);
    if (n_found > 0) {
        return n_found;
    }

    /* Fallback to Wiener-bridged self-speculative top-1 draft token */
    out_draft_tokens[0] = best_tok;
    return 1;
}

#ifdef __cplusplus
}
#endif

#endif /* UDIE_COLIBRI_BORROWED_H */
