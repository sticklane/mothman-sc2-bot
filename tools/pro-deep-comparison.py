#!/usr/bin/env python3
"""
tools/pro-deep-comparison.py

Deep spatial and temporal comparison of standard 1v1 Grandmaster Pro games
(`replays/pro_corpus/`) against Mothman games (read-only `arena_replays.sqlite`,
default `iter45..iter48`) across all 9 matchups (PvP..ZvZ).

Measures:
  1. Building grouping & clustering at 4:10 (<=250s): production pairwise/NN spacing,
     Terran addon-swap cluster rate, tech distance from Main vs front choke, and
     supply zone breakdown (mineral-line / main-ramp / drop-vision perimeter / natural).
  2. Walling geometry (<=270s): Main ramp & Natural choke wall rates, building
     composition, edge-to-edge gap width, wall completion time, and fragile tech in wall.
  3. Timings (p25 / median / p75 + adoption rate + delta sec) for major buildings,
     first combat units, and core upgrades across Protoss, Terran, and Zerg.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import importlib.util
import json
import math
import os
import sqlite3
import statistics
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PRO_DIR = REPO_ROOT / "replays" / "pro_corpus"
DEFAULT_ARENA_DIR = Path.home() / "sc2-local-arena"
DEFAULT_DB_PATH = DEFAULT_ARENA_DIR / "arena_replays.sqlite"
DEFAULT_PYLIBS_DIR = DEFAULT_ARENA_DIR / "pylibs"
DEFAULT_RUN_PREFIXES = ("iter45", "iter46", "iter47", "iter48")

GAME_LOOPS_PER_SEC = 22.4
RACES = ("Protoss", "Terran", "Zerg")
RACE_LETTER = {"Protoss": "P", "Terran": "T", "Zerg": "Z"}
MATCHUPS = ("PvP", "PvT", "PvZ", "TvP", "TvT", "TvZ", "ZvP", "ZvT", "ZvZ")

TOWN_HALLS = frozenset({
    "Nexus",
    "CommandCenter", "CommandCenterFlying", "OrbitalCommand", "OrbitalCommandFlying", "PlanetaryFortress",
    "Hatchery", "Lair", "Hive",
})
GASES = frozenset({
    "Assimilator", "Refinery", "Extractor",
    "AssimilatorRich", "RefineryRich", "ExtractorRich",
})
SUPPLY = frozenset({"Pylon", "SupplyDepot", "SupplyDepotLowered"})
STATIC_DEF = frozenset({
    "PhotonCannon", "ShieldBattery", "Bunker", "MissileTurret",
    "SpineCrawler", "SporeCrawler",
})
PROD_BY_RACE = {
    "Protoss": frozenset({"Gateway", "WarpGate", "RoboticsFacility", "Stargate"}),
    "Terran": frozenset({"Barracks", "Factory", "Starport"}),
    "Zerg": frozenset({"Hatchery", "Lair", "Hive"}),
}
ALL_PROD = frozenset({
    "Gateway", "WarpGate", "RoboticsFacility", "Stargate",
    "Barracks", "Factory", "Starport",
})
TECH = frozenset({
    "CyberneticsCore", "TwilightCouncil", "Forge", "RoboticsBay",
    "TemplarArchive", "DarkShrine", "FleetBeacon",
    "EngineeringBay", "Armory", "GhostAcademy", "FusionCore",
    "SpawningPool", "RoachWarren", "BanelingNest", "EvolutionChamber",
    "HydraliskDen", "Spire", "GreaterSpire", "InfestationPit", "LurkerDenMP",
})
FRAGILE_TECH = frozenset({
    "RoboticsFacility", "Stargate", "TwilightCouncil", "RoboticsBay",
    "TemplarArchive", "DarkShrine", "FleetBeacon",
    "Factory", "Starport", "Armory", "GhostAcademy", "FusionCore",
    "Spire", "GreaterSpire", "HydraliskDen", "LurkerDenMP", "InfestationPit",
})
ADDONS = frozenset({
    "TechLab", "Reactor",
    "BarracksTechLab", "BarracksReactor",
    "FactoryTechLab", "FactoryReactor",
    "StarportTechLab", "StarportReactor",
})
ALL_BLDGS = TOWN_HALLS | GASES | SUPPLY | STATIC_DEF | ALL_PROD | TECH | ADDONS
TH_FOR_RACE = {"Protoss": "Nexus", "Terran": "CommandCenter", "Zerg": "Hatchery"}

# Standard SC2 building footprint widths (tiles) for edge-to-edge gap calculation
BLDG_SIZE: dict[str, float] = {
    **{k: 5.0 for k in TOWN_HALLS},
    **{k: 3.0 for k in (GASES | ALL_PROD | TECH)},
    **{k: 2.0 for k in (SUPPLY | STATIC_DEF | ADDONS)},
    "Bunker": 3.0,
    "MissileTurret": 2.0,
    "PhotonCannon": 2.0,
    "ShieldBattery": 2.0,
    "SpineCrawler": 2.0,
    "SporeCrawler": 2.0,
}

SHORT_BLDG_LABEL = {
    "SupplyDepot": "Depot",
    "SupplyDepotLowered": "Depot",
    "Barracks": "Rax",
    "Factory": "Fact",
    "Starport": "Starport",
    "EngineeringBay": "EBay",
    "Bunker": "Bunker",
    "MissileTurret": "Turret",
    "Pylon": "Pylon",
    "Gateway": "Gate",
    "WarpGate": "Gate",
    "CyberneticsCore": "Cyber",
    "RoboticsFacility": "Robo",
    "Stargate": "SG",
    "TwilightCouncil": "Twilight",
    "Forge": "Forge",
    "ShieldBattery": "Battery",
    "PhotonCannon": "Cannon",
    "SpawningPool": "Pool",
    "EvolutionChamber": "Evo",
    "RoachWarren": "RW",
    "BanelingNest": "BaneNest",
    "SpineCrawler": "Spine",
    "SporeCrawler": "Spore",
    "HydraliskDen": "HydraDen",
    "Spire": "Spire",
    "LurkerDenMP": "LurkerDen",
}

BAD_MAP_TOKENS = (
    "PCANP", "EnemyTower", "AI", "Mod", "Arcade", "Unit Tester", "Micro", "Sandbox",
    "星际", "Custom", "Practice", "Cheat",
)

# Canonical ordered timing spec per race:
# (key, display_label, event_source, unit_names_tuple, nth_index_1based)
# event_source:
#   "bldg_init"   -> nth init event (excluding sec <= 2.0 starting TH)
#   "th_expand"   -> nth additional TownHall init (sec > 5.0; 1 = Nat, 2 = 3rd)
#   "morph"       -> nth morph completion event (e.g. OrbitalCommand, Lair, LurkerMP)
#   "unit_first"  -> nth unit arrival (min of born/init per unit; handles Gateway + WarpGate!)
#   "upgrade"     -> completion time of SUpgradeEvent
TIMING_SPECS: dict[str, list[tuple[str, str, str, tuple[str, ...], int]]] = {
    "Protoss": [
        ("pylon_1", "Pylon #1", "bldg_init", ("Pylon",), 1),
        ("pylon_2", "Pylon #2", "bldg_init", ("Pylon",), 2),
        ("pylon_3", "Pylon #3", "bldg_init", ("Pylon",), 3),
        ("gate_1", "Gate #1", "bldg_init", ("Gateway",), 1),
        ("gate_2", "Gate #2", "bldg_init", ("Gateway",), 2),
        ("gate_3", "Gate #3", "bldg_init", ("Gateway",), 3),
        ("gas_1", "Gas #1", "bldg_init", ("Assimilator", "AssimilatorRich"), 1),
        ("gas_2", "Gas #2", "bldg_init", ("Assimilator", "AssimilatorRich"), 2),
        ("cyber", "Cyber Core", "bldg_init", ("CyberneticsCore",), 1),
        ("nat", "Natural Nexus", "th_expand", ("Nexus",), 1),
        ("third", "3rd Nexus", "th_expand", ("Nexus",), 2),
        ("robo", "Robo Facility", "bldg_init", ("RoboticsFacility",), 1),
        ("twilight", "Twilight", "bldg_init", ("TwilightCouncil",), 1),
        ("stargate", "Stargate", "bldg_init", ("Stargate",), 1),
        ("forge", "Forge", "bldg_init", ("Forge",), 1),
        ("unit_stalker_1", "1st Stalker", "unit_first", ("Stalker",), 1),
        ("unit_adept_1", "1st Adept", "unit_first", ("Adept",), 1),
        ("unit_immortal_1", "1st Immortal", "unit_first", ("Immortal",), 1),
        ("unit_observer_1", "1st Observer", "unit_first", ("Observer",), 1),
        ("unit_colossus_1", "1st Colossus", "unit_first", ("Colossus",), 1),
        ("upg_warpgate", "WarpGate (done)", "upgrade", ("WarpGateResearch",), 1),
    ],
    "Terran": [
        ("depot_1", "Depot #1", "bldg_init", ("SupplyDepot",), 1),
        ("depot_2", "Depot #2", "bldg_init", ("SupplyDepot",), 2),
        ("depot_3", "Depot #3", "bldg_init", ("SupplyDepot",), 3),
        ("rax_1", "Rax #1", "bldg_init", ("Barracks",), 1),
        ("rax_2", "Rax #2", "bldg_init", ("Barracks",), 2),
        ("rax_3", "Rax #3", "bldg_init", ("Barracks",), 3),
        ("gas_1", "Gas #1", "bldg_init", ("Refinery", "RefineryRich"), 1),
        ("gas_2", "Gas #2", "bldg_init", ("Refinery", "RefineryRich"), 2),
        ("nat", "Natural CC", "th_expand", ("CommandCenter",), 1),
        ("third", "3rd CC", "th_expand", ("CommandCenter",), 2),
        ("orbital", "Orbital (done)", "morph", ("OrbitalCommand",), 1),
        ("factory", "Factory", "bldg_init", ("Factory",), 1),
        ("starport", "Starport", "bldg_init", ("Starport",), 1),
        ("ebay", "E-Bay", "bldg_init", ("EngineeringBay",), 1),
        ("unit_reaper_1", "1st Reaper", "unit_first", ("Reaper",), 1),
        ("unit_marine_1", "1st Marine", "unit_first", ("Marine",), 1),
        ("unit_hellion_1", "1st Hellion", "unit_first", ("Hellion",), 1),
        ("unit_tank_1", "1st Tank", "unit_first", ("SiegeTank",), 1),
        ("unit_medivac_1", "1st Medivac", "unit_first", ("Medivac",), 1),
        ("unit_viking_1", "1st Viking", "unit_first", ("VikingFighter",), 1),
        ("upg_stim", "Stim (done)", "upgrade", ("Stimpack",), 1),
        ("upg_combat_shield", "Combat Shield (done)", "upgrade", ("ShieldWall",), 1),
    ],
    "Zerg": [
        ("nat", "Natural Hatch", "th_expand", ("Hatchery",), 1),
        ("pool", "Spawning Pool", "bldg_init", ("SpawningPool",), 1),
        ("third", "3rd Hatch", "th_expand", ("Hatchery",), 2),
        ("gas_1", "Gas #1", "bldg_init", ("Extractor", "ExtractorRich"), 1),
        ("gas_2", "Gas #2", "bldg_init", ("Extractor", "ExtractorRich"), 2),
        ("lair", "Lair (done)", "morph", ("Lair",), 1),
        ("rw", "Roach Warren", "bldg_init", ("RoachWarren",), 1),
        ("bane_nest", "Bane Nest", "bldg_init", ("BanelingNest",), 1),
        ("evo", "Evo Chamber", "bldg_init", ("EvolutionChamber",), 1),
        ("hydra_den", "Hydra Den", "bldg_init", ("HydraliskDen",), 1),
        ("spire", "Spire", "bldg_init", ("Spire",), 1),
        ("lurker_den", "Lurker Den", "bldg_init", ("LurkerDenMP",), 1),
        ("queen_1", "Queen #1", "unit_first", ("Queen",), 1),
        ("queen_2", "Queen #2", "unit_first", ("Queen",), 2),
        ("queen_3", "Queen #3", "unit_first", ("Queen",), 3),
        ("queen_4", "Queen #4", "unit_first", ("Queen",), 4),
        ("upg_ling_speed", "Ling Speed (done)", "upgrade", ("zerglingmovementspeed",), 1),
        ("unit_roach_1", "1st Roach", "unit_first", ("Roach",), 1),
        ("unit_hydra_1", "1st Hydra", "unit_first", ("Hydralisk",), 1),
        ("unit_lurker_1", "1st Lurker", "morph", ("LurkerMP",), 1),
        ("unit_corruptor_1", "1st Corruptor", "unit_first", ("Corruptor",), 1),
    ],
}

_RDB_MOD = None


def _get_replay_db_module(pylibs_dir: Path):
    global _RDB_MOD
    if _RDB_MOD is None:
        spec = importlib.util.spec_from_file_location("replay_db_helper", str(REPO_ROOT / "tools" / "replay-db.py"))
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod._ensure_pylibs(pylibs_dir)
        _RDB_MOD = mod
    return _RDB_MOD


def _pctiles(vals: list[float]) -> dict[str, Any]:
    if not vals:
        return {"n": 0, "p25": None, "med": None, "p75": None, "mean": None}
    s = sorted(float(v) for v in vals)
    n = len(s)

    def _q(p: float) -> float:
        if n == 1:
            return s[0]
        pos = p * (n - 1)
        lo = int(math.floor(pos))
        hi = int(math.ceil(pos))
        if lo == hi:
            return s[lo]
        return s[lo] + (pos - lo) * (s[hi] - s[lo])

    return {
        "n": n,
        "p25": round(_q(0.25), 1),
        "med": round(_q(0.50), 1),
        "p75": round(_q(0.75), 1),
        "mean": round(sum(s) / n, 1),
    }


def _avg_opt(vals: list[float | None], prec: int = 2) -> float | None:
    xs = [float(v) for v in vals if v is not None]
    return round(sum(xs) / len(xs), prec) if xs else None


def _fmt_sec(v: float | None) -> str:
    if v is None:
        return "-"
    iv = int(round(v))
    return f"{iv // 60}:{iv % 60:02d}"


def _fmt_delta_sec(v: float | None) -> str:
    if v is None:
        return "-"
    sign = "+" if v > 0 else ""
    return f"{sign}{v:.0f}s"


def _fmt_num(v: float | None, suffix: str = "", prec: int = 1) -> str:
    if v is None:
        return "-"
    return f"{v:.{prec}f}{suffix}"


def _fmt_delta(v: float | None, suffix: str = "", prec: int = 1) -> str:
    if v is None:
        return "-"
    sign = "+" if v > 0 else ""
    return f"{sign}{v:.{prec}f}{suffix}"


# ---------------------------------------------------------------------------
# Spatial Normalization, Grouping, and Walling Math
# ---------------------------------------------------------------------------

def normalize_buildings(
    bldgs: list[dict[str, Any]],
) -> tuple[float, list[dict[str, Any]]] | None:
    """
    Rotate building coordinates so Main TownHall = (0, 0) and Natural TownHall = (+nat_dist, 0).
    Each item in `bldgs` is a dict with keys: unit_type, x, y, init_sec, done_sec, unit_tag.
    Returns `(nat_dist, normalized_list)` or None if no 2nd base exists within 18..55 tiles by 270s.
    """
    ths = [b for b in bldgs if b["unit_type"] in TOWN_HALLS]
    if not ths:
        return None
    ths.sort(key=lambda b: b["init_sec"])
    mx, my = ths[0]["x"], ths[0]["y"]
    nat = None
    for b in ths[1:]:
        d = math.hypot(b["x"] - mx, b["y"] - my)
        if 18.0 <= d <= 55.0 and b["init_sec"] <= 270.0:
            nat = b
            break
    if nat is None:
        return None
    dx, dy = nat["x"] - mx, nat["y"] - my
    nat_dist = math.hypot(dx, dy)
    if nat_dist <= 0.0:
        return None
    ux, uy = dx / nat_dist, dy / nat_dist
    vx, vy = -uy, ux

    norm: list[dict[str, Any]] = []
    for b in bldgs:
        px, py = b["x"] - mx, b["y"] - my
        rx = px * ux + py * uy
        ry = px * vx + py * vy
        nb = dict(b)
        nb["rx"] = rx
        nb["ry"] = ry
        norm.append(nb)

    early_ry = [
        b["ry"] for b in norm
        if b["unit_type"] in (SUPPLY | ALL_PROD | TECH) and 0.0 < b["init_sec"] <= 120.0
    ]
    if early_ry and sum(early_ry) < 0.0:
        for b in norm:
            b["ry"] = -b["ry"]
    return nat_dist, norm


def _analyze_wall_zone(
    bldgs: list[dict[str, Any]],
    max_center_dist: float = 4.5,
) -> dict[str, Any]:
    """
    Detect tight wall pairs in a zone (center-to-center <= max_center_dist).
    Computes wall existence, tightest edge-to-edge gap width, composition, and completion time.
    """
    if len(bldgs) < 2:
        return {
            "has_wall": False,
            "bldg_cnt": len(bldgs),
            "min_gap": None,
            "avg_gap": None,
            "comp_key": None,
            "wall_types": [],
            "complete_sec": None,
            "start_sec": None,
        }
    pairs: list[tuple[float, dict[str, Any], dict[str, Any]]] = []
    wall_indices: set[int] = set()
    for i, a in enumerate(bldgs):
        sa = BLDG_SIZE.get(a["unit_type"], 3.0)
        for j in range(i + 1, len(bldgs)):
            b = bldgs[j]
            sb = BLDG_SIZE.get(b["unit_type"], 3.0)
            cdist = math.hypot(a["rx"] - b["rx"], a["ry"] - b["ry"])
            if cdist <= max_center_dist:
                gap = max(0.0, cdist - 0.5 * (sa + sb))
                pairs.append((gap, a, b))
                wall_indices.add(i)
                wall_indices.add(j)

    if not pairs:
        return {
            "has_wall": False,
            "bldg_cnt": len(bldgs),
            "min_gap": None,
            "avg_gap": None,
            "comp_key": None,
            "wall_types": [],
            "complete_sec": None,
            "start_sec": None,
        }

    wall_bldgs = [bldgs[idx] for idx in sorted(wall_indices)]
    wall_bldgs.sort(key=lambda b: b["init_sec"])
    # Composition signature: sorted short names of up to first 4 walling structures
    labels = sorted(SHORT_BLDG_LABEL.get(b["unit_type"], b["unit_type"]) for b in wall_bldgs[:4])
    comp_key = "+".join(labels)
    gaps = [p[0] for p in pairs]

    # Completion time: max(done_sec) of the first 2-3 wall buildings if all have done_sec
    core_wall = wall_bldgs[:3]
    done_secs = [b["done_sec"] for b in core_wall if b.get("done_sec") is not None]
    complete_sec = max(done_secs) if len(done_secs) == len(core_wall) else None
    start_sec = max(b["init_sec"] for b in core_wall)

    return {
        "has_wall": True,
        "bldg_cnt": len(bldgs),
        "min_gap": round(min(gaps), 2),
        "avg_gap": round(sum(gaps) / len(gaps), 2),
        "comp_key": comp_key,
        "wall_types": [SHORT_BLDG_LABEL.get(b["unit_type"], b["unit_type"]) for b in wall_bldgs],
        "complete_sec": round(complete_sec, 1) if complete_sec is not None else None,
        "start_sec": round(start_sec, 1),
    }


def compute_spatial_metrics(
    race: str,
    nat_dist: float,
    norm_bldgs: list[dict[str, Any]],
) -> dict[str, Any] | None:
    """Compute grouping, clustering, supply zones, tech safety, and walling metrics for one game."""
    b250 = [b for b in norm_bldgs if b["init_sec"] <= 250.0]
    b270 = [b for b in norm_bldgs if b["init_sec"] <= 270.0]
    non_th_gas_250 = [
        b for b in b250
        if b["unit_type"] not in TOWN_HALLS
        and b["unit_type"] not in GASES
        and b["unit_type"] not in ADDONS
    ]
    min_non_th = 1 if race == "Zerg" else 3
    if len(non_th_gas_250) < min_non_th:
        return None
    non_th_gas_270 = [
        b for b in b270
        if b["unit_type"] not in TOWN_HALLS
        and b["unit_type"] not in GASES
        and b["unit_type"] not in ADDONS
    ]

    # 1. Production grouping & addon-swap clustering (<=250s)
    prod_set = PROD_BY_RACE.get(race, ALL_PROD)
    prods = [b for b in b250 if b["unit_type"] in prod_set]
    prod_pair_dists = [
        math.hypot(a["rx"] - b["rx"], a["ry"] - b["ry"])
        for i, a in enumerate(prods)
        for b in prods[i + 1:]
    ]
    prod_nn_dists: list[float] = []
    addon_swap_close = 0
    for i, a in enumerate(prods):
        ds = [math.hypot(a["rx"] - b["rx"], a["ry"] - b["ry"]) for j, b in enumerate(prods) if i != j]
        if ds:
            md = min(ds)
            prod_nn_dists.append(md)
            if md <= 6.5:
                addon_swap_close += 1
    addon_swap_pct = (100.0 * addon_swap_close / len(prods)) if (race == "Terran" and len(prods) >= 2) else None

    # 2. Tech distance from Main vs Front choke (<=250s)
    tech_set = TECH | {"RoboticsFacility", "Stargate", "Factory", "Starport"}
    techs = [b for b in b250 if b["unit_type"] in tech_set]
    tech_dist_main = _avg_opt([math.hypot(b["rx"], b["ry"]) for b in techs], 2)
    tech_x_frac = _avg_opt([b["rx"] / nat_dist for b in techs], 3)
    tech_behind_main_pct = (
        round(100.0 * sum(1 for b in techs if b["rx"] <= 0.15 * nat_dist) / len(techs), 1)
        if techs
        else None
    )

    # 3. Supply zone breakdown (Pylon / SupplyDepot <=250s)
    sups = [b for b in b250 if b["unit_type"] in SUPPLY]
    sup_nn: list[float] = []
    sup_clumped = 0
    zone_counts = Counter()
    for i, a in enumerate(sups):
        ds = [math.hypot(a["rx"] - b["rx"], a["ry"] - b["ry"]) for j, b in enumerate(sups) if i != j]
        if ds:
            md = min(ds)
            sup_nn.append(md)
            if md < 5.0:
                sup_clumped += 1
        d_nat = math.hypot(a["rx"] - nat_dist, a["ry"])
        d_main = math.hypot(a["rx"], a["ry"])
        if d_nat <= 14.0:
            zone_counts["natural"] += 1
        elif 0.22 * nat_dist <= a["rx"] <= 0.78 * nat_dist and abs(a["ry"]) <= 12.0:
            zone_counts["main_ramp"] += 1
        elif a["rx"] < 0.22 * nat_dist and d_main <= 10.5:
            zone_counts["mineral_line"] += 1
        else:
            zone_counts["drop_vision_perimeter"] += 1

    # 4. Walling geometry (<=270s so 4:00-4:30 Natural walls are fully captured)
    main_ramp_bldgs = [
        b for b in non_th_gas_270
        if 0.22 * nat_dist <= b["rx"] <= 0.78 * nat_dist and abs(b["ry"]) <= 12.0
    ]
    nat_area_bldgs = [
        b for b in non_th_gas_270
        if math.hypot(b["rx"] - nat_dist, b["ry"]) <= 16.0
    ]
    main_wall = _analyze_wall_zone(main_ramp_bldgs, max_center_dist=4.5)
    nat_wall = _analyze_wall_zone(nat_area_bldgs, max_center_dist=4.5)

    # Fragile tech leaked into the Natural front / wall cluster
    fragile_in_wall = any(
        b["unit_type"] in FRAGILE_TECH
        and math.hypot(b["rx"] - nat_dist, b["ry"]) <= 16.0
        and (b["rx"] / nat_dist) >= 0.70
        for b in b270
    )

    return {
        "nat_dist": round(nat_dist, 2),
        "prod_cnt": len(prods),
        "prod_pair_dist": _avg_opt(prod_pair_dists, 2),
        "prod_nn_dist": _avg_opt(prod_nn_dists, 2),
        "addon_swap_pct": round(addon_swap_pct, 1) if addon_swap_pct is not None else None,
        "tech_cnt": len(techs),
        "tech_dist_main": tech_dist_main,
        "tech_x_frac": tech_x_frac,
        "tech_behind_main_pct": tech_behind_main_pct,
        "sup_cnt": len(sups),
        "sup_nn": _avg_opt(sup_nn, 2),
        "sup_clump_pct": round(100.0 * sup_clumped / len(sups), 1) if len(sups) >= 2 else None,
        "sup_zones": dict(zone_counts),
        "has_nat_supply": 100.0 if zone_counts["natural"] > 0 else 0.0,
        "main_wall": main_wall,
        "nat_wall": nat_wall,
        "fragile_tech_in_wall": 100.0 if fragile_in_wall else 0.0,
    }


def extract_timings_from_events(
    race: str,
    bldg_inits: dict[str, list[float]],
    th_expands: list[float],
    morphs: dict[str, list[float]],
    unit_arrivals: dict[str, list[float]],
    upgrades: dict[str, float],
) -> dict[str, float | None]:
    """Extract canonical timing dictionary for a single player's match."""
    specs = TIMING_SPECS.get(race, [])
    out: dict[str, float | None] = {}
    for key, _lbl, source, names, nth in specs:
        val: float | None = None
        if source == "bldg_init":
            ts = sorted(t for nm in names for t in bldg_inits.get(nm, []))
            if len(ts) >= nth:
                val = ts[nth - 1]
        elif source == "th_expand":
            if len(th_expands) >= nth:
                val = th_expands[nth - 1]
        elif source == "morph":
            ts = sorted(t for nm in names for t in morphs.get(nm, []))
            if len(ts) >= nth:
                val = ts[nth - 1]
        elif source == "unit_first":
            ts = sorted(t for nm in names for t in unit_arrivals.get(nm, []))
            if len(ts) >= nth:
                val = ts[nth - 1]
        elif source == "upgrade":
            cands = [upgrades[nm] for nm in names if nm in upgrades]
            if cands:
                val = min(cands)
        out[key] = round(val, 1) if val is not None else None
    return out


# ---------------------------------------------------------------------------
# Pro Corpus Parallel Parser (Python 3.13-safe via tools/replay-db.py)
# ---------------------------------------------------------------------------

def _parse_single_pro_replay(args_tuple: tuple[str, str, float]) -> list[dict[str, Any]]:
    rp_str, pylibs_str, min_dur_sec = args_tuple
    pylibs_dir = Path(pylibs_str)
    rdb = _get_replay_db_module(pylibs_dir)
    import mpyq  # type: ignore

    results: list[dict[str, Any]] = []
    try:
        arch = mpyq.MPQArchive(rp_str)
        hdr = rdb._load_protocol(75689, pylibs_dir).decode_replay_header(
            arch.header["user_data_header"]["content"]
        )
        dur_sec = hdr["m_elapsedGameLoops"] / GAME_LOOPS_PER_SEC
        if dur_sec < min_dur_sec:
            return results
        bb = hdr["m_version"]["m_baseBuild"]
        proto = rdb._load_protocol(bb, pylibs_dir)
        det = proto.decode_replay_details(arch.read_file("replay.details"))
        pls = det.get("m_playerList") or []
        if len(pls) != 2:
            return results
        mname = rdb._decode_str(det.get("m_title", b""))
        if any(bad.lower() in mname.lower() for bad in BAD_MAP_TOKENS):
            return results

        race_by_pid: dict[int, str] = {}
        for idx, p in enumerate(pls, 1):
            rn = rdb._norm_race(p.get("m_race"))
            if rn not in RACES:
                return results
            # Filter out AI computer opponents in pro_corpus
            if p.get("m_control") == 3:
                return results
            race_by_pid[idx] = rn

        trk_bytes = arch.read_file("replay.tracker.events")
        if not trk_bytes:
            return results

        # Per-player tracking
        bldg_by_pid_tag: dict[tuple[int, int], dict[str, Any]] = {}
        bldgs_by_pid: dict[int, list[dict[str, Any]]] = defaultdict(list)
        bldg_inits: dict[int, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
        th_inits: dict[int, list[float]] = defaultdict(list)
        morphs: dict[int, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
        unit_arrivals: dict[int, dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
        upgrades: dict[int, dict[str, float]] = defaultdict(dict)
        seen_unit_tags: set[tuple[int, int]] = set()
        tag_owner: dict[int, int] = {}

        for ev in proto.decode_replay_tracker_events(trk_bytes):
            etype = ev.get("_event", "")
            loop = int(ev.get("_gameloop", 0))
            sec = loop / GAME_LOOPS_PER_SEC

            if etype == "NNet.Replay.Tracker.SUnitInitEvent":
                pid = int(ev.get("m_controlPlayerId") or 0)
                if pid not in race_by_pid:
                    continue
                ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                tag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                tag_owner[tag] = pid
                x, y = float(ev.get("m_x", 0.0)), float(ev.get("m_y", 0.0))
                if ut in ALL_BLDGS:
                    if sec <= 275.0:
                        rec = {
                            "unit_type": ut, "x": x, "y": y,
                            "init_sec": sec, "done_sec": None, "unit_tag": tag,
                        }
                        bldgs_by_pid[pid].append(rec)
                        bldg_by_pid_tag[(pid, tag)] = rec
                    if ut in TOWN_HALLS and sec > 5.0:
                        th_inits[pid].append(sec)
                    else:
                        bldg_inits[pid][ut].append(sec)
                else:
                    if (pid, tag) not in seen_unit_tags:
                        seen_unit_tags.add((pid, tag))
                        unit_arrivals[pid][ut].append(sec)

            elif etype == "NNet.Replay.Tracker.SUnitDoneEvent":
                tag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                pid = tag_owner.get(tag)
                if pid and (pid, tag) in bldg_by_pid_tag:
                    bldg_by_pid_tag[(pid, tag)]["done_sec"] = sec

            elif etype == "NNet.Replay.Tracker.SUnitBornEvent":
                pid = int(ev.get("m_controlPlayerId") or 0)
                if pid not in race_by_pid:
                    continue
                ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                tag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                tag_owner[tag] = pid
                x, y = float(ev.get("m_x", 0.0)), float(ev.get("m_y", 0.0))
                if ut in ALL_BLDGS:
                    if sec <= 275.0:
                        rec = {
                            "unit_type": ut, "x": x, "y": y,
                            "init_sec": sec, "done_sec": sec, "unit_tag": tag,
                        }
                        bldgs_by_pid[pid].append(rec)
                        bldg_by_pid_tag[(pid, tag)] = rec
                    if ut in TOWN_HALLS and sec > 5.0:
                        th_inits[pid].append(sec)
                    elif sec > 2.0:
                        bldg_inits[pid][ut].append(sec)
                else:
                    if (pid, tag) not in seen_unit_tags:
                        seen_unit_tags.add((pid, tag))
                        unit_arrivals[pid][ut].append(sec)

            elif etype == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
                tag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                pid = tag_owner.get(tag)
                if pid in race_by_pid:
                    ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                    if ut in ("OrbitalCommand", "Lair", "Hive", "LurkerMP", "Ravager", "Baneling"):
                        morphs[pid][ut].append(sec)

            elif etype == "NNet.Replay.Tracker.SUpgradeEvent":
                pid = int(ev.get("m_playerId") or 0)
                if pid in race_by_pid:
                    uname = rdb._decode_str(ev.get("m_upgradeTypeName", b""))
                    if uname and uname not in upgrades[pid]:
                        upgrades[pid][uname] = sec

        for pid in (1, 2):
            opp_pid = 2 if pid == 1 else 1
            orace = race_by_pid[pid]
            erace = race_by_pid[opp_pid]
            mu = f"{RACE_LETTER[orace]}v{RACE_LETTER[erace]}"
            timings = extract_timings_from_events(
                orace,
                bldg_inits[pid],
                sorted(th_inits[pid]),
                morphs[pid],
                unit_arrivals[pid],
                upgrades[pid],
            )
            spatial = None
            norm = normalize_buildings(bldgs_by_pid[pid])
            if norm is not None:
                nat_dist, nb = norm
                spatial = compute_spatial_metrics(orace, nat_dist, nb)
            results.append({
                "matchup": mu,
                "race": orace,
                "duration_sec": round(dur_sec, 1),
                "timings": timings,
                "spatial": spatial,
            })
    except Exception:
        return []
    return results


def load_pro_corpus(
    pro_dir: Path,
    pylibs_dir: Path,
    min_dur_sec: float = 250.0,
    max_per_matchup: int = 80,
    jobs: int = 8,
) -> tuple[dict[str, list[dict[str, Any]]], int]:
    """Parse pro_corpus replays in parallel and cap balanced samples per matchup."""
    replays = sorted(pro_dir.glob("*.SC2Replay"))
    if not replays:
        return {mu: [] for mu in MATCHUPS}, 0

    by_mu: dict[str, list[dict[str, Any]]] = {mu: [] for mu in MATCHUPS}
    scanned = 0
    work = [(str(rp), str(pylibs_dir), min_dur_sec) for rp in replays]

    with concurrent.futures.ProcessPoolExecutor(max_workers=max(1, jobs)) as ex:
        for batch in ex.map(_parse_single_pro_replay, work, chunksize=8):
            scanned += 1
            for rec in batch:
                mu = rec["matchup"]
                if mu in by_mu and len(by_mu[mu]) < max_per_matchup:
                    by_mu[mu].append(rec)
            if all(len(by_mu[mu]) >= max_per_matchup for mu in MATCHUPS):
                break
    return by_mu, scanned


# ---------------------------------------------------------------------------
# Mothman Read-Only SQLite Loader (iter45..iter48)
# ---------------------------------------------------------------------------

def load_mothman_sqlite(
    db_path: Path,
    run_prefixes: tuple[str, ...],
    min_dur_sec: float = 250.0,
) -> tuple[dict[str, list[dict[str, Any]]], int]:
    """Load Mothman spatial + timing records from read-only `arena_replays.sqlite`."""
    p = os.path.abspath(os.path.expanduser(str(db_path)))
    conn = sqlite3.connect(Path(p).as_uri() + "?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        like_clauses = " OR ".join("m.run_id LIKE ?" for _ in run_prefixes)
        like_params = [f"%{pref}%" for pref in run_prefixes]
        mrows = conn.execute(
            f"""
            SELECT m.replay_id, m.actual_race, m.our_race, m.opp_race, m.matchup,
                   m.our_player_id, m.our_start_x, m.our_start_y, m.duration_sec
            FROM matches m
            WHERE ({like_clauses})
              AND COALESCE(m.is_selfplay, 0) = 0
              AND COALESCE(m.duration_sec, 0) >= ?
              AND m.our_start_x IS NOT NULL AND m.our_start_y IS NOT NULL
              AND m.raw_extracted_at IS NOT NULL
            ORDER BY m.replay_mtime DESC
            """,
            like_params + [min_dur_sec],
        ).fetchall()

        if not mrows:
            return {mu: [] for mu in MATCHUPS}, 0

        rids = [r["replay_id"] for r in mrows]
        events_by_rep: dict[tuple[str, int], list[sqlite3.Row]] = defaultdict(list)
        for i in range(0, len(rids), 400):
            chunk = rids[i:i + 400]
            ph = ",".join("?" for _ in chunk)
            for ev in conn.execute(
                f"""
                SELECT replay_id, player_id, sec, event_type, unit_type, x, y, unit_tag
                FROM match_build_events
                WHERE replay_id IN ({ph})
                  AND event_type IN ('born', 'init', 'done', 'morph', 'upgrade')
                ORDER BY replay_id, sec
                """,
                chunk,
            ).fetchall():
                events_by_rep[(ev["replay_id"], ev["player_id"])].append(ev)

        by_mu: dict[str, list[dict[str, Any]]] = {mu: [] for mu in MATCHUPS}
        for m in mrows:
            orace = m["actual_race"] if m["actual_race"] in RACES else m["our_race"]
            erace = m["opp_race"]
            if orace not in RACES or erace not in RACES:
                continue
            mu = f"{RACE_LETTER[orace]}v{RACE_LETTER[erace]}"
            evs = events_by_rep.get((m["replay_id"], m["our_player_id"]), [])

            bldgs: list[dict[str, Any]] = [{
                "unit_type": TH_FOR_RACE[orace],
                "x": float(m["our_start_x"]),
                "y": float(m["our_start_y"]),
                "init_sec": 0.0,
                "done_sec": 0.0,
                "unit_tag": -1,
            }]
            bldg_by_tag: dict[int, dict[str, Any]] = {}
            bldg_inits: dict[str, list[float]] = defaultdict(list)
            th_inits: list[float] = []
            morphs: dict[str, list[float]] = defaultdict(list)
            unit_arrivals: dict[str, list[float]] = defaultdict(list)
            upgrades: dict[str, float] = {}
            seen_unit_tags: set[int] = set()

            for ev in evs:
                et = ev["event_type"]
                ut = ev["unit_type"]
                sec = float(ev["sec"] or 0.0)
                tag = ev["unit_tag"]

                if et == "init":
                    if ut in ALL_BLDGS:
                        if sec <= 275.0 and ev["x"] is not None and ev["y"] is not None:
                            rec = {
                                "unit_type": ut, "x": float(ev["x"]), "y": float(ev["y"]),
                                "init_sec": sec, "done_sec": None, "unit_tag": tag,
                            }
                            bldgs.append(rec)
                            if tag is not None:
                                bldg_by_tag[tag] = rec
                        if ut in TOWN_HALLS and sec > 5.0:
                            th_inits.append(sec)
                        else:
                            bldg_inits[ut].append(sec)
                    else:
                        if tag is None or tag not in seen_unit_tags:
                            if tag is not None:
                                seen_unit_tags.add(tag)
                            unit_arrivals[ut].append(sec)

                elif et == "done":
                    if tag is not None and tag in bldg_by_tag:
                        bldg_by_tag[tag]["done_sec"] = sec

                elif et == "born":
                    if ut in ALL_BLDGS:
                        if sec <= 275.0 and ev["x"] is not None and ev["y"] is not None:
                            rec = {
                                "unit_type": ut, "x": float(ev["x"]), "y": float(ev["y"]),
                                "init_sec": sec, "done_sec": sec, "unit_tag": tag,
                            }
                            bldgs.append(rec)
                            if tag is not None:
                                bldg_by_tag[tag] = rec
                        if ut in TOWN_HALLS and sec > 5.0:
                            th_inits.append(sec)
                        elif sec > 2.0:
                            bldg_inits[ut].append(sec)
                    else:
                        if tag is None or tag not in seen_unit_tags:
                            if tag is not None:
                                seen_unit_tags.add(tag)
                            unit_arrivals[ut].append(sec)

                elif et == "morph":
                    morphs[ut].append(sec)

                elif et == "upgrade":
                    if ut not in upgrades:
                        upgrades[ut] = sec

            timings = extract_timings_from_events(
                orace, bldg_inits, sorted(th_inits), morphs, unit_arrivals, upgrades
            )
            spatial = None
            norm = normalize_buildings(bldgs)
            if norm is not None:
                nat_dist, nb = norm
                spatial = compute_spatial_metrics(orace, nat_dist, nb)
            by_mu[mu].append({
                "matchup": mu,
                "race": orace,
                "duration_sec": round(float(m["duration_sec"] or 0.0), 1),
                "timings": timings,
                "spatial": spatial,
            })
        return by_mu, len(mrows)
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Aggregation & Report Rendering
# ---------------------------------------------------------------------------

def aggregate_side(race: str, records: list[dict[str, Any]]) -> dict[str, Any]:
    """Aggregate spatial and timing distributions for one side (Pro or Mothman)."""
    n_total = len(records)
    sp_list = [r["spatial"] for r in records if r.get("spatial") is not None]
    n_sp = len(sp_list)

    # Supply zone shares across all supply structures
    zone_totals = Counter()
    for s in sp_list:
        for z, cnt in (s.get("sup_zones") or {}).items():
            zone_totals[z] += cnt
    tot_sups = sum(zone_totals.values())
    sup_zone_pct = {
        z: round(100.0 * zone_totals[z] / tot_sups, 1) if tot_sups > 0 else None
        for z in ("mineral_line", "main_ramp", "drop_vision_perimeter", "natural")
    }

    def _agg_wall(key: str) -> dict[str, Any]:
        if not sp_list:
            return {"wall_pct": None, "n_wall": 0, "gap_med": None, "complete_sec": _pctiles([]), "top_compositions": []}
        ws = [s[key] for s in sp_list]
        hit = [w for w in ws if w["has_wall"]]
        comp_cnt = Counter(w["comp_key"] for w in hit if w.get("comp_key"))
        gaps = [w["min_gap"] for w in hit if w.get("min_gap") is not None]
        comp_secs = [w["complete_sec"] for w in hit if w.get("complete_sec") is not None]
        return {
            "wall_pct": round(100.0 * len(hit) / len(ws), 1),
            "n_wall": len(hit),
            "gap_med": round(statistics.median(gaps), 2) if gaps else None,
            "gap_mean": _avg_opt(gaps, 2),
            "complete_sec": _pctiles(comp_secs),
            "top_compositions": comp_cnt.most_common(3),
        }

    spatial_summary = {
        "n": n_sp,
        "prod_pair_dist": _avg_opt([s["prod_pair_dist"] for s in sp_list], 2),
        "prod_nn_dist": _avg_opt([s["prod_nn_dist"] for s in sp_list], 2),
        "addon_swap_pct": _avg_opt([s["addon_swap_pct"] for s in sp_list], 1),
        "tech_dist_main": _avg_opt([s["tech_dist_main"] for s in sp_list], 2),
        "tech_x_frac": _avg_opt([s["tech_x_frac"] for s in sp_list], 3),
        "tech_behind_main_pct": _avg_opt([s["tech_behind_main_pct"] for s in sp_list], 1),
        "sup_nn": _avg_opt([s["sup_nn"] for s in sp_list], 2),
        "sup_clump_pct": _avg_opt([s["sup_clump_pct"] for s in sp_list], 1),
        "nat_supply_pct": _avg_opt([s["has_nat_supply"] for s in sp_list], 1),
        "sup_zone_pct": sup_zone_pct,
        "main_wall": _agg_wall("main_wall"),
        "nat_wall": _agg_wall("nat_wall"),
        "fragile_tech_in_wall_pct": _avg_opt([s["fragile_tech_in_wall"] for s in sp_list], 1),
    }

    timings_summary: dict[str, dict[str, Any]] = {}
    for key, label, _src, _names, _nth in TIMING_SPECS.get(race, []):
        vals = [r["timings"][key] for r in records if r["timings"].get(key) is not None]
        pct = _pctiles(vals)
        pct["label"] = label
        pct["adopt_pct"] = round(100.0 * len(vals) / n_total, 1) if n_total > 0 else 0.0
        timings_summary[key] = pct

    return {
        "n_games": n_total,
        "spatial": spatial_summary,
        "timings": timings_summary,
    }


def _diff_opt(a: float | None, b: float | None, prec: int = 1) -> float | None:
    if a is None or b is None:
        return None
    return round(a - b, prec)


def build_comparison_report(
    pro_by_mu: dict[str, list[dict[str, Any]]],
    mm_by_mu: dict[str, list[dict[str, Any]]],
    meta: dict[str, Any],
) -> dict[str, Any]:
    by_matchup: dict[str, Any] = {}
    for mu in MATCHUPS:
        race = {"P": "Protoss", "T": "Terran", "Z": "Zerg"}[mu[0]]
        p_agg = aggregate_side(race, pro_by_mu.get(mu, []))
        m_agg = aggregate_side(race, mm_by_mu.get(mu, []))

        timing_deltas: dict[str, Any] = {}
        for key, label, _src, _names, _nth in TIMING_SPECS[race]:
            pt = p_agg["timings"][key]
            mt = m_agg["timings"][key]
            d_med = _diff_opt(mt["med"], pt["med"], 1)
            timing_deltas[key] = {
                "label": label,
                "pro": pt,
                "mothman": mt,
                "delta_med_sec": d_med,
                "delta_adopt_pct": _diff_opt(mt["adopt_pct"], pt["adopt_pct"], 1),
            }

        ps, ms = p_agg["spatial"], m_agg["spatial"]
        spatial_deltas = {
            "prod_pair_dist": _diff_opt(ms["prod_pair_dist"], ps["prod_pair_dist"], 2),
            "prod_nn_dist": _diff_opt(ms["prod_nn_dist"], ps["prod_nn_dist"], 2),
            "addon_swap_pct": _diff_opt(ms["addon_swap_pct"], ps["addon_swap_pct"], 1),
            "tech_dist_main": _diff_opt(ms["tech_dist_main"], ps["tech_dist_main"], 2),
            "tech_x_frac": _diff_opt(ms["tech_x_frac"], ps["tech_x_frac"], 3),
            "sup_nn": _diff_opt(ms["sup_nn"], ps["sup_nn"], 2),
            "sup_clump_pct": _diff_opt(ms["sup_clump_pct"], ps["sup_clump_pct"], 1),
            "nat_supply_pct": _diff_opt(ms["nat_supply_pct"], ps["nat_supply_pct"], 1),
            "main_wall_pct": _diff_opt(ms["main_wall"]["wall_pct"], ps["main_wall"]["wall_pct"], 1),
            "nat_wall_pct": _diff_opt(ms["nat_wall"]["wall_pct"], ps["nat_wall"]["wall_pct"], 1),
            "fragile_tech_in_wall_pct": _diff_opt(ms["fragile_tech_in_wall_pct"], ps["fragile_tech_in_wall_pct"], 1),
        }

        by_matchup[mu] = {
            "race": race,
            "pro": p_agg,
            "mothman": m_agg,
            "spatial_deltas": spatial_deltas,
            "timing_comparison": timing_deltas,
        }

    # Also build per-race rollups
    by_race: dict[str, Any] = {}
    for race in RACES:
        mus = [mu for mu in MATCHUPS if mu[0] == RACE_LETTER[race]]
        p_all = [r for mu in mus for r in pro_by_mu.get(mu, [])]
        m_all = [r for mu in mus for r in mm_by_mu.get(mu, [])]
        by_race[race] = {
            "pro": aggregate_side(race, p_all),
            "mothman": aggregate_side(race, m_all),
        }

    return {
        "meta": meta,
        "by_race": by_race,
        "by_matchup": by_matchup,
    }


def render_markdown(report: dict[str, Any]) -> str:
    meta = report["meta"]
    by_mu = report["by_matchup"]
    lines: list[str] = []

    lines.append("# Pro vs. Mothman Spatial & Timing Comparison")
    lines.append("")
    lines.append(
        f"Compares **{meta['pro_games_total']}** standard 1v1 pro games (`replays/pro_corpus`, "
        f"scanned {meta['pro_replays_scanned']} replays) against **{meta['mothman_games_total']}** "
        f"Mothman external games (`{', '.join(meta['run_prefixes'])}`, duration >= {int(meta['min_dur_sec'])}s)."
    )
    lines.append("")

    # Section 1: Spatial Grouping & Supply Zones
    lines.append("## 1. Building Grouping, Tech Safety & Supply Zones (4:10)")
    lines.append("")
    lines.append(
        "| Matchup (Pro/Us) | Prod NN (Pro/Us) | Prod Pair (Pro/Us) | Addon Cluster (Pro/Us) | "
        "Tech x-frac (Pro/Us) | Sup Clump <5t (Pro/Us) | Sup Zones Us (Min / Ramp / Edge / Nat) | Sup Zones Pro (Min / Ramp / Edge / Nat) |"
    )
    lines.append("|---|---:|---:|---:|---:|---:|---|---|")
    for mu in MATCHUPS:
        d = by_mu[mu]
        ps, ms = d["pro"]["spatial"], d["mothman"]["spatial"]
        addon_s = (
            f"{_fmt_num(ps['addon_swap_pct'],'%')} / {_fmt_num(ms['addon_swap_pct'],'%')}"
            if mu[0] == "T"
            else "-"
        )
        clump_s = (
            f"{_fmt_num(ps['sup_clump_pct'],'%')} / {_fmt_num(ms['sup_clump_pct'],'%')}"
            if mu[0] in ("P", "T")
            else "-"
        )
        def _zstr(zmap: dict[str, Any]) -> str:
            if mu[0] == "Z":
                return "-"
            return (
                f"{_fmt_num(zmap.get('mineral_line'),'%',0)} / "
                f"{_fmt_num(zmap.get('main_ramp'),'%',0)} / "
                f"{_fmt_num(zmap.get('drop_vision_perimeter'),'%',0)} / "
                f"{_fmt_num(zmap.get('natural'),'%',0)}"
            )
        lines.append(
            f"| **{mu}** ({ps['n']}/{ms['n']}) "
            f"| {_fmt_num(ps['prod_nn_dist'],'t')} / {_fmt_num(ms['prod_nn_dist'],'t')} "
            f"| {_fmt_num(ps['prod_pair_dist'],'t')} / {_fmt_num(ms['prod_pair_dist'],'t')} "
            f"| {addon_s} "
            f"| {_fmt_num(ps['tech_x_frac'],'',2)} / {_fmt_num(ms['tech_x_frac'],'',2)} "
            f"| {clump_s} "
            f"| {_zstr(ms['sup_zone_pct'])} | {_zstr(ps['sup_zone_pct'])} |"
        )
    lines.append("")

    # Section 2: Walling Geometry
    lines.append("## 2. Walling Geometry (Main Ramp & Natural Choke, <=4:30)")
    lines.append("")
    lines.append(
        "| Matchup | Main Wall % (Pro/Us) | Main Gap / Done (Pro vs Us) | Nat Wall % (Pro/Us) | "
        "Nat Gap / Done (Pro vs Us) | Top Nat Wall Comp (Pro vs Us) | Fragile Tech in Wall (Pro/Us) |"
    )
    lines.append("|---|---:|---|---:|---|---|---:|")
    for mu in MATCHUPS:
        d = by_mu[mu]
        ps, ms = d["pro"]["spatial"], d["mothman"]["spatial"]
        pmw, mmw = ps["main_wall"], ms["main_wall"]
        pnw, mnw = ps["nat_wall"], ms["nat_wall"]
        p_mstr = f"{_fmt_num(pmw['gap_med'],'t',2)} @ {_fmt_sec(pmw['complete_sec']['med'])}"
        m_mstr = f"{_fmt_num(mmw['gap_med'],'t',2)} @ {_fmt_sec(mmw['complete_sec']['med'])}"
        p_nstr = f"{_fmt_num(pnw['gap_med'],'t',2)} @ {_fmt_sec(pnw['complete_sec']['med'])}"
        m_nstr = f"{_fmt_num(mnw['gap_med'],'t',2)} @ {_fmt_sec(mnw['complete_sec']['med'])}"
        p_comp = pnw["top_compositions"][0][0] if pnw["top_compositions"] else "-"
        m_comp = mnw["top_compositions"][0][0] if mnw["top_compositions"] else "-"
        lines.append(
            f"| **{mu}** "
            f"| {_fmt_num(pmw['wall_pct'],'%')} / {_fmt_num(mmw['wall_pct'],'%')} "
            f"| {p_mstr} vs {m_mstr} "
            f"| {_fmt_num(pnw['wall_pct'],'%')} / {_fmt_num(mnw['wall_pct'],'%')} "
            f"| {p_nstr} vs {m_nstr} "
            f"| `{p_comp}` vs `{m_comp}` "
            f"| {_fmt_num(ps['fragile_tech_in_wall_pct'],'%')} / {_fmt_num(ms['fragile_tech_in_wall_pct'],'%')} |"
        )
    lines.append("")

    # Section 3: Biggest Gaps per Matchup
    lines.append("## 3. Largest Spatial & Timing Gaps by Matchup")
    lines.append("")
    for mu in MATCHUPS:
        d = by_mu[mu]
        sd = d["spatial_deltas"]
        bullets: list[str] = []
        if mu[0] == "P" and sd["sup_clump_pct"] is not None and sd["sup_clump_pct"] >= 20.0:
            bullets.append(
                f"Pylon clumping {d['mothman']['spatial']['sup_clump_pct']:.0f}% vs Pro {d['pro']['spatial']['sup_clump_pct']:.0f}%"
            )
        if mu[0] in ("P", "T") and sd["nat_supply_pct"] is not None and sd["nat_supply_pct"] <= -15.0:
            bullets.append(
                f"Natural supply {d['mothman']['spatial']['nat_supply_pct']:.0f}% vs Pro {d['pro']['spatial']['nat_supply_pct']:.0f}%"
            )
        if mu[0] == "T" and sd["addon_swap_pct"] is not None and sd["addon_swap_pct"] <= -10.0:
            bullets.append(
                f"Tight production cluster {d['mothman']['spatial']['addon_swap_pct']:.0f}% vs Pro {d['pro']['spatial']['addon_swap_pct']:.0f}%"
            )
        if sd["nat_wall_pct"] is not None and sd["nat_wall_pct"] <= -15.0:
            bullets.append(
                f"Natural wall {d['mothman']['spatial']['nat_wall']['wall_pct']:.0f}% vs Pro {d['pro']['spatial']['nat_wall']['wall_pct']:.0f}%"
            )
        if sd["fragile_tech_in_wall_pct"] is not None and sd["fragile_tech_in_wall_pct"] >= 10.0:
            bullets.append(
                f"Fragile tech exposed in wall {d['mothman']['spatial']['fragile_tech_in_wall_pct']:.0f}% vs Pro {d['pro']['spatial']['fragile_tech_in_wall_pct']:.0f}%"
            )
        # Top 3 timing gaps (where both Pro and Mothman build it in >=20% of games)
        tc_rows = []
        for _k, td in d["timing_comparison"].items():
            if td["delta_med_sec"] is not None and td["pro"]["adopt_pct"] >= 20.0 and td["mothman"]["adopt_pct"] >= 15.0:
                tc_rows.append((abs(td["delta_med_sec"]), td))
        tc_rows.sort(key=lambda x: x[0], reverse=True)
        for _absd, td in tc_rows[:3]:
            if abs(td["delta_med_sec"]) >= 12.0:
                bullets.append(
                    f"{td['label']} {_fmt_sec(td['mothman']['med'])} vs Pro {_fmt_sec(td['pro']['med'])} ({_fmt_delta_sec(td['delta_med_sec'])})"
                )
        # Flag high-adoption Pro units/buildings Mothman rarely builds (<15% vs Pro >=50%)
        missing = [
            f"{td['label']} (built {td['mothman']['adopt_pct']:.0f}% vs Pro {td['pro']['adopt_pct']:.0f}%)"
            for td in d["timing_comparison"].values()
            if td["pro"]["adopt_pct"] >= 50.0 and td["mothman"]["adopt_pct"] < 15.0
        ]
        if missing:
            bullets.append("Rarely built: " + ", ".join(missing[:2]))
        lines.append(f"- **{mu}:** " + ("; ".join(bullets) if bullets else "Within pro range on major markers."))
    lines.append("")

    # Section 4: Per-Matchup Exact Timings (p25 / med / p75)
    lines.append("## 4. Exact Building, Unit & Upgrade Timings (p25 / med / p75)")
    lines.append("")
    for mu in MATCHUPS:
        d = by_mu[mu]
        lines.append(
            f"### {mu} (`Pro n={d['pro']['n_games']}`, `Mothman n={d['mothman']['n_games']}`)"
        )
        lines.append("| Milestone | Pro p25 / med / p75 (adopt%) | Mothman p25 / med / p75 (adopt%) | Delta (med) |")
        lines.append("|---|---:|---:|---:|")
        for key, label, _src, _names, _nth in TIMING_SPECS[d["race"]]:
            td = d["timing_comparison"][key]
            p, m = td["pro"], td["mothman"]
            p_s = f"{_fmt_sec(p['p25'])} / **{_fmt_sec(p['med'])}** / {_fmt_sec(p['p75'])} ({p['adopt_pct']:.0f}%)" if p["n"] else "- (0%)"
            m_s = f"{_fmt_sec(m['p25'])} / **{_fmt_sec(m['med'])}** / {_fmt_sec(m['p75'])} ({m['adopt_pct']:.0f}%)" if m["n"] else "- (0%)"
            lines.append(f"| {label} | {p_s} | {m_s} | {_fmt_delta_sec(td['delta_med_sec'])} |")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description="Deep Pro vs. Mothman spatial and timing comparison across all 9 matchups.")
    ap.add_argument("--pro-dir", default=str(DEFAULT_PRO_DIR), help="Directory containing pro_corpus .SC2Replay files")
    ap.add_argument("--replay-db", default=str(DEFAULT_DB_PATH), help="Read-only arena_replays.sqlite path")
    ap.add_argument("--pylibs-dir", default=str(DEFAULT_PYLIBS_DIR), help="Directory containing mpyq and s2protocol")
    ap.add_argument(
        "--run-prefixes",
        default=",".join(DEFAULT_RUN_PREFIXES),
        help="Comma-separated run_id substrings for Mothman games (default: iter45,iter46,iter47,iter48)",
    )
    ap.add_argument("--min-dur-sec", type=float, default=250.0, help="Minimum game duration in seconds (default: 250)")
    ap.add_argument("--max-per-matchup", type=int, default=80, help="Max pro games per matchup (default: 80)")
    ap.add_argument("--jobs", type=int, default=8, help="Parallel worker processes for pro replay decoding")
    ap.add_argument("--out-json", required=True, help="Output structured JSON path")
    ap.add_argument("--out-md", required=True, help="Output Markdown summary path")
    args = ap.parse_args()

    t0 = time.time()
    run_prefixes = tuple(s.strip() for s in args.run_prefixes.split(",") if s.strip())
    pro_by_mu, pro_scanned = load_pro_corpus(
        Path(args.pro_dir),
        Path(args.pylibs_dir),
        min_dur_sec=args.min_dur_sec,
        max_per_matchup=args.max_per_matchup,
        jobs=args.jobs,
    )
    mm_by_mu, mm_total = load_mothman_sqlite(
        Path(args.replay_db),
        run_prefixes=run_prefixes,
        min_dur_sec=args.min_dur_sec,
    )
    meta = {
        "pro_replays_scanned": pro_scanned,
        "pro_games_total": sum(len(v) for v in pro_by_mu.values()),
        "mothman_games_total": sum(len(v) for v in mm_by_mu.values()),
        "mothman_rows_matched": mm_total,
        "run_prefixes": list(run_prefixes),
        "min_dur_sec": args.min_dur_sec,
        "max_per_matchup": args.max_per_matchup,
        "elapsed_sec": round(time.time() - t0, 2),
    }
    report = build_comparison_report(pro_by_mu, mm_by_mu, meta)
    md = render_markdown(report)

    out_json = Path(args.out_json)
    out_md = Path(args.out_md)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    out_md.write_text(md, encoding="utf-8")

    print(
        f"PRO_DEEP_COMPARISON_OK: pro={meta['pro_games_total']} (scanned={pro_scanned}), "
        f"mothman={meta['mothman_games_total']} ({','.join(run_prefixes)}), "
        f"elapsed={meta['elapsed_sec']}s -> {out_json.name}, {out_md.name}"
    )


if __name__ == "__main__":
    main()
