#!/usr/bin/env python3
"""Unit tests for Tactics Arena deterministic sharding, revision attribution, and JSONL streaming."""

from __future__ import annotations

import argparse
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
ARENA_SCRIPT = REPO_ROOT / "tools" / "sc2-tactics-arena.py"
SCENARIOS_JSON = REPO_ROOT / "tools" / "arena-scenarios.json"


def _load_arena_module():
    mod_name = "_sc2_tactics_arena_sharding_test_mod"
    if mod_name in sys.modules:
        return sys.modules[mod_name]
    spec = importlib.util.spec_from_file_location(mod_name, ARENA_SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = mod
    spec.loader.exec_module(mod)
    return mod


class TestTacticsArenaShardingAndStreaming(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.arena = _load_arena_module()
        cls.all_specs = cls.arena.load_scenarios(str(SCENARIOS_JSON), REPO_ROOT)
        cls.core_specs = cls.arena.filter_scenarios(
            cls.all_specs, "all", "", "", "", "", "all", "", "core"
        )

    def test_shard_completeness_disjointness_and_balance_core_and_all(self) -> None:
        for suite_name, full_specs, shard_counts in (
            ("core", self.core_specs, (1, 4, 6)),
            ("all", self.all_specs, (1, 6, 12)),
        ):
            full_ids = [s.id for s in full_specs]
            for sc in shard_counts:
                shards = [
                    self.arena.shard_scenarios(full_specs, si, sc)
                    for si in range(sc)
                ]
                seen: list[str] = []
                sizes = [len(sh) for sh in shards]
                self.assertLessEqual(
                    max(sizes) - min(sizes),
                    1,
                    f"{suite_name}/{sc} shard sizes imbalanced: {sizes}",
                )
                for si, sh in enumerate(shards):
                    sh_ids = [s.id for s in sh]
                    self.assertEqual(
                        sh_ids,
                        full_ids[si::sc],
                        f"{suite_name}/{sc} shard {si} does not match interleaved slice",
                    )
                    if sc in (4, 6, 12):
                        races = {s.our_race for s in sh}
                        self.assertEqual(
                            races,
                            {"Protoss", "Terran", "Zerg"},
                            f"{suite_name}/{sc} shard {si} missing race balance: {races}",
                        )
                    seen.extend(sh_ids)
                self.assertEqual(len(seen), len(full_ids), f"{suite_name}/{sc} total mismatch")
                self.assertEqual(len(set(seen)), len(full_ids), f"{suite_name}/{sc} duplicate across shards")
                self.assertEqual(set(seen), set(full_ids), f"{suite_name}/{sc} union != full list")

    def test_shard_validation_and_empty_trailing_shards(self) -> None:
        small = self.core_specs[:3]
        self.assertEqual(len(self.arena.shard_scenarios(small, 0, 5)), 1)
        self.assertEqual(len(self.arena.shard_scenarios(small, 2, 5)), 1)
        self.assertEqual(self.arena.shard_scenarios(small, 3, 5), [])
        self.assertEqual(self.arena.shard_scenarios(small, 4, 5), [])

        with self.assertRaises(ValueError):
            self.arena.shard_scenarios(small, 0, 0)
        with self.assertRaises(ValueError):
            self.arena.shard_scenarios(small, -1, 2)
        with self.assertRaises(ValueError):
            self.arena.shard_scenarios(small, 2, 2)

    def test_snapshot_meta_reading_and_vcs_fallbacks(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            snap_dir = Path(td)
            meta = {
                "rev_id": "qvnkuuus_c5b0f54d",
                "jj_change_id": "qvnkuuus",
                "commit_id": "c5b0f54d",
                "label": "iter88e-ship28",
                "created_at": "2026-11-27T19:35:00Z",
                "parent_commit": "d18f38a3",
            }
            (snap_dir / ".snapshot_meta.json").write_text(json.dumps(meta), encoding="utf-8")
            got = self.arena.read_repo_revision_meta(snap_dir)
            self.assertEqual(got["rev_id"], "qvnkuuus_c5b0f54d")
            self.assertEqual(got["commit_id"], "c5b0f54d")
            self.assertEqual(got["rev_label"], "iter88e-ship28")

            # Partial metadata (commit_id + rev_label alias)
            (snap_dir / ".snapshot_meta.json").write_text(
                json.dumps({"commit_id": "deadbeef", "rev_label": "canary"}),
                encoding="utf-8",
            )
            got2 = self.arena.read_repo_revision_meta(snap_dir)
            self.assertEqual(got2["rev_id"], "deadbeef")
            self.assertEqual(got2["commit_id"], "deadbeef")
            self.assertEqual(got2["rev_label"], "canary")

        # Empty non-VCS directory returns clean unknown fallback
        with tempfile.TemporaryDirectory() as td_empty:
            got_empty = self.arena.read_repo_revision_meta(Path(td_empty))
            self.assertEqual(got_empty, {"rev_id": "unknown", "commit_id": "unknown", "rev_label": ""})

        # Live repo without .snapshot_meta.json falls back cleanly to jj/git
        got_repo = self.arena.read_repo_revision_meta(REPO_ROOT)
        self.assertTrue(got_repo["rev_id"] and got_repo["rev_id"] != "unknown")
        self.assertTrue(got_repo["commit_id"] and got_repo["commit_id"] != "unknown")

    def test_stream_jsonl_formatting_step_p95_and_atomic_append(self) -> None:
        self.assertEqual(self.arena.compute_step_p95_ms([]), 0.0)
        samples = [float(i) for i in range(1, 21)]  # 1..20 -> p95 index 18 -> 19.0
        self.assertAlmostEqual(self.arena.compute_step_p95_ms(samples), 19.0, places=2)

        rev_meta = {"rev_id": "rev_abc123", "commit_id": "abc123", "rev_label": "loop88e"}
        rec_pass = {
            "id": "sc2-zvz-m02-roach-ravager-bile-concave",
            "tier": "canonical",
            "category": "kiting-concave",
            "terrain": "open",
            "fast_core": True,
            "scoring_mode": "combat",
            "opponent_mode": "dummy",
            "race": "Zerg",
            "enemy_race": "Zerg",
            "bot": "Mothman-Z",
            "p2_bot": "MicroDummy",
            "winner": "Mothman",
            "win_type": "ko",
            "end_reason": "ko_eliminated",
            "trade_ratio": 2.09,
            "p1_lost_val": 900.0,
            "p2_lost_val": 1880.0,
            "our_surviving_val": 1450.0,
            "enemy_surviving_val": 0.0,
            "win_margin": 1450.0,
            "loops_simulated": 404,
            "wall_ms": 812.5,
            "step_p95_ms": 6.42,
            "allow_macro": False,
            "macro_ability_cmds": 0,
            "spell_verified": True,
            "concave_arc_width": 6.2,
            "role_inversion_pct": 0.0,
            "anti_splash_clump_score": 0.5,
            "dps_active_pct": 94.0,
        }
        rec_self_loss = dict(rec_pass)
        rec_self_loss.update(
            {
                "id": "sc2-pvp-m02-shield-battery-overcharge-hold",
                "opponent_mode": "self",
                "winner": "Mothman-P2",
                "our_surviving_val": 100.0,
                "enemy_surviving_val": 950.0,
                "win_margin": -850.0,
            }
        )

        with tempfile.TemporaryDirectory() as td:
            sp = Path(td) / "sub" / "stream.jsonl"
            p1 = self.arena.append_stream_jsonl_record(
                sp, rec_pass, rev_meta=rev_meta, opp_mode="dummy", shard_index=1, shard_count=6
            )
            p2 = self.arena.append_stream_jsonl_record(
                sp, rec_self_loss, rev_meta=rev_meta, opp_mode="self", shard_index=1, shard_count=6
            )
            self.assertTrue(p1["passed"])
            self.assertFalse(p2["passed"])
            self.assertEqual(p1["rev_id"], "rev_abc123")
            self.assertEqual(p1["scenario_id"], rec_pass["id"])
            self.assertEqual(p1["elapsed_frames"], 404)
            self.assertEqual(p1["our_surviving_val"], 1450.0)
            self.assertEqual(p1["enemy_surviving_val"], 0.0)
            self.assertEqual(p1["win_margin"], 1450.0)
            self.assertEqual(p1["step_p95_ms"], 6.42)
            self.assertEqual(p1["shard_index"], 1)
            self.assertEqual(p1["shard_count"], 6)
            self.assertTrue(p1["finished_at"])

            raw_lines = sp.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(raw_lines), 2)
            # Compact JSONL (no pretty whitespace indentation)
            self.assertNotIn("\n", raw_lines[0])
            self.assertNotIn(": ", raw_lines[0])
            parsed = [json.loads(line) for line in raw_lines]
            self.assertEqual(parsed[0]["scenario_id"], rec_pass["id"])
            self.assertEqual(parsed[1]["scenario_id"], rec_self_loss["id"])
            self.assertEqual(parsed[1]["passed"], False)

    def test_host_driver_sharded_out_and_stream_jsonl_mocked(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp_dir = Path(td)
            snap_dir = tmp_dir / "snap"
            snap_dir.mkdir()
            (snap_dir / ".snapshot_meta.json").write_text(
                json.dumps(
                    {
                        "rev_id": "snap88e_abcd1234",
                        "commit_id": "abcd1234",
                        "label": "daemon-test",
                    }
                ),
                encoding="utf-8",
            )
            out_json = tmp_dir / "shard2.json"
            stream_jsonl = tmp_dir / "shard2.jsonl"
            expected_shard = self.arena.shard_scenarios(self.core_specs, 2, 6)
            expected_ids = [s.id for s in expected_shard]
            specs_by_id = {s.id: s for s in self.core_specs}

            def _fake_container(
                args,
                race,
                save_replays_dir=None,
                enemy_race="",
                scenario_ids=None,
                batch_tag="",
                map_override="",
                rev_meta=None,
            ):
                rows = []
                for sid in (scenario_ids or []):
                    sp_spec = specs_by_id[sid]
                    rec = {
                        "id": sid,
                        "tier": sp_spec.tier,
                        "category": sp_spec.category,
                        "terrain": sp_spec.terrain,
                        "fast_core": sp_spec.fast_core,
                        "scoring_mode": sp_spec.scoring_mode,
                        "opponent_mode": args.opponent,
                        "race": sp_spec.our_race,
                        "enemy_race": sp_spec.enemy_race,
                        "bot": f"Mothman-{sp_spec.our_race[0]}",
                        "p2_bot": "MicroDummy",
                        "winner": "Mothman",
                        "win_type": "ko",
                        "end_reason": "ko_eliminated",
                        "p1_lost_val": 200.0,
                        "p2_lost_val": 600.0,
                        "our_surviving_val": 800.0,
                        "enemy_surviving_val": 0.0,
                        "win_margin": 800.0,
                        "trade_ratio": 3.0,
                        "mothman_attack_unit_cmds": 40,
                        "mothman_move_unit_cmds": 5,
                        "mothman_spell_unit_cmds": 2,
                        "allow_macro": sp_spec.allow_macro,
                        "macro_buildings_built": 0,
                        "macro_workers_trained": 0,
                        "macro_ability_cmds": 0,
                        "loops_simulated": 200,
                        "step_p95_ms": 4.25,
                        "wall_ms": 350.0,
                    }
                    rows.append(rec)
                    if getattr(args, "stream_jsonl", ""):
                        self.arena.append_stream_jsonl_record(
                            args.stream_jsonl,
                            rec,
                            rev_meta=rev_meta,
                            opp_mode=args.opponent,
                            shard_index=args.shard_index,
                            shard_count=args.shard_count,
                        )
                return {"scenarios": rows}

            args = argparse.Namespace(
                mode="duel",
                opponent="dummy",
                suite="core",
                category="",
                race="all",
                enemy_race="",
                scenarios=str(SCENARIOS_JSON),
                scenario="",
                terrain="",
                source="",
                tier="all",
                scenario_ids="",
                shard_index=2,
                shard_count=6,
                stream_jsonl=str(stream_jsonl),
                workers=2,
                map="AcropolisAIE.SC2Map",
                step_size=4,
                image="mock",
                repo_dir=str(snap_dir),
                maps_dir=str(tmp_dir),
                arena_dir=str(tmp_dir),
                out=str(out_json),
                compare="",
                render_dir="",
                save_replays_dir="",
                list=False,
                validate=False,
            )
            buf = io.StringIO()
            with mock.patch.object(self.arena, "run_single_container", side_effect=_fake_container):
                with redirect_stdout(buf):
                    rc = self.arena.run_host_driver(args)
            self.assertEqual(rc, 0)
            rep = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertEqual(rep["rev_id"], "snap88e_abcd1234")
            self.assertEqual(rep["commit_id"], "abcd1234")
            self.assertEqual(rep["rev_label"], "daemon-test")
            self.assertEqual(rep["shard_index"], 2)
            self.assertEqual(rep["shard_count"], 6)
            self.assertEqual([s["id"] for s in rep["scenarios"]], expected_ids)
            self.assertEqual(rep["summary"]["total"], len(expected_ids))

            stream_rows = [
                json.loads(line)
                for line in stream_jsonl.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            self.assertEqual(len(stream_rows), len(expected_ids))
            self.assertEqual({r["scenario_id"] for r in stream_rows}, set(expected_ids))
            self.assertTrue(all(r["rev_id"] == "snap88e_abcd1234" for r in stream_rows))
            self.assertTrue(all(r["shard_index"] == 2 and r["shard_count"] == 6 for r in stream_rows))

            # Empty trailing shard (shard_index=5, shard_count=6 on 2 scenario IDs) exits cleanly
            args_empty = argparse.Namespace(**vars(args))
            args_empty.scenario_ids = ",".join(expected_ids[:2])
            args_empty.shard_index = 5
            args_empty.shard_count = 6
            args_empty.out = str(tmp_dir / "empty_shard.json")
            buf2 = io.StringIO()
            with redirect_stdout(buf2):
                rc2 = self.arena.run_host_driver(args_empty)
            self.assertEqual(rc2, 0)
            rep2 = json.loads((tmp_dir / "empty_shard.json").read_text(encoding="utf-8"))
            self.assertEqual(rep2["summary"]["total"], 0)
            self.assertEqual(rep2["scenarios"], [])
            self.assertEqual(rep2["rev_id"], "snap88e_abcd1234")

    def test_host_driver_list_with_sharding(self) -> None:
        listed_union: list[str] = []
        for si in range(6):
            args = argparse.Namespace(
                mode="duel",
                opponent="dummy",
                suite="core",
                category="",
                race="all",
                enemy_race="",
                scenarios=str(SCENARIOS_JSON),
                scenario="",
                terrain="",
                source="",
                tier="all",
                scenario_ids="",
                shard_index=si,
                shard_count=6,
                stream_jsonl="",
                workers=1,
                map="AcropolisAIE.SC2Map",
                step_size=4,
                image="mock",
                repo_dir=str(REPO_ROOT),
                maps_dir=str(REPO_ROOT),
                arena_dir=str(REPO_ROOT),
                out="",
                compare="",
                render_dir="",
                save_replays_dir="",
                list=True,
                validate=False,
            )
            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = self.arena.run_host_driver(args)
            self.assertEqual(rc, 0)
            ids_in_shard = [
                line.split()[2]
                for line in buf.getvalue().splitlines()
                if ". [" in line and len(line.split()) >= 3
            ]
            listed_union.extend(ids_in_shard)
        self.assertEqual(len(listed_union), len(self.core_specs))
        self.assertEqual(set(listed_union), {s.id for s in self.core_specs})


if __name__ == "__main__":
    unittest.main()
