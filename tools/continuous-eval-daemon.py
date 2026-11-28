#!/usr/bin/env python3
"""Continuous Background Arena & Tactical Drills Evaluation Daemon (Loop 88+).

Runs continuously in the background against immutable Btrfs CoW snapshots of the
Mothman repository, streaming per-match ladder scores (via `score-replay-batch.rkt`)
and sharded real-SC2 tactical drill results (via `sc2-tactics-arena.py --stream-jsonl`)
into a WAL-mode SQLite database with automatic matched-pair regression alerts.

All runtime state is stored strictly outside the git/jj repository under:
  - `/home/sjaconette/sc2-local-arena/continuous_eval/`
  - `/home/sjaconette/sc2-local-arena/snapshots/`

Pure Python 3 stdlib only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Callable


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ARENA_DIR = Path(
    os.environ.get("SC2_LOCAL_ARENA_DIR", "/home/sjaconette/sc2-local-arena")
)
DEFAULT_BENCH_SEED = "mothman-v1"
DEFAULT_ROTATED_BENCH_SEED = "mothman-v1-rot1"
DEFAULT_KEEP_SNAPSHOTS = 6
DEFAULT_LADDER_WORKERS = 6
DEFAULT_TACTICS_WORKERS = 2
DEFAULT_MAX_TOTAL_SC2 = 10
DEFAULT_MAX_LOADAVG = 0.0
DEFAULT_POLL_SEC = 5.0
DEFAULT_TIMEOUT_SEC = 480
DEFAULT_MAX_GAME_TIME = 33600
CHEESE_MAX_GAME_TIME = 16128

MAIN_BOTS = ("Mothman-Z", "Mothman-T", "Mothman-P")
CHEESE_BOTS = ("Mothman-PC", "Mothman-TC", "Mothman-ZC")

ALL_LADDER_TIERS = ("tier1_sentinel", "tier2_full84", "tier3_multiseed")
ALL_TACTICS_TIERS = ("tier1_core_dummy", "tier2_all_dummy", "tier3_core_self")

SNAPSHOT_EXCLUDE_TOP = frozenset({".git", ".jj", "scratch", "__pycache__"})
SC2_CONTAINER_NAME_PREFIXES = ("sc2a-", "sc2-", "tactics-", "mothman-", "ce-sc2-")
SC2_IMAGE_SUBSTRINGS = ("arenaclient", "sc2")

RACE_FROM_BOT = {
    "mothman-z": "Zerg",
    "mothman-zc": "Zerg",
    "mothman-t": "Terran",
    "mothman-tc": "Terran",
    "mothman-p": "Protoss",
    "mothman-pc": "Protoss",
    "mothman-x": "Random",
    "mothman-xc": "Random",
}
RACE_SHORT_TO_FULL = {
    "Z": "Zerg",
    "T": "Terran",
    "P": "Protoss",
    "R": "Random",
    "ZERG": "Zerg",
    "TERRAN": "Terran",
    "PROTOSS": "Protoss",
    "RANDOM": "Random",
}


# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sanitize_token(raw: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", (raw or "").strip()).strip("_.")
    return cleaned or "rev"


def atomic_write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.tmp.{os.getpid()}.{threading.get_ident()}"
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def normalize_cohort(raw: str | None, is_selfplay: bool = False) -> str:
    if is_selfplay:
        return "selfplay"
    tok = (raw or "").strip().lower()
    if tok in ("selfplay", "self_6", "self"):
        return "selfplay"
    if tok in ("core", "core_12", "core_14"):
        return "core"
    if tok in ("unseen", "unseen_6", "unseen_12"):
        return "unseen"
    if tok in ("cheese_radar", "cheese_drill", "cheese"):
        return "cheese_radar"
    return tok or "custom"


def normalize_race_full(raw: str | None, bot_name: str = "") -> str:
    key = (raw or "").strip().upper()
    if key in RACE_SHORT_TO_FULL:
        return RACE_SHORT_TO_FULL[key]
    bkey = (bot_name or "").strip().lower()
    if bkey in RACE_FROM_BOT:
        return RACE_FROM_BOT[bkey]
    return "Unknown"


def normalize_result(raw: str | None) -> str:
    tok = (raw or "").strip().lower()
    if tok in ("win", "victory", "w", "player1win"):
        return "win"
    if tok in ("loss", "defeat", "l", "player2win", "player1crash", "player1timeout"):
        return "loss"
    if tok in ("tie", "draw", "t"):
        return "tie"
    if "win" in tok:
        return "win"
    if "loss" in tok or "crash" in tok or "error" in tok:
        return "loss"
    return tok or "tie"


def normalize_gs_100(raw: Any) -> float | None:
    if raw is None or isinstance(raw, bool):
        return None
    try:
        val = float(raw)
    except (TypeError, ValueError):
        return None
    if 0.0 <= val <= 1.0:
        return round(val * 100.0, 2)
    return round(val, 2)


def safe_float(raw: Any, default: float = 0.0) -> float:
    if raw is None or isinstance(raw, bool):
        return default
    try:
        return float(raw)
    except (TypeError, ValueError):
        return default


def safe_int(raw: Any, default: int = 0) -> int:
    if raw is None:
        return default
    if isinstance(raw, bool):
        return 1 if raw else 0
    if isinstance(raw, (list, tuple, set)):
        return len(raw)
    try:
        return int(float(raw))
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# Dynamic loader for `tools/run-local-sc2-arena.py`
# ---------------------------------------------------------------------------

_ARENA_MOD_CACHE: dict[str, Any] = {}


def load_arena_module(repo_dir: Path = REPO_ROOT) -> Any:
    script = (repo_dir / "tools" / "run-local-sc2-arena.py").resolve()
    if not script.is_file():
        script = (REPO_ROOT / "tools" / "run-local-sc2-arena.py").resolve()
    key = str(script)
    if key in _ARENA_MOD_CACHE:
        return _ARENA_MOD_CACHE[key]
    spec = importlib.util.spec_from_file_location("mothman_local_sc2_arena", script)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load arena runner module from {script}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    _ARENA_MOD_CACHE[key] = mod
    return mod


# ---------------------------------------------------------------------------
# SQLite WAL storage layer
# ---------------------------------------------------------------------------

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS revisions (
    rev_id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    jj_change_id TEXT,
    commit_id TEXT,
    snapshot_dir TEXT,
    baseline_rev_id TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    superseded_at TEXT
);

CREATE TABLE IF NOT EXISTS ladder_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rev_id TEXT NOT NULL,
    tier TEXT NOT NULL,
    priority INTEGER NOT NULL,
    bot TEXT NOT NULL,
    opponent TEXT NOT NULL,
    map_name TEXT NOT NULL,
    random_seed INTEGER NOT NULL DEFAULT 0,
    cohort TEXT NOT NULL DEFAULT 'core',
    p1_mode TEXT NOT NULL DEFAULT 'source',
    p2_mode TEXT NOT NULL DEFAULT 'source',
    p2_alias TEXT DEFAULT '',
    cheese_profile TEXT DEFAULT '',
    status TEXT NOT NULL DEFAULT 'queued',
    worker_id TEXT DEFAULT '',
    started_at TEXT,
    finished_at TEXT,
    attempts INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS ladder_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rev_id TEXT NOT NULL,
    queue_id INTEGER,
    tier TEXT NOT NULL DEFAULT '',
    bot TEXT NOT NULL,
    our_race TEXT NOT NULL,
    opponent TEXT NOT NULL,
    opp_cohort TEXT NOT NULL DEFAULT 'core',
    map_name TEXT NOT NULL DEFAULT '',
    random_seed INTEGER NOT NULL DEFAULT 0,
    result TEXT NOT NULL DEFAULT 'tie',
    state_result TEXT NOT NULL DEFAULT 'tie',
    game_score REAL,
    trade_ratio REAL,
    duration_sec REAL,
    step_avg_ms REAL,
    step_p95_ms REAL,
    crashes INTEGER NOT NULL DEFAULT 0,
    wire_rejects INTEGER NOT NULL DEFAULT 0,
    self_cancel INTEGER NOT NULL DEFAULT 0,
    arbiter_error INTEGER NOT NULL DEFAULT 0,
    own_retreat_ticks INTEGER NOT NULL DEFAULT 0,
    grm_flag INTEGER NOT NULL DEFAULT 0,
    apm_p0_drops INTEGER NOT NULL DEFAULT 0,
    apm_p1_drops INTEGER NOT NULL DEFAULT 0,
    supply_block_pct REAL,
    w6_workers INTEGER,
    replay_path TEXT DEFAULT '',
    log_path TEXT DEFAULT '',
    finished_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tactics_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rev_id TEXT NOT NULL,
    tier TEXT NOT NULL,
    priority INTEGER NOT NULL,
    suite TEXT NOT NULL,
    opponent_mode TEXT NOT NULL,
    shard_index INTEGER NOT NULL,
    shard_count INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    worker_id TEXT DEFAULT '',
    started_at TEXT,
    finished_at TEXT,
    attempts INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS tactics_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rev_id TEXT NOT NULL,
    opponent_mode TEXT NOT NULL,
    scenario_id TEXT NOT NULL,
    category TEXT NOT NULL DEFAULT '',
    terrain TEXT NOT NULL DEFAULT '',
    race TEXT NOT NULL DEFAULT '',
    enemy_race TEXT NOT NULL DEFAULT '',
    passed INTEGER NOT NULL DEFAULT 0,
    trade_ratio REAL,
    win_margin REAL,
    our_surviving_val REAL,
    enemy_surviving_val REAL,
    elapsed_frames INTEGER,
    step_p95_ms REAL,
    finished_at TEXT NOT NULL,
    UNIQUE(rev_id, opponent_mode, scenario_id)
);

CREATE TABLE IF NOT EXISTS alerts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rev_id TEXT NOT NULL,
    baseline_rev_id TEXT DEFAULT '',
    kind TEXT NOT NULL,
    severity TEXT NOT NULL,
    scope TEXT NOT NULL,
    metric TEXT NOT NULL,
    rev_value REAL,
    baseline_value REAL,
    sample_n INTEGER NOT NULL DEFAULT 1,
    detail TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    acknowledged INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_ladder_queue_pick
    ON ladder_queue(status, priority, id);
CREATE INDEX IF NOT EXISTS idx_ladder_queue_rev
    ON ladder_queue(rev_id, status);
CREATE INDEX IF NOT EXISTS idx_ladder_results_rev
    ON ladder_results(rev_id, bot, opponent);
CREATE INDEX IF NOT EXISTS idx_tactics_queue_pick
    ON tactics_queue(status, priority, id);
CREATE INDEX IF NOT EXISTS idx_tactics_queue_rev
    ON tactics_queue(rev_id, status);
CREATE INDEX IF NOT EXISTS idx_tactics_results_rev
    ON tactics_results(rev_id, opponent_mode, category);
CREATE INDEX IF NOT EXISTS idx_alerts_rev
    ON alerts(rev_id, severity, acknowledged);
"""


def open_db(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path), timeout=30.0, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=NORMAL;")
    conn.execute("PRAGMA busy_timeout=15000;")
    conn.execute("PRAGMA foreign_keys=ON;")
    conn.executescript(SCHEMA_SQL)
    conn.commit()
    return conn


# ---------------------------------------------------------------------------
# Immutable Btrfs CoW snapshots + GC
# ---------------------------------------------------------------------------


def probe_vcs_ids(repo_dir: Path) -> dict[str, str]:
    jj_change = ""
    commit_id = ""
    parent_commit = ""

    def _run(cmd: list[str]) -> str:
        try:
            return subprocess.check_output(
                cmd, cwd=repo_dir, stderr=subprocess.DEVNULL, text=True
            ).strip()
        except Exception:
            return ""

    jj_change = _run(["jj", "log", "-r", "@", "--no-graph", "-T", "change_id.short(8)"])
    commit_id = _run(["jj", "log", "-r", "@", "--no-graph", "-T", "commit_id.short(8)"])
    parent_commit = _run(["jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id.short(8)"])

    if not commit_id:
        commit_id = _run(["git", "rev-parse", "--short=8", "HEAD"])
    if not parent_commit:
        parent_commit = _run(["git", "rev-parse", "--short=8", "HEAD~1"])
    if not jj_change:
        jj_change = commit_id or "local"
    if not commit_id:
        commit_id = "unknown"
    return {
        "jj_change_id": jj_change,
        "commit_id": commit_id,
        "parent_commit": parent_commit or "unknown",
    }


def _copy_entry_cow(src: Path, dst: Path) -> None:
    cp_bin = shutil.which("cp")
    if cp_bin:
        proc = subprocess.run(
            [cp_bin, "-a", "--reflink=auto", str(src), str(dst)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        if proc.returncode == 0:
            return
    if src.is_dir():
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst, follow_symlinks=False)


SNAPSHOT_PRECOMPILE_TARGETS = (
    "bots/Mothman-P.rkt",
    "bots/Mothman-T.rkt",
    "bots/Mothman-Z.rkt",
    "bots/Mothman-R.rkt",
    "sim/racket-sc2-ladder-main.rkt",
    "tools/score-replay-batch.rkt",
)


def _prune_snapshot_exclusions(snapshot_dir: Path, prune_zo: bool = True) -> None:
    elf = snapshot_dir / "ladder" / ".cache" / "mothman_standalone_elf"
    if elf.is_file() or elf.is_symlink():
        try:
            elf.unlink()
        except OSError:
            pass
    for root, dirs, files in os.walk(snapshot_dir, topdown=True):
        rpath = Path(root)
        keep_dirs: list[str] = []
        for d in dirs:
            if d in ("__pycache__", ".git", ".jj") or (prune_zo and d == "compiled"):
                shutil.rmtree(rpath / d, ignore_errors=True)
            else:
                keep_dirs.append(d)
        dirs[:] = keep_dirs
        if prune_zo:
            for fname in files:
                if fname.endswith(".zo"):
                    try:
                        (rpath / fname).unlink()
                    except OSError:
                        pass


def _probe_racket_version(racket_bin: Path | str) -> str:
    try:
        out = subprocess.check_output(
            [str(racket_bin), "--version"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        ).strip()
        return out
    except Exception:
        return ""


def _resolve_snapshot_raco(snapshot_dir: Path) -> tuple[str | None, str]:
    portable_bin_dir = snapshot_dir / "ladder" / ".cache" / "racket_runtime" / "bin"
    portable_raco = portable_bin_dir / "raco"
    portable_racket = portable_bin_dir / "racket"
    portable_ver = _probe_racket_version(portable_racket) if portable_racket.is_file() else ""
    if portable_raco.is_file():
        return str(portable_raco), portable_ver
    host_raco = shutil.which("raco")
    if not host_raco:
        return None, ""
    host_racket = Path(host_raco).resolve().parent / "racket"
    host_ver = _probe_racket_version(host_racket if host_racket.is_file() else (shutil.which("racket") or "racket"))
    if portable_ver and host_ver and portable_ver != host_ver:
        raise RuntimeError(
            f"Racket bytecode version mismatch: host raco uses {host_ver!r} "
            f"but portable runtime uses {portable_ver!r}"
        )
    return host_raco, host_ver


def _count_snapshot_zo_files(snapshot_dir: Path) -> int:
    count = 0
    for _root, _dirs, files in os.walk(snapshot_dir):
        for fname in files:
            if fname.endswith(".zo"):
                count += 1
    return count


def precompile_snapshot_bytecode(snapshot_dir: Path, jobs: int = 4) -> int:
    targets = [t for t in SNAPSHOT_PRECOMPILE_TARGETS if (snapshot_dir / t).is_file()]
    if not targets:
        return 0
    raco_bin, _ver = _resolve_snapshot_raco(snapshot_dir)
    if not raco_bin:
        return 0
    env = dict(os.environ)
    env.pop("PLTCOMPILEDROOTS", None)
    cmd = [raco_bin, "make", "-j", str(max(1, int(jobs))), *targets]
    proc = subprocess.run(
        cmd,
        cwd=snapshot_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=300,
    )
    if proc.returncode != 0:
        # Incremental compile hit stale/incompatible .zo: wipe compiled/ inside snapshot and retry clean
        _prune_snapshot_exclusions(snapshot_dir, prune_zo=True)
        proc = subprocess.run(
            cmd,
            cwd=snapshot_dir,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=300,
        )
    if proc.returncode != 0:
        err_tail = (proc.stderr or proc.stdout or "").strip()[-800:]
        raise RuntimeError(f"Snapshot bytecode precompile failed (rc={proc.returncode}): {err_tail}")
    return _count_snapshot_zo_files(snapshot_dir)


def create_repo_snapshot(
    repo_dir: Path,
    snapshots_dir: Path,
    label: str = "",
    explicit_rev_id: str | None = None,
    precompile: bool = True,
    compile_jobs: int = 4,
    clean_compile: bool = False,
) -> dict[str, Any]:
    repo_dir = repo_dir.resolve()
    snapshots_dir = snapshots_dir.resolve()
    snapshots_dir.mkdir(parents=True, exist_ok=True)

    vcs = probe_vcs_ids(repo_dir)
    created_at = utc_now_iso()
    eff_label = sanitize_token(label or f"snap_{vcs['jj_change_id']}")
    if explicit_rev_id:
        base_rev = sanitize_token(explicit_rev_id)
    else:
        base_rev = sanitize_token(f"{eff_label}_{vcs['jj_change_id']}_{vcs['commit_id']}")

    rev_id = base_rev
    dest = snapshots_dir / rev_id
    if dest.exists():
        ts_suffix = dt.datetime.now(dt.timezone.utc).strftime("%H%M%S")
        rev_id = f"{base_rev}_{ts_suffix}"
        dest = snapshots_dir / rev_id
        counter = 1
        while dest.exists():
            counter += 1
            rev_id = f"{base_rev}_{ts_suffix}_{counter}"
            dest = snapshots_dir / rev_id

    staging = snapshots_dir / f".staging_{rev_id}_{os.getpid()}"
    if staging.exists():
        shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True, exist_ok=True)

    try:
        for child in sorted(repo_dir.iterdir()):
            if child.name in SNAPSHOT_EXCLUDE_TOP:
                continue
            _copy_entry_cow(child, staging / child.name)
        has_targets = any((staging / t).is_file() for t in SNAPSHOT_PRECOMPILE_TARGETS)
        prune_zo_first = (not precompile) or clean_compile or (not has_targets)
        _prune_snapshot_exclusions(staging, prune_zo=prune_zo_first)
        zo_count = precompile_snapshot_bytecode(staging, jobs=compile_jobs) if precompile else 0
        meta = {
            "rev_id": rev_id,
            "jj_change_id": vcs["jj_change_id"],
            "commit_id": vcs["commit_id"],
            "label": label or eff_label,
            "created_at": created_at,
            "parent_commit": vcs["parent_commit"],
            "compiled_zo_count": zo_count,
        }
        (staging / ".snapshot_meta.json").write_text(
            json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.replace(staging, dest)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    meta["snapshot_dir"] = str(dest)
    return meta


def gc_snapshots(
    conn: sqlite3.Connection,
    snapshots_dir: Path,
    keep: int = DEFAULT_KEEP_SNAPSHOTS,
) -> list[str]:
    if not snapshots_dir.is_dir():
        return []
    protected_dirs: set[Path] = set()
    rows = conn.execute(
        """
        SELECT DISTINCT r.snapshot_dir
        FROM revisions r
        WHERE r.snapshot_dir IS NOT NULL AND r.snapshot_dir != ''
          AND (
            r.status IN ('active', 'queued', 'running', 'draining')
            OR r.rev_id IN (
                SELECT DISTINCT rev_id FROM ladder_queue WHERE status IN ('queued', 'running')
                UNION
                SELECT DISTINCT rev_id FROM tactics_queue WHERE status IN ('queued', 'running')
                UNION
                SELECT DISTINCT baseline_rev_id FROM revisions
                WHERE baseline_rev_id IS NOT NULL AND baseline_rev_id != ''
                  AND status IN ('active', 'queued', 'running', 'draining')
            )
          )
        """
    ).fetchall()
    for row in rows:
        try:
            protected_dirs.add(Path(row["snapshot_dir"]).resolve())
        except Exception:
            pass

    candidates: list[tuple[str, Path]] = []
    for child in snapshots_dir.iterdir():
        if not child.is_dir() or child.name.startswith("."):
            continue
        meta_path = child / ".snapshot_meta.json"
        if not meta_path.is_file():
            # Never touch snapshots created outside daemon without metadata
            continue
        created = ""
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            created = str(meta.get("created_at") or "")
        except Exception:
            created = ""
        if not created:
            created = dt.datetime.fromtimestamp(
                child.stat().st_mtime, tz=dt.timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
        candidates.append((created, child.resolve()))

    candidates.sort(key=lambda pair: pair[0], reverse=True)
    removed: list[str] = []
    for idx, (_created, path) in enumerate(candidates):
        if idx < keep or path in protected_dirs:
            continue
        shutil.rmtree(path, ignore_errors=True)
        removed.append(str(path))
    return removed


# ---------------------------------------------------------------------------
# Tiered ladder & tactics queue generation
# ---------------------------------------------------------------------------


def parse_tier_selection(raw: str | None) -> tuple[list[str], list[str]]:
    tok = (raw or "all").strip().lower()
    if tok in ("", "all"):
        return list(ALL_LADDER_TIERS), list(ALL_TACTICS_TIERS)
    if tok == "ladder":
        return list(ALL_LADDER_TIERS), []
    if tok == "tactics":
        return [], list(ALL_TACTICS_TIERS)
    if tok == "tier1":
        return ["tier1_sentinel"], ["tier1_core_dummy"]
    if tok == "tier1,tier2":
        return ["tier1_sentinel", "tier2_full84"], ["tier1_core_dummy", "tier2_all_dummy"]

    parts = [p.strip() for p in tok.split(",") if p.strip()]
    l_tiers: list[str] = []
    t_tiers: list[str] = []
    for p in parts:
        if p == "tier1":
            l_tiers.append("tier1_sentinel")
            t_tiers.append("tier1_core_dummy")
        elif p == "tier2":
            l_tiers.append("tier2_full84")
            t_tiers.append("tier2_all_dummy")
        elif p == "tier3":
            l_tiers.append("tier3_multiseed")
            t_tiers.append("tier3_core_self")
        elif p == "ladder":
            l_tiers.extend(ALL_LADDER_TIERS)
        elif p == "tactics":
            t_tiers.extend(ALL_TACTICS_TIERS)
        elif p in ALL_LADDER_TIERS:
            l_tiers.append(p)
        elif p in ALL_TACTICS_TIERS:
            t_tiers.append(p)
        else:
            raise ValueError(
                f"Unknown tier {p!r}. Valid tiers: {list(ALL_LADDER_TIERS + ALL_TACTICS_TIERS)}"
            )
    # Preserve canonical order & deduplicate
    l_out = [t for t in ALL_LADDER_TIERS if t in l_tiers]
    t_out = [t for t in ALL_TACTICS_TIERS if t in t_tiers]
    return l_out, t_out


def build_ladder_tier_items(
    arena_dir: Path,
    repo_dir: Path,
    tiers: list[str],
    mothman_mode: str = "source",
    bench_seed: str = DEFAULT_BENCH_SEED,
    rotated_bench_seed: str = DEFAULT_ROTATED_BENCH_SEED,
    canary_opponents: tuple[str, ...] | None = None,
) -> list[dict[str, Any]]:
    arena_mod = load_arena_module(repo_dir)
    roster = arena_mod.load_roster(arena_dir / "bots")
    maps = arena_mod.discover_maps(arena_dir / "maps", "season")
    if not roster:
        raise RuntimeError(f"No opponents found in {arena_dir / 'bots'}")
    if not maps:
        raise RuntimeError(f"No SC2 maps found in {arena_dir / 'maps'}")

    pair_est, opp_est = arena_mod.load_historical_wall_estimates(arena_dir)
    ci = {k.lower(): k for k in roster}
    wanted_canary = canary_opponents if canary_opponents is not None else arena_mod.CANARY_6_OPPONENTS
    canary_names = [ci[name.lower()] for name in wanted_canary if name.lower() in ci]
    if not canary_names:
        # Synthetic test roster fallback: first 6 core opponents (or first 6 sorted)
        core_sorted = sorted(
            [n for n, s in roster.items() if s.gauntlet_core],
            key=lambda n: (roster[n].elo or 0, n),
        )
        all_sorted = sorted(roster.keys(), key=lambda n: (roster[n].elo or 0, n))
        canary_names = (core_sorted if len(core_sorted) >= 6 else all_sorted)[:6]
    canary_set = {n.lower() for n in canary_names}
    all_opps = sorted(roster.keys(), key=lambda n: (roster[n].elo or 0, n))
    non_canary_opps = [n for n in all_opps if n.lower() not in canary_set]

    race_prio = {"Mothman-Z": 0, "Mothman-T": 1, "Mothman-P": 2}

    def _lpt_sort_key(item: dict[str, Any]) -> tuple[Any, ...]:
        eff_opp = item["p2_alias"] or item["opponent"]
        est = arena_mod.estimate_match_wall_sec(item["bot"], eff_opp, pair_est, opp_est)
        return (-est, race_prio.get(item["bot"], 5), eff_opp.lower(), item["bot"])

    out: list[dict[str, Any]] = []

    if "tier1_sentinel" in tiers:
        t1_items: list[dict[str, Any]] = []
        for opp in canary_names:
            coh = "core" if roster[opp].gauntlet_core else "unseen"
            for bot in MAIN_BOTS:
                mp, rseed = arena_mod.deterministic_map_and_seed(bench_seed, bot, opp, 0, maps)
                t1_items.append({
                    "tier": "tier1_sentinel",
                    "priority": 10,
                    "bot": bot,
                    "opponent": opp,
                    "map_name": mp,
                    "random_seed": rseed,
                    "cohort": coh,
                    "p1_mode": mothman_mode,
                    "p2_mode": mothman_mode,
                    "p2_alias": "",
                    "cheese_profile": "",
                })
        for sp_i, (p1_var, p2_var) in enumerate(arena_mod.build_selfplay_pairs(6)):
            p2_alias = f"{p2_var}-Base"
            mp, rseed = arena_mod.deterministic_map_and_seed(bench_seed, p1_var, p2_alias, sp_i, maps)
            t1_items.append({
                "tier": "tier1_sentinel",
                "priority": 10,
                "bot": p1_var,
                "opponent": p2_var,
                "map_name": mp,
                "random_seed": rseed,
                "cohort": "selfplay",
                "p1_mode": mothman_mode,
                "p2_mode": "zip",
                "p2_alias": p2_alias,
                "cheese_profile": "",
            })
        t1_items.sort(key=_lpt_sort_key)
        out.extend(t1_items)

    if "tier2_full84" in tiers:
        t2_items: list[dict[str, Any]] = []
        for opp in non_canary_opps:
            coh = "core" if roster[opp].gauntlet_core else "unseen"
            for bot in MAIN_BOTS:
                mp, rseed = arena_mod.deterministic_map_and_seed(bench_seed, bot, opp, 0, maps)
                t2_items.append({
                    "tier": "tier2_full84",
                    "priority": 20,
                    "bot": bot,
                    "opponent": opp,
                    "map_name": mp,
                    "random_seed": rseed,
                    "cohort": coh,
                    "p1_mode": mothman_mode,
                    "p2_mode": mothman_mode,
                    "p2_alias": "",
                    "cheese_profile": "",
                })
        t2_items.sort(key=_lpt_sort_key)
        out.extend(t2_items)

    if "tier3_multiseed" in tiers:
        t3_rot: list[dict[str, Any]] = []
        for opp in all_opps:
            coh = "core" if roster[opp].gauntlet_core else "unseen"
            for bot in MAIN_BOTS:
                mp, rseed = arena_mod.deterministic_map_and_seed(
                    rotated_bench_seed, bot, opp, 1, maps
                )
                t3_rot.append({
                    "tier": "tier3_multiseed",
                    "priority": 30,
                    "bot": bot,
                    "opponent": opp,
                    "map_name": mp,
                    "random_seed": rseed,
                    "cohort": coh,
                    "p1_mode": mothman_mode,
                    "p2_mode": mothman_mode,
                    "p2_alias": "",
                    "cheese_profile": "",
                })
        t3_rot.sort(key=_lpt_sort_key)
        out.extend(t3_rot)

        t3_cheese: list[dict[str, Any]] = []
        for opp in all_opps:
            for cbot in CHEESE_BOTS:
                mp, rseed = arena_mod.deterministic_map_and_seed(bench_seed, cbot, opp, 0, maps)
                t3_cheese.append({
                    "tier": "tier3_multiseed",
                    "priority": 31,
                    "bot": cbot,
                    "opponent": opp,
                    "map_name": mp,
                    "random_seed": rseed,
                    "cohort": "cheese_radar",
                    "p1_mode": mothman_mode,
                    "p2_mode": mothman_mode,
                    "p2_alias": "",
                    "cheese_profile": "auto",
                })
        t3_cheese.sort(key=_lpt_sort_key)
        out.extend(t3_cheese)

    return out


def build_tactics_tier_items(tiers: list[str]) -> list[dict[str, Any]]:
    specs = {
        "tier1_core_dummy": (10, "core", "dummy", 6),
        "tier2_all_dummy": (20, "all", "dummy", 12),
        "tier3_core_self": (30, "core", "self", 6),
    }
    out: list[dict[str, Any]] = []
    for tier in tiers:
        if tier not in specs:
            continue
        prio, suite, opp_mode, scount = specs[tier]
        for sidx in range(scount):
            out.append({
                "tier": tier,
                "priority": prio,
                "suite": suite,
                "opponent_mode": opp_mode,
                "shard_index": sidx,
                "shard_count": scount,
            })
    return out


def enqueue_revision(
    conn: sqlite3.Connection,
    repo_dir: Path,
    arena_dir: Path,
    state_dir: Path,
    snapshots_dir: Path,
    label: str = "",
    baseline_rev_id: str | None = None,
    tiers_spec: str = "all",
    preempt: bool = True,
    mothman_mode: str = "source",
    bench_seed: str = DEFAULT_BENCH_SEED,
    snapshot_meta: dict[str, Any] | None = None,
    keep_snapshots: int = DEFAULT_KEEP_SNAPSHOTS,
    canary_opponents: tuple[str, ...] | None = None,
    precompile: bool = True,
    compile_jobs: int = 4,
) -> dict[str, Any]:
    l_tiers, t_tiers = parse_tier_selection(tiers_spec)
    meta = snapshot_meta or create_repo_snapshot(
        repo_dir,
        snapshots_dir,
        label=label,
        precompile=precompile,
        compile_jobs=compile_jobs,
    )
    rev_id = meta["rev_id"]
    now_iso = utc_now_iso()

    eff_baseline = baseline_rev_id or ""
    if not eff_baseline:
        row = conn.execute(
            """
            SELECT rev_id FROM revisions
            WHERE rev_id != ? AND status IN ('baseline', 'active', 'completed', 'superseded')
            ORDER BY CASE WHEN status = 'baseline' THEN 0 ELSE 1 END, created_at DESC
            LIMIT 1
            """,
            (rev_id,),
        ).fetchone()
        if row:
            eff_baseline = str(row["rev_id"])

    ladder_items = (
        build_ladder_tier_items(
            arena_dir=arena_dir,
            repo_dir=repo_dir,
            tiers=l_tiers,
            mothman_mode=mothman_mode,
            bench_seed=bench_seed,
            canary_opponents=canary_opponents,
        )
        if l_tiers
        else []
    )
    tactics_items = build_tactics_tier_items(t_tiers) if t_tiers else []

    superseded_ladder = 0
    superseded_tactics = 0
    with conn:
        if preempt:
            cur = conn.execute(
                "UPDATE ladder_queue SET status = 'superseded', finished_at = ? "
                "WHERE rev_id != ? AND status = 'queued'",
                (now_iso, rev_id),
            )
            superseded_ladder = cur.rowcount
            cur = conn.execute(
                "UPDATE tactics_queue SET status = 'superseded', finished_at = ? "
                "WHERE rev_id != ? AND status = 'queued'",
                (now_iso, rev_id),
            )
            superseded_tactics = cur.rowcount
            conn.execute(
                """
                UPDATE revisions
                SET status = CASE
                    WHEN EXISTS (
                        SELECT 1 FROM ladder_queue lq
                        WHERE lq.rev_id = revisions.rev_id AND lq.status = 'running'
                    ) OR EXISTS (
                        SELECT 1 FROM tactics_queue tq
                        WHERE tq.rev_id = revisions.rev_id AND tq.status = 'running'
                    ) THEN 'draining'
                    ELSE 'superseded'
                END,
                superseded_at = COALESCE(superseded_at, ?)
                WHERE rev_id != ? AND status IN ('active', 'queued', 'running', 'draining')
                """,
                (now_iso, rev_id),
            )

        conn.execute(
            """
            INSERT OR REPLACE INTO revisions
                (rev_id, label, jj_change_id, commit_id, snapshot_dir,
                 baseline_rev_id, status, created_at, superseded_at)
            VALUES (?, ?, ?, ?, ?, ?, 'active', ?, NULL)
            """,
            (
                rev_id,
                str(meta.get("label") or label or rev_id),
                str(meta.get("jj_change_id") or ""),
                str(meta.get("commit_id") or ""),
                str(meta.get("snapshot_dir") or ""),
                eff_baseline,
                str(meta.get("created_at") or now_iso),
            ),
        )

        if ladder_items:
            conn.executemany(
                """
                INSERT INTO ladder_queue
                    (rev_id, tier, priority, bot, opponent, map_name, random_seed,
                     cohort, p1_mode, p2_mode, p2_alias, cheese_profile, status, attempts)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', 0)
                """,
                [
                    (
                        rev_id,
                        it["tier"],
                        it["priority"],
                        it["bot"],
                        it["opponent"],
                        it["map_name"],
                        it["random_seed"],
                        it["cohort"],
                        it["p1_mode"],
                        it["p2_mode"],
                        it["p2_alias"],
                        it["cheese_profile"],
                    )
                    for it in ladder_items
                ],
            )

        if tactics_items:
            conn.executemany(
                """
                INSERT INTO tactics_queue
                    (rev_id, tier, priority, suite, opponent_mode,
                     shard_index, shard_count, status, attempts)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'queued', 0)
                """,
                [
                    (
                        rev_id,
                        it["tier"],
                        it["priority"],
                        it["suite"],
                        it["opponent_mode"],
                        it["shard_index"],
                        it["shard_count"],
                    )
                    for it in tactics_items
                ],
            )

    gc_removed = gc_snapshots(conn, snapshots_dir, keep=keep_snapshots)
    write_live_state_files(conn, state_dir)

    return {
        "rev_id": rev_id,
        "label": str(meta.get("label") or label or rev_id),
        "snapshot_dir": str(meta.get("snapshot_dir") or ""),
        "baseline_rev_id": eff_baseline,
        "ladder_queued": len(ladder_items),
        "tactics_queued": len(tactics_items),
        "superseded_ladder": superseded_ladder,
        "superseded_tactics": superseded_tactics,
        "gc_removed": gc_removed,
    }


# ---------------------------------------------------------------------------
# Baseline seeding from real R27/R28 score JSONs & tactics JSONs
# ---------------------------------------------------------------------------


def _extract_tactics_row(
    rec: dict[str, Any],
    rev_id: str,
    default_opp_mode: str = "dummy",
    finished_at: str | None = None,
) -> dict[str, Any] | None:
    sid = str(rec.get("scenario_id") or rec.get("id") or "").strip()
    if not sid:
        return None
    opp_mode = str(rec.get("opponent_mode") or default_opp_mode or "dummy").strip()
    if "passed" in rec and rec["passed"] is not None:
        passed = 1 if bool(rec["passed"]) else 0
    else:
        winner = str(rec.get("winner") or "").strip()
        passed = 1 if winner in ("Mothman", "Mothman-P1", "P1") else 0
    trade = safe_float(rec.get("trade_ratio", rec.get("p1_trade_ratio")), 0.0)
    our_surv = rec.get("our_surviving_val")
    enemy_surv = rec.get("enemy_surviving_val")
    p1_lost = safe_float(rec.get("p1_lost_val"), 0.0)
    p2_lost = safe_float(rec.get("p2_lost_val"), 0.0)
    if our_surv is None and enemy_surv is None and ("p1_lost_val" in rec or "p2_lost_val" in rec):
        win_margin = safe_float(rec.get("win_margin"), round(p2_lost - p1_lost, 1))
    else:
        our_s = safe_float(our_surv, 0.0)
        en_s = safe_float(enemy_surv, 0.0)
        win_margin = safe_float(rec.get("win_margin"), round(our_s - en_s, 1))
    return {
        "rev_id": rev_id,
        "opponent_mode": opp_mode,
        "scenario_id": sid,
        "category": str(rec.get("category") or ""),
        "terrain": str(rec.get("terrain") or "open"),
        "race": str(rec.get("race") or ""),
        "enemy_race": str(rec.get("enemy_race") or ""),
        "passed": passed,
        "trade_ratio": round(trade, 4),
        "win_margin": round(win_margin, 2),
        "our_surviving_val": safe_float(our_surv, 0.0) if our_surv is not None else None,
        "enemy_surviving_val": safe_float(enemy_surv, 0.0) if enemy_surv is not None else None,
        "elapsed_frames": safe_int(
            rec.get("elapsed_frames", rec.get("loops_simulated")), 0
        ),
        "step_p95_ms": safe_float(rec.get("step_p95_ms"), 0.0)
        if rec.get("step_p95_ms") is not None
        else None,
        "finished_at": finished_at or utc_now_iso(),
    }


def _load_summary_lookup(summary_path: Path | None) -> dict[tuple[str, str], dict[str, Any]]:
    lookup: dict[tuple[str, str], dict[str, Any]] = {}
    if not summary_path or not summary_path.is_file():
        return lookup
    try:
        doc = json.loads(summary_path.read_text(encoding="utf-8"))
        for m in doc.get("matches") or []:
            if not isinstance(m, dict):
                continue
            b1 = str(m.get("bot1") or "").strip()
            b2 = str(m.get("bot2") or "").strip()
            if b1 and b2:
                lookup[(b1, b2)] = m
    except Exception:
        pass
    return lookup


def seed_baseline(
    conn: sqlite3.Connection,
    rev_id: str,
    label: str = "",
    from_score_json: Path | None = None,
    from_summary_json: Path | None = None,
    from_tactics_json: Path | None = None,
    opponent_mode: str = "dummy",
    state_dir: Path | None = None,
) -> dict[str, Any]:
    now_iso = utc_now_iso()
    ladder_inserted = 0
    tactics_inserted = 0

    with conn:
        conn.execute(
            """
            INSERT INTO revisions
                (rev_id, label, jj_change_id, commit_id, snapshot_dir,
                 baseline_rev_id, status, created_at, superseded_at)
            VALUES (?, ?, '', '', '', '', 'baseline', ?, NULL)
            ON CONFLICT(rev_id) DO UPDATE SET
                label = COALESCE(NULLIF(excluded.label, ''), revisions.label)
            """,
            (rev_id, label or rev_id, now_iso),
        )

        if from_score_json is not None:
            score_doc = json.loads(from_score_json.read_text(encoding="utf-8"))
            sib_summary = from_summary_json
            if sib_summary is None:
                cand = from_score_json.parent / "summary.json"
                if cand.is_file():
                    sib_summary = cand
            summary_map = _load_summary_lookup(sib_summary)
            conn.execute("DELETE FROM ladder_results WHERE rev_id = ?", (rev_id,))
            for m in score_doc.get("matches") or []:
                if not isinstance(m, dict):
                    continue
                bot = str(m.get("our_bot") or m.get("bot1") or "").strip()
                opp = str(m.get("opp_bot") or m.get("bot2") or "").strip()
                if not bot or not opp:
                    continue
                our_race = normalize_race_full(m.get("our_race"), bot)
                opp_cohort = normalize_cohort(
                    m.get("opp_cohort") or m.get("cohort"),
                    is_selfplay=bool(m.get("is_selfplay", False)),
                )
                s_rec = summary_map.get((bot, opp), {})
                apm = s_rec.get("apm_cap_drops")
                if not isinstance(apm, dict):
                    telem = s_rec.get("our_telemetry")
                    if isinstance(telem, dict) and isinstance(telem.get("apm_cap_drops"), dict):
                        apm = telem["apm_cap_drops"]
                by_tier = apm.get("by_tier", {}) if isinstance(apm, dict) else {}
                apm_p0 = safe_int(by_tier.get("P0", by_tier.get("p0", 0)), 0)
                apm_p1 = safe_int(by_tier.get("P1", by_tier.get("p1", 0)), 0)
                self_cancel = _extract_self_cancel_count(m)
                arbiter_err = safe_int(m.get("arbiter_error", 0), 0)
                crashes = safe_int(m.get("crashes", 0), 0)
                wire_rej = safe_int(m.get("action_rejects", m.get("wire_rejects", 0)), 0)
                own_ret = safe_int(m.get("own_base_retreat_ticks", m.get("own_retreat_ticks", 0)), 0)
                grm = 1 if bool(m.get("gas_rich_min_starved", m.get("grm_flag", False))) else 0
                gs = normalize_gs_100(m.get("game_state_score", m.get("game_score")))
                res = normalize_result(m.get("result") or s_rec.get("outcome"))
                state_res = normalize_result(
                    m.get("state_outcome") or m.get("adjudicated_outcome") or res
                )
                conn.execute(
                    """
                    INSERT INTO ladder_results
                        (rev_id, queue_id, tier, bot, our_race, opponent, opp_cohort,
                         map_name, random_seed, result, state_result, game_score,
                         trade_ratio, duration_sec, step_avg_ms, step_p95_ms,
                         crashes, wire_rejects, self_cancel, arbiter_error,
                         own_retreat_ticks, grm_flag, apm_p0_drops, apm_p1_drops,
                         supply_block_pct, w6_workers, replay_path, log_path, finished_at)
                    VALUES (?, NULL, 'baseline', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        rev_id,
                        bot,
                        our_race,
                        opp,
                        opp_cohort,
                        str(m.get("map_canon") or m.get("map_name") or s_rec.get("map") or ""),
                        safe_int(s_rec.get("random_seed", m.get("random_seed", 0)), 0),
                        res,
                        state_res,
                        gs,
                        safe_float(m.get("trade_ratio"), 0.0),
                        safe_float(m.get("duration_sec"), 0.0),
                        safe_float(m.get("avg_step_ms", s_rec.get("bot1_avg_step_ms")), 0.0),
                        safe_float(m.get("p95_step_ms", m.get("step_p95")), 0.0),
                        crashes,
                        wire_rej,
                        self_cancel,
                        arbiter_err,
                        own_ret,
                        grm,
                        apm_p0,
                        apm_p1,
                        safe_float(m.get("supply_block_pct"), 0.0),
                        safe_int(m.get("our_w6", m.get("w6_workers")), 0)
                        if (m.get("our_w6") is not None or m.get("w6_workers") is not None)
                        else None,
                        str(s_rec.get("replay_path") or m.get("file") or ""),
                        str(s_rec.get("our_log_path") or ""),
                        now_iso,
                    ),
                )
                ladder_inserted += 1

        if from_tactics_json is not None:
            tdoc = json.loads(from_tactics_json.read_text(encoding="utf-8"))
            eff_mode = str(tdoc.get("opponent_mode") or tdoc.get("opponent") or opponent_mode or "dummy")
            scenarios = tdoc.get("scenarios") or tdoc.get("results") or []
            for rec in scenarios:
                if not isinstance(rec, dict):
                    continue
                row = _extract_tactics_row(rec, rev_id, default_opp_mode=eff_mode, finished_at=now_iso)
                if row is None:
                    continue
                upsert_tactics_result(conn, row)
                tactics_inserted += 1

    if state_dir is not None:
        write_live_state_files(conn, state_dir)

    return {
        "rev_id": rev_id,
        "ladder_inserted": ladder_inserted,
        "tactics_inserted": tactics_inserted,
    }


def upsert_tactics_result(conn: sqlite3.Connection, row: dict[str, Any]) -> None:
    conn.execute(
        """
        INSERT INTO tactics_results
            (rev_id, opponent_mode, scenario_id, category, terrain, race, enemy_race,
             passed, trade_ratio, win_margin, our_surviving_val, enemy_surviving_val,
             elapsed_frames, step_p95_ms, finished_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(rev_id, opponent_mode, scenario_id) DO UPDATE SET
            category = excluded.category,
            terrain = excluded.terrain,
            race = excluded.race,
            enemy_race = excluded.enemy_race,
            passed = excluded.passed,
            trade_ratio = excluded.trade_ratio,
            win_margin = excluded.win_margin,
            our_surviving_val = excluded.our_surviving_val,
            enemy_surviving_val = excluded.enemy_surviving_val,
            elapsed_frames = excluded.elapsed_frames,
            step_p95_ms = excluded.step_p95_ms,
            finished_at = excluded.finished_at
        """,
        (
            row["rev_id"],
            row["opponent_mode"],
            row["scenario_id"],
            row["category"],
            row["terrain"],
            row["race"],
            row["enemy_race"],
            row["passed"],
            row["trade_ratio"],
            row["win_margin"],
            row["our_surviving_val"],
            row["enemy_surviving_val"],
            row["elapsed_frames"],
            row["step_p95_ms"],
            row["finished_at"],
        ),
    )


# ---------------------------------------------------------------------------
# Log parsing & fast per-match scoring
# ---------------------------------------------------------------------------

STEP_TIMING_RE = re.compile(
    r"avg_step_ms=([0-9.]+)|p95_step_ms=([0-9.]+)|step_p95=([0-9.]+)"
)
SCBOT_OP_RE = re.compile(r"\[SCBOT_OP\].*?\bmode=([A-Za-z0-9_-]+)")
SELF_CANCEL_KV_RE = re.compile(r"\bself[-_]cancel(?:_loops?)?\s*[:=]\s*(\d+)", re.IGNORECASE)
ARBITER_ERR_KV_RE = re.compile(r"\barbiter[-_]err(?:or)?s?\s*[:=]\s*(\d+)", re.IGNORECASE)


def _extract_self_cancel_count(match_doc: dict[str, Any]) -> int:
    anom = match_doc.get("anomalies") if isinstance(match_doc.get("anomalies"), dict) else {}
    if "self_cancel_loops" in anom:
        raw_loops = anom.get("self_cancel_loops")
        if isinstance(raw_loops, (list, tuple)):
            return len(raw_loops)
        return safe_int(raw_loops, 0)
    if "self_cancel" in match_doc and match_doc["self_cancel"] is not None:
        return safe_int(match_doc.get("self_cancel"), 0)
    return safe_int(anom.get("self_cancel_loop", 0), 0)


def parse_match_log_telemetry(log_path: Path | None, summary_match: dict[str, Any] | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {
        "crashes": 0,
        "wire_rejects": 0,
        "self_cancel": 0,
        "arbiter_error": 0,
        "step_avg_ms": 0.0,
        "step_p95_ms": 0.0,
        "apm_p0_drops": 0,
        "apm_p1_drops": 0,
        "op_modes": {},
    }
    srec = summary_match if isinstance(summary_match, dict) else {}
    telem = srec.get("our_telemetry") if isinstance(srec.get("our_telemetry"), dict) else {}
    if telem:
        out["step_avg_ms"] = safe_float(telem.get("avg_step_ms"), 0.0)
        out["step_p95_ms"] = safe_float(telem.get("p95_step_ms"), 0.0)
        out["wire_rejects"] = safe_int(
            telem.get("bot_action_reject_count", telem.get("wire_action_drop_count", 0)), 0
        )
    if srec.get("bot1_avg_step_ms") and not out["step_avg_ms"]:
        out["step_avg_ms"] = safe_float(srec.get("bot1_avg_step_ms"), 0.0)

    apm = srec.get("apm_cap_drops")
    if not isinstance(apm, dict) and isinstance(telem.get("apm_cap_drops"), dict):
        apm = telem["apm_cap_drops"]
    if isinstance(apm, dict):
        bt = apm.get("by_tier", {}) if isinstance(apm.get("by_tier"), dict) else {}
        out["apm_p0_drops"] = safe_int(bt.get("P0", bt.get("p0", 0)), 0)
        out["apm_p1_drops"] = safe_int(bt.get("P1", bt.get("p1", 0)), 0)

    if log_path and log_path.is_file():
        arena_mod = None
        try:
            arena_mod = load_arena_module()
        except Exception:
            arena_mod = None
        try:
            text = log_path.read_text(encoding="utf-8", errors="replace")
        except Exception:
            text = ""
        op_counts: dict[str, int] = {}
        for line in text.splitlines():
            low = line.lower()
            if "[scbot_crash]" in low or "uncaught exception" in low or "exn:fail" in low:
                out["crashes"] += 1
            if "self_cancel" in low or "self-cancel" in low:
                m_sc = SELF_CANCEL_KV_RE.search(line)
                if m_sc:
                    sc_val = int(m_sc.group(1))
                    if sc_val > 0:
                        out["self_cancel"] += sc_val
                elif (
                    "[self_cancel" in low
                    or "[self-cancel" in low
                    or "self_cancel_loop" in low
                    or "self-cancel loop" in low
                    or "self_cancel detected" in low
                ):
                    out["self_cancel"] += 1
            if "arbiter_error" in low or "arbiter-error" in low or "arbiter error" in low:
                m_ae = ARBITER_ERR_KV_RE.search(line)
                if m_ae:
                    ae_val = int(m_ae.group(1))
                    if ae_val > 0:
                        out["arbiter_error"] += ae_val
                elif (
                    "[arbiter_error]" in low
                    or "[arbiter-error]" in low
                    or "arbiter error" in low
                ):
                    out["arbiter_error"] += 1
            if "[apm_cap_drops]" in low and arena_mod is not None:
                parsed = arena_mod.parse_apm_cap_drops_line(line)
                if isinstance(parsed, dict):
                    bt = parsed.get("by_tier", {})
                    out["apm_p0_drops"] = max(out["apm_p0_drops"], safe_int(bt.get("P0", 0), 0))
                    out["apm_p1_drops"] = max(out["apm_p1_drops"], safe_int(bt.get("P1", 0), 0))
            m_op = SCBOT_OP_RE.search(line)
            if m_op:
                mode_tok = m_op.group(1)
                op_counts[mode_tok] = op_counts.get(mode_tok, 0) + 1
            if out["step_p95_ms"] == 0.0:
                for tm in STEP_TIMING_RE.finditer(line):
                    if tm.group(1) and out["step_avg_ms"] == 0.0:
                        out["step_avg_ms"] = safe_float(tm.group(1), 0.0)
                    if tm.group(2):
                        out["step_p95_ms"] = safe_float(tm.group(2), 0.0)
                    elif tm.group(3):
                        out["step_p95_ms"] = safe_float(tm.group(3), 0.0)
        out["op_modes"] = op_counts

    if str(srec.get("raw_result") or "").lower() in ("player1crash", "crash", "error"):
        out["crashes"] = max(1, out["crashes"])
    return out


# ---------------------------------------------------------------------------
# Streaming matched-pair regression detector
# ---------------------------------------------------------------------------


def _upsert_alert(
    conn: sqlite3.Connection,
    rev_id: str,
    baseline_rev_id: str,
    kind: str,
    severity: str,
    scope: str,
    metric: str,
    rev_value: float | None,
    baseline_value: float | None,
    sample_n: int,
    detail: str,
) -> dict[str, Any]:
    now_iso = utc_now_iso()
    existing = conn.execute(
        """
        SELECT id FROM alerts
        WHERE rev_id = ? AND kind = ? AND scope = ? AND metric = ? AND acknowledged = 0
        ORDER BY id DESC LIMIT 1
        """,
        (rev_id, kind, scope, metric),
    ).fetchone()
    if existing:
        conn.execute(
            """
            UPDATE alerts
            SET baseline_rev_id = ?, severity = ?, rev_value = ?, baseline_value = ?,
                sample_n = ?, detail = ?, created_at = ?
            WHERE id = ?
            """,
            (
                baseline_rev_id,
                severity,
                rev_value,
                baseline_value,
                sample_n,
                detail,
                now_iso,
                int(existing["id"]),
            ),
        )
        aid = int(existing["id"])
    else:
        cur = conn.execute(
            """
            INSERT INTO alerts
                (rev_id, baseline_rev_id, kind, severity, scope, metric,
                 rev_value, baseline_value, sample_n, detail, created_at, acknowledged)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            """,
            (
                rev_id,
                baseline_rev_id,
                kind,
                severity,
                scope,
                metric,
                rev_value,
                baseline_value,
                sample_n,
                detail,
                now_iso,
            ),
        )
        aid = int(cur.lastrowid)
    return {
        "id": aid,
        "rev_id": rev_id,
        "baseline_rev_id": baseline_rev_id,
        "kind": kind,
        "severity": severity,
        "scope": scope,
        "metric": metric,
        "rev_value": rev_value,
        "baseline_value": baseline_value,
        "sample_n": sample_n,
        "detail": detail,
        "created_at": now_iso,
    }


def _get_revision_baseline(conn: sqlite3.Connection, rev_id: str) -> str:
    row = conn.execute(
        "SELECT baseline_rev_id FROM revisions WHERE rev_id = ?", (rev_id,)
    ).fetchone()
    if row and row["baseline_rev_id"]:
        return str(row["baseline_rev_id"])
    return ""


def _latest_ladder_by_pair(
    conn: sqlite3.Connection,
    rev_id: str,
    exclude_cheese: bool = True,
) -> dict[tuple[str, str], dict[str, Any]]:
    rows = conn.execute(
        """
        SELECT * FROM ladder_results
        WHERE rev_id = ?
        ORDER BY id ASC
        """,
        (rev_id,),
    ).fetchall()
    by_pair: dict[tuple[str, str], dict[str, Any]] = {}
    for r in rows:
        d = dict(r)
        if exclude_cheese and d.get("opp_cohort") == "cheese_radar":
            continue
        key = (str(d["bot"]), str(d["opponent"]))
        by_pair[key] = d
    return by_pair


def evaluate_ladder_alerts(
    conn: sqlite3.Connection,
    rev_id: str,
    latest_row: dict[str, Any] | None = None,
    baseline_rev_id: str | None = None,
) -> list[dict[str, Any]]:
    fired: list[dict[str, Any]] = []
    base_rev = baseline_rev_id if baseline_rev_id is not None else _get_revision_baseline(conn, rev_id)

    # 1. Instant hard-fault alerts on the newly completed match
    if latest_row is not None:
        match_scope = f"{latest_row['bot']}_vs_{latest_row['opponent']}"
        for col, kind in (
            ("crashes", "hard_fault"),
            ("wire_rejects", "hard_fault"),
            ("self_cancel", "hard_fault"),
            ("arbiter_error", "hard_fault"),
        ):
            val = safe_int(latest_row.get(col), 0)
            if val > 0:
                fired.append(
                    _upsert_alert(
                        conn,
                        rev_id=rev_id,
                        baseline_rev_id=base_rev,
                        kind=kind,
                        severity="critical",
                        scope=match_scope,
                        metric=col,
                        rev_value=float(val),
                        baseline_value=0.0,
                        sample_n=1,
                        detail=f"Instant fault {col}={val} in {match_scope} on {latest_row.get('map_name', '')}",
                    )
                )
        p95 = safe_float(latest_row.get("step_p95_ms"), 0.0)
        if p95 > 40.0:
            sev = "critical" if p95 > 60.0 else "warning"
            fired.append(
                _upsert_alert(
                    conn,
                    rev_id=rev_id,
                    baseline_rev_id=base_rev,
                    kind="perf_fault",
                    severity=sev,
                    scope=match_scope,
                    metric="step_p95_ms",
                    rev_value=round(p95, 2),
                    baseline_value=40.0,
                    sample_n=1,
                    detail=f"Step p95 latency {p95:.2f}ms > 40.0ms in {match_scope}",
                )
            )

    if not base_rev:
        return fired

    rev_map = _latest_ladder_by_pair(conn, rev_id, exclude_cheese=True)
    base_map = _latest_ladder_by_pair(conn, base_rev, exclude_cheese=True)
    matched: list[tuple[dict[str, Any], dict[str, Any]]] = [
        (rev_map[k], base_map[k]) for k in sorted(rev_map.keys()) if k in base_map
    ]
    if not matched:
        return fired

    def _check_group(scope: str, pairs: list[tuple[dict[str, Any], dict[str, Any]]], is_race: bool) -> None:
        n = len(pairs)
        if n < 4:
            return
        # ownRet >= 2x baseline & >= 4 ticks on n >= 4
        rev_own_sum = sum(safe_int(r.get("own_retreat_ticks"), 0) for r, _ in pairs)
        base_own_sum = sum(safe_int(b.get("own_retreat_ticks"), 0) for _, b in pairs)
        if rev_own_sum >= 4 and (
            (base_own_sum == 0 and rev_own_sum >= 4)
            or (base_own_sum > 0 and rev_own_sum >= 2.0 * base_own_sum)
        ):
            fired.append(
                _upsert_alert(
                    conn,
                    rev_id=rev_id,
                    baseline_rev_id=base_rev,
                    kind="physics_regression",
                    severity="critical" if rev_own_sum >= 10 else "warning",
                    scope=scope,
                    metric="own_retreat_ticks",
                    rev_value=float(rev_own_sum),
                    baseline_value=float(base_own_sum),
                    sample_n=n,
                    detail=(
                        f"{scope} ownRet spiked {base_own_sum} -> {rev_own_sum} ticks "
                        f"over n={n} matched games"
                    ),
                )
            )

        # GRM rate +15pp overall / +25pp per-race on n >= 4
        rev_grm_rate = sum(1 for r, _ in pairs if safe_int(r.get("grm_flag"), 0) > 0) / n
        base_grm_rate = sum(1 for _, b in pairs if safe_int(b.get("grm_flag"), 0) > 0) / n
        grm_delta = rev_grm_rate - base_grm_rate
        grm_thresh = 0.25 if is_race else 0.15
        if grm_delta >= grm_thresh - 1e-9:
            fired.append(
                _upsert_alert(
                    conn,
                    rev_id=rev_id,
                    baseline_rev_id=base_rev,
                    kind="econ_regression",
                    severity="warning",
                    scope=scope,
                    metric="grm_rate",
                    rev_value=round(rev_grm_rate * 100.0, 1),
                    baseline_value=round(base_grm_rate * 100.0, 1),
                    sample_n=n,
                    detail=(
                        f"{scope} GRM rate spiked {base_grm_rate*100:.1f}% -> "
                        f"{rev_grm_rate*100:.1f}% (+{grm_delta*100:.1f}pp, n={n})"
                    ),
                )
            )

        # APM P0 >= 2.5x baseline & >= 20/game on n >= 4
        rev_p0_avg = sum(safe_int(r.get("apm_p0_drops"), 0) for r, _ in pairs) / n
        base_p0_avg = sum(safe_int(b.get("apm_p0_drops"), 0) for _, b in pairs) / n
        if rev_p0_avg >= 20.0 and (
            base_p0_avg == 0.0 or rev_p0_avg >= 2.5 * base_p0_avg
        ):
            fired.append(
                _upsert_alert(
                    conn,
                    rev_id=rev_id,
                    baseline_rev_id=base_rev,
                    kind="apm_regression",
                    severity="warning",
                    scope=scope,
                    metric="apm_p0_drops",
                    rev_value=round(rev_p0_avg, 2),
                    baseline_value=round(base_p0_avg, 2),
                    sample_n=n,
                    detail=(
                        f"{scope} APM P0 drops spiked {base_p0_avg:.1f} -> "
                        f"{rev_p0_avg:.1f}/game (n={n})"
                    ),
                )
            )

        # Matched-pair GS regression: <= -8.0 overall (n >= 8) or <= -12.0 per-race (n >= 4)
        gs_pairs = [
            (r["game_score"], b["game_score"])
            for r, b in pairs
            if r.get("game_score") is not None and b.get("game_score") is not None
        ]
        min_gs_n = 4 if is_race else 8
        gs_thresh = -12.0 if is_race else -8.0
        if len(gs_pairs) >= min_gs_n:
            rev_gs = sum(x for x, _ in gs_pairs) / len(gs_pairs)
            base_gs = sum(y for _, y in gs_pairs) / len(gs_pairs)
            delta_gs = rev_gs - base_gs
            if delta_gs <= gs_thresh + 1e-9:
                fired.append(
                    _upsert_alert(
                        conn,
                        rev_id=rev_id,
                        baseline_rev_id=base_rev,
                        kind="gs_regression",
                        severity="critical" if delta_gs <= gs_thresh * 1.5 else "warning",
                        scope=scope,
                        metric="game_score",
                        rev_value=round(rev_gs, 2),
                        baseline_value=round(base_gs, 2),
                        sample_n=len(gs_pairs),
                        detail=(
                            f"{scope} matched GS dropped {base_gs:.1f} -> {rev_gs:.1f} "
                            f"({delta_gs:+.1f} GS, n={len(gs_pairs)})"
                        ),
                    )
                )

    _check_group("overall", matched, is_race=False)
    for race in ("Zerg", "Terran", "Protoss"):
        rpairs = [(r, b) for r, b in matched if r.get("our_race") == race]
        if rpairs:
            _check_group(f"race:{race}", rpairs, is_race=True)

    return fired


def evaluate_tactics_alerts(
    conn: sqlite3.Connection,
    rev_id: str,
    latest_row: dict[str, Any] | None = None,
    baseline_rev_id: str | None = None,
) -> list[dict[str, Any]]:
    fired: list[dict[str, Any]] = []
    base_rev = baseline_rev_id if baseline_rev_id is not None else _get_revision_baseline(conn, rev_id)
    if not base_rev:
        return fired

    # 1. Per-scenario checks (PASS -> FAIL flip and >= 25% trade drop where base_trade >= 0.5)
    check_rows: list[dict[str, Any]]
    if latest_row is not None:
        check_rows = [latest_row]
    else:
        check_rows = [
            dict(r)
            for r in conn.execute(
                "SELECT * FROM tactics_results WHERE rev_id = ?", (rev_id,)
            ).fetchall()
        ]

    for r in check_rows:
        brow = conn.execute(
            """
            SELECT * FROM tactics_results
            WHERE rev_id = ? AND opponent_mode = ? AND scenario_id = ?
            """,
            (base_rev, r["opponent_mode"], r["scenario_id"]),
        ).fetchone()
        if not brow:
            continue
        scope = f"{r['opponent_mode']}:{r['scenario_id']}"
        base_passed = safe_int(brow["passed"], 0)
        rev_passed = safe_int(r["passed"], 0)
        if base_passed == 1 and rev_passed == 0:
            fired.append(
                _upsert_alert(
                    conn,
                    rev_id=rev_id,
                    baseline_rev_id=base_rev,
                    kind="tactics_flip",
                    severity="critical",
                    scope=scope,
                    metric="passed",
                    rev_value=0.0,
                    baseline_value=1.0,
                    sample_n=1,
                    detail=(
                        f"Tactical drill PASS -> FAIL: {r['scenario_id']} "
                        f"({r['opponent_mode']}, {r['category']})"
                    ),
                )
            )
        base_trade = safe_float(brow["trade_ratio"], 0.0)
        rev_trade = safe_float(r.get("trade_ratio"), 0.0)
        if base_trade >= 0.5 and rev_trade <= base_trade * 0.75 + 1e-9:
            drop_pct = ((rev_trade - base_trade) / base_trade) * 100.0
            fired.append(
                _upsert_alert(
                    conn,
                    rev_id=rev_id,
                    baseline_rev_id=base_rev,
                    kind="tactics_trade_drop",
                    severity="warning",
                    scope=scope,
                    metric="trade_ratio",
                    rev_value=round(rev_trade, 3),
                    baseline_value=round(base_trade, 3),
                    sample_n=1,
                    detail=(
                        f"Tactical trade drop {base_trade:.2f} -> {rev_trade:.2f} "
                        f"({drop_pct:.1f}%) on {r['scenario_id']}"
                    ),
                )
            )

    # 2. Category pass-rate drop >= 15pp on n >= 3 matched scenarios
    cat_pairs = conn.execute(
        """
        SELECT r.opponent_mode, r.category,
               COUNT(*) AS n,
               AVG(r.passed) AS rev_rate,
               AVG(b.passed) AS base_rate
        FROM tactics_results r
        JOIN tactics_results b
          ON b.rev_id = ?
         AND b.opponent_mode = r.opponent_mode
         AND b.scenario_id = r.scenario_id
        WHERE r.rev_id = ?
        GROUP BY r.opponent_mode, r.category
        HAVING COUNT(*) >= 3
        """,
        (base_rev, rev_id),
    ).fetchall()
    for row in cat_pairs:
        rev_rate = safe_float(row["rev_rate"], 0.0)
        base_rate = safe_float(row["base_rate"], 0.0)
        delta = rev_rate - base_rate
        if delta <= -0.15 + 1e-9:
            scope = f"{row['opponent_mode']}:cat:{row['category'] or 'unknown'}"
            fired.append(
                _upsert_alert(
                    conn,
                    rev_id=rev_id,
                    baseline_rev_id=base_rev,
                    kind="tactics_category_drop",
                    severity="warning",
                    scope=scope,
                    metric="category_pass_rate",
                    rev_value=round(rev_rate * 100.0, 1),
                    baseline_value=round(base_rate * 100.0, 1),
                    sample_n=int(row["n"]),
                    detail=(
                        f"Category {row['category']} ({row['opponent_mode']}) pass rate "
                        f"dropped {base_rate*100:.1f}% -> {rev_rate*100:.1f}% "
                        f"({delta*100:+.1f}pp, n={row['n']})"
                    ),
                )
            )

    return fired


# ---------------------------------------------------------------------------
# Status, Report & Alerts query engine
# ---------------------------------------------------------------------------


def _resolve_target_rev(conn: sqlite3.Connection, rev_id: str | None) -> str | None:
    if rev_id:
        return rev_id
    row = conn.execute(
        """
        SELECT rev_id FROM revisions
        ORDER BY CASE status
            WHEN 'active' THEN 0
            WHEN 'running' THEN 1
            WHEN 'draining' THEN 2
            WHEN 'completed' THEN 3
            WHEN 'superseded' THEN 4
            ELSE 5
        END, created_at DESC
        LIMIT 1
        """
    ).fetchone()
    return str(row["rev_id"]) if row else None


def _summarize_ladder_rows(rows: list[dict[str, Any]]) -> dict[str, Any]:
    n = len(rows)
    if n == 0:
        return {
            "n": 0,
            "wins": 0,
            "losses": 0,
            "ties": 0,
            "win_rate_pct": 0.0,
            "mean_gs": None,
            "own_retreat_ticks": 0,
            "grm_count": 0,
            "grm_rate_pct": 0.0,
            "apm_p0_avg": 0.0,
            "crashes": 0,
            "wire_rejects": 0,
        }
    wins = sum(1 for r in rows if r.get("result") == "win")
    losses = sum(1 for r in rows if r.get("result") == "loss")
    ties = n - wins - losses
    gss = [r["game_score"] for r in rows if r.get("game_score") is not None]
    mean_gs = round(sum(gss) / len(gss), 2) if gss else None
    own_ret = sum(safe_int(r.get("own_retreat_ticks"), 0) for r in rows)
    grm_cnt = sum(1 for r in rows if safe_int(r.get("grm_flag"), 0) > 0)
    apm_p0 = sum(safe_int(r.get("apm_p0_drops"), 0) for r in rows) / n
    crashes = sum(safe_int(r.get("crashes"), 0) for r in rows)
    wire_rej = sum(safe_int(r.get("wire_rejects"), 0) for r in rows)
    return {
        "n": n,
        "wins": wins,
        "losses": losses,
        "ties": ties,
        "win_rate_pct": round(100.0 * wins / n, 1),
        "mean_gs": mean_gs,
        "own_retreat_ticks": own_ret,
        "grm_count": grm_cnt,
        "grm_rate_pct": round(100.0 * grm_cnt / n, 1),
        "apm_p0_avg": round(apm_p0, 2),
        "crashes": crashes,
        "wire_rejects": wire_rej,
    }


def _daemon_pid_status(state_dir: Path) -> dict[str, Any]:
    pid_path = state_dir / "daemon.pid"
    pause_path = state_dir / "daemon.pause"
    pid: int | None = None
    running = False
    if pid_path.is_file():
        try:
            pid = int(pid_path.read_text(encoding="utf-8").strip())
            os.kill(pid, 0)
            running = True
        except Exception:
            running = False
    return {
        "running": running,
        "pid": pid if running else None,
        "paused": pause_path.is_file(),
    }


def build_status_payload(
    conn: sqlite3.Connection,
    state_dir: Path,
    rev_id: str | None = None,
) -> dict[str, Any]:
    target_rev = _resolve_target_rev(conn, rev_id)
    daemon_info = _daemon_pid_status(state_dir)

    rev_meta: dict[str, Any] = {}
    if target_rev:
        rrow = conn.execute("SELECT * FROM revisions WHERE rev_id = ?", (target_rev,)).fetchone()
        if rrow:
            rev_meta = dict(rrow)

    ladder_tiers: dict[str, dict[str, int]] = {}
    tactics_tiers: dict[str, dict[str, int]] = {}
    active_ladder_workers: list[str] = []
    active_tactics_workers: list[str] = []

    if target_rev:
        for row in conn.execute(
            "SELECT tier, status, COUNT(*) AS cnt FROM ladder_queue WHERE rev_id = ? GROUP BY tier, status",
            (target_rev,),
        ).fetchall():
            ladder_tiers.setdefault(row["tier"], {})[row["status"]] = int(row["cnt"])
        for row in conn.execute(
            "SELECT tier, status, COUNT(*) AS cnt FROM tactics_queue WHERE rev_id = ? GROUP BY tier, status",
            (target_rev,),
        ).fetchall():
            tactics_tiers.setdefault(row["tier"], {})[row["status"]] = int(row["cnt"])

    for row in conn.execute(
        "SELECT worker_id FROM ladder_queue WHERE status = 'running'"
    ).fetchall():
        active_ladder_workers.append(str(row["worker_id"] or "ladder"))
    for row in conn.execute(
        "SELECT worker_id FROM tactics_queue WHERE status = 'running'"
    ).fetchall():
        active_tactics_workers.append(str(row["worker_id"] or "tactics"))

    rev_rows = (
        [
            dict(r)
            for r in conn.execute(
                "SELECT * FROM ladder_results WHERE rev_id = ? AND opp_cohort != 'cheese_radar'",
                (target_rev,),
            ).fetchall()
        ]
        if target_rev
        else []
    )
    ladder_summary = _summarize_ladder_rows(rev_rows)

    base_rev = str(rev_meta.get("baseline_rev_id") or "")
    matched_delta_gs: float | None = None
    matched_n = 0
    if target_rev and base_rev:
        rmap = _latest_ladder_by_pair(conn, target_rev, exclude_cheese=True)
        bmap = _latest_ladder_by_pair(conn, base_rev, exclude_cheese=True)
        deltas = [
            rmap[k]["game_score"] - bmap[k]["game_score"]
            for k in rmap
            if k in bmap
            and rmap[k].get("game_score") is not None
            and bmap[k].get("game_score") is not None
        ]
        if deltas:
            matched_n = len(deltas)
            matched_delta_gs = round(sum(deltas) / len(deltas), 2)

    tactics_summary: dict[str, Any] = {"n": 0, "passed": 0, "pass_rate_pct": 0.0}
    if target_rev:
        trow = conn.execute(
            "SELECT COUNT(*) AS n, COALESCE(SUM(passed), 0) AS p FROM tactics_results WHERE rev_id = ?",
            (target_rev,),
        ).fetchone()
        if trow and int(trow["n"]) > 0:
            tn = int(trow["n"])
            tp = int(trow["p"])
            tactics_summary = {
                "n": tn,
                "passed": tp,
                "pass_rate_pct": round(100.0 * tp / tn, 1),
            }

    alert_counts = {"critical": 0, "warning": 0, "info": 0, "total_unacked": 0}
    if target_rev:
        for row in conn.execute(
            "SELECT severity, COUNT(*) AS cnt FROM alerts WHERE rev_id = ? AND acknowledged = 0 GROUP BY severity",
            (target_rev,),
        ).fetchall():
            sev = str(row["severity"])
            cnt = int(row["cnt"])
            if sev in alert_counts:
                alert_counts[sev] = cnt
            alert_counts["total_unacked"] += cnt

    return {
        "updated_at": utc_now_iso(),
        "daemon": daemon_info,
        "active_rev": target_rev,
        "revision": rev_meta,
        "baseline_rev": base_rev or None,
        "workers": {
            "ladder_running": len(active_ladder_workers),
            "tactics_running": len(active_tactics_workers),
        },
        "ladder_tiers": ladder_tiers,
        "tactics_tiers": tactics_tiers,
        "ladder_summary": ladder_summary,
        "matched_vs_baseline": {
            "baseline_rev": base_rev or None,
            "matched_n": matched_n,
            "delta_gs": matched_delta_gs,
        },
        "tactics_summary": tactics_summary,
        "alerts": alert_counts,
    }


def build_alerts_payload(
    conn: sqlite3.Connection,
    rev_id: str | None = None,
    severity: str | None = None,
    unacked_only: bool = False,
) -> dict[str, Any]:
    target_rev = _resolve_target_rev(conn, rev_id)
    clauses: list[str] = []
    params: list[Any] = []
    if target_rev:
        clauses.append("rev_id = ?")
        params.append(target_rev)
    if severity:
        clauses.append("severity = ?")
        params.append(severity.strip().lower())
    if unacked_only:
        clauses.append("acknowledged = 0")
    where_sql = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = conn.execute(
        f"SELECT * FROM alerts {where_sql} ORDER BY acknowledged ASC, id DESC",
        params,
    ).fetchall()
    return {
        "updated_at": utc_now_iso(),
        "rev_id": target_rev,
        "count": len(rows),
        "alerts": [dict(r) for r in rows],
    }


def write_live_state_files(conn: sqlite3.Connection, state_dir: Path) -> None:
    status_doc = build_status_payload(conn, state_dir)
    alerts_doc = build_alerts_payload(conn, rev_id=status_doc.get("active_rev"), unacked_only=True)
    atomic_write_json(state_dir / "latest_status.json", status_doc)
    atomic_write_json(state_dir / "latest_alerts.json", alerts_doc)


def build_report_payload(
    conn: sqlite3.Connection,
    rev_id: str | None = None,
    vs_rev: str | None = None,
) -> dict[str, Any]:
    target_rev = _resolve_target_rev(conn, rev_id)
    if not target_rev:
        return {"error": "No revisions found in database."}
    base_rev = vs_rev or _get_revision_baseline(conn, target_rev)

    rev_map = _latest_ladder_by_pair(conn, target_rev, exclude_cheese=True)
    base_map = _latest_ladder_by_pair(conn, base_rev, exclude_cheese=True) if base_rev else {}

    def _bucket_stats(pred: Callable[[dict[str, Any]], bool]) -> dict[str, Any]:
        r_list = [r for r in rev_map.values() if pred(r)]
        stats = _summarize_ladder_rows(r_list)
        if base_rev:
            m_pairs = [
                (rev_map[k], base_map[k])
                for k in sorted(rev_map.keys())
                if k in base_map and pred(rev_map[k])
            ]
            gs_deltas = [
                r["game_score"] - b["game_score"]
                for r, b in m_pairs
                if r.get("game_score") is not None and b.get("game_score") is not None
            ]
            base_sub = _summarize_ladder_rows([b for _, b in m_pairs])
            stats["matched_n"] = len(m_pairs)
            stats["base_mean_gs"] = base_sub["mean_gs"]
            stats["delta_gs"] = (
                round(sum(gs_deltas) / len(gs_deltas), 2) if gs_deltas else None
            )
            stats["base_own_retreat_ticks"] = base_sub["own_retreat_ticks"]
            stats["base_grm_rate_pct"] = base_sub["grm_rate_pct"]
        return stats

    ladder_breakdown = {
        "ALL": _bucket_stats(lambda _r: True),
        "EXT_Z": _bucket_stats(lambda r: r["opp_cohort"] != "selfplay" and r["our_race"] == "Zerg"),
        "EXT_T": _bucket_stats(lambda r: r["opp_cohort"] != "selfplay" and r["our_race"] == "Terran"),
        "EXT_P": _bucket_stats(lambda r: r["opp_cohort"] != "selfplay" and r["our_race"] == "Protoss"),
        "SELF_6": _bucket_stats(lambda r: r["opp_cohort"] == "selfplay"),
        "CORE": _bucket_stats(lambda r: r["opp_cohort"] == "core"),
        "UNSEEN": _bucket_stats(lambda r: r["opp_cohort"] == "unseen"),
    }

    regressed_matches: list[dict[str, Any]] = []
    if base_rev:
        for k in sorted(rev_map.keys()):
            if k not in base_map:
                continue
            r = rev_map[k]
            b = base_map[k]
            if r.get("game_score") is None or b.get("game_score") is None:
                continue
            dgs = round(r["game_score"] - b["game_score"], 2)
            regressed_matches.append({
                "bot": r["bot"],
                "opponent": r["opponent"],
                "cohort": r["opp_cohort"],
                "rev_result": r["result"],
                "base_result": b["result"],
                "rev_gs": r["game_score"],
                "base_gs": b["game_score"],
                "delta_gs": dgs,
                "rev_own_ret": r["own_retreat_ticks"],
                "base_own_ret": b["own_retreat_ticks"],
                "rev_grm": r["grm_flag"],
                "base_grm": b["grm_flag"],
            })
        regressed_matches.sort(key=lambda x: x["delta_gs"])

    # Tactics breakdown by category and terrain
    rev_t_rows = [
        dict(r)
        for r in conn.execute(
            "SELECT * FROM tactics_results WHERE rev_id = ?", (target_rev,)
        ).fetchall()
    ]
    base_t_map = (
        {
            (str(r["opponent_mode"]), str(r["scenario_id"])): dict(r)
            for r in conn.execute(
                "SELECT * FROM tactics_results WHERE rev_id = ?", (base_rev,)
            ).fetchall()
        }
        if base_rev
        else {}
    )

    def _agg_tactics(group_key: str) -> dict[str, dict[str, Any]]:
        buckets: dict[str, list[dict[str, Any]]] = {}
        for r in rev_t_rows:
            gk = f"{r['opponent_mode']}:{r.get(group_key) or 'unknown'}"
            buckets.setdefault(gk, []).append(r)
        out: dict[str, dict[str, Any]] = {}
        for gk, items in sorted(buckets.items()):
            n = len(items)
            p_cnt = sum(safe_int(x["passed"], 0) for x in items)
            trades = [safe_float(x["trade_ratio"], 0.0) for x in items if x.get("trade_ratio") is not None]
            entry: dict[str, Any] = {
                "n": n,
                "passed": p_cnt,
                "pass_rate_pct": round(100.0 * p_cnt / n, 1) if n else 0.0,
                "mean_trade": round(sum(trades) / len(trades), 3) if trades else 0.0,
            }
            if base_t_map:
                matched_b = [
                    (x, base_t_map[(x["opponent_mode"], x["scenario_id"])])
                    for x in items
                    if (x["opponent_mode"], x["scenario_id"]) in base_t_map
                ]
                if matched_b:
                    mn = len(matched_b)
                    rp = sum(safe_int(x["passed"], 0) for x, _ in matched_b) / mn
                    bp = sum(safe_int(b["passed"], 0) for _, b in matched_b) / mn
                    entry["matched_n"] = mn
                    entry["delta_pass_rate_pp"] = round((rp - bp) * 100.0, 1)
            out[gk] = entry
        return out

    regressed_scenarios: list[dict[str, Any]] = []
    for r in rev_t_rows:
        b = base_t_map.get((r["opponent_mode"], r["scenario_id"]))
        if not b:
            continue
        flipped = safe_int(b["passed"], 0) == 1 and safe_int(r["passed"], 0) == 0
        bt = safe_float(b.get("trade_ratio"), 0.0)
        rt = safe_float(r.get("trade_ratio"), 0.0)
        trade_delta = round(rt - bt, 3)
        if flipped or (bt >= 0.5 and rt <= bt * 0.75 + 1e-9):
            regressed_scenarios.append({
                "opponent_mode": r["opponent_mode"],
                "scenario_id": r["scenario_id"],
                "category": r["category"],
                "terrain": r["terrain"],
                "flipped_pass_to_fail": flipped,
                "rev_passed": r["passed"],
                "base_passed": b["passed"],
                "rev_trade": rt,
                "base_trade": bt,
                "trade_delta": trade_delta,
            })
    regressed_scenarios.sort(
        key=lambda x: (0 if x["flipped_pass_to_fail"] else 1, x["trade_delta"])
    )

    alerts = build_alerts_payload(conn, rev_id=target_rev, unacked_only=True)["alerts"]
    return {
        "rev_id": target_rev,
        "baseline_rev_id": base_rev or None,
        "ladder_breakdown": ladder_breakdown,
        "top_regressed_matches": regressed_matches[:15],
        "tactics_by_category": _agg_tactics("category"),
        "tactics_by_terrain": _agg_tactics("terrain"),
        "top_regressed_scenarios": regressed_scenarios[:15],
        "active_alerts": alerts,
    }


# ---------------------------------------------------------------------------
# Container coexistence check
# ---------------------------------------------------------------------------


def detect_container_runtime() -> str | None:
    for c in ("podman", "docker"):
        if shutil.which(c):
            return c
    return None


def count_active_sc2_containers(runtime: str | None = None) -> int:
    rt = runtime or detect_container_runtime()
    if not rt:
        return 0
    try:
        out = subprocess.check_output(
            [rt, "ps", "--format", "{{.Names}}\t{{.Image}}"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=10,
        )
    except Exception:
        return 0
    count = 0
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t", 1)
        name = parts[0].strip().lower()
        image = parts[1].strip().lower() if len(parts) > 1 else ""
        if any(name.startswith(pfx) for pfx in SC2_CONTAINER_NAME_PREFIXES) or any(
            sub in image for sub in SC2_IMAGE_SUBSTRINGS
        ):
            count += 1
    return count


# ---------------------------------------------------------------------------
# Continuous Eval Daemon Engine
# ---------------------------------------------------------------------------


class EvalDaemon:
    def __init__(
        self,
        repo_dir: Path,
        arena_dir: Path,
        state_dir: Path,
        snapshots_dir: Path,
        ladder_workers: int = DEFAULT_LADDER_WORKERS,
        tactics_workers: int = DEFAULT_TACTICS_WORKERS,
        max_total_sc2: int = DEFAULT_MAX_TOTAL_SC2,
        max_loadavg: float = DEFAULT_MAX_LOADAVG,
        poll_sec: float = DEFAULT_POLL_SEC,
        timeout_sec: int = DEFAULT_TIMEOUT_SEC,
        max_game_time: int = DEFAULT_MAX_GAME_TIME,
        once: bool = False,
        ladder_runner: Callable[[dict[str, Any], dict[str, Any], Path], dict[str, Any]] | None = None,
        tactics_runner: Callable[
            [dict[str, Any], dict[str, Any], Path, Path, Callable[[dict[str, Any]], None]],
            list[dict[str, Any]],
        ] | None = None,
        active_sc2_counter: Callable[[], int] | None = None,
        loadavg_getter: Callable[[], float] | None = None,
    ) -> None:
        self.repo_dir = repo_dir.resolve()
        self.arena_dir = arena_dir.resolve()
        self.state_dir = state_dir.resolve()
        self.snapshots_dir = snapshots_dir.resolve()
        self.db_path = self.state_dir / "eval_stream.sqlite"
        self.ladder_workers = max(0, int(ladder_workers))
        self.tactics_workers = max(0, int(tactics_workers))
        self.max_total_sc2 = max(1, int(max_total_sc2))
        self.max_loadavg = max(0.0, float(max_loadavg))
        self.poll_sec = max(0.05, float(poll_sec))
        self.timeout_sec = int(timeout_sec)
        self.max_game_time = int(max_game_time)
        self.once = bool(once)
        self.ladder_runner = ladder_runner
        self.tactics_runner = tactics_runner
        self.active_sc2_counter = active_sc2_counter or count_active_sc2_containers
        self.loadavg_getter = loadavg_getter or (lambda: float(os.getloadavg()[0]))

        self.shutdown_event = threading.Event()
        self._db_lock = threading.Lock()
        self._spawn_lock = threading.Lock()
        self._child_procs: set[subprocess.Popen[Any]] = set()
        self._procs_lock = threading.Lock()
        self._in_flight_sc2 = 0

        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.conn = open_db(self.db_path)

    def close(self) -> None:
        try:
            self.conn.close()
        except Exception:
            pass

    def is_paused(self) -> bool:
        return (self.state_dir / "daemon.pause").is_file()

    def _recover_stale_running(self) -> None:
        with self._db_lock, self.conn:
            self.conn.execute(
                "UPDATE ladder_queue SET status = 'queued', worker_id = '' WHERE status = 'running'"
            )
            self.conn.execute(
                "UPDATE tactics_queue SET status = 'queued', worker_id = '' WHERE status = 'running'"
            )

    def _can_launch_container(self) -> bool:
        if self.shutdown_event.is_set() or self.is_paused():
            return False
        if self.max_loadavg > 0.0:
            try:
                if float(self.loadavg_getter()) >= self.max_loadavg:
                    return False
            except Exception:
                pass
        with self._spawn_lock:
            active_ext = int(self.active_sc2_counter())
            return max(active_ext, self._in_flight_sc2) < self.max_total_sc2

    def _claim_ladder_item(self, worker_id: str) -> tuple[dict[str, Any], dict[str, Any]] | None:
        with self._db_lock:
            row = self.conn.execute(
                """
                SELECT * FROM ladder_queue
                WHERE status = 'queued'
                ORDER BY priority ASC, id ASC
                LIMIT 1
                """
            ).fetchone()
            if not row:
                return None
            item = dict(row)
            rrow = self.conn.execute(
                "SELECT * FROM revisions WHERE rev_id = ?", (item["rev_id"],)
            ).fetchone()
            rev_meta = dict(rrow) if rrow else {"rev_id": item["rev_id"], "snapshot_dir": str(self.repo_dir)}
            now_iso = utc_now_iso()
            with self.conn:
                self.conn.execute(
                    """
                    UPDATE ladder_queue
                    SET status = 'running', worker_id = ?, started_at = ?, attempts = attempts + 1
                    WHERE id = ?
                    """,
                    (worker_id, now_iso, item["id"]),
                )
            return item, rev_meta

    def _claim_tactics_item(self, worker_id: str) -> tuple[dict[str, Any], dict[str, Any]] | None:
        with self._db_lock:
            row = self.conn.execute(
                """
                SELECT * FROM tactics_queue
                WHERE status = 'queued'
                ORDER BY priority ASC, id ASC
                LIMIT 1
                """
            ).fetchone()
            if not row:
                return None
            item = dict(row)
            rrow = self.conn.execute(
                "SELECT * FROM revisions WHERE rev_id = ?", (item["rev_id"],)
            ).fetchone()
            rev_meta = dict(rrow) if rrow else {"rev_id": item["rev_id"], "snapshot_dir": str(self.repo_dir)}
            now_iso = utc_now_iso()
            with self.conn:
                self.conn.execute(
                    """
                    UPDATE tactics_queue
                    SET status = 'running', worker_id = ?, started_at = ?, attempts = attempts + 1
                    WHERE id = ?
                    """,
                    (worker_id, now_iso, item["id"]),
                )
            return item, rev_meta

    def _maybe_finalize_revision_status(self, rev_id: str) -> None:
        rem = self.conn.execute(
            """
            SELECT
              (SELECT COUNT(*) FROM ladder_queue WHERE rev_id = ? AND status IN ('queued', 'running')) +
              (SELECT COUNT(*) FROM tactics_queue WHERE rev_id = ? AND status IN ('queued', 'running'))
            AS rem
            """,
            (rev_id, rev_id),
        ).fetchone()
        if rem and int(rem["rem"]) == 0:
            self.conn.execute(
                """
                UPDATE revisions
                SET status = CASE WHEN status = 'draining' THEN 'superseded' ELSE 'completed' END
                WHERE rev_id = ? AND status IN ('active', 'draining')
                """,
                (rev_id,),
            )

    def _prepare_worker_arena(self, worker_id: str) -> Path:
        work_arena = self.state_dir / "work_arena" / sanitize_token(worker_id)
        work_arena.mkdir(parents=True, exist_ok=True)
        for sub, target in (
            ("bots", self.arena_dir / "bots"),
            ("maps", self.arena_dir / "maps"),
            ("runs", self.state_dir / "runs"),
        ):
            if sub == "runs":
                target.mkdir(parents=True, exist_ok=True)
            link = work_arena / sub
            if not link.exists() and not link.is_symlink():
                os.symlink(target, link)
        (work_arena / "cache").mkdir(parents=True, exist_ok=True)
        return work_arena

    def _run_subprocess(self, cmd: list[str], cwd: Path, timeout_sec: int) -> subprocess.CompletedProcess[str]:
        proc = subprocess.Popen(
            cmd,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        with self._procs_lock:
            self._child_procs.add(proc)
        try:
            stdout, stderr = proc.communicate(timeout=timeout_sec)
            return subprocess.CompletedProcess(cmd, proc.returncode, stdout, stderr)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                stdout, stderr = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                stdout, stderr = proc.communicate()
            return subprocess.CompletedProcess(cmd, 124, stdout, stderr)
        finally:
            with self._procs_lock:
                self._child_procs.discard(proc)

    def _default_run_ladder_item(
        self,
        item: dict[str, Any],
        rev_meta: dict[str, Any],
        work_arena: Path,
    ) -> dict[str, Any]:
        snap_dir = Path(rev_meta.get("snapshot_dir") or self.repo_dir)
        if not snap_dir.is_dir():
            snap_dir = self.repo_dir
        run_id = sanitize_token(f"ce_{item['rev_id'][-16:]}_q{item['id']}")
        match_run_dir = self.state_dir / "runs" / run_id
        mf_path = self.state_dir / "match_files" / f"{run_id}.json"
        mf_path.parent.mkdir(parents=True, exist_ok=True)

        entry: dict[str, Any] = {
            "bot": item["bot"],
            "opponent": item["opponent"],
            "map": item["map_name"],
            "random_seed": int(item["random_seed"]),
            "cohort": item["cohort"],
            "p1_mode": item["p1_mode"],
            "p2_mode": item["p2_mode"],
        }
        if item.get("p2_alias"):
            entry["p2_alias"] = item["p2_alias"]
        if item.get("cheese_profile"):
            entry["cheese_profile"] = item["cheese_profile"]
        mf_path.write_text(json.dumps({"matches": [entry]}, indent=2) + "\n", encoding="utf-8")

        mgt = CHEESE_MAX_GAME_TIME if item.get("cohort") == "cheese_radar" else self.max_game_time
        arena_script = snap_dir / "tools" / "run-local-sc2-arena.py"
        if not arena_script.is_file():
            arena_script = self.repo_dir / "tools" / "run-local-sc2-arena.py"

        cmd = [
            sys.executable,
            str(arena_script),
            "--match-file",
            str(mf_path),
            "--repo-dir",
            str(snap_dir),
            "--arena-dir",
            str(work_arena),
            "--run-id",
            run_id,
            "-j",
            "1",
            "--mothman-mode",
            str(item["p1_mode"] or "source"),
            "--timeout-sec",
            str(self.timeout_sec),
            "--max-game-time",
            str(mgt),
        ]
        self._run_subprocess(cmd, cwd=snap_dir, timeout_sec=self.timeout_sec + 120)

        summary_path = match_run_dir / "summary.json"
        s_match: dict[str, Any] = {}
        if summary_path.is_file():
            try:
                sdoc = json.loads(summary_path.read_text(encoding="utf-8"))
                matches = sdoc.get("matches") or []
                if matches:
                    s_match = matches[0]
            except Exception:
                s_match = {}

        log_path = Path(str(s_match.get("our_log_path") or "")) if s_match.get("our_log_path") else None
        log_telem = parse_match_log_telemetry(log_path, s_match)

        # Fast single-match replay scoring (~1.5s) via score-replay-batch.rkt
        score_match: dict[str, Any] = {}
        score_json_path = match_run_dir / "score.json"
        score_rkt = snap_dir / "tools" / "score-replay-batch.rkt"
        if not score_rkt.is_file():
            score_rkt = self.repo_dir / "tools" / "score-replay-batch.rkt"
        replays = list((match_run_dir / "replays").glob("*.SC2Replay")) if (match_run_dir / "replays").is_dir() else []
        if replays and score_rkt.is_file() and shutil.which("racket"):
            self._run_subprocess(
                ["racket", str(score_rkt), "-j", "1", "--json", str(score_json_path), str(match_run_dir)],
                cwd=snap_dir,
                timeout_sec=120,
            )
            if score_json_path.is_file():
                try:
                    scdoc = json.loads(score_json_path.read_text(encoding="utf-8"))
                    s_list = scdoc.get("matches") or []
                    if s_list:
                        score_match = s_list[0]
                except Exception:
                    score_match = {}

        eff_opp = str(item.get("p2_alias") or item["opponent"])
        our_race = normalize_race_full(
            score_match.get("our_race") or s_match.get("bot1_race"), item["bot"]
        )
        res = normalize_result(score_match.get("result") or s_match.get("outcome"))
        state_res = normalize_result(
            score_match.get("state_outcome")
            or score_match.get("adjudicated_outcome")
            or res
        )
        return {
            "rev_id": item["rev_id"],
            "queue_id": item["id"],
            "tier": item["tier"],
            "bot": item["bot"],
            "our_race": our_race,
            "opponent": eff_opp,
            "opp_cohort": normalize_cohort(item.get("cohort")),
            "map_name": item["map_name"],
            "random_seed": int(item["random_seed"]),
            "result": res,
            "state_result": state_res,
            "game_score": normalize_gs_100(score_match.get("game_state_score")),
            "trade_ratio": safe_float(score_match.get("trade_ratio"), 0.0),
            "duration_sec": safe_float(
                score_match.get("duration_sec"),
                safe_float(s_match.get("game_minutes"), 0.0) * 60.0,
            ),
            "step_avg_ms": safe_float(
                score_match.get("avg_step_ms"), log_telem["step_avg_ms"]
            ),
            "step_p95_ms": safe_float(
                score_match.get("p95_step_ms", score_match.get("step_p95")),
                log_telem["step_p95_ms"],
            ),
            "crashes": max(safe_int(score_match.get("crashes"), 0), log_telem["crashes"]),
            "wire_rejects": max(
                safe_int(score_match.get("action_rejects"), 0), log_telem["wire_rejects"]
            ),
            "self_cancel": max(
                _extract_self_cancel_count(score_match), log_telem["self_cancel"]
            ),
            "arbiter_error": log_telem["arbiter_error"],
            "own_retreat_ticks": safe_int(score_match.get("own_base_retreat_ticks"), 0),
            "grm_flag": 1 if bool(score_match.get("gas_rich_min_starved", False)) else 0,
            "apm_p0_drops": log_telem["apm_p0_drops"],
            "apm_p1_drops": log_telem["apm_p1_drops"],
            "supply_block_pct": safe_float(score_match.get("supply_block_pct"), 0.0),
            "w6_workers": safe_int(score_match.get("our_w6"), 0)
            if score_match.get("our_w6") is not None
            else None,
            "replay_path": str(s_match.get("replay_path") or (replays[0] if replays else "")),
            "log_path": str(s_match.get("our_log_path") or ""),
            "finished_at": utc_now_iso(),
        }

    def _record_ladder_result(self, item: dict[str, Any], result: dict[str, Any]) -> None:
        now_iso = result.get("finished_at") or utc_now_iso()
        with self._db_lock, self.conn:
            self.conn.execute(
                """
                INSERT INTO ladder_results
                    (rev_id, queue_id, tier, bot, our_race, opponent, opp_cohort,
                     map_name, random_seed, result, state_result, game_score,
                     trade_ratio, duration_sec, step_avg_ms, step_p95_ms,
                     crashes, wire_rejects, self_cancel, arbiter_error,
                     own_retreat_ticks, grm_flag, apm_p0_drops, apm_p1_drops,
                     supply_block_pct, w6_workers, replay_path, log_path, finished_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    result["rev_id"],
                    result.get("queue_id", item["id"]),
                    result.get("tier", item["tier"]),
                    result["bot"],
                    result["our_race"],
                    result["opponent"],
                    result["opp_cohort"],
                    result.get("map_name", item["map_name"]),
                    safe_int(result.get("random_seed", item["random_seed"]), 0),
                    result["result"],
                    result["state_result"],
                    result.get("game_score"),
                    result.get("trade_ratio"),
                    result.get("duration_sec"),
                    result.get("step_avg_ms"),
                    result.get("step_p95_ms"),
                    safe_int(result.get("crashes"), 0),
                    safe_int(result.get("wire_rejects"), 0),
                    safe_int(result.get("self_cancel"), 0),
                    safe_int(result.get("arbiter_error"), 0),
                    safe_int(result.get("own_retreat_ticks"), 0),
                    safe_int(result.get("grm_flag"), 0),
                    safe_int(result.get("apm_p0_drops"), 0),
                    safe_int(result.get("apm_p1_drops"), 0),
                    result.get("supply_block_pct"),
                    result.get("w6_workers"),
                    str(result.get("replay_path") or ""),
                    str(result.get("log_path") or ""),
                    now_iso,
                ),
            )
            self.conn.execute(
                "UPDATE ladder_queue SET status = 'done', finished_at = ? WHERE id = ?",
                (now_iso, item["id"]),
            )
            evaluate_ladder_alerts(self.conn, result["rev_id"], latest_row=result)
            self._maybe_finalize_revision_status(result["rev_id"])
            write_live_state_files(self.conn, self.state_dir)

    def _ingest_single_tactics_record(self, rev_id: str, opp_mode: str, raw_rec: dict[str, Any]) -> None:
        row = _extract_tactics_row(raw_rec, rev_id, default_opp_mode=opp_mode)
        if row is None:
            return
        with self._db_lock, self.conn:
            upsert_tactics_result(self.conn, row)
            evaluate_tactics_alerts(self.conn, rev_id, latest_row=row)
            write_live_state_files(self.conn, self.state_dir)

    def _default_run_tactics_item(
        self,
        item: dict[str, Any],
        rev_meta: dict[str, Any],
        stream_jsonl: Path,
        out_json: Path,
        on_record: Callable[[dict[str, Any]], None],
    ) -> list[dict[str, Any]]:
        snap_dir = Path(rev_meta.get("snapshot_dir") or self.repo_dir)
        if not snap_dir.is_dir():
            snap_dir = self.repo_dir
        tactics_script = snap_dir / "tools" / "sc2-tactics-arena.py"
        if not tactics_script.is_file():
            tactics_script = self.repo_dir / "tools" / "sc2-tactics-arena.py"

        stream_jsonl.parent.mkdir(parents=True, exist_ok=True)
        out_json.parent.mkdir(parents=True, exist_ok=True)
        if stream_jsonl.exists():
            stream_jsonl.unlink()

        cmd = [
            sys.executable,
            str(tactics_script),
            "--mode",
            "duel",
            "--suite",
            str(item["suite"]),
            "--opponent",
            str(item["opponent_mode"]),
            "--shard-index",
            str(item["shard_index"]),
            "--shard-count",
            str(item["shard_count"]),
            "--workers",
            "1",
            "--repo-dir",
            str(snap_dir),
            "--arena-dir",
            str(self.arena_dir),
            "--maps-dir",
            str(self.arena_dir / "maps"),
            "--out",
            str(out_json),
            "--stream-jsonl",
            str(stream_jsonl),
        ]
        shard_log = out_json.with_suffix(".log")
        log_fh = shard_log.open("w", encoding="utf-8", errors="replace")
        try:
            proc = subprocess.Popen(
                cmd,
                cwd=snap_dir,
                stdout=log_fh,
                stderr=subprocess.STDOUT,
                text=True,
            )
        except Exception:
            log_fh.close()
            raise
        with self._procs_lock:
            self._child_procs.add(proc)

        seen_offset = 0
        seen_ids: set[str] = set()

        def _drain_jsonl() -> None:
            nonlocal seen_offset
            if not stream_jsonl.is_file():
                return
            try:
                with stream_jsonl.open("r", encoding="utf-8", errors="replace") as fh:
                    fh.seek(seen_offset)
                    while True:
                        line = fh.readline()
                        if not line:
                            break
                        if not line.endswith("\n"):
                            break
                        seen_offset = fh.tell()
                        sline = line.strip()
                        if not sline:
                            continue
                        try:
                            rec = json.loads(sline)
                        except json.JSONDecodeError:
                            continue
                        if isinstance(rec, dict):
                            sid = str(rec.get("scenario_id") or rec.get("id") or "")
                            if sid:
                                seen_ids.add(sid)
                            on_record(rec)
            except Exception:
                pass

        try:
            deadline = time.monotonic() + max(self.timeout_sec * 3, 1800)
            while proc.poll() is None:
                _drain_jsonl()
                if self.shutdown_event.is_set() or time.monotonic() > deadline:
                    proc.terminate()
                    break
                time.sleep(1.0)
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            _drain_jsonl()
        finally:
            log_fh.close()
            with self._procs_lock:
                self._child_procs.discard(proc)

        extra: list[dict[str, Any]] = []
        if out_json.is_file():
            try:
                doc = json.loads(out_json.read_text(encoding="utf-8"))
                for rec in doc.get("scenarios") or []:
                    if not isinstance(rec, dict):
                        continue
                    sid = str(rec.get("scenario_id") or rec.get("id") or "")
                    if sid and sid not in seen_ids:
                        extra.append(rec)
            except Exception:
                pass
        return extra

    def _ladder_worker_loop(self, worker_id: str) -> None:
        work_arena = self._prepare_worker_arena(worker_id)
        while not self.shutdown_event.is_set():
            if not self._can_launch_container():
                self.shutdown_event.wait(self.poll_sec)
                continue
            claimed = self._claim_ladder_item(worker_id)
            if claimed is None:
                if self.once:
                    return
                self.shutdown_event.wait(self.poll_sec)
                continue
            item, rev_meta = claimed
            with self._spawn_lock:
                self._in_flight_sc2 += 1
            try:
                if self.ladder_runner is not None:
                    res = self.ladder_runner(item, rev_meta, work_arena)
                else:
                    res = self._default_run_ladder_item(item, rev_meta, work_arena)
                self._record_ladder_result(item, res)
            except Exception as exc:
                with self._db_lock, self.conn:
                    self.conn.execute(
                        "UPDATE ladder_queue SET status = 'failed', finished_at = ? WHERE id = ?",
                        (utc_now_iso(), item["id"]),
                    )
                    self._maybe_finalize_revision_status(item["rev_id"])
                    write_live_state_files(self.conn, self.state_dir)
                print(f"[{worker_id}] ladder item #{item['id']} failed: {exc}", file=sys.stderr, flush=True)
            finally:
                with self._spawn_lock:
                    self._in_flight_sc2 = max(0, self._in_flight_sc2 - 1)

    def _tactics_worker_loop(self, worker_id: str) -> None:
        while not self.shutdown_event.is_set():
            if not self._can_launch_container():
                self.shutdown_event.wait(self.poll_sec)
                continue
            claimed = self._claim_tactics_item(worker_id)
            if claimed is None:
                if self.once:
                    return
                self.shutdown_event.wait(self.poll_sec)
                continue
            item, rev_meta = claimed
            rev_id = item["rev_id"]
            opp_mode = item["opponent_mode"]
            tdir = self.state_dir / "tactics" / sanitize_token(rev_id)
            stream_jsonl = tdir / f"{item['tier']}_s{item['shard_index']}_of_{item['shard_count']}.jsonl"
            out_json = tdir / f"{item['tier']}_s{item['shard_index']}_of_{item['shard_count']}.json"

            def _on_rec(rec: dict[str, Any]) -> None:
                self._ingest_single_tactics_record(rev_id, opp_mode, rec)

            with self._spawn_lock:
                self._in_flight_sc2 += 1
            try:
                if self.tactics_runner is not None:
                    extra = self.tactics_runner(item, rev_meta, stream_jsonl, out_json, _on_rec) or []
                else:
                    extra = self._default_run_tactics_item(item, rev_meta, stream_jsonl, out_json, _on_rec)
                for rec in extra:
                    self._ingest_single_tactics_record(rev_id, opp_mode, rec)
                with self._db_lock, self.conn:
                    self.conn.execute(
                        "UPDATE tactics_queue SET status = 'done', finished_at = ? WHERE id = ?",
                        (utc_now_iso(), item["id"]),
                    )
                    evaluate_tactics_alerts(self.conn, rev_id, latest_row=None)
                    self._maybe_finalize_revision_status(rev_id)
                    write_live_state_files(self.conn, self.state_dir)
            except Exception as exc:
                with self._db_lock, self.conn:
                    self.conn.execute(
                        "UPDATE tactics_queue SET status = 'failed', finished_at = ? WHERE id = ?",
                        (utc_now_iso(), item["id"]),
                    )
                    self._maybe_finalize_revision_status(rev_id)
                    write_live_state_files(self.conn, self.state_dir)
                print(f"[{worker_id}] tactics shard #{item['id']} failed: {exc}", file=sys.stderr, flush=True)
            finally:
                with self._spawn_lock:
                    self._in_flight_sc2 = max(0, self._in_flight_sc2 - 1)

    def stop_children(self) -> None:
        self.shutdown_event.set()
        with self._procs_lock:
            procs = list(self._child_procs)
        for p in procs:
            try:
                p.terminate()
            except Exception:
                pass

    def run_forever(self, write_pid: bool = True) -> int:
        pid_path = self.state_dir / "daemon.pid"
        if write_pid:
            if pid_path.is_file():
                try:
                    old_pid = int(pid_path.read_text(encoding="utf-8").strip())
                    if old_pid != os.getpid():
                        os.kill(old_pid, 0)
                        raise RuntimeError(f"Daemon already running with PID {old_pid}")
                except ProcessLookupError:
                    pass
                except ValueError:
                    pass
            pid_path.write_text(f"{os.getpid()}\n", encoding="utf-8")

        self._recover_stale_running()
        with self._db_lock:
            write_live_state_files(self.conn, self.state_dir)

        threads: list[threading.Thread] = []
        for i in range(self.ladder_workers):
            t = threading.Thread(
                target=self._ladder_worker_loop,
                args=(f"ladder-{i}",),
                name=f"ce-ladder-{i}",
                daemon=True,
            )
            t.start()
            threads.append(t)
        for i in range(self.tactics_workers):
            t = threading.Thread(
                target=self._tactics_worker_loop,
                args=(f"tactics-{i}",),
                name=f"ce-tactics-{i}",
                daemon=True,
            )
            t.start()
            threads.append(t)

        try:
            for t in threads:
                while t.is_alive():
                    t.join(timeout=0.5)
        finally:
            self.stop_children()
            for t in threads:
                t.join(timeout=2.0)
            if write_pid and pid_path.is_file():
                try:
                    if int(pid_path.read_text(encoding="utf-8").strip()) == os.getpid():
                        pid_path.unlink()
                except Exception:
                    pass
            with self._db_lock:
                write_live_state_files(self.conn, self.state_dir)
            self.close()
        return 0


# ---------------------------------------------------------------------------
# Human-readable CLI formatting
# ---------------------------------------------------------------------------


def format_status_text(doc: dict[str, Any]) -> str:
    d = doc["daemon"]
    state_tok = "PAUSED" if d["paused"] else ("RUNNING" if d["running"] else "STOPPED")
    pid_tok = f" (pid={d['pid']})" if d.get("pid") else ""
    lines = [
        f"Continuous Eval Daemon: {state_tok}{pid_tok} | updated={doc['updated_at']}",
        f"Active rev : {doc.get('active_rev') or 'none'} | baseline={doc.get('baseline_rev') or 'none'}",
        f"Workers    : ladder={doc['workers']['ladder_running']} | tactics={doc['workers']['tactics_running']}",
    ]
    ls = doc["ladder_summary"]
    mb = doc["matched_vs_baseline"]
    dgs_s = f" | delta_gs={mb['delta_gs']:+.2f} (n={mb['matched_n']})" if mb.get("delta_gs") is not None else ""
    gs_s = f"{ls['mean_gs']:.1f}" if ls.get("mean_gs") is not None else "n/a"
    lines.append(
        f"Ladder     : {ls['wins']}W-{ls['losses']}L-{ls['ties']}T (n={ls['n']}, WR={ls['win_rate_pct']:.1f}%, "
        f"GS={gs_s}, ownRet={ls['own_retreat_ticks']}, GRM={ls['grm_rate_pct']:.1f}%{dgs_s})"
    )
    ts = doc["tactics_summary"]
    lines.append(
        f"Tactics    : {ts['passed']}/{ts['n']} passed ({ts['pass_rate_pct']:.1f}%)"
    )
    if doc["ladder_tiers"]:
        parts = [
            f"{t}=" + "/".join(f"{k}:{v}" for k, v in sorted(st.items()))
            for t, st in sorted(doc["ladder_tiers"].items())
        ]
        lines.append("L-Queue    : " + " | ".join(parts))
    if doc["tactics_tiers"]:
        parts = [
            f"{t}=" + "/".join(f"{k}:{v}" for k, v in sorted(st.items()))
            for t, st in sorted(doc["tactics_tiers"].items())
        ]
        lines.append("T-Queue    : " + " | ".join(parts))
    al = doc["alerts"]
    lines.append(
        f"Alerts     : unacked={al['total_unacked']} (critical={al['critical']}, warning={al['warning']})"
    )
    return "\n".join(lines) + "\n"


def format_report_text(doc: dict[str, Any]) -> str:
    if "error" in doc:
        return doc["error"] + "\n"
    lines = [
        "=" * 88,
        f"CONTINUOUS EVAL REPORT | rev={doc['rev_id']} | vs={doc.get('baseline_rev_id') or 'none'}",
        "=" * 88,
        f"{'Bucket':<10} {'W-L-T':<10} {'WR%':>6} {'GS':>7} {'dGS':>8} {'ownRet':>7} {'GRM%':>6} {'n':>4}",
        "-" * 88,
    ]
    for bname in ("ALL", "EXT_Z", "EXT_T", "EXT_P", "SELF_6", "CORE", "UNSEEN"):
        st = doc["ladder_breakdown"].get(bname, {})
        wlt = f"{st.get('wins', 0)}-{st.get('losses', 0)}-{st.get('ties', 0)}"
        gs_s = f"{st['mean_gs']:.1f}" if st.get("mean_gs") is not None else "n/a"
        dgs_s = f"{st['delta_gs']:+.1f}" if st.get("delta_gs") is not None else "n/a"
        lines.append(
            f"{bname:<10} {wlt:<10} {st.get('win_rate_pct', 0.0):>5.1f}% "
            f"{gs_s:>7} {dgs_s:>8} {st.get('own_retreat_ticks', 0):>7} "
            f"{st.get('grm_rate_pct', 0.0):>5.1f}% {st.get('n', 0):>4}"
        )
    if doc.get("top_regressed_matches"):
        lines.append("-" * 88)
        lines.append("Top Regressed Matches:")
        for m in doc["top_regressed_matches"][:8]:
            lines.append(
                f"  {m['bot']} vs {m['opponent']} [{m['cohort']}]: "
                f"{m['base_result']}->{m['rev_result']} GS {m['base_gs']:.1f}->{m['rev_gs']:.1f} "
                f"({m['delta_gs']:+.1f}) ownRet {m['base_own_ret']}->{m['rev_own_ret']} "
                f"GRM {m['base_grm']}->{m['rev_grm']}"
            )
    if doc.get("tactics_by_category"):
        lines.append("-" * 88)
        lines.append("Tactical Drills by Category:")
        for cat, st in sorted(doc["tactics_by_category"].items()):
            dp = (
                f" ({st['delta_pass_rate_pp']:+.1f}pp)"
                if st.get("delta_pass_rate_pp") is not None
                else ""
            )
            lines.append(
                f"  {cat:<32} {st['passed']}/{st['n']} ({st['pass_rate_pct']:.1f}%{dp}) "
                f"trade={st['mean_trade']:.2f}"
            )
    if doc.get("top_regressed_scenarios"):
        lines.append("-" * 88)
        lines.append("Top Regressed Tactical Scenarios:")
        for sc in doc["top_regressed_scenarios"][:8]:
            tag = "PASS->FAIL" if sc["flipped_pass_to_fail"] else "TRADE_DROP"
            lines.append(
                f"  [{tag}] {sc['opponent_mode']}:{sc['scenario_id']} ({sc['category']}): "
                f"trade {sc['base_trade']:.2f}->{sc['rev_trade']:.2f} ({sc['trade_delta']:+.2f})"
            )
    if doc.get("active_alerts"):
        lines.append("-" * 88)
        lines.append(f"Active Alerts ({len(doc['active_alerts'])}):")
        for al in doc["active_alerts"][:15]:
            lines.append(
                f"  #{al['id']} [{al['severity'].upper()}] {al['kind']} {al['scope']} "
                f"{al['metric']}: {al['detail']}"
            )
    lines.append("=" * 88)
    return "\n".join(lines) + "\n"


def format_alerts_text(doc: dict[str, Any]) -> str:
    alerts = doc.get("alerts") or []
    if not alerts:
        return f"No alerts for rev={doc.get('rev_id') or 'all'}.\n"
    lines = [f"Alerts for rev={doc.get('rev_id') or 'all'} (count={len(alerts)}):"]
    for al in alerts:
        ack_s = " [ACK]" if al.get("acknowledged") else ""
        lines.append(
            f"  #{al['id']} [{str(al['severity']).upper()}]{ack_s} {al['kind']} "
            f"scope={al['scope']} metric={al['metric']} n={al['sample_n']} | {al['detail']}"
        )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# CLI Entrypoint
# ---------------------------------------------------------------------------


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Continuous Background SC2 Arena & Tactical Drills Daemon"
    )
    parser.add_argument("--arena-dir", type=Path, default=DEFAULT_ARENA_DIR)
    parser.add_argument("--state-dir", type=Path, default=None)
    parser.add_argument("--snapshots-dir", type=Path, default=None)
    parser.add_argument("--repo-dir", type=Path, default=REPO_ROOT)

    sub = parser.add_subparsers(dest="command", required=True)

    p_snap = sub.add_parser("snapshot", help="Create an immutable Btrfs CoW snapshot of the repo")
    p_snap.add_argument("--label", default="")
    p_snap.add_argument("--repo-dir", dest="sub_repo_dir", type=Path, default=None)
    p_snap.add_argument("--keep-snapshots", type=int, default=DEFAULT_KEEP_SNAPSHOTS)
    p_snap.add_argument("--no-compile", action="store_true", help="Skip raco make bytecode precompilation inside snapshot")
    p_snap.add_argument("--compile-jobs", type=int, default=4, help="Parallel jobs for raco make inside snapshot (default: 4)")
    p_snap.add_argument("--json", action="store_true")

    p_enq = sub.add_parser("enqueue", help="Snapshot repo and enqueue tiered ladder + tactics evaluations")
    p_enq.add_argument("--label", default="")
    p_enq.add_argument("--baseline-rev", default=None)
    p_enq.add_argument("--tiers", default="all")
    p_enq.add_argument("--no-preempt", action="store_true")
    p_enq.add_argument("--repo-dir", dest="sub_repo_dir", type=Path, default=None)
    p_enq.add_argument("--snapshot-dir", type=Path, default=None)
    p_enq.add_argument("--mothman-mode", choices=["source", "zip", "elf"], default="source")
    p_enq.add_argument("--bench-seed", default=DEFAULT_BENCH_SEED)
    p_enq.add_argument("--keep-snapshots", type=int, default=DEFAULT_KEEP_SNAPSHOTS)
    p_enq.add_argument("--no-compile", action="store_true", help="Skip raco make bytecode precompilation inside snapshot")
    p_enq.add_argument("--compile-jobs", type=int, default=4, help="Parallel jobs for raco make inside snapshot (default: 4)")
    p_enq.add_argument("--json", action="store_true")

    p_seed = sub.add_parser("seed-baseline", help="Import historical score JSON and/or tactics JSON as baseline")
    p_seed.add_argument("--rev", required=True)
    p_seed.add_argument("--label", default="")
    p_seed.add_argument("--from-score-json", type=Path, default=None)
    p_seed.add_argument("--from-summary-json", type=Path, default=None)
    p_seed.add_argument("--from-tactics-json", type=Path, default=None)
    p_seed.add_argument("--opponent-mode", default="dummy")
    p_seed.add_argument("--json", action="store_true")

    for cmd_name in ("start", "run"):
        p_run = sub.add_parser(cmd_name, help="Run the continuous evaluation daemon")
        p_run.add_argument("--daemon", action="store_true", help="Detach and run in background")
        p_run.add_argument("--ladder-workers", type=int, default=DEFAULT_LADDER_WORKERS)
        p_run.add_argument("--tactics-workers", type=int, default=DEFAULT_TACTICS_WORKERS)
        p_run.add_argument("--max-total-sc2", type=int, default=DEFAULT_MAX_TOTAL_SC2)
        p_run.add_argument(
            "--max-loadavg",
            type=float,
            default=DEFAULT_MAX_LOADAVG,
            help="Defer launching new SC2 containers when 1-min loadavg >= threshold (0.0 disables)",
        )
        p_run.add_argument("--poll-sec", type=float, default=DEFAULT_POLL_SEC)
        p_run.add_argument("--timeout-sec", type=int, default=DEFAULT_TIMEOUT_SEC)
        p_run.add_argument("--max-game-time", type=int, default=DEFAULT_MAX_GAME_TIME)
        p_run.add_argument("--once", action="store_true", help="Drain queued work then exit")
        p_run.add_argument("--log-file", type=Path, default=None)

    p_stop = sub.add_parser("stop", help="Gracefully stop a running background daemon")
    p_stop.add_argument("--timeout", type=float, default=15.0)

    sub.add_parser("pause", help="Pause spawning new containers while letting active matches finish")
    sub.add_parser("resume", help="Resume spawning containers")

    p_st = sub.add_parser("status", help="Show daemon status, active revision, and rolling metrics")
    p_st.add_argument("--rev", default=None)
    p_st.add_argument("--json", action="store_true")

    p_rep = sub.add_parser("report", help="Show matched-pair ladder & tactical breakdown report")
    p_rep.add_argument("--rev", default=None)
    p_rep.add_argument("--vs", default=None)
    p_rep.add_argument("--json", action="store_true")

    p_al = sub.add_parser("alerts", help="List or acknowledge streaming regression alerts")
    p_al.add_argument("--rev", default=None)
    p_al.add_argument("--severity", choices=["critical", "warning", "info"], default=None)
    p_al.add_argument("--ack", action="store_true")
    p_al.add_argument("--alert-id", type=int, default=None)
    p_al.add_argument("--unacked-only", action="store_true")
    p_al.add_argument("--json", action="store_true")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_arg_parser()
    args = parser.parse_args(argv)

    arena_dir = args.arena_dir.resolve()
    state_dir = (args.state_dir or (arena_dir / "continuous_eval")).resolve()
    snapshots_dir = (args.snapshots_dir or (arena_dir / "snapshots")).resolve()
    repo_dir = (getattr(args, "sub_repo_dir", None) or args.repo_dir).resolve()
    db_path = state_dir / "eval_stream.sqlite"

    if args.command == "snapshot":
        meta = create_repo_snapshot(
            repo_dir,
            snapshots_dir,
            label=args.label,
            precompile=not args.no_compile,
            compile_jobs=args.compile_jobs,
        )
        conn = open_db(db_path)
        try:
            gc_removed = gc_snapshots(conn, snapshots_dir, keep=args.keep_snapshots)
        finally:
            conn.close()
        meta["gc_removed"] = gc_removed
        if args.json:
            print(json.dumps(meta, indent=2, sort_keys=True))
        else:
            print(
                f"Snapshot created: {meta['rev_id']} -> {meta['snapshot_dir']} "
                f"(compiled_zo={meta.get('compiled_zo_count', 0)})"
            )
        return 0

    if args.command == "enqueue":
        snap_meta: dict[str, Any] | None = None
        if args.snapshot_dir:
            sdir = args.snapshot_dir.resolve()
            mpath = sdir / ".snapshot_meta.json"
            if mpath.is_file():
                snap_meta = json.loads(mpath.read_text(encoding="utf-8"))
                snap_meta["snapshot_dir"] = str(sdir)
            else:
                vcs = probe_vcs_ids(sdir)
                snap_meta = {
                    "rev_id": sanitize_token(args.label or sdir.name),
                    "jj_change_id": vcs["jj_change_id"],
                    "commit_id": vcs["commit_id"],
                    "label": args.label or sdir.name,
                    "created_at": utc_now_iso(),
                    "parent_commit": vcs["parent_commit"],
                    "snapshot_dir": str(sdir),
                }
        conn = open_db(db_path)
        try:
            res = enqueue_revision(
                conn=conn,
                repo_dir=repo_dir,
                arena_dir=arena_dir,
                state_dir=state_dir,
                snapshots_dir=snapshots_dir,
                label=args.label,
                baseline_rev_id=args.baseline_rev,
                tiers_spec=args.tiers,
                preempt=not args.no_preempt,
                mothman_mode=args.mothman_mode,
                bench_seed=args.bench_seed,
                snapshot_meta=snap_meta,
                keep_snapshots=args.keep_snapshots,
                precompile=not args.no_compile,
                compile_jobs=args.compile_jobs,
            )
        finally:
            conn.close()
        if args.json:
            print(json.dumps(res, indent=2, sort_keys=True))
        else:
            print(
                f"Enqueued rev={res['rev_id']} (baseline={res['baseline_rev_id'] or 'none'}): "
                f"ladder={res['ladder_queued']} tactics={res['tactics_queued']} "
                f"superseded={res['superseded_ladder']}+{res['superseded_tactics']}"
            )
        return 0

    if args.command == "seed-baseline":
        conn = open_db(db_path)
        try:
            res = seed_baseline(
                conn=conn,
                rev_id=args.rev,
                label=args.label,
                from_score_json=args.from_score_json,
                from_summary_json=args.from_summary_json,
                from_tactics_json=args.from_tactics_json,
                opponent_mode=args.opponent_mode,
                state_dir=state_dir,
            )
        finally:
            conn.close()
        if args.json:
            print(json.dumps(res, indent=2, sort_keys=True))
        else:
            print(
                f"Seeded baseline rev={res['rev_id']}: "
                f"ladder={res['ladder_inserted']} tactics={res['tactics_inserted']}"
            )
        return 0

    if args.command == "pause":
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "daemon.pause").write_text(utc_now_iso() + "\n", encoding="utf-8")
        conn = open_db(db_path)
        try:
            write_live_state_files(conn, state_dir)
        finally:
            conn.close()
        print(f"Paused continuous eval daemon ({state_dir / 'daemon.pause'}).")
        return 0

    if args.command == "resume":
        pfile = state_dir / "daemon.pause"
        if pfile.exists():
            pfile.unlink()
        conn = open_db(db_path)
        try:
            write_live_state_files(conn, state_dir)
        finally:
            conn.close()
        print("Resumed continuous eval daemon.")
        return 0

    if args.command == "stop":
        pid_path = state_dir / "daemon.pid"
        if not pid_path.is_file():
            print("Daemon is not running (no PID file).")
            return 0
        try:
            pid = int(pid_path.read_text(encoding="utf-8").strip())
        except ValueError:
            pid_path.unlink(missing_ok=True)
            print("Removed invalid PID file.")
            return 0
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pid_path.unlink(missing_ok=True)
            print(f"Daemon PID {pid} already stopped.")
            return 0
        deadline = time.monotonic() + max(1.0, float(args.timeout))
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                print(f"Stopped daemon PID {pid}.")
                return 0
            time.sleep(0.25)
        print(f"Sent SIGTERM to daemon PID {pid}; still shutting down cleanly.")
        return 0

    if args.command in ("start", "run"):
        if args.daemon:
            state_dir.mkdir(parents=True, exist_ok=True)
            log_path = args.log_file or (state_dir / "daemon.log")
            child_cmd = [
                sys.executable,
                str(Path(__file__).resolve()),
                "--arena-dir",
                str(arena_dir),
                "--state-dir",
                str(state_dir),
                "--snapshots-dir",
                str(snapshots_dir),
                "--repo-dir",
                str(repo_dir),
                "run",
                "--ladder-workers",
                str(args.ladder_workers),
                "--tactics-workers",
                str(args.tactics_workers),
                "--max-total-sc2",
                str(args.max_total_sc2),
                "--max-loadavg",
                str(args.max_loadavg),
                "--poll-sec",
                str(args.poll_sec),
                "--timeout-sec",
                str(args.timeout_sec),
                "--max-game-time",
                str(args.max_game_time),
            ]
            if args.once:
                child_cmd.append("--once")
            with log_path.open("a", encoding="utf-8") as lfh:
                proc = subprocess.Popen(
                    child_cmd,
                    stdin=subprocess.DEVNULL,
                    stdout=lfh,
                    stderr=lfh,
                    start_new_session=True,
                )
            print(f"Started continuous eval daemon in background (pid={proc.pid}, log={log_path}).")
            return 0

        daemon = EvalDaemon(
            repo_dir=repo_dir,
            arena_dir=arena_dir,
            state_dir=state_dir,
            snapshots_dir=snapshots_dir,
            ladder_workers=args.ladder_workers,
            tactics_workers=args.tactics_workers,
            max_total_sc2=args.max_total_sc2,
            max_loadavg=args.max_loadavg,
            poll_sec=args.poll_sec,
            timeout_sec=args.timeout_sec,
            max_game_time=args.max_game_time,
            once=args.once,
        )

        def _handle_sig(_signum: int, _frame: Any) -> None:
            daemon.stop_children()

        signal.signal(signal.SIGTERM, _handle_sig)
        signal.signal(signal.SIGINT, _handle_sig)
        return daemon.run_forever(write_pid=True)

    if args.command == "status":
        conn = open_db(db_path)
        try:
            doc = build_status_payload(conn, state_dir, rev_id=args.rev)
        finally:
            conn.close()
        if args.json:
            print(json.dumps(doc, indent=2, sort_keys=True))
        else:
            print(format_status_text(doc), end="")
        return 0

    if args.command == "report":
        conn = open_db(db_path)
        try:
            doc = build_report_payload(conn, rev_id=args.rev, vs_rev=args.vs)
        finally:
            conn.close()
        if args.json:
            print(json.dumps(doc, indent=2, sort_keys=True))
        else:
            print(format_report_text(doc), end="")
        return 0

    if args.command == "alerts":
        conn = open_db(db_path)
        try:
            if args.ack:
                target_rev = _resolve_target_rev(conn, args.rev)
                with conn:
                    if args.alert_id is not None:
                        conn.execute(
                            "UPDATE alerts SET acknowledged = 1 WHERE id = ?",
                            (args.alert_id,),
                        )
                    else:
                        clauses = ["acknowledged = 0"]
                        params: list[Any] = []
                        if target_rev:
                            clauses.append("rev_id = ?")
                            params.append(target_rev)
                        if args.severity:
                            clauses.append("severity = ?")
                            params.append(args.severity)
                        conn.execute(
                            f"UPDATE alerts SET acknowledged = 1 WHERE {' AND '.join(clauses)}",
                            params,
                        )
                write_live_state_files(conn, state_dir)
            doc = build_alerts_payload(
                conn,
                rev_id=args.rev,
                severity=args.severity,
                unacked_only=args.unacked_only,
            )
        finally:
            conn.close()
        if args.json:
            print(json.dumps(doc, indent=2, sort_keys=True))
        else:
            print(format_alerts_text(doc), end="")
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
