#!/usr/bin/env python3
"""Unit and smoke tests for repeatable loop-speedup tooling:
  - tools/run-local-sc2-arena.py (LPT scheduling, canary preset, --list/--dry-run, results.json schema)
  - tools/racket-lane-test.sh (isolated PLTCOMPILEDROOTS compile/test + guaranteed /tmp cleanup)
"""

from __future__ import annotations

import argparse
import glob
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


REPO_ROOT = Path(__file__).resolve().parent.parent
ARENA_RUNNER_PATH = REPO_ROOT / "tools" / "run-local-sc2-arena.py"
LANE_SCRIPT_PATH = REPO_ROOT / "tools" / "racket-lane-test.sh"


def load_arena_runner_module():
    spec = importlib.util.spec_from_file_location("run_local_sc2_arena", ARENA_RUNNER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["run_local_sc2_arena"] = mod
    spec.loader.exec_module(mod)
    return mod


def make_synthetic_arena(root: Path, opp_specs: list[dict]) -> Path:
    bots_dir = root / "bots"
    maps_dir = root / "maps"
    bots_dir.mkdir(parents=True, exist_ok=True)
    maps_dir.mkdir(parents=True, exist_ok=True)
    for entry in opp_specs:
        bdir = bots_dir / entry["name"]
        bdir.mkdir(parents=True, exist_ok=True)
        (bdir / "run.py").write_text("# stub\n", encoding="utf-8")
    (bots_dir / "roster.json").write_text(json.dumps(opp_specs, indent=2), encoding="utf-8")
    for m in ("MagannathaAIE_v2", "PersephoneAIE_v4", "PylonAIE_v4"):
        (maps_dir / f"{m}.SC2Map").write_bytes(b"stub")
    return root


class LoopSpeedupsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runner = load_arena_runner_module()

    def test_py_compile_run_local_sc2_arena(self) -> None:
        py_compile.compile(str(ARENA_RUNNER_PATH), doraise=True)

    def test_default_max_game_time_is_25m_local_cap(self) -> None:
        # Temporary local-loop 25-min cap (33600 = 25 * 60 * 22.4 loops)
        runner_src = ARENA_RUNNER_PATH.read_text(encoding="utf-8")
        self.assertIn('"--max-game-time", type=int, default=33600', runner_src)
        res = subprocess.run(
            [sys.executable, str(ARENA_RUNNER_PATH), "--bots", "Mothman-P", "--opponents", "canary", "--dry-run"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("max_game_time=33600", res.stdout)

    def test_lpt_builtin_slow_tier_ordering_and_backward_compat(self) -> None:
        sample_roster_entries = [
            {"name": "12PoolBot", "race": "Z", "type": "python", "elo": 1100, "gauntlet_core": True},
            {"name": "zig-reapers", "race": "T", "type": "python", "elo": 1150, "gauntlet_core": False},
            {"name": "RustyNikolaj", "race": "T", "type": "python", "elo": 1200, "gauntlet_core": True},
            {"name": "onlyfans", "race": "P", "type": "python", "elo": 1250, "gauntlet_core": False},
            {"name": "mini-puck", "race": "P", "type": "python", "elo": 1300, "gauntlet_core": True},
            {"name": "Clicadinha", "race": "Z", "type": "python", "elo": 1350, "gauntlet_core": False},
            {"name": "puck", "race": "P", "type": "python", "elo": 1400, "gauntlet_core": True},
            {"name": "AxeFighter", "race": "T", "type": "python", "elo": 1450, "gauntlet_core": False},
            {"name": "QueenBot", "race": "Z", "type": "python", "elo": 1500, "gauntlet_core": False},
        ]
        with tempfile.TemporaryDirectory(prefix="arena_lpt_builtin_") as td:
            arena_dir = make_synthetic_arena(Path(td), sample_roster_entries)
            roster = self.runner.load_roster(arena_dir / "bots")
            maps = self.runner.discover_maps(arena_dir / "maps", "all")

            args_lpt = argparse.Namespace(
                match_file=None,
                bots="Mothman-P",
                opponents="all",
                include_selfplay=False,
                matches_per_pair=1,
                mothman_mode="zip",
                schedule_order="lpt",
            )
            tasks_lpt = self.runner.build_match_tasks(
                args_lpt, roster, maps, arena_dir, REPO_ROOT, stage_mothman=False
            )
            ordered_opps = [t.bot2.name for t in tasks_lpt]
            expected_slow_prefix = [
                "QueenBot",
                "AxeFighter",
                "puck",
                "Clicadinha",
                "mini-puck",
                "onlyfans",
                "RustyNikolaj",
            ]
            self.assertEqual(ordered_opps[: len(expected_slow_prefix)], expected_slow_prefix)
            self.assertEqual(set(ordered_opps[len(expected_slow_prefix) :]), {"12PoolBot", "zig-reapers"})

            # Interleaved and sequential remain backward-compatible (elo-sorted opponents)
            args_inter = argparse.Namespace(**{**vars(args_lpt), "bots": "Mothman-Z,Mothman-P", "schedule_order": "interleaved"})
            tasks_inter = self.runner.build_match_tasks(
                args_inter, roster, maps, arena_dir, REPO_ROOT, stage_mothman=False
            )
            self.assertEqual(tasks_inter[0].bot1.name, "Mothman-Z")
            self.assertEqual(tasks_inter[0].bot2.name, "12PoolBot")
            self.assertEqual(tasks_inter[1].bot1.name, "Mothman-P")
            self.assertEqual(tasks_inter[1].bot2.name, "12PoolBot")

            args_seq = argparse.Namespace(**{**vars(args_lpt), "bots": "Mothman-Z,Mothman-P", "schedule_order": "sequential"})
            tasks_seq = self.runner.build_match_tasks(
                args_seq, roster, maps, arena_dir, REPO_ROOT, stage_mothman=False
            )
            self.assertEqual([t.bot1.name for t in tasks_seq[:9]], ["Mothman-Z"] * 9)
            self.assertEqual([t.bot1.name for t in tasks_seq[9:]], ["Mothman-P"] * 9)

    def test_lpt_uses_recent_results_json_and_sqlite_fallback(self) -> None:
        opps = [
            {"name": "oberon", "race": "T", "type": "python", "elo": 1200, "gauntlet_core": True},
            {"name": "puck", "race": "P", "type": "python", "elo": 1400, "gauntlet_core": True},
            {"name": "zig-reapers", "race": "T", "type": "python", "elo": 1150, "gauntlet_core": False},
        ]
        # 1) Historical results.json overrides built-in fallback
        with tempfile.TemporaryDirectory(prefix="arena_lpt_results_") as td:
            arena_dir = make_synthetic_arena(Path(td), opps)
            run_dir = arena_dir / "runs" / "20261124_010000_hist"
            run_dir.mkdir(parents=True, exist_ok=True)
            (run_dir / "results.json").write_text(
                json.dumps(
                    {
                        "matches": [
                            {"bot1": "Mothman-P", "bot2": "oberon", "wall_sec": 520.0},
                            {"bot1": "Mothman-P", "bot2": "zig-reapers", "wall_sec": 310.0},
                            {"bot1": "Mothman-P", "bot2": "puck", "wall_sec": 65.0},
                        ]
                    }
                ),
                encoding="utf-8",
            )
            roster = self.runner.load_roster(arena_dir / "bots")
            maps = self.runner.discover_maps(arena_dir / "maps", "all")
            args = argparse.Namespace(
                match_file=None,
                bots="Mothman-P",
                opponents="all",
                include_selfplay=False,
                matches_per_pair=1,
                mothman_mode="zip",
                schedule_order="lpt",
            )
            tasks = self.runner.build_match_tasks(args, roster, maps, arena_dir, REPO_ROOT, stage_mothman=False)
            self.assertEqual([t.bot2.name for t in tasks], ["oberon", "zig-reapers", "puck"])

        # 2) Read-only SQLite fallback (duration_sec when wall_sec column absent)
        with tempfile.TemporaryDirectory(prefix="arena_lpt_sqlite_") as td:
            arena_dir = make_synthetic_arena(Path(td), opps)
            db_path = arena_dir / "arena_replays.sqlite"
            con = sqlite3.connect(db_path)
            con.execute("CREATE TABLE matches (bot TEXT, opponent TEXT, duration_sec REAL)")
            con.executemany(
                "INSERT INTO matches (bot, opponent, duration_sec) VALUES (?, ?, ?)",
                [
                    ("Mothman-P", "zig-reapers", 1400.0),
                    ("Mothman-P", "oberon", 700.0),
                    ("Mothman-P", "puck", 200.0),
                ],
            )
            con.commit()
            con.close()
            roster = self.runner.load_roster(arena_dir / "bots")
            maps = self.runner.discover_maps(arena_dir / "maps", "all")
            args = argparse.Namespace(
                match_file=None,
                bots="Mothman-P",
                opponents="all",
                include_selfplay=False,
                matches_per_pair=1,
                mothman_mode="zip",
                schedule_order="lpt",
            )
            tasks = self.runner.build_match_tasks(args, roster, maps, arena_dir, REPO_ROOT, stage_mothman=False)
            self.assertEqual([t.bot2.name for t in tasks], ["zig-reapers", "oberon", "puck"])

    def test_canary_preset_and_cli_list_and_dry_run(self) -> None:
        # 18-match 3-race canary via --list
        res18 = subprocess.run(
            [sys.executable, str(ARENA_RUNNER_PATH), "--opponents", "canary", "--list"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        out18 = res18.stdout
        self.assertIn("Planned matches (18): schedule_order=lpt", out18)
        plan_lines_18 = [ln for ln in out18.splitlines() if ln.strip().startswith("[0")]
        self.assertEqual(len(plan_lines_18), 18)
        for opp in ("oberon", "zig-reapers", "AxeFighter", "puck", "Creepy_strategies", "QueenBot"):
            self.assertIn(f"vs {opp}(", out18)
        # Slowest canary opponents (AxeFighter / QueenBot / puck) must appear in the top slots
        top3 = " ".join(plan_lines_18[:3])
        self.assertTrue(
            any(slow in top3 for slow in ("AxeFighter", "QueenBot", "puck")),
            f"Expected slow canary opponent in top 3 slots, got: {plan_lines_18[:3]}",
        )

        # 6-match Protoss-only canary via --list
        res6 = subprocess.run(
            [sys.executable, str(ARENA_RUNNER_PATH), "--bots", "Mothman-P", "--opponents", "canary", "--list"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        out6 = res6.stdout
        self.assertIn("Planned matches (6): schedule_order=lpt", out6)
        plan_lines_6 = [ln for ln in out6.splitlines() if ln.strip().startswith("[0")]
        self.assertEqual(len(plan_lines_6), 6)
        self.assertTrue(all("Mothman-P(P," in ln for ln in plan_lines_6))

        # 26-match Protoss-only all via --dry-run (default j=14, schedule_order=lpt)
        res26 = subprocess.run(
            [sys.executable, str(ARENA_RUNNER_PATH), "--bots", "Mothman-P", "--opponents", "all", "--dry-run"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        out26 = res26.stdout
        self.assertIn("Dry run: 26 matches", out26)
        self.assertIn("schedule_order=lpt", out26)
        self.assertIn("j=14", out26)
        plan_lines_26 = [ln for ln in out26.splitlines() if ln.strip().startswith("[0")]
        self.assertEqual(len(plan_lines_26), 26)
        # Verify results.json schema records schedule_order
        runner_src = ARENA_RUNNER_PATH.read_text(encoding="utf-8")
        self.assertIn('"schedule_order": args.schedule_order', runner_src)

    def test_racket_lane_test_smoke_and_cleanup(self) -> None:
        self.assertTrue(LANE_SCRIPT_PATH.is_file(), f"Missing {LANE_SCRIPT_PATH}")
        self.assertTrue(os.access(LANE_SCRIPT_PATH, os.X_OK), f"{LANE_SCRIPT_PATH} must be executable")

        # Tests-only smoke test (< 3s wall clock, zero leftovers in /tmp/zo-smoke*)
        t0 = time.monotonic()
        res = subprocess.run(
            [str(LANE_SCRIPT_PATH), "smoke", "--", "tests/engine-arbiter-test.rkt"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        elapsed = time.monotonic() - t0
        self.assertLess(elapsed, 3.0, f"Smoke test took {elapsed:.2f}s (expected < 3.0s)")
        self.assertIn("PASS tests/engine-arbiter-test.rkt", res.stdout)
        self.assertEqual(glob.glob("/tmp/zo-smoke*"), [], "Leftover /tmp/zo-smoke* directory found")

        # Explicit --compile + -- test invocation
        res_c = subprocess.run(
            [
                str(LANE_SCRIPT_PATH),
                "smokecompile",
                "--compile",
                "lib/engine/arbiter.rkt",
                "--",
                "tests/engine-arbiter-test.rkt",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("compiled=2 files", res_c.stdout)
        self.assertIn("PASS tests/engine-arbiter-test.rkt", res_c.stdout)
        self.assertEqual(glob.glob("/tmp/zo-smokecompile*"), [], "Leftover /tmp/zo-smokecompile* directory found")

    def test_score_replay_batch_game_state_scoring_schema_and_math(self) -> None:
        sample_run = Path("/home/sjaconette/sc2-local-arena/runs/20261124_041450_iter65g_h2h_12")
        if not sample_run.is_dir():
            self.skipTest(f"Sample run {sample_run} not present on host")
        import math
        with tempfile.TemporaryDirectory(prefix="gs_score_test_") as td:
            out_json = Path(td) / "gs_score.json"
            subprocess.run(
                ["racket", str(REPO_ROOT / "tools" / "score-replay-batch.rkt"),
                 "--json", str(out_json), str(sample_run)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=True,
            )
            data = json.loads(out_json.read_text(encoding="utf-8"))
            matches = data["matches"]
            self.assertEqual(len(matches), 12)
            for m in matches:
                for k in (
                    "end_army_val", "opp_end_army_val", "end_income", "opp_end_income",
                    "state_ratio", "game_state_score", "state_outcome", "adjudicated_outcome",
                ):
                    self.assertIn(k, m)
                self.assertGreaterEqual(m["end_army_val"], 0)
                self.assertGreaterEqual(m["opp_end_army_val"], 0)
                self.assertGreaterEqual(m["end_income"], 0.0)
                self.assertGreaterEqual(m["opp_end_income"], 0.0)
                sr = math.exp(
                    0.45 * math.log((m["end_army_val"] + 500.0) / (m["opp_end_army_val"] + 500.0))
                    + 0.30 * math.log((m["end_income"] + 400.0) / (m["opp_end_income"] + 400.0))
                    + 0.15 * math.log((m["our_min_collected"] + 1000.0) / (m["opp_min_collected"] + 1000.0))
                    + 0.10 * math.log((m["killed_val"] + 500.0) / (m["lost_val"] + 500.0))
                )
                gs = 1.0 / (1.0 + sr ** (-2.0))
                self.assertAlmostEqual(m["state_ratio"], sr, delta=0.005)
                self.assertAlmostEqual(m["game_state_score"], gs, delta=0.002)
                exp_so = "win" if sr >= 1.15 else ("loss" if sr <= (1.0 / 1.15) else "tie")
                self.assertEqual(m["state_outcome"], exp_so)
                exp_ao = m["result"] if m["result"] in ("win", "loss") else exp_so
                self.assertEqual(m["adjudicated_outcome"], exp_ao)
            for agg in (
                data["overall"]["all"],
                data["overall"]["clean"],
                data["by_cohort"]["selfplay"],
                data["by_race"]["Protoss"],
                data["by_race"]["Terran"],
                data["by_race"]["Zerg"],
            ):
                for k in (
                    "wins", "losses", "ties",
                    "mean_game_state_score",
                    "state_wins", "state_losses", "state_ties", "state_adjudicated_wlt",
                    "adjudicated_wins", "adjudicated_losses", "adjudicated_ties", "adjudicated_wlt",
                ):
                    self.assertIn(k, agg)
                self.assertGreaterEqual(agg["mean_game_state_score"], 0.0)
                self.assertLessEqual(agg["mean_game_state_score"], 100.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
