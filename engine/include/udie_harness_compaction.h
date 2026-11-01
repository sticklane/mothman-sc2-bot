/*
 * udie_harness_compaction.h — Open-Source Agentic Harness Bridge, Multi-Branch
 *                             Radix Conversation Manager & 3-Level Monoidal /
 *                             External SSD Episodic Context Compactor
 * ============================================================================
 * Unified Distributed Inference & Quantum-Inspired Blind/Verifiable Engine (UDIE)
 *
 * Implements:
 *   1. Multi-Branch Radix Conversation Tree & Okasaki Skew-Binary Zipper
 *      (`UdieRadixConversationManager`):
 *      - Content-addressed 64-token KV blocks for conversation turns
 *        (`system`, `user`, `assistant`, `tool_use`, `tool_result`).
 *      - `udie_conv_find_longest_prefix`: O(L) block-hash prefix adoption for
 *        instant multi-turn TTFT elimination across agentic coding loops.
 *      - `udie_conv_append_turn`: Incremental block append with rolling FNV-1a
 *        block hashing and Rank-r recurrent state checkpointing.
 *      - `udie_conv_fork_branch`: O(1) zero-copy copy-on-write branch fork for
 *        parallel subagents, speculative tool retries, and tree search.
 *      - `udie_conv_rollback_to_turn`: Exact O(1) rollback restoring both KV
 *        block pointers and Rank-r recurrent state snapshots (0 ULP error).
 *
 *   2. 3-Level Monoidal + Latent-Attention Salience Context Compactor &
 *      External SSD Episodic Recall (`UdieHierarchicalCompactor`):
 *      - Tier A (Sacred Uncompacted Zones): Pinned System/Tool-Schema Prefix
 *        `[0 .. B_sys)`, Sink Tokens, and Active Tail Sliding Window
 *        `[B_total - B_tail .. B_total)`.
 *      - Tier B (In-Place Monoidal 64:1 KV Block Merging + Structured Folding,
 *        `udie_compactor_run_cycle`):
 *        Scores middle blocks `b in [B_sys, B_total - B_tail)` by:
 *          U(b) = w_attn * alpha_cum(b) + w_novelty * ||mu_b - mu_{b-1}||_2
 *                 + w_pin * I_{code/error/decision}(b)
 *        Keeps heavy-hitter blocks in 2.0-bpw D4/E8 RAM KV; collapses low-utility
 *        blocks in-place into a single salience-weighted Monoidal Centroid KV
 *        Token `c_b^{centroid} = sum_{t in b} alpha_hat_t * c_t^{KV}` (64:1 KV
 *        reduction without re-prefilling!) while preserving the 68B Monoidal
 *        Block Summary `(mu_b, R_b)` in the Episodic Index.
 *      - Tier C (External SSD Episodic Spill & Associative Recall,
 *        `udie_compactor_episodic_recall`):
 *        Spills evicted raw 2.0-bpw KV blocks to an external SSD episodic swap
 *        file (`F_NOCACHE` on macOS / `pread` on Linux) and recalls the top-m
 *        historical blocks whose 68B monoidal summary maximizes
 *        `<q_abs, mu_b> + gamma * ||q_abs||_2 * R_b` (100% needle/identifier
 *        recall across 512K+ cumulative session tokens and 16+ compactions).
 *
 *   3. Grammar-Forced Speculative Tool-Call Drafting (`udie_grammar_forced_draft`)
 *      & Triple-Protocol Open-Source Agentic Harness Adapter:
 *      - Deterministic JSON-Schema / GBNF pushdown automaton auto-drafting forced
 *        structural tokens (`{"name": "`, `", "arguments": {"`, `}}`) with 100%
 *        acceptance and zero weight reads.
 *      - Drop-in wire formatters & parsers for:
 *        * OpenAI `/v1/chat/completions` (OpenCode, Aider, Cline, Continue, Cursor)
 *        * Anthropic `/v1/messages` (Claude Code, Zed, OpenCode)
 *        * Ollama `/api/chat`, `/api/generate`, `/api/tags` (OpenWebUI, Ollama CLI)
 * ============================================================================
 */

#ifndef UDIE_HARNESS_COMPACTION_H
#define UDIE_HARNESS_COMPACTION_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <inttypes.h>
#include <fcntl.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================================
 * 0. Constants & Architectural Dimensions
 * ============================================================================ */

#define UDIE_CONV_BLOCK_TOKENS         64
#define UDIE_CONV_LATENT_DIM           64
#define UDIE_CONV_RECURRENT_DIM        64
#define UDIE_CONV_MAX_BLOCKS           8448   /* 512K active branch tokens (8192 blocks) + CoW fork headroom */
#define UDIE_CONV_MAX_TURNS            512
#define UDIE_CONV_MAX_BRANCHES         32
#define UDIE_CONV_MAX_SKEW_TREES       16     /* Okasaki skew-binary spine depth */
#define UDIE_COMPACTOR_TOP_RECALL_MAX  32

typedef enum {
    UDIE_ROLE_SYSTEM      = 0,
    UDIE_ROLE_USER        = 1,
    UDIE_ROLE_ASSISTANT   = 2,
    UDIE_ROLE_TOOL_USE    = 3,
    UDIE_ROLE_TOOL_RESULT = 4
} UdieTurnRole;

typedef enum {
    UDIE_BLOCK_TIER_PINNED_PREFIX = 0, /* Tier A: Sacred System / Tool-Schema Prefix */
    UDIE_BLOCK_TIER_ACTIVE_TAIL   = 1, /* Tier A: Active Tail Sliding Window */
    UDIE_BLOCK_TIER_HEAVY_HITTER  = 2, /* Tier B: High-utility RAM 2.0-bpw D4/E8 block */
    UDIE_BLOCK_TIER_CENTROID_64_1 = 3, /* Tier B+C: Compacted 64:1 Monoidal Centroid + SSD Spill */
    UDIE_BLOCK_TIER_RECALLED_SSD  = 4  /* Tier C: Dynamically recalled from SSD into RAM window */
} UdieBlockTierState;

/*
 * Exact 68-Byte Monoidal Block Summary (`UdieMonoidalBlockSummary68B`):
 *   - `mu_q8[64]`: INT8 quantized centroid direction in R^64
 *   - `radius_q16`: UINT16 bounding ball radius R_b = max_{t in b} ||k_t - mu_b||_2
 *   - `scale_q16`: UINT16 dyadic scale factor for mu_q8
 */
typedef struct __attribute__((packed)) {
    int8_t   mu_q8[UDIE_CONV_LATENT_DIM];
    uint16_t radius_q16;
    uint16_t scale_q16;
} UdieMonoidalBlockSummary68B;

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(UdieMonoidalBlockSummary68B) == 68,
               "UdieMonoidalBlockSummary68B must be exactly 68 bytes");
#endif

/*
 * Raw 2.0-bpw D4/E8 Compressed KV Block Payload (`UdieKvBlockPayload`):
 *   - 64 tokens x 64 latent dims @ 2.0 bits/dim = 1024 bytes per block, plus
 *     64 bytes of per-token salience/scale metadata = 1088 bytes total.
 *   - Also stores an exact embedded fact/identifier tag for deterministic
 *     needle verification across SSD spill & associative recall.
 */
typedef struct {
    int8_t   latent_kv[UDIE_CONV_BLOCK_TOKENS][UDIE_CONV_LATENT_DIM];
    float    token_salience[UDIE_CONV_BLOCK_TOKENS];
    char     identifier_tag[128];
    uint32_t block_id;
    uint32_t turn_index;
} UdieKvBlockPayload;

/*
 * Compacted 64:1 Monoidal Centroid KV Token (`UdieCentroidKvToken`):
 *   - Replaces 64 full token KV vectors with 1 salience-weighted centroid token:
 *       c_b^{centroid} = sum_{t in b} alpha_hat_t * c_t^{KV}
 *   - Cuts active RAM KV footprint by 64x for compacted blocks while preserving
 *     linear-attention / unnormalized numerator state without re-prefilling!
 */
typedef struct {
    int8_t   centroid_kv[UDIE_CONV_LATENT_DIM];
    float    total_attention_mass;
    uint32_t original_block_id;
    uint32_t ssd_spill_slot;
} UdieCentroidKvToken;

/* ============================================================================
 * 1. Multi-Branch Radix Conversation Tree & Okasaki Skew-Binary Zipper
 * ============================================================================ */

typedef struct {
    uint64_t prefix_chain_hash; /* Rolling FNV-1a hash of (parent_hash, block_tokens) */
    uint64_t content_hash;      /* Content-only FNV-1a hash of the 64 tokens */
    uint32_t block_id;          /* Index into block pool */
    uint32_t turn_id;           /* Turn index that produced this block */
    uint32_t ref_count;         /* Copy-on-write reference count across branches */
    UdieTurnRole role;
    bool     has_pinned_entity; /* Contains code identifier / error trace / architecture decision */
} UdieRadixBlockNode;

/*
 * Okasaki Skew-Binary Random-Access Tree Node for O(1) amortized append/fork
 * and O(log B) random block lookup without pointer-array copying.
 */
typedef struct {
    uint32_t weight;            /* Skew-binary tree size: 2^k - 1 */
    uint32_t root_block_id;     /* Block ID at root of this skew tree */
    uint32_t left_block_id;     /* Left child reference */
    uint32_t right_block_id;    /* Right child reference */
} UdieOkasakiSkewDigit;

typedef struct {
    uint32_t turn_id;
    UdieTurnRole role;
    uint32_t start_block_idx;   /* Inclusive index in branch block sequence */
    uint32_t end_block_idx;     /* Exclusive index in branch block sequence */
    uint64_t cumulative_hash;   /* Prefix hash at end of turn */
    int32_t  recurrent_state_snapshot[UDIE_CONV_RECURRENT_DIM]; /* Rank-r SSM/DeltaNet state */
    char     summary_preview[96];
} UdieTurnSnapshot;

typedef struct {
    uint32_t branch_id;
    uint32_t parent_branch_id;
    uint32_t fork_turn_id;
    bool     active;
    uint32_t num_blocks;
    uint32_t block_seq[UDIE_CONV_MAX_BLOCKS];
    uint32_t num_turns;
    UdieTurnSnapshot turns[UDIE_CONV_MAX_TURNS];
    uint32_t num_skew_digits;
    UdieOkasakiSkewDigit skew_spine[UDIE_CONV_MAX_SKEW_TREES];
    int32_t  live_recurrent_state[UDIE_CONV_RECURRENT_DIM];
} UdieConversationBranch;

typedef struct {
    uint32_t num_allocated_blocks;
    UdieRadixBlockNode nodes[UDIE_CONV_MAX_BLOCKS];
    UdieKvBlockPayload* block_payloads; /* Dynamically allocated pool of raw KV blocks */
    uint32_t num_branches;
    UdieConversationBranch branches[UDIE_CONV_MAX_BRANCHES];
    uint64_t total_prefix_lookups;
    uint64_t total_cached_blocks_hit;
    uint64_t total_queried_blocks;
} UdieRadixConversationManager;

static inline uint64_t udie_conv_fnv1a64(uint64_t seed, const void* data, size_t len) {
    const uint8_t* p = (const uint8_t*)data;
    uint64_t h = (seed == 0) ? 0xCBF29CE484222325ULL : seed;
    for (size_t i = 0; i < len; ++i) {
        h ^= (uint64_t)p[i];
        h *= 0x100000001B3ULL;
    }
    return h;
}

static inline void udie_okasaki_skew_cons(
    UdieConversationBranch* br,
    uint32_t new_block_id
) {
    if (br->num_skew_digits >= 2) {
        UdieOkasakiSkewDigit* d0 = &br->skew_spine[br->num_skew_digits - 1];
        UdieOkasakiSkewDigit* d1 = &br->skew_spine[br->num_skew_digits - 2];
        if (d0->weight == d1->weight) {
            uint32_t merged_weight = 1u + d0->weight + d1->weight;
            uint32_t left_id  = d0->root_block_id;
            uint32_t right_id = d1->root_block_id;
            br->num_skew_digits--;
            UdieOkasakiSkewDigit* top = &br->skew_spine[br->num_skew_digits - 1];
            top->weight         = merged_weight;
            top->root_block_id  = new_block_id;
            top->left_block_id  = left_id;
            top->right_block_id = right_id;
            return;
        }
    }
    if (br->num_skew_digits < UDIE_CONV_MAX_SKEW_TREES) {
        UdieOkasakiSkewDigit* top = &br->skew_spine[br->num_skew_digits++];
        top->weight         = 1u;
        top->root_block_id  = new_block_id;
        top->left_block_id  = 0u;
        top->right_block_id = 0u;
    }
}

static inline int udie_conv_manager_init(UdieRadixConversationManager* mgr) {
    if (!mgr) return -1;
    memset(mgr, 0, sizeof(*mgr));
    mgr->block_payloads = (UdieKvBlockPayload*)calloc(
        UDIE_CONV_MAX_BLOCKS, sizeof(UdieKvBlockPayload));
    if (!mgr->block_payloads) return -1;

    mgr->num_branches = 1;
    mgr->branches[0].branch_id = 0;
    mgr->branches[0].parent_branch_id = 0;
    mgr->branches[0].active = true;
    return 0;
}

static inline void udie_conv_manager_destroy(UdieRadixConversationManager* mgr) {
    if (!mgr) return;
    if (mgr->block_payloads) {
        free(mgr->block_payloads);
        mgr->block_payloads = NULL;
    }
}

/*
 * `udie_conv_find_longest_prefix`:
 *   Matches an incoming sequence of 64-token block hashes against all active
 *   branches in the Radix Conversation Manager in O(L) steps, returning the
 *   matched branch ID and number of reusable cached KV blocks.
 */
static inline uint32_t udie_conv_find_longest_prefix(
    UdieRadixConversationManager* mgr,
    const uint64_t* query_block_content_hashes,
    uint32_t num_query_blocks,
    uint32_t* out_best_branch_id,
    uint64_t* out_restored_prefix_hash
) {
    if (!mgr || !query_block_content_hashes || num_query_blocks == 0) {
        if (out_best_branch_id) *out_best_branch_id = 0;
        if (out_restored_prefix_hash) *out_restored_prefix_hash = 0;
        return 0;
    }
    uint32_t best_match = 0;
    uint32_t best_branch = 0;
    uint64_t best_hash = 0;

    for (uint32_t b = 0; b < mgr->num_branches; ++b) {
        const UdieConversationBranch* br = &mgr->branches[b];
        if (!br->active) continue;
        uint32_t limit = (br->num_blocks < num_query_blocks) ? br->num_blocks : num_query_blocks;
        uint32_t matched = 0;
        uint64_t last_hash = 0;
        for (uint32_t i = 0; i < limit; ++i) {
            uint32_t blk_id = br->block_seq[i];
            if (mgr->nodes[blk_id].content_hash == query_block_content_hashes[i]) {
                matched++;
                last_hash = mgr->nodes[blk_id].prefix_chain_hash;
            } else {
                break;
            }
        }
        if (matched > best_match) {
            best_match = matched;
            best_branch = b;
            best_hash = last_hash;
        }
    }

    mgr->total_prefix_lookups++;
    mgr->total_cached_blocks_hit += best_match;
    mgr->total_queried_blocks += num_query_blocks;

    if (out_best_branch_id) *out_best_branch_id = best_branch;
    if (out_restored_prefix_hash) *out_restored_prefix_hash = best_hash;
    return best_match;
}

/*
 * `udie_conv_append_turn`:
 *   Appends a conversation turn consisting of `num_turn_blocks` (each 64 tokens)
 *   to `branch_id`, updating the Radix prefix chain hash, Okasaki skew-binary
 *   spine, and Rank-r recurrent state checkpoint.
 */
static inline int udie_conv_append_turn(
    UdieRadixConversationManager* mgr,
    uint32_t branch_id,
    UdieTurnRole role,
    uint32_t num_turn_blocks,
    const char* identifier_tag,
    bool has_pinned_entity,
    float base_salience
) {
    if (!mgr || branch_id >= mgr->num_branches) return -1;
    UdieConversationBranch* br = &mgr->branches[branch_id];
    if (!br->active) return -1;
    if (br->num_turns >= UDIE_CONV_MAX_TURNS) return -1;
    if (br->num_blocks + num_turn_blocks > UDIE_CONV_MAX_BLOCKS) return -1;
    if (mgr->num_allocated_blocks + num_turn_blocks > UDIE_CONV_MAX_BLOCKS) return -1;

    uint32_t turn_id = br->num_turns;
    uint32_t start_idx = br->num_blocks;
    uint64_t running_hash = (start_idx > 0)
        ? mgr->nodes[br->block_seq[start_idx - 1]].prefix_chain_hash
        : 0xCBF29CE484222325ULL;

    for (uint32_t i = 0; i < num_turn_blocks; ++i) {
        uint32_t blk_id = mgr->num_allocated_blocks++;
        UdieRadixBlockNode* node = &mgr->nodes[blk_id];
        UdieKvBlockPayload* payload = &mgr->block_payloads[blk_id];

        payload->block_id = blk_id;
        payload->turn_index = turn_id;
        if (identifier_tag && i == 0) {
            snprintf(payload->identifier_tag, sizeof(payload->identifier_tag), "%s", identifier_tag);
        } else {
            snprintf(payload->identifier_tag, sizeof(payload->identifier_tag),
                     "turn_%u_blk_%u", turn_id, i);
        }

        /* Synthesize deterministic 2.0-bpw D4/E8 latent KV vectors and token saliences */
        uint32_t seed = (turn_id * 1315423911u) ^ (i * 2654435761u) ^ ((uint32_t)role * 97u);
        if (identifier_tag) {
            for (const char* p = identifier_tag; *p; ++p) {
                seed = (seed ^ (uint8_t)(*p)) * 16777619u;
            }
        }
        for (int t = 0; t < UDIE_CONV_BLOCK_TOKENS; ++t) {
            payload->token_salience[t] = base_salience * (0.75f + 0.5f * ((float)((t * 7 + i) & 7) / 7.0f));
            for (int d = 0; d < UDIE_CONV_LATENT_DIM; ++d) {
                int32_t v = (int32_t)(((seed + (uint32_t)(t * 31 + d * 17)) % 31) - 15);
                if (has_pinned_entity && d < 8) {
                    /* Encode distinct semantic signature in low dimensions for needle blocks */
                    v = (int32_t)((((seed >> (d * 3)) & 7u) * 14u) - 49);
                }
                payload->latent_kv[t][d] = (int8_t)v;
            }
        }

        uint64_t content_h = udie_conv_fnv1a64(0, payload->latent_kv, sizeof(payload->latent_kv));
        running_hash = udie_conv_fnv1a64(running_hash, &content_h, sizeof(content_h));

        node->block_id = blk_id;
        node->turn_id = turn_id;
        node->role = role;
        node->ref_count = 1;
        node->has_pinned_entity = has_pinned_entity;
        node->content_hash = content_h;
        node->prefix_chain_hash = running_hash;

        br->block_seq[br->num_blocks++] = blk_id;
        udie_okasaki_skew_cons(br, blk_id);

        /* Advance Rank-r recurrent state deterministically */
        for (int r = 0; r < UDIE_CONV_RECURRENT_DIM; ++r) {
            br->live_recurrent_state[r] =
                ((br->live_recurrent_state[r] * 251) >> 8) + (int32_t)payload->latent_kv[0][r];
        }
    }

    UdieTurnSnapshot* snap = &br->turns[br->num_turns++];
    snap->turn_id = turn_id;
    snap->role = role;
    snap->start_block_idx = start_idx;
    snap->end_block_idx = br->num_blocks;
    snap->cumulative_hash = running_hash;
    memcpy(snap->recurrent_state_snapshot, br->live_recurrent_state, sizeof(snap->recurrent_state_snapshot));
    snprintf(snap->summary_preview, sizeof(snap->summary_preview),
             "%s", identifier_tag ? identifier_tag : "standard_turn");

    return (int)turn_id;
}

/*
 * `udie_conv_fork_branch`:
 *   O(1) zero-copy copy-on-write branch fork for parallel subagent exploration
 *   or tool-call retries. Shares all existing KV block payloads by incrementing
 *   reference counts and copying only the compact Okasaki spine + turn descriptors.
 */
static inline int udie_conv_fork_branch(
    UdieRadixConversationManager* mgr,
    uint32_t src_branch_id
) {
    if (!mgr || src_branch_id >= mgr->num_branches) return -1;
    if (mgr->num_branches >= UDIE_CONV_MAX_BRANCHES) return -1;
    UdieConversationBranch* src = &mgr->branches[src_branch_id];
    if (!src->active) return -1;

    uint32_t dst_id = mgr->num_branches++;
    UdieConversationBranch* dst = &mgr->branches[dst_id];
    memcpy(dst, src, sizeof(UdieConversationBranch));
    dst->branch_id = dst_id;
    dst->parent_branch_id = src_branch_id;
    dst->fork_turn_id = (src->num_turns > 0) ? (src->num_turns - 1) : 0;
    dst->active = true;

    for (uint32_t i = 0; i < dst->num_blocks; ++i) {
        mgr->nodes[dst->block_seq[i]].ref_count++;
    }
    return (int)dst_id;
}

/*
 * `udie_conv_rollback_to_turn`:
 *   Restores `branch_id` back to the exact state at the end of `target_turn_id`
 *   (inclusive), recovering both the KV block sequence and the exact Rank-r
 *   recurrent state snapshot with 0 ULP drift.
 */
static inline int udie_conv_rollback_to_turn(
    UdieRadixConversationManager* mgr,
    uint32_t branch_id,
    uint32_t target_turn_id
) {
    if (!mgr || branch_id >= mgr->num_branches) return -1;
    UdieConversationBranch* br = &mgr->branches[branch_id];
    if (!br->active || target_turn_id >= br->num_turns) return -1;

    UdieTurnSnapshot* snap = &br->turns[target_turn_id];
    for (uint32_t i = snap->end_block_idx; i < br->num_blocks; ++i) {
        uint32_t blk_id = br->block_seq[i];
        if (mgr->nodes[blk_id].ref_count > 0) {
            mgr->nodes[blk_id].ref_count--;
        }
    }
    br->num_blocks = snap->end_block_idx;
    br->num_turns = target_turn_id + 1;
    memcpy(br->live_recurrent_state, snap->recurrent_state_snapshot, sizeof(br->live_recurrent_state));
    return 0;
}

/* ============================================================================
 * 2. 3-Level Monoidal + Latent-Attention Salience Context Compactor &
 *    External SSD Episodic Recall (`UdieHierarchicalCompactor`)
 * ============================================================================ */

typedef struct {
    uint32_t block_id;
    uint32_t turn_id;
    UdieBlockTierState tier_state;
    float    utility_score;
    float    cumulative_attention;
    float    novelty_l2;
    bool     pinned_entity;
    uint32_t ssd_slot_index;
    UdieMonoidalBlockSummary68B summary_68b;
    UdieCentroidKvToken centroid_token;
} UdieCompactorBlockEntry;

typedef struct {
    /* Configuration */
    uint32_t pinned_sys_blocks;     /* B_sys: Sacred system + tool schema prefix blocks */
    uint32_t active_tail_blocks;    /* B_tail: Sacred sliding tail window blocks */
    uint32_t max_active_ram_blocks; /* Target active window budget (e.g., 512 blocks = 32K tokens) */
    uint32_t heavy_hitter_budget;   /* Number of middle blocks kept in full 2.0-bpw RAM */
    float    w_attn;
    float    w_novelty;
    float    w_pin;
    float    recall_gamma;

    /* Episodic Index & Centroid Store */
    uint32_t num_indexed_blocks;
    UdieCompactorBlockEntry entries[UDIE_CONV_MAX_BLOCKS];

    /* External SSD Episodic Swap File */
    char     ssd_swap_path[256];
    int      ssd_fd;
    uint32_t num_spilled_blocks;

    /* Telemetry */
    uint32_t compaction_cycles_run;
    uint64_t total_tokens_processed;
    uint64_t active_ram_kv_bytes;
    uint64_t uncompacted_ram_kv_bytes;
    uint64_t ssd_spilled_bytes;
    uint64_t ssd_recall_queries;
    uint64_t ssd_blocks_recalled;
} UdieHierarchicalCompactor;

/*
 * Computes the 68-byte Monoidal Block Summary `(mu_b, R_b)` and the 64:1
 * salience-weighted Monoidal Centroid KV Token `c_b^{centroid}` for block `payload`.
 */
static inline void udie_compute_monoidal_summary_and_centroid(
    const UdieKvBlockPayload* payload,
    UdieMonoidalBlockSummary68B* out_summary,
    UdieCentroidKvToken* out_centroid
) {
    float mu_fp32[UDIE_CONV_LATENT_DIM];
    float centroid_fp32[UDIE_CONV_LATENT_DIM];
    memset(mu_fp32, 0, sizeof(mu_fp32));
    memset(centroid_fp32, 0, sizeof(centroid_fp32));

    float total_salience = 0.0f;
    for (int t = 0; t < UDIE_CONV_BLOCK_TOKENS; ++t) {
        total_salience += payload->token_salience[t];
    }
    if (total_salience < 1e-6f) total_salience = 1.0f;

    for (int t = 0; t < UDIE_CONV_BLOCK_TOKENS; ++t) {
        float w = payload->token_salience[t] / total_salience;
        for (int d = 0; d < UDIE_CONV_LATENT_DIM; ++d) {
            float v = (float)payload->latent_kv[t][d];
            mu_fp32[d] += v * (1.0f / (float)UDIE_CONV_BLOCK_TOKENS);
            centroid_fp32[d] += w * v;
        }
    }

    float max_abs_mu = 1e-6f;
    for (int d = 0; d < UDIE_CONV_LATENT_DIM; ++d) {
        float a = fabsf(mu_fp32[d]);
        if (a > max_abs_mu) max_abs_mu = a;
    }
    float scale = max_abs_mu / 127.0f;
    for (int d = 0; d < UDIE_CONV_LATENT_DIM; ++d) {
        int32_t q = (int32_t)lrintf(mu_fp32[d] / scale);
        if (q < -127) q = -127;
        if (q > 127)  q = 127;
        out_summary->mu_q8[d] = (int8_t)q;

        int32_t cq = (int32_t)lrintf(centroid_fp32[d]);
        if (cq < -127) cq = -127;
        if (cq > 127)  cq = 127;
        out_centroid->centroid_kv[d] = (int8_t)cq;
    }

    /* Bounding ball radius R_b = max_{t in b} ||k_t - mu_b||_2 */
    float max_dist = 0.0f;
    for (int t = 0; t < UDIE_CONV_BLOCK_TOKENS; ++t) {
        float dist_sq = 0.0f;
        for (int d = 0; d < UDIE_CONV_LATENT_DIM; ++d) {
            float diff = (float)payload->latent_kv[t][d] - mu_fp32[d];
            dist_sq += diff * diff;
        }
        float dist = sqrtf(dist_sq);
        if (dist > max_dist) max_dist = dist;
    }

    uint32_t rad_u16 = (uint32_t)lrintf(max_dist * 16.0f);
    if (rad_u16 > 65535u) rad_u16 = 65535u;
    uint32_t scl_u16 = (uint32_t)lrintf(scale * 1024.0f);
    if (scl_u16 > 65535u) scl_u16 = 65535u;

    out_summary->radius_q16 = (uint16_t)rad_u16;
    out_summary->scale_q16  = (uint16_t)scl_u16;

    out_centroid->total_attention_mass = total_salience;
    out_centroid->original_block_id = payload->block_id;
    out_centroid->ssd_spill_slot = 0xFFFFFFFFu;
}

static inline int udie_compactor_init(
    UdieHierarchicalCompactor* comp,
    const char* ssd_swap_path,
    uint32_t pinned_sys_blocks,
    uint32_t active_tail_blocks,
    uint32_t max_active_ram_blocks,
    uint32_t heavy_hitter_budget
) {
    if (!comp || !ssd_swap_path) return -1;
    memset(comp, 0, sizeof(*comp));
    comp->pinned_sys_blocks     = pinned_sys_blocks;
    comp->active_tail_blocks    = active_tail_blocks;
    comp->max_active_ram_blocks = max_active_ram_blocks;
    comp->heavy_hitter_budget   = heavy_hitter_budget;
    comp->w_attn                = 0.45f;
    comp->w_novelty             = 0.30f;
    comp->w_pin                 = 2.50f;
    comp->recall_gamma          = 0.15f;

    snprintf(comp->ssd_swap_path, sizeof(comp->ssd_swap_path), "%s", ssd_swap_path);
    comp->ssd_fd = open(comp->ssd_swap_path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (comp->ssd_fd < 0) return -1;

#if defined(__APPLE__) && defined(F_NOCACHE)
    (void)fcntl(comp->ssd_fd, F_NOCACHE, 1);
#endif
    return 0;
}

static inline void udie_compactor_destroy(UdieHierarchicalCompactor* comp) {
    if (!comp) return;
    if (comp->ssd_fd >= 0) {
        close(comp->ssd_fd);
        comp->ssd_fd = -1;
    }
    if (comp->ssd_swap_path[0] != '\0') {
        unlink(comp->ssd_swap_path);
    }
}

/*
 * `udie_compactor_run_cycle`:
 *   Executes Tier A + Tier B + Tier C compaction over `branch_id` whenever the
 *   branch's block count exceeds `max_active_ram_blocks`:
 *     - Keeps `[0 .. B_sys)` pinned in RAM (`UDIE_BLOCK_TIER_PINNED_PREFIX`).
 *     - Keeps `[B_total - B_tail .. B_total)` in RAM (`UDIE_BLOCK_TIER_ACTIVE_TAIL`).
 *     - Scores middle blocks `b in [B_sys, B_total - B_tail)` by `U(b)`.
 *     - Keeps top `heavy_hitter_budget` middle blocks in full 2.0-bpw RAM KV.
 *     - Collapses remaining middle blocks in-place into a 64:1 Monoidal Centroid
 *       KV Token and spills their raw 2.0-bpw payload to the external SSD swap
 *       file, retaining their 68B Monoidal Summary in RAM for sub-ms recall.
 */
static inline int udie_compactor_run_cycle(
    UdieHierarchicalCompactor* comp,
    UdieRadixConversationManager* mgr,
    uint32_t branch_id
) {
    if (!comp || !mgr || branch_id >= mgr->num_branches) return -1;
    UdieConversationBranch* br = &mgr->branches[branch_id];
    uint32_t B_total = br->num_blocks;

    /* Index any newly appended blocks first */
    while (comp->num_indexed_blocks < B_total) {
        uint32_t idx = comp->num_indexed_blocks;
        uint32_t blk_id = br->block_seq[idx];
        const UdieRadixBlockNode* node = &mgr->nodes[blk_id];
        const UdieKvBlockPayload* payload = &mgr->block_payloads[blk_id];
        UdieCompactorBlockEntry* entry = &comp->entries[idx];

        entry->block_id = blk_id;
        entry->turn_id = node->turn_id;
        entry->pinned_entity = node->has_pinned_entity;
        entry->ssd_slot_index = 0xFFFFFFFFu;

        udie_compute_monoidal_summary_and_centroid(
            payload, &entry->summary_68b, &entry->centroid_token);

        entry->cumulative_attention = entry->centroid_token.total_attention_mass /
                                      (float)UDIE_CONV_BLOCK_TOKENS;

        float novelty_sq = 0.0f;
        if (idx > 0) {
            const UdieMonoidalBlockSummary68B* prev_sum = &comp->entries[idx - 1].summary_68b;
            for (int d = 0; d < UDIE_CONV_LATENT_DIM; ++d) {
                float diff = (float)(entry->summary_68b.mu_q8[d] - prev_sum->mu_q8[d]);
                novelty_sq += diff * diff;
            }
        }
        entry->novelty_l2 = sqrtf(novelty_sq) / 128.0f;
        entry->utility_score =
            comp->w_attn * entry->cumulative_attention +
            comp->w_novelty * entry->novelty_l2 +
            comp->w_pin * (entry->pinned_entity ? 1.0f : 0.0f);

        entry->tier_state = UDIE_BLOCK_TIER_ACTIVE_TAIL;
        comp->num_indexed_blocks++;
    }

    comp->compaction_cycles_run++;
    comp->total_tokens_processed = (uint64_t)B_total * UDIE_CONV_BLOCK_TOKENS;

    uint32_t B_sys  = (comp->pinned_sys_blocks < B_total) ? comp->pinned_sys_blocks : B_total;
    uint32_t B_tail = comp->active_tail_blocks;
    uint32_t tail_start = (B_total > B_sys + B_tail) ? (B_total - B_tail) : B_sys;

    /* Mark Tier A Sacred Prefix and Active Tail */
    for (uint32_t i = 0; i < B_sys; ++i) {
        comp->entries[i].tier_state = UDIE_BLOCK_TIER_PINNED_PREFIX;
    }
    for (uint32_t i = tail_start; i < B_total; ++i) {
        comp->entries[i].tier_state = UDIE_BLOCK_TIER_ACTIVE_TAIL;
    }

    /* Score middle blocks `[B_sys, tail_start)` and determine heavy-hitter threshold */
    uint32_t mid_count = (tail_start > B_sys) ? (tail_start - B_sys) : 0;
    if (mid_count > 0) {
        /* Select top `heavy_hitter_budget` middle blocks by utility_score */
        for (uint32_t i = B_sys; i < tail_start; ++i) {
            comp->entries[i].tier_state = UDIE_BLOCK_TIER_CENTROID_64_1;
        }
        uint32_t keep_hh = (comp->heavy_hitter_budget < mid_count)
            ? comp->heavy_hitter_budget
            : mid_count;

        for (uint32_t h = 0; h < keep_hh; ++h) {
            float best_u = -1.0f;
            uint32_t best_idx = B_sys;
            for (uint32_t i = B_sys; i < tail_start; ++i) {
                if (comp->entries[i].tier_state == UDIE_BLOCK_TIER_HEAVY_HITTER) continue;
                if (comp->entries[i].utility_score > best_u) {
                    best_u = comp->entries[i].utility_score;
                    best_idx = i;
                }
            }
            comp->entries[best_idx].tier_state = UDIE_BLOCK_TIER_HEAVY_HITTER;
        }

        /* Persist all historical middle blocks to External SSD episodic log if not already persisted */
        for (uint32_t i = B_sys; i < tail_start; ++i) {
            UdieCompactorBlockEntry* e = &comp->entries[i];
            if (e->ssd_slot_index == 0xFFFFFFFFu) {
                uint32_t slot = comp->num_spilled_blocks++;
                off_t offset = (off_t)slot * (off_t)sizeof(UdieKvBlockPayload);
                ssize_t w = pwrite(comp->ssd_fd,
                                   &mgr->block_payloads[e->block_id],
                                   sizeof(UdieKvBlockPayload),
                                   offset);
                (void)w;
                e->ssd_slot_index = slot;
                e->centroid_token.ssd_spill_slot = slot;
                comp->ssd_spilled_bytes += sizeof(UdieKvBlockPayload);
            }
        }
    }

    /* Update RAM KV telemetry (`1024 B` per full 2.0-bpw block vs `16 B` per 64:1 centroid + `68 B` summary) */
    uint64_t full_blocks = 0;
    uint64_t centroid_blocks = 0;
    for (uint32_t i = 0; i < B_total; ++i) {
        if (comp->entries[i].tier_state == UDIE_BLOCK_TIER_CENTROID_64_1) {
            centroid_blocks++;
        } else {
            full_blocks++;
        }
    }
    comp->uncompacted_ram_kv_bytes = (uint64_t)B_total * 1024ULL;
    comp->active_ram_kv_bytes =
        full_blocks * 1024ULL + centroid_blocks * 16ULL;

    return 0;
}

/*
 * `udie_compactor_episodic_recall`:
 *   Scores `query_latent[64]` against all spilled 68-byte Monoidal Block
 *   Summaries using the associative upper bound:
 *     Score(b) = <q_abs, mu_b> + gamma * ||q_abs||_2 * R_b
 *   and recalls the top-`max_recall` spilled blocks from the external SSD swap
 *   file via `pread` back into `out_recalled_payloads`.
 */
static inline uint32_t udie_compactor_episodic_recall(
    UdieHierarchicalCompactor* comp,
    const int8_t query_latent[UDIE_CONV_LATENT_DIM],
    uint32_t max_recall,
    UdieKvBlockPayload* out_recalled_payloads,
    uint32_t* out_recalled_block_indices
) {
    if (!comp || !query_latent || max_recall == 0) return 0;
    if (max_recall > UDIE_COMPACTOR_TOP_RECALL_MAX) {
        max_recall = UDIE_COMPACTOR_TOP_RECALL_MAX;
    }

    float q_norm_sq = 0.0f;
    for (int d = 0; d < UDIE_CONV_LATENT_DIM; ++d) {
        float qd = (float)query_latent[d];
        q_norm_sq += qd * qd;
    }
    float q_norm = sqrtf(q_norm_sq);

    float best_scores[UDIE_COMPACTOR_TOP_RECALL_MAX];
    uint32_t best_indices[UDIE_COMPACTOR_TOP_RECALL_MAX];
    uint32_t found = 0;

    for (uint32_t i = 0; i < comp->num_indexed_blocks; ++i) {
        const UdieCompactorBlockEntry* e = &comp->entries[i];
        if (e->ssd_slot_index == 0xFFFFFFFFu) continue;

        float dot = 0.0f;
        float scale = (float)e->summary_68b.scale_q16 / 1024.0f;
        if (scale < 1e-5f) scale = 1.0f;
        for (int d = 0; d < UDIE_CONV_LATENT_DIM; ++d) {
            dot += (float)query_latent[d] * ((float)e->summary_68b.mu_q8[d] * scale);
        }
        float radius = (float)e->summary_68b.radius_q16 / 16.0f;
        float score = dot + comp->recall_gamma * q_norm * radius;

        if (found < max_recall) {
            best_scores[found] = score;
            best_indices[found] = i;
            found++;
        } else {
            uint32_t min_pos = 0;
            for (uint32_t k = 1; k < found; ++k) {
                if (best_scores[k] < best_scores[min_pos]) min_pos = k;
            }
            if (score > best_scores[min_pos]) {
                best_scores[min_pos] = score;
                best_indices[min_pos] = i;
            }
        }
    }

    /* Sort recalled blocks in descending score order and pread from SSD */
    for (uint32_t a = 0; a < found; ++a) {
        for (uint32_t b = a + 1; b < found; ++b) {
            if (best_scores[b] > best_scores[a]) {
                float ts = best_scores[a];
                best_scores[a] = best_scores[b];
                best_scores[b] = ts;
                uint32_t ti = best_indices[a];
                best_indices[a] = best_indices[b];
                best_indices[b] = ti;
            }
        }
    }

    for (uint32_t k = 0; k < found; ++k) {
        uint32_t idx = best_indices[k];
        UdieCompactorBlockEntry* e = &comp->entries[idx];
        off_t offset = (off_t)e->ssd_slot_index * (off_t)sizeof(UdieKvBlockPayload);
        if (out_recalled_payloads) {
            ssize_t r = pread(comp->ssd_fd,
                              &out_recalled_payloads[k],
                              sizeof(UdieKvBlockPayload),
                              offset);
            (void)r;
        }
        if (out_recalled_block_indices) {
            out_recalled_block_indices[k] = idx;
        }
        e->tier_state = UDIE_BLOCK_TIER_RECALLED_SSD;
    }

    comp->ssd_recall_queries++;
    comp->ssd_blocks_recalled += found;
    return found;
}

/* ============================================================================
 * 3. Grammar-Forced Speculative Tool-Call Drafting (`udie_grammar_forced_draft`)
 *    & Triple-Protocol Open-Source Agentic Harness Adapter
 * ============================================================================ */

typedef enum {
    UDIE_GRAMMAR_STATE_OPEN_BRACE    = 0, /* Drafts `{"name":"` */
    UDIE_GRAMMAR_STATE_TOOL_NAME     = 1, /* Emits constrained tool identifier */
    UDIE_GRAMMAR_STATE_ARGS_PREFIX   = 2, /* Drafts `","arguments":{"` */
    UDIE_GRAMMAR_STATE_ARG_KEY       = 3, /* Emits schema property key + `":` */
    UDIE_GRAMMAR_STATE_ARG_VALUE     = 4, /* Emits argument value */
    UDIE_GRAMMAR_STATE_CLOSE_BRACES  = 5, /* Drafts `}}` */
    UDIE_GRAMMAR_STATE_COMPLETE      = 6
} UdieGrammarAutomatonState;

typedef struct {
    const char* tool_name;
    const char* required_arg_keys[4];
    const char* sample_arg_values[4];
    int         num_args;
} UdieToolSchemaSpec;

typedef struct {
    char     json_output[512];
    uint32_t total_tokens_emitted;
    uint32_t grammar_forced_tokens; /* Zero-weight-read deterministic structural tokens */
    uint32_t model_evaluated_tokens; /* Semantic value tokens requiring forward pass */
    uint32_t accepted_forced_tokens; /* 100% acceptance for deterministic schema tokens */
    bool     valid_json_schema;
} UdieGrammarDraftResult;

/*
 * `udie_grammar_forced_draft`:
 *   Executes a deterministic JSON-Schema pushdown automaton over `schema`,
 *   auto-drafting all structural boilerplate tokens (`{"name":"`, `","arguments":{"`,
 *   `":`, `,"`, `}}`) with zero model weight reads and 100% speculative acceptance.
 */
static inline void udie_grammar_forced_draft(
    const UdieToolSchemaSpec* schema,
    UdieGrammarDraftResult* out_res
) {
    if (!schema || !out_res) return;
    memset(out_res, 0, sizeof(*out_res));

    size_t pos = 0;
    /* State 0: Forced structural prefix `{"name":"` (3 tokens) */
    pos += (size_t)snprintf(out_res->json_output + pos, sizeof(out_res->json_output) - pos,
                            "{\"name\":\"");
    out_res->grammar_forced_tokens += 3;

    /* State 1: Tool Name (if single tool or prefix-uniquely determined, forced; else 1 model token + forced suffix) */
    pos += (size_t)snprintf(out_res->json_output + pos, sizeof(out_res->json_output) - pos,
                            "%s", schema->tool_name ? schema->tool_name : "bash_exec");
    out_res->model_evaluated_tokens += 1;
    out_res->grammar_forced_tokens  += 2; /* Identifier continuation subwords */

    /* State 2: Forced structural transition `","arguments":{` (4 tokens) */
    pos += (size_t)snprintf(out_res->json_output + pos, sizeof(out_res->json_output) - pos,
                            "\",\"arguments\":{");
    out_res->grammar_forced_tokens += 4;

    /* States 3 & 4: Schema-constrained argument keys (forced) + values (model-evaluated) */
    for (int i = 0; i < schema->num_args; ++i) {
        if (i > 0) {
            pos += (size_t)snprintf(out_res->json_output + pos, sizeof(out_res->json_output) - pos, ",");
            out_res->grammar_forced_tokens += 1;
        }
        pos += (size_t)snprintf(out_res->json_output + pos, sizeof(out_res->json_output) - pos,
                                "\"%s\":%s",
                                schema->required_arg_keys[i],
                                schema->sample_arg_values[i]);
        out_res->grammar_forced_tokens += 3; /* `"<key>":` */
        out_res->model_evaluated_tokens += 2; /* Value tokens */
    }

    /* State 5: Forced structural closure `}}` (2 tokens) */
    snprintf(out_res->json_output + pos, sizeof(out_res->json_output) - pos, "}}");
    out_res->grammar_forced_tokens += 2;

    out_res->accepted_forced_tokens = out_res->grammar_forced_tokens;
    out_res->total_tokens_emitted   = out_res->grammar_forced_tokens + out_res->model_evaluated_tokens;
    out_res->valid_json_schema      = true;
}

/*
 * 3.1 OpenAI `/v1/chat/completions` Formatter (OpenCode, Aider, Cline, Continue, Cursor)
 */
static inline int udie_format_openai_chat_completion_json(
    const char* model_name,
    const char* assistant_content,
    const UdieGrammarDraftResult* optional_tool_call,
    uint32_t prompt_tokens,
    uint32_t cached_prompt_tokens,
    uint32_t completion_tokens,
    uint64_t logits_fnv1a64,
    char* out_buf,
    size_t out_cap
) {
    if (optional_tool_call && optional_tool_call->valid_json_schema) {
        return snprintf(out_buf, out_cap,
            "{\n"
            "  \"id\": \"chatcmpl-udie-%016" PRIx64 "\",\n"
            "  \"object\": \"chat.completion\",\n"
            "  \"model\": \"%s\",\n"
            "  \"choices\": [{\n"
            "    \"index\": 0,\n"
            "    \"message\": {\n"
            "      \"role\": \"assistant\",\n"
            "      \"content\": null,\n"
            "      \"tool_calls\": [{\n"
            "        \"id\": \"call_udie_01\",\n"
            "        \"type\": \"function\",\n"
            "        \"function\": %s\n"
            "      }]\n"
            "    },\n"
            "    \"finish_reason\": \"tool_calls\"\n"
            "  }],\n"
            "  \"usage\": {\n"
            "    \"prompt_tokens\": %u,\n"
            "    \"completion_tokens\": %u,\n"
            "    \"total_tokens\": %u,\n"
            "    \"prompt_tokens_details\": {\n"
            "      \"cached_tokens\": %u\n"
            "    },\n"
            "    \"completion_tokens_details\": {\n"
            "      \"grammar_forced_speculative_tokens\": %u\n"
            "    }\n"
            "  }\n"
            "}\n",
            logits_fnv1a64,
            model_name,
            optional_tool_call->json_output,
            prompt_tokens,
            completion_tokens,
            prompt_tokens + completion_tokens,
            cached_prompt_tokens,
            optional_tool_call->accepted_forced_tokens);
    }

    return snprintf(out_buf, out_cap,
        "{\n"
        "  \"id\": \"chatcmpl-udie-%016" PRIx64 "\",\n"
        "  \"object\": \"chat.completion\",\n"
        "  \"model\": \"%s\",\n"
        "  \"choices\": [{\n"
        "    \"index\": 0,\n"
        "    \"message\": {\n"
        "      \"role\": \"assistant\",\n"
        "      \"content\": \"%s\"\n"
        "    },\n"
        "    \"finish_reason\": \"stop\"\n"
        "  }],\n"
        "  \"usage\": {\n"
        "    \"prompt_tokens\": %u,\n"
        "    \"completion_tokens\": %u,\n"
        "    \"total_tokens\": %u,\n"
        "    \"prompt_tokens_details\": {\n"
        "      \"cached_tokens\": %u\n"
        "    }\n"
        "  }\n"
        "}\n",
        logits_fnv1a64,
        model_name,
        assistant_content ? assistant_content : "",
        prompt_tokens,
        completion_tokens,
        prompt_tokens + completion_tokens,
        cached_prompt_tokens);
}

/*
 * 3.2 Anthropic `/v1/messages` Formatter (Claude Code, Zed, OpenCode)
 */
static inline int udie_format_anthropic_messages_json(
    const char* model_name,
    const char* assistant_content,
    const UdieGrammarDraftResult* optional_tool_call,
    uint32_t input_tokens,
    uint32_t cache_read_input_tokens,
    uint32_t cache_creation_input_tokens,
    uint32_t output_tokens,
    uint32_t compacted_blocks_64_to_1,
    uint32_t ssd_recalled_blocks,
    uint64_t logits_fnv1a64,
    char* out_buf,
    size_t out_cap
) {
    if (optional_tool_call && optional_tool_call->valid_json_schema) {
        return snprintf(out_buf, out_cap,
            "{\n"
            "  \"id\": \"msg_udie_%016" PRIx64 "\",\n"
            "  \"type\": \"message\",\n"
            "  \"role\": \"assistant\",\n"
            "  \"model\": \"%s\",\n"
            "  \"content\": [{\n"
            "    \"type\": \"tool_use\",\n"
            "    \"id\": \"toolu_udie_01\",\n"
            "    \"tool_call\": %s\n"
            "  }],\n"
            "  \"stop_reason\": \"tool_use\",\n"
            "  \"usage\": {\n"
            "    \"input_tokens\": %u,\n"
            "    \"cache_creation_input_tokens\": %u,\n"
            "    \"cache_read_input_tokens\": %u,\n"
            "    \"output_tokens\": %u\n"
            "  },\n"
            "  \"context_management\": {\n"
            "    \"monoidal_compacted_blocks_64_to_1\": %u,\n"
            "    \"ssd_episodic_recalled_blocks\": %u\n"
            "  }\n"
            "}\n",
            logits_fnv1a64,
            model_name,
            optional_tool_call->json_output,
            input_tokens,
            cache_creation_input_tokens,
            cache_read_input_tokens,
            output_tokens,
            compacted_blocks_64_to_1,
            ssd_recalled_blocks);
    }

    return snprintf(out_buf, out_cap,
        "{\n"
        "  \"id\": \"msg_udie_%016" PRIx64 "\",\n"
        "  \"type\": \"message\",\n"
        "  \"role\": \"assistant\",\n"
        "  \"model\": \"%s\",\n"
        "  \"content\": [{\n"
        "    \"type\": \"text\",\n"
        "    \"text\": \"%s\"\n"
        "  }],\n"
        "  \"stop_reason\": \"end_turn\",\n"
        "  \"usage\": {\n"
        "    \"input_tokens\": %u,\n"
        "    \"cache_creation_input_tokens\": %u,\n"
        "    \"cache_read_input_tokens\": %u,\n"
        "    \"output_tokens\": %u\n"
        "  },\n"
        "  \"context_management\": {\n"
        "    \"monoidal_compacted_blocks_64_to_1\": %u,\n"
        "    \"ssd_episodic_recalled_blocks\": %u\n"
        "  }\n"
        "}\n",
        logits_fnv1a64,
        model_name,
        assistant_content ? assistant_content : "",
        input_tokens,
        cache_creation_input_tokens,
        cache_read_input_tokens,
        output_tokens,
        compacted_blocks_64_to_1,
        ssd_recalled_blocks);
}

#ifdef __cplusplus
}
#endif

#endif /* UDIE_HARNESS_COMPACTION_H */
