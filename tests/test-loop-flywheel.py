#!/usr/bin/env python3
"""
Unit & integration tests for the Mothman SC2 Loop Trajectory Flywheel & Pro Comparator:
  - tools/iteration-loop/log-loop-trajectory.py
  - tools/iteration-loop/analyze-loop-flywheel.py
  - tools/iteration-loop/compare-vs-pro.py (read-only SQLite Stall Watchdog & Base Geometry KPIs)
  - tools/iteration-loop/loop_trajectory_log.jsonl (live backfill integrity)

Runs completely offline in <1s with zero GPU, zero Podman, and zero writes to
live repo files or live SQLite databases.
"""

from __future__ import annotations

import importlib.util
import json
import math
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LOGGER_PATH = REPO_ROOT / "tools/iteration-loop/log-loop-trajectory.py"
ANALYZER_PATH = REPO_ROOT / "tools/iteration-loop/analyze-loop-flywheel.py"
COMPARE_PATH = REPO_ROOT / "tools/iteration-loop/compare-vs-pro.py"
LIVE_JSONL = REPO_ROOT / "tools/iteration-loop/loop_trajectory_log.jsonl"


def _load_mod(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, str(path))
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


LOG_MOD = _load_mod("log_loop_trajectory_testmod", LOGGER_PATH)
ANA_MOD = _load_mod("analyze_loop_flywheel_testmod", ANALYZER_PATH)
CMP_MOD = _load_mod("compare_vs_pro_testmod", COMPARE_PATH)


def _write_jsonl(path: Path, objs):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for o in objs:
            f.write(json.dumps(o) + "\n")


def _build_synthetic_workspace(root: Path):
    """Build a realistic 3-loop (L45 SHIP-ZIP, L46 HOLD-ZIP, L47 HOLD-ZIP) workspace."""
    brain = root / "brain"
    coord_id = "11111111-1111-1111-1111-111111111111"
    rt_id = "22222222-2222-2222-2222-222222222222"
    ver_id = "33333333-3333-3333-3333-333333333333"
    tac_id = "44444444-4444-4444-4444-444444444444"
    ana_id = "55555555-5555-5555-5555-555555555555"
    la_id = "66666666-6666-6666-6666-666666666666"

    (brain / coord_id / "scratch/loop").mkdir(parents=True, exist_ok=True)

    # Synthetic score & tactics JSONs
    scratch = root / "scratch"
    scratch.mkdir(parents=True, exist_ok=True)

    def mk_score(p: Path, wins: int, losses: int, h2h: bool = False):
        matches = []
        for i in range(wins + losses):
            res = "win" if i < wins else "loss"
            opp = "Mothman-P-Base" if h2h else ("puck" if i % 2 == 0 else "PolyMorph")
            race = ["Protoss", "Terran", "Zerg"][i % 3]
            matches.append(
                {
                    "id": str(i + 1),
                    "our_bot": f"Mothman-{race[0]}",
                    "opp_bot": opp,
                    "our_race": race,
                    "result": res,
                    "killed_val": 10000 if res == "win" else 2000,
                    "lost_val": 3000 if res == "win" else 8000,
                    "trade_ratio": 3.33 if res == "win" else 0.25,
                    "supply_block_pct": 3.5,
                }
            )
        p.write_text(json.dumps({"matches": matches}), encoding="utf-8")

    def mk_tactics(p: Path, total: int, w: int, l: int, d: int, trade: float, wall_ms: int):
        p.write_text(
            json.dumps(
                {
                    "total_wall_ms": wall_ms,
                    "summary": {
                        "total": total,
                        "mothman_wins": w,
                        "p2_wins": l,
                        "draws": d,
                        "agg_trade_ratio": trade,
                        "am_ratio": 3.5,
                        "by_tier": {"econ-harass": {"total_enemy_workers_killed": 55}},
                    },
                }
            ),
            encoding="utf-8",
        )

    for lid, ew, el, hw, hl, sp_tot in [
        (45, 25, 53, 4, 2, 65),  # L45 SHIP-ZIP with early-end SP 65/66 drop
        (46, 21, 57, 2, 4, 66),  # L46 HOLD-ZIP Protoss PvP 0-7 / 0-Colossus
        (47, 24, 54, 3, 3, 66),  # L47 HOLD-ZIP Brain<->Runtime cap mismatch
    ]:
        mk_score(scratch / f"iter{lid}_full_score.json", ew, el, h2h=False)
        mk_score(scratch / f"iter{lid}_h2h_score.json", hw, hl, h2h=True)
        mk_tactics(scratch / f"tactics_d_{lid}.json", 66, 34, 29, 3, 1.09, 162000)
        mk_tactics(scratch / f"tactics_sp_{lid}.json", sp_tot, 28, 34, 4, 0.82, 165000)

    # Synthetic read-only SQLite DB
    db_path = root / "arena_replays.sqlite"
    con = sqlite3.connect(db_path)
    con.execute(
        "CREATE TABLE runs (run_id TEXT, started_at TEXT, wall_elapsed_sec REAL, "
        "total_replays INTEGER, git_rev TEXT, mothman_mode TEXT)"
    )
    con.executemany(
        "INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?)",
        [
            ("20261121_143000_iter45_wave45_full", "2026-11-21T14:30:00Z", 1740.0, 84, "abc45", "source"),
            ("20261121_150000_iter45_baseline_h2h", "2026-11-21T15:00:00Z", 110.0, 6, "abc45", "source"),
            ("20261121_160000_iter46_wave46_full", "2026-11-21T16:00:00Z", 1760.0, 84, "abc46", "source"),
            ("20261121_163000_iter46_baseline_h2h", "2026-11-21T16:30:00Z", 120.0, 6, "abc46", "source"),
            ("20261121_173000_iter47_wave47_full", "2026-11-21T17:30:00Z", 1800.0, 84, "abc47", "source"),
            ("20261121_180000_iter47_baseline_h2h", "2026-11-21T18:00:00Z", 100.0, 6, "abc47", "source"),
        ],
    )
    con.commit()
    con.close()

    # Synthetic loop_ledger.json
    ledger_path = root / "loop_ledger.json"
    ledger = {
        "schema_version": 1,
        "active_wave": "iter47_wave47_full",
        "iterations": [
            {
                "id": "iter45_wave45_full",
                "status": "UNCONDITIONAL_LIVE_SHIP_6_4W_2L",
                "rev": "abc45",
                "spec_summary": "Loop 45 Ship #6: r02/r05/r06 and 0-Colossus watch; p15 recall watch.",
                "run_dir": "/tmp/runs/20261121_143000_iter45_wave45_full",
                "baseline_h2h_run_dir": "/tmp/runs/20261121_150000_iter45_baseline_h2h",
                "score_json": str(scratch / "iter45_full_score.json"),
                "baseline_h2h_score_json": str(scratch / "iter45_h2h_score.json"),
                "tactics_json": str(scratch / "tactics_d_45.json"),
                "tactics_selfplay_json": str(scratch / "tactics_sp_45.json"),
                "prod_placement_stall_matches": 1,
                "cloaked_unit_damage_losses": 1,
            },
            {
                "id": "iter46_wave46_full",
                "status": "HOLD_ZIP_PROTOSS_PVP_DIP",
                "rev": "abc46",
                "spec_summary": "Loop 46 HOLD-ZIP: Protoss PvP 0-7 dip, 0-Colossus RoboticsBay delay, r02/r05/r06 6f stack, p15 KO WIN.",
                "run_dir": "/tmp/runs/20261121_160000_iter46_wave46_full",
                "baseline_h2h_run_dir": "/tmp/runs/20261121_163000_iter46_baseline_h2h",
                "score_json": str(scratch / "iter46_full_score.json"),
                "baseline_h2h_score_json": str(scratch / "iter46_h2h_score.json"),
                "tactics_json": str(scratch / "tactics_d_46.json"),
                "tactics_selfplay_json": str(scratch / "tactics_sp_46.json"),
                "prod_placement_stall_matches": 2,
                "cloaked_unit_damage_losses": 1,
            },
            {
                "id": "iter47_wave47_full",
                "status": "HOLD_ZIP_BRAIN_RUNTIME_CAP_MISMATCH",
                "rev": "abc47",
                "spec_summary": "Loop 47 HOLD-ZIP: H2H 3W-3L, raw-desired-barracks prod_stall=132, Phoenix@860 > Colossus@760, r02/r05/r06 3666 regression, p15 1.58x.",
                "run_dir": "/tmp/runs/20261121_173000_iter47_wave47_full",
                "baseline_h2h_run_dir": "/tmp/runs/20261121_180000_iter47_baseline_h2h",
                "score_json": str(scratch / "iter47_full_score.json"),
                "baseline_h2h_score_json": str(scratch / "iter47_h2h_score.json"),
                "tactics_json": str(scratch / "tactics_d_47.json"),
                "tactics_selfplay_json": str(scratch / "tactics_sp_47.json"),
                "prod_placement_stall_matches": 3,
                "cloaked_unit_damage_losses": 0,
            },
        ],
    }
    ledger_path.write_text(json.dumps(ledger, indent=2), encoding="utf-8")

    # Synthetic coordinator transcript (includes sender=<uuid> wakeups + phase dispatches!)
    coord_steps = [
        {"step_index": 0, "type": "SYSTEM_MESSAGE", "created_at": "2026-11-21T14:00:00Z", "content": f"sender={rt_id} sender={ver_id} sender={tac_id} sender={ana_id} sender={la_id}"},
        # Loop 45 launch -> Gate 1 -> Tactics -> Archival (overlaps into Loop 46!)
        {"step_index": 1, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T14:00:00Z", "input_tokens": 1000, "cache_read_tokens": 9000, "output_tokens": 200, "tool_calls": [{"name": "post_message", "args": {"text": '"@runtime-author LAUNCHING LOOP 45"'}}]},
        {"step_index": 2, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T14:15:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@verifier Loop 45 Gate 1 Verification"'}}]},
        {"step_index": 3, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T14:18:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@tactics-tester Loop 45 Tactics Arena"'}}]},
        {"step_index": 4, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T15:05:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@loop-architect Loop 45 Ship #6 archival"'}}]},
        # Loop 46 launch (overlaps Loop 45 archival!) -> Gate 1 -> Tactics -> Forensics
        {"step_index": 5, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T15:10:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@runtime-author LAUNCHING LOOP 46"'}}]},
        {"step_index": 6, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T15:40:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@verifier Loop 46 Gate 1 Verification"'}}]},
        {"step_index": 7, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T15:44:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@tactics-tester Loop 46 Tactics Arena"'}}]},
        {"step_index": 8, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T16:35:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@analyzer Loop 46 forensics"'}}]},
        # Loop 47 launch -> Gate 1 -> Tactics -> Forensics
        {"step_index": 9, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T16:50:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@runtime-author LAUNCHING LOOP 47"'}}]},
        {"step_index": 10, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T17:10:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@verifier Loop 47 Gate 1 Verification"'}}]},
        {"step_index": 11, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T17:13:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@tactics-tester Loop 47 Tactics Arena"'}}]},
        {"step_index": 12, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T18:05:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@analyzer Loop 47 forensics"'}}]},
        # Loop 48 launch closes Loop 47 cleanly
        {"step_index": 13, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T18:15:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@runtime-author LAUNCHING LOOP 48"'}}]},
    ]
    _write_jsonl(brain / coord_id / ".system_generated/logs/transcript.jsonl", coord_steps)

    # Runtime-author transcript: monolith reads (with quoted paths!), raco make, run-all-tests, ownership request,
    # 3 edit_file mismatches, CPU contention false fail, and revert!
    rt_steps = [
        {"step_index": 0, "type": "SYSTEM_MESSAGE", "created_at": "2026-11-21T14:00:00Z", "content": "@runtime-author own lib/bot-runtime.rkt"},
        {"step_index": 1, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T15:15:00Z", "input_tokens": 500, "cache_read_tokens": 9500, "output_tokens": 300, "tool_calls": [
            {"name": "read_file", "args": {"Path": '"/home/fakeuser/repos/mothman-sc2-bot/lib/bot-runtime.rkt"'}},
            {"name": "edit_file", "args": {"Path": '"/home/fakeuser/repos/mothman-sc2-bot/lib/bot-runtime.rkt"'}},
            {"name": "run_command", "args": {"CommandLine": '"raco make lib/bot-runtime.rkt && racket tests/run-all-tests.rkt"'}},
        ]},
        # 3 edit target mismatches in Loop 46 -> triggers edit_target_mismatch_churn
        {"step_index": 2, "type": "GENERIC", "status": "ERROR", "created_at": "2026-11-21T15:16:00Z", "error": "target content not found in the file"},
        {"step_index": 3, "type": "GENERIC", "status": "ERROR", "created_at": "2026-11-21T15:17:00Z", "error": "target content not found in the file"},
        {"step_index": 4, "type": "GENERIC", "status": "ERROR", "created_at": "2026-11-21T15:18:00Z", "error": "target content not found in the file"},
        {"step_index": 5, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T15:20:00Z", "tool_calls": [
            {"name": "post_message", "args": {"text": '"@coordinator Quick scope check: OK for me to update tests/l44-tactics-runtime-test.rkt? Also Suite 28 <5ms hit loadavg=12.6 under renders."'}},
        ]},
        # Loop 47 revert post + monolith read
        {"step_index": 6, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T16:55:00Z", "tool_calls": [
            {"name": "read_file", "args": {"Path": '"/home/fakeuser/repos/mothman-sc2-bot/lib/bot-runtime.rkt"'}},
            {"name": "post_message", "args": {"text": '"@coordinator Reverted L46 threshold back to L45 for r02/r05/r06 and fixed raw-desired-barracks cap mismatch."'}},
        ]},
    ]
    _write_jsonl(brain / rt_id / ".system_generated/logs/transcript.jsonl", rt_steps)

    # Verifier transcript
    ver_steps = [
        {"step_index": 0, "type": "SYSTEM_MESSAGE", "created_at": "2026-11-21T14:00:00Z", "content": "@verifier verify gates"},
        {"step_index": 1, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T14:17:30Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@coordinator Loop 45 Gate 1 GO"'}}]},
        {"step_index": 2, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T15:43:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@coordinator Loop 46 Gate 1 GO"'}}]},
        {"step_index": 3, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T17:12:30Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@coordinator Loop 47 Gate 1 GO"'}}]},
    ]
    _write_jsonl(brain / ver_id / ".system_generated/logs/transcript.jsonl", ver_steps)

    # Tactics-tester transcript
    tac_steps = [
        {"step_index": 0, "type": "SYSTEM_MESSAGE", "created_at": "2026-11-21T14:00:00Z", "content": "@tactics-tester run arena"},
        {"step_index": 1, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T14:25:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@coordinator Loop 45 Tactics Arena COMPLETE"'}}]},
        {"step_index": 2, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T15:52:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@coordinator Loop 46 Tactics Arena COMPLETE"'}}]},
        {"step_index": 3, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T17:21:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@coordinator Loop 47 Tactics Arena COMPLETE"'}}]},
    ]
    _write_jsonl(brain / tac_id / ".system_generated/logs/transcript.jsonl", tac_steps)

    # Analyzer transcript
    ana_steps = [
        {"step_index": 0, "type": "SYSTEM_MESSAGE", "created_at": "2026-11-21T14:00:00Z", "content": "@analyzer run forensics"},
        {"step_index": 1, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T16:43:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@coordinator Loop 46 Forensics COMPLETE SQLite IDLE"'}}]},
        {"step_index": 2, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T18:12:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@coordinator Loop 47 Forensics COMPLETE SQLite IDLE"'}}]},
    ]
    _write_jsonl(brain / ana_id / ".system_generated/logs/transcript.jsonl", ana_steps)

    # Loop-architect transcript: includes overlapped L45 archival completion + transient WS render error in L46!
    la_steps = [
        {"step_index": 0, "type": "SYSTEM_MESSAGE", "created_at": "2026-11-21T14:00:00Z", "content": "@loop-architect archive replays"},
        {"step_index": 1, "type": "PLANNER_RESPONSE", "created_at": "2026-11-21T15:18:00Z", "tool_calls": [{"name": "post_message", "args": {"text": '"@coordinator Loop 45 Ship #6 archival COMPLETE"'}}]},
        {"step_index": 2, "type": "GENERIC", "created_at": "2026-11-21T16:40:00Z", "content": "Command exited with code 1\nwebsockets.exceptions.ConnectionClosedError: no close frame received or sent"},
    ]
    _write_jsonl(brain / la_id / ".system_generated/logs/transcript.jsonl", la_steps)

    return brain, coord_id, ledger_path, db_path


class TestLoopFlywheel(unittest.TestCase):
    def test_unquote_arg_and_error_classification(self):
        self.assertEqual(LOG_MOD.unquote_arg('"/a/b/bot-runtime.rkt"'), "/a/b/bot-runtime.rkt")
        self.assertEqual(LOG_MOD.unquote_arg("plain/path.py"), "plain/path.py")
        self.assertEqual(LOG_MOD.unquote_arg(None), "")
        self.assertEqual(LOG_MOD.classify_tool_error("target content not found in the file"), "edit_target_mismatch")
        self.assertEqual(LOG_MOD.classify_tool_error("ConnectionClosedError: unexpected end of stream"), "ws_connection_closed")
        self.assertEqual(LOG_MOD.classify_tool_error("No such file or directory"), "file_not_found")
        self.assertEqual(LOG_MOD.classify_tool_error("sqlite3.OperationalError: database is locked"), "sqlite_error")
        self.assertEqual(LOG_MOD.classify_tool_error("command timed out"), "timeout")

    def test_auto_discovery_logging_and_frictions(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            brain, coord_id, ledger_path, db_path = _build_synthetic_workspace(root)

            # Verify auto-discovery without passing coordinator_id!
            discovered = LOG_MOD.discover_swarm_transcripts(brain, coordinator_id=None)
            self.assertIn("coordinator", discovered)
            self.assertIn("runtime-author", discovered)
            self.assertIn("verifier", discovered)
            self.assertIn("tactics-tester", discovered)
            self.assertIn("analyzer", discovered)
            self.assertIn("loop-architect", discovered)

            records = LOG_MOD.build_trajectory_records(
                ledger_path=ledger_path,
                brain_root=brain,
                coordinator_id=None,
                db_path=db_path,
                from_loop=45,
                to_loop=47,
            )
            self.assertEqual([r["loop_id"] for r in records], [45, 46, 47])
            by_lid = {r["loop_id"]: r for r in records}

            # Loop 45: SHIP-ZIP, overlapped archival (15:05 -> 15:18, loop ended 15:10 -> 8m overlap!), early-end drop 65/66
            r45 = by_lid[45]
            self.assertEqual(r45["ship_verdict"], "SHIP-ZIP")
            self.assertEqual(r45["ship_number"], 6)
            self.assertAlmostEqual(r45["phase_durations_sec"]["archival_render"], 780.0, delta=5.0)
            self.assertAlmostEqual(r45["phase_durations_sec"]["overlapped_post_bench_sec"], 480.0, delta=5.0)
            f45 = {f["kind"] for f in r45["friction_events"]}
            self.assertIn("arena_early_end_drop", f45)

            # Loop 46: HOLD-ZIP, monolith_reads, raco_make, full_test, clean relative edited_files, multiple frictions
            r46 = by_lid[46]
            self.assertEqual(r46["ship_verdict"], "HOLD-ZIP")
            rt46 = r46["agent_trajectories"]["runtime-author"]
            self.assertEqual(rt46["monolith_reads"].get("bot-runtime.rkt"), 1)
            self.assertEqual(rt46["raco_make_calls"], 1)
            self.assertEqual(rt46["full_test_calls"], 1)
            self.assertEqual(rt46["edited_files"], ["lib/bot-runtime.rkt"])  # No /home/fakeuser leak!
            self.assertEqual(rt46["ownership_requests"], 1)
            f46 = {f["kind"] for f in r46["friction_events"]}
            for expected in (
                "ownership_ping_pong",
                "cpu_contention_false_fail",
                "edit_target_mismatch_churn",
                "transient_renderer_retry",
                "late_h2h_caught_regression",
            ):
                self.assertIn(expected, f46, f"Missing expected friction {expected} in {f46}")

            # Loop 47: HOLD-ZIP, revert + brain_runtime_cap_mismatch
            r47 = by_lid[47]
            f47 = {f["kind"] for f in r47["friction_events"]}
            self.assertIn("reverted_or_flipflop_rule", f47)
            self.assertIn("brain_runtime_cap_mismatch", f47)
            self.assertIn("late_h2h_caught_regression", f47)

    def test_upsert_jsonl_idempotency(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "traj.jsonl"
            LOG_MOD.upsert_jsonl(out, [{"loop_id": 47, "v": 1}, {"loop_id": 45, "v": 1}])
            merged = LOG_MOD.upsert_jsonl(out, [{"loop_id": 46, "v": 1}, {"loop_id": 47, "v": 2}])
            self.assertEqual([r["loop_id"] for r in merged], [45, 46, 47])
            self.assertEqual(merged[2]["v"], 2)
            # File on disk matches exactly 3 lines
            disk_lines = [l for l in out.read_text(encoding="utf-8").splitlines() if l.strip()]
            self.assertEqual(len(disk_lines), 3)

    def test_flywheel_analyzer_end_to_end(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            brain, coord_id, ledger_path, db_path = _build_synthetic_workspace(root)
            jsonl_path = root / "loop_trajectory_log.jsonl"
            out_md = root / "retro.md"
            out_json = root / "retro.json"

            # Run both CLI scripts as real subprocesses
            p1 = subprocess.run(
                [
                    sys.executable,
                    str(LOGGER_PATH),
                    "--brain-root", str(brain),
                    "--coordinator-id", coord_id,
                    "--ledger", str(ledger_path),
                    "--replay-db", str(db_path),
                    "--out-jsonl", str(jsonl_path),
                    "--from-loop", "45",
                    "--to-loop", "47",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(p1.returncode, 0, f"logger failed: {p1.stderr}\n{p1.stdout}")
            self.assertIn("TRAJECTORY_LOG_OK", p1.stdout)

            p2 = subprocess.run(
                [
                    sys.executable,
                    str(ANALYZER_PATH),
                    "--jsonl", str(jsonl_path),
                    "--ledger", str(ledger_path),
                    "--out-md", str(out_md),
                    "--out-json", str(out_json),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(p2.returncode, 0, f"analyzer failed: {p2.stderr}\n{p2.stdout}")
            self.assertIn("FLYWHEEL_RETRO_OK", p2.stdout)

            rep = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertEqual(rep["loops_analyzed"], 3)
            self.assertEqual(rep["loop_span"], [45, 47])

            ht = rep["hold_taxonomy"]
            self.assertEqual(ht["ship_zip_count"], 1)
            self.assertEqual(ht["hold_zip_count"], 2)
            # Flip-flop detector must catch both r02/r05/r06 and 0-Colossus across L45, L46, L47!
            ff_keys = {x["topic_key"] for x in ht["flip_flops"]}
            self.assertIn("worker_rush_r02_r05_r06", ff_keys)
            self.assertIn("zero_colossus_robobay", ff_keys)

            cf = rep["counterfactual_simulator"]
            self.assertGreater(cf["combined_saved_min"], 30.0)
            self.assertGreater(cf["effective_speedup_x"], 1.15)
            self.assertLess(cf["projected_min_per_ship"], cf["actual_min_per_ship"])
            self.assertEqual(len(rep["ranked_patches"]), 5)

            md_text = out_md.read_text(encoding="utf-8")
            self.assertIn("Build and Test Cycle Timing Review (Loops 45", md_text)
            self.assertIn("1. Where Time Goes Each Run", md_text)
            self.assertIn("2. Agent Steps, Errors, and Retries", md_text)
            self.assertIn("3. Why Held Builds Failed & Repeated Edits", md_text)
            self.assertIn("4. Time Saved by Reordering Gates", md_text)
            self.assertIn("5. Workflow Changes Applied", md_text)
            self.assertNotIn("Recommended Flywheel Guard", md_text)
            self.assertNotIn("Trajectory Flywheel", md_text)
            self.assertNotIn("/home/fakeuser", md_text)
            # Arithmetic consistency: recent ships + holds must match reported recent n
            rec_c = ht["recent_l37_l47_counts"]
            self.assertEqual(rec_c["n"], rec_c["ships"] + rec_c["holds"])
            self.assertIn(f"recent `{rec_c['n']}` runs", md_text)
            # Ephemeral worker-XXXXXXXX roles must be filtered from agent scorecard
            fake_rows = ANA_MOD.load_jsonl(jsonl_path)
            fake_rows[0]["agent_trajectories"]["worker-78877342"] = {"steps": 12, "tool_calls_total": 5}
            sc_filtered = ANA_MOD.compute_agent_scorecard(fake_rows)
            self.assertNotIn("worker-78877342", [a["role"] for a in sc_filtered["agents"]])

    def test_live_backfilled_trajectory_log_integrity(self):
        self.assertTrue(LIVE_JSONL.is_file(), f"Missing backfilled log: {LIVE_JSONL}")
        rows = ANA_MOD.load_jsonl(LIVE_JSONL)
        self.assertGreaterEqual(len(rows), 32, "Expected Loops 19..50 logged (>=32 rows)")
        lids = [r["loop_id"] for r in rows]
        self.assertEqual(lids, sorted(set(lids)), "loop_id must be strictly unique & ascending")
        self.assertLessEqual(lids[0], 19)
        self.assertGreaterEqual(lids[-1], 50)

        raw_text = LIVE_JSONL.read_text(encoding="utf-8")
        # Hygiene: no home paths in edited_files & no bearer/token leaks
        self.assertNotIn("ghp_", raw_text)
        self.assertNotIn("AIza", raw_text)
        for r in rows:
            self.assertEqual(r.get("schema_version"), 1)
            self.assertIn(r.get("ship_verdict"), ("SHIP-ZIP", "HOLD-ZIP", "CHECKPOINT"))
            self.assertGreater(r.get("total_wall_sec", 0), 0)
            for a in (r.get("agent_trajectories") or {}).values():
                for ef in a.get("edited_files") or []:
                    self.assertFalse(ef.startswith("/home/"), f"Home path leaked in edited_files: {ef}")

    def test_arena_passes_tracking_and_deltas(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            p0_path = root / "pass0_ability.json"
            p1_path = root / "pass1_ability.json"
            p2_path = root / "pass2_ability.json"

            def _write_arena(path: Path, scens, w, l, d, trade_agg, wall_ms):
                payload = {
                    "total_wall_ms": wall_ms,
                    "summary": {
                        "total": len(scens),
                        "mothman_wins": w,
                        "p2_wins": l,
                        "draws": d,
                        "agg_trade_ratio": trade_agg,
                        "record_str": f"{w}W-{l}L-{d}D",
                    },
                    "scenarios": scens,
                }
                path.write_text(json.dumps(payload), encoding="utf-8")

            # Pass 0: 1W-2L, 1/3 spell_verified
            _write_arena(
                p0_path,
                [
                    {"id": "sp01", "winner": "mothman", "trade_ratio": 2.0, "expected_abilities": ["PsiStorm"], "spell_verified": True},
                    {"id": "sp02", "winner": "p2", "trade_ratio": 0.4, "expected_abilities": ["EMP"], "spell_verified": False},
                    {"id": "sp03", "winner": "p2", "trade_ratio": 0.5, "expected_abilities": ["Abduct"], "spell_verified": False},
                ],
                w=1, l=2, d=0, trade_agg=0.95, wall_ms=60000,
            )
            # Pass 1: improves sp02 (+spell), temporarily regresses sp01
            _write_arena(
                p1_path,
                [
                    {"id": "sp01", "winner": "p2", "trade_ratio": 0.6, "expected_abilities": ["PsiStorm"], "spell_verified": False},
                    {"id": "sp02", "winner": "mothman", "trade_ratio": 2.4, "expected_abilities": ["EMP"], "spell_verified": True},
                    {"id": "sp03", "winner": "p2", "trade_ratio": 0.7, "expected_abilities": ["Abduct"], "spell_verified": False},
                ],
                w=1, l=2, d=0, trade_agg=1.10, wall_ms=55000,
            )
            # Pass 2: fixes sp01 regression and wins sp03 too -> 3W-0L, 3/3 spell_verified, 0 regressions vs pass0
            _write_arena(
                p2_path,
                [
                    {"id": "sp01", "winner": "mothman", "trade_ratio": 2.2, "expected_abilities": ["PsiStorm"], "spell_verified": True},
                    {"id": "sp02", "winner": "mothman", "trade_ratio": 2.5, "expected_abilities": ["EMP"], "spell_verified": True},
                    {"id": "sp03", "winner": "mothman", "trade_ratio": 1.8, "expected_abilities": ["Abduct"], "spell_verified": True},
                ],
                w=3, l=0, d=0, trade_agg=2.15, wall_ms=52000,
            )

            passes = LOG_MOD.summarize_arena_passes(
                [
                    {"pass_id": "pass0", "opponent": "dummy", "suite": "ability-mastery", "result_json": str(p0_path)},
                    {"pass_id": "pass1", "opponent": "dummy", "suite": "ability-mastery", "result_json": str(p1_path)},
                    {"pass_id": "pass2", "opponent": "dummy", "suite": "ability-mastery", "result_json": str(p2_path)},
                    # Separate inline-only selfplay track should delta independently
                    {"pass_id": "pass0", "opponent": "self", "suite": "core", "total": 10, "w": 5, "l": 5, "d": 0, "trade_agg": 1.0, "wall_sec": 40.0},
                    {"pass_id": "pass1", "opponent": "self", "suite": "core", "total": 10, "w": 7, "l": 3, "d": 0, "trade_agg": 1.45, "wall_sec": 42.0},
                ]
            )
            self.assertEqual(len(passes), 5)
            p0, p1, p2, s0, s1 = passes

            self.assertEqual(p0["spell_verified"], 1)
            self.assertEqual(p0["spell_expected"], 3)
            self.assertEqual(p0["trade_med"], 0.5)
            self.assertEqual(p0["delta_w_vs_pass0"], 0)

            self.assertEqual(p1["improved_ids"], ["sp02"])
            self.assertEqual(p1["regressed_ids"], ["sp01"])
            self.assertEqual(p1["spell_gained_ids"], ["sp02"])
            self.assertEqual(p1["spell_lost_ids"], ["sp01"])
            self.assertEqual(p1["regression_count_vs_pass0"], 1)

            self.assertEqual(p2["w"], 3)
            self.assertEqual(p2["delta_w_vs_pass0"], 2)
            self.assertAlmostEqual(p2["delta_trade_vs_pass0"], 1.2, places=2)
            self.assertEqual(p2["delta_spell_verified_vs_pass0"], 2)
            self.assertEqual(p2["regressed_vs_pass0_ids"], [])
            self.assertEqual(p2["regression_count_vs_pass0"], 0)

            self.assertEqual(s0["delta_w_vs_pass0"], 0)
            self.assertEqual(s1["delta_w_vs_prev"], 2)
            self.assertAlmostEqual(s1["delta_trade_vs_pass0"], 0.45, places=2)

            # End-to-end build_trajectory_records emits arena_passes and flags unresolved pass0 regression
            brain, _, ledger_path, db_path = _build_synthetic_workspace(root / "ws")
            ledger_data = json.loads(ledger_path.read_text(encoding="utf-8"))
            ledger_data["iterations"][-1]["arena_passes"] = [
                {"pass_id": "pass0", "opponent": "dummy", "suite": "ability-mastery", "result_json": str(p0_path)},
                {"pass_id": "pass1", "opponent": "dummy", "suite": "ability-mastery", "result_json": str(p1_path)},
            ]
            ledger_path.write_text(json.dumps(ledger_data, indent=2), encoding="utf-8")

            recs = LOG_MOD.build_trajectory_records(
                ledger_path=ledger_path,
                brain_root=brain,
                coordinator_id=None,
                db_path=db_path,
                from_loop=47,
                to_loop=47,
            )
            self.assertEqual(len(recs), 1)
            bd47 = recs[0]["bot_deltas"]
            self.assertIn("arena_passes", bd47)
            self.assertEqual(len(bd47["arena_passes"]), 2)
            self.assertIn("arena_pass_regression", {f["kind"] for f in recs[0]["friction_events"]})


def _init_synthetic_arena_sqlite(db_path: Path):
    """Create a synthetic SQLite DB matching arena_replays.sqlite schema for unit tests."""
    con = sqlite3.connect(db_path)
    con.executescript(
        """
        CREATE TABLE runs (
            run_id TEXT PRIMARY KEY,
            tag TEXT,
            score_json_path TEXT,
            total_replays INTEGER DEFAULT 0,
            ingested_at TEXT
        );
        CREATE TABLE matches (
            replay_id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            replay_filename TEXT,
            replay_mtime REAL,
            our_race TEXT,
            actual_race TEXT,
            opp_race TEXT,
            matchup TEXT,
            our_player_id INTEGER DEFAULT 1,
            our_start_x REAL,
            our_start_y REAL,
            result TEXT,
            duration_sec REAL,
            is_clean INTEGER DEFAULT 1,
            is_selfplay INTEGER DEFAULT 0
        );
        CREATE TABLE match_minute_stats (
            replay_id TEXT NOT NULL,
            player_id INTEGER NOT NULL,
            minute INTEGER NOT NULL,
            minerals_current REAL,
            vespene_current REAL,
            minerals_rate REAL,
            vespene_rate REAL,
            workers_active REAL,
            food_used REAL,
            food_made REAL
        );
        CREATE TABLE match_build_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            replay_id TEXT NOT NULL,
            player_id INTEGER NOT NULL,
            sec REAL,
            event_type TEXT,
            unit_type TEXT,
            x REAL,
            y REAL
        );
        """
    )
    return con


class CompareVsProSqliteKpiTests(unittest.TestCase):
    def test_stall_watchdog_kpis_exact_math_and_edge_cases(self):
        with tempfile.TemporaryDirectory() as td:
            db_path = Path(td) / "arena.sqlite"
            con = _init_synthetic_arena_sqlite(db_path)
            con.execute(
                "INSERT INTO runs VALUES ('run_sw', 'sw', '/tmp/sw_score.json', 4, '2026-11-21T20:00:00Z')"
            )
            con.executemany(
                "INSERT INTO matches VALUES (?, 'run_sw', ?, 1000.0, ?, ?, ?, ?, 1, 30.0, 30.0, 'win', ?, 1, 0)",
                [
                    ("r1", "001_P.SC2Replay", "Protoss", "Protoss", "Protoss", "PvP", 600.0),
                    ("r2", "002_T.SC2Replay", "Terran", "Terran", "Zerg", "TvZ", 600.0),
                    ("r3", "003_Z.SC2Replay", "Zerg", "Zerg", "Zerg", "ZvZ", 360.0),
                    ("r4", "004_P.SC2Replay", "Protoss", "Protoss", "Terran", "PvT", 540.0),
                ],
            )
            # Minute stats: (replay_id, player_id, minute, min_cur, gas_cur, min_rate, gas_rate, wk, fu, fm)
            con.executemany(
                "INSERT INTO match_minute_stats VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    # r1 (Protoss, 8m): supply capped at min 3 (<195), worker plateau @8m (32 <= 36)
                    ("r1", 3, 200, 50, 900, 150, 22, 46, 46),
                    ("r1", 5, 300, 100, 1100, 200, 28, 60, 70),
                    ("r1", 8, 350, 150, 1200, 250, 32, 95, 110),
                    # r2 (Terran, 8m): maxed 200/200 NOT a supply cap; zero_income at m4; zero_gas at m6; 55 wk @8m
                    ("r2", 4, 250, 100, 0, 180, 12, 50, 62),
                    ("r2", 6, 300, 120, 1300, 0, 20, 90, 108),
                    ("r2", 8, 400, 200, 1600, 300, 55, 200, 200),
                    # r3 (Zerg, 6m only -> excluded from 8m plateau denom!):
                    #   - m5 has 22 wk (<=24 @5m), intentional Law-2 gas valve (gas_cur=520 >= 450, gas_rate=0) -> NOT zero_gas!
                    #   - m6 has 3 wk (<5) with 0 min_rate -> NOT zero_income!
                    #   - gas_rich_min_starved at m5 (520g >= 450, 100m < 200, 120 food < 175)
                    ("r3", 5, 100, 520, 900, 0, 22, 120, 140),
                    ("r3", 6, 150, 500, 0, 100, 3, 40, 80),
                    # r4 (Protoss, 8m): completely healthy
                    ("r4", 2, 150, 50, 800, 100, 20, 24, 31),
                    ("r4", 5, 250, 150, 1400, 250, 42, 75, 92),
                    ("r4", 8, 300, 200, 1800, 350, 58, 140, 160),
                ],
            )
            con.commit()
            con.close()

            ro = CMP_MOD.open_replay_db_ro(db_path)
            self.assertIsNotNone(ro)
            try:
                res = CMP_MOD.compute_stall_watchdog_kpis(ro, ["r1", "r2", "r3", "r4"])
            finally:
                ro.close()

            self.assertIsNotNone(res)
            self.assertEqual(res["n"], 4)
            self.assertEqual(res["sup_cap_matches"], 1)
            self.assertEqual(res["sup_cap_min_pct"], 25.0)
            self.assertEqual(res["zero_income_matches"], 1)
            self.assertEqual(res["zero_income_pct"], 25.0)
            self.assertEqual(res["zero_gas_matches"], 1)
            self.assertEqual(res["zero_gas_pct"], 25.0)
            self.assertEqual(res["wk_plateau_8m_denom"], 3)
            self.assertEqual(res["wk_plateau_8m_matches"], 1)
            self.assertEqual(res["wk_plateau_8m_pct"], 33.3)
            self.assertEqual(res["wk_plateau_5m_matches"], 1)
            self.assertEqual(res["gas_rich_min_starved_matches"], 1)
            self.assertEqual(set(res["by_race"].keys()), {"Protoss", "Terran", "Zerg"})
            self.assertEqual(res["by_race"]["Protoss"]["sup_cap_min_pct"], 50.0)
            self.assertEqual(res["by_race"]["Terran"]["zero_income_matches"], 1)
            self.assertEqual(res["by_race"]["Terran"]["zero_gas_matches"], 1)

    def test_base_geometry_kpis_exact_math_and_rotation_invariance(self):
        # Verify rotation/reflection invariance of normalize_base_coords + compute_single_base_geometry
        base_bldgs = [
            ("Nexus", 0.0, 0.0, 0.0),
            ("Nexus", 30.0, 0.0, 95.0),
            ("Pylon", 10.0, 4.0, 20.0),
            ("Gateway", 12.0, 4.0, 40.0),
            ("CyberneticsCore", 15.0, 4.0, 80.0),
            ("Pylon", 32.0, 3.0, 140.0),
        ]
        n1_dist, n1_b = CMP_MOD.normalize_base_coords(base_bldgs)
        m1 = CMP_MOD.compute_single_base_geometry("Protoss", n1_dist, n1_b)

        # Rotate by 135 degrees and translate to (140, 120)
        ang = math.radians(135.0)
        ca, sa = math.cos(ang), math.sin(ang)
        rot_bldgs = [
            (ut, 140.0 + x * ca - y * sa, 120.0 + x * sa + y * ca, sec)
            for ut, x, y, sec in base_bldgs
        ]
        n2_dist, n2_b = CMP_MOD.normalize_base_coords(rot_bldgs)
        m2 = CMP_MOD.compute_single_base_geometry("Protoss", n2_dist, n2_b)
        self.assertAlmostEqual(n1_dist, n2_dist, places=5)
        self.assertAlmostEqual(m1["sup_nn_avg"], m2["sup_nn_avg"], places=5)
        self.assertEqual(m1["sup_clump_pct"], m2["sup_clump_pct"])
        self.assertEqual(m1["has_nat_supply"], m2["has_nat_supply"])
        self.assertEqual(m1["main_wall_tight"], m2["main_wall_tight"])

        # Synthetic 4-match SQLite DB covering Protoss (clumped + spread), Terran (2 early bunkers), ZvZ (nat wall)
        with tempfile.TemporaryDirectory() as td:
            db_path = Path(td) / "arena_geo.sqlite"
            con = _init_synthetic_arena_sqlite(db_path)
            con.execute(
                "INSERT INTO runs VALUES ('run_geo', 'geo', '/tmp/geo_score.json', 4, '2026-11-21T20:00:00Z')"
            )
            con.executemany(
                "INSERT INTO matches VALUES (?, 'run_geo', ?, 1000.0, ?, ?, ?, ?, 1, 20.0, 20.0, 'win', 400.0, 1, 0)",
                [
                    ("g1", "001_PvP.SC2Replay", "Protoss", "Protoss", "Protoss", "PvP"),
                    ("g2", "002_PvZ.SC2Replay", "Protoss", "Protoss", "Zerg", "PvZ"),
                    ("g3", "003_TvZ.SC2Replay", "Terran", "Terran", "Zerg", "TvZ"),
                    ("g4", "004_ZvZ.SC2Replay", "Zerg", "Zerg", "Zerg", "ZvZ"),
                ],
            )
            # All 4 have Main at (20,20) and Natural at (50,20) -> nat_dist = 30.0
            bevs = [
                # g1 (PvP): 2 clumped Pylons (3t apart) in Main, NO Nat Pylon
                ("g1", 1, 95.0, "init", "Nexus", 50.0, 20.0),
                ("g1", 1, 20.0, "init", "Pylon", 26.0, 22.0),
                ("g1", 1, 70.0, "init", "Pylon", 29.0, 22.0),
                ("g1", 1, 40.0, "init", "Gateway", 32.0, 22.0),
                ("g1", 1, 80.0, "init", "CyberneticsCore", 35.0, 22.0),
                # g2 (PvZ): 2 spread Pylons (24t apart), 2nd Pylon at Natural (dist=2t from Nat)
                ("g2", 1, 90.0, "init", "Nexus", 50.0, 20.0),
                ("g2", 1, 20.0, "init", "Pylon", 28.0, 22.0),
                ("g2", 1, 130.0, "init", "Pylon", 52.0, 22.0),
                ("g2", 1, 45.0, "init", "Gateway", 55.0, 22.0),
                ("g2", 1, 85.0, "init", "CyberneticsCore", 55.0, 25.0),
                # g3 (TvZ): Depot at Nat + 2 Bunkers <=250s + 1 late Bunker at 260s (must be excluded!)
                ("g3", 1, 100.0, "init", "CommandCenter", 50.0, 20.0),
                ("g3", 1, 20.0, "init", "SupplyDepot", 32.0, 21.0),
                ("g3", 1, 42.0, "init", "Barracks", 35.0, 21.0),
                ("g3", 1, 140.0, "init", "SupplyDepot", 54.0, 21.0),
                ("g3", 1, 180.0, "init", "Bunker", 56.0, 20.0),
                ("g3", 1, 210.0, "init", "Bunker", 56.0, 24.0),
                ("g3", 1, 260.0, "init", "Bunker", 56.0, 28.0),
                # g4 (ZvZ): Tight Natural wall (Evo + RoachWarren 3.0t apart within 16t of Nat) + Pool in Main
                ("g4", 1, 55.0, "init", "Hatchery", 50.0, 20.0),
                ("g4", 1, 70.0, "init", "SpawningPool", 17.0, 20.0),
                ("g4", 1, 170.0, "init", "EvolutionChamber", 56.0, 20.0),
                ("g4", 1, 185.0, "init", "RoachWarren", 56.0, 23.0),
            ]
            con.executemany(
                "INSERT INTO match_build_events (replay_id, player_id, sec, event_type, unit_type, x, y) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                bevs,
            )
            con.commit()
            con.close()

            ro = CMP_MOD.open_replay_db_ro(db_path)
            self.assertIsNotNone(ro)
            try:
                geo = CMP_MOD.compute_base_geometry_kpis(ro, ["g1", "g2", "g3", "g4"])
            finally:
                ro.close()

            self.assertIsNotNone(geo)
            self.assertEqual(geo["n"], 4)
            self.assertEqual(geo["pylon_clump_pct"], 50.0)
            self.assertEqual(geo["pylon_clump_n"], 2)
            self.assertEqual(geo["nat_supply_pct"], 66.7)
            self.assertEqual(geo["protoss_nat_supply_pct"], 50.0)
            self.assertEqual(geo["terran_nat_supply_pct"], 100.0)
            self.assertEqual(geo["zvz_nat_wall_pct"], 100.0)
            self.assertEqual(geo["zvz_n"], 1)
            self.assertEqual(geo["early_bunkers_4m"], 2.0)
            self.assertEqual(geo["terran_nat_def"], 2.0)
            self.assertEqual(set(geo["by_matchup"].keys()), {"PvP", "PvZ", "TvZ", "ZvZ"})

    def test_compare_vs_pro_cli_end_to_end_with_and_without_sqlite(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            db_path = root / "arena.sqlite"
            cur_score = root / "cur_score.json"
            base_score = root / "base_score.json"
            out_json = root / "compare_out.json"

            def _mk_score_file(p: Path, prefix: str):
                matches = [
                    {
                        "id": "1", "file": f"{prefix}_001_PvP.SC2Replay",
                        "our_bot": "Mothman-P", "opp_bot": "puck",
                        "our_race": "Protoss", "opp_race": "Protoss", "matchup": "PvP",
                        "result": "win", "duration_sec": 500.0,
                        "killed_val": 6000, "lost_val": 2000, "trade_ratio": 3.0,
                        "supply_block_pct": 2.0,
                    },
                    {
                        "id": "2", "file": f"{prefix}_002_TvZ.SC2Replay",
                        "our_bot": "Mothman-T", "opp_bot": "SmoothBrain",
                        "our_race": "Terran", "opp_race": "Zerg", "matchup": "TvZ",
                        "result": "win", "duration_sec": 500.0,
                        "killed_val": 5000, "lost_val": 2500, "trade_ratio": 2.0,
                        "supply_block_pct": 1.5,
                    },
                    {
                        "id": "3", "file": f"{prefix}_003_ZvZ.SC2Replay",
                        "our_bot": "Mothman-Z", "opp_bot": "12PoolBot",
                        "our_race": "Zerg", "opp_race": "Zerg", "matchup": "ZvZ",
                        "result": "win", "duration_sec": 500.0,
                        "killed_val": 4000, "lost_val": 2000, "trade_ratio": 2.0,
                        "supply_block_pct": 3.0,
                    },
                ]
                p.write_text(json.dumps({"matches": matches}), encoding="utf-8")

            _mk_score_file(base_score, "base")
            _mk_score_file(cur_score, "cur")

            con = _init_synthetic_arena_sqlite(db_path)
            con.executemany(
                "INSERT INTO runs VALUES (?, ?, ?, 3, ?)",
                [
                    ("run_base", "base", str(base_score), "2026-11-21T19:00:00Z"),
                    ("run_cur", "cur", str(cur_score), "2026-11-21T20:00:00Z"),
                ],
            )
            con.executemany(
                "INSERT INTO matches VALUES (?, ?, ?, 1000.0, ?, ?, ?, ?, 1, 20.0, 20.0, 'win', 500.0, 1, 0)",
                [
                    ("b1", "run_base", "base_001_PvP.SC2Replay", "Protoss", "Protoss", "Protoss", "PvP"),
                    ("b2", "run_base", "base_002_TvZ.SC2Replay", "Terran", "Terran", "Zerg", "TvZ"),
                    ("b3", "run_base", "base_003_ZvZ.SC2Replay", "Zerg", "Zerg", "Zerg", "ZvZ"),
                    ("c1", "run_cur", "cur_001_PvP.SC2Replay", "Protoss", "Protoss", "Protoss", "PvP"),
                    ("c2", "run_cur", "cur_002_TvZ.SC2Replay", "Terran", "Terran", "Zerg", "TvZ"),
                    ("c3", "run_cur", "cur_003_ZvZ.SC2Replay", "Zerg", "Zerg", "Zerg", "ZvZ"),
                ],
            )
            # Baseline has stalls (sup_cap + zero_income + zero_gas + wk_plateau); Current fixes all 4!
            con.executemany(
                "INSERT INTO match_minute_stats VALUES (?, 1, ?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    ("b1", 3, 200, 50, 900, 150, 22, 46, 46),
                    ("b1", 8, 300, 100, 1100, 200, 30, 80, 96),
                    ("b2", 4, 200, 80, 0, 100, 18, 55, 70),
                    ("b2", 6, 300, 100, 1100, 0, 24, 75, 92),
                    ("b2", 8, 300, 100, 1200, 200, 48, 120, 140),
                    ("b3", 8, 300, 100, 1400, 250, 52, 130, 150),
                    ("c1", 3, 200, 50, 900, 150, 24, 42, 54),
                    ("c1", 8, 300, 100, 1600, 300, 55, 130, 150),
                    ("c2", 4, 200, 80, 1000, 180, 28, 58, 70),
                    ("c2", 6, 300, 100, 1400, 250, 44, 95, 112),
                    ("c2", 8, 300, 100, 1700, 300, 58, 140, 160),
                    ("c3", 8, 300, 100, 1800, 350, 62, 150, 172),
                ],
            )
            # Baseline geometry: PvP clumped Pylons (no Nat Pylon), TvZ 2 Bunkers (no Nat Depot), ZvZ no Nat wall
            # Current geometry:  PvP spread Pylons + Nat Pylon, TvZ 1 Bunker + Nat Depot, ZvZ tight Nat wall!
            con.executemany(
                "INSERT INTO match_build_events (replay_id, player_id, sec, event_type, unit_type, x, y) "
                "VALUES (?, 1, ?, 'init', ?, ?, ?)",
                [
                    ("b1", 95.0, "Nexus", 50.0, 20.0), ("b1", 20.0, "Pylon", 26.0, 22.0), ("b1", 60.0, "Pylon", 29.0, 22.0), ("b1", 40.0, "Gateway", 32.0, 22.0), ("b1", 80.0, "CyberneticsCore", 35.0, 22.0),
                    ("b2", 100.0, "CommandCenter", 50.0, 20.0), ("b2", 20.0, "SupplyDepot", 30.0, 22.0), ("b2", 42.0, "Barracks", 33.0, 22.0), ("b2", 160.0, "Bunker", 55.0, 20.0), ("b2", 190.0, "Bunker", 55.0, 24.0),
                    ("b3", 55.0, "Hatchery", 50.0, 20.0), ("b3", 70.0, "SpawningPool", 17.0, 20.0), ("b3", 150.0, "RoachWarren", 17.0, 24.0), ("b3", 180.0, "EvolutionChamber", 17.0, 28.0),
                    ("c1", 95.0, "Nexus", 50.0, 20.0), ("c1", 20.0, "Pylon", 26.0, 22.0), ("c1", 120.0, "Pylon", 52.0, 22.0), ("c1", 40.0, "Gateway", 32.0, 22.0), ("c1", 80.0, "CyberneticsCore", 35.0, 22.0),
                    ("c2", 100.0, "CommandCenter", 50.0, 20.0), ("c2", 20.0, "SupplyDepot", 30.0, 22.0), ("c2", 42.0, "Barracks", 33.0, 22.0), ("c2", 140.0, "SupplyDepot", 54.0, 21.0), ("c2", 170.0, "Bunker", 55.0, 24.0),
                    ("c3", 55.0, "Hatchery", 50.0, 20.0), ("c3", 70.0, "SpawningPool", 17.0, 20.0), ("c3", 165.0, "EvolutionChamber", 56.0, 20.0), ("c3", 180.0, "RoachWarren", 56.0, 23.0),
                ],
            )
            con.commit()
            con.close()

            # 1. Full CLI run with read-only SQLite
            p1 = subprocess.run(
                [
                    sys.executable, str(COMPARE_PATH),
                    "--current", str(cur_score),
                    "--baseline", str(base_score),
                    "--replay-db", str(db_path),
                    "--out-json", str(out_json),
                ],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(p1.returncode, 0, f"compare-vs-pro failed: {p1.stderr}\n{p1.stdout}")
            self.assertIn("### Stall Watchdog KPIs", p1.stdout)
            self.assertIn("### Pro-vs-Mothman Base Geometry KPIs", p1.stdout)

            rep = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertEqual(rep["sqlite_replay_db"]["current_run_id"], "run_cur")
            self.assertEqual(rep["sqlite_replay_db"]["baseline_run_id"], "run_base")
            sw = rep["stall_watchdog_kpis"]
            self.assertEqual(sw["current"]["sup_cap_min_pct"], 0.0)
            self.assertEqual(sw["current"]["zero_income_matches"], 0)
            self.assertEqual(sw["current"]["zero_gas_matches"], 0)
            self.assertEqual(sw["current"]["wk_plateau_8m_pct"], 0.0)
            self.assertEqual(sw["delta"]["sup_cap_min_pct"], -33.3)
            self.assertEqual(sw["delta"]["zero_income_matches"], -1)
            self.assertEqual(sw["delta"]["zero_gas_matches"], -1)
            self.assertEqual(sw["delta"]["wk_plateau_8m_pct"], -33.3)

            bg = rep["base_geometry_kpis"]
            self.assertEqual(bg["current"]["pylon_clump_pct"], 0.0)
            self.assertEqual(bg["baseline"]["pylon_clump_pct"], 100.0)
            self.assertEqual(bg["delta"]["pylon_clump_pct"], -100.0)
            self.assertEqual(bg["delta"]["nat_supply_pct"], 100.0)
            self.assertEqual(bg["delta"]["zvz_nat_wall_pct"], 100.0)
            self.assertEqual(bg["delta"]["early_bunkers_4m"], -1.0)
            self.assertEqual(bg["pro_reference"]["zvz_nat_wall_pct"], 48.0)

            # 2. Graceful fallback with --replay-db "" (disabled)
            out_nodb = root / "compare_nodb.json"
            p2 = subprocess.run(
                [
                    sys.executable, str(COMPARE_PATH),
                    "--current", str(cur_score),
                    "--replay-db", "",
                    "--out-json", str(out_nodb),
                ],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(p2.returncode, 0, f"compare-vs-pro (no db) failed: {p2.stderr}")
            self.assertNotIn("### Stall Watchdog KPIs", p2.stdout)
            rep2 = json.loads(out_nodb.read_text(encoding="utf-8"))
            self.assertIsNone(rep2["sqlite_replay_db"])
            self.assertIsNone(rep2["stall_watchdog_kpis"])
            self.assertIsNone(rep2["base_geometry_kpis"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
