# Mothman SC2 Autonomous Improvement Loop: Swarm Playbook v2.1 (Fast-Cycle & Open-Ended Bottleneck Audit Edition)

Operational playbook for running, gating, shipping, and continuously self-improving the multi-agent closed-loop optimization bench for `mothman-sc2-bot` (complements [`README.md`](./README.md)).

> **v2.1 Fast-Cycle Upgrade (Backed by Loops 19-65 Empirical Trajectory & Cycle-Time Audit):**
> Every rule below is empirically derived from logged swarm transcripts (`loop_trajectory_log.jsonl`) and real-engine match timings. Combining isolated per-lane Racket compilation (`tools/racket-lane-test.sh`), Longest-Processing-Time-First bench scheduling (`--schedule-order lpt -j 14`), targeted single-race / 6-opponent `canary` pre-checks before `ALL_84`, one-command parallel post-bench automation (`tools/post-bench-pipeline.py` + `tools/forensics-diff.py`), fast model tiers on mechanical runner roles, single-mention author dispatches, and sub-iteration trajectory logging (`--sub-iter 65G`) removes build-compile stalls, straggler tails, and serial post-bench churn.

---

## 1. Swarm Topology & Strict Disjoint File Ownership

Every role operates asynchronously on the shared message board. **No two active authors may edit the same file or run `raco make` on another author's module.**

| Role | Primary Mission | Strictly Owned Files (Write) | Pre-Granted Track Tests (No Ping-Pong Needed!) |
|---|---|---|---|
| `@coordinator` | Top-level orchestration, user directives, Ship Gate calls, BotZip builds & `jj` commits/pushes | `ladder/Mothman-*.zip` (Ship only), `jj` commits/pushes | — |
| `@runtime-author` | Core runtime macro execution, L3/L4 combat/tactics, spellcaster micro, worker defense | `lib/bot-runtime.rkt`, `lib/tactics/*.rkt`, `lib/sc2-combat-eval.rkt`, `lib/plan/map-elements-and-experiments.rkt` | **`tests/l*-tactics-runtime-test.rkt`** (new & historical runtime test updates) |
| `@belief-author` | Macro priority brain, econ ledger, opponent world model, Bayesian predictor | `lib/priority-macro-brain.rkt`, `lib/econ-ledger.rkt`, `lib/opponent-world-model.rkt`, `lib/mirror-mind-predictor.rkt` | **`tests/verify_wave*_belief.rkt`**, **`tests/run-all-tests.rkt`** |
| `@wire-author` | Protobuf wire normalization, typed commands, query batching, placement algorithms | `lib/sc2-protobuf-ws.rkt`, `lib/sc2-typed-commands.rkt`, `lib/sc2-placement.rkt` | **`tests/sc2-protobuf-ws-test.rkt`**, **`tests/typed-commands-test.rkt`** |
| `@verifier` | Solo 10-gate verification (compile, unit/wire/runtime/belief/tactics/SM, pro starvation/divergence, Python/Arena/Replay-DB, hygiene) | Read-only (bounces failures directly to owning author) | Exclusive owner of **wall-clock perf gates** (`Suite 28 <5ms`, `w5-p0-1a <4.5ms`) |
| `@tactics-tester` | Real-`SC2_x64` Tactics Arena 3.0 (`--suite core`, `66×2 = 132` MP4 duels across `16` categories) & `25s` targeted `--category`/`--scenario` pre-checks | `scratch/loop/tactics_sc2_*_iter*.json`, `scratch/loop/visuals_iter*/{arena,selfplay}/` | — |
| `@harness` | Exclusive GPU/Podman runner: **`H2H-First` (`6`m vs live Ship ZIPs)**, `84`-match roster (`core_14` + `unseen_12` + `self_6`), and `4`-race ELF ZIP smoke | `tools/run-local-sc2-arena.py`, `tools/sc2-match-proxy.py`, `scratch/iter*_score.json` | — |
| `@analyzer` | Live AI Arena `sync-prod`, SQLite forensics, **mandatory Replay + Video Trade Review** (reads contact-sheet `.jpg` + telemetry cards), disjoint next-loop blueprints | `tools/score-replay-batch.rkt`, `scratch/loop/*_audit.md` | Owns SQLite during Step 4A (`sync-prod`) |
| `@loop-architect` | Pro-Corpus comparison (`compare-vs-pro.py`, `pro-deep-comparison.py`), `trade-review-pack.py` contact sheets, `loop_ledger.json`, 3D match MP4s, SQLite ingestion, Arena 3.1 harness, Step 4C trajectory logs | `tools/iteration-loop/*`, `tools/pro-deep-comparison.py`, `tools/trade-review-pack.py`, `tools/sc2-tactics-arena.py`, `tools/arena-scenarios.json`, `.agents/skills/add-arena-scenario/**`, `tools/replay-db.py`, `tests/test-replay-db.py`, `tests/test-loop-flywheel.py` | Owns SQLite during Step 4B (`ingest-runs` + `extract-raw`) |
| `@reporter` | Living visual campaign report, phase log, GitHub Pages & Release media publishing | `tools/publish-gh-pages.py` (when directed), `scratch/loop/phase_reports.md`, campaign report artifact | Never blocks handoffs |
| `@monitor-2` | Low-frequency stall watchdog (adaptive backoff during active GPU/benchmark phases to minimize empty polling turns) | None | Read-only |

### Pre-Granted Ownership & Single-Mention Dispatch Rule (Eliminates Ping-Pongs & Wakeup Fan-Out)
- **Pre-Granted Track Tests:** Authors do **not** need to pause coding to ask `@coordinator` for permission to update historical tests inside their own pre-granted column above when a new loop explicitly supersedes an older threshold. Any cross-track file edit (e.g., `@wire-author` touching `lib/bot-runtime.rkt`) still requires explicit `@coordinator` approval.
- **Single-Mention Author Dispatches:** `@name` is a wakeup doorbell, never a CC. Dispatch each parallel author lane in its own focused post naming only that author (and on peer-to-peer handoffs, mention only the next peer), avoiding unnecessary `@all` or multi-agent wakeups that burn idle turns.
- **Model-Tier Hygiene for Mechanical Runners:** Run mechanical execution roles (`@harness`, `@verifier`, `@monitor-2`) on fast medium/flash model tiers (e.g., `gemini-4-neon-medium`) rather than slow `xhigh` reasoning models, reserving high-reasoning models for architecture, forensics, and complex code authoring.

---

## 2. Fail-Fast Closed-Loop State Machine (v2.1 Fast-Cycle)

```text
[Step 1: Parallel Disjoint Coding: @runtime-author || @belief-author || @wire-author]
   - Single-mention dispatches; pre-granted track test ownership
   - Isolated per-lane compile & test via `tools/racket-lane-test.sh <lane> --compile <srcs...> -- <tests...>`
     (PLTCOMPILEDROOTS=/tmp/zo-<lane>-<pid>: writes ZERO .zo files to repo, never uses slow `racket -c`!)
   - Mandatory Main-Army Negative Guard test on every new global runtime heuristic
   - Mandatory Brain <-> Runtime Cap & Urgency parity check on every new production/tech cap
          |
          v
[Step 2: Gate 1 Solo Verification: @verifier (~2m, fast model, CPU idle, ZERO Podman/SC2)]
   - 10/10 gates: raco make, run-all-tests (incl. Brain<->Runtime contract + Suite 28 <5ms),
     sc2-protobuf-ws-test (incl. w5-p0-1a <4.5ms), typed-commands-test, l31..lN runtime suites,
     belief verifiers, tactics-unit-tester --all --strict, state-machine-verifier,
     pro starvation (0/0/0/0) & divergence, Python/Arena-3.0/Replay-DB/Flywheel/Loop-Speedups tests, hygiene=0
          |
          v
[Step 3a: FAIL-FAST GATE 2A: Targeted Pre-Check + Canary / Single-Race + 2m H2H-First]
   1) If any Flip-Flop-Guarded micro scenario was edited -> @tactics-tester runs 25s `--scenario`/`--category` A/B FIRST!
   2) @harness (fast model, `--schedule-order lpt`):
      - Single-race diff (e.g. Protoss-only): run `--bots Mothman-P --opponents all -j 14` (26m, ~10.4m, avgStep 13.5ms) or
        `--bots Mothman-P --opponents canary -j 14` (6m) BEFORE paying for full 84-match ALL_84!
      - Multi-race diff: run `--opponents canary -j 14` (18m across Z/T/P, ~4-5m) and/or `baseline_h2h` (~2m) FIRST!
      - FAIL-FAST ABORT if pre-check or H2H regresses -> immediate `HOLD-ZIP` -> log via `--sub-iter` + forensics!
          |
          v
[Step 3b: FULL GATE 2B: Full LPT 84-Match Roster (`--schedule-order lpt -j 12`) + Tactics Arena Core]
   - @harness: use `-j 12` for full 84-match `ALL_84` (sweet spot: 24 < 32 threads, avoids `-j 14` ~3ms CPU-contention wall-ties; keep `-j 14` for `<= 26`-match canaries!) with LPT default so 640s stragglers (AxeFighter/QueenBot/puck) start in Wave 1!
   - @tactics-tester: `--suite core` Dummy (66) + Self-Play (66) = 132 full-length live-HUD MP4s (when micro/tactics changed)
   - If Ship Gate passes -> @coordinator rebuilds 4 BotZips -> @harness 4-race ELF ZIP smoke (~2.5m) -> LIVE SHIP!
          |
          v
[Step 4A || Step 4B || Step 4C: One-Command Parallel Post-Bench, Fast Diff Forensics & Open-Ended Retro]
   - One-command post-bench (@harness, 1 turn): `tools/post-bench-pipeline.py <run_dir> --label <tag> --baseline-run <base>`
     runs score-replay-batch, replay-db ingest + extract-raw, pro_deep, s2_features, trade_review_pack, and forensics-diff in parallel!
   - Fast forensics (@analyzer, <15s): `tools/forensics-diff.py <new_run_dir> <base_run_dir> [--race P|T|Z]` + mandatory
     visual inspection of `trade_review_pack` 6-frame `.jpg` contact sheets before drafting the next disjoint blueprint!
   - Step 4C (@loop-architect, <3s offline): `log-loop-trajectory.py --loop <N>` (or `--sub-iter 65G` for held sub-iterations!)
     + `analyze-loop-flywheel.py` -> refreshes `loop_trajectory_log.jsonl` & `loop_flywheel_retro.{md,json}` with all 4
     open-ended cycle-time bottleneck detectors (slow commands >30s, bench CPU/tail/LPT audit, LLM think vs tool time, sub-iters)!
```

---

## 3. Hard Guardrails (Derived from Loops 19–48)

1. **Exclusive GPU & SQLite Locks:** Never run `podman`, host `SC2_x64` rendering, or `sc2-tactics-arena.py` concurrently. Never write to `arena_replays.sqlite` while `@analyzer` runs `sync-prod`. Always verify `PODMAN_AFTER=0, SC2_AFTER=0` (`pgrep -cf '[p]odman'`, `pgrep -cf '[S]C2_x64'`).
2. **Flip-Flop Guard (`<= 3`-Loop Churn Rule):** Whenever `analyze-loop-flywheel.py` flags a scenario or subsystem as touched in `>= 2` of the last `3` loops (e.g., `r02/r05/r06`, `e01`, `rd01`, `ro09`, `0`-Colossus), **no threshold change may be submitted without a `25s` `--scenario` A/B proof** (or closed-loop multi-frame macro trace in Gate 1).
3. **Brain ↔ Runtime Contract Parity:** Every macro cap or priority rule in `lib/priority-macro-brain.rkt` MUST match `lib/bot-runtime.rkt`'s execution ceiling (preventing silent `prod_placement_stall=132` split-brains) and preserve urgency partial orders (e.g., `colossus > phoenix > stalker`, `colossus > immortal` when `colossus = 0`).
4. **Main-Army Negative Guard Mandate:** Any global runtime heuristic added to `lib/bot-runtime.rkt` or `lib/tactics/pro-spellcaster-micro.rkt` (e.g., light-harass splits, Blink-Forward, worker-focus multipliers) MUST ship with a negative unit test proving it does **not** fire during parity/outnumbered frontal clashes or unsiege defensive Tanks.
5. **Solo Perf Gate Discipline:** While `@loop-architect` runs heavy H.264 3D renders (`loadavg > 8`), authors run targeted functional unit tests and defer wall-clock microbenches (`Suite 28 <5ms`, `w5-p0-1a <4.5ms`) to `@verifier`'s solo Gate 1 pass.
6. **Zero Hacks & Plain Copy:** Zero opponent-name hacks, map-name hacks, replay-ID branches, or speed-mining. Reader-facing reports use plain, direct English (no hype adjectives, vanity counts, or cute internal nicknames). Never commit credentials or personal paths into tracked repo files.
7. **Mandatory Post-Run Replay + Video Trade Review Gate:** Every Arena batch (`tactics_sc2_*.json` + MP4s) and every real-match batch (`run_id` in SQLite + rendered match MP4s) MUST produce a `trade-review-pack.py` bundle (6-frame `.jpg` contact sheets + replay telemetry cards for the worst-trading fights). `@analyzer` MUST visually inspect the contact sheets alongside replay stats before finalizing the next loop's combat or micro fixes, extracting generalizable rules rather than one-off patches.

---

## Temporary Local-Loop Policy: 25-Minute Match Cap & Game-State Scoring (Revisit Trigger)

> **IMPORTANT (Temporary Fast-Iteration Policy):** Until late-game 25m+ endgames become a primary factor in our local benchmarks, the local test loop uses a **25-minute game-time cap** and **end-of-game state scoring** alongside raw `W-L-T` so every iteration turns around faster without 30m-45m stalemate tails distorting win/loss counts.

- **25-Minute Local Match Cap:** All local bench runs default to `--max-game-time 33600` loops (`25.0` SC2 game minutes = `25 * 60 * 22.4`) in `tools/run-local-sc2-arena.py`.
- **End-of-Game State Scoring (`tools/score-replay-batch.rkt` & `tools/post-bench-pipeline.py`):**
  - Every match computes a continuous, ungameable **`game_state_score`** in `[0, 1]` (displayed as `0-100`) from final-frame live `SPlayerStatsEvent` telemetry: **Army Value `45%` + Income Rate `30%` + Minerals Collected `15%` + Trade Value `10%`**.
  - **`state_adjudicated_wlt`** adjudicates 25m-cap and wall-timeout ties directly from the final state ratio (`state_ratio >= 1.15` -> Win, `state_ratio <= 0.87` -> Loss, else Tie) while keeping pre-cap eliminations as Win/Loss.
  - Raw `W-L-T` is still reported side-by-side for strict AI Arena production and Release `#14-#16` baseline parity.
- **Explicit Revisit Trigger:** Revisit this policy and raise `--max-game-time` back to `30m` (`40320`) / `45m` (`60480`) (and shift primary gating back toward elimination outcomes) once **either**:
  1. More than **`15%` of external matches** hit the 25-minute cap regularly, **or**
  2. We push into higher AI Arena divisions where 25m+ split-map / Tier-3 late-game endgames routinely decide matches.

---

## 4. Exact Modern Commands (Fast-Cycle v2.1)

Run all commands from the `mothman-sc2-bot/` repository root (using `jj` as default VCS):

### Step 1: Isolated Per-Lane Author Compile & Test (No `racket -c`, Zero Repo `.zo` Collisions)
```bash
# Compiles ONLY edited files + target tests inside /tmp/zo-<lane>-<pid> and cleans up via EXIT trap
tools/racket-lane-test.sh lane1 --compile lib/tactics/staging-groups.rkt lib/tactics/multiprong-coordinator.rkt -- tests/l58-staging-groups-test.rkt tests/l65-multiprong-coordinator-test.rkt
tools/racket-lane-test.sh lane2 --compile lib/bot-runtime.rkt -- tests/l49-tactics-runtime-test.rkt
tools/racket-lane-test.sh lane3 --compile lib/priority-macro-brain.rkt -- tests/l48-worker-rush-macro-test.rkt
```

### Step 3a: Targeted Pre-Check (`canary` / Single-Race / `2m` H2H) Before `ALL_84`
```bash
# Single-race pre-check on single-race diffs (e.g. Protoss-only: 6 canary matches or 26 external matches, LPT + -j 14)
python3 tools/run-local-sc2-arena.py --bots Mothman-P --opponents canary -j 14 --schedule-order lpt --mothman-mode source --tag iter<N>_p_canary
python3 tools/run-local-sc2-arena.py --bots Mothman-P --opponents all -j 14 --schedule-order lpt --mothman-mode source --tag iter<N>_p_ext26

# 3-race high-signal 18-match canary (~4-5m at -j 14)
python3 tools/run-local-sc2-arena.py --opponents canary -j 14 --schedule-order lpt --mothman-mode source --tag iter<N>_canary18

# Targeted Arena 3.0 pre-check on edited scenarios/categories (~25s)
python3 tools/sc2-tactics-arena.py --opponent dummy --category runby-offense --jobs 6 --max-loops 960
python3 tools/sc2-tactics-arena.py --opponent self --scenario r02,r05,r06 --jobs 3 --max-loops 960

# H2H-First Ship Gate vs currently live BotZips (~2m, fail-fast before 84-match roster!)
python3 tools/run-local-sc2-arena.py --opponents self_6 --selfplay-baseline --selfplay-matches 12 -j 14 --schedule-order lpt --mothman-mode source --tag iter<N>_h2h_12
```

### Step 3b: Full LPT `84`-Match Roster (`--schedule-order lpt -j 12`) & Tactics Arena Core
```bash
# Full 84-match roster (`core_14` 42m + `unseen_12` 36m + `self_6` 6m):
# Use `-j 12` for full ALL_84 (24 < 32 threads, zero contention wall-ties) and `-j 14` for <= 26-match canaries!
python3 tools/run-local-sc2-arena.py \
  --opponents all --include-selfplay --selfplay-matches 6 \
  -j 12 --schedule-order lpt --mothman-mode source --tag iter<N>_full

# Tactics Arena 3.0 Core (Dummy + Self-Play, 132 full-length live-HUD MP4s)
python3 tools/sc2-tactics-arena.py --opponent dummy --suite core --jobs 6 --max-loops 960 \
  --render-dir <scratch>/loop/visuals_iter<N>/arena \
  --json <scratch>/loop/tactics_sc2_duel_iter<N>.json
python3 tools/sc2-tactics-arena.py --opponent self --suite core --jobs 6 --max-loops 960 \
  --render-dir <scratch>/loop/visuals_iter<N>/selfplay \
  --json <scratch>/loop/tactics_sc2_selfplay_iter<N>.json
```

### Step 4A/4B: One-Command Parallel Post-Bench Pipeline & `<15s` Forensics Diff
```bash
# One-command parallel post-bench (score, replay-db ingest + extract-raw, pro_deep, s2_features, trade_review_pack, forensics-diff, dashboard)
python3 tools/post-bench-pipeline.py /path/to/runs/<run_id> \
  --label iter<N>_full \
  --baseline-run /path/to/runs/<base_run_id> \
  --baseline-score <scratch>/<base_label>_score.json \
  --workers 8

# Fast parallel replay/log diff CLI (<15s; replace multi-command ad-hoc shell forensics!)
python3 tools/forensics-diff.py /path/to/runs/<new_run_id> /path/to/runs/<base_run_id> --race P --workers 8
```

### Step 4B — Pro Comparison, Replay-DB Ingestion & 3D Video Archival
```bash
# Pro-Corpus comparison
python3 tools/iteration-loop/compare-vs-pro.py \
  --current <scratch>/iter<N>_wave<N>_full_score.json \
  --baseline <scratch>/iter<BASE>_wave<BASE>_full_score.json \
  --hwm <scratch>/iter<HWM>_wave<HWM>_full_score.json \
  --tactics <scratch>/loop/tactics_sc2_duel_iter<N>.json \
  --exclude-opp-crash \
  --out-json <scratch>/loop/pro_comparison_iter<N>_wave<N>_full.json

# SQLite Replay-DB ingestion (ONLY after @analyzer confirms SQLite IDLE!)
python3 tools/replay-db.py ingest-runs --run <run_id_full> --score-json <scratch>/iter<N>_wave<N>_full_score.json
python3 tools/replay-db.py ingest-runs --run <run_id_h2h> --score-json <scratch>/iter<N>_baseline_h2h_score.json
python3 tools/replay-db.py extract-raw --run <run_id_full> -j 8
python3 tools/replay-db.py extract-raw --run <run_id_h2h> --include-game-events -j 6
python3 tools/replay-db.py stats
python3 tools/replay-db.py spawn-bias --source local_arena --since-run 20261121_022741_iter37 --min-games 2

# Full-length 90/90 match H.264 MP4 renders (SHIP-ZIP loops only!)
python3 tools/iteration-loop/render-replay-clips.py \
  --render-all-full-matches \
  --score-json <scratch>/iter<N>_wave<N>_full_score.json \
  --replays-dir /home/<user>/sc2-local-arena/runs/<run_id_full>/replays \
  --h2h-score-json <scratch>/iter<N>_baseline_h2h_score.json \
  --h2h-replays-dir /home/<user>/sc2-local-arena/runs/<run_id_h2h>/replays \
  --out-dir <scratch>/loop/visuals_iter<N>/full_matches \
  --full-step 20 --full-fps 16 --jobs 6
```

### Step 4C: Mandatory Self-Improving Trajectory & Open-Ended Bottleneck Audit (`< 3s` Offline!)
```bash
# 1. Log a shipped loop OR a held sub-iteration (e.g. 65C, 65G, 65H) into loop_trajectory_log.jsonl
python3 tools/iteration-loop/log-loop-trajectory.py --loop <N>
python3 tools/iteration-loop/log-loop-trajectory.py --sub-iter 65G --verdict HOLD-ZIP

# 2. Refresh Pareto, agent scorecard, flip-flop warnings, counterfactual simulator, and all 4 open-ended bottleneck detectors
python3 tools/iteration-loop/analyze-loop-flywheel.py \
  --out-md <scratch>/loop/loop_flywheel_retro.md \
  --out-json <scratch>/loop/loop_flywheel_retro.json

# 3. Verify flywheel, comparator & loop-speedup unit tests (runs in <2s, included in Gate 1!)
python3 -m unittest tests/test-loop-flywheel.py
python3 tests/test-loop-speedups.py
```

### Step 4D — Mandatory Post-Run Replay + Video Trade Review & Deep Pro Comparison
```bash
# 1. Arena worst-trade review pack (6-frame JPEG contact sheets + telemetry cards)
python3 tools/trade-review-pack.py \
  --tactics-json <scratch>/loop/tactics_sc2_duel_iter<N>.json \
  --video-dir <scratch>/loop/visuals_iter<N>/arena \
  --out-dir <scratch>/loop/trade_review_iter<N>_arena \
  --top 8

# 2. Real-match worst-trade review pack (decisive battle window contact sheets + SQLite cards)
python3 tools/trade-review-pack.py \
  --run-id <run_id_full> \
  --video-dir <scratch>/loop/visuals_iter<N>/full_matches \
  --out-dir <scratch>/loop/trade_review_iter<N>_matches \
  --top 8

# 3. Deep Pro vs. Mothman spatial, walling & timing comparison across all 9 matchups
python3 tools/pro-deep-comparison.py \
  --run-prefixes iter<N-3>,iter<N-2>,iter<N-1>,iter<N> \
  --out-json <scratch>/loop/pro_deep_comparison.json \
  --out-md <scratch>/loop/pro_deep_comparison.md \
  --jobs 8
```

**Required Handoff:** `@analyzer` opens `<out-dir>/trade_review_pack.md` AND visually inspects the generated `sheets/*.jpg` contact sheets before writing the next loop's combat or micro blueprint.
