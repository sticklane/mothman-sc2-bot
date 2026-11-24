#!/usr/bin/env python3
"""
Unit & read-only integration tests for Loop-Speedup Tooling Lane B:
  - tools/forensics-diff.py
  - tools/post-bench-pipeline.py

Runs cleanly without GPU/SC2, without touching any .rkt files, and writes ALL
test artifacts strictly inside TemporaryDirectory() so live repo files,
scratch/dashboard_state.json, data/racket_native_match_telemetry.jsonl, and
arena_replays.sqlite remain untouched.
"""
from __future__ import annotations

import importlib.util
import json
import os
import py_compile
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
FORENSICS_DIFF = REPO_ROOT / "tools" / "forensics-diff.py"
POST_BENCH = REPO_ROOT / "tools" / "post-bench-pipeline.py"

RUNS_ROOT = Path("/home/sjaconette/sc2-local-arena/runs")
H2H_65G = RUNS_ROOT / "20261124_041450_iter65g_h2h_12"
H2H_65F = RUNS_ROOT / "20261124_034735_iter65f_h2h_12"
FULL_65G = RUNS_ROOT / "20261124_042114_iter65g_ship17_full"
FULL_R16 = RUNS_ROOT / "20261123_190545_iter64b_ship16_full"


def _load_mod(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


class TestPostBenchPipelineTools(unittest.TestCase):
    def test_py_compile_both_scripts(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            py_compile.compile(str(FORENSICS_DIFF), cfile=str(Path(td) / "fd.pyc"), doraise=True)
            py_compile.compile(str(POST_BENCH), cfile=str(Path(td) / "pb.pyc"), doraise=True)

    def test_pair_run_matches_handles_race_rolls_and_multi_occurrence(self) -> None:
        fd = _load_mod("fd_unit_test", FORENSICS_DIFF)
        new_m = [
            {"match_id": 1, "bot1": "Mothman-P", "bot2": "BotA", "opp_race": "Protoss", "result": "win"},
            {"match_id": 2, "bot1": "Mothman-P", "bot2": "BotB", "opp_race": "Terran", "result": "loss"},
            {"match_id": 3, "bot1": "Mothman-P", "bot2": "BotB", "opp_race": "Terran", "result": "win"},
        ]
        base_m = [
            {"match_id": 1, "bot1": "Mothman-P", "bot2": "BotA", "opp_race": "Zerg", "result": "win"},
            {"match_id": 2, "bot1": "Mothman-P", "bot2": "BotB", "opp_race": "Terran", "result": "win"},
            {"match_id": 3, "bot1": "Mothman-P", "bot2": "BotB", "opp_race": "Terran", "result": "loss"},
        ]
        pairs = fd.pair_run_matches(new_m, base_m)
        self.assertEqual(len(pairs), 3)
        by_id = {p["new"]["match_id"]: p for p in pairs}
        self.assertTrue(by_id[1]["race_roll_changed"])
        self.assertFalse(by_id[2]["race_roll_changed"])
        self.assertEqual(by_id[2]["base"]["result"], "win")
        self.assertEqual(by_id[2]["new"]["result"], "loss")
        self.assertEqual(by_id[3]["base"]["result"], "loss")
        self.assertEqual(by_id[3]["new"]["result"], "win")

    def test_parse_bot1_log_summary_streaks(self) -> None:
        fd = _load_mod("fd_unit_test_log", FORENSICS_DIFF)
        with tempfile.TemporaryDirectory() as td:
            lp = Path(td) / "sample.log"
            lp.write_text(
                "\n".join(
                    [
                        "[SCBOT_STATE] f=100 matchup=PvP arch=sky-toss win=0.5",
                        "[SCBOT_PRIORITY] f=224 race=Protoss bank=100M/50G sup=20/23 bo=immortal saving_for=nexus(floor=400M/0G)",
                        "[SCBOT_PRIORITY] f=448 race=Protoss bank=200M/80G sup=22/23 bo=immortal saving_for=nexus(floor=400M/0G)",
                        "[SCBOT_PRIORITY] f=672 race=Protoss bank=300M/90G sup=24/31 bo=stalker saving_for=nexus(floor=400M/0G)",
                        "[SCBOT_PRIORITY] f=896 race=Protoss bank=50M/90G sup=25/31 bo=stalker saving_for=none(floor=0M/0G)",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            res = fd.parse_bot1_log_summary(str(lp))
            self.assertEqual(res["pri_lines"], 4)
            self.assertEqual(res["state_lines"], 1)
            self.assertEqual(res["top_saving_for"][0], ("nexus", 3))
            self.assertEqual(res["top_arch"][0], ("sky-toss", 1))
            streak = res["longest_saving_streak"]
            self.assertIsNotNone(streak)
            self.assertEqual(streak["item"], "nexus")
            self.assertEqual(streak["ticks"], 3)
            self.assertAlmostEqual(streak["start_sec"], 10.0, places=1)
            self.assertAlmostEqual(streak["end_sec"], 30.0, places=1)

    @unittest.skipUnless(H2H_65G.is_dir() and H2H_65F.is_dir(), "H2H_12 arena runs not present")
    def test_forensics_diff_on_h2h_runs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_md = Path(td) / "diff.md"
            out_json = Path(td) / "diff.json"
            t0 = time.monotonic()
            proc = subprocess.run(
                [
                    sys.executable,
                    str(FORENSICS_DIFF),
                    str(H2H_65G),
                    str(H2H_65F),
                    "--out-md",
                    str(out_md),
                    "--out-json",
                    str(out_json),
                    "--workers",
                    "8",
                    "--quiet",
                ],
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            elapsed = time.monotonic() - t0
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertLess(elapsed, 15.0)
            self.assertTrue(out_md.is_file())
            self.assertTrue(out_json.is_file())
            data = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertEqual(data["meta"]["paired_count"], 12)
            self.assertGreaterEqual(len(data["deep_w_to_l_flips"]), 1)
            first_f = data["deep_w_to_l_flips"][0]["new_forensics"]
            self.assertTrue(first_f["ok"])
            self.assertGreater(first_f["cmds"]["atk_total"] + first_f["cmds"]["move_total"], 0)
            self.assertIn("## W -> L Regressions", out_md.read_text(encoding="utf-8"))

    @unittest.skipUnless(FULL_65G.is_dir() and FULL_R16.is_dir(), "Full 84m arena runs not present")
    def test_forensics_diff_on_full_protoss_under_15s(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_md = Path(td) / "protoss_diff.md"
            out_json = Path(td) / "protoss_diff.json"
            t0 = time.monotonic()
            proc = subprocess.run(
                [
                    sys.executable,
                    str(FORENSICS_DIFF),
                    str(FULL_65G),
                    str(FULL_R16),
                    "--race",
                    "P",
                    "--out-md",
                    str(out_md),
                    "--out-json",
                    str(out_json),
                    "--workers",
                    "8",
                    "--quiet",
                ],
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            elapsed = time.monotonic() - t0
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            self.assertLess(elapsed, 15.0)
            data = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertEqual(data["meta"]["paired_count"], 26)
            self.assertEqual(len(data["flips_w_to_l"]), 5)
            self.assertEqual(len(data["deep_w_to_l_flips"]), 5)
            self.assertIsNotNone(data["by_race"]["Protoss"]["pro_deep_new"].get("reinf_pct"))

    def test_game_state_score_rendering_present_and_absent(self) -> None:
        pb = _load_mod("pb_unit_test_gs", POST_BENCH)
        with tempfile.TemporaryDirectory() as td:
            # 1) New score JSON with game_state_score (0..1 scale) and state/adjudicated outcomes
            new_sc = Path(td) / "new_score.json"
            new_sc.write_text(
                json.dumps(
                    {
                        "matches": [
                            {
                                "our_race": "Protoss",
                                "result": "win",
                                "is_selfplay": False,
                                "killed_val": 5000,
                                "lost_val": 2000,
                                "our_min_collected": 12000,
                                "opp_min_collected": 10000,
                                "our_gas_collected": 4000,
                                "opp_gas_collected": 3500,
                                "game_state_score": 0.72,
                                "state_outcome": "win",
                                "adjudicated_outcome": "win",
                            },
                            {
                                "our_race": "Protoss",
                                "result": "tie",
                                "is_selfplay": False,
                                "killed_val": 4000,
                                "lost_val": 3500,
                                "our_min_collected": 14000,
                                "opp_min_collected": 11000,
                                "our_gas_collected": 5000,
                                "opp_gas_collected": 4000,
                                "game_state_score": 0.64,
                                "state_outcome": "win",
                                "adjudicated_outcome": "win",
                            },
                        ]
                    }
                ),
                encoding="utf-8",
            )
            ov_new = pb._extract_score_overview(new_sc)
            self.assertIsNotNone(ov_new)
            self.assertAlmostEqual(ov_new["overall"]["mean_game_state_score"], 68.0, places=1)
            self.assertEqual(ov_new["overall"]["state_adjudicated_wlt"], "2-0-0")
            md_new = pb._render_board_summary(
                {
                    "label": "gs_test",
                    "run_dir": td,
                    "total_elapsed_sec": 1.23,
                    "all_ok": True,
                    "score_overview": ov_new,
                    "steps": [],
                }
            )
            self.assertIn("GameState `68.0/100`", md_new)
            self.assertIn("StateWLT `2-0-0`", md_new)

            # 2) Legacy score JSON without game_state_score keys
            old_sc = Path(td) / "old_score.json"
            old_sc.write_text(
                json.dumps(
                    {
                        "matches": [
                            {
                                "our_race": "Zerg",
                                "result": "win",
                                "is_selfplay": False,
                                "killed_val": 3000,
                                "lost_val": 1000,
                                "our_min_collected": 10000,
                                "opp_min_collected": 8000,
                                "our_gas_collected": 3000,
                                "opp_gas_collected": 2500,
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            ov_old = pb._extract_score_overview(old_sc)
            self.assertIsNone(ov_old["overall"]["mean_game_state_score"])
            self.assertIsNone(ov_old["overall"]["state_adjudicated_wlt"])
            md_old = pb._render_board_summary(
                {
                    "label": "legacy_test",
                    "run_dir": td,
                    "total_elapsed_sec": 0.5,
                    "all_ok": True,
                    "score_overview": ov_old,
                    "steps": [],
                }
            )
            self.assertNotIn("GameState", md_old)
            self.assertNotIn("StateWLT", md_old)

    @unittest.skipUnless(H2H_65G.is_dir() and H2H_65F.is_dir(), "H2H_12 arena runs not present")
    def test_post_bench_pipeline_isolated_h2h(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_root = Path(td) / "test_pipeline"
            tmp_db = out_root / "test_arena.sqlite"
            tmp_traj = out_root / "test_traj.jsonl"
            proc = subprocess.run(
                [
                    sys.executable,
                    str(POST_BENCH),
                    str(H2H_65G),
                    "--label",
                    "iter65g_h2h_smoke",
                    "--baseline-run",
                    str(H2H_65F),
                    "--out-root",
                    str(out_root),
                    "--replay-db",
                    str(tmp_db),
                    "--skip-dashboard",
                    "--log-trajectory",
                    "--trajectory-jsonl",
                    str(tmp_traj),
                    "--workers",
                    "8",
                ],
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, msg=f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
            self.assertNotIn("None%", proc.stdout)
            self.assertIn("# Post-Bench Pipeline Summary: `iter65g_h2h_smoke`", proc.stdout)

            loop_dir = out_root / "loop" / "iter65g_h2h_smoke"
            self.assertTrue((out_root / "iter65g_h2h_smoke_score.json").is_file())
            self.assertTrue((loop_dir / "s2_features.json").is_file())
            self.assertTrue((loop_dir / "compare_vs_pro.json").is_file())
            self.assertTrue((loop_dir / "pro_deep.json").is_file())
            self.assertTrue((loop_dir / "trade_review" / "trade_review_pack.md").is_file())
            self.assertTrue((loop_dir / "forensics_diff.md").is_file())
            self.assertTrue((loop_dir / "forensics_diff.json").is_file())
            self.assertTrue((loop_dir / "pipeline_summary.json").is_file())

            # Verify extract-raw populated raw_extracted_at for all 12/12 matches
            conn = sqlite3.connect(str(tmp_db))
            try:
                raw_cnt = conn.execute(
                    "SELECT COUNT(*) FROM matches WHERE raw_extracted_at IS NOT NULL"
                ).fetchone()[0]
            finally:
                conn.close()
            self.assertEqual(raw_cnt, 12)

            s2 = json.loads((loop_dir / "s2_features.json").read_text(encoding="utf-8"))
            self.assertEqual(s2["replays_total"], 12)
            self.assertEqual(s2["replays_ok"], 12)
            self.assertEqual(s2["replays_err"], 0)
            self.assertGreater(s2["p1_totals"]["SiegeTank"], 0)
            self.assertGreater(s2["p1_totals"]["Bile"], 0)
            self.assertGreater(s2["p1_totals"]["WarpPrism"], 0)
            self.assertGreater(s2["p1_totals"]["RALLY_WORKERS"], 0)

            ps = json.loads((loop_dir / "pipeline_summary.json").read_text(encoding="utf-8"))
            self.assertTrue(ps["all_ok"])
            step_names = {s["step"] for s in ps["steps"]}
            self.assertEqual(
                step_names,
                {
                    "score_replay_batch",
                    "s2_features",
                    "bot_log_telemetry",
                    "db_ingest",
                    "db_extract_raw",
                    "compare_vs_pro",
                    "pro_deep",
                    "trade_review_pack",
                    "forensics_diff",
                    "log_trajectory",
                },
            )
            blt = ps.get("bot_log_telemetry") or {}
            self.assertGreaterEqual(int(blt.get("logs_scanned") or 0), 12)
            self.assertEqual(int(blt.get("logs_err") or 0), 0)
            self.assertGreater(int((blt.get("apm_cap_drops") or {}).get("total") or 0), 0)
            self.assertEqual(int((blt.get("health") or {}).get("crash_games") or 0), 0)
            self.assertIn("- **Health & Ties:**", proc.stdout)
            self.assertIn("- **`[APM_CAP_DROPS]`", proc.stdout)
            self.assertIn("- **`[SCBOT_ARBITER]`", proc.stdout)

    @unittest.skipUnless(FULL_65G.is_dir(), "Full 84m arena run not present")
    def test_post_bench_pipeline_extract_raw_populates_pro_deep_nonzero_rows(self) -> None:
        """Build a tiny 2-match external run in /tmp and assert extract-raw feeds non-zero pro_deep rows."""
        rj = json.loads((FULL_65G / "results.json").read_text(encoding="utf-8"))
        # Pick 2 real external matches >= 400s for fast (<8s) end-to-end verification
        picked = []
        for m in rj.get("matches", []):
            if m.get("cohort") == "self":
                continue
            rp = Path(m.get("replay_path") or "")
            if not rp.is_absolute():
                rp = FULL_65G / rp
            if rp.is_file() and float(m.get("game_minutes") or 0) >= 7.0:
                picked.append((m, rp))
                if len(picked) == 2:
                    break
        if len(picked) < 2:
            self.skipTest("Could not find 2 external >=7m replays in FULL_65G")

        with tempfile.TemporaryDirectory() as td:
            runs_parent = Path(td) / "runs"
            mini_run = runs_parent / "20261124_000000_mini_ext2"
            (mini_run / "replays").mkdir(parents=True)
            (mini_run / "logs").mkdir(parents=True)
            mini_matches = []
            for m, rp in picked:
                dst_rp = mini_run / "replays" / rp.name
                os.symlink(rp, dst_rp)
                m_copy = dict(m)
                m_copy["replay_path"] = str(dst_rp)
                for lk in ("our_log_path", "opp_log_path", "controller_log_path"):
                    lp_raw = m.get(lk)
                    if lp_raw and Path(lp_raw).is_file():
                        dst_lp = mini_run / "logs" / Path(lp_raw).name
                        if not dst_lp.exists():
                            os.symlink(lp_raw, dst_lp)
                        m_copy[lk] = str(dst_lp)
                mini_matches.append(m_copy)
            (mini_run / "results.json").write_text(
                json.dumps({"run_id": mini_run.name, "matches": mini_matches}, indent=2),
                encoding="utf-8",
            )
            (mini_run / "summary.json").write_text(
                json.dumps({"run_id": mini_run.name, "totals": {"matches": len(mini_matches)}}),
                encoding="utf-8",
            )

            out_root = Path(td) / "out"
            tmp_db = out_root / "mini.sqlite"
            proc = subprocess.run(
                [
                    sys.executable,
                    str(POST_BENCH),
                    str(mini_run),
                    "--label",
                    "mini_ext2",
                    "--out-root",
                    str(out_root),
                    "--replay-db",
                    str(tmp_db),
                    "--skip-dashboard",
                    "--workers",
                    "4",
                ],
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, msg=f"STDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}")
            pd_path = out_root / "loop" / "mini_ext2" / "pro_deep.json"
            self.assertTrue(pd_path.is_file())
            pd = json.loads(pd_path.read_text(encoding="utf-8"))
            meta = pd.get("meta") or {}
            total_mm = int(meta.get("mothman_games_total") or 0)
            self.assertGreaterEqual(total_mm, 2, msg=f"Expected >=2 pro_deep mothman_games_total, got {meta}")
            self.assertGreaterEqual(int(meta.get("mothman_army_group_games_total") or 0), 2)
            self.assertGreaterEqual(int(meta.get("mothman_rows_matched") or 0), 2)
            # Verify at least one race has non-null AG metrics
            has_ag = False
            for body in (pd.get("by_race") or {}).values():
                ag = ((body or {}).get("mothman") or {}).get("army_group_positioning") or {}
                if ag.get("reinforce_linked_pct") is not None:
                    has_ag = True
            self.assertTrue(has_ag, msg="Expected non-null army_group_positioning in pro_deep.json after extract-raw")

    def test_parse_run_bot_logs_synthetic_match_dirs_and_board_summary(self) -> None:
        pb = _load_mod("pb_unit_test_logs", POST_BENCH)
        with tempfile.TemporaryDirectory() as td:
            run_dir = Path(td) / "20261124_090000_synth_run"
            m1 = run_dir / "match_001"
            m2 = run_dir / "match_002"
            m3 = run_dir / "match_003"
            for d in (m1, m2, m3):
                d.mkdir(parents=True)

            # Match 1: populated [SCBOT_ARBITER] + [APM_CAP_DROPS] + [SCBOT_BUILD] on bot1,
            # plus Mothman selfplay bot2 with empty [SCBOT_ARBITER] (by_reason=none top=none)
            (m1 / "bot1.log").write_text(
                "\n".join(
                    [
                        "[SCBOT_BUILD] bot=Mothman-T race=Terran version=tlrrltvx_ea56f6f1 mode=zip",
                        "[APM_CAP_DROPS] total=1000 tok=950 cap=50 P0=40 P1=60 P2=850 P3=45 P4=5 top=23:400,3666:120,3685:200,558:80",
                        "[SCBOT_ARBITER] total=17 by_reason=budget-mineral:10,budget-gas:7 top=l2-macro-runtime:budget-mineral:10,l2-macro-runtime:budget-gas:7",
                        "[SCBOT_ACTION_ERR] f=224 CantBuildLocationInvalid=2 total=2",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            (m1 / "bot2.log").write_text(
                "\n".join(
                    [
                        "[SCBOT_BUILD] bot=Mothman-T-SP race=Terran version=tlrrltvx_ea56f6f1 mode=zip",
                        "[APM_CAP_DROPS] total=500 tok=500 cap=0 P0=10 P1=20 P2=450 P3=20 P4=0 top=16:300,558:40",
                        "[SCBOT_ARBITER] total=0 by_reason=none top=none",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            # Match 2: populated bot1 + non-Mothman opponent bot2 (must NOT be scanned!)
            (m2 / "bot1.log").write_text(
                "\n".join(
                    [
                        "[SCBOT_BUILD] bot=Mothman-P race=Protoss version=dev mode=source",
                        "[APM_CAP_DROPS] total=250 tok=250 cap=0 P0=5 P1=10 P2=235 P3=0 P4=0 top=3666:30,23:100",
                        "[SCBOT_ARBITER] total=5 by_reason=budget-mineral:3,facility-busy:2 top=l2-macro-runtime:budget-mineral:3,l2-macro-runtime:facility-busy:2",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            (m2 / "bot2.log").write_text(
                "OpponentBot crash error: simulated opponent exception\n",
                encoding="utf-8",
            )

            # Match 3: Mothman log with an arbiter runtime exception line
            (m3 / "bot1.log").write_text(
                "\n".join(
                    [
                        "[SCBOT_BUILD] bot=Mothman-Z race=Zerg version=dev mode=source",
                        "arbiter contract violation error at step 440",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            res = pb.parse_run_bot_logs(run_dir, workers=4)
            self.assertTrue(res["ok"])
            self.assertEqual(res["step"], "bot_log_telemetry")
            blt = res["payload"]
            self.assertEqual(blt["logs_scanned"], 4)
            self.assertEqual(blt["logs_ok"], 4)
            self.assertEqual(blt["logs_err"], 0)
            self.assertEqual(blt["build_games_logged"], 4)
            self.assertEqual(blt["build_versions"], {"dev": 2, "tlrrltvx_ea56f6f1": 2})
            self.assertEqual(blt["build_modes"], {"source": 2, "zip": 2})

            apm = blt["apm_cap_drops"]
            self.assertEqual(apm["games_logged"], 3)
            self.assertEqual(apm["total"], 1750)
            self.assertEqual(apm["tok"], 1700)
            self.assertEqual(apm["cap"], 50)
            self.assertEqual(apm["priorities"], {"P0": 55, "P1": 90, "P2": 1535, "P3": 65, "P4": 5})
            self.assertEqual(apm["key_abilities"], {"3666": 150, "3685": 200, "558": 120})
            self.assertEqual(apm["top_abilities"][0], ["23", 500])

            arb = blt["arbiter"]
            self.assertEqual(arb["games_logged"], 3)
            self.assertEqual(arb["total"], 22)
            self.assertEqual(
                arb["by_reason"],
                {"budget-mineral": 13, "budget-gas": 7, "facility-busy": 2},
            )
            self.assertEqual(arb["top_pairs"][0], ["l2-macro-runtime:budget-mineral", 13])
            self.assertEqual(arb["errors"], 1)

            hlth = blt["health"]
            self.assertEqual(hlth["crash_games"], 1)
            self.assertEqual(hlth["wire_rejects"], 2)

            # Verify ties (cap25 vs wallTies) + health extraction and board rendering
            sc_path = Path(td) / "score.json"
            sc_path.write_text(
                json.dumps(
                    {
                        "matches": [
                            {
                                "our_race": "Terran",
                                "result": "tie",
                                "tie_cause": "loop_cap_25m",
                                "is_selfplay": False,
                                "killed_val": 3000,
                                "lost_val": 4000,
                                "our_min_collected": 10000,
                                "opp_min_collected": 12000,
                                "our_gas_collected": 3000,
                                "opp_gas_collected": 3500,
                                "game_state_score": 0.25,
                                "state_outcome": "loss",
                                "adjudicated_outcome": "loss",
                                "avg_step_ms": 12.0,
                                "p95_step_ms": 20.0,
                                "max_step_ms": 150.0,
                                "crashes": [],
                                "action_rejects": 0,
                                "anomalies": {"self_cancel_loops": []},
                            },
                            {
                                "our_race": "Protoss",
                                "result": "tie",
                                "tie_cause": "cpu_wall_timeout",
                                "wall_timeout_tie": True,
                                "is_selfplay": False,
                                "killed_val": 6000,
                                "lost_val": 3000,
                                "our_min_collected": 14000,
                                "opp_min_collected": 11000,
                                "our_gas_collected": 4000,
                                "opp_gas_collected": 3000,
                                "game_state_score": 0.85,
                                "state_outcome": "win",
                                "adjudicated_outcome": "win",
                                "avg_step_ms": 14.0,
                                "p95_step_ms": 24.0,
                                "max_step_ms": 190.0,
                                "crashes": [],
                                "action_rejects": 2,
                                "anomalies": {"self_cancel_loops": [{"unit": "hatchery"}]},
                            },
                        ]
                    }
                ),
                encoding="utf-8",
            )
            sc_ov = pb._extract_score_overview(sc_path)
            self.assertEqual(sc_ov["ties"], {"total": 2, "cap25": 1, "wall_ties": 1, "other": 0})
            self.assertEqual(sc_ov["health"]["crashes"], 0)
            self.assertEqual(sc_ov["health"]["wire_rejects"], 2)
            self.assertEqual(sc_ov["health"]["self_cancel"], 1)
            self.assertAlmostEqual(sc_ov["health"]["avg_step_ms"], 13.0, places=2)
            self.assertAlmostEqual(sc_ov["health"]["max_step_ms"], 190.0, places=1)

            md = pb._render_board_summary(
                {
                    "label": "synth_run",
                    "run_dir": str(run_dir),
                    "total_elapsed_sec": 3.5,
                    "all_ok": True,
                    "score_overview": sc_ov,
                    "bot_log_telemetry": blt,
                    "steps": [],
                }
            )
            self.assertIn("ties=`2` (`cap25=1`, `wallTies=1`)", md)
            self.assertIn("crashes=`1`", md)
            self.assertIn("wire_rejects=`2`", md)
            self.assertIn("self_cancel=`1`", md)
            self.assertIn("`[APM_CAP_DROPS]` (`3g`):** total=`1,750`", md)
            self.assertIn("`3666=150 3685=200 558=120`", md)
            self.assertIn(
                "`[SCBOT_ARBITER]` (`3g`):** total=`22` | errors=`1` | by_reason=`budget-mineral:13,budget-gas:7,facility-busy:2`",
                md,
            )


if __name__ == "__main__":
    unittest.main()
