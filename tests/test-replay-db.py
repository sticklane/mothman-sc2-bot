#!/usr/bin/env python3
"""
tests/test-replay-db.py

Unit & integration test suite for `tools/replay-db.py` using an isolated
temporary SQLite database and real `.SC2Replay` + `score.json` fixtures.
"""

from __future__ import annotations

import csv
import datetime as dt
import io
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
REPLAY_DB = REPO_ROOT / "tools" / "replay-db.py"
RUNS_DIR = Path("/home/sjaconette/sc2-local-arena/runs")
SCORES_DIR = Path(
    "/home/sjaconette/.gemini/antigravity/brain/d28d22f4-2d13-41e2-9b7b-32757f58523b/scratch"
)
PROD_META_DIR = SCORES_DIR / "aiarena_replays"
PROD_LIVE_DIR = Path("/home/sjaconette/sc2-local-arena/live_32ab101a_replays")


def _find_small_real_run() -> tuple[Path | None, Path | None]:
    """Locate a small real run (4-6 replays) with a matching score.json for fast tests."""
    for pat in ("*iter34_zip_smoke", "*iter28_zip_smoke", "*iter34_baseline_h2h", "*iter30_baseline_h2h"):
        cands = sorted(RUNS_DIR.glob(pat))
        if cands:
            rdir = cands[-1]
            # Look for matching score json
            tag = rdir.name.split("_", 2)[-1]
            sj = SCORES_DIR / f"{tag}_score.json"
            return rdir, (sj if sj.is_file() else None)
    return None, None


class ReplayDbTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="replay_db_test_")
        self.tmp_dir = Path(self._tmp.name)
        self.db_path = self.tmp_dir / "test_arena.sqlite"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run_cli(self, *cli_args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        cmd = [sys.executable, str(REPLAY_DB), "--db", str(self.db_path), *cli_args]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if check and res.returncode != 0:
            self.fail(f"CLI failed ({res.returncode}): {' '.join(cmd)}\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}")
        return res

    def test_01_helper_functions_and_schema(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("replay_db_mod", str(REPLAY_DB))
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        self.assertEqual(mod._classify_spawn_corner(38, 141, 85, 85), "NW")
        self.assertEqual(mod._classify_spawn_corner(141, 141, 85, 85), "NE")
        self.assertEqual(mod._classify_spawn_corner(38, 38, 85, 85), "SW")
        self.assertEqual(mod._classify_spawn_corner(141, 38, 85, 85), "SE")
        self.assertIsNone(mod._classify_spawn_corner(None, 38, 85, 85))

        self.assertEqual(mod._norm_race("P"), "Protoss")
        self.assertEqual(mod._norm_race("Terr"), "Terran")
        self.assertEqual(mod._norm_race("zerg"), "Zerg")
        self.assertEqual(mod._norm_result("Player1Win"), "win")
        self.assertEqual(mod._norm_result("Defeat"), "loss")
        self.assertEqual(mod._norm_result("Tie"), "tie")

        parsed = mod._parse_replay_filename("007_Mothman-P_vs_onlyfans_IncorporealAIE_v4.SC2Replay")
        self.assertEqual(parsed["match_index"], 7)
        self.assertEqual(parsed["bot"], "Mothman-P")
        self.assertEqual(parsed["opponent"], "onlyfans")
        self.assertEqual(parsed["map_name"], "IncorporealAIE_v4")

        conn = mod.open_db(self.db_path)
        tables = {
            r[0]
            for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        for req in (
            "runs", "matches", "match_anomalies", "match_minute_stats",
            "match_build_events", "match_unit_totals", "match_cmd_summary",
        ):
            self.assertIn(req, tables)
        jm = conn.execute("PRAGMA journal_mode;").fetchone()[0].lower()
        self.assertEqual(jm, "wal")
        conn.close()

    def test_02_end_to_end_real_run_ingest_extract_query_dump_spawnbias(self) -> None:
        rdir, sj = _find_small_real_run()
        if rdir is None:
            self.skipTest("No local SC2 arena run fixture found")

        # 1. Ingest single real run + score.json
        ing_args = ["ingest-runs", "--runs-dir", str(RUNS_DIR), "--run", rdir.name, "-j", "4"]
        if sj:
            ing_args.extend(["--score-json", str(sj)])
        r1 = self._run_cli(*ing_args)
        self.assertIn("ingest-runs OK:", r1.stdout)
        self.assertIn("runs=1,", r1.stdout)

        # 2. Idempotent re-ingest (0 new hashes, identical match count)
        r2 = self._run_cli(*ing_args)
        self.assertIn("hashed_new=0,", r2.stdout)

        # 3. Extract raw tracker events in parallel
        r3 = self._run_cli("extract-raw", "--all", "-j", "4")
        self.assertIn("extract-raw OK:", r3.stdout)
        self.assertIn("err=0,", r3.stdout)

        # 4. Incremental extract-raw skips already-extracted replays
        r4 = self._run_cli("extract-raw", "--all", "-j", "4")
        self.assertIn("0 replays need extraction", r4.stdout)

        # Inspect DB contents directly
        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        matches = conn.execute("SELECT * FROM matches ORDER BY match_index").fetchall()
        self.assertGreaterEqual(len(matches), 4)
        for m in matches:
            self.assertIsNotNone(m["raw_extracted_at"])
            self.assertIn(m["actual_race"], ("Protoss", "Terran", "Zerg"))
            self.assertIn(m["our_spawn_corner"], ("NW", "NE", "SW", "SE"))
            self.assertIsNotNone(m["our_start_x"])
            self.assertIsNotNone(m["opp_start_x"])
            self.assertGreater(m["game_loops"], 0)

        # Minute stats sanity (food_made properly divided by 4096, bases >= 1)
        mstats = conn.execute("SELECT * FROM match_minute_stats WHERE minute = 2").fetchall()
        self.assertGreaterEqual(len(mstats), len(matches) * 2)
        for ms in mstats:
            self.assertGreater(ms["food_made"], 0.0)
            self.assertLessEqual(ms["food_made"], 250.0)
            self.assertGreaterEqual(ms["bases_alive"], 1)

        # Build events filtered properly (no Larva/Egg/Spray noise)
        noisy = conn.execute(
            "SELECT COUNT(*) FROM match_build_events WHERE unit_type IN ('Larva','Egg','Interceptor') OR unit_type LIKE 'Spray%'"
        ).fetchone()[0]
        self.assertEqual(noisy, 0)
        bev_total = conn.execute("SELECT COUNT(*) FROM match_build_events").fetchone()[0]
        self.assertGreater(bev_total, 200)

        # Unit totals sanity
        utot = conn.execute(
            "SELECT COUNT(*) FROM match_unit_totals WHERE created < 1 OR peak_alive < 1"
        ).fetchone()[0]
        self.assertEqual(utot, 0)

        first_id = matches[0]["replay_id"]
        conn.close()

        # 5. Extract optional game events on 1 single replay (match_cmd_summary)
        r_ge = self._run_cli("extract-raw", "--replay", first_id[:12], "--include-game-events", "-j", "1")
        self.assertIn("extract-raw OK: extracted=1/1", r_ge.stdout)
        conn = sqlite3.connect(str(self.db_path))
        cmd_rows = conn.execute("SELECT COUNT(*) FROM match_cmd_summary WHERE replay_id = ?", (first_id,)).fetchone()[0]
        self.assertGreater(cmd_rows, 0)
        conn.close()

        # 6. Test query subcommand (json, csv, table) + read-only protection
        qj = self._run_cli("query", "SELECT bot, opponent, our_spawn_corner, result FROM matches ORDER BY match_index", "--format", "json")
        parsed_j = json.loads(qj.stdout)
        self.assertEqual(len(parsed_j), len(matches))

        qc = self._run_cli("query", "SELECT bot, result FROM matches", "--format", "csv")
        csv_rows = list(csv.reader(io.StringIO(qc.stdout)))
        self.assertEqual(len(csv_rows), len(matches) + 1)

        q_ro = self._run_cli("query", "DELETE FROM matches", check=False)
        self.assertNotEqual(q_ro.returncode, 0)

        # 7. Test stats, replay-dump, spawn-bias
        rs = self._run_cli("stats")
        self.assertIn("Table Row Counts:", rs.stdout)
        self.assertIn("raw_tracker=", rs.stdout)

        rd = self._run_cli("replay-dump", first_id[:12])
        self.assertIn("=== REPLAY DUMP:", rd.stdout)
        self.assertIn("Minute Economy & Army Timeline", rd.stdout)
        self.assertIn("Game-Event Command Summary", rd.stdout)

        rsb = self._run_cli("spawn-bias", "--min-games", "1", "--include-selfplay")
        self.assertIn("=== Overall Spawn-Corner Bias ===", rsb.stdout)
        self.assertIn("=== Map x Spawn-Corner Breakdown ===", rsb.stdout)

    def test_03_build_version_parsers_and_v1_schema_migration(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("replay_db_mod2", str(REPLAY_DB))
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        # [SCBOT_BUILD] parsing (strips leading v_ so log & chat tags merge into one build row)
        self.assertEqual(
            mod._parse_scbot_build_from_text("[SCBOT_BUILD] version=v_1d211c83 race=Zerg\n"),
            "1d211c83",
        )
        self.assertEqual(
            mod._parse_scbot_build_from_text("[SCBOT_BUILD] version=mqklxqnz_1cd044c1 mode=zip\n"),
            "mqklxqnz_1cd044c1",
        )
        self.assertEqual(
            mod._parse_scbot_build_from_text("hello\n[SCBOT_BUILD] rev=73c70041\n"),
            "73c70041",
        )
        self.assertEqual(
            mod._parse_scbot_build_from_text("[SCBOT_BUILD] v_loop35_test\n"),
            "loop35_test",
        )
        self.assertIsNone(mod._parse_scbot_build_from_text("[SCBOT_STATE] f=0\n"))

        # Chat tag build version parsing (must ignore opponent's Tag:v_... and strip v_ prefix)
        self.assertEqual(
            mod._parse_version_from_chat_tags([(2, "Tag:v_opp"), (1, "Tag:v_mqklxqnz_1cd044c1")], our_pid=1),
            "mqklxqnz_1cd044c1",
        )
        self.assertEqual(
            mod._parse_version_from_chat_tags([(1, "Tag:v_1d211c83")], our_pid=1),
            "1d211c83",
        )
        self.assertIsNone(
            mod._parse_version_from_chat_tags([(2, "Tag:v_opp"), (2, "Tag: rush_probe")], our_pid=1),
        )

        # Deploy commit timestamp resolution
        tl = [
            (dt.datetime(2026, 11, 16, 7, 31, 11, tzinfo=dt.timezone.utc), "2c96a08d", "d1"),
            (dt.datetime(2026, 11, 18, 23, 59, 55, tzinfo=dt.timezone.utc), "32ab101a", "d2"),
        ]
        self.assertEqual(mod._resolve_deploy_commit("2026-11-16T09:48:35.813349Z", tl), "deploy:2c96a08d")
        self.assertEqual(mod._resolve_deploy_commit("2026-11-19T01:04:00+00:00", tl), "deploy:32ab101a")
        self.assertIsNone(mod._resolve_deploy_commit("2026-11-15T00:00:00Z", tl))

        self.assertEqual(
            mod._extract_map_from_aiarena_url("https://s3/media/replays/5129223_Mothman-Z_FastBC_PylonAIE_v4.SC2Replay?sig=1"),
            "PylonAIE_v4",
        )
        self.assertEqual(mod._infer_race_from_bot_name("Mothman-Z"), "Zerg")
        self.assertEqual(mod._infer_race_from_bot_name("Mothman-X"), "Random")

        # v1 -> v2 schema migration test on a pre-existing DB missing the 6 new columns
        mig_db = self.tmp_dir / "v1_legacy.sqlite"
        c = sqlite3.connect(str(mig_db))
        c.executescript(
            """
            CREATE TABLE runs (run_id TEXT PRIMARY KEY, tag TEXT, git_rev TEXT, run_dir TEXT,
                score_json_path TEXT, mothman_mode TEXT, image TEXT, concurrency INTEGER,
                wall_elapsed_sec REAL, started_at TEXT, total_replays INTEGER DEFAULT 0, ingested_at TEXT);
            CREATE TABLE matches (replay_id TEXT PRIMARY KEY, replay_sha256 TEXT NOT NULL,
                replay_mtime REAL, replay_size_bytes INTEGER, run_id TEXT NOT NULL,
                match_index INTEGER, replay_path TEXT NOT NULL UNIQUE, replay_filename TEXT,
                bot TEXT, our_race TEXT, actual_race TEXT, opponent TEXT, opp_race TEXT,
                opp_cohort TEXT, matchup TEXT, map_name TEXT, our_player_id INTEGER DEFAULT 1,
                our_spawn_corner TEXT, our_start_x REAL, our_start_y REAL, opp_start_x REAL,
                opp_start_y REAL, result TEXT, duration_sec REAL, game_loops INTEGER,
                killed_val REAL, lost_val REAL, trade_ratio REAL, w4m INTEGER, w6m INTEGER,
                peak_workers INTEGER, peak_army_val REAL, peak_bases INTEGER,
                opp_peak_workers INTEGER, opp_peak_army_val REAL, opp_bases INTEGER,
                sup_blk_pct REAL, opp_sup_blk_pct REAL, avg_step_ms REAL, p95_step_ms REAL,
                max_step_ms REAL, tr_ms REAL, tr_p95_ms REAL, action_rejects INTEGER,
                is_clean INTEGER DEFAULT 1, is_selfplay INTEGER DEFAULT 0, p2_logged INTEGER DEFAULT 0,
                raw_extracted_at TEXT, game_events_extracted_at TEXT, score_meta_json TEXT);
            INSERT INTO runs (run_id, tag) VALUES ('r1', 'legacy');
            INSERT INTO matches (replay_id, replay_sha256, run_id, replay_path) VALUES ('abc', 'abc', 'r1', '/tmp/a.SC2Replay');
            """
        )
        c.commit()
        c.close()

        conn = mod.open_db(mig_db)
        cols = {row[1] for row in conn.execute("PRAGMA table_info(matches)").fetchall()}
        for req_col in (
            "source_type", "bot_build_version", "aiarena_match_id",
            "aiarena_bot_elo", "aiarena_opp_elo", "replay_chat_tags",
        ):
            self.assertIn(req_col, cols)
        src_val = conn.execute("SELECT source_type FROM matches WHERE replay_id = 'abc'").fetchone()[0]
        self.assertEqual(src_val, "local_arena")
        conn.close()

    def test_04_ingest_prod_aiarena_both_layouts(self) -> None:
        if not PROD_META_DIR.is_dir() or not PROD_LIVE_DIR.is_dir():
            self.skipTest("Local prod AI Arena fixture directories not found")

        # Subset of fetch-aiarena-replays.yml layout (*_meta.json + *_match_log.zip + *.SC2Replay)
        sub_meta = self.tmp_dir / "prod_meta_subset"
        sub_meta.mkdir()
        for mid in ("5129220", "5129223"):
            for p in PROD_META_DIR.glob(f"{mid}_*"):
                shutil.copy2(p, sub_meta / p.name)

        r1 = self._run_cli("ingest-prod-aiarena", str(sub_meta), "--extract-raw", "-j", "2")
        self.assertIn("ingest-prod-aiarena OK:", r1.stdout)
        self.assertIn("matches=2,", r1.stdout)
        self.assertIn("extract-raw OK: extracted=2/2 (err=0,", r1.stdout)

        # Subset of live_*_summary.json layout (includes P2 Mothman + Creepy_strategies Tag: rush_probe)
        sub_live = self.tmp_dir / "prod_live_subset"
        sub_live.mkdir()
        shutil.copy2(PROD_LIVE_DIR / "live_32ab101a_summary.json", sub_live / "live_32ab101a_summary.json")
        for fn in (
            "5133416_Mothman-P_vs_Positive_Null.SC2Replay",
            "5134678_Mothman-Z_vs_Creepy_strategies.SC2Replay",
        ):
            src = PROD_LIVE_DIR / fn
            if src.is_file():
                shutil.copy2(src, sub_live / fn)

        r2 = self._run_cli("ingest-prod-aiarena", str(sub_live), "--extract-raw", "-j", "2")
        self.assertIn("ingest-prod-aiarena OK:", r2.stdout)
        self.assertIn("extract-raw OK: extracted=2/2 (err=0,", r2.stdout)

        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row

        m_fastbc = conn.execute("SELECT * FROM matches WHERE aiarena_match_id = 5129223").fetchone()
        self.assertIsNotNone(m_fastbc)
        self.assertEqual(m_fastbc["source_type"], "prod_aiarena")
        self.assertEqual(m_fastbc["bot"], "Mothman-Z")
        self.assertEqual(m_fastbc["opponent"], "FastBC")
        self.assertEqual(m_fastbc["result"], "loss")
        self.assertEqual(m_fastbc["aiarena_bot_elo"], 1246)
        self.assertEqual(m_fastbc["bot_build_version"], "deploy:2c96a08d")
        self.assertEqual(m_fastbc["peak_workers"], 48)

        m_pos = conn.execute("SELECT * FROM matches WHERE aiarena_match_id = 5133416").fetchone()
        self.assertIsNotNone(m_pos)
        self.assertEqual(m_pos["our_player_id"], 2)  # Mothman-P was P2 in this live match!
        self.assertEqual(m_pos["result"], "win")
        self.assertEqual(m_pos["aiarena_opp_elo"], 1086)
        self.assertEqual(m_pos["bot_build_version"], "deploy:32ab101a")

        m_creepy = conn.execute("SELECT * FROM matches WHERE aiarena_match_id = 5134678").fetchone()
        self.assertIsNotNone(m_creepy)
        self.assertIsNotNone(m_creepy["replay_chat_tags"])
        tags = json.loads(m_creepy["replay_chat_tags"])
        self.assertTrue(any("rush_probe" in t for t in tags))
        self.assertEqual(m_creepy["bot_build_version"], "deploy:32ab101a")
        conn.close()

        # Verify replay-dump lookup directly by AI Arena match ID
        rd = self._run_cli("replay-dump", "5134678")
        self.assertIn("source    : prod_aiarena | build=deploy:32ab101a", rd.stdout)
        self.assertIn("aiarena   : match=#5134678", rd.stdout)
        self.assertIn("chat_tags :", rd.stdout)

        # Verify stats shows Source Type & Build Versions
        st = self._run_cli("stats")
        self.assertIn("Matches by Source Type:", st.stdout)
        self.assertIn("prod_aiarena", st.stdout)
        self.assertIn("Top Build Versions:", st.stdout)

    def test_05_prod_scoring_analyze_prod_and_sync_prod(self) -> None:
        post_fix_dir = SCORES_DIR / "post_fix_replays"
        if not post_fix_dir.is_dir():
            self.skipTest("Local post_fix_replays prod fixture not found")

        # 1. Stage a 2-match prod directory with *_meta.json + *_match_log.zip + *.SC2Replay
        staged = self.tmp_dir / "prod_scored_subset"
        staged.mkdir()
        for mid in ("5129548", "5129550"):
            for p in post_fix_dir.glob(f"{mid}_*"):
                shutil.copy2(p, staged / p.name)

        score_out = self.tmp_dir / "staged_prod_score.json"
        r_ing = self._run_cli(
            "ingest-prod-aiarena",
            str(staged),
            "--score",
            "--score-out",
            str(score_out),
            "--extract-raw",
            "-j",
            "2",
        )
        self.assertIn("score-replay-batch OK", r_ing.stdout)
        self.assertIn("scored=2,", r_ing.stdout)
        self.assertTrue(score_out.is_file())

        conn = sqlite3.connect(str(self.db_path))
        conn.row_factory = sqlite3.Row
        m548 = conn.execute("SELECT * FROM matches WHERE aiarena_match_id = 5129548").fetchone()
        self.assertIsNotNone(m548)
        self.assertIsNotNone(m548["sup_blk_pct"])
        self.assertGreater(m548["sup_blk_pct"], 0.0)
        anoms = {
            r["anomaly_name"]
            for r in conn.execute(
                "SELECT anomaly_name FROM match_anomalies WHERE replay_id = ? AND player_side = 'p1'",
                (m548["replay_id"],),
            )
        }
        self.assertIn("own_base_retreat", anoms)
        conn.close()

        # 2. Verify analyze-prod renders all 5 sections + writes --out-md
        md_out = self.tmp_dir / "prod_analysis.md"
        r_ap = self._run_cli(
            "analyze-prod",
            "--min-opp-games",
            "1",
            "--top-losses",
            "2",
            "--out-md",
            str(md_out),
        )
        self.assertIn("=== PROD AI ARENA FORENSIC ANALYSIS ===", r_ap.stdout)
        self.assertIn("=== 1. Per-Build Progression", r_ap.stdout)
        self.assertIn("=== 2. Per-Bot Breakdown ===", r_ap.stdout)
        self.assertIn("=== 3A. Hardest Prod Opponents", r_ap.stdout)
        self.assertIn("=== 4. Prod Anomaly Rates by Build", r_ap.stdout)
        self.assertIn("own_base_retreat", r_ap.stdout)
        self.assertIn("=== 5. Top 2 Prod Losses", r_ap.stdout)
        self.assertIn("opening_bo:", r_ap.stdout)
        self.assertTrue(md_out.is_file())

        # 3. Verify sync-prod --dry-run detects known match IDs for skip_matches
        r_dry = self._run_cli("sync-prod", "--dry-run", "--limit", "15")
        self.assertIn("[sync-prod DRY RUN]", r_dry.stdout)
        self.assertIn("2 known IDs", r_dry.stdout)
        self.assertIn("score=True", r_dry.stdout)

        # 4. Verify sync-prod end-to-end orchestration using pre-staged run_<id>/aiarena-replays
        dest_root = self.tmp_dir / "sync_dest"
        pre = dest_root / "run_999999" / "aiarena-replays"
        pre.mkdir(parents=True)
        for p in post_fix_dir.glob("5129553_*"):
            shutil.copy2(p, pre / p.name)
        r_sync = self._run_cli(
            "sync-prod",
            "--gh-run-id",
            "999999",
            "--dest-root",
            str(dest_root),
            "--top-losses",
            "3",
            "-j",
            "2",
        )
        self.assertIn("Reusing already-downloaded replays", r_sync.stdout)
        self.assertIn("ingest-prod-aiarena OK: run_id=prod_aiarena_run_999999", r_sync.stdout)
        self.assertIn("=== PROD AI ARENA FORENSIC ANALYSIS ===", r_sync.stdout)
        self.assertIn("#5129553", r_sync.stdout)

    def test_06_canonical_map_matchup_spawn_bias_and_outliers(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("replay_db_mod3", str(REPLAY_DB))
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        # Canonical map unification across local & prod variants
        self.assertEqual(mod._canonical_map_name("Ley Lines AIE"), "LeyLines")
        self.assertEqual(mod._canonical_map_name("LeyLinesAIE_v3"), "LeyLines")
        self.assertEqual(mod._canonical_map_name("Incorporeal AIE"), "Incorporeal")
        self.assertEqual(mod._canonical_map_name("IncorporealAIE_v4.SC2Map"), "Incorporeal")
        self.assertEqual(mod._canonical_map_name("MagannathaAIE_v2"), "Magannatha")

        # Populate synthetic DB with canonical map variants + severe NE vs SW TvT outlier + SB ratio outlier
        conn = mod.open_db(self.db_path)
        with conn:
            conn.execute("INSERT INTO runs (run_id, tag, started_at) VALUES ('20261120_100000_r1', 'r1', '2026-11-20T10:00:00Z')")
            conn.execute("INSERT INTO runs (run_id, tag, started_at) VALUES ('20261120_200000_r2', 'r2', '2026-11-20T20:00:00Z')")
            idx = 0
            # LeyLines NE: 1W-5L, high SB 9.0% (mixed 'Ley Lines AIE' and 'LeyLinesAIE_v3' names!)
            for i in range(6):
                idx += 1
                mname = "Ley Lines AIE" if i % 2 == 0 else "LeyLinesAIE_v3"
                res = "win" if i == 0 else "loss"
                conn.execute(
                    """
                    INSERT INTO matches (
                        replay_id, replay_sha256, run_id, replay_path, bot, our_race, actual_race,
                        opponent, opp_race, matchup, map_name, our_spawn_corner, our_start_x, our_start_y,
                        result, duration_sec, killed_val, lost_val, sup_blk_pct, is_clean, is_selfplay,
                        source_type, bot_build_version
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        f"id_{idx}", f"id_{idx}", "20261120_200000_r2", f"/tmp/m{idx}.SC2Replay",
                        "Mothman-T", "Terran", "Terran", "oppA", "Terran", "TvT", mname,
                        "NE", 155.0, 133.0, res, 600.0, 2000.0, 5000.0, 9.0, 1, 0,
                        "prod_aiarena", "deploy:test1",
                    ),
                )
            # LeyLines SW: 5W-1L, low SB 2.0%
            for i in range(6):
                idx += 1
                mname = "Ley Lines AIE" if i % 2 == 0 else "LeyLinesAIE_v3"
                res = "loss" if i == 0 else "win"
                conn.execute(
                    """
                    INSERT INTO matches (
                        replay_id, replay_sha256, run_id, replay_path, bot, our_race, actual_race,
                        opponent, opp_race, matchup, map_name, our_spawn_corner, our_start_x, our_start_y,
                        result, duration_sec, killed_val, lost_val, sup_blk_pct, is_clean, is_selfplay,
                        source_type, bot_build_version
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    (
                        f"id_{idx}", f"id_{idx}", "20261120_200000_r2", f"/tmp/m{idx}.SC2Replay",
                        "Mothman-T", "Terran", "Terran", "oppA", "Terran", "TvT", mname,
                        "SW", 42.0, 40.0, res, 600.0, 6000.0, 2000.0, 2.0, 1, 0,
                        "prod_aiarena", "deploy:test1",
                    ),
                )
        conn.close()

        # Verify spawn-bias merges both LeyLines variants, prints SB%, supports --by-matchup & --recent-runs, and flags both WR_GAP & SB_RATIO!
        rsb = self._run_cli("spawn-bias", "--by-matchup", "--matchup", "TvT", "--recent-runs", "1", "--min-games", "1", "--min-pair-n", "5")
        self.assertIn("SB%", rsb.stdout)
        self.assertIn("LeyLines", rsb.stdout)
        self.assertNotIn("LeyLinesAIE_v3", rsb.stdout)
        self.assertIn("=== Map x Matchup x Spawn-Corner Breakdown ===", rsb.stdout)
        self.assertIn("=== Automatic Spawn-Position Outliers", rsb.stdout)
        self.assertIn("WR_GAP(", rsb.stdout)
        self.assertIn("SB_RATIO(", rsb.stdout)
        self.assertIn("TvT|LeyLines", rsb.stdout)

        # Verify analyze-prod includes section 4B Map x Spawn-Corner Outliers
        rap = self._run_cli("analyze-prod", "--min-opp-games", "1", "--top-losses", "1")
        self.assertIn("=== 4B. Map x Spawn-Corner Outliers (Prod", rap.stdout)
        self.assertIn("LeyLines", rap.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
