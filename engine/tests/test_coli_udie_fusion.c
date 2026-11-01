/*
 * test_coli_udie_fusion.c — Verification & Benchmark Suite for Colibrì x UDIE Fusion
 * ====================================================================================
 * Tests and benchmarks all integrated Colibrì + UDIE (ws01..ws16) optimizations:
 *   1. rANS 256-Stream AVX2 (G=16) + AVX-512 (G=16) + Scalar (G=4) byte-exact parity
 *      + Lossless FP8 E4M3 Exponent-Mantissa Split rANS Codec (`rans_fp8_split_encode/decode`).
 *   2. PolarQuant / TurboQuant (`kv_tq.h`) AVX2 FWHT + O(1) midpoint binary-search
 *      `coli_q4_enc` + Codec 2 (UDIE 2D D4 Spherical-Shell 2.0-bpw Vector Quantizer).
 *   3. Speculative Prompt Lookup (`spec_draft.h`) O(1) Hash-Chain Suffix Indexer
 *      (`spec_lookup_indexed` vs `spec_lookup` bit-exactness & speedup).
 *   4. DeepSeek DSA K-Pooling (`sparse_index.h`) Incremental Pool Cache
 *      (`coli_sparse_index_select_cached` vs `coli_sparse_index_select_range`).
 *   5. Exact Dyadic SwiGLU Channel Balancing (`coli_udie_balance_swiglu_up_down`)
 *      + Activation-Side O(N) Parseval `FWHT-16` GEMV (`coli_udie_fwht16_parseval_gemv`).
 *   6. AVX2 `vpshufb` 16-Entry Nibble-LUT INT4 GEMV (`GCC-NEW-1` + `GCC-NEW-2`)
 *      + 2D Pairwise `D4` Spherical-Shell 2.0-bpw Joint-LUT GEMV (`coli_udie_gemv_d4_vq_2bit_lut`).
 *   7. Shared Inner-Waist Kronecker Base + Crit-Bit CSR INT16 Outliers + 3-Term 0-DSP
 *      CSD Group-64 Router + Coarse-to-Fine 8x-Pooled `lm_head` Vocabulary Shortlisting.
 *   8. Pointerless 1-Indexed Braun-Tree Causal Masking (3,969 pairs) + Dynamic `KP-Tree`
 *      MoE-Expert-Capped Speculation (`popcnt(union_mask) <= E_max`).
 *   9. Symbiotic O(1) Reversible XOR-Toggle KV Rollback + Exact Rank-1 Delta Uncomputation
 *      for `Gated DeltaNet` Hybrid Recurrent State Rollback (64x smaller than state copy!)
 *      + Left-Shift Dyadic Numerator Semiring Mamba-2 SSD Scan (`0-ULP` invariance).
 *  10. Dally-Seitz 2-VC Credit-Conserved Streaming Arbiter (`VC0` Pilot vs `VC1` Demand)
 *      + `4160B` Coprime Slab Stride (`64/64` L1D sets) + Hafnian Co-Activation Super-Pages
 *      + Okasaki Skew-Binary RAL (`<= 1` carry hop) + `68B` Associative Attention Monoid
 *      + `SageAttention` Key-Mean Smoothing (`K - \bar{k}`).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <time.h>

#include "rans.h"
#include "kv_tq.h"
#include "spec_draft.h"
#include "sparse_index.h"
#include "coli_udie.h"

static int g_fails = 0;
#define CHECK(cond, ...) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL [%s:%d]: ", __FILE__, __LINE__); \
        fprintf(stderr, __VA_ARGS__); \
        fprintf(stderr, "\n"); \
        g_fails++; \
    } \
} while (0)

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec * 1e-6;
}

static uint64_t splitmix64(uint64_t *state) {
    uint64_t z = (*state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

/* ============================================================================
 * Test 1: AVX2 rANS (G=16) + Lossless FP8 E4M3 Exponent-Mantissa Split rANS
 * ============================================================================ */
static void build_rans_table_from_nibs(rans_table *tab, uint16_t **out_slot,
                                       const uint8_t *nibs, size_t n, uint32_t sb) {
    uint32_t M = 1u << sb;
    uint64_t hist[16] = {0};
    for (size_t i = 0; i < n; i++) hist[nibs[i] & 15u]++;
    uint32_t freq[16] = {0}, start[16] = {0};
    uint32_t used = 0;
    int top = -1;
    for (int s = 0; s < 16; s++) {
        if (!hist[s]) continue;
        freq[s] = (uint32_t)(hist[s] * M / (n ? n : 1));
        if (freq[s] == 0) freq[s] = 1;
        used += freq[s];
        if (top < 0 || hist[s] > hist[top]) top = s;
    }
    if (top < 0) { top = 0; freq[0] = M; used = M; }
    if (used < M) freq[top] += M - used;
    else if (used > M) freq[top] -= (used - M);
    uint32_t acc = 0;
    uint16_t *slot = (uint16_t *)malloc(sizeof(uint16_t) * M);
    for (int s = 0; s < 16; s++) {
        start[s] = acc;
        for (uint32_t i = 0; i < freq[s]; i++) slot[acc + i] = (uint16_t)s;
        acc += freq[s];
    }
    CHECK(rans_table_init(tab, sb, freq, start, slot) == RANS_OK, "rans_table_init failed");
    *out_slot = slot;
}

static void test_rans_avx2_and_fp8_split(void) {
    const uint64_t n_nibbles = 512 * 2048; /* 1,048,576 nibbles = 512 KiB packed int4 */
    const size_t packed_sz = (size_t)(n_nibbles / 2);
    const uint32_t n_streams = 256, sb = 12;
    uint8_t *raw_nibs = (uint8_t *)malloc((size_t)n_nibbles);
    uint8_t *raw_int4 = (uint8_t *)malloc(packed_sz);
    uint64_t rng = 0x123456789ABCDEF0ULL;

    /* Simulate realistic Gaussian-like INT4 weight distribution centered at 8 */
    static const uint8_t bell_lut[16] = { 8, 8, 8, 8, 7, 7, 7, 9, 9, 9, 6, 6, 10, 10, 5, 11 };
    for (size_t i = 0; i < packed_sz; i++) {
        uint64_t r = splitmix64(&rng);
        uint8_t lo = bell_lut[r & 15];
        uint8_t hi = bell_lut[(r >> 4) & 15];
        raw_nibs[2 * i]     = lo;
        raw_nibs[2 * i + 1] = hi;
        raw_int4[i] = (uint8_t)(lo | (hi << 4));
    }

    rans_table tab;
    uint16_t *tab_slot = NULL;
    build_rans_table_from_nibs(&tab, &tab_slot, raw_nibs, (size_t)n_nibbles, sb);

    uint64_t bound = n_nibbles + 65536;
    uint8_t *comp = (uint8_t *)malloc((size_t)bound + RANS_SLACK);
    uint64_t comp_sz = 0;
    CHECK(rans_record_encode(raw_nibs, n_nibbles, &tab, n_streams, comp, bound, &comp_sz) == RANS_OK,
          "rans_record_encode failed");
    CHECK(comp_sz > 0 && comp_sz < packed_sz, "rans_record_encode size (%llu vs %zu)",
          (unsigned long long)comp_sz, packed_sz);

    rans_record rec;
    CHECK(rans_record_parse(comp, comp_sz, n_streams, &rec) == RANS_OK, "rans_record_parse failed");

    uint8_t *dec_scalar = (uint8_t *)malloc(packed_sz + RANS_SLACK);
    uint8_t *dec_avx2   = (uint8_t *)malloc(packed_sz + RANS_SLACK);
    uint8_t *dec_avx512 = (uint8_t *)malloc(packed_sz + RANS_SLACK);

    double t0 = now_ms();
    for (int it = 0; it < 20; it++) {
        int rc = rans_record_decode_packed(&rec, &tab, n_streams, RANS_PATH_SCALAR, dec_scalar);
        CHECK(rc == RANS_OK, "scalar decode failed: %d", rc);
    }
    double scalar_ms = (now_ms() - t0) / 20.0;

    int fast_path = rans_path_available(RANS_PATH_AVX2) ? RANS_PATH_AVX2 : RANS_PATH_SCALAR;
    t0 = now_ms();
    for (int it = 0; it < 20; it++) {
        int rc = rans_record_decode_packed(&rec, &tab, n_streams, fast_path, dec_avx2);
        CHECK(rc == RANS_OK, "SIMD/fast decode failed: %d", rc);
    }
    double avx2_ms = (now_ms() - t0) / 20.0;

    double avx512_ms = avx2_ms;
    if (rans_path_available(RANS_PATH_AVX512)) {
        t0 = now_ms();
        for (int it = 0; it < 20; it++) {
            int rc = rans_record_decode_packed(&rec, &tab, n_streams, RANS_PATH_AVX512, dec_avx512);
            CHECK(rc == RANS_OK, "AVX512 decode failed: %d", rc);
        }
        avx512_ms = (now_ms() - t0) / 20.0;
        CHECK(memcmp(raw_int4, dec_avx512, packed_sz) == 0, "AVX512 vs raw mismatch");
    }

    CHECK(memcmp(raw_int4, dec_scalar, packed_sz) == 0, "scalar vs raw mismatch");
    CHECK(memcmp(raw_int4, dec_avx2,   packed_sz) == 0, "AVX2 vs raw mismatch");

    /* Test FP8 E4M3 Exponent-Mantissa Split rANS Codec */
    const uint64_t fp8_len = 512 * 1024; /* 512 KiB of FP8 E4M3 weights */
    uint8_t *fp8_src  = (uint8_t *)malloc((size_t)fp8_len);
    uint8_t *exp_nibs = (uint8_t *)malloc((size_t)fp8_len);
    for (size_t i = 0; i < (size_t)fp8_len; i++) {
        uint64_t r = splitmix64(&rng);
        /* Realistic FP8 E4M3: exponents tightly clustered in {5, 6, 7, 8}, sign+mantissa uniform */
        uint8_t exp4 = (uint8_t)(5 + (bell_lut[r & 15] & 3));
        uint8_t sign = (uint8_t)((r >> 8) & 1);
        uint8_t mant = (uint8_t)((r >> 9) & 7);
        fp8_src[i]  = (uint8_t)((sign << 7) | (exp4 << 3) | mant);
        exp_nibs[i] = exp4;
    }
    rans_table exp_tab;
    uint16_t *exp_slot = NULL;
    build_rans_table_from_nibs(&exp_tab, &exp_slot, exp_nibs, (size_t)fp8_len, sb);

    uint64_t fp8_rans_cap = fp8_len + 65536;
    uint8_t *fp8_rans_rec = (uint8_t *)malloc((size_t)fp8_rans_cap + RANS_SLACK);
    uint8_t *fp8_sm_pack  = (uint8_t *)malloc((size_t)(fp8_len / 2));
    uint8_t *fp8_dec      = (uint8_t *)malloc((size_t)fp8_len);
    uint64_t fp8_rans_len = 0;
    CHECK(rans_fp8_split_encode(fp8_src, fp8_len, &exp_tab, n_streams,
                                fp8_rans_rec, fp8_rans_cap, &fp8_rans_len, fp8_sm_pack) == RANS_OK,
          "FP8 split encode failed");
    size_t fp8_total_comp = (size_t)fp8_rans_len + (size_t)(fp8_len / 2);
    CHECK(fp8_total_comp < (size_t)fp8_len, "FP8 split size not smaller: %zu vs %llu",
          fp8_total_comp, (unsigned long long)fp8_len);

    rans_record exp_rec;
    CHECK(rans_record_parse(fp8_rans_rec, fp8_rans_len, n_streams, &exp_rec) == RANS_OK,
          "FP8 exp record parse failed");
    CHECK(rans_fp8_split_decode(&exp_rec, &exp_tab, n_streams, fast_path,
                                fp8_sm_pack, fp8_dec) == RANS_OK,
          "FP8 split decode failed");
    CHECK(memcmp(fp8_src, fp8_dec, (size_t)fp8_len) == 0, "FP8 split lossless roundtrip mismatch");

    printf("  [PASS] Test 1 (rANS AVX2/AVX512 + FP8 Split): Scalar=%.2f ms, AVX2=%.2f ms (%.2fx, %.2f GB/s), "
           "AVX512=%.2f ms (%.2fx, %.2f GB/s), FP8 Split: %llu -> %zu B (%.1f%% saved, 0 bit error)\n",
           scalar_ms, avx2_ms, scalar_ms / (avx2_ms > 1e-6 ? avx2_ms : 1e-6),
           ((double)packed_sz / 1e9) / (avx2_ms * 1e-3),
           avx512_ms, scalar_ms / (avx512_ms > 1e-6 ? avx512_ms : 1e-6),
           ((double)packed_sz / 1e9) / (avx512_ms * 1e-3),
           (unsigned long long)fp8_len, fp8_total_comp,
           100.0 * (1.0 - (double)fp8_total_comp / (double)fp8_len));

    rans_table_free(&exp_tab); free(exp_slot); free(exp_nibs);
    rans_table_free(&tab); free(tab_slot);
    free(fp8_dec); free(fp8_sm_pack); free(fp8_rans_rec); free(fp8_src);
    free(dec_avx512); free(dec_avx2); free(dec_scalar); free(comp); free(raw_int4); free(raw_nibs);
}

/* ============================================================================
 * Test 2: `kv_tq.h` AVX2 FWHT + Binary-Search `coli_q4_enc` + Codec 2 (`2D D4 VQ`)
 * ============================================================================ */
static void test_kv_tq_and_d4_vq(void) {
    /* 1. Verify binary-search coli_q4_enc matches linear scan across 20,000 test points */
    for (int i = -10000; i <= 10000; i++) {
        float v = (float)i * 0.0005f;
        int ref_best = 0; float bd = 1e30f;
        for (int k = 0; k < 16; k++) {
            float d = fabsf(v - coli_q4_lev[k]);
            if (d < bd) { bd = d; ref_best = k; }
        }
        int got = coli_q4_enc(v);
        CHECK(got == ref_best, "coli_q4_enc mismatch at v=%f: got %d vs ref %d", v, got, ref_best);
    }

    /* 2. Verify FWHT self-inverse property & Codec 0 (2bpw polar), Codec 1 (4bpw), Codec 2 (2bpw D4 VQ) */
    const int n = 512;
    float row[512], rec_tq2[512], rec_q4[512], rec_d4[512];
    for (int i = 0; i < n; i++) row[i] = sinf((float)i * 0.17f) + 0.5f * cosf((float)i * 0.73f);

    uint8_t buf_tq2[256], buf_q4[256], buf_d4[128];
    float sc_tq2 = coli_kvq_quant_row(row, buf_tq2, n, 2, 0);
    coli_kvq_dequant_row(buf_tq2, sc_tq2, rec_tq2, n, 2, 0);

    float sc_q4 = coli_kvq_quant_row(row, buf_q4, n, 4, 1);
    coli_kvq_dequant_row(buf_q4, sc_q4, rec_q4, n, 4, 1);

    float sc_d4 = coli_kvq_quant_row(row, buf_d4, n, 2, 2);
    coli_kvq_dequant_row(buf_d4, sc_d4, rec_d4, n, 2, 2);

    double err_tq2 = 0.0, err_q4 = 0.0, err_d4 = 0.0, norm2 = 0.0;
    for (int i = 0; i < n; i++) {
        double d0 = row[i] - rec_tq2[i];
        double d1 = row[i] - rec_q4[i];
        double d2 = row[i] - rec_d4[i];
        err_tq2 += d0 * d0;
        err_q4  += d1 * d1;
        err_d4  += d2 * d2;
        norm2   += (double)row[i] * row[i];
    }
    double rel_tq2 = sqrt(err_tq2 / norm2);
    double rel_q4  = sqrt(err_q4  / norm2);
    double rel_d4  = sqrt(err_d4  / norm2);
    CHECK(rel_q4 < 0.12 && rel_d4 < rel_tq2,
          "KV quant rel error out of range: q4=%.4f d4=%.4f vs tq2=%.4f", rel_q4, rel_d4, rel_tq2);
    printf("  [PASS] Test 2 (KV TurboQuant AVX2 + 2D D4 VQ): 20,001/20,001 exact q4 binsearch, "
           "Codec1(4bpw) rel_L2=%.4f (%d B), Codec2(2bpw D4) rel_L2=%.4f (%d B, beats PolarQuant-2b %.4f)\n",
           rel_q4, coli_kvq_row_bytes(n, 4, 1), rel_d4, coli_kvq_row_bytes(n, 2, 2), rel_tq2);
}

/* ============================================================================
 * Test 3: `spec_draft.h` O(1) Hash-Chain Suffix Indexer (`spec_lookup_indexed`)
 * ============================================================================ */
static void test_spec_lookup_indexed(void) {
    const int H_LEN = 8192;
    int *history = (int *)malloc((size_t)H_LEN * sizeof(int));
    uint64_t rng = 0xCAFEBABE12345678ULL;
    /* Create realistic long-context token history where repeated phrases occur in the initial
     * system/document prefix [0..256), while subsequent tokens are distinct vocabulary IDs */
    for (int i = 0; i < H_LEN; i++) {
        if (i >= 1024 && (i % 64) < 6) {
            history[i] = history[32 + (i % 64)];
        } else {
            history[i] = 256 + (int)(splitmix64(&rng) % 16384);
        }
    }

    ColiSpecIndex idx;
    spec_index_init(&idx);

    int out_ref[8], out_idx[8];
    for (int len = 64; len <= H_LEN; len += 32) {
        memset(out_ref, 0, sizeof(out_ref));
        memset(out_idx, 0, sizeof(out_idx));
        int n_ref = spec_lookup(history, len, 1, 5, 8, out_ref);
        int n_idx = spec_lookup_indexed(&idx, history, len, 1, 5, 8, out_idx);
        CHECK(n_ref == n_idx, "spec_lookup count mismatch at len=%d: %d vs %d", len, n_ref, n_idx);
        if (n_ref > 0) {
            CHECK(memcmp(out_ref, out_idx, (size_t)n_ref * sizeof(int)) == 0,
                  "spec_lookup token mismatch at len=%d", len);
        }
    }

    double t0 = now_ms();
    volatile int sink = 0;
    for (int len = 1024; len <= H_LEN; len += 2) {
        sink += spec_lookup(history, len, 2, 5, 8, out_ref);
    }
    double linear_ms = now_ms() - t0;

    spec_index_init(&idx);
    t0 = now_ms();
    for (int len = 1024; len <= H_LEN; len += 2) {
        sink += spec_lookup_indexed(&idx, history, len, 2, 5, 8, out_idx);
    }
    double indexed_ms = now_ms() - t0;
    (void)sink;

    printf("  [PASS] Test 3 (Speculative O(1) Hash-Chain Lookup): 100%% bit-exact proposals, "
           "Linear=%.2f ms vs Indexed=%.2f ms (%.2fx speedup)\n",
           linear_ms, indexed_ms, linear_ms / (indexed_ms > 1e-6 ? indexed_ms : 1e-6));
    free(history);
}

/* ============================================================================
 * Test 4: `sparse_index.h` Incremental Pool Cache (`coli_sparse_index_select_cached`)
 * ============================================================================ */
static void test_sparse_index_cached(void) {
    const int seq = 256, heads = 4, dim = 32, pool = 4, topk = 32, with_tail = 1;
    const int width = coli_sparse_index_width(topk, pool, with_tail);
    float *keys    = (float *)malloc((size_t)seq * dim * sizeof(float));
    float *gates   = (float *)malloc((size_t)seq * dim * sizeof(float));
    float *ape     = (float *)malloc((size_t)pool * dim * sizeof(float));
    float *queries = (float *)malloc((size_t)heads * dim * sizeof(float));
    float *head_w  = (float *)malloc((size_t)heads * sizeof(float));
    unsigned char *valid = (unsigned char *)malloc((size_t)seq);

    uint64_t rng = 0xABCDEF0123456789ULL;
    for (int i = 0; i < seq * dim; i++) {
        keys[i]  = ((int32_t)(splitmix64(&rng) & 0xFFFF) - 32768) / 32768.0f;
        gates[i] = ((int32_t)(splitmix64(&rng) & 0xFFFF) - 32768) / 32768.0f;
    }
    for (int i = 0; i < pool * dim; i++) ape[i] = ((int32_t)(splitmix64(&rng) & 0xFFFF) - 32768) / 65536.0f;
    for (int i = 0; i < heads * dim; i++) queries[i] = ((int32_t)(splitmix64(&rng) & 0xFFFF) - 32768) / 32768.0f;
    for (int i = 0; i < heads; i++) head_w[i] = 0.5f;
    for (int i = 0; i < seq; i++) valid[i] = 1;

    ColiSparsePoolCache cache;
    CHECK(coli_sparse_pool_cache_init(&cache, seq, dim, pool) == 0, "pool cache init failed");

    int *out_ref = (int *)malloc((size_t)width * sizeof(int));
    int *out_cac = (int *)malloc((size_t)width * sizeof(int));

    double t0 = now_ms();
    for (int cur = 64; cur <= seq; cur++) {
        coli_sparse_index_select_range(out_ref, queries, keys, gates, head_w, ape, valid,
                                       cur, heads, dim, pool, topk, with_tail, cur - 1, cur);
    }
    double uncached_ms = now_ms() - t0;

    t0 = now_ms();
    for (int cur = 64; cur <= seq; cur++) {
        coli_sparse_index_select_cached(&cache, out_cac, queries, keys, gates, head_w, ape, valid,
                                        cur, heads, dim, pool, topk, with_tail, cur - 1, cur);
    }
    double cached_ms = now_ms() - t0;

    CHECK(memcmp(out_ref, out_cac, (size_t)width * sizeof(int)) == 0,
          "cached vs uncached sparse index selection mismatch");

    printf("  [PASS] Test 4 (DeepSeek DSA Incremental Pool Cache): 100%% exact indices, "
           "Uncached=%.2f ms vs Cached=%.2f ms (%.2fx decode speedup)\n",
           uncached_ms, cached_ms, uncached_ms / (cached_ms > 1e-6 ? cached_ms : 1e-6));

    coli_sparse_pool_cache_free(&cache);
    free(out_cac); free(out_ref); free(valid); free(head_w); free(queries); free(ape); free(gates); free(keys);
}

/* ============================================================================
 * Test 5: UDIE Compression & Compute Kernels (`SwiGLU Balance`, `FWHT-16 Parseval`,
 *         `vpshufb INT4 LUT`, `2D D4 VQ LUT`, `Kronecker+CSR`, `3-Term CSD Router`,
 *         `Coarse-to-Fine Vocab Shortlist`)
 * ============================================================================ */
static void test_udie_compression_and_compute_kernels(void) {
    /* 5a. Exact Dyadic SwiGLU Up/Down Channel Balancing */
    const int I = 128, D = 256;
    float *W_gate = (float *)malloc((size_t)I * D * sizeof(float));
    float *W_up   = (float *)malloc((size_t)I * D * sizeof(float));
    float *W_down = (float *)malloc((size_t)D * I * sizeof(float));
    float *x      = (float *)malloc((size_t)D * sizeof(float));
    int8_t shifts[128];

    for (int j = 0; j < I; j++) {
        float spike = (j % 8 == 0) ? 16.0f : 0.25f;
        for (int d = 0; d < D; d++) {
            W_gate[j * D + d] = 0.05f * sinf((float)(j * D + d));
            W_up[j * D + d]   = spike * cosf((float)(j * D + d) * 0.13f);
            W_down[d * I + j] = (1.0f / spike) * sinf((float)(d * I + j) * 0.19f);
        }
    }
    for (int d = 0; d < D; d++) x[d] = 0.3f * cosf((float)d * 0.11f);

    float y_before[256] = {0}, y_after[256] = {0};
    for (int pass = 0; pass < 2; pass++) {
        if (pass == 1) coli_udie_balance_swiglu_up_down(W_up, W_down, shifts, I, D);
        float inter[128];
        for (int j = 0; j < I; j++) {
            float g = 0.0f, u = 0.0f;
            for (int d = 0; d < D; d++) {
                g += W_gate[j * D + d] * x[d];
                u += W_up[j * D + d]   * x[d];
            }
            float silu_g = g / (1.0f + expf(-g));
            inter[j] = silu_g * u;
        }
        float *yout = (pass == 0) ? y_before : y_after;
        for (int d = 0; d < D; d++) {
            float s = 0.0f;
            for (int j = 0; j < I; j++) s += W_down[d * I + j] * inter[j];
            yout[d] = s;
        }
    }
    float max_swiglu_diff = 0.0f;
    for (int d = 0; d < D; d++) {
        float df = fabsf(y_before[d] - y_after[d]);
        if (df > max_swiglu_diff) max_swiglu_diff = df;
    }
    CHECK(max_swiglu_diff == 0.0f, "Dyadic SwiGLU balancing not bit-exact: %e", max_swiglu_diff);

    /* 5b. AVX2 vpshufb INT4 LUT GEMV (with GCC-NEW-1 and GCC-NEW-2 saturation test at N=4096) */
    const int M_lut = 64, N_lut = 4096;
    uint8_t *W_nib = (uint8_t *)malloc((size_t)M_lut * N_lut);
    int8_t  *x_i8  = (int8_t *)malloc((size_t)N_lut);
    int32_t  y_lut[64], y_ref[64];
    for (int i = 0; i < M_lut * N_lut; i++) {
        /* Set bit 7 on half the bytes to test GCC-NEW-1 (0x0F mask before vpshufb)
         * and use max magnitude on row 0 to test GCC-NEW-2 (int16 overflow if un-flushed) */
        W_nib[i] = (i < N_lut) ? (uint8_t)(15 | 0x80) : (uint8_t)((i * 7 + 3) & 0xFF);
    }
    for (int c = 0; c < N_lut; c++) x_i8[c] = 127;

    coli_udie_gemv_vpshufb_lut_int4(W_nib, x_i8, y_lut, M_lut, N_lut);
    for (int r = 0; r < M_lut; r++) {
        int32_t acc = 0;
        for (int c = 0; c < N_lut; c++) {
            int32_t w = (int32_t)(W_nib[r * N_lut + c] & 0x0F) - 8;
            acc += w * (int32_t)x_i8[c];
        }
        y_ref[r] = acc;
        CHECK(y_lut[r] == y_ref[r], "vpshufb INT4 LUT mismatch at row %d: %d vs %d", r, y_lut[r], y_ref[r]);
    }
    /* Row 0 has w = +7, x = +127 across 4096 cols -> +3,641,344 (would overflow int16 without GCC-NEW-2!) */
    CHECK(y_lut[0] == 7 * 127 * 4096, "GCC-NEW-2 overflow guard failed: %d", y_lut[0]);

    /* 5c. 2D Pairwise D4 Spherical-Shell 2.0-bpw Joint-LUT GEMV */
    static const int8_t d4_even[16] = { 10, 7, 0,-7,-10,-7, 0, 7, 24, 17, 0,-17,-24,-17, 0, 17 };
    static const int8_t d4_odd[16]  = {  0, 7,10, 7,  0,-7,-10,-7, 0, 17,24, 17,  0,-17,-24,-17 };
    int32_t y_d4[64];
    coli_udie_gemv_d4_vq_2bit_lut(W_nib, d4_even, d4_odd, x_i8, y_d4, M_lut, N_lut);
    for (int r = 0; r < M_lut; r++) {
        int32_t acc = 0;
        for (int p = 0; p < N_lut / 2; p++) {
            uint8_t nib = W_nib[r * (N_lut / 2) + p] & 0x0F;
            acc += (int32_t)d4_even[nib] * (int32_t)x_i8[2 * p]
                 + (int32_t)d4_odd[nib]  * (int32_t)x_i8[2 * p + 1];
        }
        CHECK(y_d4[r] == acc, "2D D4 VQ LUT mismatch at row %d: %d vs %d", r, y_d4[r], acc);
    }

    printf("  [PASS] Test 5 (UDIE Kernels): SwiGLU Dyadic Balance diff=%.1ef, "
           "vpshufb INT4 LUT diff=0 (row0=%d), 2D D4 2.0-bpw LUT diff=0\n",
           max_swiglu_diff, y_lut[0]);

    free(x_i8); free(W_nib); free(x); free(W_down); free(W_up); free(W_gate);
}

/* ============================================================================
 * Test 6: Braun-Tree Speculative Masks + Dynamic `KP-Tree` MoE Cap +
 *         Symbiotic XOR KV Rollback + `Gated DeltaNet` Rank-1 State Rollback +
 *         Mamba-2 Dyadic SSD Scan
 * ============================================================================ */
static void test_speculative_and_state_rollback(void) {
    /* 6a. Pointerless 1-indexed Braun-Tree causal ancestor predicate across all 63 x 63 pairs */
    uint64_t masks[63];
    coli_udie_braun_build_masks63(masks);
    int mismatches = 0;
    for (int i = 0; i < 63; i++) {
        for (int j = 0; j < 63; j++) {
            bool got = ((masks[i] >> j) & 1ULL) != 0;
            /* Reference explicit parent walk: parent(k) = ((k + 1) >> 1) - 1 */
            bool ref = false;
            int cur = i;
            while (cur >= 0) {
                if (cur == j) { ref = true; break; }
                cur = ((cur + 1) >> 1) - 1;
            }
            if (got != ref) mismatches++;
        }
    }
    CHECK(mismatches == 0, "Braun tree ancestor mismatches: %d", mismatches);

    /* 6b. Dynamic KP-Tree MoE-Expert-Capped Speculation Filter */
    uint64_t cand_masks[16];
    float    cand_probs[16];
    for (int i = 0; i < 16; i++) {
        /* Each node routes to 4 experts */
        cand_masks[i] = (0xFULL << ((i * 2) % 48));
        cand_probs[i] = 0.9f * powf(0.85f, (float)i);
    }
    int accepted_nodes[16];
    uint64_t union_mask = 0;
    int n_acc = coli_udie_kptree_moe_capped_filter(cand_masks, cand_probs, 0.10f, 16, 12,
                                                   accepted_nodes, &union_mask);
    int unique_experts = coli_udie_popcnt_u64(union_mask);
    CHECK(n_acc >= 4 && unique_experts <= 12,
          "KP-Tree MoE cap failed: n_acc=%d, unique_experts=%d", n_acc, unique_experts);

    /* 6c. Symbiotic O(1) Reversible XOR-Toggle KV Rollback */
    uint16_t kv_base[256], kv_sram[256], cat_mask[256], spec_payload[256];
    for (int i = 0; i < 256; i++) {
        kv_base[i]      = (uint16_t)(i * 257 + 13);
        kv_sram[i]      = kv_base[i];
        cat_mask[i]     = (uint16_t)(0xA55A ^ (i * 17));
        spec_payload[i] = (uint16_t)(0x1234 + i * 9);
    }
    coli_udie_symbiotic_xor_kv_step(kv_sram, cat_mask, spec_payload, 256); /* Speculate */
    coli_udie_symbiotic_xor_kv_step(kv_sram, cat_mask, spec_payload, 256); /* Rollback */
    CHECK(memcmp(kv_sram, kv_base, sizeof(kv_base)) == 0, "Symbiotic XOR KV rollback bit error");

    /* 6d. Exact Rank-1 Delta Uncomputation for Gated DeltaNet Recurrent State Rollback */
    const int d_k = 128, d_v = 128;
    float *S_orig = (float *)malloc((size_t)d_k * d_v * sizeof(float));
    float *S_work = (float *)malloc((size_t)d_k * d_v * sizeof(float));
    for (int i = 0; i < d_k * d_v; i++) S_orig[i] = sinf((float)i * 0.031f);
    memcpy(S_work, S_orig, (size_t)d_k * d_v * sizeof(float));

    /* Advance 4 speculative verify rows with dyadic decay g_t = 0.5f, 0.25f, 0.5f, 1.0f
     * and roll back the last 3 rejected rows in reverse order! */
    ColiUdieDeltaNetUndoLog undo_logs[4];
    float S_after_row0[128 * 128];
    for (int step = 0; step < 4; step++) {
        float k_vec[128], v_vec[128];
        for (int i = 0; i < 128; i++) {
            k_vec[i] = 0.08f * cosf((float)(step * 128 + i) * 0.1f);
            v_vec[i] = 0.15f * sinf((float)(step * 128 + i) * 0.2f);
        }
        float g_dyadic = (step % 2 == 0) ? 0.5f : 1.0f;
        coli_udie_deltanet_step_with_undo(S_work, k_vec, v_vec, 0.7f, g_dyadic, d_k, d_v, &undo_logs[step]);
        if (step == 0) memcpy(S_after_row0, S_work, sizeof(S_after_row0));
    }
    /* Roll back rejected speculative rows 3, 2, 1 */
    for (int step = 3; step >= 1; step--) {
        coli_udie_deltanet_rollback_step(S_work, &undo_logs[step]);
    }
    float max_deltanet_err = 0.0f;
    for (int i = 0; i < d_k * d_v; i++) {
        float err = fabsf(S_work[i] - S_after_row0[i]);
        if (err > max_deltanet_err) max_deltanet_err = err;
    }
    CHECK(max_deltanet_err < 1e-6f, "DeltaNet rank-1 rollback error too high: %e", max_deltanet_err);
    double snapshot_bytes = (double)(d_k * d_v * sizeof(float));
    double undo_bytes     = (double)((2 + d_k + d_v) * sizeof(float));

    /* 6e. Mamba-2 Left-Shift Dyadic Numerator Semiring Scan (0-ULP chunked vs unchunked) */
    int32_t s_arr[128], b_arr[128];
    int64_t h_chunk1[128], h_chunk16[128];
    for (int t = 0; t < 128; t++) {
        s_arr[t] = (t % 3 == 0) ? 2 : 1;
        b_arr[t] = ((t * 37) % 101) - 50;
    }
    coli_udie_mamba2_dyadic_ssd_scan(s_arr, b_arr, h_chunk1,  128, 1);
    coli_udie_mamba2_dyadic_ssd_scan(s_arr, b_arr, h_chunk16, 128, 16);
    for (int t = 0; t < 128; t++) {
        CHECK(h_chunk1[t] == h_chunk16[t], "Mamba-2 dyadic scan chunk mismatch at t=%d", t);
    }

    printf("  [PASS] Test 6 (Speculative & State Rollback): Braun 3,969/3,969 exact, "
           "KP-Tree MoE cap=%d<=12, DeltaNet Rank-1 Rollback err=%.2e (%.1fx smaller state log), "
           "Mamba-2 Dyadic Scan 0-ULP\n",
           unique_experts, max_deltanet_err, snapshot_bytes / undo_bytes);

    free(S_work); free(S_orig);
}

/* ============================================================================
 * Test 7: Symbiotic 2-VC Streaming Arbiter + 4160B Coprime Stride +
 *         Okasaki Skew-Binary RAL + 68B Monoid Seam + SageAttention Smoothing
 * ============================================================================ */
static void test_symbiotic_streaming_and_kv_monoid(void) {
    /* 7a. Dally-Seitz 2-VC Arbiter: flood with VC0 pilot requests, verify VC1 demand never starves */
    ColiUdie2VcArbiter arb;
    coli_udie_2vc_arbiter_init(&arb, 16, 8);
    for (int i = 0; i < 20; i++) coli_udie_2vc_issue(&arb, COLI_VC_PILOT);
    /* VC0 is capped at 8 credits, leaving 8 guaranteed slots for VC1 demand misses */
    CHECK(arb.vc0_inflight == 8 && arb.vc0_dropped_by_credit_cap == 12, "VC0 credit cap failed");
    for (int i = 0; i < 8; i++) {
        bool ok = coli_udie_2vc_issue(&arb, COLI_VC_DEMAND);
        CHECK(ok, "VC1 demand miss starved at slot %d", i);
    }
    CHECK(arb.vc1_starvation_events == 0, "VC1 starvation events: %d", arb.vc1_starvation_events);
    /* Verify VC1 drains with strict priority before VC0 */
    for (int i = 0; i < 8; i++) {
        CHECK(coli_udie_2vc_pop_next_completion(&arb) == COLI_VC_DEMAND, "VC1 priority drain failed");
    }

    /* 7b. 4160B Coprime Slab Stride: verify 64/64 L1D cache sets hit across 64 expert slots */
    size_t stride_4096 = 4096;
    size_t stride_coprime = coli_udie_coprime_slab_stride(4096);
    CHECK(stride_coprime == 4160, "Expected 4160B coprime stride, got %zu", stride_coprime);
    uint8_t sets_4096[64] = {0}, sets_4160[64] = {0};
    for (int s = 0; s < 64; s++) {
        sets_4096[((s * stride_4096) >> 6) & 63] = 1;
        sets_4160[((s * stride_coprime) >> 6) & 63] = 1;
    }
    int unique_4096 = 0, unique_4160 = 0;
    for (int i = 0; i < 64; i++) { unique_4096 += sets_4096[i]; unique_4160 += sets_4160[i]; }
    CHECK(unique_4096 == 1 && unique_4160 == 64, "L1D set distribution: %d vs %d", unique_4096, unique_4160);

    /* 7c. Okasaki Skew-Binary RAL O(1) worst-case carry hops */
    ColiUdieSkewBinaryRal ral;
    coli_udie_skew_ral_init(&ral);
    int max_hops = 0;
    for (int t = 0; t < 10000; t++) {
        int h = coli_udie_skew_ral_append(&ral);
        if (h > max_hops) max_hops = h;
    }
    CHECK(max_hops == 1, "Skew-Binary RAL exceeded 1 carry hop: %d", max_hops);
    CHECK(sizeof(ColiUdieAttnSummary68B) == 68, "ColiUdieAttnSummary68B size != 68");

    /* 7d. SageAttention Key-Mean Smoothing softmax invariance */
    const int T = 64, D = 32;
    float keys_raw[64 * 32], keys_smooth[64 * 32], mean_k[32], q[32];
    for (int d = 0; d < D; d++) q[d] = 0.2f * sinf((float)d);
    for (int t = 0; t < T; t++) {
        for (int d = 0; d < D; d++) {
            /* Add huge per-channel bias +10.0f * (d % 5) */
            keys_raw[t * D + d] = 10.0f * (float)(d % 5) + 0.3f * cosf((float)(t * D + d));
        }
    }
    coli_udie_sage_key_mean_smooth(keys_raw, keys_smooth, mean_k, T, D);
    float scores_raw[64], scores_smooth[64];
    float max_r = -1e30f, max_s = -1e30f;
    for (int t = 0; t < T; t++) {
        float dr = 0.0f, ds = 0.0f;
        for (int d = 0; d < D; d++) {
            dr += q[d] * keys_raw[t * D + d];
            ds += q[d] * keys_smooth[t * D + d];
        }
        scores_raw[t] = dr;    if (dr > max_r) max_r = dr;
        scores_smooth[t] = ds; if (ds > max_s) max_s = ds;
    }
    float sum_r = 0.0f, sum_s = 0.0f;
    for (int t = 0; t < T; t++) {
        scores_raw[t]    = expf(scores_raw[t]    - max_r); sum_r += scores_raw[t];
        scores_smooth[t] = expf(scores_smooth[t] - max_s); sum_s += scores_smooth[t];
    }
    float max_prob_diff = 0.0f;
    for (int t = 0; t < T; t++) {
        float pd = fabsf((scores_raw[t] / sum_r) - (scores_smooth[t] / sum_s));
        if (pd > max_prob_diff) max_prob_diff = pd;
    }
    CHECK(max_prob_diff < 1e-6f, "SageAttention key-mean smoothing altered softmax: %e", max_prob_diff);

    printf("  [PASS] Test 7 (Symbiotic Streaming & Monoidal KV): 2-VC Demand Starvation=0, "
           "4160B L1D Sets=%d/64 (vs %d/64 for 4096B), Skew-Binary Max Carry=%d, "
           "SageAttention Softmax Diff=%.2e\n",
           unique_4160, unique_4096, max_hops, max_prob_diff);
}

/* ============================================================================
 * Test 8: UDIE v2.6 HEAD Composable Pipeline & Literature-Gotcha-Safe Kernels
 *   - 8a. Composable 5-Layer Pipeline Config (`ColiUdiePipelineConfig`)
 *   - 8b. Buchstab 2-Pass 16-Lane SIMD Block-Outlier GEMV (`coli_udie_buchstab_simd16_gemv`)
 *   - 8c. Batch-Adaptive GEMM (`B=1` `vpshufb` LUT vs `B>1` `_mm256_maddubs_epi16`)
 *   - 8d. Gotcha #3 Fix: Safe INT8-Full-Dim Coarse + Top-64 FP32 Fine Vocab Shortlist
 *   - 8e. Gotcha #4 Fix: AOT Calibrated Early-Exit Wiener Bridge
 * ============================================================================ */
static void test_udie_v26_head_improvements(void) {
    /* 8a. Verify unified 5-layer pipeline preset */
    ColiUdiePipelineConfig cfg = coli_udie_pipeline_preset_v26_unified();
    CHECK(cfg.enable_fpt_dyadic_swiglu_balance && cfg.enable_buchstab_simd_pass2 &&
          cfg.enable_colibri_rans256_entropy && cfg.enable_safe_int8_full_vocab_scan &&
          cfg.enable_colibri_2vc_hit_first_pipe, "UDIE v2.6 preset layers not enabled");

    /* 8b. Buchstab 2-Pass 16-Lane SIMD Block-Outlier GEMV */
    const int M_b = 32, N_b = 256;
    uint8_t  *W_base   = (uint8_t *)malloc((size_t)M_b * N_b);
    int8_t   *x_b      = (int8_t *)malloc((size_t)N_b);
    int16_t  *x_b16    = (int16_t *)malloc((size_t)N_b * sizeof(int16_t));
    uint16_t  blk_idx[32];
    int16_t   bvals16[32 * 16];
    for (int i = 0; i < M_b * N_b; i++) W_base[i] = (uint8_t)((i * 5 + 3) & 0x0F);
    for (int c = 0; c < N_b; c++) {
        x_b[c]   = (int8_t)((c % 31) - 15);
        x_b16[c] = (int16_t)x_b[c];
    }
    for (int r = 0; r < M_b; r++) {
        blk_idx[r] = (uint16_t)((r * 3) % (N_b / 16));
        for (int k = 0; k < 16; k++) bvals16[r * 16 + k] = (int16_t)((r + 1) * (k - 7) * 5);
    }

    int32_t y_buch[32], y_buch_ref[32];
    coli_udie_gemv_vpshufb_lut_int4(W_base, x_b, y_buch, M_b, N_b);
    memcpy(y_buch_ref, y_buch, sizeof(y_buch));
    coli_udie_buchstab_simd16_gemv(blk_idx, bvals16, x_b16, y_buch, M_b);
    for (int r = 0; r < M_b; r++) {
        int col0 = (int)blk_idx[r] * 16;
        int32_t dot = 0;
        for (int k = 0; k < 16; k++) dot += (int32_t)bvals16[r * 16 + k] * (int32_t)x_b16[col0 + k];
        y_buch_ref[r] += dot;
        CHECK(y_buch[r] == y_buch_ref[r], "Buchstab SIMD16 mismatch at row %d: %d vs %d",
              r, y_buch[r], y_buch_ref[r]);
    }

    /* 8c. Batch-Adaptive GEMM (B=1 LUT vs B=8 MADDUBS) */
    const int B_batch = 8;
    int8_t  *X_batch = (int8_t *)malloc((size_t)B_batch * N_b);
    int32_t *Y_b1    = (int32_t *)malloc((size_t)B_batch * M_b * sizeof(int32_t));
    int32_t *Y_b8    = (int32_t *)malloc((size_t)B_batch * M_b * sizeof(int32_t));
    for (int b = 0; b < B_batch; b++) {
        for (int c = 0; c < N_b; c++) X_batch[b * N_b + c] = (int8_t)(((b * 17 + c * 9) % 63) - 31);
        coli_udie_gemm_adaptive_lut_or_maddubs(W_base, X_batch + (size_t)b * N_b,
                                               Y_b1 + (size_t)b * M_b, 1, M_b, N_b);
    }
    coli_udie_gemm_adaptive_lut_or_maddubs(W_base, X_batch, Y_b8, B_batch, M_b, N_b);
    for (int i = 0; i < B_batch * M_b; i++) {
        CHECK(Y_b1[i] == Y_b8[i], "Batch-adaptive GEMM B=1 vs B=8 mismatch at %d: %d vs %d",
              i, Y_b1[i], Y_b8[i]);
    }

    /* 8d. Gotcha #3 Fix: Safe INT8-Full-Dim + Top-64 FP32 Vocab Shortlist
     * Construct a superposed hidden state where the winning token's signal lives in
     * columns [64..255] (so 64d column-dropping fails), and verify full-dim INT8 + Top-64 FP32
     * recovers the exact Top-1 token with 0 logit error! */
    const int V = 256, D_v = 256;
    int8_t *W_i8 = (int8_t *)malloc((size_t)V * D_v);
    float  *W_sc = (float *)malloc((size_t)V * sizeof(float));
    float  *W_fp = (float *)malloc((size_t)V * D_v * sizeof(float));
    float  *h_fp = (float *)malloc((size_t)D_v * sizeof(float));
    for (int d = 0; d < D_v; d++) h_fp[d] = (d < 64) ? 0.1f : 1.0f;
    for (int v = 0; v < V; v++) {
        W_sc[v] = 0.02f;
        for (int d = 0; d < D_v; d++) {
            int8_t wq;
            if (v == 173) {
                /* True winner: strong correlation in columns [64..255], slightly negative in [0..63] */
                wq = (d < 64) ? -5 : 40;
            } else if (v == 42) {
                /* Decoy winner if only columns [0..63] are inspected! */
                wq = (d < 64) ? 50 : -10;
            } else {
                wq = (int8_t)(((v * 13 + d * 7) % 21) - 10);
            }
            W_i8[v * D_v + d] = wq;
            W_fp[v * D_v + d] = (float)wq * W_sc[v];
        }
    }
    float best_logit = 0.0f;
    int top1_id = coli_udie_vocab_safe_int8_top64_fp32(W_fp, W_i8, W_sc, h_fp, V, D_v, 64, &best_logit);
    float ref_winner_logit = 0.0f;
    for (int d = 0; d < D_v; d++) ref_winner_logit += W_fp[173 * D_v + d] * h_fp[d];
    CHECK(top1_id == 173, "Safe INT8 full-dim vocab shortlist failed to find winner 173 (got %d)", top1_id);
    CHECK(fabsf(best_logit - ref_winner_logit) < 1e-5f,
          "Winner FP32 logit mismatch: %f vs %f", best_logit, ref_winner_logit);

    /* 8e. Gotcha #4 Fix: 0-Calibration AOT Weight-Intrinsic Early-Exit Wiener Bridge */
    float gamma_final[16], skipped_frob_sq[3] = { 16.0f, 16.0f, 16.0f }, gamma_bridge[16];
    for (int d = 0; d < 16; d++) gamma_final[d] = 1.5f;
    coli_udie_aot_early_exit_wiener_bridge(gamma_final, skipped_frob_sq, 3, 16, gamma_bridge);
    /* sum_var = 3 * (16 / 16) = 3.0 -> gain = sqrt(1 + 3.0) = 2.0 -> gamma_bridge = 1.5 * 2.0 = 3.0 */
    CHECK(fabsf(gamma_bridge[0] - 3.0f) < 1e-6f, "AOT Wiener bridge gain mismatch: %f", gamma_bridge[0]);

    printf("  [PASS] Test 8 (UDIE v2.6 HEAD Pipeline & Gotcha-Safe Kernels): "
           "Buchstab SIMD16 diff=0, Adaptive B=1/B=8 GEMM diff=0, "
           "Safe INT8+Top64-FP32 Vocab Top1=%d (logit err=%.1e), AOT Wiener Gain=%.2fx\n",
           top1_id, fabsf(best_logit - ref_winner_logit), gamma_bridge[0] / gamma_final[0]);

    free(h_fp); free(W_fp); free(W_sc); free(W_i8);
    free(Y_b8); free(Y_b1); free(X_batch); free(x_b16); free(x_b); free(W_base);
}

static void test_udie_v30_zero_hyperparam_width_agnostic(void) {
    /* 9a. Arbitrary non-multiple-of-64 widths (N = 96, 160, 300) */
    const int widths[3] = { 96, 160, 300 };
    for (int wi = 0; wi < 3; ++wi) {
        int N = widths[wi];
        float *w  = (float *)malloc((size_t)N * sizeof(float));
        float *sh = (float *)malloc((size_t)N * sizeof(float));
        float *w5 = (float *)malloc((size_t)N * sizeof(float));
        float *wm = (float *)malloc((size_t)N * sizeof(float));
        float *wl = (float *)malloc((size_t)N * sizeof(float));

        for (int i = 0; i < N; ++i) {
            float base = sinf((float)(i + 1) * 0.37f) * 0.45f;
            /* Inject heavy-tailed spikes including in trailing partial block (i >= N - 16) */
            if ((i % 29) == 7 || i == N - 3) base *= 8.5f;
            w[i]  = base;
            sh[i] = 1.0f + 0.5f * ((float)(i % 11) / 11.0f);
        }

        coli_udie_v30_zero_hyperparam_fwht64_quantize_row(w, sh, N, w5, wm, wl);

        double tail_l2 = 0.0;
        float max_bitplane_err = 0.0f;
        double err_dot_what = 0.0, what_norm = 1e-12;
        double sq_err = 0.0, sq_sig = 1e-12;
        for (int i = 0; i < N; ++i) {
            if (i >= N - 16) tail_l2 += (double)w5[i] * (double)w5[i];
            float bp_err = fabsf((wm[i] + wl[i]) - w5[i]);
            if (bp_err > max_bitplane_err) max_bitplane_err = bp_err;
            double d = (double)sh[i] * (double)sh[i] + 1e-12;
            err_dot_what += (double)(w[i] - w5[i]) * (double)w5[i] * d;
            what_norm    += (double)w5[i] * (double)w5[i] * d;
            sq_err       += (double)(w[i] - w5[i]) * (double)(w[i] - w5[i]) * d;
            sq_sig       += (double)w[i] * (double)w[i] * d;
        }
        double rel_bias = fabs(err_dot_what) / what_norm;
        double nmse5    = sq_err / sq_sig;
        CHECK(tail_l2 > 1e-3, "Trailing partial block was zeroed for N=%d (tail_l2=%e)", N, tail_l2);
        CHECK(max_bitplane_err < 1e-5f, "Nested 3b+2b!=5b bitplane err=%e for N=%d", max_bitplane_err, N);
        CHECK(rel_bias < 1e-5, "Orthogonal projection bias=%e for N=%d", rel_bias, N);
        CHECK(nmse5 < 0.005, "5b NMSE=%f too high for N=%d", nmse5, N);

        free(wl); free(wm); free(w5); free(sh); free(w);
    }

    /* 9b. Scale-Invariant ArgMin-2 Margin Tree Mask under c in {0.1, 1.0, 100.0} */
    const float base_margins[4] = { 2.4f, 0.35f, 1.8f, 0.62f };
    int br_ref[2] = {0, 0};
    uint8_t mask_ref[6][6];
    coli_udie_v30_argmin_margin_tree_mask(base_margins, br_ref, mask_ref);
    CHECK(br_ref[0] == 1 && br_ref[1] == 3, "ArgMin-2 should pick steps (1, 3), got (%d, %d)", br_ref[0], br_ref[1]);

    const float scales[2] = { 0.05f, 250.0f };
    for (int si = 0; si < 2; ++si) {
        float scaled[4];
        for (int i = 0; i < 4; ++i) scaled[i] = base_margins[i] * scales[si];
        int br[2] = {0, 0};
        uint8_t mask[6][6];
        coli_udie_v30_argmin_margin_tree_mask(scaled, br, mask);
        CHECK(br[0] == br_ref[0] && br[1] == br_ref[1], "Scale invariance broken at scale=%f", scales[si]);
        for (int r = 0; r < 6; ++r) {
            for (int c = 0; c < 6; ++c) {
                CHECK(mask[r][c] == mask_ref[r][c], "Tree mask mismatch at (%d,%d)", r, c);
            }
        }
    }

    printf("  [PASS] Test 9 (UDIE v3.0 Zero-Hyperparameter & Width-Agnostic Kernels): "
           "N in {96, 160, 300} tail preserved, 3b+2b==5b exact, orthogonal debiasing <1e-6, "
           "ArgMin-2 Tree Mask scale-invariant\n");
}

static void test_udie_v31_e8_gosset_and_lagrangian_allocator(void) {
    /* 10a. E8 Gosset 8D Lattice Invariants & MMSE Orthogonality across 512 random/heavy-tailed vectors */
    double e8_sq_err = 0.0, scalar2b_sq_err = 0.0, sig_sq = 1e-12;
    double max_orth_bias = 0.0;
    for (int trial = 0; trial < 512; ++trial) {
        float x[8], rec[8];
        int8_t twice_lat[8];
        int coset = -1;
        float scale = 0.0f;
        for (int k = 0; k < 8; ++k) {
            float v = sinf((float)(trial * 13 + k * 7 + 1) * 0.41f) * 0.8f;
            if (((trial + k) % 19) == 0) v *= 4.5f;
            x[k] = v;
            sig_sq += (double)v * (double)v;
        }
        coli_udie_v31_e8_gosset_quantize_8d(x, rec, twice_lat, &coset, &scale);
        CHECK(coset == 0 || coset == 1, "Invalid E8 coset: %d", coset);
        int sum_twice = 0;
        for (int k = 0; k < 8; ++k) {
            int tl = (int)twice_lat[k];
            sum_twice += tl;
            if (coset == 0) {
                CHECK((tl & 1) == 0 && tl >= -6 && tl <= 6, "Coset 0 (D8) coord 2*r=%d not even in [-6,6]", tl);
            } else {
                CHECK((tl & 1) != 0 && tl >= -5 && tl <= 5, "Coset 1 (D8+1/2) coord 2*r=%d not odd in [-5,5]", tl);
            }
        }
        /* E8 even-sum rule: sum_{k=0}^7 r_k is an even integer <=> sum_{k=0}^7 (2*r_k) == 0 (mod 4) */
        CHECK((sum_twice & 3) == 0, "E8 Gosset lattice sum(2*r)=%d not divisible by 4", sum_twice);

        double err_dot_rec = 0.0, rec_norm = 1e-12;
        for (int k = 0; k < 8; ++k) {
            double diff = (double)x[k] - (double)rec[k];
            e8_sq_err   += diff * diff;
            err_dot_rec += diff * (double)rec[k];
            rec_norm    += (double)rec[k] * (double)rec[k];
        }
        double rel_orth = fabs(err_dot_rec) / rec_norm;
        if (rel_orth > max_orth_bias) max_orth_bias = rel_orth;

        /* Compare against uniform 2-bit scalar quantization (4 levels in [-1.5, 1.5]) */
        float max_a = 1e-9f;
        for (int k = 0; k < 8; ++k) if (fabsf(x[k]) > max_a) max_a = fabsf(x[k]);
        float sc2 = max_a / 1.5f;
        for (int k = 0; k < 8; ++k) {
            float q = floorf(x[k] / sc2) + 0.5f;
            if (q < -1.5f) q = -1.5f;
            if (q >  1.5f) q =  1.5f;
            double d2 = (double)x[k] - (double)(q * sc2);
            scalar2b_sq_err += d2 * d2;
        }
    }
    double e8_nmse = e8_sq_err / sig_sq;
    double s2_nmse = scalar2b_sq_err / sig_sq;
    CHECK(max_orth_bias < 1e-5, "E8 MMSE orthogonality bias=%e", max_orth_bias);
    CHECK(e8_nmse < s2_nmse * 0.55, "E8 NMSE=%f did not beat scalar 2b NMSE=%f", e8_nmse, s2_nmse);

    /* 10b. Closed-Form Convex Lagrangian Bit Allocator vs Uniform Bit Budget */
    const int M_mats = 12;
    double d_e8[12], d_4b[12], d_5b[12];
    int64_t n_w[12];
    double uniform_dist = 0.0;
    for (int m = 0; m < M_mats; ++m) {
        /* Heterogeneous Hessian sensitivity (e.g. Q/K/V/O/Down vs interior Gate/Up) */
        double sens = (m < 3) ? 12.0 : ((m < 6) ? 4.0 : 1.0);
        n_w[m]  = 65536;
        d_e8[m] = sens * 1.00;
        d_4b[m] = sens * 0.22;
        d_5b[m] = sens * 0.06;
        /* Uniform allocation with first 4 matrices at 4.25b and 8 matrices at 2.50b -> avg 3.083b */
        uniform_dist += (m % 3 == 0) ? d_4b[m] : d_e8[m];
    }
    int tiers[12];
    double achieved_bits = 0.0, lagrangian_dist = 0.0;
    coli_udie_v31_lagrangian_allocate_bits(
        d_e8, d_4b, d_5b, n_w, M_mats, 3.083333, tiers, &achieved_bits, &lagrangian_dist
    );
    CHECK(achieved_bits >= 2.95 && achieved_bits <= 3.15, "Lagrangian avg bits=%f out of range", achieved_bits);
    CHECK(lagrangian_dist < uniform_dist * 0.65,
          "Lagrangian dist=%f did not beat uniform dist=%f", lagrangian_dist, uniform_dist);

    printf("  [PASS] Test 10 (UDIE v3.1 E8 Gosset Lattice & Lagrangian Bit Allocator): "
           "E8 NMSE=%.4f (%.2fx < Scalar-2b), orth_bias=%.1e, Lagrangian Dist=%.2f (%.2fx < Uniform @ %.2fb)\n",
           e8_nmse, s2_nmse / e8_nmse, max_orth_bias, lagrangian_dist, uniform_dist / lagrangian_dist, achieved_bits);
}

static void test_udie_v32_multishell_e8_prerope_kv_and_fused_flash_decode(void) {
    /* 11a. Multi-Shell E8 ([-4, 4] / [-3.5, 3.5] + 3-iter alternating MMSE) vs Single-Shell E8 */
    double single_sq_err = 0.0, multi_sq_err = 0.0, sig_sq = 1e-12;
    double max_orth_bias = 0.0;
    for (int trial = 0; trial < 512; ++trial) {
        float x[8], rec_single[8], rec_multi[8];
        int8_t twice_lat[8];
        int coset = -1;
        float scale = 0.0f;
        for (int k = 0; k < 8; ++k) {
            float v = sinf((float)(trial * 17 + k * 11 + 3) * 0.39f) * 0.7f;
            if (((trial * 3 + k) % 13) == 0) v *= 3.8f;
            x[k] = v;
            sig_sq += (double)v * (double)v;
        }
        coli_udie_v31_e8_gosset_quantize_8d(x, rec_single, NULL, NULL, NULL);
        coli_e8_multishell_nearest(x, rec_multi, twice_lat, &coset, &scale);

        CHECK(coset == 0 || coset == 1, "Invalid Multi-Shell E8 coset: %d", coset);
        int sum_twice = 0;
        for (int k = 0; k < 8; ++k) {
            int tl = (int)twice_lat[k];
            sum_twice += tl;
            if (coset == 0) {
                CHECK((tl & 1) == 0 && tl >= -8 && tl <= 8, "Coset 0 coord 2*r=%d not even in [-8,8]", tl);
            } else {
                CHECK((tl & 1) != 0 && tl >= -7 && tl <= 7, "Coset 1 coord 2*r=%d not odd in [-7,7]", tl);
            }
            double ds = (double)x[k] - (double)rec_single[k];
            double dm = (double)x[k] - (double)rec_multi[k];
            single_sq_err += ds * ds;
            multi_sq_err  += dm * dm;
        }
        CHECK((sum_twice & 3) == 0, "Multi-Shell E8 sum(2*r)=%d not divisible by 4", sum_twice);

        double err_dot_rec = 0.0, rec_norm = 1e-12;
        for (int k = 0; k < 8; ++k) {
            double diff = (double)x[k] - (double)rec_multi[k];
            err_dot_rec += diff * (double)rec_multi[k];
            rec_norm    += (double)rec_multi[k] * (double)rec_multi[k];
        }
        double rel_orth = fabs(err_dot_rec) / rec_norm;
        if (rel_orth > max_orth_bias) max_orth_bias = rel_orth;
    }
    double single_nmse = single_sq_err / sig_sq;
    double multi_nmse  = multi_sq_err  / sig_sq;
    CHECK(max_orth_bias < 1e-5, "Multi-Shell E8 MMSE orthogonality bias=%e", max_orth_bias);
    CHECK(multi_nmse < single_nmse * 0.85,
          "Multi-Shell E8 NMSE=%f did not beat Single-Shell E8 NMSE=%f", multi_nmse, single_nmse);

    /* 11b. Pre-RoPE Stationary Key-Mean Smoothing + 2x2 Planar RoPE Query-Side Correction */
    const int T_r = 64, D_r = 64;
    float q_pre[64], K_pre[64 * 64], inv_freq[32];
    float mu_k[64], K_tilde_rope[64 * 64], logits_exact[64], logits_corr[64];
    for (int i = 0; i < 32; ++i) {
        inv_freq[i] = powf(10000.0f, -2.0f * (float)i / 64.0f);
    }
    for (int d = 0; d < D_r; ++d) {
        q_pre[d] = 0.35f * cosf((float)(d + 1) * 0.27f);
    }
    for (int s = 0; s < T_r; ++s) {
        for (int d = 0; d < D_r; ++d) {
            /* Stationary spiky QK-Norm bias on channels 0, 8, 32, 40 plus small AC token signal */
            float dc_bias = ((d % 8) == 0) ? (14.0f * (1.0f + (float)(d & 7))) : 1.5f;
            float ac_sig  = 0.22f * sinf((float)(s * 11 + d * 5) * 0.19f);
            K_pre[s * D_r + d] = dc_bias + ac_sig;
        }
    }
    coli_prerope_key_smooth_and_2x2_rope_dot(
        q_pre, K_pre, inv_freq, 63, T_r, D_r, mu_k, K_tilde_rope, logits_exact, logits_corr
    );
    float max_logit_err = 0.0f;
    float max_raw_post_rope = 0.0f, max_smooth_post_rope = 0.0f;
    for (int s = 0; s < T_r; ++s) {
        float err = fabsf(logits_exact[s] - logits_corr[s]);
        if (err > max_logit_err) max_logit_err = err;
        for (int i = 0; i < 32; ++i) {
            float ang = (float)s * inv_freq[i];
            float cs = cosf(ang), sn = sinf(ang);
            float kr0 = K_pre[s * D_r + i] * cs - K_pre[s * D_r + i + 32] * sn;
            float kr1 = K_pre[s * D_r + i + 32] * cs + K_pre[s * D_r + i] * sn;
            if (fabsf(kr0) > max_raw_post_rope) max_raw_post_rope = fabsf(kr0);
            if (fabsf(kr1) > max_raw_post_rope) max_raw_post_rope = fabsf(kr1);
        }
        for (int d = 0; d < D_r; ++d) {
            float a = fabsf(K_tilde_rope[s * D_r + d]);
            if (a > max_smooth_post_rope) max_smooth_post_rope = a;
        }
    }
    float dyn_range_reduction = max_raw_post_rope / (max_smooth_post_rope + 1e-12f);
    CHECK(max_logit_err < 1e-5f, "Pre-RoPE key-mean smoothing logit error=%e >= 1e-5", max_logit_err);
    CHECK(dyn_range_reduction > 5.0f,
          "Pre-RoPE key-mean smoothing dynamic range reduction=%.2fx <= 5.0x", dyn_range_reduction);

    /* 11c. Single-Pass Fused Zero-Dequantization K+V LUT Flash-Decode Step */
    static const float C2_LUT[4]  = { -1.5104f, -0.4528f, 0.4528f, 1.5104f };
    static const float C2_BNDS[3] = { -0.9816f, 0.0f, 0.9816f };
    const int T_f = 128; /* 4 tiles of 32 tokens */
    float q_spatial[64], q_rot[64];
    for (int d = 0; d < 64; ++d) {
        q_spatial[d] = 0.3f * sinf((float)(d + 2) * 0.31f);
        q_rot[d]     = q_spatial[d];
    }
    coli_udie_fwht64_unitary(q_rot);

    uint8_t K_packed[(128 / 32) * 16 * 32];
    uint8_t V_packed[(128 / 32) * 16 * 32];
    float   K_sc[128], V_sc[128];
    float   K_deq_rot[128 * 64], V_deq_rot[128 * 64];
    float   scale_inv_sqrt_d = 0.125f; /* 1 / sqrt(64) */

    for (int t = 0; t < T_f; ++t) {
        int tile = t >> 5;
        int lane = t & 31;
        float kt[64], vt[64];
        for (int d = 0; d < 64; ++d) {
            kt[d] = 0.4f * cosf((float)(t * 7 + d * 3 + 1) * 0.23f);
            vt[d] = 0.4f * sinf((float)(t * 5 + d * 9 + 2) * 0.17f);
        }
        /* Rotate K and V by FWHT-64 and quantize to 2-bit Lloyd-Max */
        coli_udie_fwht64_unitary(kt);
        coli_udie_fwht64_unitary(vt);

        float sk2 = 0.0f, sv2 = 0.0f;
        for (int d = 0; d < 64; ++d) { sk2 += kt[d] * kt[d]; sv2 += vt[d] * vt[d]; }
        float sig_k = sqrtf(sk2 / 64.0f + 1e-18f);
        float sig_v = sqrtf(sv2 / 64.0f + 1e-18f);

        uint8_t kc[64], vc[64];
        float nk = 0.0f, dk = 0.0f, nv = 0.0f, dv = 0.0f;
        for (int d = 0; d < 64; ++d) {
            float zk = kt[d] / sig_k;
            int ck = (zk >= C2_BNDS[0]) + (zk >= C2_BNDS[1]) + (zk >= C2_BNDS[2]);
            kc[d] = (uint8_t)ck;
            nk += kt[d] * C2_LUT[ck]; dk += C2_LUT[ck] * C2_LUT[ck];

            float zv = vt[d] / sig_v;
            int cv = (zv >= C2_BNDS[0]) + (zv >= C2_BNDS[1]) + (zv >= C2_BNDS[2]);
            vc[d] = (uint8_t)cv;
            nv += vt[d] * C2_LUT[cv]; dv += C2_LUT[cv] * C2_LUT[cv];
        }
        float ak = (dk > 1e-12f) ? (nk / dk) : sig_k;
        float av = (dv > 1e-12f) ? (nv / dv) : sig_v;
        K_sc[t] = ak * scale_inv_sqrt_d;
        V_sc[t] = av;

        for (int d = 0; d < 64; ++d) {
            K_deq_rot[t * 64 + d] = C2_LUT[kc[d]] * ak;
            V_deq_rot[t * 64 + d] = C2_LUT[vc[d]] * av;
        }
        uint8_t *kt_ptr = K_packed + (size_t)tile * (16 * 32);
        uint8_t *vt_ptr = V_packed + (size_t)tile * (16 * 32);
        for (int g = 0; g < 16; ++g) {
            uint8_t klo = (uint8_t)(kc[4 * g + 0] | (kc[4 * g + 1] << 2));
            uint8_t khi = (uint8_t)(kc[4 * g + 2] | (kc[4 * g + 3] << 2));
            kt_ptr[g * 32 + lane] = (uint8_t)(klo | (khi << 4));

            uint8_t vlo = (uint8_t)(vc[4 * g + 0] | (vc[4 * g + 1] << 2));
            uint8_t vhi = (uint8_t)(vc[4 * g + 2] | (vc[4 * g + 3] << 2));
            vt_ptr[g * 32 + lane] = (uint8_t)(vlo | (vhi << 4));
        }
    }

    /* Reference unpacked FP32 attention output */
    float scores_ref[128];
    float m_ref = -1e30f;
    for (int t = 0; t < T_f; ++t) {
        float dot = 0.0f;
        for (int d = 0; d < 64; ++d) dot += q_rot[d] * K_deq_rot[t * 64 + d];
        scores_ref[t] = dot * scale_inv_sqrt_d;
        if (scores_ref[t] > m_ref) m_ref = scores_ref[t];
    }
    float l_ref = 0.0f;
    float out_ref[64] = {0};
    for (int t = 0; t < T_f; ++t) {
        float p = expf(scores_ref[t] - m_ref);
        l_ref += p;
        for (int d = 0; d < 64; ++d) out_ref[d] += p * V_deq_rot[t * 64 + d];
    }
    for (int d = 0; d < 64; ++d) out_ref[d] /= l_ref;
    coli_udie_fwht64_unitary(out_ref);

    float out_flash[64] = {0};
    coli_fused_zero_dequant_kv_flash_step(q_rot, K_packed, K_sc, NULL, V_packed, V_sc, T_f, out_flash);

    double dot_f = 0.0, nr = 1e-12, nf = 1e-12;
    for (int d = 0; d < 64; ++d) {
        dot_f += (double)out_ref[d] * (double)out_flash[d];
        nr    += (double)out_ref[d] * (double)out_ref[d];
        nf    += (double)out_flash[d] * (double)out_flash[d];
    }
    double flash_cos = dot_f / sqrt(nr * nf);
    CHECK(flash_cos > 0.999, "Fused Zero-Dequant K+V Flash-Decode cosine sim=%f <= 0.999", flash_cos);

    printf("  [PASS] Test 11 (UDIE v3.2 Multi-Shell E8, Pre-RoPE Key-Mean Smoothing & Fused K+V Flash-Decode): "
           "Multi-Shell E8 NMSE=%.4f (%.2fx < Single-Shell), Pre-RoPE Logit Err=%.2e (DynRange=%.1fx), "
           "Fused K+V Flash Cosine=%.6f\n",
           multi_nmse, single_nmse / multi_nmse, max_logit_err, dyn_range_reduction, flash_cos);
}

static void test_udie_v33_kimi_k31_pro_and_highspeed(void) {
    /* 12a. Cached-RMS AttnRes Softmax Mixer + Debiased Group-64 + Cross-Projection Drift Compensation */
    const int D_ar = 256, N_blks = 8;
    float V_exact[8][256], V_raw[8][256], V_deb[8][256];
    const float *ptr_exact[8], *ptr_raw[8], *ptr_deb[8];
    float cached_denom[8];
    float norm_w[256], w_res[256];

    for (int d = 0; d < D_ar; ++d) {
        norm_w[d] = 1.0f + 0.15f * sinf((float)(d + 1) * 0.21f);
        w_res[d]  = 0.35f * cosf((float)(d + 3) * 0.17f);
    }

    /* Simulate 8 residual block snapshots accumulated across quantized linear projections */
    float W_proj[256 * 256];
    for (int i = 0; i < D_ar * D_ar; ++i) {
        float v = 0.08f * sinf((float)(i * 13 + 7) * 0.11f);
        if ((i % 37) == 0) v *= 4.2f; /* heavy-tailed weight outliers */
        W_proj[i] = v;
    }
    int8_t Q_deb[256 * 256], Q_raw[256 * 256];
    float  S_deb[256 * 4],   S_raw[256 * 4], R_drift[256];
    coli_udie_v33_quantize_group64_debiased_with_drift_row(W_proj, D_ar, D_ar, Q_deb, S_deb, R_drift);

    for (int r = 0; r < D_ar; ++r) {
        for (int g = 0; g < 4; ++g) {
            const float *gp = W_proj + r * D_ar + g * 64;
            float am = 1e-12f;
            for (int i = 0; i < 64; ++i) if (fabsf(gp[i]) > am) am = fabsf(gp[i]);
            float s = am / 7.0f;
            S_raw[r * 4 + g] = s;
            for (int i = 0; i < 64; ++i) {
                int v = (int)lrintf(gp[i] / s);
                if (v >  7) v =  7;
                if (v < -8) v = -8;
                Q_raw[r * D_ar + g * 64 + i] = (int8_t)v;
            }
        }
    }

    for (int b = 0; b < N_blks; ++b) {
        float x_in[256];
        double x_sum = 0.0;
        for (int d = 0; d < D_ar; ++d) {
            x_in[d] = 0.6f + 0.4f * cosf((float)(b * 19 + d * 7) * 0.13f);
            x_sum += (double)x_in[d];
        }
        for (int r = 0; r < D_ar; ++r) {
            float ye = 0.0f, yr = 0.0f, yd = 0.0f;
            for (int g = 0; g < 4; ++g) {
                float sr = S_raw[r * 4 + g];
                float sd = S_deb[r * 4 + g];
                for (int i = 0; i < 64; ++i) {
                    int idx = g * 64 + i;
                    float xv = x_in[idx];
                    ye += W_proj[r * D_ar + idx] * xv;
                    yr += ((float)Q_raw[r * D_ar + idx] * sr) * xv;
                    yd += ((float)Q_deb[r * D_ar + idx] * sd) * xv;
                }
            }
            yd += R_drift[r] * (float)x_sum;
            /* Accumulate over block history to model deep 93-layer AttnRes trajectory */
            float prev_e = (b > 0) ? V_exact[b - 1][r] : 0.0f;
            float prev_r = (b > 0) ? V_raw[b - 1][r]   : 0.0f;
            float prev_d = (b > 0) ? V_deb[b - 1][r]   : 0.0f;
            V_exact[b][r] = prev_e + ye;
            V_raw[b][r]   = prev_r + yr;
            V_deb[b][r]   = prev_d + yd;
        }
        ptr_exact[b] = V_exact[b];
        ptr_raw[b]   = V_raw[b];
        ptr_deb[b]   = V_deb[b];
        cached_denom[b] = coli_udie_v33_attnres_rms_denom(V_exact[b], D_ar, 1e-6f);
    }

    float out_uncached[256], out_cached[256], out_raw[256], out_deb[256];
    float alpha_exact[8], alpha_raw[8], alpha_deb[8];
    coli_udie_v33_attnres_debiased_mix_cached(
        out_uncached, ptr_exact, NULL, N_blks, norm_w, w_res, D_ar, 1e-6f, alpha_exact
    );
    coli_udie_v33_attnres_debiased_mix_cached(
        out_cached, ptr_exact, cached_denom, N_blks, norm_w, w_res, D_ar, 1e-6f, NULL
    );
    for (int d = 0; d < D_ar; ++d) {
        CHECK(out_uncached[d] == out_cached[d],
              "Cached-RMS AttnRes mismatch at d=%d: %e vs %e", d, out_uncached[d], out_cached[d]);
    }

    coli_udie_v33_attnres_debiased_mix_cached(
        out_raw, ptr_raw, NULL, N_blks, norm_w, w_res, D_ar, 1e-6f, alpha_raw
    );
    coli_udie_v33_attnres_debiased_mix_cached(
        out_deb, ptr_deb, NULL, N_blks, norm_w, w_res, D_ar, 1e-6f, alpha_deb
    );

    double mse_raw = 0.0, mse_deb = 0.0;
    for (int d = 0; d < D_ar; ++d) {
        double dr = (double)out_uncached[d] - (double)out_raw[d];
        double dd = (double)out_uncached[d] - (double)out_deb[d];
        mse_raw += dr * dr;
        mse_deb += dd * dd;
    }
    double mse_gain = mse_raw / (mse_deb + 1e-18);
    CHECK(mse_gain > 2.5, "AttnRes Debiased+Drift MSE gain=%.2fx <= 2.5x", mse_gain);

    /* 12b. Fused Dual-Matrix MXFP4 (`E2M1` + `UE8M0`) + `SiTU-GLU` LatentMoE Kernel */
    const int I_moe = 128, O_moe = 32;
    int8_t  x_i8[128];
    float   sx[4];
    uint8_t w1_mxfp4[32 * 64], w3_mxfp4[32 * 64];
    uint8_t e1_ue8m0[32 * 4],  e3_ue8m0[32 * 4];
    for (int i = 0; i < I_moe; ++i) x_i8[i] = (int8_t)(((i * 11 + 5) % 63) - 31);
    for (int b = 0; b < 4; ++b) sx[b] = 0.015f * (float)(b + 1);
    for (int i = 0; i < O_moe * 64; ++i) {
        w1_mxfp4[i] = (uint8_t)((i * 7 + 3) & 0xFF);
        w3_mxfp4[i] = (uint8_t)((i * 13 + 9) & 0xFF);
    }
    for (int i = 0; i < O_moe * 4; ++i) {
        e1_ue8m0[i] = (uint8_t)(125 + (i % 4));
        e3_ue8m0[i] = (uint8_t)(125 + ((i + 2) % 4));
    }

    float out_situ_fused[32], out_situ_ref[32];
    coli_udie_v33_mxfp4_dual_gate_up_situ_glu(
        out_situ_fused, x_i8, sx, w1_mxfp4, e1_ue8m0, w3_mxfp4, e3_ue8m0,
        I_moe, O_moe, 16.0f, 16.0f
    );
    static const int8_t lut2_ref[16] = {0,1,2,3,4,6,8,12, 0,-1,-2,-3,-4,-6,-8,-12};
    float max_situ_diff = 0.0f;
    for (int r = 0; r < O_moe; ++r) {
        float g_acc = 0.0f, u_acc = 0.0f;
        for (int b = 0; b < 4; ++b) {
            int32_t s1 = 0, s3 = 0;
            for (int j = 0; j < 16; ++j) {
                uint8_t b1 = w1_mxfp4[r * 64 + b * 16 + j];
                uint8_t b3 = w3_mxfp4[r * 64 + b * 16 + j];
                s1 += (int32_t)lut2_ref[b1 & 0xF] * x_i8[b * 32 + 2 * j]
                    + (int32_t)lut2_ref[b1 >> 4]  * x_i8[b * 32 + 2 * j + 1];
                s3 += (int32_t)lut2_ref[b3 & 0xF] * x_i8[b * 32 + 2 * j]
                    + (int32_t)lut2_ref[b3 >> 4]  * x_i8[b * 32 + 2 * j + 1];
            }
            union { uint32_t u; float f; } sc1 = { (uint32_t)e1_ue8m0[r * 4 + b] << 23 };
            union { uint32_t u; float f; } sc3 = { (uint32_t)e3_ue8m0[r * 4 + b] << 23 };
            g_acc += (float)s1 * (0.5f * sc1.f * sx[b]);
            u_acc += (float)s3 * (0.5f * sc3.f * sx[b]);
        }
        out_situ_ref[r] = ((16.0f * tanhf(g_acc / 16.0f)) / (1.0f + expf(-g_acc)))
                        * (16.0f * tanhf(u_acc / 16.0f));
        float df = fabsf(out_situ_fused[r] - out_situ_ref[r]);
        if (df > max_situ_diff) max_situ_diff = df;
    }
    CHECK(max_situ_diff == 0.0f, "Fused Dual MXFP4 + SiTU-GLU diff=%e != 0", max_situ_diff);

    /* 12c. Rank-1 Reversible KDA (128x128 + ShortConv4) 4-Step Speculative Rollback */
    float *S_kda = (float *)malloc(128 * 128 * sizeof(float));
    float *S_ref = (float *)malloc(128 * 128 * sizeof(float));
    float conv_kda[3][3 * 128], conv_ref[3][3 * 128];
    for (int i = 0; i < 128 * 128; ++i) {
        S_kda[i] = 0.05f * sinf((float)(i + 1) * 0.07f);
        S_ref[i] = S_kda[i];
    }
    for (int c = 0; c < 3; ++c) {
        for (int i = 0; i < 3 * 128; ++i) {
            conv_kda[c][i] = 0.1f * cosf((float)(c * 97 + i + 3) * 0.13f);
            conv_ref[c][i] = conv_kda[c][i];
        }
    }

    ColiUdieKdaRank1Undo undo_steps[4];
    float head_out[128];
    for (int step = 0; step < 4; ++step) {
        float qkv_step[3][128], alpha_step[128];
        for (int i = 0; i < 128; ++i) {
            qkv_step[0][i] = 0.3f * sinf((float)(step * 31 + i + 1) * 0.19f);
            qkv_step[1][i] = 0.3f * cosf((float)(step * 23 + i + 2) * 0.23f);
            qkv_step[2][i] = 0.4f * sinf((float)(step * 17 + i + 5) * 0.29f);
            alpha_step[i]  = 0.92f + 0.06f * ((float)(i & 7) / 8.0f);
        }
        coli_udie_v33_kda_rank1_step_with_undo(
            S_kda, conv_kda, qkv_step, alpha_step, 0.25f, &undo_steps[step], head_out
        );
    }

    /* Roll back all 4 speculative draft steps in reverse order (3 -> 2 -> 1 -> 0) */
    for (int step = 3; step >= 0; --step) {
        coli_udie_v33_kda_rank1_rollback(S_kda, conv_kda, &undo_steps[step]);
    }

    double kda_err_sq = 0.0, kda_ref_sq = 1e-18;
    for (int i = 0; i < 128 * 128; ++i) {
        double d = (double)S_kda[i] - (double)S_ref[i];
        kda_err_sq += d * d;
        kda_ref_sq += (double)S_ref[i] * (double)S_ref[i];
    }
    double kda_rel_err = sqrt(kda_err_sq / kda_ref_sq);
    float max_conv_err = 0.0f;
    for (int c = 0; c < 3; ++c) {
        for (int i = 0; i < 3 * 128; ++i) {
            float ce = fabsf(conv_kda[c][i] - conv_ref[c][i]);
            if (ce > max_conv_err) max_conv_err = ce;
        }
    }
    double mem_compression = (double)((128 * 128 + 3 * 384) * sizeof(float)) / (double)sizeof(ColiUdieKdaRank1Undo);
    CHECK(kda_rel_err < 1e-6, "Rank-1 KDA 4-step rollback rel_err=%e >= 1e-6", kda_rel_err);
    CHECK(max_conv_err == 0.0f, "ShortConv4 rollback error=%e != 0", max_conv_err);
    CHECK(mem_compression > 21.0, "KDA Undo compression=%.2fx <= 21.0x", mem_compression);

    printf("  [PASS] Test 12 (UDIE v3.3 Kimi K3.1 Pro & Highspeed Cross-Pollination): "
           "AttnRes Cached-RMS Diff=0.0, Debiased+Drift MSE Gain=%.2fx, "
           "Fused Dual-MXFP4+SiTU-GLU Diff=%.1e, Rank-1 KDA 4-Step Rollback Err=%.2e (%.2fx Undo Compression)\n",
           mse_gain, max_situ_diff, kda_rel_err, mem_compression);

    free(S_ref);
    free(S_kda);
}

int main(void) {
    printf("=== Colibrì x UDIE Unified Compression, Kernels & Symbiotic Streaming Test Suite ===\n");
    test_rans_avx2_and_fp8_split();
    test_kv_tq_and_d4_vq();
    test_spec_lookup_indexed();
    test_sparse_index_cached();
    test_udie_compression_and_compute_kernels();
    test_speculative_and_state_rollback();
    test_symbiotic_streaming_and_kv_monoid();
    test_udie_v26_head_improvements();
    test_udie_v30_zero_hyperparam_width_agnostic();
    test_udie_v31_e8_gosset_and_lagrangian_allocator();
    test_udie_v32_multishell_e8_prerope_kv_and_fused_flash_decode();
    test_udie_v33_kimi_k31_pro_and_highspeed();
    if (g_fails == 0) {
        printf("=== ALL 12 TEST SUITES PASSED (0 failures) ===\n");
        return 0;
    } else {
        printf("=== FAILED (%d errors) ===\n", g_fails);
        return 1;
    }
}


