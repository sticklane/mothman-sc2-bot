#!/usr/bin/env python3
"""
tools/replay-db.py

Fast, indexed SQLite database for SC2 arena run metadata, scorer telemetry,
and direct raw `.SC2Replay` MPQ/s2protocol extraction (tracker + optional
game events).

Database default path lives OUTSIDE git:
  /home/sjaconette/sc2-local-arena/arena_replays.sqlite

Subcommands:
  ingest-runs         Ingest runs/* (summary.json + replays) and scratch/*score*.json
  ingest-prod-aiarena Ingest downloaded fetch-aiarena-replays.yml prod artifacts (+ --score / --score-json)
  sync-prod           One-command gh workflow download/trigger -> score -> ingest -> extract -> analyze-prod
  analyze-prod        Prod AI Arena report: per-build WR/ELO/step, per-bot, opponents, anomalies, top losses
  extract-raw         Parallel (-j 12) incremental raw .SC2Replay tracker/game extraction
  query               Run read-only SQL against the DB (--format table|json|csv)
  stats               Print DB size, row counts, coverage, and source/cohort summary
  replay-dump         Forensic single-replay view (meta, anomalies, econ, units, BO)
  spawn-bias          Map + spawn-corner (NW/NE/SW/SE) win-rate & trade breakdown
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import datetime as dt
import hashlib
import importlib.util
import io
import json
import math
import os
import re
import sqlite3
import subprocess
import sys
import time
import zipfile
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ARENA_DIR = Path("/home/sjaconette/sc2-local-arena")
DEFAULT_DB_PATH = DEFAULT_ARENA_DIR / "arena_replays.sqlite"
DEFAULT_RUNS_DIR = DEFAULT_ARENA_DIR / "runs"
DEFAULT_PROD_DIR = DEFAULT_ARENA_DIR / "prod_aiarena"
DEFAULT_PYLIBS_DIR = DEFAULT_ARENA_DIR / "pylibs"
DEFAULT_SCORES_DIR = Path(
    "/home/sjaconette/.gemini/antigravity/brain/d28d22f4-2d13-41e2-9b7b-32757f58523b/scratch"
)
DEFAULT_ROSTER_PATH = DEFAULT_ARENA_DIR / "bots" / "roster.json"

CORE_12_HISTORICAL = frozenset({
    "12PoolBot", "Chance", "Creepy_strategies", "RustyNikolaj", "SmoothBrain",
    "Thssprtssbt", "mini-puck", "monsterbot", "oberon", "puck",
    "sludgement2-revived", "titania",
})

TOWNHALL_NAMES = frozenset({
    "Nexus",
    "CommandCenter", "CommandCenterFlying",
    "OrbitalCommand", "OrbitalCommandFlying",
    "PlanetaryFortress",
    "Hatchery", "Lair", "Hive",
})

# Noisy transient tokens excluded from match_build_events (still tracked cleanly where relevant)
BUILD_EVENT_SKIP_UNITS = frozenset({
    "Larva", "Egg", "Interceptor", "Broodling", "BroodlingEscort",
    "LocustMP", "LocustMPFlying", "AdeptPhaseShift", "DisruptorPhased",
    "KD8Charge", "ForceField", "ParasiticBombDummy", "ParasiticBombRelayDummy",
    "ScannerSweep", "PointDefenseDrone",
})

BUILD_EVENT_SKIP_PREFIXES = (
    "Spray", "Reward", "Beacon", "Destructible", "MineralField", "VespeneGeyser",
    "RichMineralField", "RichVespeneGeyser", "SpacePlatformGeyser", "XelNaga",
)

GAME_LOOPS_PER_SEC = 22.4
GAME_LOOPS_PER_MIN = 1344.0  # 60 * 22.4

TABLES_SQL = """
CREATE TABLE IF NOT EXISTS runs (
    run_id TEXT PRIMARY KEY,
    tag TEXT,
    git_rev TEXT,
    run_dir TEXT,
    score_json_path TEXT,
    mothman_mode TEXT,
    image TEXT,
    concurrency INTEGER,
    wall_elapsed_sec REAL,
    started_at TEXT,
    total_replays INTEGER DEFAULT 0,
    ingested_at TEXT
);

CREATE TABLE IF NOT EXISTS matches (
    replay_id TEXT PRIMARY KEY,
    replay_sha256 TEXT NOT NULL,
    replay_mtime REAL,
    replay_size_bytes INTEGER,
    run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    match_index INTEGER,
    replay_path TEXT NOT NULL UNIQUE,
    replay_filename TEXT,
    bot TEXT,
    our_race TEXT,
    actual_race TEXT,
    opponent TEXT,
    opp_race TEXT,
    opp_cohort TEXT,
    matchup TEXT,
    map_name TEXT,
    our_player_id INTEGER DEFAULT 1,
    our_spawn_corner TEXT,
    our_start_x REAL,
    our_start_y REAL,
    opp_start_x REAL,
    opp_start_y REAL,
    result TEXT,
    duration_sec REAL,
    game_loops INTEGER,
    killed_val REAL,
    lost_val REAL,
    trade_ratio REAL,
    w4m INTEGER,
    w6m INTEGER,
    peak_workers INTEGER,
    peak_army_val REAL,
    peak_bases INTEGER,
    opp_peak_workers INTEGER,
    opp_peak_army_val REAL,
    opp_bases INTEGER,
    sup_blk_pct REAL,
    opp_sup_blk_pct REAL,
    avg_step_ms REAL,
    p95_step_ms REAL,
    max_step_ms REAL,
    tr_ms REAL,
    tr_p95_ms REAL,
    action_rejects INTEGER,
    is_clean INTEGER DEFAULT 1,
    is_selfplay INTEGER DEFAULT 0,
    p2_logged INTEGER DEFAULT 0,
    source_type TEXT DEFAULT 'local_arena',
    bot_build_version TEXT,
    aiarena_match_id INTEGER,
    aiarena_bot_elo INTEGER,
    aiarena_opp_elo INTEGER,
    replay_chat_tags TEXT,
    raw_extracted_at TEXT,
    game_events_extracted_at TEXT,
    score_meta_json TEXT
);

CREATE TABLE IF NOT EXISTS match_anomalies (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    replay_id TEXT NOT NULL REFERENCES matches(replay_id) ON DELETE CASCADE,
    player_side TEXT NOT NULL,
    anomaly_name TEXT NOT NULL,
    detail TEXT,
    UNIQUE(replay_id, player_side, anomaly_name)
);

CREATE TABLE IF NOT EXISTS match_minute_stats (
    replay_id TEXT NOT NULL REFERENCES matches(replay_id) ON DELETE CASCADE,
    player_id INTEGER NOT NULL,
    minute INTEGER NOT NULL,
    game_loop INTEGER NOT NULL,
    minerals_current INTEGER,
    vespene_current INTEGER,
    minerals_rate INTEGER,
    vespene_rate INTEGER,
    workers_active INTEGER,
    army_value_minerals INTEGER,
    army_value_vespene INTEGER,
    army_value_total INTEGER,
    food_used REAL,
    food_made REAL,
    lost_minerals INTEGER,
    lost_vespene INTEGER,
    lost_total INTEGER,
    killed_minerals INTEGER,
    killed_vespene INTEGER,
    killed_total INTEGER,
    bases_alive INTEGER,
    PRIMARY KEY (replay_id, player_id, minute)
);

CREATE TABLE IF NOT EXISTS match_build_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    replay_id TEXT NOT NULL REFERENCES matches(replay_id) ON DELETE CASCADE,
    player_id INTEGER NOT NULL,
    game_loop INTEGER NOT NULL,
    sec REAL NOT NULL,
    event_type TEXT NOT NULL,
    unit_type TEXT NOT NULL,
    x REAL,
    y REAL,
    unit_tag INTEGER
);

CREATE TABLE IF NOT EXISTS match_unit_totals (
    replay_id TEXT NOT NULL REFERENCES matches(replay_id) ON DELETE CASCADE,
    player_id INTEGER NOT NULL,
    unit_type TEXT NOT NULL,
    created INTEGER NOT NULL,
    died INTEGER NOT NULL,
    first_sec REAL,
    peak_alive INTEGER NOT NULL,
    PRIMARY KEY (replay_id, player_id, unit_type)
);

CREATE TABLE IF NOT EXISTS match_cmd_summary (
    replay_id TEXT NOT NULL REFERENCES matches(replay_id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL,
    minute INTEGER NOT NULL,
    cmd_count INTEGER NOT NULL,
    selection_count INTEGER NOT NULL,
    camera_count INTEGER NOT NULL,
    apm REAL NOT NULL,
    top_abilities_json TEXT,
    PRIMARY KEY (replay_id, user_id, minute)
);
"""

MATCHES_MIGRATION_COLUMNS: tuple[tuple[str, str], ...] = (
    ("source_type", "TEXT DEFAULT 'local_arena'"),
    ("bot_build_version", "TEXT"),
    ("aiarena_match_id", "INTEGER"),
    ("aiarena_bot_elo", "INTEGER"),
    ("aiarena_opp_elo", "INTEGER"),
    ("replay_chat_tags", "TEXT"),
)

INDEXES_SQL = """
CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_at);
CREATE INDEX IF NOT EXISTS idx_runs_tag ON runs(tag);
CREATE INDEX IF NOT EXISTS idx_matches_run ON matches(run_id);
CREATE INDEX IF NOT EXISTS idx_matches_bot_opp ON matches(bot, opponent);
CREATE INDEX IF NOT EXISTS idx_matches_cohort_res ON matches(opp_cohort, result);
CREATE INDEX IF NOT EXISTS idx_matches_map_corner ON matches(map_name, our_spawn_corner, result);
CREATE INDEX IF NOT EXISTS idx_matches_matchup ON matches(matchup, result);
CREATE INDEX IF NOT EXISTS idx_matches_sha ON matches(replay_sha256);
CREATE INDEX IF NOT EXISTS idx_matches_source ON matches(source_type, result);
CREATE INDEX IF NOT EXISTS idx_matches_build ON matches(bot_build_version);
CREATE INDEX IF NOT EXISTS idx_matches_aiarena_mid ON matches(aiarena_match_id);
CREATE INDEX IF NOT EXISTS idx_anomalies_name ON match_anomalies(anomaly_name, player_side);
CREATE INDEX IF NOT EXISTS idx_anomalies_replay ON match_anomalies(replay_id);
CREATE INDEX IF NOT EXISTS idx_min_stats_min ON match_minute_stats(minute, player_id);
CREATE INDEX IF NOT EXISTS idx_build_events_replay ON match_build_events(replay_id, player_id, game_loop);
CREATE INDEX IF NOT EXISTS idx_build_events_type ON match_build_events(event_type, unit_type);
CREATE INDEX IF NOT EXISTS idx_unit_totals_unit ON match_unit_totals(unit_type, player_id);
CREATE INDEX IF NOT EXISTS idx_cmd_summary_replay ON match_cmd_summary(replay_id, user_id, minute);
"""


# ---------------------------------------------------------------------------
# Helpers & s2protocol loader (Python 3.13 compatible, no legacy `imp` module)
# ---------------------------------------------------------------------------

_PROTO_CACHE: dict[int, Any] = {}


def _now_utc_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _safe_float(v: Any) -> float | None:
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)) and math.isfinite(float(v)):
        return float(v)
    return None


def _safe_int(v: Any) -> int | None:
    f = _safe_float(v)
    return int(round(f)) if f is not None else None


def _decode_str(v: Any) -> str:
    if isinstance(v, bytes):
        return v.decode("utf-8", errors="ignore")
    return str(v or "")


def _norm_race(r: Any) -> str | None:
    s = _decode_str(r).strip()
    if not s:
        return None
    low = s.lower()
    if low in ("p", "protoss", "prot"):
        return "Protoss"
    if low in ("t", "terran", "terr"):
        return "Terran"
    if low in ("z", "zerg"):
        return "Zerg"
    if low in ("r", "random", "rand"):
        return "Random"
    return s


def _norm_result(r: Any) -> str | None:
    s = _decode_str(r).strip().lower()
    if not s:
        return None
    if s in ("win", "victory", "player1win"):
        return "win"
    if s in ("loss", "defeat", "player2win"):
        return "loss"
    if s in ("tie", "draw"):
        return "tie"
    if "crash" in s or "error" in s or "timeout" in s:
        return s
    return s


def _parse_tag_from_run_id(run_id: str) -> str:
    m = re.match(r"^\d{8}_\d{6}_(.+)$", run_id)
    return m.group(1) if m else run_id


def _parse_started_at_from_run_id(run_id: str) -> str | None:
    m = re.match(r"^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})", run_id)
    if not m:
        return None
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}T{m.group(4)}:{m.group(5)}:{m.group(6)}Z"


def _parse_replay_filename(filename: str) -> dict[str, Any]:
    """Fallback metadata parser for `001_Mothman-Z_vs_titania_MagannathaAIE_v2.SC2Replay`."""
    stem = Path(filename).stem
    out: dict[str, Any] = {}
    m = re.match(r"^(\d+)_(.+?)_vs_(.+)$", stem)
    if not m:
        return out
    out["match_index"] = int(m.group(1))
    out["bot"] = m.group(2)
    rest = m.group(3)
    # Match known SC2Map naming pattern `_<MapName>AIE...` or last underscore segment
    mm = re.search(r"_([A-Za-z0-9]+AIE(?:_v\d+)?)$", rest)
    if mm:
        out["opponent"] = rest[: mm.start()]
        out["map_name"] = mm.group(1)
    else:
        parts = rest.rsplit("_", 1)
        out["opponent"] = parts[0]
        if len(parts) == 2:
            out["map_name"] = parts[1]
    return out


def _sha256_and_stat(path: Path) -> tuple[str, float, int]:
    st = path.stat()
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest(), st.st_mtime, st.st_size


def _hash_worker(path_str: str) -> tuple[str, str, float, int]:
    p = Path(path_str)
    sha, mtime, sz = _sha256_and_stat(p)
    return path_str, sha, mtime, sz


def _ensure_pylibs(pylibs_dir: Path = DEFAULT_PYLIBS_DIR) -> None:
    p = str(pylibs_dir)
    if p not in sys.path and pylibs_dir.is_dir():
        sys.path.insert(0, p)


def _load_protocol(base_build: int = 75689, pylibs_dir: Path = DEFAULT_PYLIBS_DIR) -> Any:
    if base_build in _PROTO_CACHE:
        return _PROTO_CACHE[base_build]
    vdir = pylibs_dir / "s2protocol" / "versions"
    cand = vdir / f"protocol{base_build}.py"
    if not cand.exists():
        cand = vdir / "protocol75689.py"
        if not cand.exists():
            protos = sorted(vdir.glob("protocol*.py"))
            if not protos:
                raise FileNotFoundError(f"No s2protocol protocol*.py found in {vdir}")
            cand = protos[-1]
    mod_name = f"_s2proto_{cand.stem}"
    spec = importlib.util.spec_from_file_location(mod_name, str(cand))
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot load protocol module {cand}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _PROTO_CACHE[base_build] = mod
    return mod


def _classify_spawn_corner(
    x: float | None, y: float | None, mid_x: float, mid_y: float
) -> str | None:
    if x is None or y is None:
        return None
    ns = "N" if y >= mid_y else "S"
    ew = "E" if x >= mid_x else "W"
    return ns + ew


def _canonical_map_name(map_name: str | None) -> str:
    """Unify local (`LeyLinesAIE_v3`) & prod (`Ley Lines AIE`) map names -> `LeyLines`."""
    s = str(map_name or "").strip()
    if not s:
        return "Unknown"
    s = re.sub(r"\.SC2Map$", "", s, flags=re.IGNORECASE)
    s = re.sub(r"[\s_-]*AIE(?:_?v\d+)?$", "", s, flags=re.IGNORECASE)
    s = re.sub(r"(?:[\s_-]+(?:LE|TE)|[\s_-]*v\d+)$", "", s, flags=re.IGNORECASE)
    s = re.sub(r"[\s_]+", "", s)
    return s or "Unknown"


def _is_selfplay_opp(opp: str | None, cohort: str | None = None) -> bool:
    c = (cohort or "").strip().lower()
    if c == "selfplay":
        return True
    o = (opp or "").strip()
    return o.startswith("Mothman-") or o.endswith("-SP") or o.endswith("-Base")


def _load_roster_core_set(roster_path: Path = DEFAULT_ROSTER_PATH) -> set[str]:
    if not roster_path.exists():
        return set(CORE_12_HISTORICAL)
    try:
        data = json.loads(roster_path.read_text())
        items = data.get("bots", data) if isinstance(data, dict) else data
        out = {
            str(e["name"])
            for e in items
            if isinstance(e, dict) and e.get("gauntlet_core") is True and e.get("name")
        }
        return out or set(CORE_12_HISTORICAL)
    except Exception:
        return set(CORE_12_HISTORICAL)


def _infer_race_from_bot_name(bot_name: str | None) -> str | None:
    s = (bot_name or "").strip()
    if not s:
        return None
    if re.search(r"-Z(?:$|[-_])", s, re.IGNORECASE):
        return "Zerg"
    if re.search(r"-T(?:$|[-_])", s, re.IGNORECASE):
        return "Terran"
    if re.search(r"-P(?:$|[-_])", s, re.IGNORECASE):
        return "Protoss"
    if re.search(r"-[XR](?:$|[-_])", s, re.IGNORECASE):
        return "Random"
    return None


def _normalize_build_version(ver: str | None) -> str | None:
    """Normalize build version strings by stripping leading `v_` so log & chat tags merge cleanly."""
    if not ver:
        return None
    s = str(ver).strip()
    if not s or s.lower() in ("unknown", "none", "n/a"):
        return None
    if re.match(r"^v_", s, re.IGNORECASE) and len(s) > 2:
        s = s[2:]
    return s or None


def _parse_scbot_build_from_text(text: str | None) -> str | None:
    """Extract build/version identifier from a `[SCBOT_BUILD]` log line."""
    if not text:
        return None
    for line in text.splitlines():
        if "[SCBOT_BUILD]" not in line:
            continue
        after = line.split("[SCBOT_BUILD]", 1)[1].strip()
        if not after:
            continue
        for pat in (
            r"\b(?:version|ver|build|tag)=([^\s,;]+)",
            r"\b(?:rev|commit|git|sha)=([^\s,;]+)",
        ):
            m = re.search(pat, after, re.IGNORECASE)
            if m:
                val = _normalize_build_version(m.group(1))
                if val:
                    return val
        first_tok = after.split()[0].strip(",;")
        if first_tok and "=" not in first_tok:
            val = _normalize_build_version(first_tok)
            if val:
                return val
    return None


def _parse_scbot_build_from_log_file(log_path: str | Path | None) -> str | None:
    if not log_path:
        return None
    p = Path(str(log_path))
    if not p.is_file():
        return None
    try:
        with p.open("rb") as fh:
            head = fh.read(32768).decode("utf-8", errors="ignore")
        return _parse_scbot_build_from_text(head)
    except Exception:
        return None


def _parse_version_from_chat_tags(
    tagged_msgs: list[tuple[int | None, str]], our_pid: int
) -> str | None:
    """Extract Mothman's build version from `Tag:v_...` in replay.message.events."""
    for sender_pid, msg in tagged_msgs:
        if sender_pid is not None and sender_pid != our_pid:
            continue
        m = re.match(r"^Tag:\s*(v_[A-Za-z0-9._-]+)", msg, re.IGNORECASE)
        if m:
            return _normalize_build_version(m.group(1))
        m2 = re.match(
            r"^Tag:\s*(?:build|version|ver|rev)[=:]\s*([A-Za-z0-9._-]+)",
            msg,
            re.IGNORECASE,
        )
        if m2:
            return _normalize_build_version(m2.group(1))
    return None


def _parse_iso_utc(ts: str | None) -> dt.datetime | None:
    if not ts:
        return None
    s = str(ts).strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        d = dt.datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.timezone.utc)
        return d.astimezone(dt.timezone.utc)
    except Exception:
        return None


def _load_deploy_timeline(repo_dir: Path = REPO_ROOT) -> list[tuple[dt.datetime, str, str]]:
    """Return ascending [(utc_dt, short8_rev, desc)] of commits touching ladder/Mothman-Z.zip."""
    if not repo_dir.is_dir():
        return []
    entries: list[tuple[dt.datetime, str, str]] = []
    # Prefer Jujutsu (`jj`)
    try:
        res = subprocess.run(
            [
                "jj", "log", "-R", str(repo_dir), "--no-graph",
                "-r", 'ancestors(@) & files(root:"ladder/Mothman-Z.zip")',
                "-T", 'commit_id.short(8) ++ "|" ++ committer.timestamp().utc().format("%Y-%m-%dT%H:%M:%SZ") ++ "|" ++ description.first_line() ++ "\\n"',
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if res.returncode == 0 and res.stdout.strip():
            for line in res.stdout.splitlines():
                parts = line.split("|", 2)
                if len(parts) < 2:
                    continue
                d = _parse_iso_utc(parts[1])
                if d is not None:
                    entries.append((d, parts[0].strip(), parts[2].strip() if len(parts) > 2 else ""))
    except Exception:
        entries = []

    # Fallback to git log if jj unavailable
    if not entries:
        try:
            res = subprocess.run(
                [
                    "git", "-C", str(repo_dir), "log",
                    "--format=%h|%cI|%s", "--", "ladder/Mothman-Z.zip",
                ],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if res.returncode == 0 and res.stdout.strip():
                for line in res.stdout.splitlines():
                    parts = line.split("|", 2)
                    if len(parts) < 2:
                        continue
                    d = _parse_iso_utc(parts[1])
                    if d is not None:
                        entries.append((d, parts[0].strip()[:8], parts[2].strip() if len(parts) > 2 else ""))
        except Exception:
            pass

    entries.sort(key=lambda x: x[0])
    return entries


def _resolve_deploy_commit(
    created_iso: str | None,
    timeline: list[tuple[dt.datetime, str, str]],
) -> str | None:
    """Map a match UTC timestamp to the most recent deploy commit <= match time."""
    if not timeline:
        return None
    ts = _parse_iso_utc(created_iso)
    if ts is None:
        return None
    chosen: str | None = None
    for deploy_ts, short8, _desc in timeline:
        if deploy_ts <= ts:
            chosen = short8
        else:
            break
    return f"deploy:{chosen}" if chosen else None


def _extract_map_from_aiarena_url(url: str | None) -> str | None:
    if not url:
        return None
    # Strip query string and examine replay basename
    base = str(url).split("?", 1)[0].rsplit("/", 1)[-1]
    stem = Path(base).stem
    m = re.search(r"_([A-Za-z0-9]+AIE(?:_v\d+)?)$", stem)
    return m.group(1) if m else None


def _parse_duration_hms(dur: Any) -> float | None:
    if isinstance(dur, (int, float)):
        return _safe_float(dur)
    s = str(dur or "").strip()
    m = re.match(r"^(\d+):(\d{2}):(\d{2})(?:\.(\d+))?$", s)
    if not m:
        return None
    return float(int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)))


# ---------------------------------------------------------------------------
# Database connection, schema initialization & automatic migrations
# ---------------------------------------------------------------------------

def ensure_schema_migrations(conn: sqlite3.Connection) -> None:
    """Safely migrate existing DBs by adding any new columns before index creation."""
    existing = {row[1] for row in conn.execute("PRAGMA table_info(matches)").fetchall()}
    added_source = False
    for col_name, col_def in MATCHES_MIGRATION_COLUMNS:
        if col_name not in existing:
            conn.execute(f"ALTER TABLE matches ADD COLUMN {col_name} {col_def}")
            if col_name == "source_type":
                added_source = True
    if added_source:
        conn.execute("UPDATE matches SET source_type = 'local_arena' WHERE source_type IS NULL")
    # Merge `v_<rev>` chat-tag versions with `<rev>` [SCBOT_BUILD] log versions cleanly
    conn.execute(
        "UPDATE matches SET bot_build_version = SUBSTR(bot_build_version, 3) "
        "WHERE (bot_build_version LIKE 'v_%' OR bot_build_version LIKE 'V_%') AND LENGTH(bot_build_version) > 2"
    )


def open_db(db_path: Path, readonly: bool = False) -> sqlite3.Connection:
    if readonly:
        uri = f"file:{db_path}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, timeout=30.0)
    else:
        db_path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(db_path), timeout=60.0)
        conn.execute("PRAGMA journal_mode=WAL;")
        conn.execute("PRAGMA synchronous=NORMAL;")
        conn.execute("PRAGMA foreign_keys=ON;")
        conn.execute("PRAGMA temp_store=MEMORY;")
        conn.execute("PRAGMA cache_size=-64000;")
        conn.executescript(TABLES_SQL)
        ensure_schema_migrations(conn)
        conn.executescript(INDEXES_SQL)
    conn.create_function("canon_map", 1, _canonical_map_name)
    conn.row_factory = sqlite3.Row
    return conn


# ---------------------------------------------------------------------------
# Raw .SC2Replay extraction worker (runs in ProcessPoolExecutor)
# ---------------------------------------------------------------------------

def extract_single_replay(
    replay_path_str: str,
    replay_id: str,
    include_game_events: bool = False,
    expected_bot: str | None = None,
    pylibs_dir_str: str = str(DEFAULT_PYLIBS_DIR),
    expected_pid: int | None = None,
) -> dict[str, Any]:
    """Decode one .SC2Replay via mpyq + s2protocol and return structured rows."""
    t0 = time.perf_counter()
    pylibs_dir = Path(pylibs_dir_str)
    _ensure_pylibs(pylibs_dir)
    import mpyq

    rp = Path(replay_path_str)
    try:
        arc = mpyq.MPQArchive(str(rp))
        proto0 = _load_protocol(75689, pylibs_dir)
        hdr = proto0.decode_replay_header(arc.header["user_data_header"]["content"])
        base_build = int((hdr.get("m_version") or {}).get("m_baseBuild") or 75689)
        proto = _load_protocol(base_build, pylibs_dir)
        game_loops = int(hdr.get("m_elapsedGameLoops") or 0)
        duration_sec = round(game_loops / GAME_LOOPS_PER_SEC, 2) if game_loops > 0 else None

        details_bytes = arc.read_file("replay.details")
        details = proto.decode_replay_details(details_bytes) if details_bytes else {}
        map_title = _decode_str(details.get("m_title")).strip() or None

        players: dict[int, dict[str, Any]] = {}
        plist = details.get("m_playerList") or []
        for idx, pl in enumerate(plist, start=1):
            pid = idx
            pname = _decode_str(pl.get("m_name")).strip()
            prace = _norm_race(pl.get("m_race"))
            pres = pl.get("m_result")  # 1=Win, 2=Loss, 0=Undecided/Tie
            players[pid] = {"name": pname, "race": prace, "result_code": pres}

        # Identify which player_id is our bot:
        # 1. Explicit expected_pid (e.g., AI Arena participant_number) if consistent with expected_bot
        # 2. Exact/substring expected_bot name match against m_playerList
        # 3. Fallback to expected_pid or 1
        our_pid = 1
        p1n = (players.get(1, {}).get("name") or "").lower()
        p2n = (players.get(2, {}).get("name") or "").lower()
        eb = (expected_bot or "").strip().lower()
        if expected_pid in (1, 2) and (not eb or eb in (players.get(expected_pid, {}).get("name") or "").lower()):
            our_pid = expected_pid
        elif eb and 2 in players:
            if eb == p2n and eb != p1n:
                our_pid = 2
            elif eb == p1n and eb != p2n:
                our_pid = 1
            elif (eb in p2n) and (eb not in p1n):
                our_pid = 2
            elif (eb in p1n) and (eb not in p2n):
                our_pid = 1
            elif expected_pid in (1, 2):
                our_pid = expected_pid
        elif expected_pid in (1, 2):
            our_pid = expected_pid
        opp_pid = 2 if our_pid == 1 else 1

        our_info = players.get(our_pid) or {}
        opp_info = players.get(opp_pid) or {}
        raw_result = None
        rc = our_info.get("result_code")
        if rc == 1:
            raw_result = "win"
        elif rc == 2:
            raw_result = "loss"
        elif rc == 0 and game_loops > 0:
            raw_result = "tie"

        # Decode replay.message.events for `Tag:` chat messages & `Tag:v_...` build tags
        tagged_msgs: list[tuple[int | None, str]] = []
        chat_tags_list: list[str] = []
        msg_bytes = arc.read_file("replay.message.events")
        if msg_bytes:
            try:
                for mev in proto.decode_replay_message_events(msg_bytes):
                    if mev.get("_event") != "NNet.Game.SChatMessage":
                        continue
                    txt = _decode_str(mev.get("m_string")).strip()
                    if not txt or not txt.lower().startswith("tag:"):
                        continue
                    uid = (mev.get("_userid") or {}).get("m_userId")
                    sender_pid = (int(uid) + 1) if isinstance(uid, int) and uid in (0, 1) else None
                    tagged_msgs.append((sender_pid, txt))
                    if not chat_tags_list or chat_tags_list[-1] != txt:
                        chat_tags_list.append(txt)
            except Exception:
                pass
        replay_chat_tags_json = (
            json.dumps(chat_tags_list, separators=(",", ":")) if chat_tags_list else None
        )
        chat_build_version = _parse_version_from_chat_tags(tagged_msgs, our_pid)

        trk_bytes = arc.read_file("replay.tracker.events")
        if not trk_bytes:
            return {"ok": False, "replay_id": replay_id, "error": "missing replay.tracker.events"}

        # Track map bounds at loop 0, start townhalls, live units, stats, build events, totals
        loop0_xs: list[float] = []
        loop0_ys: list[float] = []
        start_pos: dict[int, tuple[float, float]] = {}

        # unit_key=(idx, recycle) -> [pid, unit_type, is_completed]
        live_units: dict[tuple[int, int], list[Any]] = {}
        bases_alive: dict[int, int] = {1: 0, 2: 0}
        # Track minute-level bases_alive snapshots alongside SPlayerStatsEvent
        # stats_best[(pid, minute)] = (abs_loop_err, loop, stats_dict, bases_cnt)
        stats_best: dict[tuple[int, int], tuple[int, int, dict[str, Any], int]] = {}

        # unit totals: (pid, unit_type) -> [created, died, first_sec, cur_alive, peak_alive]
        unit_totals: dict[tuple[int, int | str], list[Any]] = {}
        build_events: list[tuple[Any, ...]] = []

        def _rec_unit_born(pid: int, utype: str, sec: float) -> None:
            key = (pid, utype)
            rec = unit_totals.get(key)
            if rec is None:
                unit_totals[key] = [1, 0, sec, 1, 1]
            else:
                rec[0] += 1
                rec[3] += 1
                if rec[3] > rec[4]:
                    rec[4] = rec[3]

        def _rec_unit_died(pid: int, utype: str) -> None:
            key = (pid, utype)
            rec = unit_totals.get(key)
            if rec is not None:
                rec[1] += 1
                if rec[3] > 0:
                    rec[3] -= 1

        def _should_keep_build_event(utype: str) -> bool:
            if not utype or utype in BUILD_EVENT_SKIP_UNITS:
                return False
            for pref in BUILD_EVENT_SKIP_PREFIXES:
                if utype.startswith(pref):
                    return False
            return True

        for ev in proto.decode_replay_tracker_events(trk_bytes):
            et = ev.get("_event")
            gl = int(ev.get("_gameloop") or 0)
            sec = round(gl / GAME_LOOPS_PER_SEC, 2)

            if et == "NNet.Replay.Tracker.SUnitBornEvent":
                pid = int(ev.get("m_controlPlayerId") or ev.get("m_upkeepPlayerId") or 0)
                utype = _decode_str(ev.get("m_unitTypeName"))
                x = _safe_float(ev.get("m_x"))
                y = _safe_float(ev.get("m_y"))
                idx = int(ev.get("m_unitTagIndex") or 0)
                rec = int(ev.get("m_unitTagRecycle") or 0)
                tag = (idx << 18) | rec
                if gl == 0 and x is not None and y is not None:
                    loop0_xs.append(x)
                    loop0_ys.append(y)
                    if pid in (1, 2) and utype in TOWNHALL_NAMES and pid not in start_pos:
                        start_pos[pid] = (x, y)
                if pid in (1, 2):
                    live_units[(idx, rec)] = [pid, utype, True]
                    if utype in TOWNHALL_NAMES:
                        bases_alive[pid] = bases_alive.get(pid, 0) + 1
                    _rec_unit_born(pid, utype, sec)
                    if gl > 0 and _should_keep_build_event(utype):
                        build_events.append((replay_id, pid, gl, sec, "born", utype, x, y, tag))

            elif et == "NNet.Replay.Tracker.SUnitInitEvent":
                pid = int(ev.get("m_controlPlayerId") or ev.get("m_upkeepPlayerId") or 0)
                utype = _decode_str(ev.get("m_unitTypeName"))
                x = _safe_float(ev.get("m_x"))
                y = _safe_float(ev.get("m_y"))
                idx = int(ev.get("m_unitTagIndex") or 0)
                rec = int(ev.get("m_unitTagRecycle") or 0)
                tag = (idx << 18) | rec
                if pid in (1, 2):
                    live_units[(idx, rec)] = [pid, utype, False]
                    if _should_keep_build_event(utype):
                        build_events.append((replay_id, pid, gl, sec, "init", utype, x, y, tag))

            elif et == "NNet.Replay.Tracker.SUnitDoneEvent":
                idx = int(ev.get("m_unitTagIndex") or 0)
                rec = int(ev.get("m_unitTagRecycle") or 0)
                tag = (idx << 18) | rec
                info = live_units.get((idx, rec))
                if info is not None:
                    pid, utype, was_done = info
                    if not was_done:
                        info[2] = True
                        if utype in TOWNHALL_NAMES:
                            bases_alive[pid] = bases_alive.get(pid, 0) + 1
                        _rec_unit_born(pid, utype, sec)
                        if _should_keep_build_event(utype):
                            build_events.append((replay_id, pid, gl, sec, "done", utype, None, None, tag))

            elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
                idx = int(ev.get("m_unitTagIndex") or 0)
                rec = int(ev.get("m_unitTagRecycle") or 0)
                tag = (idx << 18) | rec
                new_type = _decode_str(ev.get("m_unitTypeName"))
                info = live_units.get((idx, rec))
                if info is not None and new_type:
                    pid, old_type, was_done = info
                    if old_type != new_type:
                        if was_done:
                            old_th = old_type in TOWNHALL_NAMES
                            new_th = new_type in TOWNHALL_NAMES
                            if old_th and not new_th:
                                bases_alive[pid] = max(0, bases_alive.get(pid, 0) - 1)
                            elif new_th and not old_th:
                                bases_alive[pid] = bases_alive.get(pid, 0) + 1
                            # Decrement old alive count, record morph into new type
                            old_rec = unit_totals.get((pid, old_type))
                            if old_rec is not None and old_rec[3] > 0:
                                old_rec[3] -= 1
                            _rec_unit_born(pid, new_type, sec)
                        info[1] = new_type
                        if _should_keep_build_event(new_type) and not (
                            # Skip noisy Tank/Viking/Liberator/SupplyDepot/Gateway mode toggles from build timeline
                            {old_type, new_type} <= {"SiegeTank", "SiegeTankSieged"}
                            or {old_type, new_type} <= {"VikingFighter", "VikingAssault"}
                            or {old_type, new_type} <= {"Liberator", "LiberatorAG"}
                            or {old_type, new_type} <= {"SupplyDepot", "SupplyDepotLowered"}
                            or {old_type, new_type} <= {"WidowMine", "WidowMineBurrowed"}
                            or {old_type, new_type} <= {"Hellion", "HellionTank"}
                            or {old_type, new_type} <= {"Gateway", "WarpGate"}
                            or {old_type, new_type} <= {"WarpPrism", "WarpPrismPhasing"}
                            or {old_type, new_type} <= {"LurkerMP", "LurkerMPBurrowed"}
                            or {old_type, new_type} <= {"Roach", "RoachBurrowed"}
                            or {old_type, new_type} <= {"Zergling", "ZerglingBurrowed"}
                            or {old_type, new_type} <= {"Baneling", "BanelingBurrowed"}
                            or {old_type, new_type} <= {"SpineCrawler", "SpineCrawlerUprooted"}
                            or {old_type, new_type} <= {"SporeCrawler", "SporeCrawlerUprooted"}
                            or {old_type, new_type} <= {"Observer", "ObserverSiegeMode"}
                            or {old_type, new_type} <= {"Overseer", "OverseerSiegeMode"}
                        ):
                            build_events.append((replay_id, pid, gl, sec, "morph", new_type, None, None, tag))

            elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
                idx = int(ev.get("m_unitTagIndex") or 0)
                rec = int(ev.get("m_unitTagRecycle") or 0)
                tag = (idx << 18) | rec
                x = _safe_float(ev.get("m_x"))
                y = _safe_float(ev.get("m_y"))
                info = live_units.pop((idx, rec), None)
                if info is not None:
                    pid, utype, was_done = info
                    if was_done:
                        if utype in TOWNHALL_NAMES:
                            bases_alive[pid] = max(0, bases_alive.get(pid, 0) - 1)
                        _rec_unit_died(pid, utype)
                    if _should_keep_build_event(utype):
                        build_events.append((replay_id, pid, gl, sec, "died", utype, x, y, tag))

            elif et == "NNet.Replay.Tracker.SUpgradeEvent":
                pid = int(ev.get("m_playerId") or 0)
                uname = _decode_str(ev.get("m_upgradeTypeName"))
                if pid in (1, 2) and gl > 0 and _should_keep_build_event(uname):
                    build_events.append((replay_id, pid, gl, sec, "upgrade", uname, None, None, None))

            elif et == "NNet.Replay.Tracker.SPlayerStatsEvent":
                pid = int(ev.get("m_playerId") or 0)
                if pid not in (1, 2):
                    continue
                st = ev.get("m_stats") or {}
                minute = int(round(gl / GAME_LOOPS_PER_MIN))
                target_loop = int(round(minute * GAME_LOOPS_PER_MIN))
                err = abs(gl - target_loop)
                if err <= 450:
                    prev = stats_best.get((pid, minute))
                    if prev is None or err < prev[0]:
                        stats_best[(pid, minute)] = (err, gl, st, bases_alive.get(pid, 0))

        # Compute map center and spawn corner
        if loop0_xs and loop0_ys:
            mid_x = 0.5 * (min(loop0_xs) + max(loop0_xs))
            mid_y = 0.5 * (min(loop0_ys) + max(loop0_ys))
        elif 1 in start_pos and 2 in start_pos:
            mid_x = 0.5 * (start_pos[1][0] + start_pos[2][0])
            mid_y = 0.5 * (start_pos[1][1] + start_pos[2][1])
        else:
            mid_x, mid_y = 100.0, 100.0

        our_xy = start_pos.get(our_pid)
        opp_xy = start_pos.get(opp_pid)
        our_corner = _classify_spawn_corner(
            our_xy[0] if our_xy else None,
            our_xy[1] if our_xy else None,
            mid_x,
            mid_y,
        )

        # Build minute_stats rows
        minute_rows: list[tuple[Any, ...]] = []
        for (pid, minute), (_err, gl, st, b_alive) in sorted(stats_best.items()):
            am = int(st.get("m_scoreValueMineralsUsedCurrentArmy") or 0)
            av = int(st.get("m_scoreValueVespeneUsedCurrentArmy") or 0)
            lm = (
                int(st.get("m_scoreValueMineralsLostArmy") or 0)
                + int(st.get("m_scoreValueMineralsLostEconomy") or 0)
                + int(st.get("m_scoreValueMineralsLostTechnology") or 0)
            )
            lv = (
                int(st.get("m_scoreValueVespeneLostArmy") or 0)
                + int(st.get("m_scoreValueVespeneLostEconomy") or 0)
                + int(st.get("m_scoreValueVespeneLostTechnology") or 0)
            )
            km = (
                int(st.get("m_scoreValueMineralsKilledArmy") or 0)
                + int(st.get("m_scoreValueMineralsKilledEconomy") or 0)
                + int(st.get("m_scoreValueMineralsKilledTechnology") or 0)
            )
            kv = (
                int(st.get("m_scoreValueVespeneKilledArmy") or 0)
                + int(st.get("m_scoreValueVespeneKilledEconomy") or 0)
                + int(st.get("m_scoreValueVespeneKilledTechnology") or 0)
            )
            fu = round(float(st.get("m_scoreValueFoodUsed") or 0) / 4096.0, 1)
            fm = round(float(st.get("m_scoreValueFoodMade") or 0) / 4096.0, 1)
            minute_rows.append((
                replay_id,
                pid,
                minute,
                gl,
                int(st.get("m_scoreValueMineralsCurrent") or 0),
                int(st.get("m_scoreValueVespeneCurrent") or 0),
                int(st.get("m_scoreValueMineralsCollectionRate") or 0),
                int(st.get("m_scoreValueVespeneCollectionRate") or 0),
                int(st.get("m_scoreValueWorkersActiveCount") or 0),
                am,
                av,
                am + av,
                fu,
                fm,
                lm,
                lv,
                lm + lv,
                km,
                kv,
                km + kv,
                b_alive,
            ))

        unit_total_rows: list[tuple[Any, ...]] = []
        for (pid, utype), rec in sorted(unit_totals.items()):
            unit_total_rows.append((replay_id, pid, utype, rec[0], rec[1], rec[2], rec[4]))

        # Optional game events -> per-minute APM / selection / cmd / top abilities
        cmd_rows: list[tuple[Any, ...]] = []
        if include_game_events:
            gev_bytes = arc.read_file("replay.game.events")
            if gev_bytes:
                buckets: dict[tuple[int, int], list[Any]] = {}
                # value: [cmd_cnt, sel_cnt, cam_cnt, Counter(abil)]
                for ev in proto.decode_replay_game_events(gev_bytes):
                    et = ev.get("_event")
                    uid = (ev.get("_userid") or {}).get("m_userId")
                    if uid not in (0, 1):
                        continue
                    gl = int(ev.get("_gameloop") or 0)
                    minute = int(gl // GAME_LOOPS_PER_MIN)
                    bkey = (int(uid), minute)
                    b = buckets.get(bkey)
                    if b is None:
                        b = [0, 0, 0, Counter()]
                        buckets[bkey] = b
                    if et == "NNet.Game.SCmdEvent":
                        b[0] += 1
                        ab = ev.get("m_abil")
                        if isinstance(ab, dict):
                            ab_key = f"{ab.get('m_abilLink')}:{ab.get('m_abilCmdIndex', 0)}"
                        else:
                            ab_key = "smart"
                        b[3][ab_key] += 1
                    elif et == "NNet.Game.SSelectionDeltaEvent":
                        b[1] += 1
                    elif et == "NNet.Game.SCameraUpdateEvent":
                        b[2] += 1
                for (uid, minute), b in sorted(buckets.items()):
                    top_ab = json.dumps(b[3].most_common(8))
                    cmd_rows.append((
                        replay_id,
                        uid,
                        minute,
                        b[0],
                        b[1],
                        b[2],
                        round(float(b[0] + b[1]), 1),
                        top_ab,
                    ))

        # Derive raw summary fallbacks if score.json didn't supply them
        p1_mins = [r for r in minute_rows if r[1] == our_pid]
        p2_mins = [r for r in minute_rows if r[1] == opp_pid]
        raw_w4 = next((r[8] for r in p1_mins if r[2] == 4), None)
        raw_w6 = next((r[8] for r in p1_mins if r[2] == 6), None)
        raw_pk_w = max((r[8] for r in p1_mins), default=None)
        raw_pk_a = max((r[11] for r in p1_mins), default=None)
        raw_pk_b = max((r[20] for r in p1_mins), default=None)
        raw_opp_pk_w = max((r[8] for r in p2_mins), default=None)
        raw_opp_pk_a = max((r[11] for r in p2_mins), default=None)
        raw_opp_pk_b = max((r[20] for r in p2_mins), default=None)
        raw_killed = max((r[19] for r in p1_mins), default=None)
        raw_lost = max((r[16] for r in p1_mins), default=None)
        raw_trade = (
            round(raw_killed / max(100.0, float(raw_lost)), 2)
            if (raw_killed is not None and raw_lost is not None)
            else None
        )

        raw_matchup = None
        if our_info.get("race") and opp_info.get("race"):
            or_r = our_info["race"]
            op_r = opp_info["race"]
            if or_r != "Random" and op_r != "Random":
                raw_matchup = f"{or_r[0]}v{op_r[0]}"

        return {
            "ok": True,
            "replay_id": replay_id,
            "elapsed_ms": round((time.perf_counter() - t0) * 1000.0, 1),
            "meta": {
                "actual_race": our_info.get("race"),
                "opp_race": opp_info.get("race"),
                "raw_matchup": raw_matchup,
                "map_title": map_title,
                "our_player_id": our_pid,
                "our_spawn_corner": our_corner,
                "our_start_x": our_xy[0] if our_xy else None,
                "our_start_y": our_xy[1] if our_xy else None,
                "opp_start_x": opp_xy[0] if opp_xy else None,
                "opp_start_y": opp_xy[1] if opp_xy else None,
                "game_loops": game_loops,
                "duration_sec": duration_sec,
                "raw_result": raw_result,
                "raw_w4": raw_w4,
                "raw_w6": raw_w6,
                "raw_pk_w": raw_pk_w,
                "raw_pk_a": raw_pk_a,
                "raw_pk_b": raw_pk_b,
                "raw_opp_pk_w": raw_opp_pk_w,
                "raw_opp_pk_a": raw_opp_pk_a,
                "raw_opp_pk_b": raw_opp_pk_b,
                "raw_killed": raw_killed,
                "raw_lost": raw_lost,
                "raw_trade": raw_trade,
                "replay_chat_tags": replay_chat_tags_json,
                "chat_build_version": chat_build_version,
            },
            "minute_rows": minute_rows,
            "build_events": build_events,
            "unit_total_rows": unit_total_rows,
            "cmd_rows": cmd_rows,
            "include_game_events": include_game_events,
        }
    except Exception as exc:
        return {"ok": False, "replay_id": replay_id, "error": f"{type(exc).__name__}: {exc}"}


# ---------------------------------------------------------------------------
# Subcommand: ingest-runs
# ---------------------------------------------------------------------------

def _collect_anomalies(an_dict: Any, side: str) -> list[tuple[str, str, str | None]]:
    out: list[tuple[str, str, str | None]] = []
    if not isinstance(an_dict, dict):
        return out
    for k, v in an_dict.items():
        if isinstance(v, bool):
            if v:
                out.append((side, str(k), None))
        elif isinstance(v, dict):
            if len(v) > 0:
                out.append((side, str(k), json.dumps(v, separators=(",", ":"))))
        elif isinstance(v, list):
            if len(v) > 0:
                out.append((side, str(k), json.dumps(v, separators=(",", ":"))))
        elif isinstance(v, (int, float)):
            if v:
                out.append((side, str(k), str(v)))
        elif isinstance(v, str) and v.strip():
            out.append((side, str(k), v.strip()))
    return out


TOP_LEVEL_SCORE_ANOMALY_FLAGS: tuple[str, ...] = (
    "wall_timeout_tie", "wall_timeout_winning_tie", "prod_placement_stall",
    "prod_idle_bank_freeze", "gas_zero_harvest_freeze", "one_base_lockout",
    "spire_sched_drop", "drip_feed_collapse", "zero_kill_collapse_loss",
    "early_opening_order_fault", "terran_111_opening_stall", "econ_eff_collapse",
    "late_game_stalemate_tie", "tvt_zero_tank", "pvp_nat_delay_flag",
    "siege_range_zero_dps_loss", "cloaked_unit_damage_loss",
    "gas_rich_min_starved", "early_rush_idle_bank_3m",
)

SCORE_EXTRA_META_KEYS: tuple[str, ...] = (
    "opening_bo_sequence", "upgrade_timings", "macro_timings", "tie_cause",
    "signatures", "map_symmetry_kind", "first_scout_unit", "first_scout_sec",
    "enemy_first_seen_sec", "army_val_4m_ratio_vs_pro", "army_val_8m_ratio_vs_pro",
    "wall_sec", "our_top_units", "opp_top_units", "has_logs",
)


def _extract_score_extra_meta(sc: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for k in SCORE_EXTRA_META_KEYS:
        if k in sc and sc[k] is not None:
            out[k] = sc[k]
    return out


def _sync_match_anomalies(
    conn: sqlite3.Connection, replay_id: str, sc: dict[str, Any]
) -> int:
    """Sync p1/p2 anomalies from a score-replay-batch.rkt match dict into match_anomalies."""
    anoms = _collect_anomalies(sc.get("anomalies"), "p1") + _collect_anomalies(
        sc.get("p2_anomalies"), "p2"
    )
    for flag_k in TOP_LEVEL_SCORE_ANOMALY_FLAGS:
        if sc.get(flag_k):
            an_name = "pvp_nat_delay" if flag_k == "pvp_nat_delay_flag" else flag_k
            if not any(a[0] == "p1" and a[1] == an_name for a in anoms):
                detail = None
                if flag_k == "prod_placement_stall" and sc.get("prod_placement_stall_ticks"):
                    detail = f"ticks={sc['prod_placement_stall_ticks']},streak={sc.get('prod_placement_stall_max_streak')}"
                elif flag_k == "gas_rich_min_starved" and sc.get("gas_rich_min_starved_ticks"):
                    detail = f"ticks={sc['gas_rich_min_starved_ticks']}"
                elif flag_k == "gas_zero_harvest_freeze" and sc.get("gas_zero_harvest_freeze_sec"):
                    detail = f"sec={sc['gas_zero_harvest_freeze_sec']}"
                anoms.append(("p1", an_name, detail))
    conn.execute("DELETE FROM match_anomalies WHERE replay_id = ?", (replay_id,))
    if anoms:
        conn.executemany(
            """
            INSERT OR REPLACE INTO match_anomalies (replay_id, player_side, anomaly_name, detail)
            VALUES (?, ?, ?, ?)
            """,
            [(replay_id, s, n, det) for s, n, det in anoms],
        )
    return len(anoms)


def _run_score_replay_batch(
    target_dir: Path,
    out_json: Path,
    jobs: int = 4,
    repo_dir: Path = REPO_ROOT,
) -> Path:
    """Run `racket tools/score-replay-batch.rkt` on target_dir and return out_json path."""
    scorer = repo_dir / "tools" / "score-replay-batch.rkt"
    if not scorer.is_file():
        raise FileNotFoundError(f"Scorer script not found: {scorer}")
    out_json.parent.mkdir(parents=True, exist_ok=True)
    eff_jobs = max(1, min(int(jobs), 4))
    cmd = ["racket", str(scorer), "--json", str(out_json), "-j", str(eff_jobs), str(target_dir)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0 or not out_json.is_file():
        raise RuntimeError(
            f"score-replay-batch.rkt failed (rc={res.returncode}):\n"
            f"STDOUT:\n{res.stdout[-1500:]}\nSTDERR:\n{res.stderr[-1500:]}"
        )
    return out_json


def cmd_ingest_runs(args: argparse.Namespace) -> int:
    t0 = time.perf_counter()
    db_path = Path(args.db)
    runs_dir = Path(args.runs_dir)
    scores_dirs = [Path(p) for p in (args.scores_dir or [str(DEFAULT_SCORES_DIR)])]
    explicit_scores = [Path(p) for p in (args.score_json or [])]
    roster_core = _load_roster_core_set(Path(args.roster))

    # 1. Index all score.json files by run_id (from their `dir` field)
    score_by_run: dict[str, tuple[Path, dict[str, Any]]] = {}
    score_files: list[Path] = []
    for sd in scores_dirs:
        if sd.is_dir():
            score_files.extend(sorted(sd.glob("*score*.json")))
    score_files.extend(explicit_scores)

    for sf in score_files:
        if not sf.is_file():
            continue
        try:
            data = json.loads(sf.read_text())
        except Exception:
            continue
        rdir_str = data.get("dir")
        if not rdir_str:
            continue
        rid = Path(str(rdir_str)).name
        # Keep the latest-mtime score.json if multiple exist for same run_id
        prev = score_by_run.get(rid)
        if prev is None or sf.stat().st_mtime >= prev[0].stat().st_mtime:
            score_by_run[rid] = (sf, data)

    # 2. Discover run directories
    run_dirs: list[Path] = []
    if runs_dir.is_dir():
        for p in sorted(runs_dir.iterdir()):
            if p.is_dir() and (
                (p / "summary.json").exists()
                or (p / "replays").is_dir()
                or p.name in score_by_run
            ):
                if args.run and args.run not in p.name:
                    continue
                run_dirs.append(p)

    # Also include any score.json whose run_dir lives outside runs_dir
    known_rids = {p.name for p in run_dirs}
    for rid, (_sf, sdata) in score_by_run.items():
        if rid not in known_rids:
            if args.run and args.run not in rid:
                continue
            p = Path(str(sdata.get("dir") or ""))
            if p.is_dir():
                run_dirs.append(p)

    conn = open_db(db_path)

    # Cache existing (replay_path -> (replay_id, replay_sha256, replay_mtime)) to skip re-hashing unchanged files
    existing_paths: dict[str, tuple[str, str, float | None]] = {}
    for row in conn.execute("SELECT replay_path, replay_id, replay_sha256, replay_mtime FROM matches"):
        existing_paths[row["replay_path"]] = (row["replay_id"], row["replay_sha256"], row["replay_mtime"])

    # Gather all replay paths that need hashing
    to_hash: list[str] = []
    run_replays: dict[str, list[Path]] = {}
    for rdir in run_dirs:
        rep_dir = rdir / "replays"
        rlist = sorted(rep_dir.glob("*.SC2Replay")) if rep_dir.is_dir() else []
        run_replays[rdir.name] = rlist
        for rp in rlist:
            rp_str = str(rp)
            st_mtime = rp.stat().st_mtime
            prev = existing_paths.get(rp_str)
            if prev is None or prev[2] is None or abs(prev[2] - st_mtime) > 1e-3:
                to_hash.append(rp_str)

    hash_map: dict[str, tuple[str, float, int]] = {}
    if to_hash:
        workers = max(1, min(int(args.jobs), len(to_hash)))
        with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as ex:
            for rp_str, sha, mtime, sz in ex.map(_hash_worker, to_hash, chunksize=8):
                hash_map[rp_str] = (sha, mtime, sz)

    now_iso = _now_utc_iso()
    runs_upserted = 0
    matches_upserted = 0
    anomalies_upserted = 0

    with conn:
        for rdir in run_dirs:
            rid = rdir.name
            summ: dict[str, Any] = {}
            summ_path = rdir / "summary.json"
            if summ_path.exists():
                try:
                    summ = json.loads(summ_path.read_text())
                except Exception:
                    summ = {}
            score_entry = score_by_run.get(rid)
            score_path = str(score_entry[0]) if score_entry else None
            score_data = score_entry[1] if score_entry else {}

            rlist = run_replays.get(rid, [])
            conn.execute(
                """
                INSERT INTO runs (
                    run_id, tag, git_rev, run_dir, score_json_path, mothman_mode,
                    image, concurrency, wall_elapsed_sec, started_at, total_replays, ingested_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET
                    tag=COALESCE(excluded.tag, runs.tag),
                    git_rev=COALESCE(excluded.git_rev, runs.git_rev),
                    run_dir=COALESCE(excluded.run_dir, runs.run_dir),
                    score_json_path=COALESCE(excluded.score_json_path, runs.score_json_path),
                    mothman_mode=COALESCE(excluded.mothman_mode, runs.mothman_mode),
                    image=COALESCE(excluded.image, runs.image),
                    concurrency=COALESCE(excluded.concurrency, runs.concurrency),
                    wall_elapsed_sec=COALESCE(excluded.wall_elapsed_sec, runs.wall_elapsed_sec),
                    started_at=COALESCE(excluded.started_at, runs.started_at),
                    total_replays=excluded.total_replays,
                    ingested_at=excluded.ingested_at
                """,
                (
                    rid,
                    _parse_tag_from_run_id(rid),
                    summ.get("repo_commit"),
                    str(rdir),
                    score_path,
                    summ.get("mothman_mode"),
                    summ.get("image"),
                    _safe_int(summ.get("concurrency")),
                    _safe_float(summ.get("wall_elapsed_sec")),
                    summ.get("timestamp_utc") or _parse_started_at_from_run_id(rid),
                    len(rlist),
                    now_iso,
                ),
            )
            runs_upserted += 1

            # Index summary.json matches & score.json matches by filename
            summ_by_file: dict[str, dict[str, Any]] = {}
            for sm in summ.get("matches") or []:
                rp_s = sm.get("replay_path")
                if rp_s:
                    summ_by_file[Path(str(rp_s)).name] = sm
                elif sm.get("slug"):
                    summ_by_file[f"{sm['slug']}.SC2Replay"] = sm

            score_by_file: dict[str, dict[str, Any]] = {}
            for sc in score_data.get("matches") or []:
                fn = sc.get("file")
                if fn:
                    score_by_file[Path(str(fn)).name] = sc

            for rp in rlist:
                rp_str = str(rp)
                fn = rp.name
                if rp_str in hash_map:
                    sha, mtime, sz = hash_map[rp_str]
                elif rp_str in existing_paths:
                    _, sha, mtime = existing_paths[rp_str]
                    sz = rp.stat().st_size
                else:
                    sha, mtime, sz = _sha256_and_stat(rp)

                replay_id = sha
                sm = summ_by_file.get(fn) or {}
                sc = score_by_file.get(fn) or {}
                fp = _parse_replay_filename(fn)
                our_tel = sm.get("our_telemetry") if isinstance(sm.get("our_telemetry"), dict) else {}

                bot = sc.get("our_bot") or sm.get("bot1") or fp.get("bot")
                opp = sc.get("opp_bot") or sm.get("bot2") or fp.get("opponent")
                our_race = _norm_race(sc.get("our_race") or sm.get("bot1_race") or our_tel.get("configured_race"))
                actual_race = _norm_race(our_tel.get("actual_race_played")) or (our_race if our_race != "Random" else None)
                opp_race = _norm_race(sc.get("opp_race") or sm.get("bot2_race"))
                matchup = sc.get("matchup")
                if not matchup and our_race and opp_race and our_race != "Random" and opp_race != "Random":
                    matchup = f"{our_race[0]}v{opp_race[0]}"
                map_name = sc.get("map_name") or sm.get("map") or fp.get("map_name")
                match_idx = _safe_int(sc.get("id")) or _safe_int(sm.get("index")) or fp.get("match_index")

                is_sp = 1 if (sc.get("is_selfplay") or _is_selfplay_opp(opp, sc.get("opp_cohort") or sm.get("cohort"))) else 0
                raw_coh = sc.get("opp_cohort") or sm.get("cohort")
                if is_sp:
                    opp_cohort = "selfplay"
                elif raw_coh:
                    opp_cohort = str(raw_coh)
                elif opp in roster_core:
                    opp_cohort = "core"
                else:
                    opp_cohort = "unseen"

                result = _norm_result(sc.get("result") or sm.get("outcome") or sm.get("raw_result"))
                dur_sec = _safe_float(sc.get("duration_sec"))
                if dur_sec is None and sm.get("game_minutes") is not None:
                    dur_sec = round(float(sm["game_minutes"]) * 60.0, 2)
                g_loops = _safe_int(sm.get("game_steps")) or _safe_int(our_tel.get("game_loops"))

                avg_step = _safe_float(sc.get("avg_step_ms")) or _safe_float(our_tel.get("avg_step_ms")) or _safe_float(sm.get("bot1_avg_step_ms"))
                p95_step = _safe_float(sc.get("p95_step_ms")) or _safe_float(sc.get("step_p95")) or _safe_float(our_tel.get("p95_step_ms"))
                max_step = _safe_float(sc.get("max_step_ms")) or _safe_float(sc.get("step_max")) or _safe_float(our_tel.get("max_step_ms"))
                tr_ms = _safe_float(sc.get("avg_translate_ms")) or _safe_float(our_tel.get("avg_translate_ms"))
                tr_p95 = _safe_float(sc.get("tr_p95_ms"))

                opp_crash = bool(sc.get("opp_early_crash") or sc.get("opp_fault") or sc.get("opp_zero_combat_dc"))
                crashes = sc.get("crashes") or []
                is_clean = 0 if (opp_crash or (isinstance(crashes, list) and len(crashes) > 0)) else 1
                p2_logged = 1 if sc.get("p2_has_logs") else 0

                extra_meta = _extract_score_extra_meta(sc)
                if sm.get("bot2_elo") is not None:
                    extra_meta["opp_elo"] = sm["bot2_elo"]
                meta_json = json.dumps(extra_meta, separators=(",", ":")) if extra_meta else None

                bot_build_ver = (
                    _parse_scbot_build_from_log_file(sm.get("our_log_path"))
                    or summ.get("repo_commit")
                )

                conn.execute(
                    """
                    INSERT INTO matches (
                        replay_id, replay_sha256, replay_mtime, replay_size_bytes,
                        run_id, match_index, replay_path, replay_filename,
                        bot, our_race, actual_race, opponent, opp_race, opp_cohort, matchup, map_name,
                        result, duration_sec, game_loops,
                        killed_val, lost_val, trade_ratio,
                        w4m, w6m, peak_workers, peak_army_val, peak_bases,
                        opp_peak_workers, opp_peak_army_val, opp_bases,
                        sup_blk_pct, opp_sup_blk_pct,
                        avg_step_ms, p95_step_ms, max_step_ms, tr_ms, tr_p95_ms,
                        action_rejects, is_clean, is_selfplay, p2_logged,
                        source_type, bot_build_version, score_meta_json
                    ) VALUES (
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?
                    )
                    ON CONFLICT(replay_id) DO UPDATE SET
                        replay_mtime=excluded.replay_mtime,
                        replay_size_bytes=excluded.replay_size_bytes,
                        run_id=excluded.run_id,
                        match_index=COALESCE(excluded.match_index, matches.match_index),
                        bot=COALESCE(excluded.bot, matches.bot),
                        our_race=COALESCE(excluded.our_race, matches.our_race),
                        actual_race=COALESCE(matches.actual_race, excluded.actual_race),
                        opponent=COALESCE(excluded.opponent, matches.opponent),
                        opp_race=COALESCE(excluded.opp_race, matches.opp_race),
                        opp_cohort=COALESCE(excluded.opp_cohort, matches.opp_cohort),
                        matchup=COALESCE(excluded.matchup, matches.matchup),
                        map_name=COALESCE(excluded.map_name, matches.map_name),
                        result=COALESCE(excluded.result, matches.result),
                        duration_sec=COALESCE(excluded.duration_sec, matches.duration_sec),
                        game_loops=COALESCE(excluded.game_loops, matches.game_loops),
                        killed_val=COALESCE(excluded.killed_val, matches.killed_val),
                        lost_val=COALESCE(excluded.lost_val, matches.lost_val),
                        trade_ratio=COALESCE(excluded.trade_ratio, matches.trade_ratio),
                        w4m=COALESCE(excluded.w4m, matches.w4m),
                        w6m=COALESCE(excluded.w6m, matches.w6m),
                        peak_workers=COALESCE(excluded.peak_workers, matches.peak_workers),
                        peak_army_val=COALESCE(excluded.peak_army_val, matches.peak_army_val),
                        peak_bases=COALESCE(excluded.peak_bases, matches.peak_bases),
                        opp_peak_workers=COALESCE(excluded.opp_peak_workers, matches.opp_peak_workers),
                        opp_peak_army_val=COALESCE(excluded.opp_peak_army_val, matches.opp_peak_army_val),
                        opp_bases=COALESCE(excluded.opp_bases, matches.opp_bases),
                        sup_blk_pct=COALESCE(excluded.sup_blk_pct, matches.sup_blk_pct),
                        opp_sup_blk_pct=COALESCE(excluded.opp_sup_blk_pct, matches.opp_sup_blk_pct),
                        avg_step_ms=COALESCE(excluded.avg_step_ms, matches.avg_step_ms),
                        p95_step_ms=COALESCE(excluded.p95_step_ms, matches.p95_step_ms),
                        max_step_ms=COALESCE(excluded.max_step_ms, matches.max_step_ms),
                        tr_ms=COALESCE(excluded.tr_ms, matches.tr_ms),
                        tr_p95_ms=COALESCE(excluded.tr_p95_ms, matches.tr_p95_ms),
                        action_rejects=COALESCE(excluded.action_rejects, matches.action_rejects),
                        is_clean=excluded.is_clean,
                        is_selfplay=excluded.is_selfplay,
                        p2_logged=MAX(matches.p2_logged, excluded.p2_logged),
                        source_type=COALESCE(excluded.source_type, matches.source_type),
                        bot_build_version=COALESCE(excluded.bot_build_version, matches.bot_build_version),
                        score_meta_json=COALESCE(excluded.score_meta_json, matches.score_meta_json)
                    """,
                    (
                        replay_id, sha, mtime, sz,
                        rid, match_idx, rp_str, fn,
                        bot, our_race, actual_race, opp, opp_race, opp_cohort, matchup, map_name,
                        result, dur_sec, g_loops,
                        _safe_float(sc.get("killed_val")),
                        _safe_float(sc.get("lost_val")),
                        _safe_float(sc.get("trade_ratio")),
                        _safe_int(sc.get("our_w4")),
                        _safe_int(sc.get("our_w6")),
                        _safe_int(sc.get("our_peak_workers") or our_tel.get("peak_workers")),
                        _safe_float(sc.get("our_peak_army")),
                        _safe_int(sc.get("our_bases") or our_tel.get("peak_bases")),
                        _safe_int(sc.get("opp_peak_workers")),
                        _safe_float(sc.get("opp_peak_army")),
                        _safe_int(sc.get("opp_bases")),
                        _safe_float(sc.get("supply_block_pct")),
                        _safe_float(sc.get("opp_supply_block_pct")),
                        avg_step, p95_step, max_step, tr_ms, tr_p95,
                        _safe_int(sc.get("action_rejects")),
                        is_clean, is_sp, p2_logged,
                        "local_arena", bot_build_ver, meta_json,
                    ),
                )
                matches_upserted += 1

                # Sync anomalies if score.json is available for this match
                if sc:
                    anomalies_upserted += _sync_match_anomalies(conn, replay_id, sc)

    elapsed = time.perf_counter() - t0
    print(
        f"ingest-runs OK: runs={runs_upserted}, matches={matches_upserted}, "
        f"hashed_new={len(to_hash)}, anomalies={anomalies_upserted}, "
        f"score_jsons_linked={len(score_by_run)}, elapsed={elapsed:.2f}s -> {db_path}"
    )
    return 0


# ---------------------------------------------------------------------------
# Subcommand: ingest-prod-aiarena
# ---------------------------------------------------------------------------

def _read_match_log_zip(zip_path: Path) -> tuple[str | None, dict[str, Any]]:
    """Read [SCBOT_BUILD] from stderr.log and telemetry JSON from stdout.log inside *_match_log.zip."""
    build_ver: str | None = None
    tel: dict[str, Any] = {}
    if not zip_path.is_file():
        return build_ver, tel
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            names = zf.namelist()
            for n in names:
                low = n.lower()
                if low.endswith("stderr.log"):
                    raw = zf.read(n)[:32768].decode("utf-8", errors="ignore")
                    build_ver = _parse_scbot_build_from_text(raw) or build_ver
                elif low.endswith("stdout.log"):
                    raw = zf.read(n).decode("utf-8", errors="ignore")
                    if build_ver is None:
                        build_ver = _parse_scbot_build_from_text(raw[:32768])
                    for line in reversed(raw.splitlines()):
                        ls = line.strip()
                        if ls.startswith("{") and ls.endswith("}"):
                            try:
                                obj = json.loads(ls)
                                if isinstance(obj, dict):
                                    tel = obj
                                    break
                            except Exception:
                                pass
    except Exception:
        pass
    return build_ver, tel


def _parse_prod_replay_filename(filename: str) -> dict[str, Any]:
    """Parse `{mid}_{our_bot}_vs_{opp_bot}.SC2Replay` or `{mid}_...`."""
    stem = Path(filename).stem
    out: dict[str, Any] = {}
    m = re.match(r"^(\d+)_(.+?)_vs_(.+)$", stem)
    if m:
        out["match_id"] = int(m.group(1))
        out["bot"] = m.group(2)
        out["opponent"] = m.group(3)
        return out
    m2 = re.match(r"^(\d+)_(.+)$", stem)
    if m2:
        out["match_id"] = int(m2.group(1))
    return out


def cmd_ingest_prod_aiarena(args: argparse.Namespace) -> int:
    t0 = time.perf_counter()
    target_dir = Path(args.dir).resolve()
    if not target_dir.is_dir():
        print(f"Directory not found: {target_dir}", file=sys.stderr)
        return 1

    db_path = Path(args.db)
    repo_dir = Path(args.repo_dir)
    deploy_timeline = _load_deploy_timeline(repo_dir)

    # 0. Optional scorer execution (--score) or explicit --score-json loading
    score_json_path: Path | None = None
    if getattr(args, "score", False):
        out_sj = Path(args.score_out) if getattr(args, "score_out", None) else (target_dir / "prod_score.json")
        t_sc = time.perf_counter()
        score_json_path = _run_score_replay_batch(
            target_dir, out_sj, jobs=min(4, max(1, int(args.jobs))), repo_dir=repo_dir
        )
        print(f"  score-replay-batch OK ({time.perf_counter() - t_sc:.2f}s) -> {score_json_path}")
    elif getattr(args, "score_json", None):
        score_json_path = Path(args.score_json)
        if not score_json_path.is_file():
            print(f"Score JSON not found: {score_json_path}", file=sys.stderr)
            return 1
    else:
        for auto_sj in (target_dir / "prod_score.json", target_dir / "live_score.json"):
            if auto_sj.is_file():
                score_json_path = auto_sj
                break

    score_by_file: dict[str, dict[str, Any]] = {}
    score_by_mid: dict[int, dict[str, Any]] = {}
    if score_json_path and score_json_path.is_file():
        try:
            sdata = json.loads(score_json_path.read_text())
            for sc_item in sdata.get("matches") or []:
                if not isinstance(sc_item, dict):
                    continue
                sfn = sc_item.get("file")
                if sfn:
                    score_by_file[Path(str(sfn)).name] = sc_item
                sid = sc_item.get("id")
                if sid is not None and str(sid).isdigit():
                    score_by_mid[int(sid)] = sc_item
        except Exception as exc:
            print(f"  [WARN] Could not parse score JSON {score_json_path}: {exc}", file=sys.stderr)

    # 1. Load per-match metadata from {mid}_meta.json AND any *_summary.json
    meta_by_mid: dict[int, dict[str, Any]] = {}
    summary_by_mid: dict[int, dict[str, Any]] = {}
    summary_bots: dict[str, dict[str, Any]] = {}

    for mp in sorted(target_dir.glob("*_meta.json")):
        try:
            d = json.loads(mp.read_text())
            if isinstance(d, dict) and d.get("match_id") is not None:
                meta_by_mid[int(d["match_id"])] = d
            elif isinstance(d, list):
                for item in d:
                    if isinstance(item, dict) and item.get("match_id") is not None:
                        meta_by_mid[int(item["match_id"])] = item
        except Exception:
            continue

    for sp in sorted(target_dir.glob("*summary*.json")):
        try:
            d = json.loads(sp.read_text())
            if not isinstance(d, dict):
                continue
            if isinstance(d.get("bots"), dict):
                for bname, binfo in d["bots"].items():
                    if isinstance(binfo, dict):
                        summary_bots[str(bname)] = binfo
            for sm in d.get("matches") or []:
                if isinstance(sm, dict) and sm.get("match_id") is not None:
                    summary_by_mid[int(sm["match_id"])] = sm
        except Exception:
            continue

    # 2. Discover .SC2Replay files in dir (or dir/replays)
    replays = sorted(target_dir.glob("*.SC2Replay"))
    if not replays and (target_dir / "replays").is_dir():
        replays = sorted((target_dir / "replays").glob("*.SC2Replay"))
    if not replays:
        print(f"No .SC2Replay files found in {target_dir}", file=sys.stderr)
        return 1

    conn = open_db(db_path)
    existing_paths: dict[str, tuple[str, str, float | None]] = {}
    for row in conn.execute("SELECT replay_path, replay_id, replay_sha256, replay_mtime FROM matches"):
        existing_paths[row["replay_path"]] = (row["replay_id"], row["replay_sha256"], row["replay_mtime"])

    to_hash: list[str] = []
    for rp in replays:
        rp_str = str(rp)
        st_mtime = rp.stat().st_mtime
        prev = existing_paths.get(rp_str)
        if prev is None or prev[2] is None or abs(prev[2] - st_mtime) > 1e-3:
            to_hash.append(rp_str)

    hash_map: dict[str, tuple[str, float, int]] = {}
    if to_hash:
        workers = max(1, min(int(args.jobs), len(to_hash)))
        with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as ex:
            for rp_str, sha, mtime, sz in ex.map(_hash_worker, to_hash, chunksize=8):
                hash_map[rp_str] = (sha, mtime, sz)

    run_id = args.run_id or f"prod_aiarena_{target_dir.name}"
    tag = args.tag or target_dir.name
    now_iso = _now_utc_iso()

    # Determine earliest match timestamp for runs.started_at
    ts_candidates: list[str] = []
    for m in meta_by_mid.values():
        ts = m.get("created") or m.get("started")
        if ts:
            ts_candidates.append(str(ts))
    for m in summary_by_mid.values():
        if m.get("started"):
            ts_candidates.append(str(m["started"]))
    started_at = min(ts_candidates) if ts_candidates else now_iso

    matches_upserted = 0
    anomalies_upserted = 0
    scored_linked = 0
    builds_seen: Counter[str] = Counter()

    with conn:
        conn.execute(
            """
            INSERT INTO runs (
                run_id, tag, git_rev, run_dir, score_json_path, mothman_mode,
                image, concurrency, wall_elapsed_sec, started_at, total_replays, ingested_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(run_id) DO UPDATE SET
                tag=COALESCE(excluded.tag, runs.tag),
                run_dir=COALESCE(excluded.run_dir, runs.run_dir),
                score_json_path=COALESCE(excluded.score_json_path, runs.score_json_path),
                mothman_mode=COALESCE(excluded.mothman_mode, runs.mothman_mode),
                started_at=COALESCE(excluded.started_at, runs.started_at),
                total_replays=excluded.total_replays,
                ingested_at=excluded.ingested_at
            """,
            (
                run_id,
                tag,
                None,
                str(target_dir),
                str(score_json_path) if score_json_path else None,
                "prod_aiarena",
                "aiarena.net",
                None,
                None,
                started_at,
                len(replays),
                now_iso,
            ),
        )

        for idx, rp in enumerate(replays, start=1):
            rp_str = str(rp)
            fn = rp.name
            if rp_str in hash_map:
                sha, mtime, sz = hash_map[rp_str]
            elif rp_str in existing_paths:
                _, sha, mtime = existing_paths[rp_str]
                sz = rp.stat().st_size
            else:
                sha, mtime, sz = _sha256_and_stat(rp)

            replay_id = sha
            fp = _parse_prod_replay_filename(fn)
            mid = fp.get("match_id")
            pm = meta_by_mid.get(mid) if mid is not None else None
            sm = summary_by_mid.get(mid) if mid is not None else None
            sc = score_by_file.get(fn) or (score_by_mid.get(mid) if mid is not None else None)
            pm = pm or {}
            sm = sm or {}
            sc = sc or {}
            if sc:
                scored_linked += 1

            # Inspect optional {mid}_match_log.zip
            log_build_ver: str | None = None
            tel: dict[str, Any] = {}
            if mid is not None:
                log_zip = target_dir / f"{mid}_match_log.zip"
                if log_zip.is_file():
                    log_build_ver, tel = _read_match_log_zip(log_zip)

            bot = pm.get("our_bot_name") or pm.get("our_bot") or sm.get("bot") or sc.get("our_bot") or tel.get("bot_name") or fp.get("bot")
            opp = pm.get("opp_bot_name") or pm.get("opp_bot") or sm.get("opp") or sc.get("opp_bot") or fp.get("opponent")
            our_race = _norm_race(
                sm.get("bot_race") or sc.get("our_race") or tel.get("configured_race") or _infer_race_from_bot_name(bot)
            )
            actual_race = _norm_race(tel.get("actual_race_played") or sc.get("our_race")) or (
                our_race if our_race != "Random" else None
            )
            opp_race = _norm_race(pm.get("opp_race") or sm.get("opp_race") or sc.get("opp_race") or _infer_race_from_bot_name(opp))
            matchup = sc.get("matchup")
            if not matchup and actual_race and opp_race and actual_race != "Random" and opp_race != "Random":
                matchup = f"{actual_race[0]}v{opp_race[0]}"

            map_name = (
                pm.get("map_name")
                or sm.get("map")
                or sc.get("map_name")
                or _extract_map_from_aiarena_url(pm.get("replay_url"))
                or _extract_map_from_aiarena_url(sm.get("replay_file"))
                or tel.get("map")
            )

            pnum = _safe_int(pm.get("our_participant_number"))
            pnum_explicit = pnum if pnum in (1, 2) else None
            our_pid = pnum_explicit or 1

            result = _norm_result(pm.get("result") or sm.get("result") or sc.get("result") or tel.get("result"))
            g_loops = _safe_int(pm.get("game_steps")) or _safe_int(sm.get("game_steps")) or _safe_int(tel.get("game_loops"))
            dur_sec = _safe_float(sc.get("duration_sec")) or _parse_duration_hms(pm.get("game_time_fmt") or sm.get("duration"))
            if dur_sec is None and g_loops and g_loops > 0:
                dur_sec = round(g_loops / GAME_LOOPS_PER_SEC, 2)

            avg_step = _safe_float(pm.get("avg_step_time_ms") or pm.get("avg_step_ms"))
            if avg_step == 0.0:
                avg_step = None
            avg_step = avg_step or _safe_float(sm.get("avg_step_ms")) or _safe_float(sc.get("avg_step_ms")) or _safe_float(tel.get("avg_step_ms"))
            p95_step = _safe_float(sc.get("p95_step_ms")) or _safe_float(sc.get("step_p95")) or _safe_float(tel.get("p95_step_ms"))
            max_step = _safe_float(sc.get("max_step_ms")) or _safe_float(sc.get("step_max")) or _safe_float(tel.get("max_step_ms"))
            tr_ms = _safe_float(sc.get("avg_translate_ms")) or _safe_float(tel.get("avg_translate_ms"))
            tr_p95 = _safe_float(sc.get("tr_p95_ms"))

            bot_elo = _safe_int(pm.get("resultant_elo"))
            if bot_elo is not None and bot_elo <= 0:
                bot_elo = None
            bot_elo_snapshot = False
            if bot_elo is None and bot and bot in summary_bots:
                cand_elo = _safe_int(summary_bots[bot].get("elo"))
                if cand_elo and cand_elo > 0:
                    bot_elo = cand_elo
                    bot_elo_snapshot = True
            opp_elo = _safe_int(
                pm.get("opp_resultant_elo") or pm.get("opp_elo") or sm.get("opp_elo")
            )
            if opp_elo is not None and opp_elo <= 0:
                opp_elo = None

            created_iso = pm.get("created") or pm.get("started") or sm.get("started")
            if not created_iso:
                created_iso = dt.datetime.fromtimestamp(mtime, tz=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

            build_ver = log_build_ver or _resolve_deploy_commit(str(created_iso), deploy_timeline)
            builds_seen[build_ver or "(unknown)"] += 1

            is_sp = 1 if _is_selfplay_opp(opp) else 0
            opp_cohort = "selfplay" if is_sp else "prod_aiarena"

            cause = (pm.get("result_cause") or sm.get("result_cause") or "").lower()
            opp_crash = bool(sc.get("opp_early_crash") or sc.get("opp_fault") or sc.get("opp_zero_combat_dc"))
            crashes = sc.get("crashes") or []
            is_clean = 0 if (
                "crash" in cause or "error" in cause or "timeout" in cause
                or opp_crash or (isinstance(crashes, list) and len(crashes) > 0)
            ) else 1
            p2_logged = 1 if sc.get("p2_has_logs") else 0

            extra_meta: dict[str, Any] = _extract_score_extra_meta(sc)
            extra_meta.update({
                "created": created_iso,
                "result_cause": pm.get("result_cause") or sm.get("result_cause"),
                "elo_change": pm.get("elo_change") if "elo_change" in pm else sm.get("elo_change"),
                "result_type": pm.get("result_type"),
                "our_bot_id": pm.get("our_bot_id"),
                "opp_bot_id": pm.get("opp_bot_id") or sm.get("opp_id"),
                "opp_div": sm.get("opp_div"),
            })
            if bot_elo_snapshot:
                extra_meta["bot_elo_is_snapshot"] = True
            if sc:
                extra_meta["scored"] = True
            for tk in ("final_posture", "opponent_id", "commands_sent", "status", "engine"):
                if tk in tel and tel[tk] is not None:
                    extra_meta[tk] = tel[tk]
            extra_meta = {k: v for k, v in extra_meta.items() if v is not None and v != ""}
            meta_json = json.dumps(extra_meta, separators=(",", ":")) if extra_meta else None

            conn.execute(
                """
                INSERT INTO matches (
                    replay_id, replay_sha256, replay_mtime, replay_size_bytes,
                    run_id, match_index, replay_path, replay_filename,
                    bot, our_race, actual_race, opponent, opp_race, opp_cohort, matchup, map_name,
                    our_player_id, result, duration_sec, game_loops,
                    killed_val, lost_val, trade_ratio,
                    w4m, w6m, peak_workers, peak_army_val, peak_bases,
                    opp_peak_workers, opp_peak_army_val, opp_bases,
                    sup_blk_pct, opp_sup_blk_pct,
                    avg_step_ms, p95_step_ms, max_step_ms, tr_ms, tr_p95_ms,
                    action_rejects, is_clean, is_selfplay, p2_logged,
                    source_type, bot_build_version,
                    aiarena_match_id, aiarena_bot_elo, aiarena_opp_elo,
                    score_meta_json
                ) VALUES (
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                    ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                )
                ON CONFLICT(replay_id) DO UPDATE SET
                    replay_mtime=excluded.replay_mtime,
                    replay_size_bytes=excluded.replay_size_bytes,
                    run_id=excluded.run_id,
                    match_index=COALESCE(excluded.match_index, matches.match_index),
                    bot=COALESCE(excluded.bot, matches.bot),
                    our_race=COALESCE(excluded.our_race, matches.our_race),
                    actual_race=COALESCE(matches.actual_race, excluded.actual_race),
                    opponent=COALESCE(excluded.opponent, matches.opponent),
                    opp_race=COALESCE(excluded.opp_race, matches.opp_race),
                    opp_cohort=COALESCE(excluded.opp_cohort, matches.opp_cohort),
                    matchup=COALESCE(excluded.matchup, matches.matchup),
                    map_name=COALESCE(excluded.map_name, matches.map_name),
                    our_player_id=CASE
                        WHEN ? IN (1, 2) THEN ?
                        ELSE matches.our_player_id
                    END,
                    result=COALESCE(excluded.result, matches.result),
                    duration_sec=COALESCE(excluded.duration_sec, matches.duration_sec),
                    game_loops=COALESCE(excluded.game_loops, matches.game_loops),
                    killed_val=COALESCE(excluded.killed_val, matches.killed_val),
                    lost_val=COALESCE(excluded.lost_val, matches.lost_val),
                    trade_ratio=COALESCE(excluded.trade_ratio, matches.trade_ratio),
                    w4m=COALESCE(excluded.w4m, matches.w4m),
                    w6m=COALESCE(excluded.w6m, matches.w6m),
                    peak_workers=COALESCE(excluded.peak_workers, matches.peak_workers),
                    peak_army_val=COALESCE(excluded.peak_army_val, matches.peak_army_val),
                    peak_bases=COALESCE(excluded.peak_bases, matches.peak_bases),
                    opp_peak_workers=COALESCE(excluded.opp_peak_workers, matches.opp_peak_workers),
                    opp_peak_army_val=COALESCE(excluded.opp_peak_army_val, matches.opp_peak_army_val),
                    opp_bases=COALESCE(excluded.opp_bases, matches.opp_bases),
                    sup_blk_pct=COALESCE(excluded.sup_blk_pct, matches.sup_blk_pct),
                    opp_sup_blk_pct=COALESCE(excluded.opp_sup_blk_pct, matches.opp_sup_blk_pct),
                    avg_step_ms=COALESCE(excluded.avg_step_ms, matches.avg_step_ms),
                    p95_step_ms=COALESCE(excluded.p95_step_ms, matches.p95_step_ms),
                    max_step_ms=COALESCE(excluded.max_step_ms, matches.max_step_ms),
                    tr_ms=COALESCE(excluded.tr_ms, matches.tr_ms),
                    tr_p95_ms=COALESCE(excluded.tr_p95_ms, matches.tr_p95_ms),
                    action_rejects=COALESCE(excluded.action_rejects, matches.action_rejects),
                    is_clean=excluded.is_clean,
                    is_selfplay=excluded.is_selfplay,
                    p2_logged=MAX(matches.p2_logged, excluded.p2_logged),
                    source_type='prod_aiarena',
                    bot_build_version=COALESCE(
                        CASE
                            WHEN matches.bot_build_version IS NOT NULL AND matches.bot_build_version NOT LIKE 'deploy:%'
                            THEN matches.bot_build_version
                            ELSE excluded.bot_build_version
                        END,
                        matches.bot_build_version
                    ),
                    aiarena_match_id=COALESCE(excluded.aiarena_match_id, matches.aiarena_match_id),
                    aiarena_bot_elo=COALESCE(excluded.aiarena_bot_elo, matches.aiarena_bot_elo),
                    aiarena_opp_elo=COALESCE(excluded.aiarena_opp_elo, matches.aiarena_opp_elo),
                    score_meta_json=COALESCE(excluded.score_meta_json, matches.score_meta_json)
                """,
                (
                    replay_id, sha, mtime, sz,
                    run_id, idx, rp_str, fn,
                    bot, our_race, actual_race, opp, opp_race, opp_cohort, matchup, map_name,
                    our_pid, result, dur_sec, g_loops,
                    _safe_float(sc.get("killed_val")),
                    _safe_float(sc.get("lost_val")),
                    _safe_float(sc.get("trade_ratio")),
                    _safe_int(sc.get("our_w4")),
                    _safe_int(sc.get("our_w6")),
                    _safe_int(sc.get("our_peak_workers") or tel.get("peak_workers")),
                    _safe_float(sc.get("our_peak_army")),
                    _safe_int(sc.get("our_bases") or tel.get("peak_bases")),
                    _safe_int(sc.get("opp_peak_workers")),
                    _safe_float(sc.get("opp_peak_army")),
                    _safe_int(sc.get("opp_bases")),
                    _safe_float(sc.get("supply_block_pct")),
                    _safe_float(sc.get("opp_supply_block_pct")),
                    avg_step, p95_step, max_step, tr_ms, tr_p95,
                    _safe_int(sc.get("action_rejects")),
                    is_clean, is_sp, p2_logged,
                    "prod_aiarena", build_ver,
                    mid, bot_elo, opp_elo,
                    meta_json,
                    pnum_explicit, pnum_explicit,
                ),
            )
            matches_upserted += 1
            if sc:
                anomalies_upserted += _sync_match_anomalies(conn, replay_id, sc)

    elapsed = time.perf_counter() - t0
    b_str = ", ".join(f"{k}:{v}" for k, v in builds_seen.most_common(6))
    print(
        f"ingest-prod-aiarena OK: run_id={run_id}, matches={matches_upserted}, "
        f"meta_jsons={len(meta_by_mid)}, summary_entries={len(summary_by_mid)}, "
        f"scored={scored_linked}, anomalies={anomalies_upserted}, "
        f"hashed_new={len(to_hash)}, builds=[{b_str}], elapsed={elapsed:.2f}s -> {db_path}"
    )

    if args.extract_raw:
        ext_ns = argparse.Namespace(
            db=str(db_path),
            all=False,
            latest=None,
            run=run_id,
            replay=None,
            include_game_events=False,
            force=False,
            limit=None,
            pylibs_dir=str(args.pylibs_dir),
            jobs=int(args.jobs),
            verbose=bool(args.verbose),
        )
        return cmd_extract_raw(ext_ns)
    return 0


# ---------------------------------------------------------------------------
# Subcommand: extract-raw
# ---------------------------------------------------------------------------

def _extract_worker_tuple(
    item: tuple[str, str, bool, str | None, str, int | None]
) -> dict[str, Any]:
    return extract_single_replay(*item)


def cmd_extract_raw(args: argparse.Namespace) -> int:
    t0 = time.perf_counter()
    db_path = Path(args.db)
    conn = open_db(db_path)

    clauses: list[str] = []
    params: list[Any] = []

    if args.replay:
        q = args.replay
        clauses.append("(m.replay_path = ? OR m.replay_id = ? OR m.replay_id LIKE ? OR m.replay_filename = ?)")
        params.extend([q, q, f"{q}%", Path(q).name])
    elif args.run:
        clauses.append("(m.run_id = ? OR m.run_id LIKE ?)")
        params.extend([args.run, f"%{args.run}%"])
    elif args.latest is not None:
        n_runs = max(1, int(args.latest))
        top_runs = [
            r["run_id"]
            for r in conn.execute(
                "SELECT run_id FROM runs ORDER BY COALESCE(started_at, run_id) DESC LIMIT ?",
                (n_runs,),
            )
        ]
        if not top_runs:
            print("No runs in DB. Run `ingest-runs` first.")
            return 1
        placeholders = ",".join("?" for _ in top_runs)
        clauses.append(f"m.run_id IN ({placeholders})")
        params.extend(top_runs)
    elif not args.all:
        print("Specify one target: --all, --latest [N], --run <run_id>, or --replay <id|path>.")
        return 2

    if not args.force:
        if args.include_game_events:
            clauses.append("(m.raw_extracted_at IS NULL OR m.game_events_extracted_at IS NULL)")
        else:
            clauses.append("m.raw_extracted_at IS NULL")

    where_sql = ("WHERE " + " AND ".join(clauses)) if clauses else ""
    sql = f"""
        SELECT m.replay_id, m.replay_path, m.bot, m.our_player_id, m.source_type
        FROM matches m
        {where_sql}
        ORDER BY m.run_id DESC, m.match_index ASC
    """
    rows = conn.execute(sql, params).fetchall()
    if args.limit:
        rows = rows[: int(args.limit)]

    if not rows:
        print(f"extract-raw: 0 replays need extraction (already up-to-date; pass --force to re-extract).")
        return 0

    work_items = [
        (
            r["replay_path"],
            r["replay_id"],
            bool(args.include_game_events),
            r["bot"],
            str(args.pylibs_dir),
            r["our_player_id"] if (r["source_type"] == "prod_aiarena" and r["our_player_id"] in (1, 2)) else None,
        )
        for r in rows
        if Path(r["replay_path"]).is_file()
    ]
    missing = len(rows) - len(work_items)
    workers = max(1, min(int(args.jobs), len(work_items)))

    ok_cnt = 0
    err_cnt = 0
    min_cnt = 0
    ev_cnt = 0
    tot_cnt = 0
    cmd_cnt = 0
    now_iso = _now_utc_iso()

    # Process in chunks so memory stays modest even across 1,654 replays
    chunk_sz = max(workers * 4, 48)
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as ex:
        for i in range(0, len(work_items), chunk_sz):
            batch = work_items[i : i + chunk_sz]
            results = list(ex.map(_extract_worker_tuple, batch, chunksize=2))
            with conn:
                for res in results:
                    if not res.get("ok"):
                        err_cnt += 1
                        if args.verbose:
                            print(f"  ERR {res.get('replay_id','')[:12]}: {res.get('error')}", file=sys.stderr)
                        continue
                    ok_cnt += 1
                    rid = res["replay_id"]
                    meta = res["meta"]
                    conn.execute(
                        """
                        UPDATE matches SET
                            actual_race = COALESCE(?, actual_race),
                            our_race = COALESCE(our_race, ?),
                            opp_race = COALESCE(opp_race, ?),
                            matchup = COALESCE(matchup, ?),
                            map_name = COALESCE(map_name, ?),
                            our_player_id = ?,
                            our_spawn_corner = ?,
                            our_start_x = ?,
                            our_start_y = ?,
                            opp_start_x = ?,
                            opp_start_y = ?,
                            game_loops = COALESCE(?, game_loops),
                            duration_sec = COALESCE(duration_sec, ?),
                            result = COALESCE(result, ?),
                            w4m = COALESCE(w4m, ?),
                            w6m = COALESCE(w6m, ?),
                            peak_workers = COALESCE(peak_workers, ?),
                            peak_army_val = COALESCE(peak_army_val, ?),
                            peak_bases = COALESCE(peak_bases, ?),
                            opp_peak_workers = COALESCE(opp_peak_workers, ?),
                            opp_peak_army_val = COALESCE(opp_peak_army_val, ?),
                            opp_bases = COALESCE(opp_bases, ?),
                            killed_val = COALESCE(killed_val, ?),
                            lost_val = COALESCE(lost_val, ?),
                            trade_ratio = COALESCE(trade_ratio, ?),
                            replay_chat_tags = COALESCE(?, replay_chat_tags),
                            bot_build_version = COALESCE(?, bot_build_version),
                            raw_extracted_at = ?,
                            game_events_extracted_at = CASE WHEN ? THEN ? ELSE game_events_extracted_at END
                        WHERE replay_id = ?
                        """,
                        (
                            meta["actual_race"],
                            meta["actual_race"],
                            meta["opp_race"],
                            meta["raw_matchup"],
                            meta["map_title"],
                            meta["our_player_id"],
                            meta["our_spawn_corner"],
                            meta["our_start_x"],
                            meta["our_start_y"],
                            meta["opp_start_x"],
                            meta["opp_start_y"],
                            meta["game_loops"],
                            meta["duration_sec"],
                            meta["raw_result"],
                            meta["raw_w4"],
                            meta["raw_w6"],
                            meta["raw_pk_w"],
                            meta["raw_pk_a"],
                            meta["raw_pk_b"],
                            meta["raw_opp_pk_w"],
                            meta["raw_opp_pk_a"],
                            meta["raw_opp_pk_b"],
                            meta["raw_killed"],
                            meta["raw_lost"],
                            meta["raw_trade"],
                            meta["replay_chat_tags"],
                            meta["chat_build_version"],
                            now_iso,
                            1 if res["include_game_events"] else 0,
                            now_iso,
                            rid,
                        ),
                    )
                    conn.execute("DELETE FROM match_minute_stats WHERE replay_id = ?", (rid,))
                    if res["minute_rows"]:
                        conn.executemany(
                            """
                            INSERT INTO match_minute_stats (
                                replay_id, player_id, minute, game_loop,
                                minerals_current, vespene_current, minerals_rate, vespene_rate,
                                workers_active, army_value_minerals, army_value_vespene, army_value_total,
                                food_used, food_made,
                                lost_minerals, lost_vespene, lost_total,
                                killed_minerals, killed_vespene, killed_total, bases_alive
                            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                            """,
                            res["minute_rows"],
                        )
                        min_cnt += len(res["minute_rows"])

                    conn.execute("DELETE FROM match_build_events WHERE replay_id = ?", (rid,))
                    if res["build_events"]:
                        conn.executemany(
                            """
                            INSERT INTO match_build_events (
                                replay_id, player_id, game_loop, sec, event_type, unit_type, x, y, unit_tag
                            ) VALUES (?,?,?,?,?,?,?,?,?)
                            """,
                            res["build_events"],
                        )
                        ev_cnt += len(res["build_events"])

                    conn.execute("DELETE FROM match_unit_totals WHERE replay_id = ?", (rid,))
                    if res["unit_total_rows"]:
                        conn.executemany(
                            """
                            INSERT INTO match_unit_totals (
                                replay_id, player_id, unit_type, created, died, first_sec, peak_alive
                            ) VALUES (?,?,?,?,?,?,?)
                            """,
                            res["unit_total_rows"],
                        )
                        tot_cnt += len(res["unit_total_rows"])

                    if res["include_game_events"]:
                        conn.execute("DELETE FROM match_cmd_summary WHERE replay_id = ?", (rid,))
                        if res["cmd_rows"]:
                            conn.executemany(
                                """
                                INSERT INTO match_cmd_summary (
                                    replay_id, user_id, minute, cmd_count, selection_count,
                                    camera_count, apm, top_abilities_json
                                ) VALUES (?,?,?,?,?,?,?,?)
                                """,
                                res["cmd_rows"],
                            )
                            cmd_cnt += len(res["cmd_rows"])

    elapsed = time.perf_counter() - t0
    rate = ok_cnt / max(0.001, elapsed)
    print(
        f"extract-raw OK: extracted={ok_cnt}/{len(work_items)} (err={err_cnt}, missing={missing}) "
        f"in {elapsed:.2f}s ({rate:.1f} replays/s, -j {workers}) | "
        f"minute_stats={min_cnt:,}, build_events={ev_cnt:,}, unit_totals={tot_cnt:,}, cmd_summary={cmd_cnt:,}"
    )
    return 0 if err_cnt == 0 else 1


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def _print_table(headers: list[str], rows: list[list[Any]]) -> None:
    str_rows = [["" if v is None else str(v) for v in r] for r in rows]
    widths = [len(h) for h in headers]
    for r in str_rows:
        for i, cell in enumerate(r):
            if len(cell) > widths[i]:
                widths[i] = len(cell)
    fmt = " | ".join(f"{{:<{w}}}" for w in widths)
    sep = "-+-".join("-" * w for w in widths)
    print(fmt.format(*headers))
    print(sep)
    for r in str_rows:
        print(fmt.format(*r))


# ---------------------------------------------------------------------------
# Subcommand: query
# ---------------------------------------------------------------------------

def cmd_query(args: argparse.Namespace) -> int:
    sql = Path(args.sql_file).read_text() if args.sql_file else args.sql
    if not sql or not sql.strip():
        print("Provide SQL string or --sql-file.", file=sys.stderr)
        return 2
    conn = open_db(Path(args.db), readonly=True)
    cur = conn.execute(sql)
    cols = [d[0] for d in (cur.description or [])]
    rows = cur.fetchall()
    if args.format == "json":
        print(json.dumps([dict(zip(cols, r)) for r in rows], indent=2))
    elif args.format == "csv":
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(cols)
        for r in rows:
            w.writerow(list(r))
        sys.stdout.write(buf.getvalue())
    else:
        if not cols:
            print("(no result columns)")
        else:
            _print_table(cols, [list(r) for r in rows])
            print(f"\n({len(rows)} rows)")
    return 0


# ---------------------------------------------------------------------------
# Subcommand: stats
# ---------------------------------------------------------------------------

def cmd_stats(args: argparse.Namespace) -> int:
    db_path = Path(args.db)
    if not db_path.exists():
        print(f"DB not found at {db_path}. Run `ingest-runs` first.", file=sys.stderr)
        return 1
    conn = open_db(db_path, readonly=True)
    size_mb = db_path.stat().st_size / (1024 * 1024)
    wal_path = Path(str(db_path) + "-wal")
    wal_mb = (wal_path.stat().st_size / (1024 * 1024)) if wal_path.exists() else 0.0

    tables = [
        "runs", "matches", "match_anomalies", "match_minute_stats",
        "match_build_events", "match_unit_totals", "match_cmd_summary",
    ]
    counts = {t: conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in tables}
    raw_done = conn.execute("SELECT COUNT(*) FROM matches WHERE raw_extracted_at IS NOT NULL").fetchone()[0]
    ge_done = conn.execute("SELECT COUNT(*) FROM matches WHERE game_events_extracted_at IS NOT NULL").fetchone()[0]
    span = conn.execute("SELECT MIN(started_at), MAX(started_at) FROM runs").fetchone()

    print(f"Database: {db_path} ({size_mb:.2f} MiB, WAL {wal_mb:.2f} MiB)")
    print(f"Run span: {span[0]} .. {span[1]}")
    print(
        f"Coverage: raw_tracker={raw_done}/{counts['matches']} "
        f"({(100.0 * raw_done / max(1, counts['matches'])):.1f}%), "
        f"game_events={ge_done}/{counts['matches']}"
    )
    print("\nTable Row Counts:")
    _print_table(["table", "rows"], [[t, f"{counts[t]:,}"] for t in tables])

    print("\nMatches by Source Type:")
    src_rows = conn.execute(
        """
        SELECT COALESCE(source_type, 'local_arena') AS source_type,
               COUNT(*) AS n,
               SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) AS w,
               SUM(CASE WHEN result='loss' THEN 1 ELSE 0 END) AS l,
               SUM(CASE WHEN result='tie' THEN 1 ELSE 0 END) AS t,
               ROUND(100.0 * SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) / MAX(1, COUNT(*)), 1) AS wr_pct
        FROM matches
        GROUP BY source_type
        ORDER BY n DESC
        """
    ).fetchall()
    _print_table(["source_type", "n", "W", "L", "T", "WR%"], [list(r) for r in src_rows])

    print("\nMatches by Cohort:")
    coh_rows = conn.execute(
        """
        SELECT COALESCE(opp_cohort, '(none)') AS cohort,
               COUNT(*) AS n,
               SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) AS w,
               SUM(CASE WHEN result='loss' THEN 1 ELSE 0 END) AS l,
               SUM(CASE WHEN result='tie' THEN 1 ELSE 0 END) AS t,
               ROUND(100.0 * SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) / MAX(1, COUNT(*)), 1) AS wr_pct
        FROM matches
        GROUP BY cohort
        ORDER BY n DESC
        """
    ).fetchall()
    _print_table(["cohort", "n", "W", "L", "T", "WR%"], [list(r) for r in coh_rows])

    b_rows = conn.execute(
        """
        SELECT COALESCE(bot_build_version, '(unknown)') AS build_ver,
               COALESCE(source_type, 'local_arena') AS src,
               COUNT(*) AS n,
               SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) AS w,
               SUM(CASE WHEN result='loss' THEN 1 ELSE 0 END) AS l,
               SUM(CASE WHEN result='tie' THEN 1 ELSE 0 END) AS t,
               ROUND(100.0 * SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) / MAX(1, COUNT(*)), 1) AS wr_pct
        FROM matches
        GROUP BY build_ver, src
        ORDER BY n DESC
        LIMIT 12
        """
    ).fetchall()
    if b_rows:
        print("\nTop Build Versions:")
        _print_table(["bot_build_version", "source", "n", "W", "L", "T", "WR%"], [list(r) for r in b_rows])
    return 0


# ---------------------------------------------------------------------------
# Subcommand: replay-dump
# ---------------------------------------------------------------------------

def cmd_replay_dump(args: argparse.Namespace) -> int:
    conn = open_db(Path(args.db), readonly=True)
    target = args.target
    row = conn.execute(
        """
        SELECT m.*, r.tag AS run_tag, r.git_rev
        FROM matches m
        JOIN runs r ON r.run_id = m.run_id
        WHERE m.replay_id = ? OR m.replay_id LIKE ? OR m.replay_path = ? OR m.replay_filename = ? OR m.replay_path LIKE ?
           OR CAST(m.aiarena_match_id AS TEXT) = ?
        ORDER BY m.run_id DESC
        LIMIT 1
        """,
        (target, f"{target}%", target, Path(target).name, f"%{target}%", target),
    ).fetchone()
    if row is None:
        print(f"Replay not found in DB: {target}", file=sys.stderr)
        return 1

    rid = row["replay_id"]
    print(f"=== REPLAY DUMP: {row['replay_filename']} ===")
    print(f"replay_id : {rid}")
    print(f"run_id    : {row['run_id']} (tag={row['run_tag']}, git={row['git_rev']})")
    print(f"source    : {row['source_type']} | build={row['bot_build_version']}")
    if row["aiarena_match_id"] is not None or row["aiarena_bot_elo"] is not None:
        print(
            f"aiarena   : match=#{row['aiarena_match_id']} | "
            f"bot_elo={row['aiarena_bot_elo']} opp_elo={row['aiarena_opp_elo']}"
        )
    if row["replay_chat_tags"]:
        print(f"chat_tags : {row['replay_chat_tags']}")
    print(f"matchup   : {row['bot']} ({row['actual_race'] or row['our_race']}) vs {row['opponent']} ({row['opp_race']}) [{row['matchup']}, cohort={row['opp_cohort']}]")
    print(f"map/spawn : {row['map_name']} | corner={row['our_spawn_corner']} | our=({row['our_start_x']},{row['our_start_y']}) opp=({row['opp_start_x']},{row['opp_start_y']})")
    print(f"outcome   : {str(row['result']).upper()} in {row['duration_sec']}s ({row['game_loops']} loops) | Trade={row['trade_ratio']}x (K={row['killed_val']} / L={row['lost_val']})")
    print(f"macro     : W@4m={row['w4m']} W@6m={row['w6m']} PkW={row['peak_workers']} PkArmy={row['peak_army_val']} Bases={row['peak_bases']} SB={row['sup_blk_pct']}%")
    print(f"latency   : avg={row['avg_step_ms']}ms p95={row['p95_step_ms']}ms max={row['max_step_ms']}ms tr={row['tr_ms']}ms rej={row['action_rejects']}")

    anoms = conn.execute(
        "SELECT player_side, anomaly_name, detail FROM match_anomalies WHERE replay_id = ? ORDER BY player_side, anomaly_name",
        (rid,),
    ).fetchall()
    if anoms:
        print("\nAnomalies:")
        _print_table(["side", "anomaly", "detail"], [list(a) for a in anoms])

    mstats = conn.execute(
        """
        SELECT a.minute,
               a.workers_active AS p1_w, b.workers_active AS p2_w,
               a.bases_alive AS p1_b, b.bases_alive AS p2_b,
               a.army_value_total AS p1_army, b.army_value_total AS p2_army,
               a.minerals_current || '/' || a.vespene_current AS p1_bank,
               a.minerals_rate || '/' || a.vespene_rate AS p1_rate,
               ROUND(a.food_used,0) || '/' || ROUND(a.food_made,0) AS p1_sup,
               a.killed_total || '/' || a.lost_total AS p1_kl
        FROM match_minute_stats a
        LEFT JOIN match_minute_stats b
          ON b.replay_id = a.replay_id AND b.minute = a.minute AND b.player_id != a.player_id
        WHERE a.replay_id = ? AND a.player_id = ?
        ORDER BY a.minute
        """,
        (rid, row["our_player_id"] or 1),
    ).fetchall()
    if mstats:
        print("\nMinute Economy & Army Timeline (P1 vs P2):")
        _print_table(
            ["min", "W(P1/P2)", "B(P1/P2)", "Army(P1/P2)", "Bank(M/G)", "Rate(M/G)", "Sup", "K/L"],
            [
                [
                    r["minute"],
                    f"{r['p1_w']}/{r['p2_w']}",
                    f"{r['p1_b']}/{r['p2_b']}",
                    f"{r['p1_army']}/{r['p2_army']}",
                    r["p1_bank"],
                    r["p1_rate"],
                    r["p1_sup"],
                    r["p1_kl"],
                ]
                for r in mstats
            ],
        )

    utots = conn.execute(
        """
        SELECT player_id, unit_type, created, died, first_sec, peak_alive
        FROM match_unit_totals
        WHERE replay_id = ? AND unit_type NOT IN ('Larva','Egg','Interceptor','Broodling','CreepTumor','CreepTumorBurrowed','CreepTumorQueen')
        ORDER BY player_id ASC, created DESC
        """,
        (rid,),
    ).fetchall()
    if utots:
        print("\nTop Unit Totals (P1 & P2):")
        p1_u = [r for r in utots if r["player_id"] == (row["our_player_id"] or 1)][:15]
        p2_u = [r for r in utots if r["player_id"] != (row["our_player_id"] or 1)][:15]
        _print_table(
            ["side", "unit_type", "created", "died", "first_sec", "peak_alive"],
            [
                ["P1" if r["player_id"] == (row["our_player_id"] or 1) else "P2", r["unit_type"], r["created"], r["died"], r["first_sec"], r["peak_alive"]]
                for r in (p1_u + p2_u)
            ],
        )

    bevs = conn.execute(
        """
        SELECT sec, event_type, unit_type, x, y
        FROM match_build_events
        WHERE replay_id = ? AND player_id = ? AND event_type IN ('init','born','morph','upgrade')
        ORDER BY game_loop ASC
        LIMIT ?
        """,
        (rid, row["our_player_id"] or 1, int(args.build_limit)),
    ).fetchall()
    if bevs:
        print(f"\nP1 Opening Build/Upgrade Events (first {len(bevs)}):")
        _print_table(
            ["sec", "event", "unit_or_upgrade", "xy"],
            [
                [r["sec"], r["event_type"], r["unit_type"], f"({r['x']},{r['y']})" if r["x"] is not None else "-"]
                for r in bevs
            ],
        )

    cmds = conn.execute(
        """
        SELECT user_id, minute, cmd_count, selection_count, camera_count, apm, top_abilities_json
        FROM match_cmd_summary
        WHERE replay_id = ?
        ORDER BY user_id, minute
        """,
        (rid,),
    ).fetchall()
    if cmds:
        print("\nGame-Event Command Summary (per minute):")
        _print_table(
            ["uid", "min", "cmds", "sels", "cams", "apm", "top_abilities"],
            [list(r) for r in cmds[:30]],
        )
    return 0


# ---------------------------------------------------------------------------
# Subcommand: spawn-bias (+ canonical map x matchup x corner outlier detection)
# ---------------------------------------------------------------------------

def _two_prop_z(w1: int, n1: int, w2: int, n2: int) -> float:
    if n1 <= 0 or n2 <= 0:
        return 0.0
    p1 = w1 / n1
    p2 = w2 / n2
    p_pool = (w1 + w2) / (n1 + n2)
    denom = math.sqrt(max(1e-12, p_pool * (1.0 - p_pool) * (1.0 / n1 + 1.0 / n2)))
    if p_pool <= 0.0 or p_pool >= 1.0:
        return 0.0
    return (p1 - p2) / denom


def _compute_spawn_outliers(
    conn: sqlite3.Connection,
    where_sql: str,
    params: list[Any],
    min_pair_n: int = 5,
    single_run_mode: bool = False,
) -> list[dict[str, Any]]:
    """Detect statistically & practically significant paired corner outliers per map and (map, matchup)."""
    outliers: list[dict[str, Any]] = []

    def _scan(scope: str, group_expr: str) -> None:
        rows = conn.execute(
            f"""
            SELECT {group_expr} AS grp_key,
                   canon_map(map_name) AS map_canon,
                   matchup,
                   our_spawn_corner AS corner,
                   COUNT(*) AS n,
                   SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) AS w,
                   SUM(CASE WHEN result='loss' THEN 1 ELSE 0 END) AS l,
                   SUM(CASE WHEN result='tie' THEN 1 ELSE 0 END) AS t,
                   ROUND(100.0 * SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) / COUNT(*), 1) AS wr_pct,
                   ROUND(AVG(sup_blk_pct), 1) AS sb_pct,
                   ROUND(SUM(COALESCE(killed_val,0)) / MAX(1.0, SUM(COALESCE(lost_val,0))), 2) AS trade_agg
            FROM matches
            WHERE {where_sql}
            GROUP BY grp_key, our_spawn_corner
            ORDER BY grp_key, corner
            """,
            params,
        ).fetchall()
        by_grp: dict[str, list[sqlite3.Row]] = defaultdict(list)
        for r in rows:
            by_grp[str(r["grp_key"])].append(r)

        for grp_key, items in by_grp.items():
            items.sort(key=lambda x: str(x["corner"]))
            for i in range(len(items)):
                for j in range(i + 1, len(items)):
                    a, b = items[i], items[j]
                    na, nb = int(a["n"]), int(b["n"])
                    wa, wb = int(a["w"]), int(b["w"])
                    wra, wrb = float(a["wr_pct"] or 0.0), float(b["wr_pct"] or 0.0)
                    dw = round(wra - wrb, 1)
                    z = round(_two_prop_z(wa, na, wb, nb), 2)
                    sba = float(a["sb_pct"]) if a["sb_pct"] is not None else None
                    sbb = float(b["sb_pct"]) if b["sb_pct"] is not None else None
                    sb_ratio = 1.0
                    max_sb = 0.0
                    if sba is not None and sbb is not None:
                        max_sb = max(sba, sbb)
                        sb_ratio = round(max_sb / max(0.5, min(sba, sbb)), 2) if max_sb > 0 else 1.0
                    tra, trb = float(a["trade_agg"] or 0.0), float(b["trade_agg"] or 0.0)
                    dt = round(tra - trb, 2)

                    reasons: list[str] = []
                    min_n = min(na, nb)
                    if min_n >= min_pair_n and (abs(z) >= 1.65 or abs(dw) >= 15.0):
                        reasons.append(f"WR_GAP({dw:+.1f}pp,z={z:+.2f})")
                    elif single_run_mode and min_n >= 1 and (na + nb) >= 3 and abs(dw) >= 50.0:
                        reasons.append(f"WR_GAP({dw:+.1f}pp)")
                    if min_n >= max(2, min(min_pair_n, 2)) and max_sb >= 6.0 and sb_ratio >= 1.8:
                        reasons.append(f"SB_RATIO({sb_ratio:.2f}x)")
                    elif single_run_mode and min_n >= 1 and max_sb >= 5.0 and sb_ratio >= 2.0:
                        reasons.append(f"SB_RATIO({sb_ratio:.2f}x)")

                    if reasons:
                        outliers.append({
                            "scope": scope,
                            "key": grp_key,
                            "map_canon": str(a["map_canon"]),
                            "matchup": str(a["matchup"]) if scope == "matchup_map" else None,
                            "corner_a": str(a["corner"]),
                            "corner_b": str(b["corner"]),
                            "n_a": na,
                            "n_b": nb,
                            "wr_a": wra,
                            "wr_b": wrb,
                            "wr_delta_pp": dw,
                            "z_score": z,
                            "sb_a": sba,
                            "sb_b": sbb,
                            "sb_ratio": sb_ratio,
                            "trade_a": tra,
                            "trade_b": trb,
                            "trade_diff": dt,
                            "reason": ", ".join(reasons),
                        })

    _scan("map", "canon_map(map_name)")
    _scan("matchup_map", "COALESCE(matchup, '?v?') || '|' || canon_map(map_name)")
    outliers.sort(
        key=lambda o: (abs(o["z_score"]) * 12.0 + abs(o["wr_delta_pp"]) + max(0.0, o["sb_ratio"] - 1.0) * 15.0),
        reverse=True,
    )
    return outliers


def cmd_spawn_bias(args: argparse.Namespace) -> int:
    conn = open_db(Path(args.db), readonly=True)
    clauses = ["our_spawn_corner IS NOT NULL", "result IN ('win','loss','tie')"]
    params: list[Any] = []
    if not args.include_selfplay:
        clauses.append("is_selfplay = 0")
    if not args.include_dirty:
        clauses.append("is_clean = 1")
    if args.cohort:
        clauses.append("opp_cohort = ?")
        params.append(args.cohort)
    if args.source:
        clauses.append("source_type = ?")
        params.append(args.source)
    if args.race:
        clauses.append("COALESCE(actual_race, our_race) = ?")
        params.append(_norm_race(args.race))
    if getattr(args, "matchup", None):
        clauses.append("UPPER(matchup) = UPPER(?)")
        params.append(args.matchup)
    if args.bot:
        clauses.append("bot = ?")
        params.append(args.bot)
    if getattr(args, "build", None):
        clauses.append("(bot_build_version = ? OR bot_build_version LIKE ?)")
        params.extend([args.build, f"%{args.build}%"])
    if args.run:
        clauses.append("run_id LIKE ?")
        params.append(f"%{args.run}%")
    if getattr(args, "since_run", None):
        clauses.append("run_id >= ?")
        params.append(args.since_run)
    if getattr(args, "recent_runs", None):
        n_rec = max(1, int(args.recent_runs))
        src_filter = "AND m.source_type = ?" if args.source else ""
        src_params = [args.source] if args.source else []
        top_rids = [
            r[0]
            for r in conn.execute(
                f"""
                SELECT DISTINCT r.run_id
                FROM runs r
                JOIN matches m ON m.run_id = r.run_id
                WHERE 1=1 {src_filter}
                ORDER BY COALESCE(r.started_at, r.run_id) DESC
                LIMIT ?
                """,
                src_params + [n_rec],
            ).fetchall()
        ]
        if not top_rids:
            print("No matching recent runs found.")
            return 0
        ph = ",".join("?" for _ in top_rids)
        clauses.append(f"run_id IN ({ph})")
        params.extend(top_rids)

    where = " AND ".join(clauses)

    print("=== Overall Spawn-Corner Bias ===")
    overall = conn.execute(
        f"""
        SELECT our_spawn_corner AS corner,
               COUNT(*) AS n,
               SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) AS w,
               SUM(CASE WHEN result='loss' THEN 1 ELSE 0 END) AS l,
               SUM(CASE WHEN result='tie' THEN 1 ELSE 0 END) AS t,
               ROUND(100.0 * SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) / COUNT(*), 1) AS wr_pct,
               ROUND(100.0 * SUM(CASE WHEN result!='loss' THEN 1 ELSE 0 END) / COUNT(*), 1) AS nl_pct,
               ROUND(SUM(COALESCE(killed_val,0)) / MAX(1.0, SUM(COALESCE(lost_val,0))), 2) AS trade_agg,
               ROUND(AVG(sup_blk_pct), 1) AS sb_pct,
               ROUND(AVG(duration_sec), 0) AS avg_dur_s
        FROM matches
        WHERE {where}
        GROUP BY our_spawn_corner
        ORDER BY corner
        """,
        params,
    ).fetchall()
    _print_table(
        ["corner", "n", "W", "L", "T", "WR%", "NL%", "TradeAgg", "SB%", "AvgDur"],
        [list(r) for r in overall],
    )

    print("\n=== Map x Spawn-Corner Breakdown ===")
    by_map = conn.execute(
        f"""
        SELECT canon_map(map_name) AS map_canon,
               our_spawn_corner AS corner,
               COUNT(*) AS n,
               SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) AS w,
               SUM(CASE WHEN result='loss' THEN 1 ELSE 0 END) AS l,
               SUM(CASE WHEN result='tie' THEN 1 ELSE 0 END) AS t,
               ROUND(100.0 * SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) / COUNT(*), 1) AS wr_pct,
               ROUND(SUM(COALESCE(killed_val,0)) / MAX(1.0, SUM(COALESCE(lost_val,0))), 2) AS trade_agg,
               ROUND(AVG(sup_blk_pct), 1) AS sb_pct,
               ROUND(AVG(our_start_x), 1) || ',' || ROUND(AVG(our_start_y), 1) AS avg_start_xy
        FROM matches
        WHERE {where}
        GROUP BY map_canon, our_spawn_corner
        HAVING COUNT(*) >= ?
        ORDER BY map_canon, corner
        """,
        params + [int(args.min_games)],
    ).fetchall()
    _print_table(
        ["map_canon", "corner", "n", "W", "L", "T", "WR%", "TradeAgg", "SB%", "avg_start_xy"],
        [list(r) for r in by_map],
    )

    if getattr(args, "by_matchup", False) or getattr(args, "matchup", None):
        print("\n=== Map x Matchup x Spawn-Corner Breakdown ===")
        by_mu = conn.execute(
            f"""
            SELECT canon_map(map_name) AS map_canon,
                   COALESCE(matchup, '?v?') AS mu,
                   our_spawn_corner AS corner,
                   COUNT(*) AS n,
                   SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) AS w,
                   SUM(CASE WHEN result='loss' THEN 1 ELSE 0 END) AS l,
                   SUM(CASE WHEN result='tie' THEN 1 ELSE 0 END) AS t,
                   ROUND(100.0 * SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) / COUNT(*), 1) AS wr_pct,
                   ROUND(SUM(COALESCE(killed_val,0)) / MAX(1.0, SUM(COALESCE(lost_val,0))), 2) AS trade_agg,
                   ROUND(AVG(sup_blk_pct), 1) AS sb_pct
            FROM matches
            WHERE {where}
            GROUP BY map_canon, mu, our_spawn_corner
            HAVING COUNT(*) >= ?
            ORDER BY map_canon, mu, corner
            """,
            params + [int(args.min_games)],
        ).fetchall()
        _print_table(
            ["map_canon", "mu", "corner", "n", "W", "L", "T", "WR%", "TradeAgg", "SB%"],
            [list(r) for r in by_mu],
        )

    single_mode = bool(args.run or (getattr(args, "recent_runs", None) == 1))
    eff_min_pair = (
        int(args.min_pair_n)
        if getattr(args, "min_pair_n", None) is not None
        else (2 if single_mode else 5)
    )
    outliers = _compute_spawn_outliers(conn, where, params, min_pair_n=eff_min_pair, single_run_mode=single_mode)
    print(f"\n=== Automatic Spawn-Position Outliers (min_pair_n={eff_min_pair}, found={len(outliers)}) ===")
    if outliers:
        _print_table(
            ["scope", "key", "A vs B", "nA/nB", "WR_A/B", "dWR", "z", "SB_A/B", "Tr_A/B", "reason"],
            [
                [
                    o["scope"],
                    o["key"],
                    f"{o['corner_a']} vs {o['corner_b']}",
                    f"{o['n_a']}/{o['n_b']}",
                    f"{o['wr_a']}%/{o['wr_b']}%",
                    f"{o['wr_delta_pp']:+.1f}pp",
                    f"{o['z_score']:+.2f}",
                    f"{o['sb_a'] if o['sb_a'] is not None else '-'}%/{o['sb_b'] if o['sb_b'] is not None else '-'}%",
                    f"{o['trade_a']}x/{o['trade_b']}x",
                    o["reason"],
                ]
                for o in outliers[:20]
            ],
        )
    else:
        print("(No significant spawn-corner outliers detected under current filter.)")
    return 0


# ---------------------------------------------------------------------------
# Subcommand: analyze-prod
# ---------------------------------------------------------------------------

def _fmt_table_str(headers: list[str], rows: list[list[Any]]) -> str:
    str_rows = [["" if v is None else str(v) for v in r] for r in rows]
    widths = [len(h) for h in headers]
    for r in str_rows:
        for i, cell in enumerate(r):
            if len(cell) > widths[i]:
                widths[i] = len(cell)
    fmt = " | ".join(f"{{:<{w}}}" for w in widths)
    sep = "-+-".join("-" * w for w in widths)
    lines = [fmt.format(*headers), sep]
    for r in str_rows:
        lines.append(fmt.format(*r))
    return "\n".join(lines)


def _fmt_mmss(sec: float | None) -> str:
    if sec is None or sec <= 0:
        return "-"
    s = int(round(sec))
    return f"{s // 60}:{s % 60:02d}"


def cmd_analyze_prod(args: argparse.Namespace) -> int:
    db_path = Path(args.db)
    if not db_path.exists():
        print(f"DB not found at {db_path}. Run `ingest-prod-aiarena` first.", file=sys.stderr)
        return 1
    conn = open_db(db_path, readonly=True)

    clauses = ["m.source_type = 'prod_aiarena'"]
    params: list[Any] = []
    if not getattr(args, "include_selfplay", False):
        clauses.append("m.is_selfplay = 0")
    if getattr(args, "build", None):
        clauses.append("(m.bot_build_version = ? OR m.bot_build_version LIKE ?)")
        params.extend([args.build, f"%{args.build}%"])
    if getattr(args, "since", None):
        clauses.append("COALESCE(json_extract(m.score_meta_json, '$.created'), '') >= ?")
        params.append(args.since)
    if getattr(args, "bot", None):
        clauses.append("m.bot = ?")
        params.append(args.bot)
    where = " AND ".join(clauses)

    out_lines: list[str] = []
    p = out_lines.append

    # 1. Overview
    ov = conn.execute(
        f"""
        SELECT COUNT(*) AS n,
               SUM(CASE WHEN m.result='win' THEN 1 ELSE 0 END) AS w,
               SUM(CASE WHEN m.result='loss' THEN 1 ELSE 0 END) AS l,
               SUM(CASE WHEN m.result='tie' THEN 1 ELSE 0 END) AS t,
               SUM(CASE WHEN m.raw_extracted_at IS NOT NULL THEN 1 ELSE 0 END) AS raw_n,
               SUM(CASE WHEN json_extract(m.score_meta_json, '$.scored') = 1 OR m.sup_blk_pct IS NOT NULL THEN 1 ELSE 0 END) AS scored_n,
               ROUND(SUM(COALESCE(m.killed_val,0)) / MAX(1.0, SUM(COALESCE(m.lost_val,0))), 2) AS trade_agg,
               ROUND(AVG(m.avg_step_ms), 2) AS avg_step,
               ROUND(AVG(m.sup_blk_pct), 1) AS avg_sb,
               MIN(json_extract(m.score_meta_json, '$.created')) AS min_ts,
               MAX(json_extract(m.score_meta_json, '$.created')) AS max_ts,
               COUNT(DISTINCT m.bot_build_version) AS n_builds
        FROM matches m
        WHERE {where}
        """,
        params,
    ).fetchone()
    sp_cnt = conn.execute(
        "SELECT COUNT(*) FROM matches WHERE source_type = 'prod_aiarena' AND is_selfplay = 1"
    ).fetchone()[0]

    n_total = int(ov["n"] or 0)
    if n_total == 0:
        print("No prod_aiarena matches found matching filter.")
        return 0
    w_tot = int(ov["w"] or 0)
    l_tot = int(ov["l"] or 0)
    t_tot = int(ov["t"] or 0)
    wr_tot = round(100.0 * w_tot / n_total, 1)
    nl_tot = round(100.0 * (n_total - l_tot) / n_total, 1)

    p("=== PROD AI ARENA FORENSIC ANALYSIS ===")
    p(
        f"Scope     : n={n_total} ({'all incl. selfplay' if getattr(args, 'include_selfplay', False) else f'external; +{sp_cnt} selfplay excluded'}) | "
        f"builds={ov['n_builds']} | span={str(ov['min_ts'] or '-')[:16]} .. {str(ov['max_ts'] or '-')[:16]}"
    )
    p(
        f"Record    : {w_tot}W-{l_tot}L-{t_tot}T ({wr_tot}% WR, {nl_tot}% NL) | "
        f"TradeAgg={ov['trade_agg']}x | AvgStep={ov['avg_step']}ms | AvgSupBlk={ov['avg_sb']}%"
    )
    p(f"Coverage  : raw_tracker={ov['raw_n']}/{n_total}, anomaly_scored={ov['scored_n']}/{n_total}")

    # 2. Per-Build Progression
    p("\n=== 1. Per-Build Progression (Chronological) ===")
    b_rows = conn.execute(
        f"""
        SELECT COALESCE(m.bot_build_version, '(unknown)') AS build,
               COUNT(*) AS n,
               SUM(CASE WHEN m.result='win' THEN 1 ELSE 0 END) AS w,
               SUM(CASE WHEN m.result='loss' THEN 1 ELSE 0 END) AS l,
               SUM(CASE WHEN m.result='tie' THEN 1 ELSE 0 END) AS t,
               ROUND(100.0 * SUM(CASE WHEN m.result='win' THEN 1 ELSE 0 END) / COUNT(*), 1) AS wr_pct,
               ROUND(100.0 * SUM(CASE WHEN m.result!='loss' THEN 1 ELSE 0 END) / COUNT(*), 1) AS nl_pct,
               ROUND(AVG(m.aiarena_bot_elo), 0) AS bot_elo,
               ROUND(AVG(m.aiarena_opp_elo), 0) AS opp_elo,
               ROUND(AVG(m.avg_step_ms), 2) AS step_ms,
               ROUND(SUM(COALESCE(m.killed_val,0)) / MAX(1.0, SUM(COALESCE(m.lost_val,0))), 2) AS trade_agg,
               ROUND(AVG(m.w4m), 1) AS w4m,
               ROUND(AVG(m.w6m), 1) AS w6m,
               ROUND(AVG(m.sup_blk_pct), 1) AS sb_pct
        FROM matches m
        WHERE {where}
        GROUP BY build
        ORDER BY MIN(COALESCE(json_extract(m.score_meta_json, '$.created'), m.run_id)) ASC
        """,
        params,
    ).fetchall()
    p(_fmt_table_str(
        ["build", "n", "W", "L", "T", "WR%", "NL%", "BotELO", "OppELO", "StepMs", "Trade", "W@4m", "W@6m", "SB%"],
        [list(r) for r in b_rows],
    ))

    # 3. Per-Bot Breakdown
    p("\n=== 2. Per-Bot Breakdown ===")
    bot_rows = conn.execute(
        f"""
        SELECT COALESCE(m.bot, '(unknown)') AS bot,
               COUNT(*) AS n,
               SUM(CASE WHEN m.result='win' THEN 1 ELSE 0 END) AS w,
               SUM(CASE WHEN m.result='loss' THEN 1 ELSE 0 END) AS l,
               SUM(CASE WHEN m.result='tie' THEN 1 ELSE 0 END) AS t,
               ROUND(100.0 * SUM(CASE WHEN m.result='win' THEN 1 ELSE 0 END) / COUNT(*), 1) AS wr_pct,
               ROUND(100.0 * SUM(CASE WHEN m.result!='loss' THEN 1 ELSE 0 END) / COUNT(*), 1) AS nl_pct,
               (SELECT m2.aiarena_bot_elo FROM matches m2
                WHERE m2.source_type='prod_aiarena' AND m2.bot=m.bot AND m2.aiarena_bot_elo IS NOT NULL
                ORDER BY COALESCE(m2.aiarena_match_id, 0) DESC LIMIT 1) AS last_elo,
               ROUND(SUM(COALESCE(m.killed_val,0)) / MAX(1.0, SUM(COALESCE(m.lost_val,0))), 2) AS trade_agg,
               ROUND(AVG(m.avg_step_ms), 2) AS step_ms,
               ROUND(AVG(m.w4m), 1) AS w4m,
               ROUND(AVG(m.w6m), 1) AS w6m,
               ROUND(AVG(m.sup_blk_pct), 1) AS sb_pct
        FROM matches m
        WHERE {where}
        GROUP BY m.bot
        ORDER BY m.bot
        """,
        params,
    ).fetchall()
    p(_fmt_table_str(
        ["bot", "n", "W", "L", "T", "WR%", "NL%", "LastELO", "Trade", "StepMs", "W@4m", "W@6m", "SB%"],
        [list(r) for r in bot_rows],
    ))

    # 4. Top Prod Opponents (Hardest & Easiest)
    min_opp = max(1, int(getattr(args, "min_opp_games", 2)))
    opp_rows = conn.execute(
        f"""
        SELECT COALESCE(m.opponent, '(unknown)') AS opp,
               MAX(COALESCE(m.opp_race, '?')) AS race,
               ROUND(AVG(m.aiarena_opp_elo), 0) AS opp_elo,
               COUNT(*) AS n,
               SUM(CASE WHEN m.result='win' THEN 1 ELSE 0 END) AS w,
               SUM(CASE WHEN m.result='loss' THEN 1 ELSE 0 END) AS l,
               SUM(CASE WHEN m.result='tie' THEN 1 ELSE 0 END) AS t,
               ROUND(100.0 * SUM(CASE WHEN m.result='win' THEN 1 ELSE 0 END) / COUNT(*), 1) AS wr_pct,
               ROUND(SUM(COALESCE(m.killed_val,0)) / MAX(1.0, SUM(COALESCE(m.lost_val,0))), 2) AS trade_agg,
               ROUND(AVG(m.duration_sec), 0) AS avg_dur_s
        FROM matches m
        WHERE {where}
        GROUP BY m.opponent
        HAVING COUNT(*) >= ?
        """,
        params + [min_opp],
    ).fetchall()
    if opp_rows:
        hardest = sorted(opp_rows, key=lambda r: (r["wr_pct"], -r["l"], r["trade_agg"] or 0.0))[:10]
        easiest = sorted(opp_rows, key=lambda r: (-r["wr_pct"], -r["w"], -(r["trade_agg"] or 0.0)))[:10]
        p(f"\n=== 3A. Hardest Prod Opponents (n >= {min_opp}) ===")
        p(_fmt_table_str(
            ["opponent", "race", "elo", "n", "W", "L", "T", "WR%", "Trade", "AvgDur"],
            [list(r) for r in hardest],
        ))
        p(f"\n=== 3B. Easiest Prod Opponents (n >= {min_opp}) ===")
        p(_fmt_table_str(
            ["opponent", "race", "elo", "n", "W", "L", "T", "WR%", "Trade", "AvgDur"],
            [list(r) for r in easiest],
        ))

    # 5. Prod Anomaly Rates by Build (among scored matches)
    scored_builds = conn.execute(
        f"""
        SELECT COALESCE(m.bot_build_version, '(unknown)') AS build,
               COUNT(*) AS scored_n
        FROM matches m
        WHERE {where} AND (json_extract(m.score_meta_json, '$.scored') = 1 OR m.sup_blk_pct IS NOT NULL)
        GROUP BY build
        ORDER BY MIN(COALESCE(json_extract(m.score_meta_json, '$.created'), m.run_id)) ASC
        """,
        params,
    ).fetchall()
    if scored_builds:
        recent_builds = [r["build"] for r in scored_builds[-6:]]
        build_n = {r["build"]: int(r["scored_n"]) for r in scored_builds}
        total_scored = sum(build_n.values())
        anom_counts = conn.execute(
            f"""
            SELECT a.anomaly_name,
                   COALESCE(m.bot_build_version, '(unknown)') AS build,
                   COUNT(DISTINCT a.replay_id) AS cnt
            FROM match_anomalies a
            JOIN matches m ON m.replay_id = a.replay_id
            WHERE {where} AND a.player_side = 'p1'
            GROUP BY a.anomaly_name, build
            """,
            params,
        ).fetchall()
        by_anom: dict[str, dict[str, int]] = defaultdict(dict)
        anom_totals: Counter[str] = Counter()
        for r in anom_counts:
            by_anom[r["anomaly_name"]][r["build"]] = int(r["cnt"])
            anom_totals[r["anomaly_name"]] += int(r["cnt"])
        if anom_totals:
            p(f"\n=== 4. Prod Anomaly Rates by Build (scored n={total_scored}, latest {len(recent_builds)} builds) ===")
            hdr = ["anomaly", f"ALL(n={total_scored})"] + [
                f"{b.replace('deploy:', '')}({build_n[b]})" for b in recent_builds
            ]
            arows: list[list[Any]] = []
            for aname, tot in anom_totals.most_common(18):
                row_vals: list[Any] = [aname, f"{tot} ({100.0 * tot / max(1, total_scored):.0f}%)"]
                for b in recent_builds:
                    c = by_anom[aname].get(b, 0)
                    row_vals.append(f"{c} ({100.0 * c / max(1, build_n[b]):.0f}%)" if c else "0")
                arows.append(row_vals)
            p(_fmt_table_str(hdr, arows))
    else:
        p("\n=== 4. Prod Anomaly Rates by Build ===")
        p("(No anomaly-scored prod matches yet — run `ingest-prod-aiarena <dir> --score` to populate!)")

    # 5B. Map x Spawn-Corner Outliers (Prod)
    # Note: _compute_spawn_outliers queries `FROM matches` (no `m.` alias), so strip `m.` prefix cleanly
    plain_where = re.sub(r"\bm\.", "", where) + " AND our_spawn_corner IS NOT NULL AND result IN ('win','loss','tie')"
    prod_outliers = _compute_spawn_outliers(conn, plain_where, params, min_pair_n=3, single_run_mode=False)
    p(f"\n=== 4B. Map x Spawn-Corner Outliers (Prod, min_pair_n=3, found={len(prod_outliers)}) ===")
    if prod_outliers:
        p(_fmt_table_str(
            ["scope", "key", "A vs B", "nA/nB", "WR_A/B", "dWR", "z", "SB_A/B", "Tr_A/B", "reason"],
            [
                [
                    o["scope"],
                    o["key"],
                    f"{o['corner_a']} vs {o['corner_b']}",
                    f"{o['n_a']}/{o['n_b']}",
                    f"{o['wr_a']}%/{o['wr_b']}%",
                    f"{o['wr_delta_pp']:+.1f}pp",
                    f"{o['z_score']:+.2f}",
                    f"{o['sb_a'] if o['sb_a'] is not None else '-'}%/{o['sb_b'] if o['sb_b'] is not None else '-'}%",
                    f"{o['trade_a']}x/{o['trade_b']}x",
                    o["reason"],
                ]
                for o in prod_outliers[:10]
            ],
        ))
    else:
        p("(No significant prod spawn-corner outliers detected under current filter.)")

    # 6. Top Prod Losses with Raw Build-Order, Econ & Death Forensics
    top_k = max(0, int(getattr(args, "top_losses", 10)))
    if top_k > 0:
        sort_mode = getattr(args, "sort_losses", "recent")
        order_sql = (
            "COALESCE(m.trade_ratio, 999.0) ASC, COALESCE(m.aiarena_match_id, 0) DESC"
            if sort_mode == "worst-trade"
            else "COALESCE(json_extract(m.score_meta_json, '$.created'), '') DESC, COALESCE(m.aiarena_match_id, 0) DESC"
        )
        losses = conn.execute(
            f"""
            SELECT m.*
            FROM matches m
            WHERE {where} AND m.result = 'loss'
            ORDER BY {order_sql}
            LIMIT ?
            """,
            params + [top_k],
        ).fetchall()
        if losses:
            p(f"\n=== 5. Top {len(losses)} Prod Losses — Raw Econ, Unit Deaths & Opening BO (sort={sort_mode}) ===")
            for idx, m in enumerate(losses, start=1):
                rid = m["replay_id"]
                our_pid = m["our_player_id"] or 1
                opp_pid = 2 if our_pid == 1 else 1
                mid_s = f"#{m['aiarena_match_id']}" if m["aiarena_match_id"] else rid[:10]
                elo_s = f"elo={m['aiarena_bot_elo'] or '?'}/{m['aiarena_opp_elo'] or '?'}"
                p(
                    f"\n[{idx}] {mid_s} [{m['bot_build_version'] or '?'}] "
                    f"{m['bot']}({m['actual_race'] or m['our_race']}) vs {m['opponent']}({m['opp_race'] or '?'}) "
                    f"[{m['matchup'] or '?'}] | {m['map_name'] or '?'} [{m['our_spawn_corner'] or '?'}] | "
                    f"{_fmt_mmss(m['duration_sec'])} | Trade={m['trade_ratio']}x (K={m['killed_val']}/L={m['lost_val']}) | "
                    f"{elo_s} | SB={m['sup_blk_pct']}% | step={m['avg_step_ms']}ms"
                )
                anoms = [
                    r["anomaly_name"]
                    for r in conn.execute(
                        "SELECT anomaly_name FROM match_anomalies WHERE replay_id = ? AND player_side = 'p1' ORDER BY anomaly_name",
                        (rid,),
                    )
                ]
                if anoms:
                    p(f"    anomalies : {', '.join(anoms)}")
                # Minute econ curve (2, 4, 6, 8, 10)
                mstats = conn.execute(
                    """
                    SELECT a.minute, a.workers_active AS w1, b.workers_active AS w2,
                           a.army_value_total AS a1, b.army_value_total AS a2,
                           a.bases_alive AS b1, b.bases_alive AS b2
                    FROM match_minute_stats a
                    LEFT JOIN match_minute_stats b
                      ON b.replay_id = a.replay_id AND b.minute = a.minute AND b.player_id = ?
                    WHERE a.replay_id = ? AND a.player_id = ? AND a.minute IN (2, 4, 6, 8, 10)
                    ORDER BY a.minute
                    """,
                    (opp_pid, rid, our_pid),
                ).fetchall()
                if mstats:
                    pts = [
                        f"m{r['minute']}:W({r['w1']}/{r['w2']}) A({r['a1']}/{r['a2']}) B({r['b1']}/{r['b2']})"
                        for r in mstats
                    ]
                    p(f"    econ      : {' | '.join(pts)}")
                # Top P1 deaths & P2 combat units
                skip_u = (
                    "('Larva','Egg','Interceptor','Broodling','CreepTumor','CreepTumorBurrowed',"
                    "'CreepTumorQueen','MULE','InvisibleTargetDummy','AdeptPhaseShift','KD8Charge',"
                    "'ForceField','BeaconArmy','OverlordCocoon','TransportOverlordCocoon',"
                    "'BanelingCocoon','RavagerCocoon','LurkerMPEgg','BroodLordCocoon',"
                    "'DisruptorPhased','ParasiticBombDummy','ParasiticBombRelayDummy','AutoTurret')"
                )
                our_died = conn.execute(
                    f"""
                    SELECT unit_type, died, created FROM match_unit_totals
                    WHERE replay_id = ? AND player_id = ? AND died > 0 AND unit_type NOT IN {skip_u}
                    ORDER BY died DESC LIMIT 6
                    """,
                    (rid, our_pid),
                ).fetchall()
                opp_built = conn.execute(
                    f"""
                    SELECT unit_type, created, died FROM match_unit_totals
                    WHERE replay_id = ? AND player_id = ? AND unit_type NOT IN {skip_u}
                      AND unit_type NOT IN ('Drone','SCV','Probe','Overlord','Pylon','SupplyDepot','SupplyDepotLowered')
                    ORDER BY created DESC LIMIT 6
                    """,
                    (rid, opp_pid),
                ).fetchall()
                if our_died or opp_built:
                    d_str = ", ".join(f"{r['unit_type']}:{r['died']}/{r['created']}" for r in our_died)
                    o_str = ", ".join(f"{r['unit_type']}:{r['created']}(-{r['died']})" for r in opp_built)
                    p(f"    our_deaths: {d_str or '-'} || opp_units: {o_str or '-'}")
                # Opening build events (first 8 init/morph/upgrade)
                bevs = conn.execute(
                    """
                    SELECT sec, unit_type FROM match_build_events
                    WHERE replay_id = ? AND player_id = ? AND event_type IN ('init', 'morph', 'upgrade')
                      AND unit_type NOT IN ('Drone','SCV','Probe','Overlord','Zergling','CreepTumor','CreepTumorQueen','CreepTumorBurrowed')
                    ORDER BY game_loop ASC LIMIT 8
                    """,
                    (rid, our_pid),
                ).fetchall()
                if bevs:
                    bo_str = " -> ".join(f"{int(round(r['sec']))}s:{r['unit_type']}" for r in bevs)
                    p(f"    opening_bo: {bo_str}")

    report_text = "\n".join(out_lines) + "\n"
    sys.stdout.write(report_text)
    if getattr(args, "out_md", None):
        out_p = Path(args.out_md)
        out_p.parent.mkdir(parents=True, exist_ok=True)
        out_p.write_text(report_text)
        print(f"Wrote prod analysis report -> {out_p}", file=sys.stderr)
    return 0


# ---------------------------------------------------------------------------
# Subcommand: sync-prod (one-command gh fetch -> score -> ingest -> analyze)
# ---------------------------------------------------------------------------

def _gh_run_cmd(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=str(cwd), capture_output=True, text=True)


def _gh_latest_workflow_run_id(repo_dir: Path, workflow: str, status: str | None = None) -> int | None:
    cmd = ["gh", "run", "list", "--workflow", workflow, "--limit", "5", "--json", "databaseId,status,conclusion"]
    if status:
        cmd.extend(["--status", status])
    res = _gh_run_cmd(cmd, repo_dir)
    if res.returncode != 0 or not res.stdout.strip():
        return None
    try:
        items = json.loads(res.stdout)
        if items and isinstance(items, list):
            return int(items[0]["databaseId"])
    except Exception:
        return None
    return None


def cmd_sync_prod(args: argparse.Namespace) -> int:
    db_path = Path(args.db)
    repo_dir = Path(args.repo_dir)
    dest_root = Path(args.dest_root)
    workflow = args.workflow
    artifact_name = args.artifact_name

    # Collect known match IDs to pass as skip_matches when triggering a new run
    skip_csv = ""
    if not args.no_skip_known and db_path.exists():
        try:
            conn = open_db(db_path, readonly=True)
            mids = [
                str(r[0])
                for r in conn.execute(
                    "SELECT DISTINCT aiarena_match_id FROM matches "
                    "WHERE source_type='prod_aiarena' AND aiarena_match_id IS NOT NULL "
                    "ORDER BY aiarena_match_id DESC LIMIT 120"
                ).fetchall()
            ]
            conn.close()
            skip_csv = ",".join(mids)
        except Exception:
            skip_csv = ""

    gh_run_id: int | None = int(args.gh_run_id) if args.gh_run_id else None
    if args.dry_run:
        plan_lines = ["[sync-prod DRY RUN]"]
        if gh_run_id:
            plan_lines.append(f"  1. Download existing gh run_id={gh_run_id} ({artifact_name})")
        elif args.latest_gh_run:
            plan_lines.append(f"  1. Lookup latest completed `{workflow}` gh run & download `{artifact_name}`")
        else:
            wf_cmd = ["gh", "workflow", "run", workflow, "-f", f"limit={args.limit}"]
            if args.since_date:
                wf_cmd.extend(["-f", f"since_date={args.since_date}"])
            if args.since_match:
                wf_cmd.extend(["-f", f"since_match={args.since_match}"])
            if skip_csv:
                wf_cmd.extend(["-f", f"skip_matches=<{len(skip_csv.split(','))} known IDs>"])
            plan_lines.append(f"  1. Trigger: {' '.join(wf_cmd)}")
            plan_lines.append("  2. Watch run to completion & download artifact")
        plan_lines.append(f"  3. Unpack -> {dest_root}/run_<gh_run_id>/{artifact_name}")
        plan_lines.append(f"  4. Ingest + raw-extract + score={not args.no_score} -> {db_path}")
        plan_lines.append(f"  5. Run analyze-prod (enabled={not args.no_analyze})")
        print("\n".join(plan_lines))
        return 0

    # Step 1: Resolve or trigger GitHub Actions workflow run
    if gh_run_id is None and args.latest_gh_run:
        gh_run_id = _gh_latest_workflow_run_id(repo_dir, workflow, status="completed")
        if gh_run_id is None:
            print(f"No completed `{workflow}` runs found via `gh run list`.", file=sys.stderr)
            return 1
        print(f"[sync-prod] Using latest completed workflow run_id={gh_run_id}")
    elif gh_run_id is None:
        prev_id = _gh_latest_workflow_run_id(repo_dir, workflow) or 0
        wf_cmd = ["gh", "workflow", "run", workflow, "-f", f"limit={args.limit}"]
        if args.since_date:
            wf_cmd.extend(["-f", f"since_date={args.since_date}"])
        if args.since_match:
            wf_cmd.extend(["-f", f"since_match={args.since_match}"])
        if skip_csv:
            wf_cmd.extend(["-f", f"skip_matches={skip_csv}"])
        print(f"[sync-prod] Triggering `{workflow}` (limit={args.limit}, skip_known={len(skip_csv.split(',')) if skip_csv else 0})...")
        trig = _gh_run_cmd(wf_cmd, repo_dir)
        if trig.returncode != 0:
            print(f"Failed to trigger workflow:\n{trig.stderr}", file=sys.stderr)
            return 1
        # Wait up to 60s for new run ID to register
        deadline = time.time() + 60.0
        while time.time() < deadline:
            cand = _gh_latest_workflow_run_id(repo_dir, workflow)
            if cand is not None and cand > prev_id:
                gh_run_id = cand
                break
            time.sleep(3.0)
        if gh_run_id is None:
            print("Timed out waiting for triggered GitHub Actions run ID to appear.", file=sys.stderr)
            return 1
        print(f"[sync-prod] Watching workflow run_id={gh_run_id} until completion...")
        wres = subprocess.run(
            ["gh", "run", "watch", str(gh_run_id), "--exit-status"],
            cwd=str(repo_dir),
        )
        if wres.returncode != 0:
            print(f"Workflow run {gh_run_id} did not succeed (rc={wres.returncode}).", file=sys.stderr)
            return wres.returncode

    # Step 2: Download artifact to dest_root/run_<id>/<artifact_name>
    run_dest = dest_root / f"run_{gh_run_id}"
    artifact_dir = run_dest / artifact_name
    artifact_dir.mkdir(parents=True, exist_ok=True)
    if not list(artifact_dir.glob("*.SC2Replay")):
        print(f"[sync-prod] Downloading artifact `{artifact_name}` from run {gh_run_id} -> {artifact_dir}")
        dres = _gh_run_cmd(
            ["gh", "run", "download", str(gh_run_id), "-n", artifact_name, "-D", str(artifact_dir)],
            repo_dir,
        )
        if dres.returncode != 0:
            print(f"Failed to download artifact:\n{dres.stderr}", file=sys.stderr)
            return 1
    else:
        print(f"[sync-prod] Reusing already-downloaded replays in {artifact_dir}")

    # Step 3: Score + Ingest + Raw-Extract
    ing_ns = argparse.Namespace(
        db=str(db_path),
        dir=str(artifact_dir),
        run_id=f"prod_aiarena_run_{gh_run_id}",
        tag=f"run_{gh_run_id}",
        repo_dir=str(repo_dir),
        score=not args.no_score,
        score_json=None,
        score_out=str(run_dest / f"prod_score_run_{gh_run_id}.json"),
        extract_raw=True,
        pylibs_dir=str(args.pylibs_dir),
        jobs=int(args.jobs),
        verbose=bool(args.verbose),
    )
    rc = cmd_ingest_prod_aiarena(ing_ns)
    if rc != 0:
        return rc

    # Step 4: Automatic analyze-prod report (never download without analysis!)
    if not args.no_analyze:
        an_ns = argparse.Namespace(
            db=str(db_path),
            build=args.analyze_build,
            since=args.since_date,
            bot=None,
            include_selfplay=False,
            min_opp_games=2,
            top_losses=int(args.top_losses),
            sort_losses="recent",
            out_md=args.out_md,
        )
        return cmd_analyze_prod(an_ns)
    return 0


# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="SQLite Replay Metadata & Raw SC2Replay Extraction DB")
    p.add_argument("--db", default=str(DEFAULT_DB_PATH), help=f"SQLite DB path (default: {DEFAULT_DB_PATH})")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp_ing = sub.add_parser("ingest-runs", help="Ingest runs/* summary/replays + score.json files")
    sp_ing.add_argument("--runs-dir", default=str(DEFAULT_RUNS_DIR))
    sp_ing.add_argument("--scores-dir", action="append", default=None, help="Directory with *score*.json (repeatable)")
    sp_ing.add_argument("--score-json", action="append", default=None, help="Explicit score.json file (repeatable)")
    sp_ing.add_argument("--roster", default=str(DEFAULT_ROSTER_PATH))
    sp_ing.add_argument("--run", default=None, help="Filter to run_id substring")
    sp_ing.add_argument("-j", "--jobs", type=int, default=12)

    sp_prod = sub.add_parser(
        "ingest-prod-aiarena",
        help="Ingest downloaded fetch-aiarena-replays.yml or live_*_summary.json prod AI Arena artifacts",
    )
    sp_prod.add_argument("dir", help="Directory containing *_meta.json / *_match_log.zip / *.SC2Replay")
    sp_prod.add_argument("--run-id", default=None, help="Custom run_id (default: prod_aiarena_<dirname>)")
    sp_prod.add_argument("--tag", default=None, help="Custom run tag")
    sp_prod.add_argument("--repo-dir", default=str(REPO_ROOT), help="Repo path for jj/git deploy commit mapping")
    sp_prod.add_argument("--score", action="store_true", help="Auto-run tools/score-replay-batch.rkt to populate all 20 anomalies")
    sp_prod.add_argument("--score-json", default=None, help="Link existing score-replay-batch.rkt JSON output")
    sp_prod.add_argument("--score-out", default=None, help="Output JSON path when --score is enabled")
    sp_prod.add_argument("--extract-raw", action="store_true", help="Also run extract-raw on ingested replays")
    sp_prod.add_argument("--pylibs-dir", default=str(DEFAULT_PYLIBS_DIR))
    sp_prod.add_argument("-j", "--jobs", type=int, default=12)
    sp_prod.add_argument("-v", "--verbose", action="store_true")

    sp_ap = sub.add_parser(
        "analyze-prod",
        help="Prod AI Arena report: per-build WR/ELO/step, per-bot, opponents, anomalies by build, top losses",
    )
    sp_ap.add_argument("--build", default=None, help="Filter bot_build_version (exact or substring)")
    sp_ap.add_argument("--since", default=None, help="Filter matches created >= YYYY-MM-DD")
    sp_ap.add_argument("--bot", default=None, help="Filter bot name (e.g. Mothman-Z)")
    sp_ap.add_argument("--include-selfplay", action="store_true", help="Include Mothman-vs-Mothman prod selfplay")
    sp_ap.add_argument("--min-opp-games", type=int, default=2, help="Min matches for opponent hardest/easiest tables")
    sp_ap.add_argument("--top-losses", type=int, default=10, help="Number of prod losses with raw econ/BO/death forensics")
    sp_ap.add_argument("--sort-losses", choices=["recent", "worst-trade"], default="recent")
    sp_ap.add_argument("--out-md", default=None, help="Optional Markdown file to save the analysis report")

    sp_sp = sub.add_parser(
        "sync-prod",
        help="One-command gh fetch-aiarena-replays.yml -> score-replay-batch -> ingest -> extract-raw -> analyze-prod",
    )
    sp_sp.add_argument("--gh-run-id", type=int, default=None, help="Download existing GitHub Actions run ID (no trigger)")
    sp_sp.add_argument("--latest-gh-run", action="store_true", help="Download latest completed fetch-aiarena-replays.yml run")
    sp_sp.add_argument("--limit", type=int, default=30, help="Max matches to fetch when triggering workflow")
    sp_sp.add_argument("--since-date", default=None, help="Workflow input since_date (YYYY-MM-DD)")
    sp_sp.add_argument("--since-match", type=int, default=None, help="Workflow input since_match")
    sp_sp.add_argument("--no-skip-known", action="store_true", help="Do not pass known DB match IDs to skip_matches")
    sp_sp.add_argument("--workflow", default="fetch-aiarena-replays.yml")
    sp_sp.add_argument("--artifact-name", default="aiarena-replays")
    sp_sp.add_argument("--dest-root", default=str(DEFAULT_PROD_DIR))
    sp_sp.add_argument("--repo-dir", default=str(REPO_ROOT))
    sp_sp.add_argument("--no-score", action="store_true", help="Skip score-replay-batch.rkt anomaly scoring")
    sp_sp.add_argument("--no-analyze", action="store_true", help="Skip automatic analyze-prod output")
    sp_sp.add_argument("--analyze-build", default=None, help="Filter build passed to analyze-prod")
    sp_sp.add_argument("--top-losses", type=int, default=8, help="Losses shown in automatic analyze-prod")
    sp_sp.add_argument("--out-md", default=None, help="Optional Markdown file to save analyze-prod output")
    sp_sp.add_argument("--dry-run", action="store_true", help="Print sync plan without calling gh or modifying DB")
    sp_sp.add_argument("--pylibs-dir", default=str(DEFAULT_PYLIBS_DIR))
    sp_sp.add_argument("-j", "--jobs", type=int, default=12)
    sp_sp.add_argument("-v", "--verbose", action="store_true")

    sp_ext = sub.add_parser("extract-raw", help="Extract raw .SC2Replay tracker (and optional game) events in parallel")
    sp_ext.add_argument("--all", action="store_true", help="Extract all unextracted matches")
    sp_ext.add_argument("--latest", nargs="?", const=1, type=int, default=None, help="Extract latest N runs (default 1)")
    sp_ext.add_argument("--run", default=None, help="Extract matches for run_id or substring")
    sp_ext.add_argument("--replay", default=None, help="Extract single replay by id/prefix/path")
    sp_ext.add_argument("--include-game-events", action="store_true", help="Also decode replay.game.events into match_cmd_summary")
    sp_ext.add_argument("--force", action="store_true", help="Re-extract even if already extracted")
    sp_ext.add_argument("--limit", type=int, default=None, help="Cap number of replays processed")
    sp_ext.add_argument("--pylibs-dir", default=str(DEFAULT_PYLIBS_DIR))
    sp_ext.add_argument("-j", "--jobs", type=int, default=12)
    sp_ext.add_argument("-v", "--verbose", action="store_true")

    sp_q = sub.add_parser("query", help="Run read-only SQL query")
    sp_q.add_argument("sql", nargs="?", default=None)
    sp_q.add_argument("--sql-file", default=None)
    sp_q.add_argument("--format", choices=["table", "json", "csv"], default="table")

    sub.add_parser("stats", help="Show DB size, row counts, extraction coverage, and cohort summary")

    sp_dump = sub.add_parser("replay-dump", help="Forensic dump for one replay (id/prefix/path/match_id)")
    sp_dump.add_argument("target", help="replay_id (or prefix), aiarena_match_id, filename, or path")
    sp_dump.add_argument("--build-limit", type=int, default=40)

    sp_sb = sub.add_parser("spawn-bias", help="Map x Matchup x Spawn-Corner (NW/NE/SW/SE) win-rate & outlier detector")
    sp_sb.add_argument("--cohort", default=None)
    sp_sb.add_argument("--source", default=None, help="Filter source_type (local_arena|prod_aiarena|pro_corpus)")
    sp_sb.add_argument("--race", default=None)
    sp_sb.add_argument("--matchup", default=None, help="Filter matchup (e.g. TvT, TvP, ZvP)")
    sp_sb.add_argument("--by-matchup", action="store_true", help="Also print Map x Matchup x Spawn-Corner breakdown")
    sp_sb.add_argument("--bot", default=None)
    sp_sb.add_argument("--build", default=None, help="Filter bot_build_version (exact or substring)")
    sp_sb.add_argument("--run", default=None)
    sp_sb.add_argument("--since-run", default=None, help="Include only runs with run_id >= value")
    sp_sb.add_argument("--recent-runs", type=int, default=None, help="Include only the most recent N runs")
    sp_sb.add_argument("--min-games", type=int, default=3)
    sp_sb.add_argument("--min-pair-n", type=int, default=None, help="Min games per corner for outlier detection (default 5, or 2 for single run)")
    sp_sb.add_argument("--include-selfplay", action="store_true")
    sp_sb.add_argument("--include-dirty", action="store_true")

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.cmd == "ingest-runs":
        return cmd_ingest_runs(args)
    if args.cmd == "ingest-prod-aiarena":
        return cmd_ingest_prod_aiarena(args)
    if args.cmd == "analyze-prod":
        return cmd_analyze_prod(args)
    if args.cmd == "sync-prod":
        return cmd_sync_prod(args)
    if args.cmd == "extract-raw":
        return cmd_extract_raw(args)
    if args.cmd == "query":
        return cmd_query(args)
    if args.cmd == "stats":
        return cmd_stats(args)
    if args.cmd == "replay-dump":
        return cmd_replay_dump(args)
    if args.cmd == "spawn-bias":
        return cmd_spawn_bias(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
