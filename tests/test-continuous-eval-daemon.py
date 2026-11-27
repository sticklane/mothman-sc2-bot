#!/usr/bin/env python3
"""Unit tests for tools/continuous-eval-daemon.py and run-local-sc2-arena.py hooks.

Pure Python stdlib unittest (< 2s, zero live SC2 containers).
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
DAEMON_PATH = REPO_ROOT / "tools" / "continuous-eval-daemon.py"
ARENA_PATH = REPO_ROOT / "tools" / "run-local-sc2-arena.py"


def _load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


CE = _load_module("continuous_eval_daemon_under_test", DAEMON_PATH)
ARENA = _load_module("run_local_sc2_arena_under_test", ARENA_PATH)


def _make_synthetic_arena(root: Path, num_core: int = 14, num_unseen: int = 12) -> tuple[Path, tuple[str, ...]]:
    arena_dir = root / "arena"
    bots_dir = arena_dir / "bots"
    maps_dir = arena_dir / "maps"
    bots_dir.mkdir(parents=True, exist_ok=True)
    maps_dir.mkdir(parents=True, exist_ok=True)

    roster_entries: list[dict[str, Any]] = []
    canary_list: list[str] = []
    races = ("Z", "T", "P")
    total = num_core + num_unseen
    for i in range(total):
        name = f"SynthBot_{i+1:02d}"
        bdir = bots_dir / name
        bdir.mkdir(parents=True, exist_ok=True)
        (bdir / "run.py").write_text("# stub\n", encoding="utf-8")
        is_core = i < num_core
        roster_entries.append({
            "name": name,
            "race": races[i % 3],
            "type": "python",
            "elo": 1200 + i * 10,
            "aiarena_id": 100 + i,
            "gauntlet_core": is_core,
            "active_comp38": True,
            "archetype": "macro",
            "tier": "mid",
        })
        if i < 6:
            canary_list.append(name)

    (bots_dir / "roster.json").write_text(
        json.dumps({"bots": roster_entries}, indent=2) + "\n", encoding="utf-8"
    )

    map_names = [f"SynthMap_{i+1:02d}" for i in range(6)]
    for mn in map_names:
        (maps_dir / f"{mn}.SC2Map").write_bytes(b"SC2MAP")
    (maps_dir / "maps_manifest.json").write_text(
        json.dumps(
            {"maps": [{"name": mn, "filename": f"{mn}.SC2Map"} for mn in map_names]},
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return arena_dir, tuple(canary_list)


def _make_fake_repo(root: Path) -> Path:
    repo = root / "fake_repo"
    (repo / ".git").mkdir(parents=True)
    (repo / ".git" / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
    (repo / ".jj").mkdir(parents=True)
    (repo / ".jj" / "store").write_text("jj", encoding="utf-8")
    (repo / "scratch").mkdir(parents=True)
    (repo / "scratch" / "temp.txt").write_text("scratch", encoding="utf-8")
    (repo / "lib" / "compiled").mkdir(parents=True)
    (repo / "lib" / "bot.rkt").write_text("#lang racket/base\n", encoding="utf-8")
    (repo / "lib" / "compiled" / "bot_rkt.zo").write_bytes(b"zo")
    (repo / "tools" / "__pycache__").mkdir(parents=True)
    (repo / "tools" / "__pycache__" / "x.pyc").write_bytes(b"pyc")
    (repo / "ladder" / ".cache" / "racket_runtime" / "bin").mkdir(parents=True)
    (repo / "ladder" / ".cache" / "mothman_standalone_elf").write_bytes(b"ELF")
    (repo / "ladder" / ".cache" / "racket_runtime" / "bin" / "racket").write_bytes(b"RKT")
    (repo / "ladder" / "Mothman-Z.zip").write_bytes(b"PK\x05\x06" + b"\x00" * 18)
    return repo


class TestContinuousEvalDaemon(unittest.TestCase):
    def test_arena_hooks_snapshot_meta_and_match_file_modes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            snap = root / "snap_dir"
            snap.mkdir()
            (snap / ".snapshot_meta.json").write_text(
                json.dumps({"rev_id": "iter88f_abcd1234_99887766", "commit_id": "99887766"}) + "\n",
                encoding="utf-8",
            )
            # No .git or .jj exists in snap_dir; get_repo_commit must read .snapshot_meta.json
            self.assertEqual(ARENA.get_repo_commit(snap), "iter88f_abcd1234_99887766")

            arena_dir, canary = _make_synthetic_arena(root, num_core=6, num_unseen=2)
            roster = ARENA.load_roster(arena_dir / "bots")
            maps = ARENA.discover_maps(arena_dir / "maps", "season")
            mf = root / "matches.json"
            mf.write_text(
                json.dumps({
                    "matches": [
                        {
                            "bot": "Mothman-Z",
                            "opponent": "Mothman-Z",
                            "p1_mode": "source",
                            "p2_mode": "zip",
                            "p2_alias": "Mothman-Z-Base",
                            "cohort": "selfplay",
                            "random_seed": 4242,
                        },
                        {
                            "bot": "Mothman-P",
                            "opponent": canary[0],
                            "p1_mode": "source",
                            "cohort": "core",
                        },
                    ]
                }),
                encoding="utf-8",
            )
            fake_args = SimpleNamespace(
                bench_seed="mothman-v1",
                cheese_profile=None,
                p2_cheese_profile=None,
                cheese_defense_drill=False,
                match_file=str(mf),
                mothman_mode="source",
            )
            tasks = ARENA.build_match_tasks(
                fake_args, roster, maps, arena_dir, REPO_ROOT, stage_mothman=False
            )
            self.assertEqual(len(tasks), 2)
            t0, t1 = tasks[0], tasks[1]
            self.assertEqual(t0.bot1.name, "Mothman-Z")
            self.assertEqual(t0.bot1.bot_mode, "source")
            self.assertEqual(t0.bot2.name, "Mothman-Z-Base")
            self.assertEqual(t0.bot2.source_bot_name, "Mothman-Z")
            self.assertEqual(t0.bot2.bot_mode, "zip")
            self.assertEqual(t0.cohort, "selfplay")
            self.assertEqual(t0.random_seed, 4242)
            self.assertEqual(t1.bot1.name, "Mothman-P")
            self.assertEqual(t1.bot2.name, canary[0])
            self.assertEqual(t1.cohort, "core")

    def test_cow_snapshot_exclusions_meta_and_gc(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            fake_repo = _make_fake_repo(root)
            snaps_dir = root / "snapshots"
            state_dir = root / "continuous_eval"
            conn = CE.open_db(state_dir / "eval_stream.sqlite")
            try:
                m1 = CE.create_repo_snapshot(fake_repo, snaps_dir, label="s1", explicit_rev_id="rev_01")
                s1_dir = Path(m1["snapshot_dir"])
                self.assertTrue((s1_dir / "lib" / "bot.rkt").is_file())
                self.assertTrue((s1_dir / "ladder" / "Mothman-Z.zip").is_file())
                self.assertTrue((s1_dir / "ladder" / ".cache" / "racket_runtime" / "bin" / "racket").is_file())
                self.assertFalse((s1_dir / ".git").exists())
                self.assertFalse((s1_dir / ".jj").exists())
                self.assertFalse((s1_dir / "scratch").exists())
                self.assertFalse((s1_dir / "lib" / "compiled" / "bot_rkt.zo").exists())
                self.assertFalse((s1_dir / "tools" / "__pycache__").exists())
                self.assertFalse((s1_dir / "ladder" / ".cache" / "mothman_standalone_elf").exists())

                meta_doc = json.loads((s1_dir / ".snapshot_meta.json").read_text(encoding="utf-8"))
                for key in ("rev_id", "jj_change_id", "commit_id", "label", "created_at", "parent_commit"):
                    self.assertIn(key, meta_doc)
                self.assertEqual(meta_doc["rev_id"], "rev_01")

                # Create 3 more snapshots with monotonically increasing timestamps; mark rev_01 active so GC keeps it
                m2 = CE.create_repo_snapshot(fake_repo, snaps_dir, label="s2", explicit_rev_id="rev_02")
                m3 = CE.create_repo_snapshot(fake_repo, snaps_dir, label="s3", explicit_rev_id="rev_03")
                m4 = CE.create_repo_snapshot(fake_repo, snaps_dir, label="s4", explicit_rev_id="rev_04")
                for idx, m in enumerate((m1, m2, m3, m4), start=1):
                    p = Path(m["snapshot_dir"]) / ".snapshot_meta.json"
                    d = json.loads(p.read_text(encoding="utf-8"))
                    d["created_at"] = f"2026-11-28T00:00:0{idx}Z"
                    p.write_text(json.dumps(d) + "\n", encoding="utf-8")

                with conn:
                    conn.execute(
                        "INSERT INTO revisions (rev_id, label, snapshot_dir, status, created_at) "
                        "VALUES (?, ?, ?, 'active', ?)",
                        ("rev_01", "s1", m1["snapshot_dir"], "2026-11-28T00:00:01Z"),
                    )
                    conn.execute(
                        "INSERT INTO revisions (rev_id, label, snapshot_dir, status, created_at) "
                        "VALUES (?, ?, ?, 'superseded', ?)",
                        ("rev_02", "s2", m2["snapshot_dir"], "2026-11-28T00:00:02Z"),
                    )

                removed = CE.gc_snapshots(conn, snaps_dir, keep=2)
                # rev_04 and rev_03 are top 2 newest; rev_01 is active/protected; only rev_02 is deleted!
                self.assertEqual(len(removed), 1)
                self.assertTrue(Path(m1["snapshot_dir"]).is_dir())
                self.assertFalse(Path(m2["snapshot_dir"]).is_dir())
                self.assertTrue(Path(m3["snapshot_dir"]).is_dir())
                self.assertTrue(Path(m4["snapshot_dir"]).is_dir())
            finally:
                conn.close()

    def test_seed_baseline_from_score_and_tactics_json(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            state_dir = root / "continuous_eval"
            score_path = root / "iter88_score.json"
            summary_path = root / "summary.json"
            tactics_path = root / "tactics.json"

            score_path.write_text(
                json.dumps({
                    "schema_version": 2,
                    "matches": [
                        {
                            "our_bot": "Mothman-Z",
                            "our_race": "Zerg",
                            "opp_bot": "SynthBot_01",
                            "opp_cohort": "core_12",
                            "map_canon": "SynthMap_01",
                            "result": "win",
                            "state_outcome": "win",
                            "game_state_score": 0.942,
                            "trade_ratio": 1.85,
                            "duration_sec": 620.0,
                            "avg_step_ms": 14.2,
                            "p95_step_ms": 24.5,
                            "crashes": 0,
                            "action_rejects": 0,
                            "own_base_retreat_ticks": 1,
                            "gas_rich_min_starved": False,
                            "supply_block_pct": 1.4,
                            "our_w6": 46,
                            "anomalies": {"self_cancel_loop": 0},
                        },
                        {
                            "our_bot": "Mothman-T",
                            "our_race": "Terran",
                            "opp_bot": "Mothman-T-Base",
                            "opp_cohort": "selfplay",
                            "is_selfplay": True,
                            "map_canon": "SynthMap_02",
                            "result": "win",
                            "state_outcome": "win",
                            "game_state_score": 0.985,
                            "trade_ratio": 2.1,
                            "duration_sec": 540.0,
                            "avg_step_ms": 13.0,
                            "p95_step_ms": 22.0,
                            "crashes": 0,
                            "action_rejects": 0,
                            "own_base_retreat_ticks": 0,
                            "gas_rich_min_starved": True,
                            "supply_block_pct": 2.1,
                            "our_w6": 41,
                            "anomalies": {"self_cancel_loop": 0},
                        },
                    ],
                }),
                encoding="utf-8",
            )
            summary_path.write_text(
                json.dumps({
                    "matches": [
                        {
                            "bot1": "Mothman-Z",
                            "bot2": "SynthBot_01",
                            "random_seed": 777,
                            "replay_path": "/tmp/r1.SC2Replay",
                            "our_log_path": "/tmp/l1.log",
                            "apm_cap_drops": {"by_tier": {"P0": 3, "P1": 9}},
                        }
                    ]
                }),
                encoding="utf-8",
            )
            tactics_path.write_text(
                json.dumps({
                    "opponent_mode": "dummy",
                    "scenarios": [
                        {
                            "id": "sc2-real-z01",
                            "category": "kiting-concave",
                            "terrain": "open",
                            "race": "Zerg",
                            "enemy_race": "Terran",
                            "winner": "Mothman",
                            "trade_ratio": 2.45,
                            "p1_lost_val": 200.0,
                            "p2_lost_val": 900.0,
                            "loops_simulated": 240,
                        }
                    ],
                }),
                encoding="utf-8",
            )

            conn = CE.open_db(state_dir / "eval_stream.sqlite")
            try:
                res = CE.seed_baseline(
                    conn,
                    rev_id="r28_base",
                    label="R28 Baseline",
                    from_score_json=score_path,
                    from_tactics_json=tactics_path,
                    state_dir=state_dir,
                )
                self.assertEqual(res["ladder_inserted"], 2)
                self.assertEqual(res["tactics_inserted"], 1)

                r0 = dict(
                    conn.execute(
                        "SELECT * FROM ladder_results WHERE rev_id = 'r28_base' AND bot = 'Mothman-Z'"
                    ).fetchone()
                )
                self.assertAlmostEqual(r0["game_score"], 94.2, places=2)
                self.assertEqual(r0["opp_cohort"], "core")
                self.assertEqual(r0["apm_p0_drops"], 3)
                self.assertEqual(r0["apm_p1_drops"], 9)
                self.assertEqual(r0["random_seed"], 777)
                self.assertEqual(r0["w6_workers"], 46)

                r1 = dict(
                    conn.execute(
                        "SELECT * FROM ladder_results WHERE rev_id = 'r28_base' AND bot = 'Mothman-T'"
                    ).fetchone()
                )
                self.assertEqual(r1["opp_cohort"], "selfplay")
                self.assertEqual(r1["grm_flag"], 1)

                t0 = dict(
                    conn.execute(
                        "SELECT * FROM tactics_results WHERE rev_id = 'r28_base'"
                    ).fetchone()
                )
                self.assertEqual(t0["passed"], 1)
                self.assertAlmostEqual(t0["trade_ratio"], 2.45, places=2)
                self.assertAlmostEqual(t0["win_margin"], 700.0, places=1)
            finally:
                conn.close()

    def test_tiered_queue_generation_equals_exact_all84(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            arena_dir, canary = _make_synthetic_arena(root, num_core=14, num_unseen=12)
            fake_repo = _make_fake_repo(root)
            state_dir = root / "continuous_eval"
            snaps_dir = root / "snapshots"
            conn = CE.open_db(state_dir / "eval_stream.sqlite")
            try:
                res = CE.enqueue_revision(
                    conn=conn,
                    repo_dir=fake_repo,
                    arena_dir=arena_dir,
                    state_dir=state_dir,
                    snapshots_dir=snaps_dir,
                    label="test84",
                    tiers_spec="all",
                    canary_opponents=canary,
                )
                rev_id = res["rev_id"]
                t1 = conn.execute(
                    "SELECT * FROM ladder_queue WHERE rev_id = ? AND tier = 'tier1_sentinel'",
                    (rev_id,),
                ).fetchall()
                t2 = conn.execute(
                    "SELECT * FROM ladder_queue WHERE rev_id = ? AND tier = 'tier2_full84'",
                    (rev_id,),
                ).fetchall()
                t3 = conn.execute(
                    "SELECT * FROM ladder_queue WHERE rev_id = ? AND tier = 'tier3_multiseed'",
                    (rev_id,),
                ).fetchall()

                self.assertEqual(len(t1), 24)  # 18 canary + 6 SELF_6
                self.assertEqual(len(t2), 60)  # remaining 20 opponents x 3 races
                self.assertEqual(len(t1) + len(t2), 84)
                self.assertEqual(len(t3), 156)  # 78 rotated + 78 cheese radar

                self6 = [dict(r) for r in t1 if r["cohort"] == "selfplay"]
                self.assertEqual(len(self6), 6)
                for sp in self6:
                    self.assertEqual(sp["p2_mode"], "zip")
                    self.assertTrue(sp["p2_alias"].endswith("-Base"))

                # tier1 + tier2 must be 84 pairwise-distinct (bot, effective_opponent) matchups
                keys_84 = {(r["bot"], r["p2_alias"] or r["opponent"]) for r in list(t1) + list(t2)}
                self.assertEqual(len(keys_84), 84)

                # Tactics shards: 6 + 12 + 6 = 24
                t_counts = {
                    row["tier"]: row["cnt"]
                    for row in conn.execute(
                        "SELECT tier, COUNT(*) AS cnt FROM tactics_queue WHERE rev_id = ? GROUP BY tier",
                        (rev_id,),
                    ).fetchall()
                }
                self.assertEqual(
                    t_counts,
                    {"tier1_core_dummy": 6, "tier2_all_dummy": 12, "tier3_core_self": 6},
                )
            finally:
                conn.close()

    def test_preemption_preserves_inflight_attribution(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            arena_dir, canary = _make_synthetic_arena(root, num_core=6, num_unseen=2)
            fake_repo = _make_fake_repo(root)
            state_dir = root / "continuous_eval"
            snaps_dir = root / "snapshots"
            conn = CE.open_db(state_dir / "eval_stream.sqlite")
            enq1 = CE.enqueue_revision(
                conn=conn,
                repo_dir=fake_repo,
                arena_dir=arena_dir,
                state_dir=state_dir,
                snapshots_dir=snaps_dir,
                label="revA",
                tiers_spec="tier1_sentinel",
                canary_opponents=canary,
            )
            rev_a = enq1["rev_id"]

            started_ev = threading.Event()
            release_ev = threading.Event()
            completed_revs: list[str] = []

            def mock_ladder_runner(item: dict[str, Any], _rev_meta: dict[str, Any], _wa: Path) -> dict[str, Any]:
                if item["rev_id"] == rev_a and not started_ev.is_set():
                    started_ev.set()
                    release_ev.wait(timeout=5.0)
                completed_revs.append(item["rev_id"])
                return {
                    "rev_id": item["rev_id"],
                    "queue_id": item["id"],
                    "tier": item["tier"],
                    "bot": item["bot"],
                    "our_race": CE.normalize_race_full("", item["bot"]),
                    "opponent": item["p2_alias"] or item["opponent"],
                    "opp_cohort": item["cohort"],
                    "map_name": item["map_name"],
                    "random_seed": item["random_seed"],
                    "result": "win",
                    "state_result": "win",
                    "game_score": 88.0,
                    "trade_ratio": 1.7,
                    "duration_sec": 420.0,
                    "step_avg_ms": 12.0,
                    "step_p95_ms": 21.0,
                    "crashes": 0,
                    "wire_rejects": 0,
                    "self_cancel": 0,
                    "arbiter_error": 0,
                    "own_retreat_ticks": 0,
                    "grm_flag": 0,
                    "apm_p0_drops": 0,
                    "apm_p1_drops": 0,
                    "supply_block_pct": 1.0,
                    "w6_workers": 44,
                    "finished_at": CE.utc_now_iso(),
                }

            daemon = CE.EvalDaemon(
                repo_dir=fake_repo,
                arena_dir=arena_dir,
                state_dir=state_dir,
                snapshots_dir=snaps_dir,
                ladder_workers=1,
                tactics_workers=0,
                max_total_sc2=4,
                poll_sec=0.05,
                once=True,
                ladder_runner=mock_ladder_runner,
                active_sc2_counter=lambda: 0,
            )
            t = threading.Thread(target=daemon.run_forever, kwargs={"write_pid": False}, daemon=True)
            t.start()
            self.assertTrue(started_ev.wait(timeout=3.0))

            # Preempt revA while 1 item is in-flight
            enq2 = CE.enqueue_revision(
                conn=conn,
                repo_dir=fake_repo,
                arena_dir=arena_dir,
                state_dir=state_dir,
                snapshots_dir=snaps_dir,
                label="revB",
                tiers_spec="tier1_sentinel",
                preempt=True,
                canary_opponents=canary,
            )
            rev_b = enq2["rev_id"]
            self.assertEqual(enq2["superseded_ladder"], 23)

            rev_a_status = conn.execute(
                "SELECT status FROM revisions WHERE rev_id = ?", (rev_a,)
            ).fetchone()["status"]
            self.assertEqual(rev_a_status, "draining")

            # Let in-flight item finish and drain revB
            release_ev.set()
            t.join(timeout=10.0)
            self.assertFalse(t.is_alive())

            cnt_a = conn.execute(
                "SELECT COUNT(*) AS c FROM ladder_results WHERE rev_id = ?", (rev_a,)
            ).fetchone()["c"]
            cnt_b = conn.execute(
                "SELECT COUNT(*) AS c FROM ladder_results WHERE rev_id = ?", (rev_b,)
            ).fetchone()["c"]
            final_a_status = conn.execute(
                "SELECT status FROM revisions WHERE rev_id = ?", (rev_a,)
            ).fetchone()["status"]
            self.assertEqual(cnt_a, 1)  # In-flight item attributed to revA!
            self.assertEqual(cnt_b, 24)  # Full revB tier1_sentinel completed!
            self.assertEqual(final_a_status, "superseded")
            conn.close()

    def test_streaming_regression_detector_ownret_grm_gs_apm_and_tactics(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            state_dir = root / "continuous_eval"
            conn = CE.open_db(state_dir / "eval_stream.sqlite")
            try:
                now = CE.utc_now_iso()
                with conn:
                    conn.execute(
                        "INSERT INTO revisions (rev_id, label, status, created_at) "
                        "VALUES ('base_r27', 'R27', 'baseline', ?)",
                        (now,),
                    )
                    conn.execute(
                        "INSERT INTO revisions (rev_id, label, baseline_rev_id, status, created_at) "
                        "VALUES ('cand_88d', '88D-like', 'base_r27', 'active', ?)",
                        (now,),
                    )
                    # Seed 5 Zerg + 3 Terran baseline ladder matches (clean)
                    base_matches = [
                        ("Mothman-Z", "Zerg", f"Opp_{i}", "core", "win", 82.0, 0 if i < 4 else 1, 0, 2)
                        for i in range(1, 6)
                    ] + [
                        ("Mothman-T", "Terran", f"Opp_{i}", "core", "win", 78.0, 0, 0, 2)
                        for i in range(1, 4)
                    ]
                    for bot, race, opp, coh, res, gs, own_ret, grm, p0 in base_matches:
                        conn.execute(
                            """
                            INSERT INTO ladder_results
                                (rev_id, tier, bot, our_race, opponent, opp_cohort,
                                 result, state_result, game_score, trade_ratio, duration_sec,
                                 step_avg_ms, step_p95_ms, own_retreat_ticks, grm_flag,
                                 apm_p0_drops, finished_at)
                            VALUES ('base_r27', 'baseline', ?, ?, ?, ?, ?, ?, ?, 1.6, 600, 14, 24, ?, ?, ?, ?)
                            """,
                            (bot, race, opp, coh, res, res, gs, own_ret, grm, p0, now),
                        )

                    # Seed 4 baseline tactical drills in category 'kiting-concave' (all PASS, trade=2.0)
                    for i in range(1, 5):
                        CE.upsert_tactics_result(
                            conn,
                            {
                                "rev_id": "base_r27",
                                "opponent_mode": "dummy",
                                "scenario_id": f"scen-{i:02d}",
                                "category": "kiting-concave",
                                "terrain": "open",
                                "race": "Zerg",
                                "enemy_race": "Terran",
                                "passed": 1,
                                "trade_ratio": 2.0,
                                "win_margin": 500.0,
                                "our_surviving_val": 800.0,
                                "enemy_surviving_val": 0.0,
                                "elapsed_frames": 220,
                                "step_p95_ms": 18.0,
                                "finished_at": now,
                            },
                        )

                # Stream 5 regressed Zerg matches (88D-like: ownRet spikes 1 -> 15 ticks, GRM 0% -> 60%, GS -30, APM P0 2 -> 28, wire_reject=1 on match 1)
                for idx in range(1, 6):
                    row = {
                        "rev_id": "cand_88d",
                        "tier": "tier1_sentinel",
                        "bot": "Mothman-Z",
                        "our_race": "Zerg",
                        "opponent": f"Opp_{idx}",
                        "opp_cohort": "core",
                        "map_name": "SynthMap_01",
                        "result": "loss",
                        "state_result": "loss",
                        "game_score": 52.0,
                        "trade_ratio": 0.7,
                        "duration_sec": 700.0,
                        "step_avg_ms": 19.0,
                        "step_p95_ms": 47.0 if idx == 1 else 26.0,
                        "crashes": 0,
                        "wire_rejects": 1 if idx == 1 else 0,
                        "self_cancel": 0,
                        "arbiter_error": 0,
                        "own_retreat_ticks": 3,
                        "grm_flag": 1 if idx <= 3 else 0,
                        "apm_p0_drops": 28,
                        "finished_at": now,
                    }
                    with conn:
                        conn.execute(
                            """
                            INSERT INTO ladder_results
                                (rev_id, tier, bot, our_race, opponent, opp_cohort, map_name,
                                 result, state_result, game_score, trade_ratio, duration_sec,
                                 step_avg_ms, step_p95_ms, crashes, wire_rejects, self_cancel,
                                 arbiter_error, own_retreat_ticks, grm_flag, apm_p0_drops, finished_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            (
                                row["rev_id"], row["tier"], row["bot"], row["our_race"],
                                row["opponent"], row["opp_cohort"], row["map_name"],
                                row["result"], row["state_result"], row["game_score"],
                                row["trade_ratio"], row["duration_sec"], row["step_avg_ms"],
                                row["step_p95_ms"], row["crashes"], row["wire_rejects"],
                                row["self_cancel"], row["arbiter_error"],
                                row["own_retreat_ticks"], row["grm_flag"],
                                row["apm_p0_drops"], row["finished_at"],
                            ),
                        )
                        CE.evaluate_ladder_alerts(conn, "cand_88d", latest_row=row)

                # Stream 3 regressed tactical scenarios (2 PASS->FAIL flips + trade drops)
                for i in range(1, 4):
                    trow = {
                        "rev_id": "cand_88d",
                        "opponent_mode": "dummy",
                        "scenario_id": f"scen-{i:02d}",
                        "category": "kiting-concave",
                        "terrain": "open",
                        "race": "Zerg",
                        "enemy_race": "Terran",
                        "passed": 0 if i <= 2 else 1,
                        "trade_ratio": 0.9 if i <= 2 else 1.8,
                        "win_margin": -200.0 if i <= 2 else 400.0,
                        "our_surviving_val": 100.0,
                        "enemy_surviving_val": 300.0,
                        "elapsed_frames": 300,
                        "step_p95_ms": 20.0,
                        "finished_at": now,
                    }
                    with conn:
                        CE.upsert_tactics_result(conn, trow)
                        CE.evaluate_tactics_alerts(conn, "cand_88d", latest_row=trow)

                alerts = [
                    dict(r)
                    for r in conn.execute("SELECT * FROM alerts WHERE rev_id = 'cand_88d'").fetchall()
                ]
                kinds_metrics = {(a["kind"], a["scope"], a["metric"]) for a in alerts}
                self.assertIn(("hard_fault", "Mothman-Z_vs_Opp_1", "wire_rejects"), kinds_metrics)
                self.assertIn(("perf_fault", "Mothman-Z_vs_Opp_1", "step_p95_ms"), kinds_metrics)
                self.assertIn(("physics_regression", "race:Zerg", "own_retreat_ticks"), kinds_metrics)
                self.assertIn(("econ_regression", "race:Zerg", "grm_rate"), kinds_metrics)
                self.assertIn(("apm_regression", "race:Zerg", "apm_p0_drops"), kinds_metrics)
                self.assertIn(("gs_regression", "race:Zerg", "game_score"), kinds_metrics)
                self.assertIn(("tactics_flip", "dummy:scen-01", "passed"), kinds_metrics)
                self.assertIn(("tactics_trade_drop", "dummy:scen-01", "trade_ratio"), kinds_metrics)
                self.assertIn(("tactics_category_drop", "dummy:cat:kiting-concave", "category_pass_rate"), kinds_metrics)
            finally:
                conn.close()

    def test_max_total_sc2_throttling_pause_and_live_streaming(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            arena_dir, canary = _make_synthetic_arena(root, num_core=6, num_unseen=0)
            fake_repo = _make_fake_repo(root)
            state_dir = root / "continuous_eval"
            snaps_dir = root / "snapshots"
            conn = CE.open_db(state_dir / "eval_stream.sqlite")
            enq = CE.enqueue_revision(
                conn=conn,
                repo_dir=fake_repo,
                arena_dir=arena_dir,
                state_dir=state_dir,
                snapshots_dir=snaps_dir,
                label="throttle_test",
                tiers_spec="tier1_core_dummy",
                canary_opponents=canary,
            )
            rev_id = enq["rev_id"]
            # Trim to 1 tactics shard for snappy test
            with conn:
                conn.execute("DELETE FROM tactics_queue WHERE shard_index > 0")

            # Start both paused AND saturated (active SC2 = 10 >= max_total_sc2 = 10)
            (state_dir / "daemon.pause").write_text("paused\n", encoding="utf-8")
            ext_count = [10]
            ran_shards: list[int] = []

            def mock_tactics_runner(
                item: dict[str, Any],
                _rev_meta: dict[str, Any],
                _sjsonl: Path,
                _ojson: Path,
                on_record: Any,
            ) -> list[dict[str, Any]]:
                ran_shards.append(item["shard_index"])
                on_record({
                    "scenario_id": "sc2-stream-01",
                    "category": "spell-micro",
                    "terrain": "open",
                    "race": "Protoss",
                    "enemy_race": "Zerg",
                    "passed": True,
                    "trade_ratio": 3.1,
                    "win_margin": 600.0,
                    "our_surviving_val": 900.0,
                    "enemy_surviving_val": 0.0,
                    "elapsed_frames": 180,
                    "step_p95_ms": 14.5,
                })
                return []

            daemon = CE.EvalDaemon(
                repo_dir=fake_repo,
                arena_dir=arena_dir,
                state_dir=state_dir,
                snapshots_dir=snaps_dir,
                ladder_workers=0,
                tactics_workers=1,
                max_total_sc2=10,
                poll_sec=0.05,
                once=True,
                tactics_runner=mock_tactics_runner,
                active_sc2_counter=lambda: ext_count[0],
            )
            t = threading.Thread(target=daemon.run_forever, kwargs={"write_pid": False}, daemon=True)
            t.start()

            # While paused + saturated, nothing may launch
            time.sleep(0.18)
            self.assertEqual(ran_shards, [])

            # Unpause, still saturated at 10 -> still must NOT launch!
            (state_dir / "daemon.pause").unlink()
            time.sleep(0.18)
            self.assertEqual(ran_shards, [])

            # Drop active SC2 below cap -> shard immediately runs and streams record!
            ext_count[0] = 4
            t.join(timeout=5.0)
            self.assertFalse(t.is_alive())
            self.assertEqual(ran_shards, [0])

            # Verify live JSON files updated atomically
            status_doc = json.loads((state_dir / "latest_status.json").read_text(encoding="utf-8"))
            alerts_doc = json.loads((state_dir / "latest_alerts.json").read_text(encoding="utf-8"))
            self.assertEqual(status_doc["active_rev"], rev_id)
            self.assertEqual(status_doc["tactics_summary"]["n"], 1)
            self.assertEqual(status_doc["tactics_summary"]["passed"], 1)
            self.assertEqual(alerts_doc["count"], 0)
            conn.close()

    def test_cli_status_report_alerts_pause_resume(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            arena_dir, _ = _make_synthetic_arena(root, num_core=6, num_unseen=2)
            fake_repo = _make_fake_repo(root)
            state_dir = root / "continuous_eval"
            snaps_dir = root / "snapshots"
            base_args = [
                "--arena-dir", str(arena_dir),
                "--state-dir", str(state_dir),
                "--snapshots-dir", str(snaps_dir),
                "--repo-dir", str(fake_repo),
            ]

            def _run_cli(extra: list[str]) -> str:
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    rc = CE.main(base_args + extra)
                self.assertEqual(rc, 0)
                return buf.getvalue()

            # Snapshot + enqueue + pause + resume
            snap_out = json.loads(_run_cli(["snapshot", "--label", "cli_test", "--json"]))
            self.assertTrue(Path(snap_out["snapshot_dir"]).is_dir())

            enq_out = json.loads(
                _run_cli([
                    "enqueue", "--label", "cli_run",
                    "--snapshot-dir", snap_out["snapshot_dir"],
                    "--tiers", "tier1", "--json",
                ])
            )
            rev_id = enq_out["rev_id"]

            _run_cli(["pause"])
            st_paused = json.loads(_run_cli(["status", "--json"]))
            self.assertTrue(st_paused["daemon"]["paused"])

            _run_cli(["resume"])
            st_resumed = json.loads(_run_cli(["status", "--json"]))
            self.assertFalse(st_resumed["daemon"]["paused"])
            self.assertEqual(st_resumed["active_rev"], rev_id)

            # Human-readable status & report
            st_txt = _run_cli(["status"])
            self.assertIn("Continuous Eval Daemon:", st_txt)
            rep_doc = json.loads(_run_cli(["report", "--rev", rev_id, "--json"]))
            for bucket in ("ALL", "EXT_Z", "EXT_T", "EXT_P", "SELF_6", "CORE", "UNSEEN"):
                self.assertIn(bucket, rep_doc["ladder_breakdown"])
            rep_txt = _run_cli(["report", "--rev", rev_id])
            self.assertIn("CONTINUOUS EVAL REPORT", rep_txt)

            # Insert a test alert and verify alerts + --ack
            conn = CE.open_db(state_dir / "eval_stream.sqlite")
            with conn:
                CE._upsert_alert(
                    conn, rev_id, "", "hard_fault", "critical", "Mothman-Z_vs_X",
                    "crashes", 1.0, 0.0, 1, "Crash test"
                )
            conn.close()

            al_before = json.loads(_run_cli(["alerts", "--rev", rev_id, "--unacked-only", "--json"]))
            self.assertEqual(al_before["count"], 1)
            _run_cli(["alerts", "--rev", rev_id, "--ack", "--severity", "critical", "--json"])
            al_after = json.loads(_run_cli(["alerts", "--rev", rev_id, "--unacked-only", "--json"]))
            self.assertEqual(al_after["count"], 0)

    def test_self_cancel_loops_list_and_log_nonzero_guard(self) -> None:
        # 1. Per-match anomalies.self_cancel_loops list extraction in _extract_self_cancel_count and seed_baseline
        self.assertEqual(
            CE._extract_self_cancel_count({"anomalies": {"self_cancel_loops": []}}), 0
        )
        self.assertEqual(
            CE._extract_self_cancel_count({
                "anomalies": {
                    "self_cancel_loops": [
                        {"unit": "hatchery", "count": 3},
                        {"unit": "lair", "count": 2},
                    ]
                }
            }),
            2,
        )
        self.assertEqual(
            CE._extract_self_cancel_count({"anomalies": {"self_cancel_loop": 1}}), 1
        )

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            score_path = root / "score_loops.json"
            score_path.write_text(
                json.dumps({
                    "matches": [
                        {
                            "our_bot": "Mothman-Z",
                            "our_race": "Zerg",
                            "opp_bot": "SynthBot_01",
                            "opp_cohort": "core_12",
                            "result": "loss",
                            "game_state_score": 0.25,
                            "anomalies": {
                                "self_cancel_loops": [
                                    {"unit": "spawning_pool"},
                                    {"unit": "roach_warren"},
                                ]
                            },
                        },
                        {
                            "our_bot": "Mothman-P",
                            "our_race": "Protoss",
                            "opp_bot": "SynthBot_02",
                            "opp_cohort": "core_12",
                            "result": "win",
                            "game_state_score": 0.91,
                            "anomalies": {"self_cancel_loops": []},
                        },
                    ]
                }),
                encoding="utf-8",
            )
            conn = CE.open_db(root / "eval.sqlite")
            try:
                CE.seed_baseline(conn, rev_id="loops_rev", from_score_json=score_path)
                z_sc = conn.execute(
                    "SELECT self_cancel FROM ladder_results WHERE rev_id='loops_rev' AND bot='Mothman-Z'"
                ).fetchone()["self_cancel"]
                p_sc = conn.execute(
                    "SELECT self_cancel FROM ladder_results WHERE rev_id='loops_rev' AND bot='Mothman-P'"
                ).fetchone()["self_cancel"]
                self.assertEqual(z_sc, 2)
                self.assertEqual(p_sc, 0)
            finally:
                conn.close()

            # 2. Log parser must ignore `self_cancel=0` / `arbiter_error=0` and count real events / non-zero values
            clean_log = root / "clean.log"
            clean_log.write_text(
                "[SUMMARY] self_cancel=0 self-cancel=0 arbiter_error=0 arbiter-error: 0\n"
                "[INFO] status ok self_cancel_loops=0\n",
                encoding="utf-8",
            )
            t_clean = CE.parse_match_log_telemetry(clean_log)
            self.assertEqual(t_clean["self_cancel"], 0)
            self.assertEqual(t_clean["arbiter_error"], 0)

            fault_log = root / "fault.log"
            fault_log.write_text(
                "[WARN] self_cancel=2\n"
                "[SELF_CANCEL] canceled nexus loop\n"
                "[ARBITER_ERROR] invalid transition\n"
                "[SUMMARY] arbiter_error=3\n",
                encoding="utf-8",
            )
            t_fault = CE.parse_match_log_telemetry(fault_log)
            self.assertEqual(t_fault["self_cancel"], 3)
            self.assertEqual(t_fault["arbiter_error"], 4)

    def test_max_loadavg_throttling_and_dashboard_reader(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            arena_dir, canary = _make_synthetic_arena(root, num_core=6, num_unseen=0)
            fake_repo = _make_fake_repo(root)
            state_dir = root / "continuous_eval"
            snaps_dir = root / "snapshots"
            conn = CE.open_db(state_dir / "eval_stream.sqlite")
            CE.enqueue_revision(
                conn=conn,
                repo_dir=fake_repo,
                arena_dir=arena_dir,
                state_dir=state_dir,
                snapshots_dir=snaps_dir,
                label="load_test",
                tiers_spec="tier1_core_dummy",
                canary_opponents=canary,
            )
            with conn:
                conn.execute("DELETE FROM tactics_queue WHERE shard_index > 0")
            conn.close()

            load_val = [24.5]
            ran: list[int] = []

            def mock_tactics_runner(
                item: dict[str, Any],
                _rev_meta: dict[str, Any],
                _sjsonl: Path,
                _ojson: Path,
                on_record: Any,
            ) -> list[dict[str, Any]]:
                ran.append(item["shard_index"])
                on_record({
                    "scenario_id": "sc2-load-01",
                    "category": "kiting-concave",
                    "terrain": "open",
                    "race": "Terran",
                    "enemy_race": "Zerg",
                    "passed": True,
                    "trade_ratio": 2.2,
                })
                return []

            daemon = CE.EvalDaemon(
                repo_dir=fake_repo,
                arena_dir=arena_dir,
                state_dir=state_dir,
                snapshots_dir=snaps_dir,
                ladder_workers=0,
                tactics_workers=1,
                max_total_sc2=10,
                max_loadavg=20.0,
                poll_sec=0.05,
                once=True,
                tactics_runner=mock_tactics_runner,
                active_sc2_counter=lambda: 0,
                loadavg_getter=lambda: load_val[0],
            )
            t = threading.Thread(target=daemon.run_forever, kwargs={"write_pid": False}, daemon=True)
            t.start()

            # Loadavg 24.5 >= 20.0 -> must defer launching
            time.sleep(0.18)
            self.assertEqual(ran, [])

            # Drop loadavg below 20.0 -> launches immediately
            load_val[0] = 12.0
            t.join(timeout=5.0)
            self.assertFalse(t.is_alive())
            self.assertEqual(ran, [0])

            # Verify update-dashboard-state.py fail-safe reader (no-op on empty dir, compact block when present)
            dash_mod = _load_module("update_dashboard_state_under_test", REPO_ROOT / "tools" / "update-dashboard-state.py")
            self.assertIsNone(dash_mod.collect_continuous_eval(root / "nonexistent_ce"))
            ce_block = dash_mod.collect_continuous_eval(state_dir)
            self.assertIsInstance(ce_block, dict)
            self.assertEqual(ce_block["tactics_summary"]["passed"], 1)
            self.assertIn("recent_alerts", ce_block)

    def test_snapshot_precompile_zo_and_no_compile_flag(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            fake_repo = root / "mini_rkt_repo"
            (fake_repo / "lib" / "compiled").mkdir(parents=True)
            (fake_repo / "bots").mkdir(parents=True)
            (fake_repo / "lib" / "bot.rkt").write_text(
                "#lang racket/base\n(provide answer)\n(define answer 42)\n",
                encoding="utf-8",
            )
            (fake_repo / "lib" / "compiled" / "stale_rkt.zo").write_bytes(b"stale")
            (fake_repo / "bots" / "Mothman-Z.rkt").write_text(
                '#lang racket/base\n(require "../lib/bot.rkt")\n(void answer)\n',
                encoding="utf-8",
            )
            snaps_dir = root / "snapshots"

            # 1. precompile=False prunes stale .zo and records compiled_zo_count=0
            m_no = CE.create_repo_snapshot(
                fake_repo, snaps_dir, label="nocomp", explicit_rev_id="rev_nocomp", precompile=False
            )
            s_no = Path(m_no["snapshot_dir"])
            self.assertEqual(m_no["compiled_zo_count"], 0)
            self.assertFalse((s_no / "lib" / "compiled").exists())

            # 2. precompile=True compiles fresh .zo strictly inside snapshot_dir (never inside fake_repo)
            m_yes = CE.create_repo_snapshot(
                fake_repo,
                snaps_dir,
                label="comp",
                explicit_rev_id="rev_comp",
                precompile=True,
                compile_jobs=2,
                clean_compile=True,
            )
            s_yes = Path(m_yes["snapshot_dir"])
            meta_doc = json.loads((s_yes / ".snapshot_meta.json").read_text(encoding="utf-8"))
            self.assertGreaterEqual(meta_doc["compiled_zo_count"], 2)
            self.assertFalse((s_yes / "lib" / "compiled" / "stale_rkt.zo").exists())
            self.assertTrue((s_yes / "bots" / "compiled" / "Mothman-Z_rkt.zo").is_file())
            self.assertTrue((s_yes / "lib" / "compiled" / "bot_rkt.zo").is_file())
            # Source repo must NOT receive any new compiled files
            self.assertFalse((fake_repo / "bots" / "compiled").exists())
            self.assertFalse((fake_repo / "lib" / "compiled" / "bot_rkt.zo").exists())


if __name__ == "__main__":
    unittest.main()
