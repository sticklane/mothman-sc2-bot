#!/usr/bin/env python3
"""
Parallel Local Real-Engine StarCraft II Match Runner (`tools/run-local-sc2-arena.py`)

Runs N concurrent real SC2_x64 (Blizzard 4.10) bot-vs-bot matches using the official
AI Arena combined container image (`docker.io/aiarena/arenaclient-combined:v0.8.0`)
under rootless Podman (or Docker).

Key properties:
  - 100% faithful to AI Arena production (exact SC2 4.10 + multi-language bot runtimes:
    python, cpplinux, dotnetcore, java, nodejs + Rust proxy/sc2/bot controllers).
  - Full per-match network & filesystem isolation: each match runs in its own container
    with isolated loopback ports, isolated CoW-cloned bot directories (`cp --reflink=auto`),
    per-match replay/log capture, and hard wall-clock timeout with forced container cleanup.
  - Supports three Mothman execution modes (`--mothman-mode`):
      * `zip`    (default): unpacks `ladder/Mothman-{P,T,Z,X}.zip` (cached & mtime-checked).
      * `elf`             : stages `ladder/.cache/mothman_standalone_elf` + `config.json`.
      * `source`          : zero-rebuild dev mode mounting repo `:ro` + portable Racket 8.16.
  - All heavy artifacts (maps, opponent bots, caches, replays, logs) live strictly OUTSIDE
    the repository under `/home/sjaconette/sc2-local-arena/`.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import signal
import sqlite3
import stat
import subprocess
import sys
import threading
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_IMAGE = "docker.io/aiarena/arenaclient-combined:v0.8.0"
DEFAULT_ARENA_DIR = Path(os.environ.get("SC2_LOCAL_ARENA_DIR", "/home/sjaconette/sc2-local-arena"))
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BENCH_SEED = "mothman-v1"
MAP_HASH_SALT = "map-171"
RANDOM_BENCH_SEEDS = frozenset({"", "0", "none", "random", "off", "false"})

MOTHMAN_VARIANTS: dict[str, dict[str, str]] = {
    "Mothman-P": {"race": "P", "race_full": "Protoss", "bot_path": "bots/Mothman-P.rkt"},
    "Mothman-T": {"race": "T", "race_full": "Terran", "bot_path": "bots/Mothman-T.rkt"},
    "Mothman-Z": {"race": "Z", "race_full": "Zerg", "bot_path": "bots/Mothman-Z.rkt"},
    "Mothman-X": {"race": "R", "race_full": "Random", "bot_path": "bots/Mothman-R.rkt"},
}

# Full-game Self-Play schedule covering all 6 canonical SC2 matchups (3 mirrors + 3 cross-race)
SELFPLAY_MATCHUPS_6: list[tuple[str, str]] = [
    ("Mothman-Z", "Mothman-Z"),  # ZvZ
    ("Mothman-T", "Mothman-T"),  # TvT
    ("Mothman-P", "Mothman-P"),  # PvP
    ("Mothman-P", "Mothman-T"),  # PvT
    ("Mothman-P", "Mothman-Z"),  # PvZ
    ("Mothman-T", "Mothman-Z"),  # TvZ
]
SELFPLAY_MATCHUPS_REV: list[tuple[str, str]] = [
    ("Mothman-Z", "Mothman-Z"),  # ZvZ
    ("Mothman-T", "Mothman-T"),  # TvT
    ("Mothman-P", "Mothman-P"),  # PvP
    ("Mothman-T", "Mothman-P"),  # TvP
    ("Mothman-Z", "Mothman-P"),  # ZvP
    ("Mothman-Z", "Mothman-T"),  # ZvT
]

RACE_NORMALIZE = {
    "P": "P",
    "PROTOSS": "P",
    "T": "T",
    "TERRAN": "T",
    "Z": "Z",
    "ZERG": "Z",
    "R": "R",
    "RANDOM": "R",
}

SUPPORTED_BOT_TYPES = {"python", "cpplinux", "dotnetcore", "java", "nodejs", "cppwin32"}


@dataclass(frozen=True)
class BotSpec:
    name: str
    race: str  # P, T, Z, R
    bot_type: str  # python, cpplinux, dotnetcore, java, nodejs
    source_dir: Path | None = None
    is_mothman: bool = False
    source_bot_name: str = ""  # underlying Mothman variant when aliased (e.g. Mothman-P-SP -> Mothman-P)
    bot_mode: str = ""         # zip | elf | source (allows mixed source-vs-zip selfplay baseline!)
    elo: int | float | None = None
    aiarena_id: int | str | None = None
    gauntlet_core: bool = False
    active_comp38: bool = False
    archetype: str = ""
    tier: str = ""


@dataclass(frozen=True)
class MatchTask:
    index: int
    bot1: BotSpec
    bot2: BotSpec
    map_name: str
    slug: str
    cohort: str = "core"  # core | unseen | selfplay | custom
    est_wall_sec: float | None = None
    random_seed: int = 0


def normalize_bench_seed(raw: str | None) -> str:
    s = (raw or "").strip()
    if s.lower() in RANDOM_BENCH_SEEDS:
        return "random"
    return s


def deterministic_map_and_seed(
    bench_seed: str | None,
    bot1_name: str,
    bot2_name: str,
    rep: int,
    maps: list[str],
) -> tuple[str, int]:
    """Deterministically assign (map_name, sc2_random_seed) from canonical matchup key.

    Uses SHA-256 of (bench_seed, bot1_name, bot2_name, rep) against sorted(maps)
    BEFORE any scheduling sort (LPT/interleaved/sequential) so map and SC2 RNG seed
    are 100% invariant to historical wall-time drift, schedule order, and opponent subsetting.
    When bench_seed is 'random' / '0' / '', returns random_seed=0 (SC2 random) while keeping
    deterministic map selection under DEFAULT_BENCH_SEED.
    """
    if not maps:
        raise ValueError("maps list must be non-empty")
    canonical_maps = sorted(maps)
    norm_seed = normalize_bench_seed(bench_seed)
    map_seed_key = DEFAULT_BENCH_SEED if norm_seed == "random" else norm_seed
    map_digest = hashlib.sha256(
        f"{map_seed_key}|{MAP_HASH_SALT}|{bot1_name}|{bot2_name}|{int(rep)}".encode("utf-8")
    ).digest()
    map_name = canonical_maps[int.from_bytes(map_digest[:8], "big") % len(canonical_maps)]
    if norm_seed == "random":
        return map_name, 0
    rng_digest = hashlib.sha256(
        f"{norm_seed}|rng|{bot1_name}|{bot2_name}|{int(rep)}".encode("utf-8")
    ).digest()
    sc2_seed = (int.from_bytes(rng_digest[:4], "big") % 2147483647) + 1
    return map_name, sc2_seed


ACTIVE_CONTAINERS: set[str] = set()
ACTIVE_LOCK = threading.Lock()
PRINT_LOCK = threading.Lock()
SHUTDOWN_EVENT = threading.Event()


def log(msg: str) -> None:
    with PRINT_LOCK:
        print(msg, flush=True)


def normalize_race(raw: str) -> str:
    key = (raw or "").strip().upper()
    if key not in RACE_NORMALIZE:
        raise ValueError(f"Unsupported SC2 race: {raw!r}")
    return RACE_NORMALIZE[key]


def normalize_bot_type(raw: str) -> str:
    key = (raw or "").strip().lower()
    if key not in SUPPORTED_BOT_TYPES:
        raise ValueError(f"Unsupported AI Arena bot type: {raw!r}")
    return key


def sanitize_slug(s: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("_")


def detect_container_runtime(preferred: str | None = None) -> str:
    candidates = [preferred] if preferred else ["podman", "docker"]
    for c in candidates:
        if c and shutil.which(c):
            return c
    raise RuntimeError("Neither podman nor docker was found in PATH.")


def get_repo_commit(repo_dir: Path) -> str:
    for cmd in (["git", "rev-parse", "--short=8", "HEAD"],
                ["jj", "log", "-r", "@-", "--no-graph", "-T", "commit_id.short(8)"]):
        try:
            out = subprocess.check_output(cmd, cwd=repo_dir, stderr=subprocess.DEVNULL, text=True).strip()
            if out:
                return out
        except Exception:
            pass
    return "unknown"


def load_roster(bots_dir: Path, roster_path: Path | None = None) -> dict[str, BotSpec]:
    specs: dict[str, BotSpec] = {}
    rp = roster_path or (bots_dir / "roster.json")
    if rp.exists():
        raw = json.loads(rp.read_text(encoding="utf-8"))
        if isinstance(raw, dict):
            entries = raw.get("bots") or raw.get("opponents") or raw.get("roster")
            if isinstance(entries, list):
                items = entries
            else:
                items = [{"name": k, **v} for k, v in raw.items() if isinstance(v, dict)]
        elif isinstance(raw, list):
            items = raw
        else:
            items = []

        for entry in items:
            if not isinstance(entry, dict):
                continue
            name = str(entry.get("name") or entry.get("bot_name") or "").strip()
            if not name:
                continue
            bot_dir = bots_dir / name
            if not bot_dir.is_dir():
                continue
            try:
                race = normalize_race(str(entry.get("race") or entry.get("plays_race") or "R"))
                btype = normalize_bot_type(str(entry.get("type") or entry.get("bot_type") or infer_bot_type(bot_dir, name)))
            except ValueError:
                continue
            specs[name] = BotSpec(
                name=name,
                race=race,
                bot_type=btype,
                source_dir=bot_dir,
                is_mothman=False,
                elo=entry.get("elo"),
                aiarena_id=entry.get("aiarena_id") or entry.get("id"),
                gauntlet_core=bool(entry.get("gauntlet_core", False)),
                active_comp38=bool(entry.get("active_comp38", False)),
                archetype=str(entry.get("archetype") or ""),
                tier=str(entry.get("tier") or ""),
            )

    # Also auto-discover any unpacked bot directories not in roster.json
    if bots_dir.is_dir():
        for child in sorted(bots_dir.iterdir()):
            if not child.is_dir() or child.name in specs or child.name.startswith("."):
                continue
            inferred = infer_bot_type(child, child.name)
            if inferred:
                specs[child.name] = BotSpec(
                    name=child.name,
                    race="R",
                    bot_type=inferred,
                    source_dir=child,
                    is_mothman=False,
                )
    return specs


def infer_bot_type(bot_dir: Path, name: str) -> str | None:
    if (bot_dir / "run.py").is_file():
        return "python"
    if (bot_dir / f"{name}.dll").is_file():
        return "dotnetcore"
    if (bot_dir / f"{name}.jar").is_file():
        return "java"
    if (bot_dir / f"{name}.js").is_file():
        return "nodejs"
    if (bot_dir / f"{name}.exe").is_file():
        return "cppwin32"
    if (bot_dir / name).is_file():
        return "cpplinux"
    return None


def discover_maps(maps_dir: Path, selection: str) -> list[str]:
    available = {p.stem: p for p in sorted(maps_dir.glob("*.SC2Map"))}
    if not available:
        raise RuntimeError(f"No .SC2Map files found in {maps_dir}")

    sel = selection.strip()
    if sel.lower() == "season":
        manifest = maps_dir / "maps_manifest.json"
        if manifest.is_file():
            data = json.loads(manifest.read_text(encoding="utf-8"))
            names = [
                Path(m["filename"]).stem if "filename" in m else str(m["name"]).replace(".SC2Map", "")
                for m in data.get("maps", [])
            ]
            chosen = [n for n in names if n in available]
            if chosen:
                return chosen
        return sorted(available.keys())

    if sel.lower() == "all":
        return sorted(available.keys())

    chosen: list[str] = []
    for item in [x.strip() for x in sel.split(",") if x.strip()]:
        stem = item[:-7] if item.lower().endswith(".sc2map") else item
        if stem not in available:
            # Case-insensitive fallback
            ci = {k.lower(): k for k in available}
            if stem.lower() in ci:
                stem = ci[stem.lower()]
            else:
                raise ValueError(f"Map {item!r} not found in {maps_dir}. Available: {sorted(available.keys())}")
        chosen.append(stem)
    if not chosen:
        raise ValueError("No maps selected.")
    return chosen


def ensure_portable_racket_etc(arena_dir: Path, repo_dir: Path) -> Path:
    etc_dir = arena_dir / "cache" / "racket-etc"
    etc_dir.mkdir(parents=True, exist_ok=True)
    cfg_out = etc_dir / "config.rktd"
    host_cfg = Path("/etc/racket/config.rktd")
    portable_cfg = repo_dir / "ladder" / ".cache" / "portable-etc" / "config.rktd"
    src_cfg = portable_cfg if portable_cfg.is_file() else host_cfg
    if not src_cfg.is_file():
        raise RuntimeError(f"Cannot locate Racket config.rktd at {portable_cfg} or {host_cfg}")
    text = src_cfg.read_text(encoding="utf-8")
    text = re.sub(r'\(bin-dir\s*\.\s*"[^"]+"\)', '(bin-dir . "/usr/local/bin")', text)
    cfg_out.write_text(text, encoding="utf-8")
    return etc_dir


def stage_mothman_cache(bot_name: str, mode: str, arena_dir: Path, repo_dir: Path) -> Path:
    if bot_name not in MOTHMAN_VARIANTS:
        raise ValueError(f"Unknown Mothman variant: {bot_name}")
    meta = MOTHMAN_VARIANTS[bot_name]

    if mode == "zip":
        zip_path = repo_dir / "ladder" / f"{bot_name}.zip"
        if not zip_path.is_file():
            raise RuntimeError(f"Missing Mothman zip: {zip_path} (run ladder/build-aiarena-zip.rkt or use --mothman-mode source)")
        st = zip_path.stat()
        sig = f"{st.st_size}:{st.st_mtime_ns}"
        dest = arena_dir / "cache" / "mothman_zip" / bot_name
        stamp = dest / ".zip_stamp"
        if stamp.is_file() and stamp.read_text(encoding="utf-8").strip() == sig and (dest / bot_name).is_file():
            return dest
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall(dest)
        exe = dest / bot_name
        if not exe.is_file():
            raise RuntimeError(f"Expected executable {exe} inside {zip_path}")
        exe.chmod(0o755)
        (dest / "data").mkdir(exist_ok=True)
        stamp.write_text(sig, encoding="utf-8")
        return dest

    if mode == "elf":
        elf_path = repo_dir / "ladder" / ".cache" / "mothman_standalone_elf"
        if not elf_path.is_file():
            raise RuntimeError(f"Missing standalone ELF: {elf_path}")
        st = elf_path.stat()
        sig = f"{st.st_size}:{st.st_mtime_ns}"
        dest = arena_dir / "cache" / "mothman_elf" / bot_name
        stamp = dest / ".elf_stamp"
        if stamp.is_file() and stamp.read_text(encoding="utf-8").strip() == sig and (dest / bot_name).is_file():
            return dest
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True, exist_ok=True)
        copy_file_cow(elf_path, dest / bot_name)
        (dest / bot_name).chmod(0o755)
        (dest / "config.json").write_text(
            json.dumps({"BotName": bot_name, "BotRace": meta["race_full"], "BotPath": meta["bot_path"]}, indent=2) + "\n",
            encoding="utf-8",
        )
        (dest / "data").mkdir(exist_ok=True)
        (dest / "data" / "mirror_mind_opponents.json").write_text(
            json.dumps({"bot_name": bot_name, "opponents": {}}, indent=2) + "\n",
            encoding="utf-8",
        )
        stamp.write_text(sig, encoding="utf-8")
        return dest

    if mode == "source":
        portable_racket = repo_dir / "ladder" / ".cache" / "racket_runtime" / "bin" / "racket"
        if not portable_racket.is_file():
            raise RuntimeError(f"Missing portable Racket binary at {portable_racket}")
        ensure_portable_racket_etc(arena_dir, repo_dir)
        dest = arena_dir / "cache" / "mothman_source" / bot_name
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "config.json").write_text(
            json.dumps(
                {
                    "BotName": bot_name,
                    "BotRace": meta["race_full"],
                    "BotPath": f"/mothman-repo/{meta['bot_path']}",
                },
                indent=2,
            ) + "\n",
            encoding="utf-8",
        )
        launcher = dest / bot_name
        # CRITICAL: `exec` replaces the shell so `bot_controller`'s PID-to-TCP-port lookup sees `racket`!
        launcher.write_text(
            "#!/bin/sh\n"
            f"exec /usr/local/bin/racket -U -X /usr/share/racket/collects -G /etc/racket-portable "
            f"/mothman-repo/sim/racket-sc2-ladder-main.rkt --BotName {bot_name} \"$@\"\n",
            encoding="utf-8",
        )
        launcher.chmod(0o755)
        (dest / "data").mkdir(exist_ok=True)
        (dest / "data" / "mirror_mind_opponents.json").write_text(
            json.dumps({"bot_name": bot_name, "opponents": {}}, indent=2) + "\n",
            encoding="utf-8",
        )
        return dest

    raise ValueError(f"Unknown mothman mode: {mode}")


def copy_file_cow(src: Path, dst: Path) -> None:
    try:
        subprocess.run(["cp", "--reflink=auto", "-p", str(src), str(dst)], check=True)
    except Exception:
        shutil.copy2(src, dst)


def clone_bot_dir(src: Path, dst: Path, orig_name: str, alias_name: str, bot_type: str) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    try:
        subprocess.run(["cp", "--reflink=auto", "-a", str(src), str(dst)], check=True)
    except Exception:
        shutil.copytree(src, dst, symlinks=True)

    # Ensure isolated writable data dir
    (dst / "data").mkdir(exist_ok=True)

    # If aliased for a mirror / self-play match, rename the expected entry binary & update BotName metadata
    if alias_name != orig_name:
        ext_map = {
            "cpplinux": "",
            "dotnetcore": ".dll",
            "java": ".jar",
            "nodejs": ".js",
            "cppwin32": ".exe",
        }
        if bot_type in ext_map:
            ext = ext_map[bot_type]
            orig_file = dst / f"{orig_name}{ext}"
            alias_file = dst / f"{alias_name}{ext}"
            if orig_file.is_file() and not alias_file.exists():
                orig_file.rename(alias_file)
        # Update config.json BotName & source-mode shell launcher --BotName flag if present
        cfg_json = dst / "config.json"
        if cfg_json.is_file():
            try:
                cfg_obj = json.loads(cfg_json.read_text(encoding="utf-8"))
                if isinstance(cfg_obj, dict) and "BotName" in cfg_obj:
                    cfg_obj["BotName"] = alias_name
                    cfg_json.write_text(json.dumps(cfg_obj, indent=2) + "\n", encoding="utf-8")
            except Exception:
                pass
        mm_json = dst / "data" / "mirror_mind_opponents.json"
        if mm_json.is_file():
            try:
                mm_obj = json.loads(mm_json.read_text(encoding="utf-8"))
                if isinstance(mm_obj, dict) and "bot_name" in mm_obj:
                    mm_obj["bot_name"] = alias_name
                    mm_json.write_text(json.dumps(mm_obj, indent=2) + "\n", encoding="utf-8")
            except Exception:
                pass
        if bot_type == "cpplinux":
            exe_script = dst / alias_name
            if exe_script.is_file():
                try:
                    raw_head = exe_script.read_bytes()[:16]
                    if raw_head.startswith(b"#!/bin/sh"):
                        txt = exe_script.read_text(encoding="utf-8")
                        txt = txt.replace(f"--BotName {orig_name} ", f"--BotName {alias_name} ")
                        exe_script.write_text(txt, encoding="utf-8")
                except Exception:
                    pass

    if bot_type == "cpplinux":
        exe = dst / alias_name
        if exe.is_file():
            mode = exe.stat().st_mode
            exe.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def write_config_toml(path: Path, max_game_time: int, max_frame_time: int, strikes: int, realtime: bool) -> None:
    content = f"""ARENA_CLIENT_ID = "aiarenaclient_local"
ROUNDS_PER_RUN = -1
BASE_WEBSITE_URL = ""
DEBUG_MODE = true
PYTHON = "python"
RUN_TYPE = "local"
SECURE_MODE = false

LOGGING_LEVEL = "info"
LOG_ROOT = "/logs"

REPLAYS_DIRECTORY = "/replays"
BOTS_DIRECTORY = "/bots"

MAX_GAME_TIME = {max_game_time}
MAX_REAL_TIME = 7200
MAX_FRAME_TIME = {max_frame_time}
STRIKES = {strikes}
REALTIME = {"true" if realtime else "false"}
VISUALIZE = false

DISABLE_DEBUG = true
VALIDATE_RACE = false

MATCHES_FILE = "/app/matches"
RESULTS_FILE = "/app/results.json"

BOT_CONT_1_HOST = "127.0.0.1"
BOT_CONT_1_PORT = 8081
BOT_CONT_2_HOST = "127.0.0.1"
BOT_CONT_2_PORT = 8082
SC2_CONT_HOST = "127.0.0.1"
SC2_CONT_PORT = 8083
"""
    path.write_text(content, encoding="utf-8")


def parse_mothman_telemetry(log_path: Path) -> dict[str, Any]:
    if not log_path.is_file():
        return {}
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return {}
    for line in reversed(lines):
        s = line.strip()
        if s.startswith("{") and s.endswith("}"):
            try:
                obj = json.loads(s)
                if isinstance(obj, dict) and ("status" in obj or "engine" in obj or "bot_name" in obj):
                    return obj
            except Exception:
                continue
    return {}


APM_DROP_TIERS = ("P0", "P1", "P2", "P3", "P4")


def _normalize_ability_counts(raw: Any) -> dict[str, int]:
    counts: dict[str, int] = {}
    if isinstance(raw, dict):
        for k, v in raw.items():
            key = str(k).strip()
            if not key:
                continue
            try:
                iv = int(v)
            except Exception:
                continue
            if iv > 0:
                counts[key] = counts.get(key, 0) + iv
    elif isinstance(raw, list):
        for item in raw:
            if isinstance(item, (list, tuple)) and len(item) >= 2:
                key = str(item[0]).strip()
                try:
                    iv = int(item[1])
                except Exception:
                    continue
                if key and iv > 0:
                    counts[key] = counts.get(key, 0) + iv
            elif isinstance(item, dict):
                key = str(item.get("ability") or item.get("id") or "").strip()
                try:
                    iv = int(item.get("count", 0))
                except Exception:
                    continue
                if key and iv > 0:
                    counts[key] = counts.get(key, 0) + iv
    return dict(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))


def parse_apm_cap_drops_line(line: str) -> dict[str, Any] | None:
    """Parse a single `[APM_CAP_DROPS] ...` stderr line."""
    idx = line.find("[APM_CAP_DROPS]")
    if idx < 0:
        return None
    tail = line[idx + len("[APM_CAP_DROPS]"):].strip()
    if not tail:
        return None

    def _int_field(names: tuple[str, ...]) -> int:
        for nm in names:
            m = re.search(rf"\b{re.escape(nm)}=(-?\d+)\b", tail)
            if m:
                return int(m.group(1))
        return 0

    total = _int_field(("total",))
    tok = _int_field(("tok", "token_bucket"))
    cap = _int_field(("cap", "rolling_hard_cap"))
    by_tier = {t: _int_field((t, t.lower())) for t in APM_DROP_TIERS}

    top_abilities: dict[str, int] = {}
    m_top = re.search(r"\btop=([^\s]+)", tail)
    if m_top:
        raw_top = m_top.group(1).strip()
        if raw_top and raw_top.lower() not in ("none", "-", "()", "null"):
            for entry in raw_top.split(","):
                entry = entry.strip()
                if ":" not in entry:
                    continue
                ab, cnt_s = entry.rsplit(":", 1)
                ab = ab.strip()
                try:
                    cnt = int(cnt_s.strip())
                except Exception:
                    continue
                if ab and cnt > 0:
                    top_abilities[ab] = top_abilities.get(ab, 0) + cnt
            top_abilities = dict(sorted(top_abilities.items(), key=lambda kv: (-kv[1], kv[0])))

    return {
        "total": total,
        "tok": tok,
        "cap": cap,
        "by_tier": by_tier,
        "top_abilities": top_abilities,
    }


def parse_apm_cap_drops(log_path: Path, telemetry: dict[str, Any] | None = None) -> dict[str, Any] | None:
    """Extract per-match APM-cap drop telemetry from JSON summary or `[APM_CAP_DROPS]` stderr line."""
    if isinstance(telemetry, dict) and isinstance(telemetry.get("apm_cap_drops"), dict):
        raw = telemetry["apm_cap_drops"]
        bt_raw = raw.get("by_tier") if isinstance(raw.get("by_tier"), dict) else {}
        by_tier = {
            t: int(bt_raw.get(t, bt_raw.get(t.lower(), 0)) or 0)
            for t in APM_DROP_TIERS
        }
        top_src = raw.get("top_abilities") if raw.get("top_abilities") is not None else raw.get("by_ability")
        out: dict[str, Any] = {
            "total": int(raw.get("total", 0) or 0),
            "tok": int(raw.get("token_bucket", raw.get("tok", 0)) or 0),
            "cap": int(raw.get("rolling_hard_cap", raw.get("cap", 0)) or 0),
            "by_tier": by_tier,
            "top_abilities": _normalize_ability_counts(top_src),
        }
        if isinstance(raw.get("by_minute"), dict):
            bm: dict[str, int] = {}
            for k, v in raw["by_minute"].items():
                try:
                    iv = int(v)
                except Exception:
                    continue
                if iv > 0:
                    bm[str(k)] = iv
            if bm:
                out["by_minute"] = dict(sorted(bm.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 9999))
        return out

    if not log_path.is_file():
        return None
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return None
    for line in reversed(lines):
        if "[APM_CAP_DROPS]" in line:
            parsed = parse_apm_cap_drops_line(line)
            if parsed is not None:
                return parsed
    return None


def aggregate_apm_cap_drops(records: list[dict[str, Any]]) -> dict[str, Any]:
    """Aggregate per-match APM-cap drop stats across a run."""
    matches_parsed = 0
    matches_with_drops = 0
    total_drops = 0
    total_tok = 0
    total_cap = 0
    by_tier = {t: 0 for t in APM_DROP_TIERS}
    ability_totals: dict[str, int] = {}
    minute_totals: dict[str, int] = {}
    worst: list[dict[str, Any]] = []

    for r in records:
        d = r.get("apm_cap_drops")
        if not isinstance(d, dict):
            telem = r.get("our_telemetry")
            if isinstance(telem, dict) and isinstance(telem.get("apm_cap_drops"), dict):
                d = parse_apm_cap_drops(Path(), telem)
        if not isinstance(d, dict):
            continue
        matches_parsed += 1
        tot = int(d.get("total", 0) or 0)
        tok = int(d.get("tok", d.get("token_bucket", 0)) or 0)
        cap = int(d.get("cap", d.get("rolling_hard_cap", 0)) or 0)
        total_drops += tot
        total_tok += tok
        total_cap += cap
        bt = d.get("by_tier") if isinstance(d.get("by_tier"), dict) else {}
        tier_row: dict[str, int] = {}
        for t in APM_DROP_TIERS:
            v = int(bt.get(t, bt.get(t.lower(), 0)) or 0)
            by_tier[t] += v
            tier_row[t] = v
        ab_map = _normalize_ability_counts(d.get("top_abilities") if d.get("top_abilities") is not None else d.get("by_ability"))
        for ab, cnt in ab_map.items():
            ability_totals[ab] = ability_totals.get(ab, 0) + cnt
        if isinstance(d.get("by_minute"), dict):
            for mk, mv in d["by_minute"].items():
                try:
                    iv = int(mv)
                except Exception:
                    continue
                if iv > 0:
                    minute_totals[str(mk)] = minute_totals.get(str(mk), 0) + iv
        if tot > 0:
            matches_with_drops += 1
            worst.append({
                "index": r.get("index"),
                "bot1": r.get("bot1"),
                "bot2": r.get("bot2"),
                "map": r.get("map"),
                "outcome": r.get("outcome"),
                "total": tot,
                "tok": tok,
                "cap": cap,
                "by_tier": tier_row,
                "top_abilities": dict(list(ab_map.items())[:5]),
            })

    top_abilities = dict(sorted(ability_totals.items(), key=lambda kv: (-kv[1], kv[0]))[:12])
    worst.sort(key=lambda item: (-item["total"], item.get("index") or 0))
    out: dict[str, Any] = {
        "matches_parsed": matches_parsed,
        "matches_with_drops": matches_with_drops,
        "total_drops": total_drops,
        "tok": total_tok,
        "cap": total_cap,
        "by_tier": by_tier,
        "top_abilities": top_abilities,
        "worst_matches": worst[:5],
    }
    if minute_totals:
        out["by_minute"] = dict(sorted(minute_totals.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 9999))
    return out


def classify_result(raw_result: str) -> str:
    if raw_result in ("Player1Win", "Player2Crash", "Player2TimeOut"):
        return "Win"
    if raw_result in ("Player2Win", "Player1Crash", "Player1TimeOut"):
        return "Loss"
    if raw_result == "Tie":
        return "Tie"
    return "Error"


def force_rm_container(runtime: str, cname: str) -> None:
    try:
        subprocess.run(
            [runtime, "rm", "-f", cname],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=20,
        )
    except Exception:
        pass


def run_single_match(
    task: MatchTask,
    total_matches: int,
    run_dir: Path,
    arena_dir: Path,
    repo_dir: Path,
    mothman_mode: str,
    image: str,
    runtime: str,
    timeout_sec: int,
    max_game_time: int,
    max_frame_time: int,
    strikes: int,
    realtime: bool,
    keep_workdirs: bool,
    run_id_short: str,
    network_mode: str = "none",
    launch_delay_sec: float = 0.0,
) -> dict[str, Any]:
    if launch_delay_sec > 0.0 and not SHUTDOWN_EVENT.is_set():
        SHUTDOWN_EVENT.wait(timeout=launch_delay_sec)
    if SHUTDOWN_EVENT.is_set():
        return {
            "index": task.index,
            "slug": task.slug,
            "cohort": task.cohort,
            "bot1": task.bot1.name,
            "bot1_race": task.bot1.race,
            "bot2": task.bot2.name,
            "bot2_race": task.bot2.race,
            "bot2_type": task.bot2.bot_type,
            "bot2_elo": task.bot2.elo,
            "map": task.map_name,
            "raw_result": "Cancelled",
            "outcome": "Error",
            "game_steps": 0,
            "game_minutes": 0.0,
            "wall_sec": 0.0,
        }

    workdir = run_dir / "workdirs" / task.slug
    bots_dir = workdir / "bots"
    logs_dir = workdir / "logs"
    replays_dir = workdir / "replays"
    for d in (bots_dir, logs_dir, replays_dir):
        d.mkdir(parents=True, exist_ok=True)

    bot1_alias = task.bot1.name
    bot2_alias = f"{task.bot2.name}_p2" if task.bot2.name == task.bot1.name else task.bot2.name
    bot1_orig = task.bot1.source_bot_name or task.bot1.name
    bot2_orig = task.bot2.source_bot_name or task.bot2.name

    assert task.bot1.source_dir is not None and task.bot2.source_dir is not None
    clone_bot_dir(task.bot1.source_dir, bots_dir / bot1_alias, bot1_orig, bot1_alias, task.bot1.bot_type)
    clone_bot_dir(task.bot2.source_dir, bots_dir / bot2_alias, bot2_orig, bot2_alias, task.bot2.bot_type)

    cfg_path = workdir / "config.toml"
    write_config_toml(cfg_path, max_game_time, max_frame_time, strikes, realtime)

    matches_path = workdir / "matches"
    matches_path.write_text(
        f"1,{bot1_alias},{task.bot1.race},{task.bot1.bot_type},"
        f"2,{bot2_alias},{task.bot2.race},{task.bot2.bot_type},"
        f"{task.map_name}\n",
        encoding="utf-8",
    )

    results_path = workdir / "results.json"
    results_path.write_text("", encoding="utf-8")

    cname = f"sc2a-{run_id_short}-m{task.index:03d}-{os.getpid()}"
    maps_host_dir = arena_dir / "maps"
    proxy_script = Path(__file__).resolve().parent / "sc2-match-proxy.py"

    cmd = [
        runtime,
        "run",
        "--rm",
        "--name",
        cname,
        "--entrypoint",
        "python",
    ]
    if network_mode:
        cmd.extend(["--network", network_mode])
    cmd.extend([
        "-v",
        f"{maps_host_dir}:/root/StarCraftII/Maps:ro",
        "-v",
        f"{bots_dir}:/bots:rw",
        "-v",
        f"{logs_dir}:/logs:rw",
        "-v",
        f"{replays_dir}:/replays:rw",
        "-v",
        f"{results_path}:/app/results.json:rw",
        "-v",
        f"{proxy_script}:/harness/sc2-match-proxy.py:ro",
    ])

    need_source_racket = (
        task.bot1.bot_mode == "source"
        or task.bot2.bot_mode == "source"
        or (mothman_mode == "source" and (task.bot1.is_mothman or task.bot2.is_mothman))
    )
    if need_source_racket:
        racket_etc = arena_dir / "cache" / "racket-etc"
        portable_racket = repo_dir / "ladder" / ".cache" / "racket_runtime" / "bin" / "racket"
        cmd.extend([
            "-v", f"{racket_etc}:/etc/racket-portable:ro",
            "-v", f"{portable_racket}:/usr/local/bin/racket:ro",
            "-v", "/usr/share/racket:/usr/share/racket:ro",
            "-v", "/usr/lib/x86_64-linux-gnu/racket:/usr/lib/x86_64-linux-gnu/racket:ro",
            "-v", f"{repo_dir}:/mothman-repo:ro",
        ])

    cmd.extend([
        image,
        "/harness/sc2-match-proxy.py",
        "--bot1-name", bot1_alias,
        "--bot1-race", task.bot1.race,
        "--bot1-type", task.bot1.bot_type,
        "--bot1-id", sanitize_slug(task.bot1.name),
        "--bot2-name", bot2_alias,
        "--bot2-race", task.bot2.race,
        "--bot2-type", task.bot2.bot_type,
        "--bot2-id", sanitize_slug(task.bot2.name),
        "--map", task.map_name,
        "--replay-path", f"/replays/{task.slug}.SC2Replay",
        "--results-path", "/app/results.json",
        "--max-game-time", str(max_game_time),
        "--wall-timeout-sec", str(max(30, timeout_sec - 25)),
    ])
    if task.random_seed > 0:
        cmd.extend(["--random-seed", str(task.random_seed)])
    if realtime:
        cmd.append("--realtime")

    controller_log_dest = run_dir / "logs" / f"{task.slug}_controller.log"
    our_log_dest = run_dir / "logs" / f"{task.slug}_{sanitize_slug(task.bot1.name)}.log"
    opp_log_dest = run_dir / "logs" / f"{task.slug}_{sanitize_slug(task.bot2.name)}.log"
    replay_dest = run_dir / "replays" / f"{task.slug}.SC2Replay"

    t0 = time.monotonic()
    timed_out = False
    exit_code = -1

    with ACTIVE_LOCK:
        ACTIVE_CONTAINERS.add(cname)

    try:
        with controller_log_dest.open("wb") as clog:
            proc = subprocess.Popen(cmd, stdout=clog, stderr=subprocess.STDOUT)
            try:
                exit_code = proc.wait(timeout=timeout_sec)
            except subprocess.TimeoutExpired:
                timed_out = True
                force_rm_container(runtime, cname)
                try:
                    proc.kill()
                    proc.wait(timeout=10)
                except Exception:
                    pass
    except Exception as exc:
        with controller_log_dest.open("ab") as clog:
            clog.write(f"\n[HARNESS_ERROR] {exc!r}\n".encode("utf-8"))
        force_rm_container(runtime, cname)
    finally:
        with ACTIVE_LOCK:
            ACTIVE_CONTAINERS.discard(cname)
        # Belt-and-suspenders: make sure container is gone
        if timed_out or SHUTDOWN_EVENT.is_set():
            force_rm_container(runtime, cname)

    wall_sec = round(time.monotonic() - t0, 2)

    # Collect replay
    replay_saved = ""
    found_replays = sorted(replays_dir.glob("*.SC2Replay"))
    if found_replays:
        shutil.copy2(found_replays[0], replay_dest)
        replay_saved = str(replay_dest)

    # Collect bot logs
    our_src_log = logs_dir / bot1_alias / "stderr.log"
    opp_src_log = logs_dir / bot2_alias / "stderr.log"
    our_log_saved = ""
    opp_log_saved = ""
    if our_src_log.is_file():
        shutil.copy2(our_src_log, our_log_dest)
        our_log_saved = str(our_log_dest)
    if opp_src_log.is_file():
        shutil.copy2(opp_src_log, opp_log_dest)
        opp_log_saved = str(opp_log_dest)

    # Parse results.json
    raw_result = "HarnessTimeout" if timed_out else "ContainerError"
    game_steps = 0
    bot1_avg_step_ms: float | None = None
    bot2_avg_step_ms: float | None = None
    p1_start_xy: list[float] | None = None
    p2_start_xy: list[float] | None = None
    if results_path.is_file():
        txt = results_path.read_text(encoding="utf-8", errors="replace").strip()
        if txt:
            try:
                rdata = json.loads(txt)
                res_list = rdata.get("results", [])
                if res_list:
                    r0 = res_list[0]
                    raw_result = str(r0.get("type", raw_result))
                    game_steps = int(r0.get("game_steps", 0) or 0)
                    if r0.get("bot1_avg_step_time") is not None:
                        bot1_avg_step_ms = round(float(r0["bot1_avg_step_time"]) * 1000.0, 2)
                    if r0.get("bot2_avg_step_time") is not None:
                        bot2_avg_step_ms = round(float(r0["bot2_avg_step_time"]) * 1000.0, 2)
                    if isinstance(r0.get("p1_start_xy"), list) and len(r0["p1_start_xy"]) == 2:
                        p1_start_xy = [float(r0["p1_start_xy"][0]), float(r0["p1_start_xy"][1])]
                    if isinstance(r0.get("p2_start_xy"), list) and len(r0["p2_start_xy"]) == 2:
                        p2_start_xy = [float(r0["p2_start_xy"][0]), float(r0["p2_start_xy"][1])]
            except Exception:
                pass

    our_telemetry = parse_mothman_telemetry(our_log_dest) if our_log_saved else {}
    opp_telemetry = parse_mothman_telemetry(opp_log_dest) if (opp_log_saved and task.bot2.is_mothman) else {}
    our_apm_cap_drops = parse_apm_cap_drops(our_log_dest, our_telemetry) if our_log_saved else None
    opp_apm_cap_drops = parse_apm_cap_drops(opp_log_dest, opp_telemetry) if (opp_log_saved and task.bot2.is_mothman) else None
    outcome = classify_result(raw_result)
    game_minutes = round(game_steps / (22.4 * 60.0), 2) if game_steps > 0 else 0.0

    # Clean up bulky cloned bots workdir unless requested to keep
    if not keep_workdirs:
        try:
            shutil.rmtree(workdir)
        except Exception:
            pass

    step_str = f"{bot1_avg_step_ms:.2f}ms" if bot1_avg_step_ms is not None else "n/a"
    pw = our_telemetry.get("peak_workers", "-")
    pb = our_telemetry.get("peak_bases", "-")
    pa = our_telemetry.get("peak_army_supply", "-")
    apm_drop_str = f" | apmDrop={our_apm_cap_drops['total']}" if (our_apm_cap_drops and our_apm_cap_drops.get("total", 0) > 0) else ""
    coh_tag = f"[{task.cohort.upper()}] " if task.cohort == "selfplay" else ""
    log(
        f"[{task.index:02d}/{total_matches:02d}] {coh_tag}{task.bot1.name}({task.bot1.race}) vs "
        f"{task.bot2.name}({task.bot2.race},{task.bot2.bot_type}) on {task.map_name} -> "
        f"{outcome} ({raw_result}) | {game_steps} loops ({game_minutes:.1f}m) | "
        f"{wall_sec:.1f}s | step={step_str} | pkW={pw} pkB={pb} pkA={pa}{apm_drop_str}"
    )

    rec: dict[str, Any] = {
        "index": task.index,
        "slug": task.slug,
        "cohort": task.cohort,
        "bot1": task.bot1.name,
        "bot1_race": task.bot1.race,
        "bot2": task.bot2.name,
        "bot2_race": task.bot2.race,
        "bot2_type": task.bot2.bot_type,
        "bot2_elo": task.bot2.elo,
        "map": task.map_name,
        "random_seed": task.random_seed,
        "p1_start_xy": p1_start_xy,
        "p2_start_xy": p2_start_xy,
        "raw_result": raw_result,
        "outcome": outcome,
        "exit_code": exit_code,
        "timed_out": timed_out,
        "game_steps": game_steps,
        "game_minutes": game_minutes,
        "wall_sec": wall_sec,
        "bot1_avg_step_ms": bot1_avg_step_ms,
        "bot2_avg_step_ms": bot2_avg_step_ms,
        "our_telemetry": our_telemetry,
        "replay_path": replay_saved,
        "our_log_path": our_log_saved,
        "opp_log_path": opp_log_saved,
        "controller_log_path": str(controller_log_dest),
    }
    if our_apm_cap_drops is not None:
        rec["apm_cap_drops"] = our_apm_cap_drops
    if opp_telemetry:
        rec["opp_telemetry"] = opp_telemetry
    if opp_apm_cap_drops is not None:
        rec["opp_apm_cap_drops"] = opp_apm_cap_drops
    return rec


def aggregate_records(records: list[dict[str, Any]]) -> dict[str, Any]:
    wins = sum(1 for r in records if r["outcome"] == "Win")
    clean_wins = sum(1 for r in records if r["raw_result"] == "Player1Win")
    opp_fault_wins = wins - clean_wins
    losses = sum(1 for r in records if r["outcome"] == "Loss")
    clean_losses = sum(1 for r in records if r["raw_result"] == "Player2Win")
    our_fault_losses = losses - clean_losses
    ties = sum(1 for r in records if r["outcome"] == "Tie")
    errors = sum(1 for r in records if r["outcome"] == "Error")
    decided = wins + losses + ties
    win_rate = round(100.0 * wins / decided, 1) if decided > 0 else 0.0
    avg_wall = round(sum(r["wall_sec"] for r in records) / len(records), 1) if records else 0.0
    avg_min = round(sum(r["game_minutes"] for r in records) / len(records), 2) if records else 0.0
    step_vals = [r["bot1_avg_step_ms"] for r in records if r.get("bot1_avg_step_ms") is not None]
    avg_step_ms = round(sum(step_vals) / len(step_vals), 2) if step_vals else None
    mm_avg = [r["our_telemetry"]["avg_step_ms"] for r in records if isinstance(r.get("our_telemetry"), dict) and r["our_telemetry"].get("avg_step_ms") is not None]
    mm_p95 = [r["our_telemetry"]["p95_step_ms"] for r in records if isinstance(r.get("our_telemetry"), dict) and r["our_telemetry"].get("p95_step_ms") is not None]
    mm_max = [r["our_telemetry"]["max_step_ms"] for r in records if isinstance(r.get("our_telemetry"), dict) and r["our_telemetry"].get("max_step_ms") is not None]
    return {
        "matches": len(records),
        "wins": wins,
        "clean_wins": clean_wins,
        "opp_crash_or_timeout_wins": opp_fault_wins,
        "losses": losses,
        "clean_losses": clean_losses,
        "our_crash_or_timeout_losses": our_fault_losses,
        "ties": ties,
        "errors": errors,
        "win_rate_pct": win_rate,
        "avg_game_minutes": avg_min,
        "avg_wall_sec": avg_wall,
        "avg_bot1_step_ms": avg_step_ms,
        "mothman_avg_step_ms": round(sum(mm_avg) / len(mm_avg), 2) if mm_avg else None,
        "mothman_p95_step_ms": round(sum(mm_p95) / len(mm_p95), 2) if mm_p95 else None,
        "mothman_max_step_ms": round(max(mm_max), 2) if mm_max else None,
    }


def aggregate_spawn_balance(records: list[dict[str, Any]]) -> dict[str, Any]:
    """Compute North/South and quadrant spawn balance from (p1_start_xy, p2_start_xy).

    Uses relative placement (p1_y >= p2_y -> North, p1_x >= p2_x -> East) so it works
    cleanly on any map size without needing map dimensions.
    """
    def _bucket(rows: list[dict[str, Any]]) -> dict[str, Any]:
        north = south = 0
        quads = {"NE": 0, "NW": 0, "SE": 0, "SW": 0}
        for r in rows:
            p1 = r.get("p1_start_xy")
            p2 = r.get("p2_start_xy")
            if not (isinstance(p1, list) and len(p1) == 2 and isinstance(p2, list) and len(p2) == 2):
                continue
            is_n = float(p1[1]) >= float(p2[1])
            is_e = float(p1[0]) >= float(p2[0])
            if is_n:
                north += 1
            else:
                south += 1
            q = ("N" if is_n else "S") + ("E" if is_e else "W")
            quads[q] += 1
        n = north + south
        return {
            "observed": n,
            "north": north,
            "south": south,
            "north_pct": round(100.0 * north / n, 1) if n > 0 else 0.0,
            "south_pct": round(100.0 * south / n, 1) if n > 0 else 0.0,
            "quadrants": quads,
        }

    by_bot: dict[str, Any] = {}
    for b in sorted({str(r.get("bot1") or "") for r in records if r.get("bot1")}):
        by_bot[b] = _bucket([r for r in records if r.get("bot1") == b])
    return {
        "overall": _bucket(records),
        "by_bot": by_bot,
    }


def format_summary_text(summary: dict[str, Any]) -> str:
    t = summary["totals"]
    lines = [
        "=" * 96,
        f"LOCAL REAL-SC2 PARALLEL BENCHMARK SUMMARY | run_id={summary['run_id']}",
        f"commit={summary['repo_commit']} | mode={summary['mothman_mode']} | "
        f"order={summary.get('schedule_order', 'unknown')} | "
        f"concurrency={summary['concurrency']} | wall={summary['wall_elapsed_sec']}s | "
        f"image={summary['image']}",
        "=" * 96,
        f"OVERALL: {t['wins']}W - {t['losses']}L - {t['ties']}T ({t['errors']} err) | "
        f"WR={t['win_rate_pct']}% | clean={t['clean_wins']}W-{t['clean_losses']}L | "
        f"oppFault={t['opp_crash_or_timeout_wins']} | ourFault={t['our_crash_or_timeout_losses']} | "
        f"avgGame={t['avg_game_minutes']}m | avgStep={t['avg_bot1_step_ms']}ms",
    ]
    apm_drops = summary.get("apm_cap_drops")
    if isinstance(apm_drops, dict) and apm_drops.get("matches_parsed", 0) > 0:
        bt = apm_drops.get("by_tier") or {}
        top_ab = apm_drops.get("top_abilities") or {}
        top_str = ",".join(f"{k}:{v}" for k, v in list(top_ab.items())[:6]) or "none"
        worst_list = apm_drops.get("worst_matches") or []
        worst_str = (
            " | worst=" + ",".join(f"#{w['index']}({w['total']})" for w in worst_list[:3])
            if worst_list
            else ""
        )
        lines.append(
            f"APM_CAP_DROPS: total={apm_drops.get('total_drops', 0)} "
            f"(tok={apm_drops.get('tok', 0)}, cap={apm_drops.get('cap', 0)}) | "
            f"matches={apm_drops.get('matches_with_drops', 0)}/{apm_drops.get('matches_parsed', 0)} | "
            f"P0={bt.get('P0', 0)} P1={bt.get('P1', 0)} P2={bt.get('P2', 0)} "
            f"P3={bt.get('P3', 0)} P4={bt.get('P4', 0)} | top={top_str}{worst_str}"
        )
    sb = summary.get("spawn_balance")
    if isinstance(sb, dict):
        ov = sb.get("overall") or {}
        if ov.get("observed", 0) > 0:
            q = ov.get("quadrants") or {}
            per_bot_parts = []
            for bname, bv in sorted((sb.get("by_bot") or {}).items()):
                if bv.get("observed", 0) > 0:
                    short = bname.replace("Mothman-", "")
                    per_bot_parts.append(f"{short}:{bv['north']}N/{bv['south']}S({bv['north_pct']:.0f}%N)")
            per_bot_str = (" | " + " ".join(per_bot_parts)) if per_bot_parts else ""
            lines.append(
                f"Spawn balance: {ov['north']}N/{ov['south']}S ({ov['north_pct']:.1f}%N) "
                f"[NE={q.get('NE', 0)} NW={q.get('NW', 0)} SE={q.get('SE', 0)} SW={q.get('SW', 0)}]"
                f"{per_bot_str}"
            )
    lines.extend([
        "",
        "--- Per Our Bot ---",
    ])
    for k, v in sorted(summary["by_bot"].items()):
        lines.append(
            f"  {k:<12} {v['wins']:>2}W-{v['losses']:<2}L-{v['ties']:<2}T "
            f"(err={v['errors']}) WR={v['win_rate_pct']:>5.1f}% | "
            f"clean={v['clean_wins']}W-{v['clean_losses']}L | avgGame={v['avg_game_minutes']:.1f}m"
        )
    lines.append("")
    lines.append("--- Per Opponent ---")
    for k, v in sorted(summary["by_opponent"].items()):
        lines.append(
            f"  {k:<22} {v['wins']:>2}W-{v['losses']:<2}L-{v['ties']:<2}T "
            f"(err={v['errors']}) WR={v['win_rate_pct']:>5.1f}% | "
            f"clean={v['clean_wins']}W-{v['clean_losses']}L | oppFault={v['opp_crash_or_timeout_wins']}"
        )
    if summary.get("by_cohort"):
        lines.append("")
        lines.append("--- Per Cohort ---")
        for k, v in sorted(summary["by_cohort"].items()):
            lines.append(
                f"  {k:<12} {v['wins']:>2}W-{v['losses']:<2}L-{v['ties']:<2}T "
                f"(err={v['errors']}) WR={v['win_rate_pct']:>5.1f}% | "
                f"clean={v['clean_wins']}W-{v['clean_losses']}L | avgGame={v['avg_game_minutes']:.1f}m"
            )
    lines.append("")
    lines.append("--- Match Details ---")
    lines.append(f"{'#':>3} {'Cohort':<8} {'Bot':<10} {'Opponent':<20} {'Map':<20} {'Outcome':<7} {'RawResult':<16} {'Loops':>6} {'Min':>5} {'Wall':>6} {'Step':>6}")
    for m in summary["matches"]:
        st = f"{m['bot1_avg_step_ms']:.1f}ms" if m.get("bot1_avg_step_ms") is not None else "n/a"
        coh = str(m.get("cohort") or "-")[:8]
        lines.append(
            f"{m['index']:>3} {coh:<8} {m['bot1']:<10} {m['bot2']:<20} {m['map']:<20} "
            f"{m['outcome']:<7} {m['raw_result']:<16} {m['game_steps']:>6} "
            f"{m['game_minutes']:>5.1f} {m['wall_sec']:>5.1f}s {st:>6}"
        )
    lines.append("=" * 96)
    return "\n".join(lines) + "\n"


def resolve_bot_spec(
    name: str,
    roster: dict[str, BotSpec],
    mothman_mode: str,
    arena_dir: Path,
    repo_dir: Path,
    mothman_cache: dict[tuple[str, str], Path],
    alias_name: str = "",
    stage_mothman: bool = True,
) -> BotSpec:
    if name in MOTHMAN_VARIANTS:
        src_dir: Path | None = None
        if stage_mothman:
            ckey = (name, mothman_mode)
            if ckey not in mothman_cache:
                mothman_cache[ckey] = stage_mothman_cache(name, mothman_mode, arena_dir, repo_dir)
            src_dir = mothman_cache[ckey]
        eff_name = alias_name or name
        return BotSpec(
            name=eff_name,
            race=MOTHMAN_VARIANTS[name]["race"],
            bot_type="cpplinux",
            source_dir=src_dir,
            is_mothman=True,
            source_bot_name=name,
            bot_mode=mothman_mode,
        )
    if name in roster:
        return roster[name]
    ci = {k.lower(): k for k in roster}
    if name.lower() in ci:
        return roster[ci[name.lower()]]
    raise ValueError(f"Unknown bot {name!r}. Known Mothman: {sorted(MOTHMAN_VARIANTS)}; Roster: {sorted(roster)}")


CORE_12_HISTORICAL = frozenset({
    "12PoolBot", "Chance", "Creepy_strategies", "RustyNikolaj", "SmoothBrain",
    "Thssprtssbt", "mini-puck", "monsterbot", "oberon", "puck",
    "sludgement2-revived", "titania",
})

# High-signal 6-opponent canary preset (18 matches across Z/T/P; 6 matches for single race)
CANARY_6_OPPONENTS: tuple[str, ...] = (
    "oberon",
    "zig-reapers",
    "AxeFighter",
    "puck",
    "Creepy_strategies",
    "QueenBot",
)

# Built-in fallback wall-clock estimates (seconds) when no historical data exists.
# Preserves known slow-tier priority:
# QueenBot > AxeFighter > puck > Clicadinha > mini-puck > PolyMorph > onlyfans > RustyNikolaj
BUILTIN_SLOW_TIER_WALL_SEC: dict[str, float] = {
    "queenbot": 640.0,
    "axefighter": 610.0,
    "puck": 560.0,
    "clicadinha": 460.0,
    "mini-puck": 410.0,
    "polymorph": 370.0,
    "onlyfans": 310.0,
    "rustynikolaj": 270.0,
}
DEFAULT_FALLBACK_WALL_SEC = 150.0


def _percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return DEFAULT_FALLBACK_WALL_SEC
    idx = int(round(pct * (len(ordered) - 1)))
    idx = max(0, min(len(ordered) - 1, idx))
    return float(ordered[idx])


def load_historical_wall_estimates(
    arena_dir: Path,
    max_recent_runs: int = 20,
    percentile: float = 0.75,
) -> tuple[dict[tuple[str, str], float], dict[str, float]]:
    """Load per-(bot1, bot2) and per-bot2 expected wall_sec estimates for LPT scheduling.

    Sources (highest fidelity first):
      1. Exact `wall_sec` from `arena_replays.sqlite` (read-only `?mode=ro`) if column exists.
      2. Exact `wall_sec` from up to `max_recent_runs` most recent `<arena_dir>/runs/*/results.json`.
      3. Scaled `duration_sec` fallback from `arena_replays.sqlite` (read-only `?mode=ro`) for pairs
         or opponents absent from exact wall-clock logs.
    Keys are normalized to lowercase strings for resilient lookup.
    """
    pair_wall_samples: dict[tuple[str, str], list[float]] = {}
    opp_wall_samples: dict[str, list[float]] = {}
    pair_dur_samples: dict[tuple[str, str], list[float]] = {}
    opp_dur_samples: dict[str, list[float]] = {}

    db_path = arena_dir / "arena_replays.sqlite"
    if db_path.is_file():
        con: sqlite3.Connection | None = None
        try:
            con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
            cur = con.cursor()
            cols = {str(row[1]).lower() for row in cur.execute("PRAGMA table_info(matches)").fetchall()}
            has_wall = "wall_sec" in cols
            has_dur = "duration_sec" in cols
            if has_wall and "bot" in cols and "opponent" in cols:
                rows = cur.execute(
                    "SELECT bot, opponent, wall_sec FROM matches "
                    "WHERE wall_sec IS NOT NULL AND wall_sec > 0 "
                    "ORDER BY rowid DESC LIMIT 2500"
                ).fetchall()
                for b1, b2, ws in rows:
                    if not b1 or not b2:
                        continue
                    try:
                        val = float(ws)
                    except Exception:
                        continue
                    if val > 0:
                        k1, k2 = str(b1).strip().lower(), str(b2).strip().lower()
                        pair_wall_samples.setdefault((k1, k2), []).append(val)
                        opp_wall_samples.setdefault(k2, []).append(val)
            if has_dur and "bot" in cols and "opponent" in cols:
                rows = cur.execute(
                    "SELECT bot, opponent, duration_sec FROM matches "
                    "WHERE duration_sec IS NOT NULL AND duration_sec > 0 "
                    "ORDER BY rowid DESC LIMIT 2500"
                ).fetchall()
                for b1, b2, ds in rows:
                    if not b1 or not b2:
                        continue
                    try:
                        val = float(ds) * 0.35
                    except Exception:
                        continue
                    if val > 0:
                        k1, k2 = str(b1).strip().lower(), str(b2).strip().lower()
                        pair_dur_samples.setdefault((k1, k2), []).append(val)
                        opp_dur_samples.setdefault(k2, []).append(val)
        except Exception:
            pass
        finally:
            if con is not None:
                try:
                    con.close()
                except Exception:
                    pass

    runs_dir = arena_dir / "runs"
    if runs_dir.is_dir():
        run_results = sorted(
            (p / "results.json" for p in runs_dir.iterdir() if p.is_dir() and (p / "results.json").is_file()),
            key=lambda p: p.parent.name,
            reverse=True,
        )[:max_recent_runs]
        for rp in run_results:
            try:
                data = json.loads(rp.read_text(encoding="utf-8"))
            except Exception:
                continue
            matches = data.get("matches") if isinstance(data, dict) else None
            if not isinstance(matches, list):
                continue
            for m in matches:
                if not isinstance(m, dict):
                    continue
                b1 = str(m.get("bot1") or "").strip().lower()
                b2 = str(m.get("bot2") or "").strip().lower()
                ws = m.get("wall_sec")
                if not b1 or not b2 or not isinstance(ws, (int, float)) or ws <= 0:
                    continue
                val = float(ws)
                pair_wall_samples.setdefault((b1, b2), []).append(val)
                opp_wall_samples.setdefault(b2, []).append(val)

    pair_est: dict[tuple[str, str], float] = {}
    opp_est: dict[str, float] = {}

    for k, vals in pair_dur_samples.items():
        pair_est[k] = _percentile(vals, percentile)
    for k, vals in opp_dur_samples.items():
        opp_est[k] = _percentile(vals, percentile)

    # Exact wall_sec samples override duration_sec heuristic
    for k, vals in pair_wall_samples.items():
        pair_est[k] = _percentile(vals, percentile)
    for k, vals in opp_wall_samples.items():
        opp_est[k] = _percentile(vals, percentile)

    return pair_est, opp_est


def estimate_match_wall_sec(
    bot1_name: str,
    bot2_name: str,
    pair_est: dict[tuple[str, str], float],
    opp_est: dict[str, float],
) -> float:
    k1 = bot1_name.strip().lower()
    k2 = bot2_name.strip().lower()
    if (k1, k2) in pair_est:
        return pair_est[(k1, k2)]
    if k2 in opp_est:
        return opp_est[k2]
    return BUILTIN_SLOW_TIER_WALL_SEC.get(k2, DEFAULT_FALLBACK_WALL_SEC)


def _infer_cohort(b2: BotSpec) -> str:
    if b2.is_mothman:
        return "selfplay"
    if b2.gauntlet_core:
        return "core"
    return "unseen"


def build_selfplay_pairs(n_matches: int) -> list[tuple[str, str]]:
    """Build `n_matches` Mothman-vs-Mothman pairs covering all 6 SC2 matchups first."""
    out: list[tuple[str, str]] = []
    round_idx = 0
    while len(out) < n_matches:
        seq = SELFPLAY_MATCHUPS_6 if (round_idx % 2 == 0) else SELFPLAY_MATCHUPS_REV
        for pair in seq:
            out.append(pair)
            if len(out) >= n_matches:
                break
        round_idx += 1
    return out


def build_match_tasks(
    args: argparse.Namespace,
    roster: dict[str, BotSpec],
    maps: list[str],
    arena_dir: Path,
    repo_dir: Path,
    stage_mothman: bool = True,
) -> list[MatchTask]:
    mothman_cache: dict[tuple[str, str], Path] = {}
    tasks: list[MatchTask] = []
    bench_seed = normalize_bench_seed(getattr(args, "bench_seed", DEFAULT_BENCH_SEED))

    if args.match_file:
        mf = Path(args.match_file)
        raw = json.loads(mf.read_text(encoding="utf-8"))
        entries = raw["matches"] if isinstance(raw, dict) and "matches" in raw else raw
        pair_reps: dict[tuple[str, str], int] = {}
        for idx, item in enumerate(entries, start=1):
            b1 = resolve_bot_spec(
                item["bot"], roster, args.mothman_mode, arena_dir, repo_dir, mothman_cache,
                stage_mothman=stage_mothman,
            )
            b2 = resolve_bot_spec(
                item["opponent"], roster, args.mothman_mode, arena_dir, repo_dir, mothman_cache,
                stage_mothman=stage_mothman,
            )
            rep_k = (b1.name, b2.name)
            rep_i = pair_reps.get(rep_k, 0)
            pair_reps[rep_k] = rep_i + 1
            det_mp, det_seed = deterministic_map_and_seed(bench_seed, b1.name, b2.name, rep_i, maps)
            mp = item.get("map") or det_mp
            mp = mp[:-7] if mp.lower().endswith(".sc2map") else mp
            rseed = int(item["random_seed"]) if item.get("random_seed") is not None else det_seed
            coh = str(item.get("cohort") or _infer_cohort(b2))
            slug = f"{idx:03d}_{sanitize_slug(b1.name)}_vs_{sanitize_slug(b2.name)}_{sanitize_slug(mp)}"
            tasks.append(MatchTask(idx, b1, b2, mp, slug, cohort=coh, random_seed=rseed))
        return tasks

    if args.bots.strip().lower() == "all":
        bot_names = ["Mothman-P", "Mothman-T", "Mothman-Z", "Mothman-X"]
    else:
        bot_names = [x.strip() for x in args.bots.split(",") if x.strip()]

    opp_arg = args.opponents.strip()
    opp_low = opp_arg.lower()
    want_selfplay = bool(getattr(args, "include_selfplay", False)) or (opp_low in ("self_6", "selfplay", "self"))
    if opp_low in ("self_6", "selfplay", "self", "none", ""):
        opp_names: list[str] = []
    elif opp_low == "all":
        opp_names = sorted(roster.keys(), key=lambda n: (roster[n].elo or 0, n))
    elif opp_low in ("canary", "canary_6"):
        ci = {k.lower(): k for k in roster}
        opp_names = [ci[name.lower()] for name in CANARY_6_OPPONENTS if name.lower() in ci]
        if not opp_names:
            raise ValueError(f"Canary preset matched 0 bots in roster. Expected subset of {list(CANARY_6_OPPONENTS)}.")
    elif opp_low in ("core", "core_14"):
        opp_names = sorted([n for n, s in roster.items() if s.gauntlet_core], key=lambda n: (roster[n].elo or 0, n))
    elif opp_low == "core_12":
        opp_names = sorted([n for n in roster.keys() if n in CORE_12_HISTORICAL], key=lambda n: (roster[n].elo or 0, n))
    elif opp_low in ("unseen", "unseen_12", "unseen_6"):
        opp_names = sorted([n for n, s in roster.items() if not s.gauntlet_core], key=lambda n: (roster[n].elo or 0, n))
    elif opp_low == "active":
        opp_names = sorted([n for n, s in roster.items() if s.active_comp38], key=lambda n: (roster[n].elo or 0, n))
    else:
        opp_names = [x.strip() for x in opp_arg.split(",") if x.strip()]

    if not opp_names and not want_selfplay:
        raise ValueError("No opponents selected. Specify --opponents <names|canary|core|core_14|core_12|unseen|all|self_6>, --include-selfplay, or --match-file <path>.")

    schedule_order = str(getattr(args, "schedule_order", "lpt") or "lpt").lower()
    race_priority = {"Z": 0, "T": 1, "P": 2, "R": 3}

    if schedule_order == "lpt":
        pair_est, opp_est = load_historical_wall_estimates(arena_dir)
        raw_entries: list[tuple[BotSpec, BotSpec, int, str, float, str, int]] = []

        if opp_names:
            bot_specs = [
                resolve_bot_spec(
                    bname, roster, args.mothman_mode, arena_dir, repo_dir, mothman_cache,
                    stage_mothman=stage_mothman,
                )
                for bname in bot_names
            ]
            opp_specs = [
                resolve_bot_spec(
                    oname, roster, args.mothman_mode, arena_dir, repo_dir, mothman_cache,
                    stage_mothman=stage_mothman,
                )
                for oname in opp_names
            ]
            for rep in range(args.matches_per_pair):
                for b2 in opp_specs:
                    for b1 in bot_specs:
                        est = estimate_match_wall_sec(b1.name, b2.name, pair_est, opp_est)
                        mp, rseed = deterministic_map_and_seed(bench_seed, b1.name, b2.name, rep, maps)
                        raw_entries.append((b1, b2, rep, _infer_cohort(b2), est, mp, rseed))

        if want_selfplay:
            sp_n = int(getattr(args, "selfplay_matches", 6) or 6)
            sp_lim = getattr(args, "selfplay_limit", None)
            if sp_lim is not None:
                sp_n = min(sp_n, max(0, int(sp_lim)))
            use_base = bool(getattr(args, "selfplay_baseline", False))
            p2_mode = "zip" if use_base else args.mothman_mode
            p2_suffix = "-Base" if use_base else "-SP"
            for sp_i, (p1_var, p2_var) in enumerate(build_selfplay_pairs(sp_n)):
                b1 = resolve_bot_spec(
                    p1_var, roster, args.mothman_mode, arena_dir, repo_dir, mothman_cache,
                    stage_mothman=stage_mothman,
                )
                b2 = resolve_bot_spec(
                    p2_var,
                    roster,
                    p2_mode,
                    arena_dir,
                    repo_dir,
                    mothman_cache,
                    alias_name=f"{p2_var}{p2_suffix}",
                    stage_mothman=stage_mothman,
                )
                est = estimate_match_wall_sec(b1.name, b2.name, pair_est, opp_est)
                mp, rseed = deterministic_map_and_seed(bench_seed, b1.name, b2.name, sp_i, maps)
                raw_entries.append((b1, b2, sp_i, "selfplay", est, mp, rseed))

        # Longest-Processing-Time-First: schedule slowest expected matches in Wave 1
        # so 640s stragglers never sit at the tail of parallel runs.
        # Map and random_seed were already assigned deterministically BEFORE sorting!
        raw_entries.sort(
            key=lambda item: (
                -item[4],
                race_priority.get(item[0].race, 9),
                item[1].name.lower(),
                item[0].name,
                item[2],
            )
        )
        for idx, (b1, b2, _rep, coh, est, mp, rseed) in enumerate(raw_entries, start=1):
            slug = f"{idx:03d}_{sanitize_slug(b1.name)}_vs_{sanitize_slug(b2.name)}_{sanitize_slug(mp)}"
            tasks.append(MatchTask(idx, b1, b2, mp, slug, cohort=coh, est_wall_sec=round(est, 1), random_seed=rseed))
        return tasks

    if opp_names:
        bot_specs = [
            resolve_bot_spec(
                bname, roster, args.mothman_mode, arena_dir, repo_dir, mothman_cache,
                stage_mothman=stage_mothman,
            )
            for bname in bot_names
        ]
        opp_specs = [
            resolve_bot_spec(
                oname, roster, args.mothman_mode, arena_dir, repo_dir, mothman_cache,
                stage_mothman=stage_mothman,
            )
            for oname in opp_names
        ]

        # Interleaved ordering spreads each Mothman race (with typically longer Zerg macro games first)
        # across waves so slow 20-30m matches start early instead of creating a late straggler tail.
        if schedule_order == "interleaved":
            ordered_bots = sorted(bot_specs, key=lambda b: (race_priority.get(b.race, 9), b.name))
            pairs = [
                (b1, b2, rep)
                for rep in range(args.matches_per_pair)
                for b2 in opp_specs
                for b1 in ordered_bots
            ]
        else:
            pairs = [
                (b1, b2, rep)
                for b1 in bot_specs
                for b2 in opp_specs
                for rep in range(args.matches_per_pair)
            ]

        for b1, b2, rep in pairs:
            idx = len(tasks) + 1
            mp, rseed = deterministic_map_and_seed(bench_seed, b1.name, b2.name, rep, maps)
            slug = f"{idx:03d}_{sanitize_slug(b1.name)}_vs_{sanitize_slug(b2.name)}_{sanitize_slug(mp)}"
            tasks.append(MatchTask(idx, b1, b2, mp, slug, cohort=_infer_cohort(b2), random_seed=rseed))

    if want_selfplay:
        sp_n = int(getattr(args, "selfplay_matches", 6) or 6)
        sp_lim = getattr(args, "selfplay_limit", None)
        if sp_lim is not None:
            sp_n = min(sp_n, max(0, int(sp_lim)))
        use_base = bool(getattr(args, "selfplay_baseline", False))
        p2_mode = "zip" if use_base else args.mothman_mode
        p2_suffix = "-Base" if use_base else "-SP"
        for sp_i, (p1_var, p2_var) in enumerate(build_selfplay_pairs(sp_n)):
            idx = len(tasks) + 1
            b1 = resolve_bot_spec(
                p1_var, roster, args.mothman_mode, arena_dir, repo_dir, mothman_cache,
                stage_mothman=stage_mothman,
            )
            b2 = resolve_bot_spec(
                p2_var,
                roster,
                p2_mode,
                arena_dir,
                repo_dir,
                mothman_cache,
                alias_name=f"{p2_var}{p2_suffix}",
                stage_mothman=stage_mothman,
            )
            mp, rseed = deterministic_map_and_seed(bench_seed, b1.name, b2.name, sp_i, maps)
            slug = f"{idx:03d}_{sanitize_slug(b1.name)}_vs_{sanitize_slug(b2.name)}_{sanitize_slug(mp)}"
            tasks.append(MatchTask(idx, b1, b2, mp, slug, cohort="selfplay", random_seed=rseed))

    return tasks


def main() -> int:
    parser = argparse.ArgumentParser(description="Parallel Local Real-SC2 Match Runner (AI Arena Combined Container)")
    parser.add_argument("--bots", default="Mothman-Z,Mothman-T,Mothman-P",
                        help="Comma-separated Mothman variants (or 'all' for P,T,Z,X)")
    parser.add_argument("--opponents", default="core",
                        help="Comma-separated opponent names from roster, 'canary' (6 swing opponents: oberon, zig-reapers, AxeFighter, puck, Creepy_strategies, QueenBot), 'core'/'core_14' (dynamic gauntlet_core), 'core_12' (historical 12-bot core), 'unseen'/'unseen_12' (non-core holdouts), 'active' (Comp#38), 'all', 'self_6' (6 full-game self-play matchups), or 'none'")
    parser.add_argument("--include-selfplay", action="store_true",
                        help="Append full-game Mothman-vs-Mothman Self-Play matches (default 6: ZvZ, TvT, PvP, PvT, PvZ, TvZ) tagged cohort='selfplay'")
    parser.add_argument("--selfplay-matches", type=int, default=6,
                        help="Number of full-game Self-Play matches to run with --include-selfplay or --opponents self_6 (default: 6)")
    parser.add_argument("--selfplay-limit", type=int, default=None,
                        help="Optional cap on Self-Play matches appended (e.g. 1 for quick smoke verification)")
    parser.add_argument("--selfplay-baseline", action="store_true",
                        help="Pit live P1 Mothman (--mothman-mode) against committed ladder/Mothman-{P,T,Z}.zip as P2 (Mothman-*-Base)")
    parser.add_argument("--maps", default="season",
                        help="Comma-separated map names, 'season' (maps_manifest.json), or 'all'")
    parser.add_argument("--matches-per-pair", type=int, default=1,
                        help="Matches to play per (bot, opponent) pair (rotates maps)")
    parser.add_argument("--match-file", default=None,
                        help="Optional JSON file with explicit match schedule [{bot, opponent, map}, ...]")
    parser.add_argument("--mothman-mode", choices=["zip", "elf", "source"], default="zip",
                        help="How to run Mothman: 'zip' (ladder/*.zip), 'elf' (standalone ELF), or 'source' (live repo .rkt)")
    parser.add_argument("-j", "--concurrency", type=int, default=14,
                        help="Number of concurrent real SC2 matches (default: 14; empirically tuned for 16C/32T 125GiB host)")
    parser.add_argument("--schedule-order", choices=["lpt", "interleaved", "sequential"], default="lpt",
                        help="Match queue order: 'lpt' schedules longest expected matches first from historical wall_sec (default: lpt); 'interleaved' spreads Z/T/P; 'sequential' runs in bot-major order")
    parser.add_argument("--bench-seed", default=DEFAULT_BENCH_SEED,
                        help=f"Deterministic seed string for LPT-invariant map + SC2 random_seed assignment (default: '{DEFAULT_BENCH_SEED}'; pass 'random' or '0' to disable deterministic SC2 RNG seeding)")
    parser.add_argument("--timeout-sec", type=int, default=480,
                        help="Per-match wall-clock timeout in seconds (default: 480)")
    # Temporary local-loop 25m cap (33600 = 25 * 60 * 22.4 loops) paired with end-of-game
    # state scoring for faster iteration; revisit & raise to 40320 (30m) / 60480 (45m) once
    # >15% of external matches reach 25m or late-game Tier-3 endgames dominate.
    parser.add_argument("--max-game-time", type=int, default=33600,
                        help="SC2 MAX_GAME_TIME in loops (default: 33600=25m temporary local-loop cap, revisit once >15%% of matches reach 25m or Tier-3 endgames dominate; 40320=30m, 60480=45m AI Arena std)")
    parser.add_argument("--max-frame-time", type=int, default=1000,
                        help="AI Arena MAX_FRAME_TIME in ms (default: 1000)")
    parser.add_argument("--strikes", type=int, default=10,
                        help="AI Arena frame timeout strike limit (default: 10)")
    parser.add_argument("--realtime", action="store_true",
                        help="Run SC2 in real-time mode (default: false for max speed)")
    parser.add_argument("--arena-dir", type=Path, default=DEFAULT_ARENA_DIR,
                        help=f"External SC2 arena data directory (default: {DEFAULT_ARENA_DIR})")
    parser.add_argument("--repo-dir", type=Path, default=REPO_ROOT,
                        help=f"Mothman repo root (default: {REPO_ROOT})")
    parser.add_argument("--roster", type=Path, default=None,
                        help="Optional path to roster.json (default: <arena-dir>/bots/roster.json)")
    parser.add_argument("--run-id", default=None,
                        help="Explicit run directory name under <arena-dir>/runs/")
    parser.add_argument("--tag", default=None,
                        help="Optional tag appended to auto-generated run_id")
    parser.add_argument("--image", default=DEFAULT_IMAGE,
                        help=f"Container image (default: {DEFAULT_IMAGE})")
    parser.add_argument("--container-runtime", default=None,
                        help="Force 'podman' or 'docker' (default: auto-detect)")
    parser.add_argument("--network", default="none",
                        help="Container network mode (default: 'none' for zero-overhead loopback isolation; pass '' for runtime default)")
    parser.add_argument("--stagger-sec", type=float, default=0.25,
                        help="Delay in seconds between initial concurrent container spawns to prevent podman startup spikes (default: 0.25)")
    parser.add_argument("--keep-workdirs", action="store_true",
                        help="Keep per-match cloned /bots workdirs after match finishes")
    parser.add_argument("--list", action="store_true",
                        help="List discovered opponents, maps, and planned matches for current flags and exit")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print match plan and exit without running matches")
    args = parser.parse_args()

    arena_dir = args.arena_dir.resolve()
    repo_dir = args.repo_dir.resolve()
    bots_dir = arena_dir / "bots"
    maps_dir = arena_dir / "maps"

    roster = load_roster(bots_dir, args.roster)
    maps = discover_maps(maps_dir, args.maps)

    if args.list:
        core_n = sum(1 for s in roster.values() if s.gauntlet_core)
        unseen_n = len(roster) - core_n
        canary_set = {n.lower() for n in CANARY_6_OPPONENTS}
        print(f"Arena dir: {arena_dir}")
        print(f"Maps ({len(maps)}): {', '.join(maps)}")
        print(f"Opponents ({len(roster)} total: {core_n} CORE, {unseen_n} UNSEEN):")
        for name, spec in sorted(roster.items(), key=lambda kv: (kv[1].elo or 0, kv[0])):
            core_tag = " [CORE]" if spec.gauntlet_core else " [UNSEEN]"
            canary_tag = " [CANARY]" if name.lower() in canary_set else ""
            print(f"  - {name:<22} race={spec.race} type={spec.bot_type:<10} elo={str(spec.elo):<5} id={str(spec.aiarena_id):<5}{core_tag}{canary_tag} {spec.archetype}")
        tasks = build_match_tasks(args, roster, maps, arena_dir, repo_dir, stage_mothman=False)
        bench_seed_norm = normalize_bench_seed(args.bench_seed)
        print(f"Planned matches ({len(tasks)}): schedule_order={args.schedule_order} | bench_seed={bench_seed_norm} | bots={args.bots} | opponents={args.opponents}")
        for t in tasks:
            est_s = f" | est={t.est_wall_sec:.0f}s" if t.est_wall_sec is not None else ""
            print(f"  [{t.index:03d}] [{t.cohort:<8}] {t.bot1.name}({t.bot1.race},{t.bot1.bot_mode or t.bot1.bot_type}) vs "
                  f"{t.bot2.name}({t.bot2.race},{t.bot2.bot_mode or t.bot2.bot_type}) on {t.map_name} | seed={t.random_seed}{est_s}")
        return 0

    if args.dry_run:
        try:
            runtime = detect_container_runtime(args.container_runtime)
        except RuntimeError:
            runtime = "unavailable"
        tasks = build_match_tasks(args, roster, maps, arena_dir, repo_dir, stage_mothman=False)
        bench_seed_norm = normalize_bench_seed(args.bench_seed)
        print(f"Dry run: {len(tasks)} matches | mode={args.mothman_mode} | schedule_order={args.schedule_order} | bench_seed={bench_seed_norm} | j={args.concurrency} | max_game_time={args.max_game_time} | runtime={runtime}")
        for t in tasks:
            est_s = f" | est={t.est_wall_sec:.0f}s" if t.est_wall_sec is not None else ""
            print(f"  [{t.index:03d}] [{t.cohort:<8}] {t.bot1.name}({t.bot1.race},{t.bot1.bot_mode or t.bot1.bot_type}) vs "
                  f"{t.bot2.name}({t.bot2.race},{t.bot2.bot_mode or t.bot2.bot_type}) on {t.map_name} | seed={t.random_seed}{est_s}")
        return 0

    runtime = detect_container_runtime(args.container_runtime)
    tasks = build_match_tasks(args, roster, maps, arena_dir, repo_dir)

    now_utc = dt.datetime.now(dt.timezone.utc)
    ts_str = now_utc.strftime("%Y%m%d_%H%M%S")
    run_id = args.run_id or (f"{ts_str}_{sanitize_slug(args.tag)}" if args.tag else ts_str)
    run_id_short = re.sub(r"[^a-zA-Z0-9]", "", run_id)[-12:].lower() or "run"

    run_dir = arena_dir / "runs" / run_id
    (run_dir / "replays").mkdir(parents=True, exist_ok=True)
    (run_dir / "logs").mkdir(parents=True, exist_ok=True)
    (run_dir / "workdirs").mkdir(parents=True, exist_ok=True)

    def handle_signal(signum: int, _frame: Any) -> None:
        SHUTDOWN_EVENT.set()
        log(f"\n[SIGNAL {signum}] Stopping active SC2 containers...")
        with ACTIVE_LOCK:
            to_kill = list(ACTIVE_CONTAINERS)
        for cname in to_kill:
            force_rm_container(runtime, cname)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    commit = get_repo_commit(repo_dir)
    bench_seed_norm = normalize_bench_seed(args.bench_seed)
    concurrency = max(1, min(args.concurrency, len(tasks)))
    log(
        f"[SC2-ARENA] Starting {len(tasks)} real SC2 matches (concurrency={concurrency}, "
        f"mode={args.mothman_mode}, schedule_order={args.schedule_order}, bench_seed={bench_seed_norm}, "
        f"commit={commit}, max_game_time={args.max_game_time}, timeout={args.timeout_sec}s)\n"
        f"[SC2-ARENA] Run directory: {run_dir}"
    )

    t_start = time.monotonic()
    results: list[dict[str, Any]] = []
    dash_stop = threading.Event()
    dash_script = repo_dir / "tools" / "update-dashboard-state.py"

    def _dash_pulse() -> None:
        while not dash_stop.wait(timeout=5.0):
            if dash_script.is_file():
                try:
                    subprocess.run(
                        [sys.executable, str(dash_script), "--auto"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=8,
                    )
                except Exception:
                    pass

    dash_thread = threading.Thread(target=_dash_pulse, daemon=True)
    dash_thread.start()
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            futs = [
                pool.submit(
                    run_single_match,
                    task,
                    len(tasks),
                    run_dir,
                    arena_dir,
                    repo_dir,
                    args.mothman_mode,
                    args.image,
                    runtime,
                    args.timeout_sec,
                    args.max_game_time,
                    args.max_frame_time,
                    args.strikes,
                    args.realtime,
                    args.keep_workdirs,
                    run_id_short,
                    args.network,
                    (idx * args.stagger_sec) if idx < concurrency else 0.0,
                )
                for idx, task in enumerate(tasks)
            ]
            for fut in concurrent.futures.as_completed(futs):
                results.append(fut.result())
    finally:
        dash_stop.set()
        dash_thread.join(timeout=2.0)

    results.sort(key=lambda r: r["index"])
    wall_elapsed = round(time.monotonic() - t_start, 2)

    if not args.keep_workdirs:
        try:
            wd_root = run_dir / "workdirs"
            if wd_root.is_dir() and not any(wd_root.iterdir()):
                wd_root.rmdir()
        except Exception:
            pass

    by_bot: dict[str, Any] = {}
    for b in sorted({r["bot1"] for r in results}):
        by_bot[b] = aggregate_records([r for r in results if r["bot1"] == b])

    by_opponent: dict[str, Any] = {}
    for o in sorted({r["bot2"] for r in results}):
        by_opponent[o] = aggregate_records([r for r in results if r["bot2"] == o])

    by_matchup: dict[str, Any] = {}
    for mu in sorted({f"{r['bot1_race']}v{r['bot2_race']}" for r in results}):
        by_matchup[mu] = aggregate_records([r for r in results if f"{r['bot1_race']}v{r['bot2_race']}" == mu])

    by_cohort: dict[str, Any] = {}
    for c in sorted({str(r.get("cohort") or "unknown") for r in results}):
        by_cohort[c] = aggregate_records([r for r in results if str(r.get("cohort") or "unknown") == c])

    ext_results = [r for r in results if r.get("cohort") != "selfplay"]
    summary = {
        "run_id": run_id,
        "run_dir": str(run_dir),
        "timestamp_utc": now_utc.isoformat(),
        "repo_commit": commit,
        "mothman_mode": args.mothman_mode,
        "schedule_order": args.schedule_order,
        "bench_seed": bench_seed_norm,
        "image": args.image,
        "concurrency": concurrency,
        "max_game_time": args.max_game_time,
        "max_frame_time": args.max_frame_time,
        "timeout_sec": args.timeout_sec,
        "wall_elapsed_sec": wall_elapsed,
        "totals": aggregate_records(results),
        "totals_external": aggregate_records(ext_results) if ext_results else None,
        "apm_cap_drops": aggregate_apm_cap_drops(results),
        "spawn_balance": aggregate_spawn_balance(results),
        "by_cohort": by_cohort,
        "by_bot": by_bot,
        "by_opponent": by_opponent,
        "by_matchup": by_matchup,
        "matches": results,
    }

    summary_json_path = run_dir / "summary.json"
    results_json_path = run_dir / "results.json"
    summary_txt_path = run_dir / "summary.txt"
    summary_payload = json.dumps(summary, indent=2) + "\n"
    summary_json_path.write_text(summary_payload, encoding="utf-8")
    results_json_path.write_text(summary_payload, encoding="utf-8")
    summary_txt = format_summary_text(summary)
    summary_txt_path.write_text(summary_txt, encoding="utf-8")

    print("\n" + summary_txt, end="", flush=True)
    print(f"Summary JSON : {summary_json_path}")
    print(f"Replays dir  : {run_dir / 'replays'}")
    print(f"Logs dir     : {run_dir / 'logs'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
