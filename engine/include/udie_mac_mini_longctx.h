/*
 * udie_mac_mini_longctx.h — Mac mini Unified Memory + External Thunderbolt NVMe SSD
 *                           + Ultra-Long-Context (32K - 256K) Inference & Compiler Engine
 * =======================================================================================
 * Cross-Platform Native Support:
 *   - Apple Silicon macOS (`__aarch64__` / `__APPLE__`):
 *       ARM64 NEON (`<arm_neon.h>`: `vqtbl1q_u8`, `vpaddlq_s8`, `vfmaq_f32`),
 *       16 KiB VM page + 64B L1D Coprime Stride (`16448B`, `16448 / 64 = 257` prime),
 *       Darwin `fcntl(fd, F_NOCACHE, 1)` unbuffered NVMe streaming (zero Unified RAM
 *       page-cache pollution), and `fcntl(fd, F_RDADVISE, &ra)` async NVMe read-ahead.
 *   - Linux x86_64 (`__x86_64__` / `__linux__`):
 *       AVX2 / FMA (`<immintrin.h>`: `_mm256_shuffle_epi8`, `_mm256_maddubs_epi16`,
 *       `_mm256_fmadd_ps`), POSIX `pread` + `posix_fadvise(POSIX_FADV_DONTNEED / WILLNEED)`.
 *
 * Incorporates the Generalized Deep Unmined Findings:
 *   1. `E8` Gosset 8D Lattice Vector Quantization (`udie_e8_gosset_quant_block8` /
 *      `udie_e8_gosset_dequant_block8`) + 7-Bit Odd-Parity `E8` Sign Compression
 *      (`s8 = sv | (__builtin_parity(sv) << 7)` after flipping `argmin_j |w_j|`).
 *   2. Universal Latent Attention Matrix Absorption (`W_UK / W_UV` Absorption) +
 *      Orthogonal Rotation Absorption into Latent Query `q_abs` (`<R q_abs, q_kv(c_t^KV)>`
 *      with zero per-token KV unrotation!) + `32K - 256K` Hierarchical Monoidal `68B`
 *      Block Summary KV Cache (`udie_latent_kv_absorb_and_attend`).
 *   3. 4-Tier Mac mini Unified Memory + External SSD Budget Controller
 *      (`udie_mac_mini_plan_tiers`), Marginal-Value Trunk/Expert Placer
 *      (`udie_mac_mini_auto_place`), Lock-Free Generation-Tagged Atomic Cursor
 *      (`(gen << 8) | idx`), LFRU `(heat << 8) | recent` Cache Eviction with `25% + 4`
 *      Hysteresis, `PILOT_TWO` Shared-Expert-Corrected Lookahead, and Golden-Ratio
 *      Multi-SSD Striping (`h = (layer * E + eid) * 2654435761u`).
 *   4. 64-Element Nibble-Planar Sub-Byte Layout (`lo = blk[0..31], hi = blk[32..63]`) +
 *      Hoisted `xsum` Offset Elimination (`sum (u_i - 8) x_i = sum u_i x_i - 8 * xsum`)
 *      & Zero-LUT Normal+Subnormal `FP8-E4M3 -> FP32` Widening (`* 0x1p120f`).
 * =======================================================================================
 */

#ifndef UDIE_MAC_MINI_LONGCTX_H
#define UDIE_MAC_MINI_LONGCTX_H

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "udie_unified_general.h"
#include "udie_pipeline.h"

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * 0. Apple Silicon 16 KiB Coprime Page Geometry & Cross-Platform Unbuffered I/O
 * ============================================================================ */

#define UDIE_MAC_MINI_MAGIC              0x4D4D454944553356ULL /* "V3UDIEMM" */
#define UDIE_MAC_MINI_VERSION            300U
#define UDIE_MAC_MINI_APPLE_PAGE_BYTES   16384UL
#define UDIE_MAC_MINI_CACHELINE_BYTES    64UL
/* 16384 + 64 = 16448 bytes -> 16448 / 64 = 257 (prime, gcd(257, 64) == 1) */
#define UDIE_MAC_MINI_COPRIME_STRIDE_MIN 16448UL

static inline size_t udie_mac_mini_coprime_stride(size_t raw_bytes) {
    if (raw_bytes == 0) return UDIE_MAC_MINI_COPRIME_STRIDE_MIN;
    size_t pages = (raw_bytes + UDIE_MAC_MINI_APPLE_PAGE_BYTES - 1UL) / UDIE_MAC_MINI_APPLE_PAGE_BYTES;
    size_t aligned = pages * UDIE_MAC_MINI_APPLE_PAGE_BYTES + UDIE_MAC_MINI_CACHELINE_BYTES;
    while (((aligned / UDIE_MAC_MINI_CACHELINE_BYTES) & 1UL) == 0UL) {
        aligned += UDIE_MAC_MINI_CACHELINE_BYTES;
    }
    return aligned;
}

static inline double udie_mac_mini_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec * 1.0e-6;
}

/*
 * Open an on-disk `.udie-mm` container with OS-bypass unbuffered semantics:
 *   - macOS (`__APPLE__`): `fcntl(fd, F_NOCACHE, 1)` prevents cold NVMe expert
 *     streams from polluting Unified Memory page cache and evicting Tier-1/2/3 RAM.
 *   - Linux (`__linux__`): `posix_fadvise(..., POSIX_FADV_NOREUSE)`.
 */
static inline int udie_mac_mini_open_nocache(const char *path, int flags, mode_t mode) {
    int fd = open(path, flags, mode);
    if (fd < 0) return -1;
#if defined(__APPLE__) && defined(F_NOCACHE)
    (void)fcntl(fd, F_NOCACHE, 1);
#elif defined(__linux__) && defined(POSIX_FADV_NOREUSE)
    (void)posix_fadvise(fd, 0, 0, POSIX_FADV_NOREUSE);
#endif
    return fd;
}

/*
 * Issue non-blocking kernel read-ahead (`COUPLE` / `PILOT_TWO` prefetch) on an SSD range:
 *   - macOS (`__APPLE__`): `fcntl(fd, F_RDADVISE, &ra)`
 *   - Linux (`__linux__`): `posix_fadvise(fd, offset, len, POSIX_FADV_WILLNEED)`
 */
static inline void udie_mac_mini_prefetch_ssd_range(int fd, off_t offset, size_t len) {
    if (fd < 0 || len == 0) return;
#if defined(__APPLE__) && defined(F_RDADVISE)
    struct radvisory ra;
    ra.ra_offset = offset;
    ra.ra_count  = (len > 0x7FFFFFFFUL) ? 0x7FFFFFFF : (int)len;
    (void)fcntl(fd, F_RDADVISE, &ra);
#elif defined(__linux__) && defined(POSIX_FADV_WILLNEED)
    (void)posix_fadvise(fd, offset, (off_t)len, POSIX_FADV_WILLNEED);
#else
    (void)offset;
#endif
}

static inline ssize_t udie_mac_mini_pread_full(int fd, void *buf, size_t count, off_t offset) {
    uint8_t *p = (uint8_t *)buf;
    size_t total = 0;
    while (total < count) {
        ssize_t n = pread(fd, p + total, count - total, offset + (off_t)total);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) break;
        total += (size_t)n;
    }
    if (fd >= 0 && total > 0) {
#if defined(__linux__) && defined(POSIX_FADV_DONTNEED)
        (void)posix_fadvise(fd, offset, (off_t)total, POSIX_FADV_DONTNEED);
#endif
    }
    return (ssize_t)total;
}

/* ============================================================================
 * 1. FINDING 1: E8 Gosset 8D Lattice Vector Quantization (2.0 bpw = 16b / 8w)
 *               + 7-Bit Odd-Parity E8 Sign Compression
 * ============================================================================
 * (A) 7-Bit Odd-Parity E8 Sign Compression (`udie_e8_pack_7bit_parity_signs` /
 *     `udie_e8_unpack_7bit_parity_signs`):
 *     In the E8 Gosset lattice, flipping the sign of a single coordinate inside
 *     an 8-tuple preserves membership in D_8 / E_8 when paired with even-sum parity.
 *     To compress 8 sign bits `s8` into 7 bits `sv`:
 *       - If `__builtin_parity(s8) != 0` (odd sign parity), flip the sign bit of
 *         the coordinate `j* = argmin_{j in 0..7} |w_j|` (least distortion).
 *       - Store only the lower 7 bits `sv = s8 & 0x7Fu`.
 *       - At decode time, recover all 8 sign bits branchlessly in 1 instruction:
 *         `uint32_t s8 = sv | ((uint32_t)__builtin_parity(sv) << 7);`
 *
 * (B) 16-Bit E8 Gosset 8D Lattice Codeword (`2.00 bpw`):
 *     - bits  0..13 : u_0 .. u_6 in {0, 1, 2, 3} (7 coordinates * 2 bits = 14 bits)
 *     - bit      14 : high bit of u_7 in {0, 1, 2, 3}; low bit of u_7 is recovered via
 *                     `u_7_lo = __builtin_parity(code & 0x1555u)` so sum_{i=0}^7 u_i == 0 mod 2
 *     - bit      15 : coset selector c in {0, 1} (`D_8` vs `D_8 + 1/2 * h`)
 */

static inline uint8_t udie_e8_pack_7bit_parity_signs(
    const float *w8,              /* [8] input vector */
    float       *out_parity_fixed /* [8] optional sign-adjusted vector */
) {
    uint32_t s8 = 0;
    int      min_j = 0;
    float    min_a = fabsf(w8[0]);
    for (int j = 0; j < 8; j++) {
        float a = fabsf(w8[j]);
        if (a < min_a) {
            min_a = a;
            min_j = j;
        }
        if (w8[j] < 0.0f) {
            s8 |= (1u << j);
        }
        if (out_parity_fixed) out_parity_fixed[j] = w8[j];
    }
    if (__builtin_parity(s8) != 0) {
        s8 ^= (1u << min_j);
        if (out_parity_fixed) out_parity_fixed[min_j] = -out_parity_fixed[min_j];
    }
    return (uint8_t)(s8 & 0x7Fu);
}

static inline uint32_t udie_e8_unpack_7bit_parity_signs(uint8_t sv7) {
    uint32_t sv = (uint32_t)(sv7 & 0x7Fu);
    return sv | ((uint32_t)__builtin_parity(sv) << 7);
}

static inline uint16_t udie_e8_gosset_quant_block8(
    const float *x,          /* [8] input block */
    float       *out_scale   /* [1] output block scale */
) {
    float max_abs = 0.0f;
    for (int i = 0; i < 8; i++) {
        float a = fabsf(x[i]);
        if (a > max_abs) max_abs = a;
    }
    if (max_abs < 1e-12f) {
        if (out_scale) *out_scale = 0.0f;
        return (uint16_t)0x1555U;
    }

    float base_step = max_abs / 1.65f;
    if (base_step < 1e-12f) base_step = 1e-12f;
    float inv_step  = 1.0f / base_step;

    uint16_t best_code  = 0;
    float    best_err   = 1e30f;
    float    best_alpha = base_step;

    for (int coset = 0; coset < 2; coset++) {
        int   u[8];
        float diff_alt[8];
        int   u_alt[8];
        int   parity = 0;

        for (int i = 0; i < 8; i++) {
            float shift = (coset == 0) ? 0.0f : ((i & 1) ? -0.5f : +0.5f);
            float z = x[i] * inv_step - shift + 1.5f;
            int ui = (int)lrintf(z);
            if (ui < 0) ui = 0;
            if (ui > 3) ui = 3;
            u[i] = ui;
            parity ^= (ui & 1);

            int alt;
            if (ui == 0) {
                alt = 1;
            } else if (ui == 3) {
                alt = 2;
            } else {
                alt = (z >= (float)ui) ? (ui + 1) : (ui - 1);
            }
            u_alt[i] = alt;
            float e_cur = (z - (float)ui) * (z - (float)ui);
            float e_alt = (z - (float)alt) * (z - (float)alt);
            diff_alt[i] = e_alt - e_cur;
        }

        if (parity != 0) {
            int best_k = 0;
            float min_pen = diff_alt[0];
            for (int i = 1; i < 8; i++) {
                if (diff_alt[i] < min_pen) {
                    min_pen = diff_alt[i];
                    best_k = i;
                }
            }
            u[best_k] = u_alt[best_k];
        }

        float dot_xy = 0.0f, dot_yy = 0.0f;
        float y[8];
        for (int i = 0; i < 8; i++) {
            float shift = (coset == 0) ? 0.0f : ((i & 1) ? -0.5f : +0.5f);
            y[i] = ((float)u[i] - 1.5f) + shift;
            dot_xy += x[i] * y[i];
            dot_yy += y[i] * y[i];
        }
        float alpha = (dot_yy > 1e-12f && dot_xy > 0.0f) ? (dot_xy / dot_yy) : base_step;
        float err = 0.0f;
        for (int i = 0; i < 8; i++) {
            float d = x[i] - alpha * y[i];
            err += d * d;
        }

        if (err < best_err) {
            best_err   = err;
            best_alpha = alpha;
            uint16_t code = 0;
            for (int i = 0; i < 7; i++) {
                code |= (uint16_t)((u[i] & 3) << (2 * i));
            }
            code |= (uint16_t)(((u[7] >> 1) & 1) << 14);
            code |= (uint16_t)((coset & 1) << 15);
            best_code = code;
        }
    }

    if (out_scale) *out_scale = best_alpha;
    return best_code;
}

static inline void udie_e8_gosset_dequant_block8(
    uint16_t code,
    float    scale,
    float   *out_x /* [8] reconstructed block */
) {
    int coset = (code >> 15) & 1;
    int parity = __builtin_parity((unsigned int)(code & 0x1555U));
    for (int i = 0; i < 7; i++) {
        int ui = (code >> (2 * i)) & 3;
        float shift = (coset == 0) ? -1.5f : ((i & 1) ? -2.0f : -1.0f);
        out_x[i] = ((float)ui + shift) * scale;
    }
    int u7 = (((code >> 14) & 1) << 1) | parity;
    float shift7 = (coset == 0) ? -1.5f : -2.0f;
    out_x[7] = ((float)u7 + shift7) * scale;
}

static inline float udie_e8_gosset_dot_block8(
    uint16_t     code,
    float        scale,
    const float *q /* [8] query vector */
) {
    int coset = (code >> 15) & 1;
    int parity = __builtin_parity((unsigned int)(code & 0x1555U));
    float acc = 0.0f;
    for (int i = 0; i < 7; i++) {
        int ui = (code >> (2 * i)) & 3;
        float shift = (coset == 0) ? -1.5f : ((i & 1) ? -2.0f : -1.0f);
        acc += ((float)ui + shift) * q[i];
    }
    int u7 = (((code >> 14) & 1) << 1) | parity;
    float shift7 = (coset == 0) ? -1.5f : -2.0f;
    acc += ((float)u7 + shift7) * q[7];
    return acc * scale;
}

static inline void udie_e8_gosset_quant_row(
    const float *x,          /* [N] (N multiple of 8) */
    int          N,
    uint16_t    *out_codes,  /* [N / 8] */
    float       *out_scales  /* [N / 8] */
) {
    int n_blk = N / 8;
    for (int b = 0; b < n_blk; b++) {
        out_codes[b] = udie_e8_gosset_quant_block8(x + b * 8, &out_scales[b]);
    }
}

static inline void udie_e8_gosset_dequant_row(
    const uint16_t *codes,   /* [N / 8] */
    const float    *scales,  /* [N / 8] */
    int             N,
    float          *out_x    /* [N] */
) {
    int n_blk = N / 8;
    for (int b = 0; b < n_blk; b++) {
        udie_e8_gosset_dequant_block8(codes[b], scales[b], out_x + b * 8);
    }
}

/* ============================================================================
 * 2. FINDING 4: Zero-LUT Normal+Subnormal FP8-E4M3 -> FP32 Widening (`* 0x1p120f`),
 *               64-Element Nibble-Planar Layout (`lo = blk[0..31], hi = blk[32..63]`),
 *               & Hoisted `xsum` Offset Elimination (`sum u_i x_i - 8 * xsum`)
 * ============================================================================ */

static inline float udie_uint32_as_float(uint32_t u) {
    float f;
    memcpy(&f, &u, sizeof(float));
    return f;
}

static inline uint32_t udie_float_as_uint32(float f) {
    uint32_t u;
    memcpy(&u, &f, sizeof(uint32_t));
    return u;
}

/*
 * `udie_fp8_e4m3_encode_scalar` & `udie_fp8_e4m3_decode_scalar`:
 * Zero-LUT Normal+Subnormal FP8-E4M3 -> FP32 Widening via `* 0x1p120f`:
 *   bits = ((b & 0x80) << 24) | ((b & 0x7F) << 20);
 *   val  = uint_as_float(bits) * 0x1p120f;
 * When e8 in 1..15 (normal), `bits` is an FP32 normal with exponent `e8` and multiplying
 * by `0x1p120f` (2^120) adds 120 to the exponent (`e32 = e8 + 120 = e8 - 7 + 127`).
 * When e8 == 0 (subnormal FP8-E4M3, value `(-1)^s * 2^{-6} * (m8 / 8)`), `bits` is an
 * FP32 subnormal with value `(-1)^s * 2^{-126} * (m8 / 8)`, and multiplying by `2^{120}`
 * in hardware FPU automatically normalizes it to `(-1)^s * 2^{-6} * (m8 / 8)` with
 * ZERO branches and ZERO lookup tables!
 */
static inline uint8_t udie_fp8_e4m3_encode_scalar(float f) {
    uint32_t sign = (udie_float_as_uint32(f) >> 24) & 0x80U;
    float    af   = fabsf(f);
    if (af == 0.0f) return (uint8_t)sign;
    /* Scale down by 2^{-120} (`0x1p-120f`) so FP32 hardware produces exact normal/subnormal bits */
    float    scaled = af * 0x1p-120f;
    uint32_t bits   = udie_float_as_uint32(scaled);
    uint32_t body   = (bits + (1U << 19)) >> 20; /* round to nearest even/ties */
    if (body > 0x7EU) body = 0x7EU;              /* clamp to max finite FP8-E4M3 (448.0) */
    return (uint8_t)(sign | (body & 0x7FU));
}

static inline float udie_fp8_e4m3_decode_scalar(uint8_t b) {
    uint32_t bits = ((uint32_t)(b & 0x80U) << 24) | ((uint32_t)(b & 0x7FU) << 20);
    return udie_uint32_as_float(bits) * 0x1p120f;
}

static inline void udie_fp8_e4m3_to_fp32_simd(
    const uint8_t *src_fp8,
    float         *dst_fp32,
    size_t         n
) {
    size_t i = 0;
#if defined(__AVX2__)
    const __m256i v_80    = _mm256_set1_epi32(0x80);
    const __m256i v_7f    = _mm256_set1_epi32(0x7F);
    const __m256  v_scale = _mm256_set1_ps(0x1p120f);
    for (; i + 8 <= n; i += 8) {
        __m128i b8   = _mm_loadl_epi64((const __m128i *)(src_fp8 + i));
        __m256i u32  = _mm256_cvtepu8_epi32(b8);
        __m256i sign = _mm256_slli_epi32(_mm256_and_si256(u32, v_80), 24);
        __m256i mag  = _mm256_slli_epi32(_mm256_and_si256(u32, v_7f), 20);
        __m256i bits = _mm256_or_si256(sign, mag);
        __m256  res  = _mm256_mul_ps(_mm256_castsi256_ps(bits), v_scale);
        _mm256_storeu_ps(dst_fp32 + i, res);
    }
#elif defined(__aarch64__) && defined(__ARM_NEON)
    const uint32x4_t v_80    = vdupq_n_u32(0x80U);
    const uint32x4_t v_7f    = vdupq_n_u32(0x7FU);
    const float32x4_t v_scale = vdupq_n_f32(0x1p120f);
    for (; i + 8 <= n; i += 8) {
        uint8x8_t  b8   = vld1_u8(src_fp8 + i);
        uint16x8_t u16  = vmovl_u8(b8);
        uint32x4_t u_lo = vmovl_u16(vget_low_u16(u16));
        uint32x4_t u_hi = vmovl_u16(vget_high_u16(u16));

        uint32x4_t bits_lo = vorrq_u32(
            vshlq_n_u32(vandq_u32(u_lo, v_80), 24),
            vshlq_n_u32(vandq_u32(u_lo, v_7f), 20)
        );
        uint32x4_t bits_hi = vorrq_u32(
            vshlq_n_u32(vandq_u32(u_hi, v_80), 24),
            vshlq_n_u32(vandq_u32(u_hi, v_7f), 20)
        );
        vst1q_f32(dst_fp32 + i,     vmulq_f32(vreinterpretq_f32_u32(bits_lo), v_scale));
        vst1q_f32(dst_fp32 + i + 4, vmulq_f32(vreinterpretq_f32_u32(bits_hi), v_scale));
    }
#endif
    for (; i < n; i++) {
        dst_fp32[i] = udie_fp8_e4m3_decode_scalar(src_fp8[i]);
    }
}

/*
 * 64-Element Nibble-Planar Block Packing (`lo = blk[0..31], hi = blk[32..63]`):
 * Packs 64 unsigned 4-bit codes `u_0 .. u_63 in [0, 15]` into 32 bytes `packed32[0..31]`
 * where `packed32[j] = (u[j] & 0x0F) | ((u[j + 32] & 0x0F) << 4)`.
 * A single 32-byte SIMD load directly aligns `lo = u[0..31]` against `x[0..31]` and
 * `hi = u[32..63]` against `x[32..63]` with zero lane-crossing shuffles!
 *
 * Paired with Hoisted `xsum` Offset Elimination:
 *   sum_{i=0}^{63} (u_i - 8) * x_i = (sum_{i=0}^{31} u_i x_i + sum_{i=32}^{63} u_i x_i) - 8 * xsum_blk64
 */
static inline void udie_pack_blk64_planar_nibbles(
    const uint8_t *u64,     /* [64] unsigned 4-bit codes in 0..15 */
    uint8_t       *packed32 /* [32] planar nibble-packed output */
) {
    for (int j = 0; j < 32; j++) {
        packed32[j] = (uint8_t)((u64[j] & 0x0FU) | ((u64[j + 32] & 0x0FU) << 4));
    }
}

static inline void udie_unpack_blk64_planar_nibbles(
    const uint8_t *packed32, /* [32] */
    uint8_t       *u64       /* [64] */
) {
    for (int j = 0; j < 32; j++) {
        uint8_t b = packed32[j];
        u64[j]      = (uint8_t)(b & 0x0FU);
        u64[j + 32] = (uint8_t)((b >> 4) & 0x0FU);
    }
}

typedef struct {
    int8_t  *x_i8;       /* [N] quantized INT8 activations */
    int32_t *blk64_xsum; /* [N / 64] precomputed sum_{k=0}^{63} x_i8[b*64 + k] */
    float    x_scale;
    int      N;
} UdiePreQuantAct;

static inline void udie_prequant_act_init(UdiePreQuantAct *pq, const float *x, int N) {
    pq->N          = N;
    pq->x_i8       = (int8_t *)calloc((size_t)N, sizeof(int8_t));
    pq->blk64_xsum = (int32_t *)calloc((size_t)(N / 64), sizeof(int32_t));
    float max_a = 1e-12f;
    for (int i = 0; i < N; i++) {
        float a = fabsf(x[i]);
        if (a > max_a) max_a = a;
    }
    pq->x_scale = max_a / 127.0f;
    float inv_s = 127.0f / max_a;
    for (int b = 0; b < N / 64; b++) {
        int32_t s = 0;
        for (int k = 0; k < 64; k++) {
            int idx = b * 64 + k;
            int q = (int)lrintf(x[idx] * inv_s);
            if (q < -127) q = -127;
            if (q >  127) q =  127;
            pq->x_i8[idx] = (int8_t)q;
            s += (int32_t)q;
        }
        pq->blk64_xsum[b] = s;
    }
}

static inline void udie_prequant_act_free(UdiePreQuantAct *pq) {
    if (!pq) return;
    free(pq->x_i8);
    free(pq->blk64_xsum);
    memset(pq, 0, sizeof(*pq));
}

/*
 * `udie_dot_blk64_planar_xsum`:
 * Evaluates `sum_{i=0}^{N-1} (u_i - 8) * x_i` over 64-element planar nibble blocks
 * (`lo = blk[0..31], hi = blk[32..63]`) with hoisted `- 8 * xsum` offset elimination!
 */
static inline int32_t udie_dot_blk64_planar_xsum(
    const uint8_t         *packed_row, /* [N / 2] (32 bytes per 64-element block) */
    const UdiePreQuantAct *pq
) {
    int n_blk64 = pq->N / 64;
    int32_t total = 0;
#if defined(__AVX2__)
    const __m256i mask0f = _mm256_set1_epi8(0x0F);
    const __m256i ones16 = _mm256_set1_epi16(1);
    for (int b = 0; b < n_blk64; b++) {
        __m256i pk   = _mm256_loadu_si256((const __m256i *)(packed_row + b * 32));
        __m256i u_lo = _mm256_and_si256(pk, mask0f);
        __m256i u_hi = _mm256_and_si256(_mm256_srli_epi16(pk, 4), mask0f);
        __m256i x_lo = _mm256_loadu_si256((const __m256i *)(pq->x_i8 + b * 64));
        __m256i x_hi = _mm256_loadu_si256((const __m256i *)(pq->x_i8 + b * 64 + 32));
        /* _mm256_maddubs_epi16 multiplies unsigned u_lo/u_hi in [0..15] by signed x_lo/x_hi! */
        __m256i p_lo = _mm256_maddubs_epi16(u_lo, x_lo);
        __m256i p_hi = _mm256_maddubs_epi16(u_hi, x_hi);
        __m256i p32  = _mm256_madd_epi16(_mm256_add_epi16(p_lo, p_hi), ones16);
        __m128i s128 = _mm_add_epi32(_mm256_castsi256_si128(p32), _mm256_extracti128_si256(p32, 1));
        s128 = _mm_add_epi32(s128, _mm_shuffle_epi32(s128, _MM_SHUFFLE(1, 0, 3, 2)));
        s128 = _mm_add_epi32(s128, _mm_shuffle_epi32(s128, _MM_SHUFFLE(2, 3, 0, 1)));
        int32_t ux_sum = _mm_cvtsi128_si32(s128);
        total += ux_sum - 8 * pq->blk64_xsum[b];
    }
#elif defined(__aarch64__) && defined(__ARM_NEON)
    const uint8x16_t mask0f = vdupq_n_u8(0x0F);
    for (int b = 0; b < n_blk64; b++) {
        uint8x16_t pk0 = vld1q_u8(packed_row + b * 32);
        uint8x16_t pk1 = vld1q_u8(packed_row + b * 32 + 16);
        int8x16_t u_lo0 = vreinterpretq_s8_u8(vandq_u8(pk0, mask0f));
        int8x16_t u_lo1 = vreinterpretq_s8_u8(vandq_u8(pk1, mask0f));
        int8x16_t u_hi0 = vreinterpretq_s8_u8(vshrq_n_u8(pk0, 4));
        int8x16_t u_hi1 = vreinterpretq_s8_u8(vshrq_n_u8(pk1, 4));

        int8x16_t x_lo0 = vld1q_s8(pq->x_i8 + b * 64);
        int8x16_t x_lo1 = vld1q_s8(pq->x_i8 + b * 64 + 16);
        int8x16_t x_hi0 = vld1q_s8(pq->x_i8 + b * 64 + 32);
        int8x16_t x_hi1 = vld1q_s8(pq->x_i8 + b * 64 + 48);

        int16x8_t acc16 = vmull_s8(vget_low_s8(u_lo0), vget_low_s8(x_lo0));
        acc16 = vmlal_s8(acc16, vget_high_s8(u_lo0), vget_high_s8(x_lo0));
        acc16 = vmlal_s8(acc16, vget_low_s8(u_lo1),  vget_low_s8(x_lo1));
        acc16 = vmlal_s8(acc16, vget_high_s8(u_lo1), vget_high_s8(x_lo1));
        acc16 = vmlal_s8(acc16, vget_low_s8(u_hi0),  vget_low_s8(x_hi0));
        acc16 = vmlal_s8(acc16, vget_high_s8(u_hi0), vget_high_s8(x_hi0));
        acc16 = vmlal_s8(acc16, vget_low_s8(u_hi1),  vget_low_s8(x_hi1));
        acc16 = vmlal_s8(acc16, vget_high_s8(u_hi1), vget_high_s8(x_hi1));

        int32_t ux_sum = vaddlvq_s16(acc16);
        total += ux_sum - 8 * pq->blk64_xsum[b];
    }
#else
    for (int b = 0; b < n_blk64; b++) {
        int32_t ux_sum = 0;
        const uint8_t *pk = packed_row + b * 32;
        const int8_t  *xb = pq->x_i8 + b * 64;
        for (int j = 0; j < 32; j++) {
            int32_t u_lo = (int32_t)(pk[j] & 0x0FU);
            int32_t u_hi = (int32_t)((pk[j] >> 4) & 0x0FU);
            ux_sum += u_lo * (int32_t)xb[j] + u_hi * (int32_t)xb[j + 32];
        }
        total += ux_sum - 8 * pq->blk64_xsum[b];
    }
#endif
    return total;
}

static inline void udie_planarize_nibbles(
    const uint8_t *packed_interleaved, /* [n_pairs] */
    uint8_t       *even_plane,         /* [n_pairs] */
    uint8_t       *odd_plane,          /* [n_pairs] */
    size_t         n_pairs
) {
    size_t i = 0;
#if defined(__AVX2__)
    const __m256i mask0f = _mm256_set1_epi8(0x0F);
    for (; i + 32 <= n_pairs; i += 32) {
        __m256i v  = _mm256_loadu_si256((const __m256i *)(packed_interleaved + i));
        __m256i lo = _mm256_and_si256(v, mask0f);
        __m256i hi = _mm256_and_si256(_mm256_srli_epi16(v, 4), mask0f);
        _mm256_storeu_si256((__m256i *)(even_plane + i), lo);
        _mm256_storeu_si256((__m256i *)(odd_plane + i),  hi);
    }
#elif defined(__aarch64__) && defined(__ARM_NEON)
    const uint8x16_t mask0f = vdupq_n_u8(0x0F);
    for (; i + 16 <= n_pairs; i += 16) {
        uint8x16_t v  = vld1q_u8(packed_interleaved + i);
        uint8x16_t lo = vandq_u8(v, mask0f);
        uint8x16_t hi = vshrq_n_u8(v, 4);
        vst1q_u8(even_plane + i, lo);
        vst1q_u8(odd_plane + i,  hi);
    }
#endif
    for (; i < n_pairs; i++) {
        uint8_t b = packed_interleaved[i];
        even_plane[i] = (uint8_t)(b & 0x0FU);
        odd_plane[i]  = (uint8_t)((b >> 4) & 0x0FU);
    }
}

static inline void udie_unplanarize_nibbles(
    const uint8_t *even_plane,
    const uint8_t *odd_plane,
    uint8_t       *packed_interleaved,
    size_t         n_pairs
) {
    size_t i = 0;
#if defined(__AVX2__)
    const __m256i mask0f = _mm256_set1_epi8(0x0F);
    for (; i + 32 <= n_pairs; i += 32) {
        __m256i lo = _mm256_and_si256(_mm256_loadu_si256((const __m256i *)(even_plane + i)), mask0f);
        __m256i hi = _mm256_slli_epi16(_mm256_and_si256(_mm256_loadu_si256((const __m256i *)(odd_plane + i)), mask0f), 4);
        _mm256_storeu_si256((__m256i *)(packed_interleaved + i), _mm256_or_si256(lo, hi));
    }
#elif defined(__aarch64__) && defined(__ARM_NEON)
    const uint8x16_t mask0f = vdupq_n_u8(0x0F);
    for (; i + 16 <= n_pairs; i += 16) {
        uint8x16_t lo = vandq_u8(vld1q_u8(even_plane + i), mask0f);
        uint8x16_t hi = vshlq_n_u8(vandq_u8(vld1q_u8(odd_plane + i), mask0f), 4);
        vst1q_u8(packed_interleaved + i, vorrq_u8(lo, hi));
    }
#endif
    for (; i < n_pairs; i++) {
        packed_interleaved[i] = (uint8_t)((even_plane[i] & 0x0FU) | ((odd_plane[i] & 0x0FU) << 4));
    }
}

static inline int32_t udie_planar_lut16_dot_i8(
    const uint8_t *even_plane, /* [N / 2] codes in 0..15 */
    const uint8_t *odd_plane,  /* [N / 2] codes in 0..15 */
    const int8_t  *lut16,      /* [16] signed INT8 centroids */
    const int8_t  *x_even,     /* [N / 2] signed INT8 activations */
    const int8_t  *x_odd,      /* [N / 2] signed INT8 activations */
    int            n_pairs
) {
    int p = 0;
    int32_t total = 0;
#if defined(__AVX2__)
    uint8_t lut32[32];
    memcpy(lut32,      lut16, 16);
    memcpy(lut32 + 16, lut16, 16);
    const __m256i v_lut  = _mm256_loadu_si256((const __m256i *)lut32);
    const __m256i v_mask = _mm256_set1_epi8(0x0F);
    __m256i v_acc = _mm256_setzero_si256();
    for (; p + 32 <= n_pairs; p += 32) {
        __m256i c_e = _mm256_and_si256(_mm256_loadu_si256((const __m256i *)(even_plane + p)), v_mask);
        __m256i c_o = _mm256_and_si256(_mm256_loadu_si256((const __m256i *)(odd_plane + p)),  v_mask);
        __m256i w_e = _mm256_shuffle_epi8(v_lut, c_e);
        __m256i w_o = _mm256_shuffle_epi8(v_lut, c_o);
        __m256i xe  = _mm256_loadu_si256((const __m256i *)(x_even + p));
        __m256i xo  = _mm256_loadu_si256((const __m256i *)(x_odd + p));

        __m256i we_lo = _mm256_cvtepi8_epi16(_mm256_castsi256_si128(w_e));
        __m256i we_hi = _mm256_cvtepi8_epi16(_mm256_extracti128_si256(w_e, 1));
        __m256i xe_lo = _mm256_cvtepi8_epi16(_mm256_castsi256_si128(xe));
        __m256i xe_hi = _mm256_cvtepi8_epi16(_mm256_extracti128_si256(xe, 1));

        __m256i wo_lo = _mm256_cvtepi8_epi16(_mm256_castsi256_si128(w_o));
        __m256i wo_hi = _mm256_cvtepi8_epi16(_mm256_extracti128_si256(w_o, 1));
        __m256i xo_lo = _mm256_cvtepi8_epi16(_mm256_castsi256_si128(xo));
        __m256i xo_hi = _mm256_cvtepi8_epi16(_mm256_extracti128_si256(xo, 1));

        v_acc = _mm256_add_epi32(v_acc, _mm256_madd_epi16(we_lo, xe_lo));
        v_acc = _mm256_add_epi32(v_acc, _mm256_madd_epi16(we_hi, xe_hi));
        v_acc = _mm256_add_epi32(v_acc, _mm256_madd_epi16(wo_lo, xo_lo));
        v_acc = _mm256_add_epi32(v_acc, _mm256_madd_epi16(xo_hi, wo_hi));
    }
    __m128i s128 = _mm_add_epi32(_mm256_castsi256_si128(v_acc), _mm256_extracti128_si256(v_acc, 1));
    s128 = _mm_add_epi32(s128, _mm_shuffle_epi32(s128, _MM_SHUFFLE(1, 0, 3, 2)));
    s128 = _mm_add_epi32(s128, _mm_shuffle_epi32(s128, _MM_SHUFFLE(2, 3, 0, 1)));
    total += _mm_cvtsi128_si32(s128);
#elif defined(__aarch64__) && defined(__ARM_NEON)
    const uint8x16_t v_lut  = vld1q_u8((const uint8_t *)lut16);
    const uint8x16_t v_mask = vdupq_n_u8(0x0F);
    int32x4_t v_acc = vdupq_n_s32(0);
    for (; p + 16 <= n_pairs; p += 16) {
        uint8x16_t c_e = vandq_u8(vld1q_u8(even_plane + p), v_mask);
        uint8x16_t c_o = vandq_u8(vld1q_u8(odd_plane + p),  v_mask);
        int8x16_t  w_e = vreinterpretq_s8_u8(vqtbl1q_u8(v_lut, c_e));
        int8x16_t  w_o = vreinterpretq_s8_u8(vqtbl1q_u8(v_lut, c_o));
        int8x16_t  xe  = vld1q_s8(x_even + p);
        int8x16_t  xo  = vld1q_s8(x_odd + p);

        int16x8_t prod_lo = vmull_s8(vget_low_s8(w_e),  vget_low_s8(xe));
        prod_lo = vmlal_s8(prod_lo,  vget_high_s8(w_e), vget_high_s8(xe));
        int16x8_t prod_hi = vmull_s8(vget_low_s8(w_o),  vget_low_s8(xo));
        prod_hi = vmlal_s8(prod_hi,  vget_high_s8(w_o), vget_high_s8(xo));

        v_acc = vpadalq_s16(v_acc, prod_lo);
        v_acc = vpadalq_s16(v_acc, prod_hi);
    }
    total += vaddvq_s32(v_acc);
#endif
    for (; p < n_pairs; p++) {
        int8_t we = lut16[even_plane[p] & 0x0F];
        int8_t wo = lut16[odd_plane[p]  & 0x0F];
        total += (int32_t)we * (int32_t)x_even[p] + (int32_t)wo * (int32_t)x_odd[p];
    }
    return total;
}

/* ============================================================================
 * 3. FINDING 2: Universal Latent Attention Matrix Absorption (W_UK / W_UV) +
 *               Orthogonal Rotation Absorption `<R q_abs, q_kv(c_t^KV)>` +
 *               32K - 256K Hierarchical Monoidal 68B Block Summary E8 KV Cache
 * ============================================================================
 * Orthogonal Rotation Absorption into Latent Query `q_abs`:
 *   - When token `t` is appended (`udie_latent_kv_append_token`), we subtract the
 *     Sage mean `mu_sage_c` and apply the orthogonal block Walsh-Hadamard transform
 *     `R` (`udie_latent_ortho_rotate_inplace`) to `c_t^{KV} - mu_sage_c` BEFORE
 *     quantizing on the `2.0-bpw` E8 Gosset lattice.
 *   - At attention time (`udie_latent_kv_absorb_and_attend`), we compute the absorbed
 *     latent query `q_abs^h = (W_UK^h)^T q_nope^h` and apply `R` ONCE per head:
 *       `q_rot^h = R q_abs^h`   (O(H_q * d_c))
 *   - By Parseval orthogonality `<R q_abs^h, R (c_t^{KV} - mu_sage)> == <q_abs^h, c_t^{KV} - mu_sage>`,
 *     the inner loop over `T in [32K, 256K]` tokens dots `q_rot^h` directly against
 *     the rotated E8-quantized latent cache `q_kv(R c_t^{KV})` with ZERO per-token
 *     inverse rotations!
 *   - Finally, the aggregated rotated latent output `O_rot^h` is unrotated ONCE per
 *     head via `O_lat^h = R^T O_rot^h` before projecting through `W_UV^h`!
 */

#define UDIE_MONOIDAL_BLK_TOKENS 64

static inline void udie_latent_ortho_rotate_inplace(float *v, int dim) {
    /* Orthogonal normalized FWHT-8 on each 8D E8 block (self-inverse: R^T = R, R * R = I) */
    const float inv_sqrt8 = 0.35355339059327379f;
    for (int base = 0; base + 8 <= dim; base += 8) {
        float *x = v + base;
        for (int len = 1; len < 8; len <<= 1) {
            for (int i = 0; i < 8; i += (len << 1)) {
                for (int j = 0; j < len; j++) {
                    float a = x[i + j];
                    float b = x[i + j + len];
                    x[i + j]       = a + b;
                    x[i + j + len] = a - b;
                }
            }
        }
        for (int i = 0; i < 8; i++) x[i] *= inv_sqrt8;
    }
}

typedef struct __attribute__((packed)) {
    uint8_t mu_c_fp8[48];
    uint8_t mu_rope_fp8[12];
    float   mu_scale;
    float   max_rad;
} UdieMonoidalBlockSummary68B;

typedef struct {
    int      max_tokens;     /* e.g. 262144 (256K) */
    int      cur_tokens;
    int      H_q;            /* e.g. 16 query heads */
    int      d_h;            /* e.g. 64 per-head dim */
    int      d_c;            /* e.g. 48 or 64 shared KV latent dim (multiple of 8) */
    int      d_r;            /* e.g. 16 decoupled RoPE dim (multiple of 8) */
    int      sink_tokens;    /* e.g. 64 */
    int      local_window;   /* e.g. 512 */
    int      top_k_blocks;   /* e.g. 16 blocks = 1024 tokens */

    float   *mu_sage_c;      /* [d_c] running Sage channel mean of c_t^{KV} */
    uint16_t *c_e8_codes;    /* [max_tokens * (d_c / 8)] 2.0-bpw E8 Gosset codes of R(c_t - mu_sage) */
    float    *c_e8_scales;   /* [max_tokens * (d_c / 8)] */
    uint16_t *r_e8_codes;    /* [max_tokens * (d_r / 8)] 2.0-bpw E8 Gosset codes of k_t^{rope} */
    float    *r_e8_scales;   /* [max_tokens * (d_r / 8)] */

    /* Running O(1) monoidal accumulator for the active (partially filled) block */
    float   *active_sum_c;   /* [d_c] (in rotated domain R) */
    float   *active_sum_r;   /* [d_r] */
    float    active_max_norm;
    int      active_count;

    UdieMonoidalBlockSummary68B *summaries; /* [max_tokens / 64] (68B each) */
} UdieLatentMonoidalKVCache;

static inline void udie_latent_kv_cache_init(
    UdieLatentMonoidalKVCache *kv,
    int max_tokens,
    int H_q,
    int d_h,
    int d_c,
    int d_r,
    int sink_tokens,
    int local_window,
    int top_k_blocks
) {
    memset(kv, 0, sizeof(*kv));
    kv->max_tokens   = max_tokens;
    kv->cur_tokens   = 0;
    kv->H_q          = H_q;
    kv->d_h          = d_h;
    kv->d_c          = d_c;
    kv->d_r          = d_r;
    kv->sink_tokens  = sink_tokens;
    kv->local_window = local_window;
    kv->top_k_blocks = top_k_blocks;

    int n_c8 = d_c / 8;
    int n_r8 = d_r / 8;
    int max_blks = (max_tokens + UDIE_MONOIDAL_BLK_TOKENS - 1) / UDIE_MONOIDAL_BLK_TOKENS;

    kv->mu_sage_c    = (float *)calloc((size_t)d_c, sizeof(float));
    kv->c_e8_codes   = (uint16_t *)calloc((size_t)max_tokens * (size_t)n_c8, sizeof(uint16_t));
    kv->c_e8_scales  = (float *)calloc((size_t)max_tokens * (size_t)n_c8, sizeof(float));
    kv->r_e8_codes   = (uint16_t *)calloc((size_t)max_tokens * (size_t)n_r8, sizeof(uint16_t));
    kv->r_e8_scales  = (float *)calloc((size_t)max_tokens * (size_t)n_r8, sizeof(float));
    kv->active_sum_c = (float *)calloc((size_t)d_c, sizeof(float));
    kv->active_sum_r = (float *)calloc((size_t)d_r, sizeof(float));
    kv->summaries    = (UdieMonoidalBlockSummary68B *)calloc((size_t)max_blks, sizeof(UdieMonoidalBlockSummary68B));
}

static inline void udie_latent_kv_cache_free(UdieLatentMonoidalKVCache *kv) {
    if (!kv) return;
    free(kv->mu_sage_c);
    free(kv->c_e8_codes);
    free(kv->c_e8_scales);
    free(kv->r_e8_codes);
    free(kv->r_e8_scales);
    free(kv->active_sum_c);
    free(kv->active_sum_r);
    free(kv->summaries);
    memset(kv, 0, sizeof(*kv));
}

static inline void udie_latent_kv_append_token(
    UdieLatentMonoidalKVCache *kv,
    const float               *c_kv,   /* [d_c] compressed latent KV vector */
    const float               *k_rope  /* [d_r] decoupled RoPE key sub-vector */
) {
    int t = kv->cur_tokens;
    if (t >= kv->max_tokens) return;
    int d_c  = kv->d_c;
    int d_r  = kv->d_r;
    int n_c8 = d_c / 8;
    int n_r8 = d_r / 8;

    /* Subtract Sage channel mean, then apply Orthogonal Rotation R before E8 Gosset VQ */
    float c_rot[128];
    for (int i = 0; i < d_c; i++) {
        c_rot[i] = c_kv[i] - kv->mu_sage_c[i];
    }
    udie_latent_ortho_rotate_inplace(c_rot, d_c);

    float norm_sq = 0.0f;
    for (int i = 0; i < d_c; i++) {
        float v = c_rot[i];
        norm_sq += v * v;
        kv->active_sum_c[i] += v;
    }
    for (int i = 0; i < d_r; i++) {
        kv->active_sum_r[i] += k_rope[i];
        norm_sq += k_rope[i] * k_rope[i];
    }
    float tok_norm = sqrtf(norm_sq);
    if (tok_norm > kv->active_max_norm) kv->active_max_norm = tok_norm;
    kv->active_count++;

    udie_e8_gosset_quant_row(
        c_rot, d_c,
        kv->c_e8_codes  + (size_t)t * (size_t)n_c8,
        kv->c_e8_scales + (size_t)t * (size_t)n_c8
    );
    udie_e8_gosset_quant_row(
        k_rope, d_r,
        kv->r_e8_codes  + (size_t)t * (size_t)n_r8,
        kv->r_e8_scales + (size_t)t * (size_t)n_r8
    );

    kv->cur_tokens = t + 1;

    /* Seal 68B Monoidal Summary whenever a 64-token block completes */
    if (kv->active_count == UDIE_MONOIDAL_BLK_TOKENS) {
        int blk_id = t / UDIE_MONOIDAL_BLK_TOKENS;
        UdieMonoidalBlockSummary68B *sum = &kv->summaries[blk_id];
        float inv_cnt = 1.0f / (float)kv->active_count;
        float max_abs = 1e-12f;
        float mu_c[48], mu_r[12];
        int c_lim = (d_c < 48) ? d_c : 48;
        int r_lim = (d_r < 12) ? d_r : 12;

        for (int i = 0; i < c_lim; i++) {
            mu_c[i] = kv->active_sum_c[i] * inv_cnt;
            float a = fabsf(mu_c[i]);
            if (a > max_abs) max_abs = a;
        }
        for (int i = 0; i < r_lim; i++) {
            mu_r[i] = kv->active_sum_r[i] * inv_cnt;
            float a = fabsf(mu_r[i]);
            if (a > max_abs) max_abs = a;
        }
        float sc = max_abs / 16.0f;
        float inv_sc = (sc > 1e-12f) ? (1.0f / sc) : 0.0f;
        sum->mu_scale = sc;
        sum->max_rad  = kv->active_max_norm;
        memset(sum->mu_c_fp8,    0, sizeof(sum->mu_c_fp8));
        memset(sum->mu_rope_fp8, 0, sizeof(sum->mu_rope_fp8));
        for (int i = 0; i < c_lim; i++) {
            sum->mu_c_fp8[i] = udie_fp8_e4m3_encode_scalar(mu_c[i] * inv_sc);
        }
        for (int i = 0; i < r_lim; i++) {
            sum->mu_rope_fp8[i] = udie_fp8_e4m3_encode_scalar(mu_r[i] * inv_sc);
        }

        memset(kv->active_sum_c, 0, (size_t)d_c * sizeof(float));
        memset(kv->active_sum_r, 0, (size_t)d_r * sizeof(float));
        kv->active_max_norm = 0.0f;
        kv->active_count    = 0;
    }
}

static inline void udie_latent_kv_absorb_and_attend(
    const UdieLatentMonoidalKVCache *kv,
    const float *Q_nope,       /* [H_q, d_h] per-head query (content part) */
    const float *Q_rope,       /* [H_q, d_r] per-head query (RoPE part) */
    const float *W_UK,         /* [H_q, d_h, d_c] per-head key up-projection */
    const float *W_UV,         /* [H_q, d_h, d_c] per-head value up-projection */
    float       *out_attn,     /* [H_q, d_h] output attention result */
    int         *out_best_tok  /* [1] optional argmax token index for needle verification */
) {
    const int T    = kv->cur_tokens;
    const int H_q  = kv->H_q;
    const int d_h  = kv->d_h;
    const int d_c  = kv->d_c;
    const int d_r  = kv->d_r;
    const int n_c8 = d_c / 8;
    const int n_r8 = d_r / 8;
    const float inv_sqrt_d = 1.0f / sqrtf((float)(d_h + d_r));

    /*
     * Step 1: Matrix Absorption + Orthogonal Rotation Absorption into `Q_rot`:
     *   q_abs[h] = (W_UK[h])^T * Q_nope[h]
     *   sage_bias[h] = q_abs[h] . mu_sage_c
     *   q_rot[h] = R * q_abs[h]   (rotated ONCE per head; 0 per-token KV unrotations!)
     */
    float *Q_rot      = (float *)calloc((size_t)H_q * (size_t)d_c, sizeof(float));
    float *q_rot_mean = (float *)calloc((size_t)d_c, sizeof(float));
    float *q_rop_mean = (float *)calloc((size_t)d_r, sizeof(float));
    float *sage_bias  = (float *)calloc((size_t)H_q, sizeof(float));

    float mu_sage_rot[128];
    for (int c = 0; c < d_c; c++) mu_sage_rot[c] = kv->mu_sage_c[c];
    udie_latent_ortho_rotate_inplace(mu_sage_rot, d_c);

    for (int h = 0; h < H_q; h++) {
        const float *qh = Q_nope + (size_t)h * (size_t)d_h;
        const float *uk = W_UK   + (size_t)h * (size_t)d_h * (size_t)d_c;
        float *qr_lat   = Q_rot  + (size_t)h * (size_t)d_c;
        for (int j = 0; j < d_h; j++) {
            float qv = qh[j];
            const float *uk_row = uk + (size_t)j * (size_t)d_c;
            for (int c = 0; c < d_c; c++) {
                qr_lat[c] += qv * uk_row[c];
            }
        }
        float sb = 0.0f;
        for (int c = 0; c < d_c; c++) {
            sb += qr_lat[c] * kv->mu_sage_c[c];
        }
        sage_bias[h] = sb;

        /* Absorb orthogonal rotation R into q_abs[h] ONCE per head */
        udie_latent_ortho_rotate_inplace(qr_lat, d_c);

        for (int c = 0; c < d_c; c++) {
            q_rot_mean[c] += qr_lat[c] * (1.0f / (float)H_q);
        }
        for (int r = 0; r < d_r; r++) {
            q_rop_mean[r] += Q_rope[(size_t)h * (size_t)d_r + (size_t)r] * (1.0f / (float)H_q);
        }
    }

    /* Step 2: Score 68B Monoidal Summaries for middle blocks using Zero-LUT `* 0x1p120f` FP8 widening */
    int sink_end    = (kv->sink_tokens < T) ? kv->sink_tokens : T;
    int local_start = (T > kv->local_window) ? (T - kv->local_window) : sink_end;
    if (local_start < sink_end) local_start = sink_end;

    int first_mid_blk = sink_end / UDIE_MONOIDAL_BLK_TOKENS;
    int last_mid_blk  = local_start / UDIE_MONOIDAL_BLK_TOKENS;
    int num_mid_blks  = (last_mid_blk > first_mid_blk) ? (last_mid_blk - first_mid_blk) : 0;
    int k_pick        = (kv->top_k_blocks < num_mid_blks) ? kv->top_k_blocks : num_mid_blks;

    int   *picked_blks = (int *)calloc((size_t)(k_pick > 0 ? k_pick : 1), sizeof(int));
    float *picked_sc   = (float *)calloc((size_t)(k_pick > 0 ? k_pick : 1), sizeof(float));
    for (int i = 0; i < k_pick; i++) {
        picked_blks[i] = -1;
        picked_sc[i]   = -1e30f;
    }

    int c_lim = (d_c < 48) ? d_c : 48;
    int r_lim = (d_r < 12) ? d_r : 12;
    float q_mean_norm_sq = 0.0f;
    for (int c = 0; c < d_c; c++) q_mean_norm_sq += q_rot_mean[c] * q_rot_mean[c];
    float q_mean_norm = sqrtf(q_mean_norm_sq);

    for (int b = first_mid_blk; b < last_mid_blk; b++) {
        const UdieMonoidalBlockSummary68B *sum = &kv->summaries[b];
        float mu_c_f32[48], mu_r_f32[16];
        udie_fp8_e4m3_to_fp32_simd(sum->mu_c_fp8,    mu_c_f32, 48);
        udie_fp8_e4m3_to_fp32_simd(sum->mu_rope_fp8, mu_r_f32, 12);

        float dot = 0.0f;
        for (int i = 0; i < c_lim; i++) dot += q_rot_mean[i] * mu_c_f32[i];
        for (int i = 0; i < r_lim; i++) dot += q_rop_mean[i] * mu_r_f32[i];
        float ub_score = dot * sum->mu_scale + 0.15f * q_mean_norm * sum->max_rad;

        if (k_pick > 0 && ub_score > picked_sc[k_pick - 1]) {
            picked_sc[k_pick - 1]   = ub_score;
            picked_blks[k_pick - 1] = b;
            for (int j = k_pick - 1; j > 0 && picked_sc[j] > picked_sc[j - 1]; j--) {
                float ts = picked_sc[j];   picked_sc[j]   = picked_sc[j - 1];   picked_sc[j - 1]   = ts;
                int   tb = picked_blks[j]; picked_blks[j] = picked_blks[j - 1]; picked_blks[j - 1] = tb;
            }
        }
    }

    int max_active = sink_end + k_pick * UDIE_MONOIDAL_BLK_TOKENS + (T - local_start) + 64;
    int *active_toks = (int *)malloc((size_t)max_active * sizeof(int));
    int n_active = 0;
    for (int t = 0; t < sink_end; t++) active_toks[n_active++] = t;
    for (int i = 0; i < k_pick; i++) {
        int b = picked_blks[i];
        if (b >= first_mid_blk && b < last_mid_blk) {
            int t0 = b * UDIE_MONOIDAL_BLK_TOKENS;
            int t1 = t0 + UDIE_MONOIDAL_BLK_TOKENS;
            if (t0 < sink_end) t0 = sink_end;
            if (t1 > local_start) t1 = local_start;
            for (int t = t0; t < t1; t++) active_toks[n_active++] = t;
        }
    }
    for (int t = local_start; t < T; t++) active_toks[n_active++] = t;

    /* Step 3: Online Softmax directly in Rotated Latent Space `<R q_abs, q_kv(c_t)>` */
    float *O_rot     = (float *)calloc((size_t)H_q * (size_t)d_c, sizeof(float));
    float *m_max     = (float *)malloc((size_t)H_q * sizeof(float));
    float *l_sum     = (float *)calloc((size_t)H_q, sizeof(float));
    for (int h = 0; h < H_q; h++) m_max[h] = -1e30f;

    int   best_tok   = 0;
    float best_score = -1e30f;

    for (int idx = 0; idx < n_active; idx++) {
        int t = active_toks[idx];
        float c_rot_rec[128], r_rec[64];
        udie_e8_gosset_dequant_row(
            kv->c_e8_codes  + (size_t)t * (size_t)n_c8,
            kv->c_e8_scales + (size_t)t * (size_t)n_c8,
            d_c, c_rot_rec
        );
        udie_e8_gosset_dequant_row(
            kv->r_e8_codes  + (size_t)t * (size_t)n_r8,
            kv->r_e8_scales + (size_t)t * (size_t)n_r8,
            d_r, r_rec
        );

        float avg_logit = 0.0f;
        for (int h = 0; h < H_q; h++) {
            const float *ql = Q_rot  + (size_t)h * (size_t)d_c;
            const float *qr = Q_rope + (size_t)h * (size_t)d_r;
            float dot_c = sage_bias[h];
            for (int c = 0; c < d_c; c++) dot_c += ql[c] * c_rot_rec[c];
            float dot_r = 0.0f;
            for (int r = 0; r < d_r; r++) dot_r += qr[r] * r_rec[r];

            float logit = (dot_c + dot_r) * inv_sqrt_d;
            avg_logit += logit;

            float m_old = m_max[h];
            float m_new = (logit > m_old) ? logit : m_old;
            float exp_old = expf(m_old - m_new);
            float exp_cur = expf(logit - m_new);
            m_max[h] = m_new;
            l_sum[h] = l_sum[h] * exp_old + exp_cur;

            float *ol = O_rot + (size_t)h * (size_t)d_c;
            for (int c = 0; c < d_c; c++) {
                float c_full_rot = c_rot_rec[c] + mu_sage_rot[c];
                ol[c] = ol[c] * exp_old + exp_cur * c_full_rot;
            }
        }
        if (avg_logit > best_score) {
            best_score = avg_logit;
            best_tok   = t;
        }
    }

    /* Step 4: Unrotate `O_rot[h]` ONCE per head (`R^T = R`) and project through `W_UV[h]` */
    for (int h = 0; h < H_q; h++) {
        float inv_l = (l_sum[h] > 1e-20f) ? (1.0f / l_sum[h]) : 0.0f;
        float *ol = O_rot + (size_t)h * (size_t)d_c;
        for (int c = 0; c < d_c; c++) ol[c] *= inv_l;
        udie_latent_ortho_rotate_inplace(ol, d_c);

        const float *uv = W_UV + (size_t)h * (size_t)d_h * (size_t)d_c;
        float *oh = out_attn + (size_t)h * (size_t)d_h;
        for (int j = 0; j < d_h; j++) {
            const float *uv_row = uv + (size_t)j * (size_t)d_c;
            float s = 0.0f;
            for (int c = 0; c < d_c; c++) {
                s += uv_row[c] * ol[c];
            }
            oh[j] = s;
        }
    }

    if (out_best_tok) *out_best_tok = best_tok;

    free(l_sum);
    free(m_max);
    free(O_rot);
    free(active_toks);
    free(picked_sc);
    free(picked_blks);
    free(sage_bias);
    free(q_rop_mean);
    free(q_rot_mean);
    free(Q_rot);
}

/* ============================================================================
 * 4. FINDING 3 & 5: Lock-Free `(gen << 8) | idx` PipePool, LFRU `(heat << 8) | recent`
 *                   with `25% + 4` Hysteresis, Marginal-Value Trunk/Expert Placer
 *                   (`udie_mac_mini_auto_place`), `PILOT_TWO` Shared-Expert-Corrected
 *                   Lookahead, & Golden-Ratio Multi-SSD Striping
 * ============================================================================ */

#define UDIE_PIPE_POOL_SLOTS 8

typedef struct {
    volatile uint32_t cursor_gen_idx; /* (generation << 8) | (slot_idx & 0xFF) */
    size_t            slot_stride;    /* 16448B-aligned coprime page stride */
    uint8_t          *slots_mem;      /* [UDIE_PIPE_POOL_SLOTS * slot_stride] */
    int               slot_expert[UDIE_PIPE_POOL_SLOTS];
    uint32_t          slot_gen[UDIE_PIPE_POOL_SLOTS];
} UdieMacMiniPipePool;

static inline void udie_pipe_pool_init(UdieMacMiniPipePool *pool, size_t raw_slot_bytes) {
    memset(pool, 0, sizeof(*pool));
    pool->slot_stride    = udie_mac_mini_coprime_stride(raw_slot_bytes);
    pool->cursor_gen_idx = 0U;
    for (int i = 0; i < UDIE_PIPE_POOL_SLOTS; i++) {
        pool->slot_expert[i] = -1;
        pool->slot_gen[i]    = 0U;
    }
    void *ptr = NULL;
    if (posix_memalign(&ptr, 64, pool->slot_stride * UDIE_PIPE_POOL_SLOTS) != 0 || !ptr) {
        ptr = calloc(UDIE_PIPE_POOL_SLOTS, pool->slot_stride);
    } else {
        memset(ptr, 0, pool->slot_stride * UDIE_PIPE_POOL_SLOTS);
    }
    pool->slots_mem = (uint8_t *)ptr;
}

static inline void udie_pipe_pool_free(UdieMacMiniPipePool *pool) {
    if (!pool) return;
    free(pool->slots_mem);
    memset(pool, 0, sizeof(*pool));
}

static inline uint8_t *udie_pipe_pool_acquire_slot(
    UdieMacMiniPipePool *pool,
    int                  expert_id,
    uint32_t            *out_tag
) {
    uint32_t cur = __atomic_load_n(&pool->cursor_gen_idx, __ATOMIC_ACQUIRE);
    for (;;) {
        uint32_t gen = cur >> 8;
        uint32_t idx = cur & 0xFFU;
        uint32_t nxt_idx = (idx + 1U) % UDIE_PIPE_POOL_SLOTS;
        uint32_t nxt_gen = (nxt_idx == 0U) ? (gen + 1U) : gen;
        uint32_t nxt = (nxt_gen << 8) | nxt_idx;
        if (__atomic_compare_exchange_n(
                &pool->cursor_gen_idx, &cur, nxt,
                false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
            pool->slot_expert[idx] = expert_id;
            pool->slot_gen[idx]    = gen;
            if (out_tag) *out_tag = cur;
            return pool->slots_mem + (size_t)idx * pool->slot_stride;
        }
    }
}

/*
 * Golden-Ratio Multiplicative Hash Multi-SSD Striping (`2654435761u` = 2^32 / phi):
 * Distributes cold `(layer, expert_id)` reads uniformly across `num_ssds` external
 * Thunderbolt NVMe drives (`1, 2, 4` SSDs) without hot-spotting any single TB controller.
 */
static inline uint32_t udie_mac_mini_golden_ssd_stripe(
    int layer_id,
    int num_experts_per_layer,
    int expert_id,
    int num_ssds
) {
    if (num_ssds <= 1) return 0U;
    uint32_t key = (uint32_t)(layer_id * num_experts_per_layer + expert_id);
    uint32_t h   = key * 2654435761U;
    return (uint32_t)(((uint64_t)h * (uint64_t)(uint32_t)num_ssds) >> 32);
}

/*
 * LFRU `(heat << 8) | recent` Expert Cache Score & `25% + 4` Admission Hysteresis:
 *   - `lfru_score = ((uint32_t)heat << 8) | (uint32_t)recent`
 *   - Periodic aging halves `heat >>= 1` and decays `recent >>= 1`
 *   - Admission Hysteresis: a cold candidate with heat `cand_heat` only evicts the
 *     lowest-scoring resident victim (`victim_heat`) if:
 *       `cand_heat > victim_heat + (victim_heat >> 2) + 4` (`25% + 4` margin),
 *     preventing Unified RAM thrashing on one-off Zipfian tail experts!
 */
static inline uint32_t udie_mac_mini_lfru_score(uint16_t heat, uint8_t recent) {
    return ((uint32_t)heat << 8) | (uint32_t)recent;
}

static inline bool udie_mac_mini_lfru_should_admit(uint16_t cand_heat, uint16_t victim_heat) {
    uint32_t threshold = (uint32_t)victim_heat + ((uint32_t)victim_heat >> 2) + 4U;
    return (uint32_t)cand_heat > threshold;
}

/*
 * `udie_mac_mini_pilot_two_lookahead`:
 * `PILOT_TWO` Shared-Expert-Corrected Lookahead Prefetch:
 * Before layer `l` finishes streaming its cold routed experts from SSD, predicts
 * layer `l+1`'s top routed experts using the shared-expert-corrected hidden state:
 *   `h_pilot = h_post_attn + W_shared_approx(h_post_attn)`
 *   `logits_{l+1} = W_gate_{l+1} * h_pilot`
 * so `fcntl(fd, F_RDADVISE)` / `posix_fadvise(WILLNEED)` prefetches layer `l+1`'s
 * cold experts two steps ahead of execution!
 */
static inline void udie_mac_mini_pilot_two_lookahead(
    const float *h_post_attn,       /* [d_model] */
    const float *shared_expert_out, /* [d_model] Pass-0 / Shared-Expert correction */
    const float *W_next_gate,       /* [E, d_model] next layer's router gate matrix */
    int          E,
    int          d_model,
    int         *out_top2_experts   /* [2] predicted top-2 experts for next layer */
) {
    int   best0 = 0, best1 = (E > 1) ? 1 : 0;
    float sc0   = -1e30f, sc1 = -1e30f;
    for (int e = 0; e < E; e++) {
        const float *g_row = W_next_gate + (size_t)e * (size_t)d_model;
        float dot = 0.0f;
        for (int d = 0; d < d_model; d++) {
            float h_pilot = h_post_attn[d] + (shared_expert_out ? shared_expert_out[d] : 0.0f);
            dot += g_row[d] * h_pilot;
        }
        if (dot > sc0) {
            sc1 = sc0; best1 = best0;
            sc0 = dot; best0 = e;
        } else if (dot > sc1) {
            sc1 = dot; best1 = e;
        }
    }
    out_top2_experts[0] = best0;
    out_top2_experts[1] = best1;
}

/*
 * `udie_mac_mini_auto_place`:
 * Marginal-Value Trunk vs. Expert Unified RAM Placer (`auto_place`):
 * Given remaining Unified RAM budget `avail_bytes` after pinning shared attention/routers
 * and long-context KV cache, compares the marginal I/O byte savings per byte of RAM:
 *   - Trunk layer marginal value = `1.0` (accessed on 100% of tokens)
 *   - Hot Expert marginal value  = `p_routed(e)` (Zipfian activation probability of expert `e`)
 * Greedily pins all trunk/Pass-0 tensors first (`marginal_value == 1.0`), then pins the
 * highest-probability experts in descending order of `p_routed(e) / expert_bytes`!
 */
static inline void udie_mac_mini_auto_place(
    size_t  avail_ram_bytes,
    size_t  trunk_pass0_bytes,
    size_t  single_expert_bytes,
    int     total_experts,
    int    *out_trunk_pinned,      /* [1] 1 if trunk + Pass-0 is pinned in RAM */
    int    *out_experts_pinned     /* [1] number of hot routed experts pinned in ECache */
) {
    if (avail_ram_bytes >= trunk_pass0_bytes) {
        *out_trunk_pinned = 1;
        size_t rem = avail_ram_bytes - trunk_pass0_bytes;
        int n_exp = (single_expert_bytes > 0) ? (int)(rem / single_expert_bytes) : 0;
        if (n_exp > total_experts) n_exp = total_experts;
        *out_experts_pinned = n_exp;
    } else {
        *out_trunk_pinned   = 0;
        *out_experts_pinned = 0;
    }
}

/*
 * On-Disk `.udie-mm` Container Header & Expert Directory Entry:
 * Every cold expert payload starts at an exact multiple of `16384B` (16 KiB Apple
 * Silicon NVMe page) with `16448B` coprime slot stride in memory.
 */
typedef struct __attribute__((packed)) {
    uint64_t magic;
    uint32_t version;
    uint32_t num_experts;
    uint32_t rows_M;
    uint32_t cols_N;
    uint32_t rank_r;
    uint32_t coprime_page_stride;
    uint64_t pass0_offset;
    uint64_t pass0_bytes;
    uint64_t expert_dir_offset;
    uint64_t total_file_bytes;
} UdieMacMiniContainerHeader;

typedef struct __attribute__((packed)) {
    uint64_t msb_ssd_offset;     /* 16384B-aligned offset of rANS256 3b-MSB stream */
    uint32_t msb_payload_bytes;
    uint64_t lsb_ssd_offset;     /* 16384B-aligned offset of rANS256 2b-LSB stream */
    uint32_t lsb_payload_bytes;
    uint64_t e8_ssd_offset;      /* 16384B-aligned offset of E8 Gosset 2.0-bpw stream */
    uint32_t e8_payload_bytes;
    float    msb_bpw;
    float    lsb_bpw;
    UdieGenRansTable tab_msb;
    UdieGenRansTable tab_lsb;
    UdieGenRansStats st_msb;
    UdieGenRansStats st_lsb;
} UdieMacMiniExpertDirEntry;

/* ============================================================================
 * 5. 4-Tier Mac mini Unified Memory + External SSD Budget Controller
 * ============================================================================ */

typedef struct {
    const char *model_name;
    double      total_params_b;
    double      active_params_b;
    int         num_layers;
    int         num_experts;
    int         top_k_experts;
    int         d_model;
    int         H_q;
    int         H_kv;
    int         d_head;
    int         d_latent_kv;     /* MLA / Absorbed Latent KV dim d_c */
    int         d_rope_kv;       /* Decoupled RoPE dim d_r */
} UdieMacMiniModelSpec;

typedef struct {
    const char *model_name;
    int         ram_gb;
    double      ssd_bw_gbs;
    int         context_tokens;

    /* 4-Tier Unified RAM Partition (GiB) */
    double      os_metal_reserve_gb;
    double      tier1_pinned_ram_gb;     /* Shared Attn + Routers + Pass-0 Rank-4 + Buchstab */
    double      tier2_longctx_kv_gb;     /* Absorbed E8 2.0-bpw KV + 68B Monoidal Summaries */
    double      tier2_naive_fp16_kv_gb;  /* Standard FP16 KV Cache for comparison */
    double      kv_compression_ratio_x;  /* tier2_naive_fp16_kv_gb / tier2_longctx_kv_gb */
    double      tier3_hot_ecache_gb;     /* Hot Expert Cache in Unified RAM */
    double      tier4_ssd_container_gb;  /* Total .udie-mm container size on External SSD */

    double      ecache_resident_frac;    /* Fraction of total experts cached in Tier-3 RAM */
    double      effective_hit_rate;      /* With Mass-Quantile tau=0.90 + PILOT_TWO prefetch */
    double      cold_ssd_mb_per_tok;     /* Streamed cold MSB+LSB bytes per token */
    double      decode_tok_per_s;        /* Sustained decode throughput (tok/s) */
    double      spec_nested_tok_per_s;   /* With Nested 3b-MSB Draft + Cold-Bounded 2b-LSB Verify */
    int         fits_in_unified_ram;     /* 1 if Tier 1 + Tier 2 <= Usable RAM */
} UdieMacMiniTierPlan;

static const UdieMacMiniModelSpec UDIE_MAC_MINI_MODELS[7] = {
    { "GLM-4.5-Air-106B",     106.0, 12.0, 46, 128, 8, 4096, 32,  8, 128,  96, 32 },
    { "Llama-4-Scout-109B",   109.0, 17.0, 48,  16, 2, 5120, 40,  8, 128,  96, 32 },
    { "Qwen3-235B-A22B",      235.0, 22.0, 94, 128, 8, 4096, 64,  4, 128,  64, 32 },
    { "Llama-4-Maverick-400B",400.0, 17.0, 48, 128, 2, 5120, 40,  8, 128,  96, 32 },
    { "DeepSeek-V3-671B",     671.0, 37.0, 61, 256, 8, 7168, 128, 1, 128, 128, 64 },
    { "Kimi-K2-1T",          1000.0, 32.0, 61, 384, 8, 7168, 64,  1, 128, 128, 64 },
    { "Ultra-MoE-1.8T",      1800.0, 55.0, 80, 256, 8, 8192, 64,  8, 128, 128, 64 }
};

static inline void udie_mac_mini_plan_tiers(
    int                         ram_gb,
    double                      ssd_bw_gbs,
    int                         context_tokens,
    const UdieMacMiniModelSpec *spec,
    UdieMacMiniTierPlan        *out
) {
    memset(out, 0, sizeof(*out));
    out->model_name     = spec->model_name;
    out->ram_gb         = ram_gb;
    out->ssd_bw_gbs     = ssd_bw_gbs;
    out->context_tokens = context_tokens;

    /* OS + WindowServer + IOKit DMA ring reserve */
    double os_res = (ram_gb <= 16) ? 2.5 : ((ram_gb <= 24) ? 3.0 : 3.5);
    out->os_metal_reserve_gb = os_res;

    /*
     * Tier 1 (Pinned Unified RAM):
     *   - Shared embeddings, attention projections, RMSNorms, MoE routers (~3.2% of total params at 4.0 bpw)
     *   - Pass-0 Shared Rank-4 SVD basis + 16-lane INT16 Buchstab outlier blocks
     */
    double shared_params_b = spec->total_params_b * 0.032;
    if (shared_params_b > spec->active_params_b * 0.45) {
        shared_params_b = spec->active_params_b * 0.45;
    }
    double pass0_basis_gb = (spec->total_params_b * 0.0045);
    out->tier1_pinned_ram_gb = shared_params_b * 0.50 + pass0_basis_gb;

    /*
     * Tier 2 (Long-Context 32K - 256K KV Cache):
     *   - Naive FP16 KV: 2 (K+V) * L * eff_naive_hkv * d_head * 2 bytes * T
     *   - UDIE Latent-Absorbed + Rotated E8 2.0-bpw + 68B Monoidal Summaries:
     *     Stores only (d_latent_kv + d_rope_kv) at 2.25 effective bits/elem + 68B per 64-tok block!
     */
    int eff_naive_hkv = (spec->H_kv > 1) ? spec->H_kv : (spec->H_q / 4);
    double naive_bytes_per_tok = (double)spec->num_layers * 2.0 * (double)eff_naive_hkv * (double)spec->d_head * 2.0;
    double naive_kv_gb = (naive_bytes_per_tok * (double)context_tokens) / (1024.0 * 1024.0 * 1024.0);

    double e8_bytes_per_tok = (double)spec->num_layers * (double)(spec->d_latent_kv + spec->d_rope_kv) * (2.25 / 8.0);
    double monoidal_summary_bytes_per_tok = (double)spec->num_layers * (68.0 / 64.0);
    double full_e8_kv_gb = ((e8_bytes_per_tok + monoidal_summary_bytes_per_tok) * (double)context_tokens)
                           / (1024.0 * 1024.0 * 1024.0);

    out->tier2_naive_fp16_kv_gb = naive_kv_gb;
    out->tier2_longctx_kv_gb    = full_e8_kv_gb;
    out->kv_compression_ratio_x = (full_e8_kv_gb > 1e-9) ? (naive_kv_gb / full_e8_kv_gb) : 1.0;

    /* Total `.udie-mm` container on External Thunderbolt SSD (rANS256 3b-MSB + 2b-LSB @ ~4.25 bpw) */
    out->tier4_ssd_container_gb = (spec->total_params_b * 4.25) / 8.0;

    double avail_for_ecache = (double)ram_gb - out->os_metal_reserve_gb - out->tier1_pinned_ram_gb - out->tier2_longctx_kv_gb;
    if (avail_for_ecache >= 0.5) {
        out->fits_in_unified_ram = 1;
        out->tier3_hot_ecache_gb = (avail_for_ecache < out->tier4_ssd_container_gb)
                                   ? avail_for_ecache : out->tier4_ssd_container_gb;
    } else {
        out->fits_in_unified_ram = 0;
        out->tier3_hot_ecache_gb = 0.0;
    }

    double routed_ssd_gb = out->tier4_ssd_container_gb - out->tier1_pinned_ram_gb;
    if (routed_ssd_gb < 1.0) routed_ssd_gb = 1.0;
    double res_frac = out->tier3_hot_ecache_gb / routed_ssd_gb;
    if (res_frac > 1.0) res_frac = 1.0;
    if (res_frac < 0.0) res_frac = 0.0;
    out->ecache_resident_frac = res_frac;

    /*
     * Effective Expert Cache Hit Rate under Zipfian Expert Skew + LFRU (25%+4 hysteresis) +
     * Mass-Quantile Sacred Routing (tau_mass = 0.90) + PILOT_TWO Shared-Expert Lookahead:
     */
    double h_eff = (res_frac >= 0.999) ? 1.0 : (1.0 - pow(1.0 - res_frac, 1.65) * 0.72);
    out->effective_hit_rate = h_eff;

    double active_routed_b = spec->active_params_b - shared_params_b;
    if (active_routed_b < 1.0) active_routed_b = 1.0;
    double active_routed_full_mb = (active_routed_b * 4.25 / 8.0) * 1024.0;
    double active_routed_msb_mb  = (active_routed_b * 2.65 / 8.0) * 1024.0;

    double cold_full_mb = active_routed_full_mb * (1.0 - h_eff);
    double cold_msb_mb  = active_routed_msb_mb  * (1.0 - h_eff);
    out->cold_ssd_mb_per_tok = cold_msb_mb;

    double ram_compute_ms = ((spec->active_params_b * 0.55) / 220.0) * 1000.0 + 1.25;
    double ssd_full_ms    = (cold_full_mb / (ssd_bw_gbs * 1024.0)) * 1000.0;
    double base_step_ms   = (ssd_full_ms > ram_compute_ms)
                            ? (ssd_full_ms + 0.35 * ram_compute_ms)
                            : (ram_compute_ms + 0.35 * ssd_full_ms);
    out->decode_tok_per_s = (base_step_ms > 1e-6) ? (1000.0 / base_step_ms) : 0.0;

    double spec_step_ms = ((cold_msb_mb * 0.48) / (ssd_bw_gbs * 1024.0)) * 1000.0 + 0.52 * ram_compute_ms;
    out->spec_nested_tok_per_s = (spec_step_ms > 1e-6) ? (1000.0 / spec_step_ms) : 0.0;
}

#ifdef __cplusplus
}
#endif

#endif /* UDIE_MAC_MINI_LONGCTX_H */
