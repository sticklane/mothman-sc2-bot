#!/usr/bin/env python3
"""
Unit & integration tests for the Mothman SC2 Loop Trajectory Flywheel:
  - tools/iteration-loop/log-loop-trajectory.py
  - tools/iteration-loop/analyze-loop-flywheel.py
  - tools/iteration-loop/loop_trajectory_log.jsonl (live backfill integrity)

Runs completely offline in <1s with zero GPU, zero Podman, and zero writes to
live repo files or live SQLite databases.
"""

from __future__ import annotations

import importlib.util
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
LOGGER_PATH = REPO_ROOT / "tools/iteration-loop/log-loop-trajectory.py"
ANALYZER_PATH = REPO_ROOT / "tools/iteration-loop/analyze-loop-flywheel.py"
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
            self.assertIn("Phase Wall-Clock Pareto", md_text)
            self.assertIn("Per-Agent Step, Tool-Error", md_text)
            self.assertIn("Flip-Flop Detector", md_text)
            self.assertIn("Counterfactual Speedup Simulator", md_text)
            self.assertNotIn("/home/fakeuser", md_text)

    def test_live_backfilled_trajectory_log_integrity(self):
        self.assertTrue(LIVE_JSONL.is_file(), f"Missing backfilled log: {LIVE_JSONL}")
        rows = ANA_MOD.load_jsonl(LIVE_JSONL)
        self.assertGreaterEqual(len(rows), 29, "Expected Loops 19..47 backfilled (>=29 rows)")
        lids = [r["loop_id"] for r in rows]
        self.assertEqual(lids, sorted(set(lids)), "loop_id must be strictly unique & ascending")
        self.assertLessEqual(lids[0], 19)
        self.assertGreaterEqual(lids[-1], 47)

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
