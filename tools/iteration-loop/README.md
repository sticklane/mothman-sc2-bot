# Mothman SC2 Closed-Loop Autonomous Iteration & Trajectory Flywheel Framework

This directory powers the durable multi-agent closed-loop optimization system for `mothman-sc2-bot`. Every iteration fuses **real-`SC2_x64` 90-match gauntlets & Head-to-Head Ship Gates**, **213-scenario Tactics Arena 3.0 micro/runby drills**, **298-replay LotV Pro Corpus baselines**, **live AI Arena production feedback**, and a **Self-Improving Loop Trajectory Flywheel** that audits the swarm's own execution logs to make the loop faster and sharper every cycle.

See [`SWARM_PLAYBOOK.md`](./SWARM_PLAYBOOK.md) (v2.1) for the full operational protocol, disjoint file ownership matrix, fast-cycle tooling, and fail-fast Ship Gate rules.

---

## Temporary Local-Loop Policy: 25-Minute Match Cap & Game-State Scoring (Revisit Trigger)

> **IMPORTANT (Temporary Fast-Iteration Policy):** Local benchmark runs cap matches at **`25` game minutes max (`--max-game-time 33600` loops)** and evaluate matches with **end-of-game state scoring** alongside raw `W-L-T`.

- **25-Minute Match Cap:** `tools/run-local-sc2-arena.py` defaults to `--max-game-time 33600` (`25.0` SC2 minutes) for faster local iteration and fewer wall-clock stragglers.
- **End-of-Game State Scoring:** `tools/score-replay-batch.rkt` computes `game_state_score` (`[0, 1]` / `0-100`) from final live **Army Value (`45%`) + Income Rate (`30%`) + Minerals Collected (`15%`) + Trade Value (`10%`)**, plus `state_adjudicated_wlt` adjudicating 25m-cap / wall-timeout ties at `state_ratio >= 1.15` (Win) and `<= 0.87` (Loss), displayed alongside raw `W-L-T` for AI Arena and Release `#14-#16` parity.
- **Explicit Revisit Trigger:** Revisit and raise the cap back to `30m` (`40320`) / `45m` (`60480`) and switch primary gating back toward elimination outcome once longer late-game matches become common (e.g., `> 15%` of external matches hitting the 25m cap, or when pushing into higher AI Arena divisions where 25m+ split-map / Tier-3 endgames decide matches).

---

## 1. Closed-Loop Pipeline (Fail-Fast Gate 2A + Step 4C Flywheel)

```text
[Step 1: Parallel Disjoint Implementation — @runtime-author || @belief-author || @wire-author]
   - Pre-granted track test ownership; mandatory Main-Army Negative Guard & Brain<->Runtime parity
        |
        v
[Step 2: Gate 1 Solo Verification — @verifier (~2m, 10/10 gates, exclusive wall-clock perf owner)]
        |
        v
[Step 3a: Fail-Fast Gate 2A (~2.5m GPU)]
   - 25s targeted `--category`/`--scenario` Arena 3.0 pre-check on Flip-Flop-Guarded edits
   - 2m `baseline_h2h` (6 matches vs live Ship ZIPs) BEFORE 30m 84-match roster
   - If H2H <= 3W-3L or a race collapses 0-2 -> immediate HOLD-ZIP (saves ~29m!)
        |
        v (H2H PASS)
[Step 3b: Full Gate 2B (~35m GPU)]
   - @tactics-tester: Tactics Arena 3.0 `--suite core` (66x2 = 132 full-length live-HUD MP4s)
   - @harness: 84-match roster (`core_14` 42m + `unseen_12` 36m + `self_6` 6m)
   - On Ship Gate PASS -> 4-race ELF ZIP smoke (~2.5m) -> LIVE AI ARENA SHIP!
        |
        v
[Step 4A || Step 4B || Step 4C: Forensics, Visual Archival & Trajectory Flywheel]
   - Step 4A (@analyzer): `sync-prod` live AI Arena audit + SQLite forensics + next-loop blueprint
   - Step 4B (@loop-architect): `compare-vs-pro.py`, `loop_ledger.json`, Top-8 MP4s
     (+ 90/90 full-match MP4s on SHIP-ZIP), SQLite `ingest-runs` + `extract-raw`
   - Step 4C (@loop-architect, <3s): `log-loop-trajectory.py` + `analyze-loop-flywheel.py`
     -> feeds phase Pareto, agent churn, flip-flop warnings & counterfactual patches into Loop N+1!
```

---

## 2. Core Artifacts & Tooling

| File | Owner | Purpose |
|---|---|---|
| `SWARM_PLAYBOOK.md` | `@loop-architect` | v2.0 operational playbook: disjoint ownership, pre-granted track tests, `H2H-First` fail-fast gate, Flip-Flop Guard, and Step 4C flywheel commands. |
| `pro_baselines.json` | `@loop-architect` | Canonical Pro LotV medians by Race & all 9 Matchups (`W@2/4/6/8/10m`, `Nat@`, `3rd@`, `Gas1/2@`, `Prod1@`, `Tech1@`, `ArmyVal/Worker@6m`). |
| `compare-vs-pro.py` | `@loop-architect` | Fast (`<1s`) comparator fusing match scorecards + Tactics Arena JSON vs `pro_baselines.json`, flagging systemic divergences & evaluating 9 promotion gates. |
| `loop_ledger.json` | `@loop-architect` | Durable repo ledger (`#1..#50+`) recording every loop's revision, cohorts, H2H, Tactics Arena summary, latency, anomalies, and Visual QA highlights. |
| `log-loop-trajectory.py` | `@loop-architect` | **Flywheel Step 4C logger:** streams coordinator + all auto-discovered worker `transcript.jsonl` files, joins with `loop_ledger.json`, tactics JSONs, and read-only `arena_replays.sqlite`, and upserts compact per-loop trajectory telemetry into `loop_trajectory_log.jsonl`. |
| `loop_trajectory_log.jsonl` | `@loop-architect` | Append/upsert-friendly structured JSONL log of every loop's phase wall-clock breakdown, per-agent step/tool/error/token/monolith-read counts, bot deltas, and automated friction events (backfilled from Loop 19 onward). |
| `analyze-loop-flywheel.py` | `@loop-architect` | **Flywheel Step 4C analyzer:** computes phase wall-clock Pareto & GPU utilization, per-agent churn scorecards, HOLD-ZIP root-cause taxonomy, `<=3`-loop Flip-Flop Detector, row-by-row counterfactual speedup simulator, and ranked concrete process patches -> `scratch/loop/loop_flywheel_retro.{md,json}`. |
| `sc2_3d_renderer.py`, `render-replay-clips.py`, `build-visual-report.py` | `@loop-architect` | Real-`SC2_x64` 3D Live-HUD H.264 MP4 renderer (`Top-8` extended 21s highlights + `90/90` full-length `00:00->GG` match videos) and plain-English Markdown visual report builder. |
| `tests/test-loop-flywheel.py` | `@loop-architect` | Fast (`<1s`) self-contained unit & integration test suite verifying trajectory logging, auto-discovery, friction detection, JSONL idempotency, flip-flop detection, counterfactual math, and live log hygiene. |

---

## 3. Running the Trajectory Flywheel

```bash
# Backfill historical loops (e.g. Loops 19–47) or log a single newly finished loop:
python3 tools/iteration-loop/log-loop-trajectory.py --from-loop 19
python3 tools/iteration-loop/log-loop-trajectory.py --loop 48

# Generate Markdown + JSON flywheel retrospective:
python3 tools/iteration-loop/analyze-loop-flywheel.py

# Run flywheel unit tests:
python3 tests/test-loop-flywheel.py
```

---

## 4. Non-Negotiable Generalization & Safety Rules

1. **Zero Opponent-Name Hacks, Map-Name Hacks, Replay-ID Branches, or Speed-Mining.**
2. **General SC2 Physics & Macro Laws Only:** Every fix must pass Gate 1's formal invariants (`state-machine-verifier.rkt` 24/24), pro starvation (`0/0/0/0`), pro divergence, Brain↔Runtime contract checks, and `HYGIENE_CODE_HITS=0`.
3. **Secret & Path Hygiene:** `log-loop-trajectory.py` auto-discovers brain paths dynamically (zero hardcoded credentials/tokens) and strips local home prefixes from `edited_files` before writing `loop_trajectory_log.jsonl`.
