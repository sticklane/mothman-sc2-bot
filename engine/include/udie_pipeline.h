#ifndef UDIE_PIPELINE_H
#define UDIE_PIPELINE_H

/*
 * ============================================================================
 * UDIE Composable 5-Layer Architecture & Universal Model-Agnostic Pipeline
 * (`engine/include/udie_pipeline.h` + `engine/include/udie_unified_general.h`)
 * ============================================================================
 * Organizes all compression, kernel, KV/recurrent state, and speculative/streaming
 * techniques into 5 orthogonal, mathematically composable layers where every
 * module is toggleable and free of model-specific overfitting:
 *
 *   [Layer 1: Function-Preserving Gauge & Arbitrary-N Equipartition (AOT)]
 *     Input:  Raw pretrained layer weights (any paired projections W_in, W_out)
 *     Output: Conditioned weights W' such that f_{W'}(x) == f_W(x) identically
 *             before quantization (0.00e+00 error), with bounded outlier kurtosis
 *             for arbitrary dimension N (including non-multiples of 16).
 *     Toggles:
 *       - `enable_rmsnorm_salience_fold`     (Fold col salience into RMSNorm/QK-Norm)
 *       - `enable_fpt_dyadic_swiglu_balance` (Universal bilinear/homogeneous 2^{\pm s_j} gauge)
 *       - `enable_duquant_stride16_perm`     (Arbitrary-N block-strided energy equipartition)
 *
 *   [Layer 2: Universal Residency-Split Additive Decomposition (AOT, Dense E=1 & MoE E>=1)]
 *     Contract: W' = U_basis * V_factors^T + W_buchstab_kurtosis_adaptive + R_dense_coprime_page
 *     Toggles:
 *       - `enable_moe_rank2_subspace`        (Universal Rank-r basis for Dense E=1 & MoE E>=1)
 *       - `enable_kronecker_block_base`      (Local 1x16 / Rank-r Kronecker base)
 *       - `enable_hessian_csr_pass1`         (1st-pass salience-weighted super-outliers)
 *       - `enable_buchstab_simd_pass2`       (Kurtosis-adaptive 16-lane SIMD block outliers)
 *
 *   [Layer 3: Spectral Rotation, Empirical Adaptive Codebook & Universal Entropy Split (AOT)]
 *     Contract: Quantizes R_dense in the rotated Hadamard basis H_B * P_B * R_dense
 *     Toggles:
 *       - `enable_fwht16_spectral_rotation`  (Arbitrary-N Block Walsh-Hadamard transform)
 *       - `codebook_kind`                    (UNIFORM / LLOYD_MAX / D4_2D / MIXED / EMPIRICAL_ADAPTIVE)
 *       - `enable_mmse_and_hessian_row_cal`  (Closed-form block alpha* & row gamma_r*)
 *       - `enable_colibri_rans256_entropy`   (Self-contained 256-stream AVX2 G=16 rANS)
 *       - `enable_colibri_fp8_exp_split`     (Universal FP8-E4M3/E5M2/BF16/FP16 exponent/mantissa split)
 *
 *   [Layer 4: Hardware Kernel, Universal Monoidal Sparse KV & Rank-r Recurrent Rollback (Online)]
 *     Contract: Executes <W_hat, x>, attention, and recurrent state rollback across any architecture
 *     Toggles:
 *       - `enable_activation_side_parseval`  (O(N) Q(x) instead of O(M*N) Q(W))
 *       - `enable_adaptive_batch_maddubs`    (vpshufb LUT for B=1; maddubs INT8 for B>=2)
 *       - `enable_gpu_warp_shfl_lut`         (__shfl_sync register LUT + fused FWHT prologue)
 *       - `enable_incremental_causal_kv`     (O(T) GQA+QKNorm KV + Sage key-mean centering)
 *       - `enable_safe_int8_full_vocab_scan` (INT8 all-V scan + Top-64 FP32 exact rescore)
 *       - `enable_colibri_dsa_kpool_cache`   (Zero-parameter Monoidal Block-Summary Sparse Attention)
 *       - `enable_colibri_tq_d4_kv_codec`    (Empirical-Adaptive D4 2.0-bpw KV codec + Rank-r Recurrent Undo)
 *
 *   [Layer 5: Mass-Quantile Sacred Routing & Cold-I/O-Bounded Speculation (Online Global)]
 *     Contract: Multi-token drafting, mass-quantile MoE routing, & I/O-bounded tree verification
 *     Toggles:
 *       - `enable_active_expert_only_moe`    (Gather only Top-k routed experts for any E>=1, K>=1)
 *       - `enable_single_fwht_moe_combine`   (Linearity of Q^{-1} across Top-k experts)
 *       - `enable_layer_resumed_self_spec`   (Reuse 0..L_draft-1 + confidence margin gate)
 *       - `enable_aot_early_exit_bridge`     (0-calibration Wiener/norm layer bridge)
 *       - `enable_colibri_spec_gate_hash`    (Universal Cold-I/O + Compute Cost-Value Speculative Gate)
 *       - `enable_colibri_sacred_j_cache_route` (Mass-Quantile tau_mass Sacred Cache Routing + PILOT/COUPLE)
 * ============================================================================
 */

#include <stdint.h>
#include "udie_unified_general.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    UDIE_CODEBOOK_UNIFORM_3BIT          = 0,
    UDIE_CODEBOOK_LLOYD_MAX_3BIT        = 1,
    UDIE_CODEBOOK_D4_SPHERICAL_2B       = 2,
    UDIE_CODEBOOK_MIXED_3B_4B_SENSITIVE = 3,
    UDIE_CODEBOOK_EMPIRICAL_ADAPTIVE    = 4
} UdieCodebookKind;

/* Layer 1 Configuration: Universal Gauge & Arbitrary-N Equipartition */
typedef struct {
    int enable_rmsnorm_salience_fold;     /* Fold col_scale into preceding RMSNorm */
    int enable_fpt_dyadic_swiglu_balance; /* Universal bilinear/homogeneous 2^{\pm s_j} gauge */
    int enable_duquant_stride16_perm;     /* Arbitrary-N block-strided energy equipartition */
} UdieLayer1GaugeConfig;

/* Layer 2 Configuration: Universal Residency-Split Additive Decomposition */
typedef struct {
    int enable_moe_rank2_subspace;        /* Universal Rank-r basis (Dense E=1 & MoE E>=1) */
    int enable_kronecker_block_base;      /* Canonical 1x16 Kronecker block mean */
    int enable_hessian_csr_pass1;         /* 1st-pass salience-weighted CSR outliers */
    int enable_buchstab_simd_pass2;       /* Kurtosis-adaptive 16-lane SIMD block outliers */
} UdieLayer2DecompConfig;

/* Layer 3 Configuration: Spectral Rotation, Adaptive Codebook & Universal Float Split */
typedef struct {
    int              enable_fwht16_spectral_rotation; /* Arbitrary-N Block FWHT rotation */
    UdieCodebookKind codebook_kind;                   /* Quantizer codebook selection */
    int              enable_mmse_and_hessian_row_cal; /* Closed-form alpha* & gamma_r* */
    int              enable_colibri_rans256_entropy;  /* 256-stream AVX2 G=16 rANS entropy coding */
    int              enable_colibri_fp8_exp_split;    /* Universal FP8/BF16/FP16 exp/mantissa split */
} UdieLayer3QuantConfig;

/* Layer 4 Configuration: Hardware Kernel, Monoidal Sparse KV & Rank-r Recurrent Undo */
typedef struct {
    int enable_activation_side_parseval;  /* O(N) activation Q(x) via Q^T = Q^{-1} */
    int enable_adaptive_batch_maddubs;    /* B=1 vpshufb LUT vs B>=2 AVX2 maddubs */
    int enable_gpu_warp_shfl_lut;         /* Warp __shfl_sync LUT + fused FWHT prologue */
    int enable_incremental_causal_kv;     /* O(T) incremental KV + Sage key-mean centering */
    int enable_safe_int8_full_vocab_scan; /* Full-vocab INT8 scan + Top-64 FP32 rescore */
    int enable_colibri_dsa_kpool_cache;   /* Zero-parameter Monoidal Block-Summary Sparse Attention */
    int enable_colibri_tq_d4_kv_codec;    /* Adaptive D4 2.0-bpw KV codec + Universal Rank-r Recurrent Undo */
} UdieLayer4RuntimeConfig;

/* Layer 5 Configuration: Mass-Quantile Sacred Routing & Cold-I/O-Bounded Speculation */
typedef struct {
    int enable_active_expert_only_moe;       /* Active-expert-only execution for any E>=1, K>=1 */
    int enable_single_fwht_moe_combine;      /* Single inverse Q^{-1} across Top-k experts */
    int enable_layer_resumed_self_spec;      /* Reuse 0..L_draft-1 + confidence margin gate */
    int enable_aot_early_exit_bridge;        /* 0-calibration AOT Wiener/norm bridge */
    int enable_colibri_spec_gate_hash;       /* Universal Cold-I/O + Compute Cost-Value Speculative Gate */
    int enable_colibri_sacred_j_cache_route; /* Mass-Quantile tau_mass Sacred Cache Routing + PILOT/COUPLE */
} UdieLayer5ControlConfig;

/* Master Composable Pipeline Configuration */
typedef struct {
    const char              *preset_name;
    UdieLayer1GaugeConfig    layer1_gauge;
    UdieLayer2DecompConfig   layer2_decomp;
    UdieLayer3QuantConfig    layer3_quant;
    UdieLayer4RuntimeConfig  layer4_runtime;
    UdieLayer5ControlConfig  layer5_control;
} UdiePipelineConfig;

/* Standard Predefined Pipeline Presets for Clean Ablation Studies */
static inline UdiePipelineConfig udie_pipeline_preset_v1_baseline(void) {
    UdiePipelineConfig cfg = {
        "UDIE_v1_Baseline",
        {0, 0, 0},
        {0, 1, 1, 0},
        {1, UDIE_CODEBOOK_UNIFORM_3BIT, 0, 0, 0},
        {0, 0, 0, 1, 0, 0, 0},
        {0, 0, 0, 0, 0, 0}
    };
    return cfg;
}

static inline UdiePipelineConfig udie_pipeline_preset_v25_wanda(void) {
    UdiePipelineConfig cfg = {
        "UDIE_v2.5_Wanda_Kronecker",
        {1, 0, 0},
        {1, 1, 1, 0},
        {1, UDIE_CODEBOOK_LLOYD_MAX_3BIT, 1, 0, 0},
        {1, 0, 0, 1, 1, 0, 0},
        {1, 1, 1, 0, 0, 0}
    };
    return cfg;
}

static inline UdiePipelineConfig udie_pipeline_preset_v26_full_modular(void) {
    UdiePipelineConfig cfg = {
        "UDIE_v2.6_Full_5Layer_Modular",
        {1, 1, 1},
        {1, 1, 1, 1},
        {1, UDIE_CODEBOOK_MIXED_3B_4B_SENSITIVE, 1, 0, 0},
        {1, 1, 1, 1, 1, 0, 0},
        {1, 1, 1, 1, 0, 0}
    };
    return cfg;
}

static inline UdiePipelineConfig udie_pipeline_preset_v27_colibri_infused(void) {
    UdiePipelineConfig cfg = {
        "UDIE_v2.7_Colibri_Infused_5Layer",
        {1, 1, 1},
        {1, 1, 1, 1},
        {1, UDIE_CODEBOOK_MIXED_3B_4B_SENSITIVE, 1, 1, 1},
        {1, 1, 1, 1, 1, 1, 1},
        {1, 1, 1, 1, 1, 1}
    };
    return cfg;
}

static inline UdiePipelineConfig udie_pipeline_preset_v28_universal_general(void) {
    UdiePipelineConfig cfg = {
        "UDIE_v2.8_Universal_Model_Agnostic_5Layer",
        {1, 1, 1},
        {1, 1, 1, 1},
        {1, UDIE_CODEBOOK_EMPIRICAL_ADAPTIVE, 1, 1, 1},
        {1, 1, 1, 1, 1, 1, 1},
        {1, 1, 1, 1, 1, 1}
    };
    return cfg;
}

static inline UdiePipelineConfig udie_pipeline_preset_v30_unified_rans_residency(void) {
    UdiePipelineConfig cfg = {
        "UDIE_v3.0_Unified_rANS256_Residency_NestedBitPlanes",
        {1, 1, 1},
        {1, 1, 1, 1},
        {1, UDIE_CODEBOOK_EMPIRICAL_ADAPTIVE, 1, 1, 1},
        {1, 1, 1, 1, 1, 1, 1},
        {1, 1, 1, 1, 1, 1}
    };
    return cfg;
}

#ifdef __cplusplus
}
#endif

#endif /* UDIE_PIPELINE_H */
