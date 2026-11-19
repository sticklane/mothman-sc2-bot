# Mothman SC2 Closed-Loop Autonomous Iteration Framework

This directory defines the durable multi-track closed-loop improvement cycle for `mothman-sc2-bot`. Every loop fuses **real-`SC2_x64` parallel gauntlet replays**, **deterministic + real-SC2 tactical unit tests**, and **298-replay LotV Pro Corpus baselines** to derive generalized game-physics / macro / combat improvements — never opponent-specific hacks or brittle band-aids.

---

## 1. Closed-Loop Pipeline (5 Phases + Live `@reporter`)

```
[Phase 1: Parallel Evaluation (~8.5-10m wall time)]
   @harness (real SC2 36-match gauntlet, default `-j 14 --network none --stagger-sec 0.25 --schedule-order interleaved --mothman-mode source`)
     ||  @tactics-tester (tactics suite `tools/tactics-unit-tester.rkt` ~0.7s + real-SC2 `tools/sc2-tactics-arena.py` ~13s + newly invented scenarios)
        |                                            |
        v  (+ @reporter)                             v  (+ @reporter)
[Phase 2: Fast Single-Pass Analysis (< 2s script, 1-2 turns)]
   @analyzer -> `racket tools/score-replay-batch.rkt --anomalies --compare <prev.json> --json <cur.json> <run_dir>`
        |
        v  (+ @reporter)
[Phase 3: Post-Analysis Generalization & Pro-Data Comparison]
   @loop-architect -> `python3 tools/iteration-loop/compare-vs-pro.py --current <cur.json> --baseline <prev.json> --tactics <tactics.json> --out-json <cmp.json>`
   - Fuse gauntlet v2 JSON + tactical scorecard + Pro Corpus baselines (`pro_baselines.json`)
   - Update `tools/iteration-loop/loop_ledger.json` & `scratch/loop/loop_ledger.json`
   - If ALL Promotion Gates PASS -> notify @coordinator to build zips & deploy
   - Else -> distill generalized Wave-(N+1) Spec with strict disjoint file ownership -> kick off authors!
        |
        v  (+ @reporter)
[Phase 4: Parallel Disjoint-Ownership Implementation]
   @runtime-author  : `lib/bot-runtime.rkt` (read-only elsewhere)
   @belief-author   : `lib/{opponent-world-model,mirror-mind-predictor,econ-ledger,priority-macro-brain}.rkt`
   @wire-author     : `lib/sc2-protobuf-ws.rkt`, `tests/sc2-protobuf-ws-test.rkt`
   *Rule: NEVER run `raco make` on another author's files during parallel edits; hand off directly to @verifier.*
        |
        v  (+ @reporter)
[Phase 5: Verification Gate]
   @verifier -> 5 Mandatory Gates + `tools/tactics-unit-tester.rkt` + Generality & Repo Hygiene Audit
   - PASS -> trigger Phase 1 (`@harness` + `@tactics-tester`) + `@reporter`
   - FAIL -> bounce failing gate directly to owning author
```

### Mandatory `@reporter` Integration (Non-Blocking)
At the end of **every phase**, the completing agent tags **both** the next phase owner(s) **and** `@reporter` in the same board post. Never stall a handoff waiting for `@reporter`; `@reporter` updates `scratch/loop/phase_reports.md` and surfaces a crisp `[phase-report]` bulletin to `@coordinator` in parallel.

---

## 2. Artifacts & Tooling

| File | Owner | Purpose |
|---|---|---|
| `tools/iteration-loop/pro_baselines.json` | `@loop-architect` | Canonical Pro LotV medians by Race & all 9 Matchups (`W@2/4/6/8/10m`, `Nat@`, `3rd@`, `Gas1/2@`, `Prod1@`, `Tech1@`, `ArmyVal/Worker@6m`, macro laws). |
| `tools/iteration-loop/compare-vs-pro.py` | `@loop-architect` | Fast (`< 1s`) comparator fusing `@analyzer` v2 JSON + `@tactics-tester` JSON vs `pro_baselines.json`, flagging systemic divergences & evaluating Promotion Gates. |
| `tools/iteration-loop/loop_ledger.json` | `@loop-architect` | Durable repo ledger tracking every iteration wave, git/jj rev, gauntlet scorecard, pro gaps, tactical score, and Wave spec. |
| `tools/score-replay-batch.rkt` | `@analyzer` | Single-pass compiled Racket scorer (`~1.3s` for 36 matches) with automatic anomaly detectors (`zero_fire_retreat`, `escrow_lockouts`, `self_cancel_loops`, `endgame_stall`, `air_aa_starvation`). |
| `tools/tactics-unit-tester.rkt` | `@tactics-tester` | Deterministic tactical scenario suite covering core micro/tactics + failure regressions + newly invented pro-inspired stress scenarios. |
| `scratch/loop/phase_reports.md` | `@reporter` | Append-only cumulative phase bulletin & running scorecard. |

---

## 3. Generalization & Generality Rules (Enforced by `@loop-architect` & `@verifier`)

1. **Zero Opponent-Name Hacks**: Never branch on opponent bot name, map name, or replay ID.
2. **Zero Speed-Mining**: Preserve clean legal harvesting without micro-exploit deceleration bypasses.
3. **General Physics / Macro / Game-Rule Laws Only**: Every fix must express a race-general or game-physics invariant (e.g. unit conversion, stutter-step cooldown discipline, win-condition building definitions, gas-bottleneck escrow liquidity, pro matchup expansion timing).
4. **Formal & Pro-Alignment Safety**: Every wave must pass all 5 mandatory gates (`raco make`, `state-machine-verifier.rkt` 24/24 invariants, `sc2-protobuf-ws-test.rkt`, `run-all-tests.rkt`, `audit-pro-replay-starvation.rkt`) plus `benchmark-pro-divergence.rkt --spatial` with zero regressions.

---

## 4. Explicit Promotion / Ship Criteria (`ready_to_promote`)

`@loop-architect` notifies `@coordinator` to finalize zips & deploy when **all 9 gates** pass on a clean 36-match parallel gauntlet + tactical suite:
1. `zero_crashes_and_rejects`: `0` Mothman crashes, `0` SC2 `ActionReject`s
2. `overall_wr_ge_50pct`: Clean win rate `>= 50.0%` (`>= 18/36` wins)
3. `overall_trade_agg_ge_1_0x`: Aggregate trade ratio `>= 1.00x`
4. `overall_trade_med_ge_0_85x`: Median per-match trade ratio `>= 0.85x`
5. `ties_le_2`: `<= 2` ties across 36 matches (`0` winning-position endgame stalls)
6. `sup_blk_le_6pct`: Average supply block `<= 6.0%`
7. `every_race_wr_ge_33pct`: Each of `Protoss`, `Terran`, `Zerg` at `>= 33.3%` WR
8. `every_race_w4_within_6_of_pro`: Alive-median `W@4m` within `-6.0` workers of Pro median for every race
9. `tactics_suite_100pct`: `100%` pass rate on `tools/tactics-unit-tester.rkt` (including all regression + newly invented scenarios)
