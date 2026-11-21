# Mothman SC2 Autonomous Improvement Loop — Swarm Playbook v2.0 (Trajectory Flywheel Edition)

Operational playbook for running, gating, shipping, and continuously self-improving the multi-agent closed-loop optimization bench for `mothman-sc2-bot` (complements [`README.md`](./README.md)).

> **v2.0 Flywheel Upgrade (Backed by Loops 19–47 Empirical Trajectory Audit):**
> Every rule below is empirically derived from `31,701+` logged agent steps across `12` swarm transcripts (`loop_trajectory_log.jsonl`). Adopting `H2H-First` fail-fast gating, Gate 1 Brain↔Runtime contract checks, `25s` targeted Arena pre-checks, pre-granted sibling test ownership, and Step 4C automatic trajectory logging cuts wall time per live Ship by **`~30%` (`1.44×` throughput)** and lifts Gate-2 Ship Rate from **`43% → 55–67%`**.

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
| `@analyzer` | Live AI Arena `sync-prod`, SQLite forensics, root-cause audits, strictly-disjoint next-loop blueprints, qualitative trajectory audits | `tools/score-replay-batch.rkt`, `scratch/loop/*_audit.md` | Owns SQLite during Step 4A (`sync-prod`) |
| `@loop-architect` | Pro-Corpus comparison, `loop_ledger.json`, 3D Live-HUD MP4 highlights & Ship `90/90` full-match videos, SQLite ingestion, Arena 3.0 catalog/harness, **Step 4C Trajectory Flywheel** | `tools/iteration-loop/*`, `tools/sc2-tactics-arena.py`, `tools/arena-scenarios.json`, `.agents/skills/add-arena-scenario/**`, `tools/replay-db.py`, `tests/test-replay-db.py`, `tests/test-loop-flywheel.py` | Owns SQLite during Step 4B (`ingest-runs` + `extract-raw`) |
| `@reporter` | Living visual campaign report, phase log, GitHub Pages & Release media publishing | `tools/publish-gh-pages.py` (when directed), `scratch/loop/phase_reports.md`, campaign report artifact | Never blocks handoffs |
| `@monitor-2` | Low-frequency stall watchdog (adaptive backoff during active GPU/benchmark phases to minimize empty polling turns) | None | Read-only |

### Pre-Granted Ownership Rule (Eliminates Ownership Ping-Pongs)
Authors do **not** need to pause coding to ask `@coordinator` for permission to update historical tests inside their own pre-granted column above when a new loop explicitly supersedes an older threshold. Any cross-track file edit (e.g., `@wire-author` touching `lib/bot-runtime.rkt`) still requires explicit `@coordinator` approval.

---

## 2. Fail-Fast Closed-Loop State Machine (v2.0)

```text
[Step 1: Parallel Disjoint Coding — @runtime-author || @belief-author || @wire-author]
   - Pre-granted track test ownership; authors run targeted module tests (--skip-perf while GPU renders run)
   - Mandatory Main-Army Negative Guard test on every new global runtime heuristic
   - Mandatory Brain <-> Runtime Cap & Urgency parity check on every new production/tech cap
          |
          v
[Step 2: Gate 1 Solo Verification — @verifier (~2m, CPU idle, ZERO Podman/SC2)]
   - 10/10 gates: raco make, run-all-tests (incl. Brain<->Runtime contract + Suite 28 <5ms),
     sc2-protobuf-ws-test (incl. w5-p0-1a <4.5ms), typed-commands-test, l31..lN runtime suites,
     belief verifiers, tactics-unit-tester --all --strict, state-machine-verifier,
     pro starvation (0/0/0/0) & divergence, Python/Arena-3.0/Replay-DB/Flywheel tests, hygiene=0
          |
          v
[Step 3a: FAIL-FAST GATE 2A — Targeted 25s Arena Pre-Check + 2m H2H-First (~2.5m GPU)]
   1) If any Flip-Flop-Guarded micro scenario was edited -> @tactics-tester runs 25s `--scenario`/`--category` A/B FIRST!
      (Abort immediately to Step 1 if targeted scenario regresses — saves ~40m!)
   2) @harness runs 6-match `baseline_h2h` vs currently live Ship BotZips (~2m GPU) FIRST!
      - FAIL-FAST ABORT: If `baseline_h2h` finishes `<= 3W-3L` OR any race drops `0-2` ->
        immediate `HOLD-ZIP`! Skip the 30m 84-match roster -> go straight to Step 4A forensics (saves ~29m/HOLD!).
      - PASS (`>= 4W-2L`, no race collapse) -> proceed to full Gate 2B!
          |
          v
[Step 3b: FULL GATE 2B — Tactics Arena 3.0 Core (132 MP4s, ~6m) + 84-Match Roster (~29m)]
   - @tactics-tester: `--suite core` Dummy (66) + Self-Play (66) = 132 full-length live-HUD MP4s
   - @harness: 84-match roster (`core_14` 42m + `unseen_12` 36m + `self_6` 6m)
   - If Ship Gate passes -> @coordinator rebuilds 4 BotZips -> @harness 4-race ELF ZIP smoke (~2.5m) -> LIVE SHIP!
          |
          v
[Step 4A || Step 4B || Step 4C — Parallel Post-Benchmark Forensics, Archival & Flywheel]
   - Step 4A (@analyzer, owns SQLite first): `sync-prod` + live AI Arena audit + next-loop disjoint blueprint -> clears SQLite
   - Step 4B (@loop-architect, owns GPU): `compare-vs-pro.py`, `loop_ledger.json`, Top-8 live-HUD MP4s
     (+ ALL 90/90 full-length MP4s & `visual_report_iterN.md` on SHIP-ZIP loops; skip 90/90 on HOLD-ZIP!),
     SQLite `ingest-runs` + `extract-raw` once `@analyzer` clears SQLite
   - Step 4C (@loop-architect, <3s offline): `log-loop-trajectory.py --loop <N>` + `analyze-loop-flywheel.py`
     -> appends Loop N trajectory to `loop_trajectory_log.jsonl` & refreshes `scratch/loop/loop_flywheel_retro.{md,json}`
     -> feeds Flip-Flop warnings & top friction fixes directly into `@coordinator`'s Loop-(N+1) brief!
   - (@reporter on SHIP-ZIP): updates living report & publishes GitHub Pages / Releases non-blockingly!
```

---

## 3. Hard Flywheel Guardrails (Derived from Loops 19–47)

1. **Exclusive GPU & SQLite Locks:** Never run `podman`, host `SC2_x64` rendering, or `sc2-tactics-arena.py` concurrently. Never write to `arena_replays.sqlite` while `@analyzer` runs `sync-prod`. Always verify `PODMAN_AFTER=0, SC2_AFTER=0` (`pgrep -cf '[p]odman'`, `pgrep -cf '[S]C2_x64'`).
2. **Flip-Flop Guard (`<= 3`-Loop Churn Rule):** Whenever `analyze-loop-flywheel.py` flags a scenario or subsystem as touched in `>= 2` of the last `3` loops (e.g., `r02/r05/r06`, `e01`, `rd01`, `ro09`, `0`-Colossus), **no threshold change may be submitted without a `25s` `--scenario` A/B proof** (or closed-loop multi-frame macro trace in Gate 1).
3. **Brain ↔ Runtime Contract Parity:** Every macro cap or priority rule in `lib/priority-macro-brain.rkt` MUST match `lib/bot-runtime.rkt`'s execution ceiling (preventing silent `prod_placement_stall=132` split-brains) and preserve urgency partial orders (e.g., `colossus > phoenix > stalker`, `colossus > immortal` when `colossus = 0`).
4. **Main-Army Negative Guard Mandate:** Any global runtime heuristic added to `lib/bot-runtime.rkt` or `lib/tactics/pro-spellcaster-micro.rkt` (e.g., light-harass splits, Blink-Forward, worker-focus multipliers) MUST ship with a negative unit test proving it does **not** fire during parity/outnumbered frontal clashes or unsiege defensive Tanks.
5. **Solo Perf Gate Discipline:** While `@loop-architect` runs heavy H.264 3D renders (`loadavg > 8`), authors run targeted functional unit tests and defer wall-clock microbenches (`Suite 28 <5ms`, `w5-p0-1a <4.5ms`) to `@verifier`'s solo Gate 1 pass.
6. **Zero Hacks & Calm Copy:** Zero opponent-name hacks, map-name hacks, replay-ID branches, or speed-mining. Reader-facing reports use calm, plain-English prose. Never commit credentials or personal paths into tracked repo files.

---

## 4. Exact Modern Commands (Loops 45+)

Run all commands from the `mothman-sc2-bot/` repository root (using `jj` as default VCS):

### Step 3a — Targeted `25s` Arena Pre-Check & `2m` `H2H-First` Fail-Fast Gate
```bash
# Targeted Arena 3.0 pre-check on edited scenarios/categories (~25s)
python3 tools/sc2-tactics-arena.py --opponent dummy --category runby-offense --jobs 6 --max-loops 960
python3 tools/sc2-tactics-arena.py --opponent self --scenario r02,r05,r06 --jobs 3 --max-loops 960

# H2H-First Ship Gate vs currently live BotZips (~2m, fail-fast before 84-match roster!)
python3 tools/run-local-sc2-arena.py \
  --run-name iter<N>_baseline_h2h \
  --baseline-h2h \
  --mothman-mode source
```

### Step 3b — Full Tactics Arena 3.0 Core (`66×2 = 132` MP4s) & `84`-Match Roster
```bash
# Tactics Arena 3.0 Core (Dummy + Self-Play, 132 full-length live-HUD MP4s)
python3 tools/sc2-tactics-arena.py --opponent dummy --suite core --jobs 6 --max-loops 960 \
  --render-dir <scratch>/loop/visuals_iter<N>/arena \
  --json <scratch>/loop/tactics_sc2_duel_iter<N>.json
python3 tools/sc2-tactics-arena.py --opponent self --suite core --jobs 6 --max-loops 960 \
  --render-dir <scratch>/loop/visuals_iter<N>/selfplay \
  --json <scratch>/loop/tactics_sc2_selfplay_iter<N>.json

# Full 84-match roster (`core_14` 42m + `unseen_12` 36m + `self_6` 6m)
python3 tools/run-local-sc2-arena.py \
  --run-name iter<N>_wave<N>_full \
  --roster full_84 \
  --mothman-mode source
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

### Step 4C — Mandatory Self-Improving Loop Trajectory Flywheel (`< 3s` Offline!)
```bash
# 1. Stream swarm transcripts + ledger + read-only SQLite -> upsert Loop <N> into loop_trajectory_log.jsonl
python3 tools/iteration-loop/log-loop-trajectory.py --loop <N>

# 2. Refresh empirical Pareto, agent scorecard, flip-flop warnings & counterfactual simulator
python3 tools/iteration-loop/analyze-loop-flywheel.py \
  --out-md <scratch>/loop/loop_flywheel_retro.md \
  --out-json <scratch>/loop/loop_flywheel_retro.json

# 3. Verify flywheel unit tests (runs in <1s, included in Gate 1!)
python3 tests/test-loop-flywheel.py
```
