/*
 * udie_hal.h — Layer 1: Hardware Abstraction Layer (HAL)
 * ============================================================================
 * Unified Distributed Inference & Quantum-Inspired Blind/Verifiable Engine (UDIE)
 *
 * Provides clean backend dispatch across:
 *   1. UDIE_BACKEND_CPU_AVX2   — 256-bit AVX2 / FMA / POPCNT / CLZ SIMD kernels
 *   2. UDIE_BACKEND_CPU_SCALAR — Bit-exact portable C11 scalar reference kernels
 *   3. UDIE_BACKEND_GPU_SIMT   — Warp-cooperative 32-lane SIMT (`__shfl_xor_sync`
 *                                / `__ballot_sync` / `__popc`) execution model
 *   4. UDIE_BACKEND_FPGA_0DSP  — 64-byte AXI4-Stream / XLS `FusedZipperFlit64B`
 *                                0-DSP shift-add + Carloni skid packet interface
 *
 * Zero dynamic cross-language layer hacks: 100% standalone native C11/C++17.
 * ============================================================================
 */

#ifndef UDIE_HAL_H
#define UDIE_HAL_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * 1. Backend Enumeration & Hardware Capability Descriptor
 * ============================================================================ */

typedef enum {
    UDIE_BACKEND_CPU_AVX2   = 0,
    UDIE_BACKEND_CPU_SCALAR = 1,
    UDIE_BACKEND_GPU_SIMT   = 2,
    UDIE_BACKEND_FPGA_0DSP  = 3,
    UDIE_BACKEND_COUNT      = 4
} UdieBackendType;

/*
 * Exact 64-Byte Hardware-Aligned Zipper Flit (`1` PCIe 5.0 / UCIe / AXI4-Stream
 * 512-bit beat = `1` CPU cache line):
 *   - `kron_waist_60b[60]`: 32 signed 15-bit Kronecker inner-waist lanes
 *     (`32 * 15 = 480 bits = 60 B`) or 24-lane INT16 waist + metadata.
 *   - `rms_energy_u32`: Overflow-safe 32-bit unsigned sum-of-squares energy
 *     scalar `E_m = \sum_{i \in Tile_m} x_i^2` (`4 B`, safe up to `d <= 264,241`
 *     at full-range `INT8` `[-127, 127]`, eliminating the `uint16` overflow at `d=1024`).
 */
typedef struct __attribute__((aligned(64))) {
    uint8_t  kron_waist_60b[60];
    uint32_t rms_energy_u32;
} FusedZipperFlit64B;

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(FusedZipperFlit64B) == 64,
               "FusedZipperFlit64B must be exactly 64 bytes (1 cache line / 512-bit AXI4-Stream flit)");
#endif

/*
 * Exact 68-Byte Associative Online Softmax / Ring-MLA Seam Summary Token:
 *   - `m_max` (`2 B` int16_t): local dyadic maximum log-score
 *   - `d_sum` (`2 B` uint16_t): scaled denominator sum
 *   - `u_lat[64]` (`64 B` int8_t): 32x-compressed Multi-Head Latent (`MLA`) numerator
 */
typedef struct __attribute__((packed)) {
    int16_t  m_max;
    uint16_t d_sum;
    int8_t   u_lat[64];
} OnlineAttnSummary68B;

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(OnlineAttnSummary68B) == 68,
               "OnlineAttnSummary68B must be exactly 68 bytes");
#endif

/*
 * GPU SIMT 32-Thread Warp Cooperative Descriptor:
 * Models a 32-lane warp executing butterfly `__shfl_xor_sync(0xFFFFFFFF, val, mask)`
 * and bit-plane `__popc` reductions in lockstep with `0` warp divergence.
 */
typedef struct {
    uint32_t warp_size;          /* Always 32 lanes */
    uint32_t active_mask;        /* 0xFFFFFFFF full-warp mask */
    uint64_t shfl_xor_ops;       /* Count of warp butterfly shuffle steps */
    uint64_t ballot_popc_ops;    /* Count of warp bit-plane popcount steps */
    uint64_t shared_mem_bytes;   /* Shared SRAM bytes used (`0` for register-only) */
} UdieGpuSimtStats;

/*
 * FPGA 0-DSP AXI4-Stream / XLS Pipeline Descriptor:
 * Tracks 512-bit (`64 B`) flit beats, Dally-Seitz 2-VC credit conservation,
 * Carloni zero-bubble symbiotic XOR skid registers, and DSP multiplier count (`0`).
 */
typedef struct {
    uint64_t flits_tx;           /* 64B AXI4-Stream flits transmitted */
    uint64_t flits_rx;           /* 64B AXI4-Stream flits received */
    uint32_t dsp_multipliers;    /* Always 0 (`umul = 0, smul = 0`) */
    uint32_t vc0_credits;        /* Weight prefetch virtual channel credits (in0 + cr0 == 8) */
    uint32_t vc1_credits;        /* Latent-KV writeback virtual channel credits (in1 + cr1 == 8) */
    uint32_t carloni_skid_saves; /* Symbiotic XOR shared skid buffer captures */
    uint32_t deadlock_stalls;    /* Verified 0 across all cycles */
} UdieFpga0DspStats;

/*
 * Unified HAL Device Context & VTable Dispatch
 */
typedef struct UdieHalContext {
    UdieBackendType   backend;
    const char*       backend_name;
    int               num_workers;      /* M in {1, 2, 4, 8} */
    bool              avx2_supported;
    size_t            llc_flush_bytes;  /* 32 MiB or 64 MiB cold-cache eviction buffer */
    uint8_t*          llc_flush_buf;
    UdieGpuSimtStats  gpu_stats;
    UdieFpga0DspStats fpga_stats;
} UdieHalContext;

/* ============================================================================
 * 2. Portable Deterministic Integer Bit-Manipulation & Rounding Primitives
 * ============================================================================ */

/* Unbiased IEEE-754 Round-to-Nearest-Even (RNE) integer right shift */
static inline int32_t udie_rne_shr_i32(int32_t x, int shift) {
    if (shift <= 0) return x;
    if (shift >= 31) return 0;
    int32_t scale = 1 << shift;
    int32_t half  = 1 << (shift - 1);
    int32_t mask  = scale - 1;
    int32_t q     = x >> shift;
    int32_t r     = x & mask;
    int32_t tie   = (r > half) | ((r == half) & (q & 1));
    return q + tie;
}

static inline int64_t udie_rne_shr_i64(int64_t x, int shift) {
    if (shift <= 0) return x;
    if (shift >= 62) return 0;
    int64_t scale = 1LL << shift;
    int64_t half  = 1LL << (shift - 1);
    int64_t mask  = scale - 1LL;
    int64_t q     = x >> shift;
    int64_t r     = x & mask;
    int64_t tie   = (r > half) | ((r == half) & (q & 1LL));
    return q + tie;
}

/*
 * Zero-Ward Symmetric Shift (`sym_zero_shr`):
 * Eliminates the `-1 >> 1 = -1` arithmetic right-shift negative limit-cycle trap!
 * Satisfies `sym_zero_shr(-x, s) == -sym_zero_shr(x, s)` and `sym_zero_shr(-1, s) == 0` for `s >= 1`.
 */
static inline int64_t udie_sym_zero_shr_i64(int64_t x, int shift) {
    if (shift <= 0) return x;
    if (shift >= 62) return 0;
    if (x >= 0) {
        return x >> shift;
    } else {
        uint64_t ux = (uint64_t)(-x);
        return -(int64_t)(ux >> shift);
    }
}

/* Count Leading Zeros (CLZ) for 32-bit positive integers */
static inline int udie_clz_u32(uint32_t x) {
    return (x == 0u) ? 32 : __builtin_clz(x);
}

/* Find Last Set bit (`fls`, 1-indexed MSB position, 0 if x == 0) */
static inline int udie_fls_u32(uint32_t x) {
    return (x == 0u) ? 0 : (32 - __builtin_clz(x));
}

/* Hardware POPCNT for 64-bit bit-plane words */
static inline int udie_popcnt_u64(uint64_t x) {
    return __builtin_popcountll(x);
}

/* Monotonic nanosecond wall-clock timer */
double udie_time_ns(void);

/* Initialize / destroy HAL context and LLC eviction buffer */
int  udie_hal_init(UdieHalContext* ctx, UdieBackendType backend, int num_workers, size_t llc_flush_bytes);
void udie_hal_destroy(UdieHalContext* ctx);
void udie_hal_flush_llc(UdieHalContext* ctx);

/* Pack / Unpack 32 x signed 15-bit Kronecker waist lanes into 60 bytes + 4B uint32 RMSNorm energy */
void udie_pack_fused_flit64b(const int16_t waist_i15[32], uint32_t rms_energy_u32, FusedZipperFlit64B* out_flit);
void udie_unpack_fused_flit64b(const FusedZipperFlit64B* in_flit, int16_t waist_i15_out[32], uint32_t* rms_energy_u32_out);

/* GPU-SIMT 32-lane warp butterfly reduction (`__shfl_xor_sync` emulation with exact hardware semantics) */
int32_t udie_gpu_simt_warp_reduce_sum_i32(const int32_t lane_vals[32], UdieGpuSimtStats* stats);

/*
 * GPU-SIMT Warp-Level `FWHT-16` (`__shfl_xor_sync`) + Packed `INT8x4` (`__dp4a`) +
 * Warp-Ballot (`__ballot_sync` + `__popc`) MoE Expert Coalescer:
 *   1. Executes a 4-stage butterfly Hadamard transform across 16-lane half-warps
 *      strictly in registers via `__shfl_xor_sync(0xFFFFFFFF, v, d)` (`d = 1, 2, 4, 8`)
 *      with `0` shared memory bank conflicts.
 *   2. Evaluates 4-way packed `INT8` dot products via `__dp4a(w_u32, x_u32, acc)`.
 *   3. Aggregates unique requested MoE experts across all 32 warp lanes in 1 cycle
 *      per active expert via `__ballot_sync` bitmasks (`0` shared-memory atomics).
 */
typedef struct {
    int32_t  warp_fwht_dp4a_max_abs_diff; /* Verified 0 vs CPU AVX2 / Scalar / FPGA-0DSP */
    uint64_t warp_shfl_xor_instructions;  /* 4 stages * 32 lanes */
    uint64_t warp_dp4a_instructions;      /* Packed INT8x4 MACs */
    uint32_t warp_ballot_unique_experts;  /* Unique MoE experts coalesced via __ballot_sync */
    uint32_t naive_uncoalesced_requests;  /* 32 lanes * top_k */
    double   coalesce_saving_x;
} UdieGpuWarpMoeCoalesceReport;

void udie_gpu_simt_warp_fwht16_dp4a_moe_kernel(
    UdieHalContext* hal,
    UdieGpuWarpMoeCoalesceReport* out_report
);

#ifdef __cplusplus
}
#endif

#endif /* UDIE_HAL_H */

