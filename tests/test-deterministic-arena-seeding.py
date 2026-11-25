#!/usr/bin/env python3
"""Unit tests for deterministic LPT-invariant map & SC2 random_seed assignment."""

from __future__ import annotations

import argparse
import importlib.util
import json
import py_compile
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER_PATH = REPO_ROOT / "tools" / "run-local-sc2-arena.py"
PROXY_PATH = REPO_ROOT / "tools" / "sc2-match-proxy.py"

SEASON_MAPS = [
    "IncorporealAIE_v4",
    "LeyLinesAIE_v3",
    "MagannathaAIE_v2",
    "PersephoneAIE_v4",
    "PylonAIE_v4",
    "TorchesAIE_v4",
    "UltraloveAIE_v2",
]


def _load_runner():
    mod_name = "run_local_sc2_arena_under_test"
    if mod_name in sys.modules:
        return sys.modules[mod_name]
    spec = importlib.util.spec_from_file_location(mod_name, RUNNER_PATH)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = mod
    spec.loader.exec_module(mod)
    return mod


def _make_synthetic_roster(rla) -> dict:
    """26-bot roster matching the real 14 core + 12 unseen structure (offline-safe)."""
    core_names = [
        "12PoolBot", "Chance", "Creepy_strategies", "RustyNikolaj", "SmoothBrain",
        "Thssprtssbt", "mini-puck", "monsterbot", "oberon", "onlyfans",
        "puck", "sludgement2-revived", "titania", "who",
    ]
    unseen_names = [
        "AxeFighter", "Clicadinha", "CryptBotRevival", "ModBotNewBuilds", "Mulebot",
        "PolyMorph", "QueenBot", "Thessaloniki", "VeTerran-revived", "norman",
        "sc2ai_protoss", "zig-reapers",
    ]
    roster = {}
    for idx, name in enumerate(core_names + unseen_names, start=1):
        roster[name] = rla.BotSpec(
            name=name,
            race=("Z", "T", "P")[idx % 3],
            bot_type="cpplinux",
            source_dir=Path("/tmp/fake-bot"),
            is_mothman=False,
            elo=1000 + idx * 15,
            gauntlet_core=(name in core_names),
        )
    return roster


def _make_args(
    *,
    bots: str = "Mothman-Z,Mothman-T,Mothman-P",
    opponents: str = "all",
    include_selfplay: bool = True,
    schedule_order: str = "lpt",
    bench_seed: str = "mothman-v1",
    matches_per_pair: int = 1,
    match_file: str | None = None,
) -> argparse.Namespace:
    return argparse.Namespace(
        bots=bots,
        opponents=opponents,
        include_selfplay=include_selfplay,
        selfplay_matches=6,
        selfplay_limit=None,
        selfplay_baseline=False,
        matches_per_pair=matches_per_pair,
        match_file=match_file,
        mothman_mode="source",
        schedule_order=schedule_order,
        bench_seed=bench_seed,
    )


class TestDeterministicArenaSeeding(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rla = _load_runner()
        cls.roster = _make_synthetic_roster(cls.rla)
        cls.arena_dir = Path("/tmp/fake-arena")

    def _task_map(self, tasks) -> dict[tuple[str, str, str], tuple[str, int]]:
        out: dict[tuple[str, str, str], tuple[str, int]] = {}
        for t in tasks:
            key = (t.bot1.name, t.bot2.name, t.cohort)
            self.assertNotIn(key, out, f"Duplicate matchup key {key}")
            out[key] = (t.map_name, t.random_seed)
        return out

    def test_lpt_wall_estimate_invariance(self) -> None:
        args = _make_args(schedule_order="lpt", bench_seed="mothman-v1")
        est_a = (
            {("mothman-z", "oberon"): 600.0, ("mothman-p", "titania"): 50.0},
            {"oberon": 500.0, "titania": 60.0},
        )
        est_b = (
            {("mothman-z", "oberon"): 40.0, ("mothman-p", "titania"): 620.0},
            {"oberon": 45.0, "titania": 610.0},
        )
        with mock.patch.object(self.rla, "load_historical_wall_estimates", return_value=est_a):
            tasks_a = self.rla.build_match_tasks(
                args, self.roster, list(SEASON_MAPS), self.arena_dir, REPO_ROOT, stage_mothman=False
            )
        with mock.patch.object(self.rla, "load_historical_wall_estimates", return_value=est_b):
            tasks_b = self.rla.build_match_tasks(
                args, self.roster, list(reversed(SEASON_MAPS)), self.arena_dir, REPO_ROOT, stage_mothman=False
            )

        self.assertEqual(len(tasks_a), 84)
        self.assertEqual(len(tasks_b), 84)
        # Execution order MUST differ when LPT estimates invert,
        # while (map_name, random_seed) MUST stay 100% identical!
        order_a = [(t.bot1.name, t.bot2.name) for t in tasks_a]
        order_b = [(t.bot1.name, t.bot2.name) for t in tasks_b]
        self.assertNotEqual(order_a, order_b)
        self.assertEqual(self._task_map(tasks_a), self._task_map(tasks_b))

    def test_schedule_order_invariance(self) -> None:
        with mock.patch.object(self.rla, "load_historical_wall_estimates", return_value=({}, {})):
            t_lpt = self.rla.build_match_tasks(
                _make_args(schedule_order="lpt"),
                self.roster, SEASON_MAPS, self.arena_dir, REPO_ROOT, stage_mothman=False,
            )
            t_int = self.rla.build_match_tasks(
                _make_args(schedule_order="interleaved"),
                self.roster, SEASON_MAPS, self.arena_dir, REPO_ROOT, stage_mothman=False,
            )
            t_seq = self.rla.build_match_tasks(
                _make_args(schedule_order="sequential"),
                self.roster, SEASON_MAPS, self.arena_dir, REPO_ROOT, stage_mothman=False,
            )
        m_lpt = self._task_map(t_lpt)
        self.assertEqual(m_lpt, self._task_map(t_int))
        self.assertEqual(m_lpt, self._task_map(t_seq))

    def test_subset_vs_full_invariance(self) -> None:
        with mock.patch.object(self.rla, "load_historical_wall_estimates", return_value=({}, {})):
            full = self._task_map(
                self.rla.build_match_tasks(
                    _make_args(opponents="all", include_selfplay=True),
                    self.roster, SEASON_MAPS, self.arena_dir, REPO_ROOT, stage_mothman=False,
                )
            )
            for opp_preset, inc_sp in (
                ("oberon", False),
                ("canary", False),
                ("core", False),
                ("self_6", True),
            ):
                sub = self._task_map(
                    self.rla.build_match_tasks(
                        _make_args(opponents=opp_preset, include_selfplay=inc_sp),
                        self.roster, SEASON_MAPS, self.arena_dir, REPO_ROOT, stage_mothman=False,
                    )
                )
                self.assertGreater(len(sub), 0)
                for k, v in sub.items():
                    self.assertIn(k, full)
                    self.assertEqual(v, full[k], f"Mismatch for {k} under preset={opp_preset}")

    def test_random_bench_seed_disables_rng_seeding(self) -> None:
        with mock.patch.object(self.rla, "load_historical_wall_estimates", return_value=({}, {})):
            for raw_seed in ("random", "0", ""):
                tasks = self.rla.build_match_tasks(
                    _make_args(opponents="canary", include_selfplay=False, bench_seed=raw_seed),
                    self.roster, SEASON_MAPS, self.arena_dir, REPO_ROOT, stage_mothman=False,
                )
                self.assertEqual(len(tasks), 18)
                self.assertTrue(all(t.random_seed == 0 for t in tasks))
                self.assertTrue(all(t.map_name in SEASON_MAPS for t in tasks))

    def test_match_file_explicit_and_default_seeding(self) -> None:
        payload = [
            {"bot": "Mothman-P", "opponent": "titania", "map": "PylonAIE_v4", "random_seed": 424242},
            {"bot": "Mothman-T", "opponent": "oberon"},
        ]
        with tempfile.TemporaryDirectory() as td:
            mf = Path(td) / "matches.json"
            mf.write_text(json.dumps(payload), encoding="utf-8")
            tasks = self.rla.build_match_tasks(
                _make_args(match_file=str(mf), bench_seed="mothman-v1"),
                self.roster, SEASON_MAPS, self.arena_dir, REPO_ROOT, stage_mothman=False,
            )
        self.assertEqual(len(tasks), 2)
        self.assertEqual(tasks[0].map_name, "PylonAIE_v4")
        self.assertEqual(tasks[0].random_seed, 424242)
        exp_mp, exp_seed = self.rla.deterministic_map_and_seed(
            "mothman-v1", "Mothman-T", "oberon", 0, SEASON_MAPS
        )
        self.assertEqual(tasks[1].map_name, exp_mp)
        self.assertEqual(tasks[1].random_seed, exp_seed)

    def test_map_balance_and_seed_uniqueness_across_84_games(self) -> None:
        with mock.patch.object(self.rla, "load_historical_wall_estimates", return_value=({}, {})):
            tasks = self.rla.build_match_tasks(
                _make_args(opponents="all", include_selfplay=True, bench_seed="mothman-v1"),
                self.roster, SEASON_MAPS, self.arena_dir, REPO_ROOT, stage_mothman=False,
            )
        self.assertEqual(len(tasks), 84)
        seeds = [t.random_seed for t in tasks]
        self.assertTrue(all(1 <= s <= 2147483647 for s in seeds))
        self.assertEqual(len(set(seeds)), 84, "Expected all 84 matchup seeds to be unique")

        per_bot: dict[str, Counter] = {b: Counter() for b in ("Mothman-Z", "Mothman-T", "Mothman-P")}
        total = Counter()
        for t in tasks:
            total[t.map_name] += 1
            if t.cohort != "selfplay":
                per_bot[t.bot1.name][t.map_name] += 1

        for b, cnt in per_bot.items():
            counts = [cnt[m] for m in SEASON_MAPS]
            self.assertGreaterEqual(min(counts), 2, f"{b} map distribution too low: {dict(cnt)}")
            self.assertLessEqual(max(counts), 5, f"{b} map distribution too high: {dict(cnt)}")
        tot_counts = [total[m] for m in SEASON_MAPS]
        self.assertGreaterEqual(min(tot_counts), 9, f"Total map distribution too low: {dict(total)}")
        self.assertLessEqual(max(tot_counts), 15, f"Total map distribution too high: {dict(total)}")

    def test_syntax_and_proxy_seed_contract(self) -> None:
        py_compile.compile(str(RUNNER_PATH), doraise=True)
        py_compile.compile(str(PROXY_PATH), doraise=True)
        proxy_src = PROXY_PATH.read_text(encoding="utf-8")
        for token in ("--random-seed", "random_seed", "p1_start_xy", "p2_start_xy"):
            self.assertIn(token, proxy_src)

    def test_spawn_balance_aggregation_and_summary_line(self) -> None:
        records = [
            {"bot1": "Mothman-P", "p1_start_xy": [117.5, 20.5], "p2_start_xy": [14.5, 115.5]},  # SE (South)
            {"bot1": "Mothman-P", "p1_start_xy": [14.5, 115.5], "p2_start_xy": [117.5, 20.5]},  # NW (North)
            {"bot1": "Mothman-Z", "p1_start_xy": [150.0, 140.0], "p2_start_xy": [30.0, 40.0]},  # NE (North)
            {"bot1": "Mothman-T", "p1_start_xy": [30.0, 40.0], "p2_start_xy": [150.0, 140.0]},  # SW (South)
            {"bot1": "Mothman-T", "p1_start_xy": None, "p2_start_xy": None},                    # unobserved
        ]
        sb = self.rla.aggregate_spawn_balance(records)
        ov = sb["overall"]
        self.assertEqual(ov["observed"], 4)
        self.assertEqual(ov["north"], 2)
        self.assertEqual(ov["south"], 2)
        self.assertEqual(ov["north_pct"], 50.0)
        self.assertEqual(ov["quadrants"], {"NE": 1, "NW": 1, "SE": 1, "SW": 1})
        self.assertEqual(sb["by_bot"]["Mothman-P"]["north"], 1)
        self.assertEqual(sb["by_bot"]["Mothman-P"]["south"], 1)
        self.assertEqual(sb["by_bot"]["Mothman-Z"]["north_pct"], 100.0)
        self.assertEqual(sb["by_bot"]["Mothman-T"]["south_pct"], 100.0)

        dummy_summary = {
            "run_id": "test_run",
            "repo_commit": "abc12345",
            "mothman_mode": "source",
            "schedule_order": "lpt",
            "concurrency": 4,
            "wall_elapsed_sec": 10.0,
            "image": "img",
            "totals": {
                "wins": 2, "losses": 2, "ties": 0, "errors": 0,
                "win_rate_pct": 50.0, "clean_wins": 2, "clean_losses": 2,
                "opp_crash_or_timeout_wins": 0, "our_crash_or_timeout_losses": 0,
                "avg_game_minutes": 10.0, "avg_bot1_step_ms": 12.0,
            },
            "spawn_balance": sb,
            "by_bot": {},
            "by_opponent": {},
            "by_cohort": {},
            "matches": [],
        }
        txt = self.rla.format_summary_text(dummy_summary)
        self.assertIn("Spawn balance: 2N/2S (50.0%N) [NE=1 NW=1 SE=1 SW=1]", txt)
        self.assertIn("P:1N/1S(50%N)", txt)
        self.assertIn("Z:1N/0S(100%N)", txt)
        self.assertIn("T:0N/1S(0%N)", txt)


if __name__ == "__main__":
    unittest.main(verbosity=2)
