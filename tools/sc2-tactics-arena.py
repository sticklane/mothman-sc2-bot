#!/usr/bin/env python3
"""
Real-SC2_x64 Physics-Accurate Micro Skirmish Arena (`tools/sc2-tactics-arena.py`)

Runs deterministic, multi-scenario real-SC2_x64 (Blizzard 4.10) micro skirmishes
inside `docker.io/aiarena/arenaclient-combined:v0.8.0` using SC2 `RequestDebug`
(`DebugCreateUnit` + `DebugKillUnit` + `DebugGameState.show_map`), resetting units
cleanly between scenarios WITHOUT rebooting SC2_x64.

Modes:
  --mode probe    : Standalone 1-SC2 RequestDebug feasibility + weapon_cooldown verification.
  --mode duel     : 2-Participant real-SC2_x64 physics skirmish arena:
                      P1 = LIVE Mothman (source mode via portable Racket)
                      P2 = Aggressive Focus-Firing Scripted Micro Opponent
                    Runs all scenarios for a race inside ONE container (~15-18s),
                    or `--race all` runs P/T/Z containers in parallel (~20s total) for
                    all 9 real-SC2 combat physics scenarios!

Usage (from host):
  python3 tools/sc2-tactics-arena.py --mode duel --race all --out /path/to/out.json
  python3 tools/sc2-tactics-arena.py --mode duel --race Protoss
  python3 tools/sc2-tactics-arena.py --mode probe
"""

from __future__ import annotations

import argparse
import asyncio
import concurrent.futures
import json
import math
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_IMAGE = "docker.io/aiarena/arenaclient-combined:v0.8.0"
DEFAULT_MAPS_DIR = Path("/home/sjaconette/sc2-local-arena/maps")
DEFAULT_ARENA_DIR = Path("/home/sjaconette/sc2-local-arena")
DEFAULT_REPO_DIR = Path("/home/sjaconette/repos/mothman-sc2-bot")
DEFAULT_MAP = "AcropolisAIE.SC2Map"

# Canonical SC2 UnitTypeIds (Blizzard 4.10)
UNIT_IDS: dict[str, int] = {
    # Terran
    "marine": 48,
    "reaper": 49,
    "marauder": 51,
    "medivac": 54,
    "siege-tank": 33,
    "siege-tank-sieged": 32,
    "hellion": 53,
    "ghost": 50,
    "raven": 56,
    "viking-fighter": 35,
    "widow-mine": 498,
    "widow-mine-burrowed": 500,
    "liberator": 689,
    "liberator-ag": 734,
    "cyclone": 692,
    "scv": 45,
    # Protoss
    "zealot": 73,
    "stalker": 74,
    "sentry": 77,
    "adept": 311,
    "immortal": 83,
    "colossus": 4,
    "high-templar": 75,
    "archon": 141,
    "oracle": 495,
    "void-ray": 80,
    "carrier": 79,
    "tempest": 496,
    "probe": 84,
    # Zerg
    "zergling": 105,
    "baneling": 9,
    "roach": 110,
    "ravager": 688,
    "hydralisk": 107,
    "mutalisk": 108,
    "corruptor": 112,
    "queen": 126,
    "ultralisk": 109,
    "infestor": 111,
    "viper": 499,
    "lurker-mp": 502,
    "lurker-mp-burrowed": 503,
    "drone": 104,
}

# Approximate mineral + 1.5*gas weighted combat value per unit
UNIT_VALUES: dict[int, float] = {
    48: 50.0,     # marine
    49: 125.0,    # reaper
    51: 137.5,    # marauder
    54: 250.0,    # medivac
    33: 337.5,    # siege-tank
    32: 337.5,    # siege-tank-sieged
    53: 100.0,    # hellion
    50: 337.5,    # ghost
    56: 400.0,    # raven
    35: 262.5,    # viking-fighter
    498: 112.5,   # widow-mine
    500: 112.5,   # widow-mine-burrowed
    689: 375.0,   # liberator
    734: 375.0,   # liberator-ag
    692: 300.0,   # cyclone
    45: 50.0,     # scv
    73: 100.0,    # zealot
    74: 200.0,    # stalker
    77: 200.0,    # sentry
    311: 137.5,   # adept
    83: 425.0,    # immortal
    4: 600.0,     # colossus
    75: 275.0,    # high-templar
    141: 550.0,   # archon
    495: 375.0,   # oracle
    80: 475.0,    # void-ray
    79: 725.0,    # carrier
    496: 512.5,   # tempest
    84: 50.0,     # probe
    105: 25.0,    # zergling
    9: 87.5,      # baneling
    110: 112.5,   # roach
    688: 250.0,   # ravager
    107: 175.0,   # hydralisk
    108: 250.0,   # mutalisk
    112: 300.0,   # corruptor
    126: 150.0,   # queen
    109: 575.0,   # ultralisk
    111: 325.0,   # infestor
    499: 400.0,   # viper
    502: 375.0,   # lurker
    503: 375.0,   # lurker-burrowed
    104: 50.0,    # drone
}

TOWNHALL_IDS = {18, 59, 86, 100, 101, 130, 132}
WORKER_IDS = {45, 84, 104}
COMBAT_IDS = set(UNIT_VALUES) - WORKER_IDS


@dataclass
class SkirmishSpec:
    id: str
    our_race: str        # Protoss | Terran | Zerg
    enemy_race: str
    description: str
    p1_units: list[tuple[str, int, float, float]]  # (unit_name, count, dx, dy)
    p2_units: list[tuple[str, int, float, float]]
    max_loops: int = 336  # ~15s Faster SC2 combat


DEFAULT_SKIRMISHES: list[SkirmishSpec] = [
    # --- Protoss (3 real-SC2 combat physics scenarios) ---
    SkirmishSpec(
        id="sc2-real-p01-zealot-stalker-vs-bio",
        our_race="Protoss",
        enemy_race="Terran",
        description="Real SC2: 4 Zealots + 4 Stalkers vs 12 Marines + 3 Marauders (melee + ranged stutter-step)",
        p1_units=[("zealot", 4, -3.5, 0.0), ("stalker", 4, -5.0, 0.0)],
        p2_units=[("marine", 12, 4.5, 0.0), ("marauder", 3, 5.5, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-p02-stalker-immortal-vs-roach-ravager",
        our_race="Protoss",
        enemy_race="Zerg",
        description="Real SC2: 4 Stalkers + 2 Immortals vs 9 Roaches + 2 Ravagers (slow Immortal + Stalker focus-fire)",
        p1_units=[("immortal", 2, -3.5, 0.0), ("stalker", 4, -5.0, 0.0)],
        p2_units=[("roach", 9, 4.5, 0.0), ("ravager", 2, 5.5, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-p03-outnumbered-stalkers-vs-lings",
        our_race="Protoss",
        enemy_race="Zerg",
        description="Real SC2: 5 Stalkers vs 18 Zerglings (outnumbered ranged stutter-kite vs fast melee)",
        p1_units=[("stalker", 5, -4.5, 0.0)],
        p2_units=[("zergling", 18, 4.5, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-p04-colossus-sentry-stalker-vs-bio",
        our_race="Protoss",
        enemy_race="Terran",
        description="Real SC2: 2 Colossus + 1 Sentry + 4 Stalkers + 3 Zealots vs 14 Marines + 4 Marauders + 1 Medivac (Guardian Shield + splash)",
        p1_units=[("zealot", 3, -3.5, 0.0), ("sentry", 1, -4.5, 0.0), ("stalker", 4, -5.0, 0.0), ("colossus", 2, -6.0, 0.0)],
        p2_units=[("marine", 14, 4.5, 0.0), ("marauder", 4, 4.0, 0.0), ("medivac", 1, 6.0, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-p05-ht-archon-stalker-vs-hydra-infestor",
        our_race="Protoss",
        enemy_race="Zerg",
        description="Real SC2: 2 High Templar + 2 Archons + 4 Stalkers vs 8 Hydralisks + 10 Zerglings + 2 Infestors (W3-TAC-4a HT Feedback + mixed micro)",
        p1_units=[("archon", 2, -3.5, 0.0), ("stalker", 4, -5.0, 0.0), ("high-templar", 2, -5.8, 0.0)],
        p2_units=[("zergling", 10, 4.0, 0.0), ("hydralisk", 8, 5.2, 0.0), ("infestor", 2, 5.8, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-p06-early-12pool-zealot-adept-vs-lings",
        our_race="Protoss",
        enemy_race="Zerg",
        description="Real SC2 (W5-EARLY-1): 2 Zealots + 2 Adepts + 1 Stalker defending vs 14 early 12-Pool Zerglings",
        p1_units=[("zealot", 2, -3.5, 0.0), ("adept", 2, -4.5, 0.0), ("stalker", 1, -5.5, 0.0)],
        p2_units=[("zergling", 14, 4.2, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-p07-stalkers-vs-tempests-voidrays",
        our_race="Protoss",
        enemy_race="Protoss",
        description="Real SC2 (W12-LOOP-1): 10 Stalkers diving 3 Tempests + 2 Void Rays at 14t separation (guards W9/W11 capital siege dive)",
        p1_units=[("stalker", 10, -6.0, 0.0)],
        p2_units=[("void-ray", 2, 6.5, 0.0), ("tempest", 3, 8.0, 0.0)],
        max_loops=336,
    ),
    # --- Terran (7 real-SC2 combat physics scenarios) ---
    SkirmishSpec(
        id="sc2-real-t01-bio-medivac-vs-zealot-stalker",
        our_race="Terran",
        enemy_race="Protoss",
        description="Real SC2: 10 Marines + 4 Marauders + 1 Medivac vs 5 Zealots + 4 Stalkers (bio kite + heal)",
        p1_units=[("marine", 10, -4.5, 0.0), ("marauder", 4, -3.5, 0.0), ("medivac", 1, -5.5, 0.0)],
        p2_units=[("zealot", 5, 4.0, 0.0), ("stalker", 4, 5.5, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-t02-tank-marine-vs-roach-ling",
        our_race="Terran",
        enemy_race="Zerg",
        description="Real SC2: 2 Siege Tanks + 8 Marines vs 8 Roaches + 12 Zerglings (tank siege discipline)",
        p1_units=[("siege-tank", 2, -5.5, 0.0), ("marine", 8, -3.5, 0.0)],
        p2_units=[("zergling", 12, 4.0, 0.0), ("roach", 8, 5.5, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-t03-outnumbered-bio-vs-lings",
        our_race="Terran",
        enemy_race="Zerg",
        description="Real SC2: 6 Marines + 2 Marauders vs 20 Zerglings (retreating stutter-fire under pursuit)",
        p1_units=[("marine", 6, -4.5, 0.0), ("marauder", 2, -3.5, 0.0)],
        p2_units=[("zergling", 20, 4.5, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-t04-ghost-bio-medivac-vs-ultra-infestor",
        our_race="Terran",
        enemy_race="Zerg",
        description="Real SC2: 2 Ghosts + 8 Marines + 4 Marauders + 2 Medivacs vs 2 Ultralisks + 2 Infestors + 10 Zerglings (W3-TAC-4b EMP/Snipe + W3-TAC-7 Medivac)",
        p1_units=[("marauder", 4, -3.5, 0.0), ("marine", 8, -4.5, 0.0), ("ghost", 2, -5.5, 0.0), ("medivac", 2, -6.0, 0.0)],
        p2_units=[("ultralisk", 2, 4.0, 0.0), ("zergling", 10, 4.2, 0.0), ("infestor", 2, 5.8, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-t05-bio-medivac-vs-ling-bane",
        our_race="Terran",
        enemy_race="Zerg",
        description="Real SC2: 12 Marines + 4 Marauders + 2 Medivacs vs 16 Zerglings + 6 Banelings (W3-TAC-3 Bio stutter cadence + Baneling split)",
        p1_units=[("marauder", 4, -3.5, 0.0), ("marine", 12, -4.5, 0.0), ("medivac", 2, -5.8, 0.0)],
        p2_units=[("zergling", 16, 4.2, 0.0), ("baneling", 6, 4.8, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-t06-early-12pool-marines-reaper-vs-lings",
        our_race="Terran",
        enemy_race="Zerg",
        description="Real SC2 (W5-EARLY-1): 6 Marines + 1 Reaper defending vs 14 early 12-Pool Zerglings",
        p1_units=[("marine", 6, -4.5, 0.0), ("reaper", 1, -3.8, 0.0)],
        p2_units=[("zergling", 14, 4.2, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-t07-bio-cyclones-vs-stalker-immortal",
        our_race="Terran",
        enemy_race="Protoss",
        description="Real SC2 (W12-LOOP-1): 2 Cyclones + 8 Marines + 1 Medivac vs 5 Stalkers + 2 Immortals (guards W10/W12 Cyclone Lock-On dedup + bio)",
        p1_units=[("cyclone", 2, -4.0, 0.0), ("marine", 8, -4.8, 0.0), ("medivac", 1, -5.8, 0.0)],
        p2_units=[("immortal", 2, 3.8, 0.0), ("stalker", 5, 4.8, 0.0)],
        max_loops=336,
    ),
    # --- Zerg (7 real-SC2 combat physics scenarios) ---
    SkirmishSpec(
        id="sc2-real-z01-lings-vs-marines-open",
        our_race="Zerg",
        enemy_race="Terran",
        description="Real SC2: 20 Zerglings vs 6 Marines open field (winning melee surround, guards arena-minimax retreat)",
        p1_units=[("zergling", 20, -4.0, 0.0)],
        p2_units=[("marine", 6, 4.5, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-z02-roach-ravager-vs-tank-bio",
        our_race="Zerg",
        enemy_race="Terran",
        description="Real SC2: 6 Roaches + 3 Ravagers vs 8 Marines + 2 Siege Tanks (Corrosive Bile + ground push)",
        p1_units=[("roach", 6, -4.0, 0.0), ("ravager", 3, -5.0, 0.0)],
        p2_units=[("marine", 8, 4.0, 0.0), ("siege-tank-sieged", 2, 6.0, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-z03-hydra-roach-vs-stalker-zealot",
        our_race="Zerg",
        enemy_race="Protoss",
        description="Real SC2: 6 Hydralisks + 6 Roaches vs 4 Zealots + 5 Stalkers (ranged focus-fire + concave)",
        p1_units=[("roach", 6, -3.5, 0.0), ("hydralisk", 6, -5.0, 0.0)],
        p2_units=[("zealot", 4, 4.0, 0.0), ("stalker", 5, 5.5, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-z04-queen-ultra-ling-vs-stalker-immortal",
        our_race="Zerg",
        enemy_race="Protoss",
        description="Real SC2: 3 Queens + 2 Ultralisks + 10 Zerglings vs 6 Stalkers + 3 Zealots + 1 Immortal (W3-TAC-6 Queen Transfuse + melee cleave)",
        p1_units=[("zergling", 10, -3.5, 0.0), ("ultralisk", 2, -4.0, 0.0), ("queen", 3, -5.2, 0.0)],
        p2_units=[("zealot", 3, 4.0, 0.0), ("immortal", 1, 4.8, 0.0), ("stalker", 6, 5.5, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-z05-hydra-roach-vs-voidray-zealot",
        our_race="Zerg",
        enemy_race="Protoss",
        description="Real SC2: 8 Hydralisks + 4 Roaches vs 3 Void Rays + 4 Zealots (ground-vs-air target filtering + anti-air focus fire)",
        p1_units=[("roach", 4, -3.5, 0.0), ("hydralisk", 8, -5.0, 0.0)],
        p2_units=[("zealot", 4, 4.0, 0.0), ("void-ray", 3, 5.0, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-z06-early-12pool-queen-lings-vs-lings",
        our_race="Zerg",
        enemy_race="Zerg",
        description="Real SC2 (W5-EARLY-1): 2 Queens + 10 Zerglings defending vs 14 early 12-Pool Zerglings (guards W5-TAC-1/2 spotter & queen recall)",
        p1_units=[("zergling", 10, -3.8, 0.0), ("queen", 2, -5.0, 0.0)],
        p2_units=[("zergling", 14, 4.2, 0.0)],
        max_loops=336,
    ),
    SkirmishSpec(
        id="sc2-real-z07-hydras-vipers-vs-carriers-voidrays",
        our_race="Zerg",
        enemy_race="Protoss",
        description="Real SC2 (W12-LOOP-1): 10 Hydralisks + 2 Vipers vs 2 Carriers + 3 Void Rays (guards Viper Parasitic Bomb/Abduct + Hydra AA)",
        p1_units=[("hydralisk", 10, -4.5, 0.0), ("viper", 2, -6.0, 0.0)],
        p2_units=[("void-ray", 3, 4.5, 0.0), ("carrier", 2, 5.5, 0.0)],
        max_loops=336,
    ),
]


def run_single_container(args: argparse.Namespace, race: str) -> dict[str, Any]:
    repo_dir = Path(args.repo_dir).resolve()
    maps_dir = Path(args.maps_dir).resolve()
    arena_dir = Path(args.arena_dir).resolve()
    map_file = maps_dir / args.map
    if not map_file.is_file():
        raise FileNotFoundError(f"Map not found: {map_file}")

    self_script = Path(__file__).resolve()
    mounts = [
        "-v", f"{repo_dir}:/mothman-repo:ro",
        "-v", f"{self_script}:/harness/sc2-tactics-arena.py:ro",
        "-v", f"{map_file}:/root/StarCraftII/Maps/{args.map}:ro",
    ]
    if args.mode == "duel":
        portable_racket = repo_dir / "ladder" / ".cache" / "racket_runtime" / "bin" / "racket"
        if not portable_racket.is_file():
            portable_racket = DEFAULT_REPO_DIR / "ladder" / ".cache" / "racket_runtime" / "bin" / "racket"
        portable_etc = arena_dir / "cache" / "racket-etc"
        if not portable_racket.is_file():
            raise FileNotFoundError(f"Portable Racket missing at {portable_racket}")
        mounts.extend([
            "-v", f"{portable_racket.resolve()}:/usr/local/bin/racket:ro",
            "-v", "/usr/share/racket:/usr/share/racket:ro",
            "-v", "/usr/lib/x86_64-linux-gnu/racket:/usr/lib/x86_64-linux-gnu/racket:ro",
        ])
        if portable_etc.is_dir():
            mounts.extend(["-v", f"{portable_etc}:/etc/racket-portable:ro"])
        elif (DEFAULT_REPO_DIR / "ladder" / ".cache" / "portable-etc").is_dir():
            mounts.extend(["-v", f"{DEFAULT_REPO_DIR / 'ladder' / '.cache' / 'portable-etc'}:/etc/racket-portable:ro"])

    inner_cmd = [
        "python3", "/harness/sc2-tactics-arena.py",
        "--in-container",
        "--mode", args.mode,
        "--map", args.map,
        "--race", race,
        "--step-size", str(args.step_size),
    ]
    cmd = ["podman", "run", "--rm", "--network", "none", *mounts, args.image, *inner_cmd]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"Container failed for race={race} (rc={proc.returncode}):\n{proc.stderr}\n{proc.stdout}")
    return json.loads(proc.stdout)


def run_host_driver(args: argparse.Namespace) -> int:
    t0 = time.monotonic()
    if args.mode == "duel" and args.race.lower() == "all":
        races = ["Protoss", "Terran", "Zerg"]
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futs = {pool.submit(run_single_container, args, r): r for r in races}
            sub_reports: dict[str, dict[str, Any]] = {}
            for fut in concurrent.futures.as_completed(futs):
                r = futs[fut]
                sub_reports[r] = fut.result()
        all_scens: list[dict[str, Any]] = []
        for r in races:
            all_scens.extend(sub_reports[r].get("scenarios", []))
        wins = sum(1 for s in all_scens if s.get("winner") == "Mothman")
        tot_p1_lost = sum(float(s.get("p1_lost_val", 0.0)) for s in all_scens)
        tot_p2_lost = sum(float(s.get("p2_lost_val", 0.0)) for s in all_scens)
        agg_trade = round(tot_p2_lost / max(1.0, tot_p1_lost), 2) if tot_p1_lost > 0 else 99.0
        tot_atk = sum(int(s.get("mothman_attack_unit_cmds", 0)) for s in all_scens)
        tot_mov = sum(int(s.get("mothman_move_unit_cmds", 0)) for s in all_scens)
        tot_spl = sum(int(s.get("mothman_spell_unit_cmds", 0)) for s in all_scens)
        by_race: dict[str, Any] = {}
        for r in races:
            rs = [s for s in all_scens if s.get("race") == r]
            r_p1 = sum(float(s.get("p1_lost_val", 0.0)) for s in rs)
            r_p2 = sum(float(s.get("p2_lost_val", 0.0)) for s in rs)
            r_atk = sum(int(s.get("mothman_attack_unit_cmds", 0)) for s in rs)
            r_mov = sum(int(s.get("mothman_move_unit_cmds", 0)) for s in rs)
            r_spl = sum(int(s.get("mothman_spell_unit_cmds", 0)) for s in rs)
            by_race[r] = {
                "total": len(rs),
                "mothman_wins": sum(1 for s in rs if s.get("winner") == "Mothman"),
                "agg_trade_ratio": round(r_p2 / max(1.0, r_p1), 2) if r_p1 > 0 else 99.0,
                "attack_unit_cmds": r_atk,
                "move_unit_cmds": r_mov,
                "spell_unit_cmds": r_spl,
                "am_ratio": round(r_atk / max(1, r_mov), 2),
            }
        report = {
            "mode": "duel",
            "engine": "SC2_x64_Base75689",
            "map": args.map,
            "total_wall_ms": round((time.monotonic() - t0) * 1000.0, 1),
            "summary": {
                "total": len(all_scens),
                "mothman_wins": wins,
                "agg_trade_ratio": agg_trade,
                "total_p1_lost_val": round(tot_p1_lost, 1),
                "total_p2_lost_val": round(tot_p2_lost, 1),
                "total_attack_unit_cmds": tot_atk,
                "total_move_unit_cmds": tot_mov,
                "total_spell_unit_cmds": tot_spl,
                "am_ratio": round(tot_atk / max(1, tot_mov), 2),
                "by_race": by_race,
            },
            "scenarios": all_scens,
        }
    else:
        report = run_single_container(args, args.race)

    if args.compare:
        base_path = Path(args.compare)
        if base_path.is_file():
            base_doc = json.loads(base_path.read_text(encoding="utf-8"))
            base_by_id = {s["id"]: s for s in base_doc.get("scenarios", []) if "id" in s}
            cur_by_id = {s["id"]: s for s in report.get("scenarios", []) if "id" in s}
            common_ids = [sid for sid in cur_by_id if sid in base_by_id]
            c_wins_base = sum(1 for sid in common_ids if base_by_id[sid].get("winner") == "Mothman")
            c_wins_cur = sum(1 for sid in common_ids if cur_by_id[sid].get("winner") == "Mothman")
            b_p1 = sum(float(base_by_id[sid].get("p1_lost_val", 0.0)) for sid in common_ids)
            b_p2 = sum(float(base_by_id[sid].get("p2_lost_val", 0.0)) for sid in common_ids)
            c_p1 = sum(float(cur_by_id[sid].get("p1_lost_val", 0.0)) for sid in common_ids)
            c_p2 = sum(float(cur_by_id[sid].get("p2_lost_val", 0.0)) for sid in common_ids)
            b_agg = round(b_p2 / max(1.0, b_p1), 2) if b_p1 > 0 else 99.0
            c_agg = round(c_p2 / max(1.0, c_p1), 2) if c_p1 > 0 else 99.0
            b_atk = sum(int(base_by_id[sid].get("mothman_attack_unit_cmds", 0)) for sid in common_ids)
            b_mov = sum(int(base_by_id[sid].get("mothman_move_unit_cmds", 0)) for sid in common_ids)
            c_atk = sum(int(cur_by_id[sid].get("mothman_attack_unit_cmds", 0)) for sid in common_ids)
            c_mov = sum(int(cur_by_id[sid].get("mothman_move_unit_cmds", 0)) for sid in common_ids)
            b_am = round(b_atk / max(1, b_mov), 2)
            c_am = round(c_atk / max(1, c_mov), 2)
            per_scen = []
            for sid in common_ids:
                bs, cs = base_by_id[sid], cur_by_id[sid]
                bt = float(bs.get("trade_ratio", 0.0))
                ct = float(cs.get("trade_ratio", 0.0))
                per_scen.append({
                    "id": sid,
                    "prev_winner": bs.get("winner"),
                    "winner": cs.get("winner"),
                    "prev_trade": bt,
                    "trade": ct,
                    "trade_delta": round(ct - bt, 2),
                    "prev_atk": int(bs.get("mothman_attack_unit_cmds", 0)),
                    "atk": int(cs.get("mothman_attack_unit_cmds", 0)),
                    "prev_mov": int(bs.get("mothman_move_unit_cmds", 0)),
                    "mov": int(cs.get("mothman_move_unit_cmds", 0)),
                })
            report["comparison"] = {
                "baseline_path": str(base_path),
                "common_count": len(common_ids),
                "prev_wins": c_wins_base,
                "cur_wins": c_wins_cur,
                "wins_delta": c_wins_cur - c_wins_base,
                "prev_agg_trade": b_agg,
                "cur_agg_trade": c_agg,
                "agg_trade_delta": round(c_agg - b_agg, 2),
                "prev_am_ratio": b_am,
                "cur_am_ratio": c_am,
                "am_ratio_delta": round(c_am - b_am, 2),
                "flipped_to_win": [x["id"] for x in per_scen if x["prev_winner"] != "Mothman" and x["winner"] == "Mothman"],
                "flipped_from_win": [x["id"] for x in per_scen if x["prev_winner"] == "Mothman" and x["winner"] != "Mothman"],
                "by_scenario": per_scen,
            }

    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


# -----------------------------------------------------------------------------
# In-Container SC2_x64 Engine & RequestDebug Skirmish Runner
# -----------------------------------------------------------------------------
async def run_in_container(args: argparse.Namespace) -> int:
    import aiohttp
    from aiohttp import web
    from s2clientprotocol import common_pb2, debug_pb2, raw_pb2, sc2api_pb2

    SC2_BASE = Path("/root/StarCraftII")
    SC2_BIN = SC2_BASE / "Versions" / "Base75689" / "SC2_x64"
    SC2_CWD = SC2_BASE / "Support64"
    SC2_PORT = 5001
    SC2_PORT_2 = 5002
    PROXY_PORT = 8081

    RACE_ENUM = {
        "Protoss": common_pb2.Protoss,
        "Terran": common_pb2.Terran,
        "Zerg": common_pb2.Zerg,
    }

    t_start = time.monotonic()
    sc2_tmp = tempfile.mkdtemp(prefix="sc2_tactics_")
    sc2_proc = subprocess.Popen(
        [str(SC2_BIN), "-listen", "127.0.0.1", "-port", str(SC2_PORT),
         "-dataDir", str(SC2_BASE), "-displayMode", "0", "-tempDir", sc2_tmp],
        cwd=str(SC2_CWD if SC2_CWD.is_dir() else SC2_BASE),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    async def rpc(ws: aiohttp.ClientWebSocketResponse, req: sc2api_pb2.Request, timeout: float = 30.0) -> sc2api_pb2.Response:
        await ws.send_bytes(req.SerializeToString())
        msg = await asyncio.wait_for(ws.receive(), timeout=timeout)
        if msg.type != aiohttp.WSMsgType.BINARY:
            raise RuntimeError(f"Unexpected WS msg type={msg.type}")
        resp = sc2api_pb2.Response()
        resp.ParseFromString(msg.data)
        return resp

    async def wait_sc2_port(session: aiohttp.ClientSession, port: int) -> aiohttp.ClientWebSocketResponse:
        url = f"ws://127.0.0.1:{port}/sc2api"
        deadline = time.monotonic() + 30.0
        last_err = None
        while time.monotonic() < deadline:
            try:
                ws = await session.ws_connect(url, max_msg_size=128 * 1024 * 1024)
                await rpc(ws, sc2api_pb2.Request(ping=sc2api_pb2.RequestPing()), timeout=5.0)
                return ws
            except Exception as exc:
                last_err = exc
                await asyncio.sleep(0.2)
        raise RuntimeError(f"SC2_x64 on :{port} failed to start: {last_err}")

    def find_open_arena_center(game_info: Any) -> tuple[float, float]:
        """Scan SC2 pathing_grid near map center for a guaranteed open 16x10 pathable clearing."""
        pg = game_info.start_raw.pathing_grid
        w, h = pg.size.x, pg.size.y
        data = pg.data
        bpp = pg.bits_per_pixel

        def is_pathable(x: int, y: int) -> bool:
            if x < 16 or y < 16 or x >= w - 16 or y >= h - 16:
                return False
            idx = y * w + x
            if bpp == 1:
                return bool((data[idx // 8] >> (7 - (idx % 8))) & 1)
            return data[idx] != 0

        cx0, cy0 = w // 2, h // 2
        for rad in range(0, 45, 2):
            for dx in range(-rad, rad + 1, 2):
                for dy in (-rad, rad) if abs(dx) < rad else range(-rad, rad + 1, 2):
                    tx, ty = cx0 + dx, cy0 + dy
                    if all(is_pathable(tx + ox, ty + oy) for ox in range(-8, 9, 2) for oy in range(-5, 6, 2)):
                        return float(tx), float(ty)
        return float(cx0), float(cy0)

    scenarios = (
        DEFAULT_SKIRMISHES
        if args.race.lower() == "all"
        else [s for s in DEFAULT_SKIRMISHES if s.our_race.lower() == args.race.lower()]
    )
    if not scenarios:
        scenarios = [DEFAULT_SKIRMISHES[0]]

    try:
        async with aiohttp.ClientSession() as session:
            t_boot0 = time.monotonic()
            sc2_ws = await wait_sc2_port(session, SC2_PORT)
            boot_ms = round((time.monotonic() - t_boot0) * 1000.0, 1)

            if args.mode == "duel":
                # 2-Participant Multi-Scenario Real-SC2_x64 Duel inside ONE container!
                sc2_tmp2 = tempfile.mkdtemp(prefix="sc2_tactics_p2_")
                sc2_proc2 = subprocess.Popen(
                    [str(SC2_BIN), "-listen", "127.0.0.1", "-port", str(SC2_PORT_2),
                     "-dataDir", str(SC2_BASE), "-displayMode", "0", "-tempDir", sc2_tmp2],
                    cwd=str(SC2_CWD if SC2_CWD.is_dir() else SC2_BASE),
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                try:
                    sc2_ws2 = await wait_sc2_port(session, SC2_PORT_2)
                    cg2 = sc2api_pb2.RequestCreateGame(
                        local_map=sc2api_pb2.LocalMap(map_path=args.map),
                        realtime=False,
                        disable_fog=True,
                    )
                    pa = cg2.player_setup.add()
                    pa.type = sc2api_pb2.Participant
                    pb = cg2.player_setup.add()
                    pb.type = sc2api_pb2.Participant
                    cg2_resp = await rpc(sc2_ws, sc2api_pb2.Request(create_game=cg2))
                    if cg2_resp.HasField("create_game") and cg2_resp.create_game.HasField("error"):
                        raise RuntimeError(f"2P CreateGame failed: {cg2_resp.create_game.error_details}")

                    our_race = scenarios[0].our_race
                    enemy_race = scenarios[0].enemy_race
                    bot_dir = Path(tempfile.mkdtemp(prefix="mothman_duel_bot_"))
                    (bot_dir / "data").mkdir(exist_ok=True)
                    bot_map = {
                        "Protoss": ("Mothman-P", "/mothman-repo/bots/mothman-protoss.rkt"),
                        "Terran": ("Mothman-T", "/mothman-repo/bots/mothman-terran.rkt"),
                        "Zerg": ("Mothman-Z", "/mothman-repo/bots/mothman-zerg.rkt"),
                    }
                    bname, bpath = bot_map.get(our_race, bot_map["Protoss"])
                    (bot_dir / "config.json").write_text(
                        json.dumps({"BotName": bname, "BotRace": our_race, "BotPath": bpath}, indent=2),
                        encoding="utf-8",
                    )
                    (bot_dir / "data" / "mirror_mind_opponents.json").write_text(
                        json.dumps({"bot_name": bname, "opponents": {}}, indent=2), encoding="utf-8"
                    )

                    dstate: dict[str, Any] = {
                        "arena_cx": 88.0,
                        "arena_cy": 88.0,
                        "scen_idx": 0,
                        "phase": "wait_init",  # wait_init -> clearing -> spawning -> fighting -> done
                        "phase_start_loop": 0,
                        "p2_clear_ok": False,
                        "round_t0": time.monotonic(),
                        "attack_cmds": 0,
                        "move_cmds": 0,
                        "spell_cmds": 0,
                        "ability_counts": {},
                        "p1_start_cnt": 0,
                        "p2_start_cnt": 0,
                        "p1_start_types": {},
                        "p2_start_types": {},
                        "p1_start_val": 0.0,
                        "p2_start_val": 0.0,
                        "p1_alive_cnt": 0,
                        "p2_alive_cnt": 0,
                        "p1_rem_val": 0.0,
                        "p2_rem_val": 0.0,
                        "results": [],
                        "p1_joined": asyncio.Event(),
                        "done": asyncio.Event(),
                    }

                    def make_mp_join(race_enum: int, pname: str) -> sc2api_pb2.Request:
                        jg = sc2api_pb2.RequestJoinGame(
                            race=race_enum,
                            player_name=pname,
                            options=sc2api_pb2.InterfaceOptions(raw=True, score=True),
                            shared_port=9200,
                        )
                        jg.server_ports.game_port = 9201
                        jg.server_ports.base_port = 9202
                        cp = jg.client_ports.add()
                        cp.game_port = 9203
                        cp.base_port = 9204
                        return sc2api_pb2.Request(join_game=jg)

                    async def p2_aggressive_micro_loop() -> None:
                        await dstate["p1_joined"].wait()
                        await rpc(sc2_ws2, make_mp_join(RACE_ENUM.get(enemy_race, common_pb2.Terran), "MicroDummy"))
                        step_n = max(1, args.step_size)
                        while not dstate["done"].is_set():
                            obs_r = await rpc(sc2_ws2, sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation()))
                            obs = obs_r.observation.observation
                            if dstate["phase"] == "clearing":
                                # Kill P2 non-TownHall units from P2's socket; signal p2_clear_ok ONLY once 0 remain!
                                p2_kill = [u.tag for u in obs.raw_data.units if u.alliance == 1 and u.unit_type not in TOWNHALL_IDS]
                                if p2_kill:
                                    dstate["p2_clear_ok"] = False
                                    await rpc(sc2_ws2, sc2api_pb2.Request(
                                        debug=sc2api_pb2.RequestDebug(
                                            debug=[debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=p2_kill))]
                                        )
                                    ))
                                else:
                                    dstate["p2_clear_ok"] = True
                            elif dstate["phase"] == "fighting":
                                my_u = [u for u in obs.raw_data.units if u.display_type == 1 and u.alliance == 1 and u.unit_type in COMBAT_IDS]
                                en_u = [u for u in obs.raw_data.units if u.display_type == 1 and u.alliance == 4 and u.unit_type in COMBAT_IDS]
                                if my_u and en_u:
                                    cx_my = sum(u.pos.x for u in my_u) / len(my_u)
                                    cy_my = sum(u.pos.y for u in my_u) / len(my_u)
                                    tgt = min(en_u, key=lambda e: (math.hypot(e.pos.x - cx_my, e.pos.y - cy_my), e.health + e.shield))
                                    act = sc2api_pb2.Action(
                                        action_raw=raw_pb2.ActionRaw(
                                            unit_command=raw_pb2.ActionRawUnitCommand(
                                                ability_id=23,
                                                target_unit_tag=tgt.tag,
                                                unit_tags=[u.tag for u in my_u],
                                            )
                                        )
                                    )
                                    await rpc(sc2_ws2, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=[act])))
                            await rpc(sc2_ws2, sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=step_n)))

                    def finalize_current_round(cur_loop: int) -> None:
                        scen = scenarios[dstate["scen_idx"]]
                        p1_lost = max(0.0, dstate["p1_start_val"] - dstate["p1_rem_val"])
                        p2_lost = max(0.0, dstate["p2_start_val"] - dstate["p2_rem_val"])
                        trade = round(p2_lost / max(1.0, p1_lost), 2) if p1_lost > 0 else (99.0 if p2_lost > 0 else 1.0)
                        winner = (
                            "Mothman" if (dstate["p1_alive_cnt"] > 0 and dstate["p2_alive_cnt"] == 0)
                            else ("MicroDummy" if (dstate["p2_alive_cnt"] > 0 and dstate["p1_alive_cnt"] == 0) else "Timeout")
                        )
                        dstate["results"].append({
                            "id": scen.id,
                            "bot": bname,
                            "race": scen.our_race,
                            "enemy_race": scen.enemy_race,
                            "winner": winner,
                            "p1_start_cnt": dstate["p1_start_cnt"],
                            "p2_start_cnt": dstate["p2_start_cnt"],
                            "p1_start_types": dstate["p1_start_types"],
                            "p2_start_types": dstate["p2_start_types"],
                            "p1_alive_cnt": dstate["p1_alive_cnt"],
                            "p2_alive_cnt": dstate["p2_alive_cnt"],
                            "p1_lost_val": round(p1_lost, 1),
                            "p2_lost_val": round(p2_lost, 1),
                            "trade_ratio": trade,
                            "mothman_attack_unit_cmds": dstate["attack_cmds"],
                            "mothman_move_unit_cmds": dstate["move_cmds"],
                            "mothman_spell_unit_cmds": dstate["spell_cmds"],
                            "mothman_ability_breakdown": dict(
                                sorted(dstate["ability_counts"].items(), key=lambda kv: -kv[1])[:10]
                            ),
                            "first_action_loop_offset": dstate.get("first_action_loop_offset", -1),
                            "loops_simulated": cur_loop - dstate["phase_start_loop"],
                            "wall_ms": round((time.monotonic() - dstate["round_t0"]) * 1000.0, 1),
                        })

                    async def duel_ws_handler(http_req: web.Request) -> web.WebSocketResponse:
                        bot_ws = web.WebSocketResponse(max_msg_size=128 * 1024 * 1024)
                        await bot_ws.prepare(http_req)
                        try:
                            async for msg in bot_ws:
                                if msg.type != aiohttp.WSMsgType.BINARY:
                                    continue
                                req = sc2api_pb2.Request()
                                req.ParseFromString(msg.data)

                                if dstate["phase"] == "fighting" and req.HasField("action"):
                                    for a in req.action.actions:
                                        if a.HasField("action_raw") and a.action_raw.HasField("unit_command"):
                                            ab = a.action_raw.unit_command.ability_id
                                            n_tags = len(a.action_raw.unit_command.unit_tags)
                                            dstate["ability_counts"][str(ab)] = dstate["ability_counts"].get(str(ab), 0) + n_tags
                                            if ab == 23:
                                                dstate["attack_cmds"] += n_tags
                                                if dstate.get("first_action_loop_offset", -1) < 0:
                                                    dstate["first_action_loop_offset"] = max(0, dstate.get("last_obs_loop", dstate["phase_start_loop"]) - dstate["phase_start_loop"])
                                            elif ab == 16:
                                                dstate["move_cmds"] += n_tags
                                            elif ab not in (298, 299, 3666):
                                                dstate["spell_cmds"] += n_tags
                                                if dstate.get("first_action_loop_offset", -1) < 0:
                                                    dstate["first_action_loop_offset"] = max(0, dstate.get("last_obs_loop", dstate["phase_start_loop"]) - dstate["phase_start_loop"])

                                if req.HasField("join_game"):
                                    dstate["p1_joined"].set()
                                    resp = await rpc(sc2_ws, make_mp_join(RACE_ENUM.get(our_race, common_pb2.Protoss), bname))
                                    await bot_ws.send_bytes(resp.SerializeToString())
                                    continue

                                resp = await rpc(sc2_ws, req)
                                if req.HasField("game_info") and resp.HasField("game_info"):
                                    dstate["arena_cx"], dstate["arena_cy"] = find_open_arena_center(resp.game_info)

                                if req.HasField("observation") and resp.HasField("observation"):
                                    obs = resp.observation.observation
                                    gl = obs.game_loop
                                    dstate["last_obs_loop"] = gl
                                    cx, cy = dstate["arena_cx"], dstate["arena_cy"]

                                    if dstate["phase"] == "wait_init" and gl >= 4:
                                        # Clear starting workers + reveal map, enter clearing phase
                                        kill_tags = [u.tag for u in obs.raw_data.units if u.alliance in (1, 4) and u.unit_type not in TOWNHALL_IDS]
                                        dbg = [debug_pb2.DebugCommand(game_state=debug_pb2.show_map)]
                                        if kill_tags:
                                            dbg.append(debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=kill_tags)))
                                        await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg)))
                                        dstate["p2_clear_ok"] = False
                                        dstate["phase"] = "clearing"
                                        dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "clearing":
                                        rem_u = [
                                            u for u in obs.raw_data.units
                                            if u.display_type == 1 and u.alliance in (1, 4)
                                            and u.unit_type in COMBAT_IDS
                                        ]
                                        if rem_u:
                                            await rpc(sc2_ws, sc2api_pb2.Request(
                                                debug=sc2api_pb2.RequestDebug(
                                                    debug=[debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=[u.tag for u in rem_u]))]
                                                )
                                            ))
                                        elif dstate["p2_clear_ok"] and gl >= dstate["phase_start_loop"] + 4:
                                            dstate["phase"] = "spawning"
                                            dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "spawning" and gl >= dstate["phase_start_loop"] + 2:
                                        scen = scenarios[dstate["scen_idx"]]
                                        dbg = []
                                        for uname, cnt, dx, dy in scen.p1_units:
                                            dbg.append(debug_pb2.DebugCommand(
                                                create_unit=debug_pb2.DebugCreateUnit(
                                                    unit_type=UNIT_IDS[uname], owner=1,
                                                    pos=common_pb2.Point2D(x=cx + dx, y=cy + dy), quantity=cnt,
                                                )
                                            ))
                                        for uname, cnt, dx, dy in scen.p2_units:
                                            dbg.append(debug_pb2.DebugCommand(
                                                create_unit=debug_pb2.DebugCreateUnit(
                                                    unit_type=UNIT_IDS[uname], owner=2,
                                                    pos=common_pb2.Point2D(x=cx + dx, y=cy + dy), quantity=cnt,
                                                )
                                            ))
                                        await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg)))
                                        dstate["phase"] = "fighting"
                                        dstate["phase_start_loop"] = gl
                                        dstate["round_t0"] = time.monotonic()
                                        dstate["attack_cmds"] = 0
                                        dstate["move_cmds"] = 0
                                        dstate["spell_cmds"] = 0
                                        dstate["ability_counts"] = {}
                                        dstate["first_action_loop_offset"] = -1
                                        dstate["p1_start_cnt"] = 0
                                        dstate["p2_start_cnt"] = 0
                                        dstate["p1_start_val"] = 0.0
                                        dstate["p2_start_val"] = 0.0

                                    elif dstate["phase"] == "fighting":
                                        scen = scenarios[dstate["scen_idx"]]
                                        p1u = [u for u in obs.raw_data.units if u.display_type == 1 and u.alliance == 1 and u.unit_type in COMBAT_IDS]
                                        p2u = [u for u in obs.raw_data.units if u.display_type == 1 and u.alliance == 4 and u.unit_type in COMBAT_IDS]
                                        exp_p1 = sum(cnt for _, cnt, _, _ in scen.p1_units)
                                        exp_p2 = sum(cnt for _, cnt, _, _ in scen.p2_units)
                                        if dstate["p1_start_cnt"] == 0 and (len(p1u) >= exp_p1 and len(p2u) >= exp_p2 or (gl >= dstate["phase_start_loop"] + 8 and p1u and p2u)):
                                            dstate["p1_start_cnt"] = len(p1u)
                                            dstate["p2_start_cnt"] = len(p2u)
                                            id_to_name = {v: k for k, v in UNIT_IDS.items()}
                                            t1: dict[str, int] = {}
                                            for u in p1u:
                                                nm = id_to_name.get(u.unit_type, str(u.unit_type))
                                                t1[nm] = t1.get(nm, 0) + 1
                                            t2: dict[str, int] = {}
                                            for u in p2u:
                                                nm = id_to_name.get(u.unit_type, str(u.unit_type))
                                                t2[nm] = t2.get(nm, 0) + 1
                                            dstate["p1_start_types"] = t1
                                            dstate["p2_start_types"] = t2
                                            dstate["p1_start_val"] = sum(UNIT_VALUES.get(u.unit_type, 100.0) for u in p1u)
                                            dstate["p2_start_val"] = sum(UNIT_VALUES.get(u.unit_type, 100.0) for u in p2u)
                                            # Boost spawned casters/supports (HT, Ghost, Sentry, Queen, Medivac, Infestor) to 120 energy, Viper (499) to 140 for Parasitic Bomb (125)
                                            energy_cmds = [
                                                debug_pb2.DebugCommand(
                                                    unit_value=debug_pb2.DebugSetUnitValue(
                                                        unit_value=debug_pb2.DebugSetUnitValue.Energy,
                                                        value=min(140.0 if u.unit_type == 499 else 120.0, float(u.energy_max)),
                                                        unit_tag=u.tag,
                                                    )
                                                )
                                                for u in (p1u + p2u)
                                                if getattr(u, "energy_max", 0.0) > 0.0
                                            ]
                                            if energy_cmds:
                                                await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=energy_cmds)))
                                        if dstate["p1_start_cnt"] > 0:
                                            dstate["p1_alive_cnt"] = len(p1u)
                                            dstate["p2_alive_cnt"] = len(p2u)
                                            dstate["p1_rem_val"] = sum(UNIT_VALUES.get(u.unit_type, 100.0) for u in p1u)
                                            dstate["p2_rem_val"] = sum(UNIT_VALUES.get(u.unit_type, 100.0) for u in p2u)
                                            elapsed_loops = gl - dstate["phase_start_loop"]
                                            if elapsed_loops >= scen.max_loops or not p1u or not p2u:
                                                finalize_current_round(gl)
                                                dstate["scen_idx"] += 1
                                                if dstate["scen_idx"] >= len(scenarios):
                                                    dstate["phase"] = "done"
                                                    dstate["done"].set()
                                                else:
                                                    # Kill all remaining non-TH units and advance to next skirmish!
                                                    kill_tags = [u.tag for u in obs.raw_data.units if u.alliance in (1, 4) and u.unit_type not in TOWNHALL_IDS]
                                                    if kill_tags:
                                                        await rpc(sc2_ws, sc2api_pb2.Request(
                                                            debug=sc2api_pb2.RequestDebug(
                                                                debug=[debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=kill_tags))]
                                                            )
                                                        ))
                                                    dstate["p2_clear_ok"] = False
                                                    dstate["phase"] = "clearing"
                                                    dstate["phase_start_loop"] = gl

                                await bot_ws.send_bytes(resp.SerializeToString())
                                if dstate["done"].is_set():
                                    break
                        finally:
                            dstate["done"].set()
                        return bot_ws

                    app = web.Application()
                    app.router.add_get("/sc2api", duel_ws_handler)
                    runner = web.AppRunner(app)
                    await runner.setup()
                    site = web.TCPSite(runner, "127.0.0.1", PROXY_PORT)
                    await site.start()

                    p2_task = asyncio.create_task(p2_aggressive_micro_loop())
                    bot_cmd = [
                        "/usr/local/bin/racket", "-U", "-X", "/usr/share/racket/collects",
                        "-G", "/etc/racket-portable",
                        "/mothman-repo/sim/racket-sc2-ladder-main.rkt",
                        "--BotName", bname,
                        "--GamePort", str(PROXY_PORT),
                        "--LadderServer", "127.0.0.1",
                        "--StartPort", "8090",
                        "--OpponentId", "MicroDummy",
                    ]
                    bot_log = (bot_dir / "bot.log").open("wb")
                    bot_proc = subprocess.Popen(bot_cmd, cwd=str(bot_dir), stdout=bot_log, stderr=subprocess.STDOUT)
                    try:
                        await asyncio.wait_for(dstate["done"].wait(), timeout=120.0)
                    finally:
                        dstate["done"].set()
                        p2_task.cancel()
                        bot_proc.terminate()
                        try:
                            bot_proc.wait(timeout=3.0)
                        except Exception:
                            bot_proc.kill()
                        bot_log.close()
                        await runner.cleanup()

                    res = dstate["results"]
                    wins = sum(1 for s in res if s["winner"] == "Mothman")
                    tot_p1 = sum(s["p1_lost_val"] for s in res)
                    tot_p2 = sum(s["p2_lost_val"] for s in res)
                    report = {
                        "mode": "duel",
                        "engine": "SC2_x64_Base75689",
                        "bot": bname,
                        "race": our_race,
                        "map": args.map,
                        "sc2_boot_ms": boot_ms,
                        "total_wall_ms": round((time.monotonic() - t_start) * 1000.0, 1),
                        "summary": {
                            "total": len(res),
                            "mothman_wins": wins,
                            "agg_trade_ratio": round(tot_p2 / max(1.0, tot_p1), 2) if tot_p1 > 0 else 99.0,
                        },
                        "scenarios": res,
                    }
                    print(json.dumps(report, indent=2))
                    return 0
                finally:
                    sc2_proc2.terminate()
                    try:
                        sc2_proc2.wait(timeout=3.0)
                    except Exception:
                        sc2_proc2.kill()

            # --- Standalone RequestDebug Probe Mode ---
            primary_race = scenarios[0].our_race
            enemy_race = scenarios[0].enemy_race
            cg = sc2api_pb2.RequestCreateGame(
                local_map=sc2api_pb2.LocalMap(map_path=args.map),
                realtime=False,
                disable_fog=True,
            )
            p1 = cg.player_setup.add()
            p1.type = sc2api_pb2.Participant
            p1.race = RACE_ENUM.get(primary_race, common_pb2.Protoss)
            p2 = cg.player_setup.add()
            p2.type = sc2api_pb2.Computer
            p2.race = RACE_ENUM.get(enemy_race, common_pb2.Terran)
            p2.difficulty = sc2api_pb2.VeryEasy
            cg_resp = await rpc(sc2_ws, sc2api_pb2.Request(create_game=cg))
            if cg_resp.HasField("create_game") and cg_resp.create_game.HasField("error"):
                raise RuntimeError(f"CreateGame failed: {cg_resp.create_game.error_details}")

            jg = sc2api_pb2.RequestJoinGame(
                race=RACE_ENUM.get(primary_race, common_pb2.Protoss),
                options=sc2api_pb2.InterfaceOptions(raw=True, score=True),
            )
            await rpc(sc2_ws, sc2api_pb2.Request(join_game=jg))
            gi_resp = await rpc(sc2_ws, sc2api_pb2.Request(game_info=sc2api_pb2.RequestGameInfo()))
            arena_cx, arena_cy = find_open_arena_center(gi_resp.game_info)

            await rpc(sc2_ws, sc2api_pb2.Request(
                debug=sc2api_pb2.RequestDebug(debug=[debug_pb2.DebugCommand(game_state=debug_pb2.show_map)])
            ))
            await rpc(sc2_ws, sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=2)))

            results: list[dict[str, Any]] = []
            observed_wcd: list[float] = []
            for scen in scenarios[:3]:
                st0 = time.monotonic()
                obs_resp = await rpc(sc2_ws, sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation()))
                kill_tags = [u.tag for u in obs_resp.observation.observation.raw_data.units if u.alliance in (1, 4) and u.unit_type not in TOWNHALL_IDS]
                if kill_tags:
                    await rpc(sc2_ws, sc2api_pb2.Request(
                        debug=sc2api_pb2.RequestDebug(debug=[debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=kill_tags))])
                    ))
                    await rpc(sc2_ws, sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=2)))
                dbg_cmds = []
                for uname, cnt, dx, dy in scen.p1_units:
                    dbg_cmds.append(debug_pb2.DebugCommand(
                        create_unit=debug_pb2.DebugCreateUnit(unit_type=UNIT_IDS[uname], owner=1, pos=common_pb2.Point2D(x=arena_cx + dx, y=arena_cy + dy), quantity=cnt)
                    ))
                for uname, cnt, dx, dy in scen.p2_units:
                    dbg_cmds.append(debug_pb2.DebugCommand(
                        create_unit=debug_pb2.DebugCreateUnit(unit_type=UNIT_IDS[uname], owner=2, pos=common_pb2.Point2D(x=arena_cx + dx, y=arena_cy + dy), quantity=cnt)
                    ))
                await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg_cmds)))
                await rpc(sc2_ws, sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=2)))

                obs0 = (await rpc(sc2_ws, sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation()))).observation.observation
                p1_start = [u for u in obs0.raw_data.units if u.alliance == 1 and u.unit_type not in TOWNHALL_IDS and math.hypot(u.pos.x - arena_cx, u.pos.y - arena_cy) < 35.0]
                p2_start = [u for u in obs0.raw_data.units if u.alliance == 4 and u.unit_type not in TOWNHALL_IDS and math.hypot(u.pos.x - arena_cx, u.pos.y - arena_cy) < 35.0]
                p1_alive, p2_alive = p1_start, p2_start
                loops_run = 0
                while loops_run < scen.max_loops and p1_alive and p2_alive:
                    ex = sum(u.pos.x for u in p2_alive) / len(p2_alive)
                    ey = sum(u.pos.y for u in p2_alive) / len(p2_alive)
                    act = sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(
                        ability_id=23, target_world_space_pos=common_pb2.Point2D(x=ex, y=ey), unit_tags=[u.tag for u in p1_alive]
                    )))
                    await rpc(sc2_ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=[act])))
                    await rpc(sc2_ws, sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=max(1, args.step_size))))
                    loops_run += max(1, args.step_size)
                    obs_now = (await rpc(sc2_ws, sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation()))).observation.observation
                    p1_alive = [u for u in obs_now.raw_data.units if u.alliance == 1 and u.unit_type not in TOWNHALL_IDS and math.hypot(u.pos.x - arena_cx, u.pos.y - arena_cy) < 38.0]
                    p2_alive = [u for u in obs_now.raw_data.units if u.alliance == 4 and u.unit_type not in TOWNHALL_IDS and math.hypot(u.pos.x - arena_cx, u.pos.y - arena_cy) < 38.0]
                    for u in p1_alive:
                        if u.weapon_cooldown > 0.0:
                            observed_wcd.append(round(float(u.weapon_cooldown), 3))
                results.append({
                    "id": scen.id,
                    "p1_start_cnt": len(p1_start),
                    "p2_start_cnt": len(p2_start),
                    "p1_alive_cnt": len(p1_alive),
                    "p2_alive_cnt": len(p2_alive),
                    "loops_simulated": loops_run,
                    "wall_ms": round((time.monotonic() - st0) * 1000.0, 1),
                })

            print(json.dumps({
                "mode": "probe",
                "engine": "SC2_x64_Base75689",
                "sc2_boot_ms": boot_ms,
                "total_wall_ms": round((time.monotonic() - t_start) * 1000.0, 1),
                "weapon_cooldown_in_game_loops_confirmed": (max(observed_wcd) > 5.0) if observed_wcd else False,
                "observed_weapon_cooldown_sample": observed_wcd[:10],
                "scenarios": results,
            }, indent=2))
            return 0
    finally:
        sc2_proc.terminate()
        try:
            sc2_proc.wait(timeout=3.0)
        except Exception:
            sc2_proc.kill()


def main() -> int:
    parser = argparse.ArgumentParser(description="Real-SC2_x64 RequestDebug Micro Skirmish Arena")
    parser.add_argument("--in-container", action="store_true")
    parser.add_argument("--mode", choices=["probe", "duel"], default="duel")
    parser.add_argument("--race", default="all", help="Protoss | Terran | Zerg | all")
    parser.add_argument("--map", default=DEFAULT_MAP)
    parser.add_argument("--step-size", type=int, default=4)
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--repo-dir", default=str(DEFAULT_REPO_DIR))
    parser.add_argument("--maps-dir", default=str(DEFAULT_MAPS_DIR))
    parser.add_argument("--arena-dir", default=str(DEFAULT_ARENA_DIR))
    parser.add_argument("--out", default="")
    parser.add_argument("--compare", default="", help="Optional baseline JSON path to emit A/B delta comparison")
    args = parser.parse_args()
    if args.in_container:
        return asyncio.run(run_in_container(args))
    return run_host_driver(args)


if __name__ == "__main__":
    raise SystemExit(main())
