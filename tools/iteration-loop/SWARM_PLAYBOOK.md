# Mothman SC2 Autonomous Improvement Loop — Swarm Playbook

Operational playbook for running, checkpointing, and continuously self-improving the multi-agent closed-loop optimization bench for `mothman-sc2-bot` (complements [`README.md`](./README.md)).

---

## 1. Swarm Topology & Strict Disjoint File Ownership

Every role operates asynchronously on a shared message board. **No two active authors may edit the same file or run `raco make` on another author's module.**

| Role | Primary Mission | Strictly Owned Files (Write) | Read-Only / Hands-Off |
|---|---|---|---|
| `@coordinator` | Top-level swarm orchestration, user directives, ladder zip packaging & final AI-Arena deploy | `ladder/Mothman-*.zip` (ship only) | Delegates code edits to specialists |
| `@harness` | Runs parallel real-`SC2_x64` container gauntlets (`-j 14` interleaved, source `.zo` mode) | `tools/run-local-sc2-arena.py`, `tools/sc2-match-proxy.py` | `lib/`, `tests/` |
| `@tactics-tester` | Maintains & expands deterministic live-pipeline suite (`80+` scenarios) + `15`-duel real-`SC2_x64` physics arena | `tools/tactics-unit-tester.rkt`, `tools/sc2-tactics-arena.py`, `scratch/loop/tactics_*.json` | `lib/`, `tests/` |
| `@analyzer` | Single-pass `<1s` replay scoring, anomaly detection, paired W(N-1)->W(N) diffs, regression forensics | `tools/score-replay-batch.rkt`, `scratch/*_score.json` | `lib/`, `tests/` |
| `@loop-architect` | Fuses gauntlet JSON + tactical scorecards + 298-replay LotV Pro Corpus -> generalizes laws -> writes Wave-(N+1) Spec & Loop Self-Improvement item -> kicks off next wave | `tools/iteration-loop/*`, `scratch/loop/pro_comparison_*.json`, `scratch/loop/loop_ledger.json` | `lib/`, `tests/` |
| `@wire-author` | Protobuf wire normalization, query batching/caching, placement wall algorithms, wire action guards | `lib/sc2-protobuf-ws.rkt`, `lib/sc2-placement.rkt`, `tests/sc2-protobuf-ws-test.rkt` | All other `lib/` files |
| `@belief-author` | Macro priority brain, econ ledger, opponent world model, Bayesian mirror-mind predictor | `lib/priority-macro-brain.rkt`, `lib/econ-ledger.rkt`, `lib/opponent-world-model.rkt`, `lib/mirror-mind-predictor.rkt` | All other `lib/` files |
| `@runtime-author` | Core runtime L2 macro execution, L3/L4 combat/tactics, spellcaster micro, arena minimax | `lib/bot-runtime.rkt`, `lib/tactics/pro-spellcaster-micro.rkt`, `lib/tactics/arena-minimax.rkt` | All other `lib/` files |
| `@verifier` | Unified 7-gate verification (`raco make`, formal invariants, wire tests, unit tests, starvation audit, pro divergence, tactical suite + generality/hygiene audit) & clean `jj` checkpoints | Verifies whole repo; runs `jj describe`/`bookmark`/`push`/`new` on clean checkpoints | Never hacks around failing gates; bounces to owning author |
| `@reporter` | Non-blocking cumulative phase log & crisp `[phase-report]` bulletins to `@coordinator` | `scratch/loop/phase_reports.md` | Everything in repo |
| `@monitor` | Low-frequency stall watchdog (wakes stuck agent if whole swarm idles unexpectedly) | None | Everything |

---

## 2. Non-Blocking Phase State Machine & Reporting Protocol

```text
[Phase 1a: @harness 36-match SC2 gauntlet (~10-12m)]
   ||  [Phase 1b: @tactics-tester 80+ unit-tester (0.6s) + 15-duel SC2 physics A/B (15s) + next-round repro invention]
          |  (post + tag @analyzer @reporter)
          v
[Phase 2: @analyzer single-pass scoring (~0.8s) + paired diff + top-5 root causes]
          |  (post + tag @loop-architect @tactics-tester @reporter @coordinator)
          v
[Phase 3: @loop-architect Pro-Corpus comparison + generalization + Wave-(N+1) Spec + 1 Loop Self-Improvement item]
          |  (if 9/9 Promotion Gates PASS -> tag @coordinator to package & deploy)
          |  (else post disjoint spec + tag @wire-author @belief-author @runtime-author @reporter @coordinator)
          v
[Phase 4: @wire-author || @belief-author || @runtime-author parallel edits (no cross-module raco make)]
          |  (each tags @verifier @reporter upon finishing its slice)
          v
[Phase 5: @verifier 7-gate unified build/test/audit -> clean `jj` checkpoint commit & push -> green-light Phase 1!]
```

### Mandatory Non-Blocking Rules
1. **Always tag `@reporter` alongside the next phase owner(s)** at every handoff — never pause waiting for `@reporter`.
2. **Never run `podman` real-SC2 duels concurrently with a `-j 14` gauntlet**; run `sc2-tactics-arena.py` right after `@verifier` PASS (15s) or before gauntlet launch, and keep `tactics-unit-tester.rkt` + read-only diagnostics running while `@harness` holds the CPU/RAM budget.
3. **Never touch `lib/` while `@harness` is running** (source `.zo` mode reads live `.rkt`/`.zo` from the workspace).
4. **Always pair matches by `(our_bot, opp_bot)`**, never by numeric `match_id` (`--schedule-order interleaved` permutes match IDs across runs).

---

## 3. Per-Cycle "Loop Self-Improvement" Mandate

Every Wave-(N+1) spec issued by `@loop-architect` includes **at least one Loop Self-Improvement upgrade** alongside bot fixes so the measurement and verification machinery gets sharper every cycle:
- **`@tactics-tester`**: Convert newly discovered real-`SC2_x64` duel or gauntlet failures into fast deterministic `tier=wave<N>-repro` acceptance tests + pro-micro `novel` shields.
- **`@analyzer`**: Add new automatic anomaly detectors or per-minute economic/combat diagnostics to `tools/score-replay-batch.rkt` whenever manual log forensics uncovers a recurring failure class.
- **`@loop-architect`**: Refine `tools/iteration-loop/compare-vs-pro.py` & `pro_baselines.json` (e.g., opponent-DC exclusion, alive-median worker curves, paired `(our_bot, opp_bot)` delta reporting, army-volume gap tracking).
- **`@harness`**: Tune container parallelism, scheduling order, and latency telemetry while maintaining `0` errors/crashes.

---

## 4. Exact Relaunch & Verification Commands

Run all commands from `/home/sjaconette/repos/mothman-sc2-bot` (with `jj` as default VCS):

### Phase 1a — 36-Match Parallel Local SC2 Gauntlet (`~10–12m` on 16C/32T, 125 GiB RAM)
```bash
python3 tools/run-local-sc2-arena.py \
  --run-name iter<N>_wave<N> \
  -j 14 \
  --network none \
  --stagger-sec 0.25 \
  --schedule-order interleaved \
  --mothman-mode source
```

### Phase 1b — Deterministic Tactical Suite (`~0.6s`) & 15-Duel Real-`SC2_x64` Physics A/B (`~15s`)
```bash
# Deterministic live-pipeline tactical gate (must be 100%, wire_rejects=0)
racket tools/tactics-unit-tester.rkt --all --strict --json <scratch>/loop/tactics_wave<N>.json

# Real Blizzard SC2_x64 15-duel micro/spellcaster physics A/B (run when gauntlet is idle)
python3 tools/sc2-tactics-arena.py --all --jobs 8 --json <scratch>/loop/tactics_sc2_duel_wave<N>_15.json
```

### Phase 2 — Fast Single-Pass Replay Scoring & Anomaly Detection (`~0.8s`)
```bash
racket tools/score-replay-batch.rkt \
  --anomalies \
  --compare <scratch>/iter<N-1>_wave<N-1>_score.json \
  --json <scratch>/iter<N>_wave<N>_score.json \
  /home/sjaconette/sc2-local-arena/runs/<run_dir>
```

### Phase 3 — Pro-Corpus Comparison & Promotion Gate Check (`<1s`)
```bash
python3 tools/iteration-loop/compare-vs-pro.py \
  --current <scratch>/iter<N>_wave<N>_score.json \
  --baseline <scratch>/iter<N-1>_wave<N-1>_score.json \
  --tactics <scratch>/loop/tactics_wave<N>.json \
  --exclude-opp-crash \
  --out-json <scratch>/loop/pro_comparison_iter<N>_wave<N>.json
```

### Phase 5 — Unified 7-Gate Verification & Clean `jj` Checkpoint
```bash
# 1. Compile core modules (sequentially under @verifier only)
raco make lib/sc2-protobuf-ws.rkt lib/sc2-placement.rkt lib/econ-ledger.rkt \
  lib/priority-macro-brain.rkt lib/opponent-world-model.rkt lib/mirror-mind-predictor.rkt \
  lib/tactics/pro-spellcaster-micro.rkt lib/tactics/arena-minimax.rkt lib/bot-runtime.rkt

# 2-6. Formal invariants, wire tests, unit tests, pro starvation & divergence
racket lib/state-machine-verifier.rkt
racket tests/sc2-protobuf-ws-test.rkt
racket tests/run-all-tests.rkt
racket tools/audit-pro-replay-starvation.rkt --stride 1
racket tools/benchmark-pro-divergence.rkt --spatial --max-replays 80

# 7. Full deterministic live-pipeline tactical suite
racket tools/tactics-unit-tester.rkt --all --strict

# Clean jj checkpoint (NEVER touch ladder/Mothman-*.zip until 9/9 Promotion Gates pass)
jj restore data/racket_native_match_telemetry.jsonl
jj status
jj describe -m "<concise summary of verified wave & loop upgrades>"
jj bookmark set main -r @
jj bookmark set master -r @
jj git push --bookmark main --bookmark master
jj new
```

---

## 5. Generalization & Safety Invariants (Non-Negotiable)

1. **Zero opponent-name hacks, zero map-name hacks, zero replay-ID branches, zero speed-mining.**
2. **Never push `ladder/Mothman-*.zip`** during intermediate checkpoints (`.github/workflows/deploy-aiarena.yml` triggers live ladder deployment strictly on zip changes).
3. **Every fix must be backed by a general SC2 law** (wire unit semantics, resource/tech gating, spell energy/claim invariants, stutter-step firing geometry, win-condition sweep physics) and verified against Pro Corpus medians in [`pro_baselines.json`](./pro_baselines.json).
