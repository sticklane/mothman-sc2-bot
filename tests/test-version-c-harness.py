#!/usr/bin/env python3
"""Unit tests for Loop 84 Version C ("C is for Cheese") harness & BotZip repacker.

Validates:
  1. `Mothman-{PC,TC,ZC,XC}` registration in `MOTHMAN_VARIANTS` with `cheese_mode=True`.
  2. `--cheese-defense-drill` preset: 18 deterministic matches (9 matchups x 2 pro cheeses),
     exact 18 Profile IDs, P1 Main Macro vs P2 Version C, default `max_game_time=16128`.
  3. `--cheese-radar` preset: 78 deterministic matches (`Mothman-{PC,TC,ZC}` vs 26 roster bots),
     `aggregate_cheese_vulnerability` ranking, and `format_summary_text` table output.
  4. Staging (`source`, `elf`, `zip`) & `clone_bot_dir`: writes `CheeseMode`/`CheeseProfile`
     into `config.json` AND `--cheese-mode --cheese-profile <id>` into `source`/`elf` launchers,
     plus `--cheese-profile` and `--p2-cheese-profile` overrides.
  5. `tools/repack_version_c_zips.py`: zero-bloat repacking of `Mothman-{Z,T,P,X}.zip` into
     `Mothman-{ZC,TC,PC,XC}.zip` with renamed executable, `+x` permissions, `config.json`,
     `bot_config.json`, `run.py`, and `--dry-run` verification.
  6. CLI `--dry-run` execution of `--cheese-defense-drill` and `--cheese-radar`.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ARENA_SCRIPT = REPO_ROOT / "tools" / "run-local-sc2-arena.py"
REPACK_SCRIPT = REPO_ROOT / "tools" / "repack_version_c_zips.py"


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


ARENA = _load_module("run_local_sc2_arena_vc", ARENA_SCRIPT)
REPACK = _load_module("repack_version_c_zips_vc", REPACK_SCRIPT)

EXPECTED_18_PROFILES = {
    "zvz-13-12-ling-bane",
    "zvz-12pool-proxy-spine",
    "zvp-19d-speedling-roach-ravager",
    "zvp-12pool-ling-flood",
    "zvt-26d-roach-ravager-bust",
    "zvt-42d-queen-ling-nydus",
    "tvp-proxy-2rax-marauder",
    "tvp-1base-2gas-cyclone",
    "tvt-proxy-2rax-reaper",
    "tvt-1base-111-tank-bunker",
    "tvz-proxy-2rax-bunker",
    "tvz-reaper-fe-hellion-banshee",
    "pvz-32p-8gate-chargelot-prism",
    "pvz-cannon-rush",
    "pvt-proxy-4gate-zealot-stalker",
    "pvt-proxy-stargate-voidray",
    "pvp-proxy-robo-immortal",
    "pvp-cannon-rush",
}

MAPS_7 = [
    "IncorporealAIE_v4",
    "LeyLinesAIE_v3",
    "MagannathaAIE_v2",
    "PersephoneAIE_v4",
    "PylonAIE_v4",
    "TorchesAIE_v4",
    "UltraloveAIE_v2",
]


def _make_fake_roster(n: int = 26) -> dict:
    roster = {}
    races = ("P", "T", "Z", "R")
    for i in range(n):
        name = f"OppBot_{i:02d}"
        roster[name] = ARENA.BotSpec(
            name=name,
            race=races[i % 4],
            bot_type="python",
            source_dir=Path(f"/tmp/fake/{name}"),
            is_mothman=False,
            elo=1500 + i * 10,
            gauntlet_core=(i < 14),
            active_comp38=True,
        )
    return roster


def _make_args(**overrides) -> argparse.Namespace:
    base = dict(
        bots="Mothman-Z,Mothman-T,Mothman-P",
        opponents="core",
        include_selfplay=False,
        selfplay_matches=6,
        selfplay_limit=None,
        selfplay_baseline=False,
        cheese_profile=None,
        p2_cheese_profile=None,
        cheese_defense_drill=False,
        cheese_radar=False,
        maps="season",
        matches_per_pair=1,
        match_file=None,
        mothman_mode="source",
        schedule_order="lpt",
        bench_seed="mothman-v1",
        max_game_time=None,
    )
    base.update(overrides)
    return argparse.Namespace(**base)


class VersionCHarnessTests(unittest.TestCase):
    def test_variants_registered(self) -> None:
        for vc, base, race in (
            ("Mothman-PC", "Mothman-P", "P"),
            ("Mothman-TC", "Mothman-T", "T"),
            ("Mothman-ZC", "Mothman-Z", "Z"),
            ("Mothman-XC", "Mothman-X", "R"),
        ):
            self.assertIn(vc, ARENA.MOTHMAN_VARIANTS)
            meta = ARENA.MOTHMAN_VARIANTS[vc]
            self.assertTrue(meta["cheese_mode"])
            self.assertEqual(meta["cheese_profile"], "auto")
            self.assertEqual(meta["race"], race)
            self.assertEqual(meta["base_zip"], base)
        for main_var in ("Mothman-P", "Mothman-T", "Mothman-Z", "Mothman-X"):
            self.assertFalse(ARENA.MOTHMAN_VARIANTS[main_var]["cheese_mode"])

    def test_cheese_defense_drill_18_exact_profiles_and_matchups(self) -> None:
        args = _make_args(cheese_defense_drill=True)
        tasks = ARENA.build_match_tasks(args, {}, MAPS_7, Path("/tmp/no_arena"), REPO_ROOT, stage_mothman=False)
        self.assertEqual(len(tasks), 18)
        seen_profiles = set()
        seen_matchups = set()
        seen_slugs = set()
        for t in tasks:
            self.assertEqual(t.cohort, "cheese_drill")
            self.assertFalse(t.bot1.cheese_mode)
            self.assertTrue(t.bot2.cheese_mode)
            self.assertIn(t.bot1.name, ("Mothman-P", "Mothman-T", "Mothman-Z"))
            self.assertIn(t.bot2.name, ("Mothman-PC", "Mothman-TC", "Mothman-ZC"))
            prof = t.bot2.cheese_profile
            seen_profiles.add(prof)
            seen_matchups.add((t.bot1.race, t.bot2.race))
            seen_slugs.add(t.slug)
            # Profile prefix must match P2 race vs P1 race
            expected_mu = f"{t.bot2.race.lower()}v{t.bot1.race.lower()}-"
            self.assertTrue(prof.startswith(expected_mu), f"{prof} does not match {expected_mu}")
            self.assertGreater(t.random_seed, 0)
        self.assertEqual(seen_profiles, EXPECTED_18_PROFILES)
        self.assertEqual(len(seen_matchups), 9)
        self.assertEqual(len(seen_slugs), 18)
        # Deterministic replayability
        tasks2 = ARENA.build_match_tasks(args, {}, MAPS_7, Path("/tmp/no_arena"), REPO_ROOT, stage_mothman=False)
        self.assertEqual([(t.map_name, t.random_seed, t.slug) for t in tasks], [(t.map_name, t.random_seed, t.slug) for t in tasks2])

    def test_cheese_radar_78_and_vulnerability_table(self) -> None:
        roster = _make_fake_roster(26)
        args = _make_args(cheese_radar=True, schedule_order="lpt")
        tasks = ARENA.build_match_tasks(args, roster, MAPS_7, Path("/tmp/no_arena"), REPO_ROOT, stage_mothman=False)
        self.assertEqual(len(tasks), 78)
        self.assertEqual({t.bot1.name for t in tasks}, {"Mothman-PC", "Mothman-TC", "Mothman-ZC"})
        self.assertTrue(all(t.bot1.cheese_mode and t.bot1.cheese_profile == "auto" for t in tasks))
        self.assertEqual(len({t.bot2.name for t in tasks}), 26)

        # Synthetic results -> vulnerability ranking + stdout formatting
        fake_records = [
            {"index": 1, "cohort": "core", "bot1": "Mothman-PC", "bot1_race": "P", "bot2": "SoftBot", "bot2_race": "Z", "bot2_elo": 1600, "map": "PylonAIE_v4", "outcome": "Win", "raw_result": "Player1Win", "game_steps": 5000, "game_minutes": 3.72, "wall_sec": 30.0},
            {"index": 2, "cohort": "core", "bot1": "Mothman-TC", "bot1_race": "T", "bot2": "SoftBot", "bot2_race": "Z", "bot2_elo": 1600, "map": "PylonAIE_v4", "outcome": "Win", "raw_result": "Player1Win", "game_steps": 6200, "game_minutes": 4.61, "wall_sec": 35.0},
            {"index": 3, "cohort": "core", "bot1": "Mothman-PC", "bot1_race": "P", "bot2": "TankyBot", "bot2_race": "T", "bot2_elo": 2100, "map": "PylonAIE_v4", "outcome": "Loss", "raw_result": "Player2Win", "game_steps": 12000, "game_minutes": 8.93, "wall_sec": 80.0},
            {"index": 4, "cohort": "core", "bot1": "Mothman-TC", "bot1_race": "T", "bot2": "TankyBot", "bot2_race": "T", "bot2_elo": 2100, "map": "PylonAIE_v4", "outcome": "Win", "raw_result": "Player1Win", "game_steps": 7500, "game_minutes": 5.58, "wall_sec": 55.0},
        ]
        vuln = ARENA.aggregate_cheese_vulnerability(fake_records)
        self.assertEqual([r["opponent"] for r in vuln], ["SoftBot", "TankyBot"])
        self.assertEqual(vuln[0]["cheese_wr_pct"], 100.0)
        self.assertEqual(vuln[0]["sub6_wins"], 2)
        self.assertEqual(vuln[1]["cheese_wr_pct"], 50.0)

        summary = {
            "run_id": "test_radar",
            "repo_commit": "deadbeef",
            "mothman_mode": "source",
            "schedule_order": "lpt",
            "concurrency": 4,
            "wall_elapsed_sec": 100.0,
            "image": "test",
            "totals": ARENA.aggregate_records(fake_records),
            "by_bot": {"Mothman-PC": ARENA.aggregate_records(fake_records[:1])},
            "by_opponent": {"SoftBot": ARENA.aggregate_records(fake_records[:2])},
            "by_cohort": {"core": ARENA.aggregate_records(fake_records)},
            "cheese_vulnerability": vuln,
            "matches": fake_records,
        }
        txt = ARENA.format_summary_text(summary)
        self.assertIn("--- Cheese Vulnerability (by Opponent) ---", txt)
        self.assertIn("SoftBot", txt)
        self.assertIn("100.0%", txt)

    def test_stage_and_clone_cheese_flags_source_and_elf(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vc_stage_test_") as td:
            root = Path(td)
            fake_repo = root / "repo"
            fake_arena = root / "arena"
            # Populate minimal fake portable racket + elf + config.rktd
            (fake_repo / "ladder" / ".cache" / "racket_runtime" / "bin").mkdir(parents=True)
            (fake_repo / "ladder" / ".cache" / "racket_runtime" / "bin" / "racket").write_text("#!/bin/sh\n", encoding="utf-8")
            (fake_repo / "ladder" / ".cache" / "portable-etc").mkdir(parents=True)
            (fake_repo / "ladder" / ".cache" / "portable-etc" / "config.rktd").write_text('#hash((bin-dir . "/old"))\n', encoding="utf-8")
            (fake_repo / "ladder" / ".cache" / "mothman_standalone_elf").write_bytes(b"\x7fELFfake")

            # 1) Source mode staging for Mothman-TC with explicit profile
            src_dir = ARENA.stage_mothman_cache("Mothman-TC", "source", fake_arena, fake_repo, cheese_profile="tvp-proxy-2rax-marauder")
            cfg = json.loads((src_dir / "config.json").read_text(encoding="utf-8"))
            self.assertEqual(cfg["BotName"], "Mothman-TC")
            self.assertTrue(cfg["CheeseMode"])
            self.assertEqual(cfg["CheeseProfile"], "tvp-proxy-2rax-marauder")
            launcher_txt = (src_dir / "Mothman-TC").read_text(encoding="utf-8")
            self.assertIn("--cheese-mode --cheese-profile tvp-proxy-2rax-marauder", launcher_txt)

            # 2) ELF mode staging for Mothman-PC with auto profile
            elf_dir = ARENA.stage_mothman_cache("Mothman-PC", "elf", fake_arena, fake_repo)
            elf_cfg = json.loads((elf_dir / "config.json").read_text(encoding="utf-8"))
            self.assertTrue(elf_cfg["CheeseMode"])
            self.assertEqual(elf_cfg["CheeseProfile"], "auto")
            self.assertTrue((elf_dir / "Mothman-PC.elf").is_file())
            elf_launcher = (elf_dir / "Mothman-PC").read_text(encoding="utf-8")
            self.assertIn("--cheese-mode --cheese-profile auto", elf_launcher)

            # 3) clone_bot_dir per-match override
            cloned = root / "cloned_pc"
            ARENA.clone_bot_dir(src_dir, cloned, "Mothman-TC", "Mothman-TC", "cpplinux", cheese_mode=True, cheese_profile="tvt-proxy-2rax-reaper")
            cloned_cfg = json.loads((cloned / "config.json").read_text(encoding="utf-8"))
            self.assertEqual(cloned_cfg["CheeseProfile"], "tvt-proxy-2rax-reaper")
            cloned_launcher = (cloned / "Mothman-TC").read_text(encoding="utf-8")
            self.assertIn("--cheese-mode --cheese-profile tvt-proxy-2rax-reaper", cloned_launcher)
            self.assertNotIn("tvp-proxy-2rax-marauder", cloned_launcher)

    def test_repack_version_c_zips_and_dry_run(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vc_repack_test_") as td:
            root = Path(td)
            src_dir = root / "src_zips"
            out_dir = root / "out_zips"
            src_dir.mkdir()

            # Build a minimal synthetic Mothman-Z.zip with a working executable stub
            src_zip = src_dir / "Mothman-Z.zip"
            stub_exe = (
                "#!/bin/sh\n"
                'echo "DRY_RUN_OK"\n'
                'echo \'{"status":"DRY_RUN_OK","cheese_mode":true,"cheese_profile":"auto"}\'\n'
            ).encode("utf-8")
            base_cfg = {"BotName": "Mothman-Z", "BotRace": "Zerg", "BotPath": "bots/Mothman-Z.rkt"}
            run_py = 'NAMES = ("Mothman", "Mothman-X", "Mothman-Z", "Mothman-T", "Mothman-P", "Mothman-R")\n'

            with zipfile.ZipFile(src_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                zi_exe = zipfile.ZipInfo("Mothman-Z")
                zi_exe.create_system = 3
                zi_exe.external_attr = (stat.S_IFREG | 0o755) << 16
                zf.writestr(zi_exe, stub_exe)
                zf.writestr("config.json", json.dumps(base_cfg, indent=2) + "\n")
                zf.writestr("bot_config.json", json.dumps(base_cfg, indent=2) + "\n")
                zf.writestr("run.py", run_py)

            out_zip = out_dir / "Mothman-ZC.zip"
            REPACK.repack_version_c_zip(src_zip, "Mothman-Z", "Mothman-ZC", out_zip, cheese_profile="zvz-13-12-ling-bane")
            self.assertTrue(out_zip.is_file())

            with zipfile.ZipFile(out_zip, "r") as zf:
                names = set(zf.namelist())
                self.assertIn("Mothman-ZC", names)
                self.assertNotIn("Mothman-Z", names)
                exe_info = zf.getinfo("Mothman-ZC")
                self.assertTrue(((exe_info.external_attr >> 16) & 0o111) != 0)
                for cfg_name in ("config.json", "bot_config.json"):
                    cfg = json.loads(zf.read(cfg_name).decode("utf-8"))
                    self.assertEqual(cfg["BotName"], "Mothman-ZC")
                    self.assertTrue(cfg["CheeseMode"])
                    self.assertEqual(cfg["CheeseProfile"], "zvz-13-12-ling-bane")
                run_txt = zf.read("run.py").decode("utf-8")
                self.assertIn('"Mothman-ZC"', run_txt)

            dry = REPACK.verify_repacked_zip_dry_run(out_zip, "Mothman-ZC")
            self.assertIn("DRY_RUN_OK", dry["stdout"])
            self.assertTrue(dry["json"]["cheese_mode"])

    def test_cli_dry_run_presets(self) -> None:
        # 1) --cheese-defense-drill --dry-run
        res1 = subprocess.run(
            [sys.executable, str(ARENA_SCRIPT), "--cheese-defense-drill", "--mothman-mode", "source", "--dry-run"],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(res1.returncode, 0, msg=res1.stderr)
        self.assertIn("Dry run: 18 matches", res1.stdout)
        self.assertIn("max_game_time=16128", res1.stdout)
        self.assertIn("tvp-proxy-2rax-marauder", res1.stdout)
        self.assertIn("pvz-cannon-rush", res1.stdout)

        # 2) --cheese-radar --dry-run
        res2 = subprocess.run(
            [sys.executable, str(ARENA_SCRIPT), "--cheese-radar", "--mothman-mode", "source", "--dry-run"],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(res2.returncode, 0, msg=res2.stderr)
        self.assertIn("Dry run: 78 matches", res2.stdout)
        self.assertIn("max_game_time=16128", res2.stdout)
        self.assertIn("Mothman-PC", res2.stdout)
        self.assertIn("Mothman-TC", res2.stdout)
        self.assertIn("Mothman-ZC", res2.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
