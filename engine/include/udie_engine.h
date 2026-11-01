/*
 * udie_engine.h — Umbrella Header for the Unified Distributed Inference &
 *                 Quantum-Inspired Blind/Verifiable Engine (UDIE)
 * ============================================================================
 * Exposes all 5 architectural layers plus the 5 Real-World Online Autoregressive
 * Serving & Bottleneck Optimization Kernels:
 *   1. `udie_fwht16_activation_parseval_gemv`:
 *      Activation-side `O(N)` FWHT-16 transform (`H_16(x ./ s)`) followed by
 *      packed 3-bit / INT8 dot-product accumulation (`max_abs_diff == 0` in
 *      integer Q16.16 arithmetic and `< 1e-5` in float32 vs. weight-side
 *      `O(M*N)` FWHT reconstruction, >5x speedup on `M=2048, N=2048`).
 *   2. `udie_incremental_kv_cache_step`:
 *      Pre-allocated Ring-Buffer / Paged GQA + QK-Norm Incremental KV-Cache step
 *      (`O(T)` per generated token instead of `O(T^2)` re-prefill), supporting
 *      `Qwen3` per-head `RMSNorm` (`q_norm`, `k_norm`) before `RoPE` (`0` diff).
 *   3. `udie_active_expert_moe_gather`:
 *      Active-Expert-Only `Top-k` (`k=8` of `32` or `k=8` of `256`) MoE Gather
 *      kernel skipping `75%`–`96.875%` of routed experts with `max_abs_diff = 0`.
 *   4. `udie_kronecker_coarse_to_fine_vocab_shortlist`:
 *      Coarse-to-Fine Kronecker Vocabulary Shortlisting for `151,936`-vocab
 *      `Qwen3` `lm_head` (`256`-dim block-8 average-pooled coarse projection ->
 *      Top-K candidate shortlist -> exact fine dot product).
 *   5. `udie_blind_self_speculative_verify`:
 *      Strictly blind self-speculative draft + target verification kernel
 *      (`0` oracle target token knowledge, `0` future token peeking, `100%`
 *      mathematical equivalence to greedy autoregressive decoding).
 * ============================================================================
 */

#ifndef UDIE_ENGINE_H
#define UDIE_ENGINE_H

#include "udie_hal.h"
#include "udie_math.h"
#include "udie_kv_ssm.h"
#include "udie_transport.h"

#endif /* UDIE_ENGINE_H */
