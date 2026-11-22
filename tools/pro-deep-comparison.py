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
  4. Combat concave, unit layout & positioning across all battles (LotV tracker
     SUnitPositionsEvent + SUnitDiedEvent): frontage width, depth, width-to-depth ratio,
     concave wrap score, front-to-back role layering & inversion, caster exposure,
     engagement firing utilization (in_range_pct), anti-splash spread (NN & 2t density),
     and choke/uphill fight rates by race and across all 9 matchups.
  5. Macro army-group positioning, rotation, regroup, multiprong & drop/runby taxonomy
     (LotV tracker SUnitPositionsEvent + SUnitDiedEvent killer tags + SUnitInitEvent
     offensive warp-ins/Nydus): multiprong attack rate, synchronized harass rate,
     reinforcement staging/link-up vs solo trickle deaths, disengage & regroup vs
     fight-to-annihilation, base-switch target rotations, and per-subtype Pro vs. Mothman
     drop/warp-in/Nydus/runby frequencies and worker damage per 10 minutes.
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

# ---------------------------------------------------------------------------
# Combat Concave, Unit Layout & Positioning Classification Tables (LotV 5.0.14)
# ---------------------------------------------------------------------------

COMBAT_MIN_BASE_BUILD = 38215  # LotV replays with SUnitPositionsEvent

COMBAT_FRONTLINE = frozenset({
    "Zealot", "Archon", "DarkTemplar",
    "Hellion", "HellionTank", "Marauder", "Thor", "ThorAP",
    "Zergling", "Baneling", "BanelingBurrowed", "Roach", "RoachBurrowed", "Ultralisk", "Queen",
})
COMBAT_MIDLINE = frozenset({
    "Stalker", "Adept", "Immortal", "Phoenix", "VoidRay", "Oracle",
    "Marine", "Reaper", "Cyclone", "VikingFighter", "VikingAssault", "Banshee", "Battlecruiser",
    "WidowMine", "WidowMineBurrowed",
    "Ravager", "Hydralisk", "HydraliskBurrowed", "Mutalisk", "Corruptor", "SwarmHostMP",
})
COMBAT_REAR_SIEGE = frozenset({
    "Colossus", "Disruptor", "HighTemplar", "Sentry", "Tempest", "Carrier", "Mothership",
    "WarpPrism", "WarpPrismPhasing", "Observer", "ObserverSiegeMode",
    "SiegeTank", "SiegeTankSieged", "Liberator", "LiberatorAG", "Ghost", "Raven", "Medivac",
    "LurkerMP", "LurkerMPBurrowed", "Infestor", "InfestorBurrowed", "Viper", "BroodLord",
    "Overseer", "OverseerSiegeMode",
})
COMBAT_CASTERS = frozenset({
    "HighTemplar", "Sentry", "Disruptor",
    "Ghost", "Raven", "Medivac",
    "Infestor", "InfestorBurrowed", "Viper",
})
COMBAT_UNITS = COMBAT_FRONTLINE | COMBAT_MIDLINE | COMBAT_REAR_SIEGE
COMBAT_FLYERS = frozenset({
    "Phoenix", "VoidRay", "Oracle", "Tempest", "Carrier", "Mothership",
    "WarpPrism", "WarpPrismPhasing", "Observer", "ObserverSiegeMode",
    "VikingFighter", "Medivac", "Liberator", "LiberatorAG", "Raven", "Banshee", "Battlecruiser",
    "Mutalisk", "Corruptor", "BroodLord", "Viper", "Overseer", "OverseerSiegeMode",
})
COMBAT_LONG_RANGE_ENGAGE = frozenset({
    "SiegeTankSieged", "SiegeTank", "Tempest", "Colossus", "BroodLord", "LiberatorAG",
    "LurkerMPBurrowed", "Carrier", "Thor", "ThorAP", "VikingFighter", "Medivac", "Raven",
    "HighTemplar", "Infestor", "Viper", "Disruptor", "Ghost", "Sentry", "Overseer", "Observer",
})
COMBAT_STATIONARY_OK = frozenset({
    "SiegeTankSieged", "LurkerMPBurrowed", "WidowMineBurrowed", "LiberatorAG",
    "ObserverSiegeMode", "OverseerSiegeMode", "WarpPrismPhasing",
})
COMBAT_SPLASH_UNITS = frozenset({
    "SiegeTank", "SiegeTankSieged", "Baneling", "BanelingBurrowed", "Colossus",
    "HighTemplar", "Disruptor", "LurkerMP", "LurkerMPBurrowed",
    "WidowMine", "WidowMineBurrowed", "Archon", "Ultralisk",
    "Hellion", "HellionTank", "LiberatorAG", "Thor", "Ravager",
})
# Weapon ranges in tiles: (ground_range, air_range); None if unit cannot shoot that domain
COMBAT_UNIT_RANGE: dict[str, tuple[float | None, float | None]] = {
    "Zealot": (0.1, None), "DarkTemplar": (0.1, None), "Archon": (3.0, 3.0),
    "Stalker": (6.0, 6.0), "Adept": (4.0, None), "Sentry": (5.0, 5.0),
    "HighTemplar": (6.0, None), "Immortal": (6.0, None), "Colossus": (8.0, None),
    "Disruptor": (None, None), "Phoenix": (None, 5.0), "VoidRay": (6.0, 6.0),
    "Oracle": (4.0, None), "Tempest": (14.0, 14.0), "Carrier": (8.0, 8.0), "Mothership": (7.0, 7.0),
    "Marine": (5.0, 5.0), "Marauder": (6.0, None), "Reaper": (5.0, None), "Ghost": (6.0, 6.0),
    "Hellion": (5.0, None), "HellionTank": (2.0, None),
    "WidowMine": (None, None), "WidowMineBurrowed": (5.0, 5.0), "Cyclone": (6.0, 6.0),
    "SiegeTank": (7.0, None), "SiegeTankSieged": (13.0, None),
    "Thor": (7.0, 10.0), "ThorAP": (7.0, 11.0),
    "VikingFighter": (None, 9.0), "VikingAssault": (6.0, None),
    "Liberator": (None, 5.0), "LiberatorAG": (10.0, None),
    "Banshee": (6.0, None), "Battlecruiser": (6.0, 6.0),
    "Zergling": (0.1, None), "Baneling": (0.25, None), "BanelingBurrowed": (None, None),
    "Queen": (5.0, 7.0), "Roach": (4.0, None), "RoachBurrowed": (None, None),
    "Ravager": (6.0, None), "Hydralisk": (6.0, 6.0), "HydraliskBurrowed": (None, None),
    "LurkerMP": (None, None), "LurkerMPBurrowed": (9.0, None), "Ultralisk": (1.0, None),
    "Mutalisk": (3.0, 3.0), "Corruptor": (None, 6.0), "BroodLord": (10.0, None),
    "Medivac": (None, None), "Raven": (None, None), "Observer": (None, None),
    "ObserverSiegeMode": (None, None), "WarpPrism": (None, None), "WarpPrismPhasing": (None, None),
    "Overseer": (None, None), "OverseerSiegeMode": (None, None),
    "Infestor": (None, None), "InfestorBurrowed": (None, None),
    "Viper": (None, None), "SwarmHostMP": (None, None),
}


def _combat_role_of(unit_type: str) -> int | None:
    if unit_type in COMBAT_FRONTLINE:
        return 0
    if unit_type in COMBAT_MIDLINE:
        return 1
    if unit_type in COMBAT_REAR_SIEGE:
        return 2
    return None


def _quantile(vals: list[float], p: float) -> float:
    s = sorted(vals)
    pos = p * (len(s) - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return s[lo]
    return s[lo] + (pos - lo) * (s[hi] - s[lo])


def compute_combat_battles_from_tracker_state(
    deaths: list[tuple[int, int, str, float, float]],
    snaps: list[tuple[int, dict[int, list[tuple[str, float, float]]]]],
    th_pos: dict[int, list[tuple[float, float, float]]],
    all_bldgs_pts: list[tuple[float, float, float]],
    target_pids: tuple[int, ...] = (1, 2),
    replay_name: str = "",
) -> dict[int, list[dict[str, Any]]]:
    """
    Compute per-battle concave geometry, role layering, firing utilization, anti-splash
    spread, and choke/uphill fight metrics from collected tracker deaths & SUnitPositionsEvent
    snapshots. Identical extractor for both Pro GM replays and Mothman replays.
    """
    out: dict[int, list[dict[str, Any]]] = {pid: [] for pid in target_pids}
    if not deaths or not snaps:
        return out

    # Precompute Main -> Natural axis per player for objective ramp/uphill detection
    base_axes: dict[int, tuple[float, float, float, float, float, float, float]] = {}
    for pid in (1, 2):
        ths = sorted(th_pos.get(pid, []))
        if ths:
            mx, my = ths[0][1], ths[0][2]
            for sec_t, nx, ny in ths[1:]:
                d = math.hypot(nx - mx, ny - my)
                if 18.0 <= d <= 55.0 and sec_t <= 360.0:
                    dx, dy = nx - mx, ny - my
                    base_axes[pid] = (mx, my, dx / d, dy / d, -dy / d, dx / d, d)
                    break

    # Identify active combat snapshots (at least 2 clustered combat deaths within +-140 loops)
    d_idx = 0
    n_d = len(deaths)
    active_snaps: list[tuple[int, float, float, int, dict[int, list[tuple[str, float, float]]]]] = []
    for s_gl, u_by_p in snaps:
        while d_idx < n_d and deaths[d_idx][0] < s_gl - 140:
            d_idx += 1
        win_d: list[tuple[int, int, str, float, float]] = []
        j = d_idx
        while j < n_d and deaths[j][0] <= s_gl + 140:
            win_d.append(deaths[j])
            j += 1
        if len(win_d) < 2:
            continue
        clusters: list[list[tuple[int, int, str, float, float]]] = []
        for d in win_d:
            placed = False
            for cl in clusters:
                cx0 = sum(z[3] for z in cl) / len(cl)
                cy0 = sum(z[4] for z in cl) / len(cl)
                if math.hypot(d[3] - cx0, d[4] - cy0) <= 20.0:
                    cl.append(d)
                    placed = True
                    break
            if not placed:
                clusters.append([d])
        best_cl = max(clusters, key=len)
        if len(best_cl) < 2:
            continue
        fcx = sum(z[3] for z in best_cl) / len(best_cl)
        fcy = sum(z[4] for z in best_cl) / len(best_cl)
        active_snaps.append((s_gl, fcx, fcy, len(best_cl), u_by_p))

    if not active_snaps:
        return out

    # Group contiguous combat snapshots (<= 320 loops apart & <= 22t centroid drift) into distinct battles
    battles_raw: list[list[tuple[int, float, float, int, dict[int, list[tuple[str, float, float]]]]]] = []
    for item in active_snaps:
        s_gl, fcx, fcy, _nd, _u = item
        if (
            battles_raw
            and (s_gl - battles_raw[-1][-1][0]) <= 320
            and math.hypot(fcx - battles_raw[-1][-1][1], fcy - battles_raw[-1][-1][2]) <= 22.0
        ):
            battles_raw[-1].append(item)
        else:
            battles_raw.append([item])

    for pid in target_pids:
        opp_pid = 2 if pid == 1 else 1
        recs: list[dict[str, Any]] = []
        for b_snaps in battles_raw:
            best_rec = None
            best_score = -1
            for s_gl, fcx, fcy, nd, u_by_p in b_snaps:
                opp_cand = [u for u in u_by_p[opp_pid] if math.hypot(u[1] - fcx, u[2] - fcy) <= 16.0]
                if len(opp_cand) < 3:
                    continue
                our_eng = [
                    u for u in u_by_p[pid]
                    if math.hypot(u[1] - fcx, u[2] - fcy) <= 18.0
                    and any(
                        math.hypot(u[1] - e[1], u[2] - e[2]) <= (16.0 if u[0] in COMBAT_LONG_RANGE_ENGAGE else 13.0)
                        for e in opp_cand
                    )
                ]
                if len(our_eng) < 4:
                    continue
                opp_eng = [
                    e for e in opp_cand
                    if any(
                        math.hypot(e[1] - u[1], e[2] - u[2]) <= (16.0 if e[0] in COMBAT_LONG_RANGE_ENGAGE else 13.0)
                        for u in our_eng
                    )
                ]
                if len(opp_eng) < 3:
                    continue
                sc = len(our_eng) + len(opp_eng) + 2 * nd
                if sc > best_score:
                    best_score = sc
                    best_rec = (s_gl, fcx, fcy, our_eng, opp_eng)
            if best_rec is None:
                continue

            s_gl, _fcx, _fcy, our_eng, opp_eng = best_rec
            sec = round(s_gl / GAME_LOOPS_PER_SEC, 1)
            ox = sum(u[1] for u in our_eng) / len(our_eng)
            oy = sum(u[2] for u in our_eng) / len(our_eng)
            ex = sum(u[1] for u in opp_eng) / len(opp_eng)
            ey = sum(u[2] for u in opp_eng) / len(opp_eng)
            dist_oe = math.hypot(ex - ox, ey - oy)
            if dist_oe < 0.75:
                continue
            fx, fy = (ex - ox) / dist_oe, (ey - oy) / dist_oe
            px, py = -fy, fx

            a_vals: list[float] = []
            w_vals: list[float] = []
            role_a: dict[int, list[float]] = {0: [], 1: [], 2: []}
            caster_entries: list[tuple[str, float]] = []
            non_caster_a: list[float] = []
            in_range_ok = 0
            shooters = 0

            for ut, ux, uy in our_eng:
                a = (ux - ox) * fx + (uy - oy) * fy
                w = (ux - ox) * px + (uy - oy) * py
                a_vals.append(a)
                w_vals.append(w)
                rl = _combat_role_of(ut)
                if rl is not None:
                    role_a[rl].append(a)
                if ut in COMBAT_CASTERS:
                    caster_entries.append((ut, a))
                else:
                    non_caster_a.append(a)
                gr, ar = COMBAT_UNIT_RANGE.get(ut, (None, None))
                if gr is not None or ar is not None:
                    shooters += 1
                    can_hit = False
                    for eut, eux, euy in opp_eng:
                        r_use = ar if eut in COMBAT_FLYERS else gr
                        if r_use is not None and math.hypot(ux - eux, uy - euy) <= r_use + 1.2:
                            can_hit = True
                            break
                    if can_hit:
                        in_range_ok += 1

            width_t = _quantile(w_vals, 0.90) - _quantile(w_vals, 0.10)
            depth_t = _quantile(a_vals, 0.90) - _quantile(a_vals, 0.10)
            w2d = width_t / max(1.0, depth_t)

            wrap: float | None = None
            if len(our_eng) >= 6 and width_t >= 2.5:
                hw = max(1.25, 0.5 * width_t)
                wings = [a for a, w in zip(a_vals, w_vals) if abs(w) >= 0.45 * hw]
                center = [a for a, w in zip(a_vals, w_vals) if abs(w) <= 0.35 * hw]
                if len(wings) >= 2 and len(center) >= 2:
                    wrap = (sum(wings) / len(wings)) - (sum(center) / len(center))

            sep_t: float | None = None
            role_inv: float | None = None
            if role_a[0] and (role_a[1] or role_a[2]):
                back = role_a[2] if role_a[2] else role_a[1]
                sep_t = statistics.median(role_a[0]) - statistics.median(back)
                role_inv = 1.0 if sep_t < -0.5 else 0.0
            elif role_a[1] and role_a[2]:
                sep_t = statistics.median(role_a[1]) - statistics.median(role_a[2])
                role_inv = 1.0 if sep_t < -0.5 else 0.0

            # Caster exposed: fragile casters > 0.5t ahead of median non-caster; healing Medivac > 1.5t ahead
            caster_exp: float | None = None
            if caster_entries and non_caster_a:
                nc_med = statistics.median(non_caster_a)
                exposed = any(
                    ca > nc_med + (1.5 if cut == "Medivac" else 0.5)
                    for cut, ca in caster_entries
                )
                caster_exp = 1.0 if exposed else 0.0

            in_rng_pct = (100.0 * in_range_ok / shooters) if shooters > 0 else None

            opp_has_splash = any(u[0] in COMBAT_SPLASH_UNITS for u in opp_eng)
            splash_nn: float | None = None
            max_in_2t: int | None = None
            splash_clump_pct: float | None = None
            if opp_has_splash and len(our_eng) >= 4:
                nns: list[float] = []
                m2 = 0
                for i, (_ut1, ux, uy) in enumerate(our_eng):
                    min_d = 999.0
                    cnt2 = 0
                    for j, (_ut2, vx, vy) in enumerate(our_eng):
                        if i == j:
                            continue
                        d = math.hypot(ux - vx, uy - vy)
                        if d < min_d:
                            min_d = d
                        if d <= 2.0:
                            cnt2 += 1
                    nns.append(min_d)
                    if cnt2 + 1 > m2:
                        m2 = cnt2 + 1
                splash_nn = statistics.median(nns)
                max_in_2t = m2
                splash_clump_pct = round(100.0 * m2 / len(our_eng), 1)

            in_ramp_zone = False
            uphill = False
            for bpid, ax in base_axes.items():
                mx, my, ux0, uy0, vx0, vy0, nd = ax
                orx = (ox - mx) * ux0 + (oy - my) * uy0
                ory = (ox - mx) * vx0 + (oy - my) * vy0
                erx = (ex - mx) * ux0 + (ey - my) * uy0
                ery = (ex - mx) * vx0 + (ey - my) * vy0
                if 0.18 * nd <= orx <= 0.78 * nd and abs(ory) <= 11.0:
                    in_ramp_zone = True
                if (
                    bpid == opp_pid
                    and orx >= 0.25 * nd
                    and erx < orx - 2.0
                    and erx <= 0.48 * nd
                    and abs(ory) <= 13.0
                    and abs(ery) <= 13.0
                ):
                    uphill = True

            near_bldgs = sum(
                1 for bx, by, bs in all_bldgs_pts
                if bs <= sec and math.hypot(bx - ox, by - oy) <= 6.5
            )
            in_choke = (
                (in_ramp_zone and len(our_eng) >= 6 and width_t <= 7.5)
                or (near_bldgs >= 2 and len(our_eng) >= 6 and w2d < 0.75 and width_t <= 7.0)
                or (len(our_eng) >= 8 and width_t <= 5.5 and w2d < 0.65)
            )

            recs.append({
                "sec": sec,
                "n_our": len(our_eng),
                "n_opp": len(opp_eng),
                "frontage_width_t": round(width_t, 2),
                "formation_depth_t": round(depth_t, 2),
                "width_to_depth_ratio": round(w2d, 2),
                "concave_wrap_score": round(wrap, 2) if wrap is not None else None,
                "front_to_rear_separation_t": round(sep_t, 2) if sep_t is not None else None,
                "role_inversion": role_inv,
                "caster_exposed": caster_exp,
                "in_range_pct": round(in_rng_pct, 1) if in_rng_pct is not None else None,
                "splash_nn_t": round(splash_nn, 2) if splash_nn is not None else None,
                "max_units_in_2t_radius": max_in_2t,
                "splash_clump_pct": splash_clump_pct,
                "fighting_in_choke": 1.0 if in_choke else 0.0,
                "fighting_uphill": 1.0 if uphill else 0.0,
                "replay": replay_name,
                "our_comp": Counter(u[0] for u in our_eng).most_common(3),
                "opp_comp": Counter(u[0] for u in opp_eng).most_common(3),
            })
        out[pid] = recs
    return out


# ---------------------------------------------------------------------------
# Section 6: Macro Army-Group Positioning, Rotation, Regroup, Multiprong &
#            Pro Drop / Warp-In / Nydus / Runby Taxonomy (LotV Tracker)
# ---------------------------------------------------------------------------

WORKERS = frozenset({"SCV", "Probe", "Drone", "DroneBurrowed"})
WARP_GATE_UNITS = frozenset({"Zealot", "Stalker", "Sentry", "Adept", "HighTemplar", "DarkTemplar"})
TRANSPORTS = frozenset({"Medivac", "WarpPrism", "WarpPrismPhasing", "OverlordTransport"})
MOBILE_COMBAT_UNITS = (
    (COMBAT_UNITS - {"Observer", "ObserverSiegeMode", "Overseer", "OverseerSiegeMode"})
    | {"OverlordTransport", "DisruptorPhased"}
)
ARMY_REINFORCE_UNITS = MOBILE_COMBAT_UNITS - TRANSPORTS - {"DisruptorPhased"}
SPECIALIST_HARASS_UNITS = frozenset({
    "DarkTemplar", "Oracle", "Banshee", "Liberator", "LiberatorAG",
    "WidowMine", "WidowMineBurrowed", "Reaper", "Mutalisk", "Phoenix", "Battlecruiser",
    "WarpPrism", "WarpPrismPhasing", "Medivac", "OverlordTransport",
})
DEFENSE_STRUCTURE_UNITS = STATIC_DEF | frozenset({"PlanetaryFortress"})
SIEGE_DEFENDERS = frozenset({"SiegeTankSieged", "LurkerMPBurrowed", "LiberatorAG", "WidowMineBurrowed"})

HARASS_SUBTYPE_META: dict[str, tuple[str, str, str]] = {
    # subtype: (race, kind, display_label)
    "prism_ht_storm_drop": ("Protoss", "drop", "Prism HT Storm Drop"),
    "prism_archon_drop": ("Protoss", "drop", "Prism Archon Drop"),
    "prism_disruptor_drop": ("Protoss", "drop", "Prism Disruptor Drop"),
    "prism_immortal_drop": ("Protoss", "drop", "Prism Immortal Drop"),
    "prism_dt_warp_or_drop": ("Protoss", "warp_in", "Prism / Offensive DT Warp-In"),
    "prism_zealot_warp_in": ("Protoss", "warp_in", "Prism / Offensive Zealot Warp-In"),
    "prism_gateway_warp_in": ("Protoss", "warp_in", "Prism / Proxy Gateway Warp-In"),
    "prism_drop_other": ("Protoss", "drop", "Prism Drop (Other)"),
    "runby_zealot": ("Protoss", "runby", "Zealot Runby"),
    "runby_dt": ("Protoss", "runby", "Dark Templar Runby"),
    "runby_adept": ("Protoss", "runby", "Adept Shade Runby"),
    "harass_oracle": ("Protoss", "runby", "Oracle Harass"),
    "harass_phoenix": ("Protoss", "runby", "Phoenix Harass"),
    "runby_protoss_other": ("Protoss", "runby", "Other Protoss Raid"),
    "medivac_mine_drop": ("Terran", "drop", "Medivac Widow Mine Drop"),
    "medivac_bio_drop": ("Terran", "drop", "Medivac Bio Drop"),
    "medivac_hellion_hellbat_drop": ("Terran", "drop", "Medivac Hellion/Hellbat Drop"),
    "medivac_tank_thor_drop": ("Terran", "drop", "Medivac Tank/Thor Cliff Drop"),
    "runby_hellion_hellbat": ("Terran", "runby", "Hellion/Hellbat Runby"),
    "harass_banshee": ("Terran", "runby", "Banshee Harass"),
    "harass_liberator": ("Terran", "runby", "Liberator Harass"),
    "harass_reaper": ("Terran", "runby", "Reaper Harass"),
    "harass_bc": ("Terran", "runby", "Battlecruiser Jump Harass"),
    "runby_terran_other": ("Terran", "runby", "Other Terran Raid"),
    "dropperlord_baneling_drop": ("Zerg", "drop", "Dropperlord Baneling Drop"),
    "dropperlord_zergling_drop": ("Zerg", "drop", "Dropperlord Zergling Drop"),
    "dropperlord_heavy_drop": ("Zerg", "drop", "Dropperlord Roach/Lurker/Ravager Drop"),
    "nydus_worm_attack": ("Zerg", "nydus", "Nydus Worm Attack"),
    "runby_baneling": ("Zerg", "runby", "Baneling Runby"),
    "runby_zergling": ("Zerg", "runby", "Zergling Runby"),
    "harass_mutalisk": ("Zerg", "runby", "Mutalisk Harass"),
    "runby_zerg_other": ("Zerg", "runby", "Roach/Lurker/Other Zerg Raid"),
}


class _TrackerCombatState:
    """Shared single-pass LotV tracker collector for Section 5 (battles) & Section 6 (army groups)."""

    __slots__ = (
        "live", "unit_meta", "th_pos", "th_records", "th_by_idx",
        "static_def_records", "static_def_by_idx", "all_bldgs_pts",
        "deaths", "combat_death_recs", "worker_death_recs", "death_gl_by_tag",
        "combat_snaps", "active_pos_snaps", "unit_births", "seen_birth_tags",
        "warp_in_inits", "nydus_events", "seen_nydus_tags", "dur_gl",
        "transport_sightings",
    )

    def __init__(self) -> None:
        self.live: dict[int, list[Any]] = {}
        self.unit_meta: dict[tuple[int, int], tuple[int, str, int]] = {}
        self.th_pos: dict[int, list[tuple[float, float, float]]] = {1: [], 2: []}
        self.th_records: dict[int, list[list[Any]]] = {1: [], 2: []}
        self.th_by_idx: dict[int, list[Any]] = {}
        self.static_def_records: dict[int, list[list[Any]]] = {1: [], 2: []}
        self.static_def_by_idx: dict[int, list[Any]] = {}
        self.all_bldgs_pts: list[tuple[float, float, float]] = []
        self.deaths: list[tuple[int, int, str, float, float]] = []
        self.combat_death_recs: list[tuple[int, int, str, float, float, int, int | None, str | None, int | None]] = []
        self.worker_death_recs: list[tuple[int, int, str, float, float, int | None, str | None, int | None]] = []
        self.death_gl_by_tag: dict[int, int] = {}
        self.combat_snaps: list[tuple[int, dict[int, list[tuple[str, float, float]]]]] = []
        self.active_pos_snaps: list[tuple[int, dict[int, list[tuple[int, str, float, float, int]]], dict[int, int]]] = []
        self.unit_births: dict[int, list[tuple[int, int, str, float, float, bool]]] = {1: [], 2: []}
        self.seen_birth_tags: set[int] = set()
        self.warp_in_inits: dict[int, list[tuple[int, int, str, float, float]]] = {1: [], 2: []}
        self.nydus_events: dict[int, list[tuple[int, int, float, float]]] = {1: [], 2: []}
        self.seen_nydus_tags: set[int] = set()
        self.dur_gl: int = 0
        self.transport_sightings: dict[int, list[tuple[int, str, float, float]]] = {1: [], 2: []}

    def on_unit_appear(
        self, gl: int, pid: int, idx: int, recycle: int, ut: str, x: float, y: float, is_init: bool
    ) -> None:
        if gl > self.dur_gl:
            self.dur_gl = gl
        if pid not in (1, 2):
            return
        tag = (idx << 18) | recycle
        self.live[idx] = [pid, ut, x, y, gl, False, tag, gl, x, y]
        self.unit_meta[(idx, recycle)] = (pid, ut, tag)
        sec = gl / GAME_LOOPS_PER_SEC
        if ut in ALL_BLDGS:
            self.all_bldgs_pts.append((x, y, sec))
            if ut in TOWN_HALLS:
                self.th_pos[pid].append((sec, x, y))
                rec = [sec, 1e9, x, y, tag]
                self.th_records[pid].append(rec)
                self.th_by_idx[idx] = rec
            if ut in DEFENSE_STRUCTURE_UNITS:
                drec = [sec, 1e9, x, y]
                self.static_def_records[pid].append(drec)
                self.static_def_by_idx[idx] = drec
        elif ut == "NydusCanal":
            if tag not in self.seen_nydus_tags:
                self.seen_nydus_tags.add(tag)
                self.nydus_events[pid].append((gl, tag, x, y))
        if ut in ARMY_REINFORCE_UNITS and tag not in self.seen_birth_tags:
            self.seen_birth_tags.add(tag)
            self.unit_births[pid].append((gl, tag, ut, x, y, is_init))
        if is_init and ut in WARP_GATE_UNITS:
            self.warp_in_inits[pid].append((gl, tag, ut, x, y))
        if ut in TRANSPORTS:
            self.transport_sightings[pid].append((gl, ut, x, y))

    def on_type_change(self, gl: int, idx: int, recycle: int, ut: str) -> None:
        if gl > self.dur_gl:
            self.dur_gl = gl
        u = self.live.get(idx)
        if u is not None:
            pid = u[0]
            u[1] = ut
            u[4] = gl
            self.unit_meta[(idx, recycle)] = (pid, ut, u[6])
            if ut == "PlanetaryFortress":
                drec = [gl / GAME_LOOPS_PER_SEC, 1e9, u[2], u[3]]
                self.static_def_records[pid].append(drec)
                self.static_def_by_idx[idx] = drec
            elif ut in TRANSPORTS:
                self.transport_sightings[pid].append((gl, ut, u[2], u[3]))

    def on_died(
        self,
        gl: int,
        idx: int,
        dx_raw: Any,
        dy_raw: Any,
        k_pid_raw: Any,
        k_idx_raw: Any,
        k_rec_raw: Any,
    ) -> None:
        if gl > self.dur_gl:
            self.dur_gl = gl
        sec = gl / GAME_LOOPS_PER_SEC
        th_r = self.th_by_idx.pop(idx, None)
        if th_r is not None:
            th_r[1] = sec
        sd_r = self.static_def_by_idx.pop(idx, None)
        if sd_r is not None:
            sd_r[1] = sec

        u = self.live.pop(idx, None)
        if u is None:
            return
        dx = float(dx_raw if dx_raw is not None else u[2])
        dy = float(dy_raw if dy_raw is not None else u[3])

        k_pid: int | None = int(k_pid_raw) if k_pid_raw in (1, 2) else None
        k_ut: str | None = None
        k_tag: int | None = None
        if k_idx_raw is not None and k_rec_raw is not None:
            km = self.unit_meta.get((int(k_idx_raw), int(k_rec_raw)))
            if km is not None:
                k_pid, k_ut, k_tag = km

        ut = u[1]
        if ut in COMBAT_UNITS or ut in TRANSPORTS:
            if ut in COMBAT_UNITS:
                self.deaths.append((gl, u[0], ut, dx, dy))
            self.combat_death_recs.append((gl, u[0], ut, dx, dy, u[6], k_pid, k_ut, k_tag))
            self.death_gl_by_tag[u[6]] = gl
            if ut in TRANSPORTS:
                self.transport_sightings[u[0]].append((gl, ut, dx, dy))
        elif ut in WORKERS:
            self.worker_death_recs.append((gl, u[0], ut, dx, dy, k_pid, k_ut, k_tag))

    def on_positions(self, gl: int, first_idx: int, items: list[Any]) -> None:
        if gl > self.dur_gl:
            self.dur_gl = gl
        idx = first_idx
        moved_p1: list[tuple[int, str, float, float, int]] = []
        moved_p2: list[tuple[int, str, float, float, int]] = []
        for k in range(0, len(items), 3):
            idx += int(items[k])
            x, y = float(items[k + 1]), float(items[k + 2])
            u = self.live.get(idx)
            if u is not None:
                u[2] = x
                u[3] = y
                u[4] = gl
                u[5] = True
                ut = u[1]
                if ut in MOBILE_COMBAT_UNITS:
                    rec = (u[6], ut, x, y, u[7])
                    if u[0] == 1:
                        moved_p1.append(rec)
                    else:
                        moved_p2.append(rec)
                    if ut in TRANSPORTS:
                        self.transport_sightings[u[0]].append((gl, ut, x, y))

        if gl >= 1200 and (moved_p1 or moved_p2):
            cnt1 = 0
            cnt2 = 0
            for v in self.live.values():
                if v[1] in ARMY_REINFORCE_UNITS:
                    if v[0] == 1:
                        cnt1 += 1
                    else:
                        cnt2 += 1
            self.active_pos_snaps.append((gl, {1: moved_p1, 2: moved_p2}, {1: cnt1, 2: cnt2}))

        # Exact Section 5 combat snapshot logic (100% preserved)
        if gl >= 2400:
            p1u: list[tuple[str, float, float]] = []
            p2u: list[tuple[str, float, float]] = []
            for v in self.live.values():
                if v[1] not in COMBAT_UNITS:
                    continue
                age = gl - v[4]
                if age > 960 and v[1] not in COMBAT_STATIONARY_OK:
                    continue
                if not v[5] and age > 480:
                    continue
                rec_u = (v[1], v[2], v[3])
                if v[0] == 1:
                    p1u.append(rec_u)
                else:
                    p2u.append(rec_u)
            if len(p1u) >= 3 and len(p2u) >= 3:
                self.combat_snaps.append((gl, {1: p1u, 2: p2u}))


def _cluster_active_units(
    units: list[tuple[int, str, float, float, int]],
    radius: float = 12.0,
) -> list[dict[str, Any]]:
    """
    Density-seeded centroid-bounded spatial clustering (immune to single-linkage chaining).
    Each input unit is `(tag, unit_type, x, y, birth_gl)`.
    """
    n = len(units)
    if n == 0:
        return []
    r2 = radius * radius
    # Count neighbors within radius to seed densest cores first (deterministic order)
    deg = [0] * n
    for i in range(n):
        xi, yi = units[i][2], units[i][3]
        c = 0
        for j in range(n):
            dx = xi - units[j][2]
            dy = yi - units[j][3]
            if dx * dx + dy * dy <= r2:
                c += 1
        deg[i] = c

    order = sorted(range(n), key=lambda i: (-deg[i], units[i][0]))
    assigned = [False] * n
    clusters: list[dict[str, Any]] = []
    for seed in order:
        if assigned[seed]:
            continue
        sx, sy = units[seed][2], units[seed][3]
        members = [seed]
        assigned[seed] = True
        for j in order:
            if not assigned[j]:
                dx = units[j][2] - sx
                dy = units[j][3] - sy
                if dx * dx + dy * dy <= r2:
                    members.append(j)
                    assigned[j] = True
        cx = sum(units[m][2] for m in members) / len(members)
        cy = sum(units[m][3] for m in members) / len(members)
        # One centroid-pull pass to capture adjacent units within radius of updated centroid
        for j in order:
            if not assigned[j]:
                dx = units[j][2] - cx
                dy = units[j][3] - cy
                if dx * dx + dy * dy <= r2:
                    members.append(j)
                    assigned[j] = True
        cx = sum(units[m][2] for m in members) / len(members)
        cy = sum(units[m][3] for m in members) / len(members)
        m_units = [units[m] for m in members]
        clusters.append({
            "cx": cx,
            "cy": cy,
            "size": len(m_units),
            "units": m_units,
            "tags": frozenset(u[0] for u in m_units),
            "types": Counter(u[1] for u in m_units),
        })
    return clusters


def _nearest_alive_base(
    x: float, y: float, sec: float, th_list: list[list[Any]]
) -> tuple[int | None, float]:
    best_i: int | None = None
    best_d = 9999.0
    for i, r in enumerate(th_list):
        if r[0] <= sec + 5.0 and sec <= r[1] + 5.0:
            d = math.hypot(x - r[2], y - r[3])
            if d < best_d:
                best_d = d
                best_i = i
    if best_i is None and th_list:
        for i, r in enumerate(th_list):
            d = math.hypot(x - r[2], y - r[3])
            if d < best_d:
                best_d = d
                best_i = i
    return best_i, best_d


def _classify_drop_subtype(transport_ut: str, types: Counter[str]) -> str | None:
    if transport_ut in ("WarpPrism", "WarpPrismPhasing"):
        if types.get("HighTemplar", 0) >= 1:
            return "prism_ht_storm_drop"
        if types.get("Archon", 0) >= 1:
            return "prism_archon_drop"
        if types.get("Disruptor", 0) + types.get("DisruptorPhased", 0) >= 1:
            return "prism_disruptor_drop"
        if types.get("Immortal", 0) >= 1:
            return "prism_immortal_drop"
        if types.get("DarkTemplar", 0) >= 1:
            return "prism_dt_warp_or_drop"
        if types.get("Zealot", 0) >= 2:
            return "prism_zealot_warp_in"
        if sum(types.get(u, 0) for u in ("Stalker", "Adept", "Sentry", "Zealot")) >= 2:
            return "prism_gateway_warp_in"
        return "prism_drop_other"
    if transport_ut == "Medivac":
        if types.get("WidowMine", 0) + types.get("WidowMineBurrowed", 0) >= 1:
            return "medivac_mine_drop"
        if types.get("Hellion", 0) + types.get("HellionTank", 0) >= 1:
            return "medivac_hellion_hellbat_drop"
        if types.get("SiegeTank", 0) + types.get("SiegeTankSieged", 0) + types.get("Thor", 0) + types.get("ThorAP", 0) >= 1:
            return "medivac_tank_thor_drop"
        if types.get("Marine", 0) + types.get("Marauder", 0) + types.get("Ghost", 0) >= 2:
            return "medivac_bio_drop"
        return None
    if transport_ut == "OverlordTransport":
        if types.get("Baneling", 0) + types.get("BanelingBurrowed", 0) >= 1:
            return "dropperlord_baneling_drop"
        if sum(types.get(u, 0) for u in ("Roach", "RoachBurrowed", "Ravager", "LurkerMP", "LurkerMPBurrowed", "Hydralisk", "Queen")) >= 1:
            return "dropperlord_heavy_drop"
        if types.get("Zergling", 0) >= 2:
            return "dropperlord_zergling_drop"
        return None
    return None


def _classify_runby_subtype(race: str, types: Counter[str]) -> str | None:
    if race == "Protoss":
        if types.get("DarkTemplar", 0) >= 1:
            return "runby_dt"
        if types.get("Oracle", 0) >= 1:
            return "harass_oracle"
        if types.get("Phoenix", 0) >= 2:
            return "harass_phoenix"
        if types.get("Zealot", 0) >= 2:
            return "runby_zealot"
        if types.get("Adept", 0) >= 1:
            return "runby_adept"
        if sum(types.values()) >= 2:
            return "runby_protoss_other"
        return None
    if race == "Terran":
        if types.get("Banshee", 0) >= 1:
            return "harass_banshee"
        if types.get("Liberator", 0) + types.get("LiberatorAG", 0) >= 1:
            return "harass_liberator"
        if types.get("Battlecruiser", 0) >= 1:
            return "harass_bc"
        if types.get("Hellion", 0) + types.get("HellionTank", 0) >= 2:
            return "runby_hellion_hellbat"
        if types.get("Reaper", 0) >= 1:
            return "harass_reaper"
        if sum(types.values()) >= 2:
            return "runby_terran_other"
        return None
    if race == "Zerg":
        if types.get("Baneling", 0) + types.get("BanelingBurrowed", 0) >= 1:
            return "runby_baneling"
        if types.get("Mutalisk", 0) >= 2:
            return "harass_mutalisk"
        if types.get("Zergling", 0) >= 3:
            return "runby_zergling"
        if sum(types.values()) >= 2:
            return "runby_zerg_other"
        return None
    return None


def compute_army_group_metrics_from_tracker_state(
    state: _TrackerCombatState,
    race_by_pid: dict[int, str],
    target_pids: tuple[int, ...] = (1, 2),
    replay_name: str = "",
) -> dict[int, dict[str, Any]]:
    """
    Compute Section 6 macro army-group metrics (multiprong, synchronized harass,
    reinforcement staging/link-up vs solo trickle deaths, disengage & regroup vs
    fight-to-annihilation, base-switch target rotations, and full drop/warp-in/Nydus/runby
    taxonomy) from identical LotV tracker state for Pro GM and Mothman replays.
    """
    out: dict[int, dict[str, Any]] = {}
    dur_gl = max(state.dur_gl, 1)
    dur_sec = dur_gl / GAME_LOOPS_PER_SEC
    if dur_sec < 120.0:
        return out

    # Index active combat positions & live army counts on the canonical 240f tracker grid
    grid_units: dict[int, dict[int, dict[int, tuple[int, str, float, float, int]]]] = {
        1: defaultdict(dict),
        2: defaultdict(dict),
    }
    grid_live_cnt: dict[int, dict[int, int]] = {1: {}, 2: {}}
    first_combat_by_tag: dict[int, tuple[int, float, float]] = {}

    for gl, mp, cnts in state.active_pos_snaps:
        b = int(round(gl / 240.0)) * 240
        for p in (1, 2):
            grid_live_cnt[p][b] = max(grid_live_cnt[p].get(b, 0), cnts[p])
            bd = grid_units[p][b]
            for tag, ut, x, y, bgl in mp[p]:
                bd[tag] = (tag, ut, x, y, bgl)
                prev_fc = first_combat_by_tag.get(tag)
                if prev_fc is None or gl < prev_fc[0]:
                    first_combat_by_tag[tag] = (gl, x, y)

    # Fold combat deaths into grid & first_combat (catches 1-second burst kills between 240f ticks)
    deaths_by_pid: dict[int, list[tuple[int, str, float, float, int, int | None, str | None, int | None]]] = {
        1: [], 2: []
    }
    kills_by_pid: dict[int, list[tuple[int, str, float, float, int | None, bool]]] = {1: [], 2: []}
    for gl, vpid, vut, dx, dy, vtag, kpid, kut, ktag in state.combat_death_recs:
        deaths_by_pid[vpid].append((gl, vut, dx, dy, vtag, kpid, kut, ktag))
        b = int(round(gl / 240.0)) * 240
        if vut in MOBILE_COMBAT_UNITS:
            if vtag not in grid_units[vpid][b]:
                grid_units[vpid][b][vtag] = (vtag, vut, dx, dy, gl)
            prev_fc = first_combat_by_tag.get(vtag)
            if prev_fc is None or gl < prev_fc[0]:
                first_combat_by_tag[vtag] = (gl, dx, dy)
        if kpid in (1, 2) and kut:
            kills_by_pid[kpid].append((gl, kut, dx, dy, ktag, False))
            if ktag is not None and kut in MOBILE_COMBAT_UNITS:
                if ktag not in grid_units[kpid][b]:
                    grid_units[kpid][b][ktag] = (ktag, kut, dx, dy, gl)
                prev_kfc = first_combat_by_tag.get(ktag)
                if prev_kfc is None or gl < prev_kfc[0]:
                    first_combat_by_tag[ktag] = (gl, dx, dy)

    worker_kills_by_killer: dict[int, list[tuple[int, str | None, float, float, int | None, int]]] = {1: [], 2: []}
    for w_idx, (gl, vpid, _vut, dx, dy, kpid, kut, ktag) in enumerate(state.worker_death_recs):
        attacker = kpid if kpid in (1, 2) and kpid != vpid else (2 if vpid == 1 else 1)
        worker_kills_by_killer[attacker].append((gl, kut, dx, dy, ktag, w_idx))
        kills_by_pid[attacker].append((gl, kut or "Unknown", dx, dy, ktag, True))
        b = int(round(gl / 240.0)) * 240
        if ktag is not None and kut and kut in MOBILE_COMBAT_UNITS:
            if ktag not in grid_units[attacker][b]:
                grid_units[attacker][b][ktag] = (ktag, kut, dx, dy, gl)

    all_buckets = sorted(set(grid_units[1].keys()) | set(grid_units[2].keys()))

    def _est_live_army(pid: int, gl: int) -> int:
        b = int(round(gl / 240.0)) * 240
        if b in grid_live_cnt[pid]:
            return grid_live_cnt[pid][b]
        for off in (240, -240, 480, -480, 720, -720):
            if (b + off) in grid_live_cnt[pid]:
                return grid_live_cnt[pid][b + off]
        return 0

    for pid in target_pids:
        opp_pid = 2 if pid == 1 else 1
        race = race_by_pid.get(pid, "")
        our_ths = state.th_records.get(pid, [])
        opp_ths = state.th_records.get(opp_pid, [])
        opp_sdefs = state.static_def_records.get(opp_pid, [])
        if not our_ths or not opp_ths:
            continue

        # Active-game horizon: stop offensive multiprong/harass/rotation clock 15s after opponent's
        # army collapses (< 3 combat units & no more combat kills), eliminating Human-GG vs AI-No-GG mop-up bias!
        opp_active_gls = [b for b, cnt in grid_live_cnt[opp_pid].items() if cnt >= 3]
        opp_active_gls.extend(r[0] for r in kills_by_pid[opp_pid] if not r[5])
        if opp_active_gls:
            active_end_gl = min(dur_gl, max(max(opp_active_gls) + 336, min(dur_gl, 5376)))
        else:
            active_end_gl = dur_gl
        active_dur_sec = max(60.0, active_end_gl / GAME_LOOPS_PER_SEC)

        # -------------------------------------------------------------------
        # Precompute per-bucket clustered active groups (all & offensive)
        # -------------------------------------------------------------------
        bucket_off_groups: dict[int, list[dict[str, Any]]] = {}
        bucket_all_groups: dict[int, list[dict[str, Any]]] = {}
        active_group_counts_mid: list[int] = []

        # Index warp-ins & nydus by 240f bucket for offensive pressure windows
        warp_by_b: dict[int, list[tuple[int, int, str, float, float]]] = defaultdict(list)
        for gl, tag, ut, wx, wy in state.warp_in_inits[pid]:
            sec = gl / GAME_LOOPS_PER_SEC
            _eb, ed = _nearest_alive_base(wx, wy, sec, opp_ths)
            _ob, od = _nearest_alive_base(wx, wy, sec, our_ths)
            if ed <= 30.0 and od >= 24.0:
                warp_by_b[int(round(gl / 240.0)) * 240].append((gl, tag, ut, wx, wy))
        nydus_by_b: dict[int, list[tuple[int, int, float, float]]] = defaultdict(list)
        for gl, tag, nx, ny in state.nydus_events[pid]:
            sec = gl / GAME_LOOPS_PER_SEC
            _eb, ed = _nearest_alive_base(nx, ny, sec, opp_ths)
            _ob, od = _nearest_alive_base(nx, ny, sec, our_ths)
            if ed <= 35.0 and od >= 25.0:
                nydus_by_b[int(round(gl / 240.0)) * 240].append((gl, tag, nx, ny))

        for b in all_buckets:
            if b < 1920:
                continue
            sec = b / GAME_LOOPS_PER_SEC
            # Combine units from [b, b+240]? Keep exact bucket b for crisp 10.7s/15s windows
            u_map: dict[int, tuple[int, str, float, float, int]] = dict(grid_units[pid].get(b, {}))
            for _gl, tag, ut, wx, wy in warp_by_b.get(b, ()):
                u_map[tag] = (tag, ut, wx, wy, _gl)
            for _gl, tag, nx, ny in nydus_by_b.get(b, ()):
                u_map[tag] = (tag, "NydusCanal", nx, ny, _gl)

            all_cls = _cluster_active_units(list(u_map.values()), radius=12.0)
            qual_all: list[dict[str, Any]] = []
            qual_off: list[dict[str, Any]] = []
            for cl in all_cls:
                eb_i, eb_d = _nearest_alive_base(cl["cx"], cl["cy"], sec, opp_ths)
                ob_i, ob_d = _nearest_alive_base(cl["cx"], cl["cy"], sec, our_ths)
                has_spec = any(
                    (ut in SPECIALIST_HARASS_UNITS) or (ut == "NydusCanal")
                    for ut in cl["types"]
                )
                cl["eb_idx"] = eb_i
                cl["eb_dist"] = eb_d
                cl["ob_idx"] = ob_i
                cl["ob_dist"] = ob_d
                cl["on_enemy_half"] = (eb_d < ob_d) or (eb_d <= 28.0)
                if cl["size"] >= 3 or has_spec:
                    qual_all.append(cl)
                if cl["on_enemy_half"] and (
                    cl["size"] >= 3
                    or (has_spec and eb_d <= 28.0)
                    or (cl["size"] >= 2 and eb_d <= 22.0)
                ):
                    qual_off.append(cl)
            bucket_all_groups[b] = qual_all
            bucket_off_groups[b] = qual_off
            if sec >= 240.0 and qual_all:
                active_group_counts_mid.append(sum(1 for g in qual_all if g["size"] >= 3))

        # -------------------------------------------------------------------
        # Metric 1A: Multiprong Attack Rate (15s rolling windows)
        # -------------------------------------------------------------------
        off_windows = 0
        multiprong_windows = 0
        multiprong_samples: list[dict[str, Any]] = []
        last_mp_sample_b = -9999

        for b in all_buckets:
            if b < 2160 or b > active_end_gl:
                continue
            # Union offensive groups across [b - 240, b] (15s overlapping activity window)
            win_groups: list[dict[str, Any]] = []
            for wb in (b - 240, b):
                win_groups.extend(bucket_off_groups.get(wb, ()))
            if not win_groups:
                continue
            # Merge overlapping groups from b-240 and b (within 18t) keeping the stronger one
            merged_wg: list[dict[str, Any]] = []
            for g in sorted(win_groups, key=lambda x: -x["size"]):
                dup = False
                for mg in merged_wg:
                    if math.hypot(g["cx"] - mg["cx"], g["cy"] - mg["cy"]) <= 18.0:
                        dup = True
                        break
                if not dup:
                    merged_wg.append(g)
            # Active offensive window requires >= 3 total offensive units or a genuine threat to an enemy base
            tot_off_u = sum(g["size"] for g in merged_wg)
            if tot_off_u < 3 and not any(g["eb_dist"] <= 20.0 for g in merged_wg):
                continue
            off_windows += 1
            is_mp = False
            best_pair = None
            for i in range(len(merged_wg)):
                g1 = merged_wg[i]
                for j in range(i + 1, len(merged_wg)):
                    g2 = merged_wg[j]
                    sep = math.hypot(g1["cx"] - g2["cx"], g1["cy"] - g2["cy"])
                    if sep >= 25.0 and (
                        (g1["eb_idx"] is not None and g2["eb_idx"] is not None and g1["eb_idx"] != g2["eb_idx"] and g1["eb_dist"] <= 30.0 and g2["eb_dist"] <= 30.0)
                        or (sep >= 32.0 and g1["size"] >= 2 and g2["size"] >= 2)
                    ):
                        is_mp = True
                        best_pair = (g1, g2, sep)
                        break
                if is_mp:
                    break
            if is_mp:
                multiprong_windows += 1
                if b - last_mp_sample_b >= 960 and best_pair is not None and len(multiprong_samples) < 3:
                    g1, g2, sep = best_pair
                    multiprong_samples.append({
                        "sec": round(b / GAME_LOOPS_PER_SEC, 1),
                        "sep_t": round(sep, 1),
                        "g1": g1["types"].most_common(2),
                        "g2": g2["types"].most_common(2),
                        "replay": replay_name,
                    })
                    last_mp_sample_b = b

        multiprong_pct = round(100.0 * multiprong_windows / off_windows, 1) if off_windows > 0 else None

        # -------------------------------------------------------------------
        # Metric 1B & 5: Full Drop / Warp-In / Nydus / Runby Taxonomy & Sync Rate
        # -------------------------------------------------------------------
        raw_harass: list[dict[str, Any]] = []

        # Helper: check whether player has a transport near (x, y) around gl
        def _nearby_transport(gl: int, x: float, y: float, max_d: float = 26.0, max_dt: int = 560) -> str | None:
            for tgl, tut, tx, ty in state.transport_sightings[pid]:
                if abs(tgl - gl) <= max_dt and math.hypot(tx - x, ty - y) <= max_d:
                    return tut
            return None

        # (A) Nydus Worm attacks
        for gl, _tag, nx, ny in state.nydus_events[pid]:
            if gl > active_end_gl:
                continue
            sec = gl / GAME_LOOPS_PER_SEC
            eb_i, eb_d = _nearest_alive_base(nx, ny, sec, opp_ths)
            _ob, ob_d = _nearest_alive_base(nx, ny, sec, our_ths)
            if eb_i is not None and eb_d <= 35.0 and ob_d >= 25.0:
                raw_harass.append({
                    "gl": gl, "kind": "nydus", "subtype": "nydus_worm_attack",
                    "x": nx, "y": ny, "eb_idx": eb_i, "priority": 1,
                })

        # (B) Offensive Warp-Ins (clustered within 15s and 14t)
        off_warps: list[tuple[int, str, float, float, int]] = []
        for gl, _tag, ut, wx, wy in state.warp_in_inits[pid]:
            if gl > active_end_gl:
                continue
            sec = gl / GAME_LOOPS_PER_SEC
            eb_i, eb_d = _nearest_alive_base(wx, wy, sec, opp_ths)
            _ob, ob_d = _nearest_alive_base(wx, wy, sec, our_ths)
            near_prism = _nearby_transport(gl, wx, wy, max_d=18.0, max_dt=600) in ("WarpPrism", "WarpPrismPhasing")
            if eb_i is not None and ((eb_d <= 28.0 and ob_d >= 26.0) or (near_prism and eb_d < ob_d)):
                off_warps.append((gl, ut, wx, wy, eb_i))
        off_warps.sort(key=lambda z: z[0])
        warp_waves: list[list[tuple[int, str, float, float, int]]] = []
        for w in off_warps:
            placed = False
            for wv in reversed(warp_waves):
                if w[0] - wv[-1][0] <= 336 and math.hypot(w[2] - wv[0][2], w[3] - wv[0][3]) <= 14.0:
                    wv.append(w)
                    placed = True
                    break
            if not placed:
                warp_waves.append([w])
        for wv in warp_waves:
            w_types = Counter(z[1] for z in wv)
            if len(wv) >= 2 or w_types.get("DarkTemplar", 0) >= 1 or w_types.get("HighTemplar", 0) >= 1:
                if w_types.get("DarkTemplar", 0) >= 1:
                    st = "prism_dt_warp_or_drop"
                elif w_types.get("HighTemplar", 0) >= 1:
                    st = "prism_ht_storm_drop"
                elif w_types.get("Zealot", 0) >= 2:
                    st = "prism_zealot_warp_in"
                else:
                    st = "prism_gateway_warp_in"
                raw_harass.append({
                    "gl": wv[0][0], "kind": HARASS_SUBTYPE_META[st][1], "subtype": st,
                    "x": sum(z[2] for z in wv) / len(wv),
                    "y": sum(z[3] for z in wv) / len(wv),
                    "eb_idx": wv[0][4], "priority": 1,
                })

        # (C) Transport drops from SUnitPositionsEvent sightings near enemy bases
        for b in all_buckets:
            if b < 1920 or b > active_end_gl:
                continue
            sec = b / GAME_LOOPS_PER_SEC
            b_u = list(grid_units[pid].get(b, {}).values())
            for _tag, ut, tx, ty, _bgl in b_u:
                if ut not in TRANSPORTS:
                    continue
                eb_i, eb_d = _nearest_alive_base(tx, ty, sec, opp_ths)
                if eb_i is None or eb_d > 20.0:
                    continue
                # Gather nearby friendly combat units & killers around this transport
                near_types: Counter[str] = Counter()
                local_cnt = 0
                for wb in (b - 240, b, b + 240):
                    for _t2, u2, x2, y2, _bg2 in grid_units[pid].get(wb, {}).values():
                        if u2 not in TRANSPORTS and math.hypot(x2 - tx, y2 - ty) <= 14.0:
                            near_types[u2] += 1
                            if wb == b:
                                local_cnt += 1
                # Also fold killer types near this enemy base within +-240f
                ebx, eby = opp_ths[eb_i][2], opp_ths[eb_i][3]
                for kgl, kut, kx, ky, _kt, _isw in kills_by_pid[pid]:
                    if abs(kgl - b) <= 280 and kut and kut != "Unknown" and math.hypot(kx - ebx, ky - eby) <= 18.0:
                        near_types[kut] += 1
                # Exclude giant end-game full-army push UNLESS a separate group exists >= 25t away
                has_other_prong = any(
                    g["size"] >= 6 and math.hypot(g["cx"] - tx, g["cy"] - ty) >= 25.0
                    for g in bucket_all_groups.get(b, ())
                )
                if local_cnt > 18 and not has_other_prong:
                    continue
                st = _classify_drop_subtype(ut, near_types)
                if st is not None:
                    # Skip empty WarpPrism flyby with zero units and zero kills
                    if st == "prism_drop_other" and sum(near_types.values()) == 0:
                        continue
                    raw_harass.append({
                        "gl": b, "kind": HARASS_SUBTYPE_META[st][1], "subtype": st,
                        "x": tx, "y": ty, "eb_idx": eb_i, "priority": 2,
                    })

        # (D) Killer-anchored instant drops & worker-killing raids (catches 1.5s HT Storm / Mine / Archon / Bane drops!)
        for wgl, kut, wx, wy, _ktag, _widx in worker_kills_by_killer[pid]:
            if wgl < 1600 or wgl > active_end_gl or not kut:
                continue
            sec = wgl / GAME_LOOPS_PER_SEC
            eb_i, eb_d = _nearest_alive_base(wx, wy, sec, opp_ths)
            if eb_i is None or eb_d > 20.0:
                continue
            b = int(round(wgl / 240.0)) * 240
            live_n = max(1, _est_live_army(pid, wgl))
            local_n = sum(
                1 for _t2, u2, x2, y2, _bg2 in grid_units[pid].get(b, {}).values()
                if u2 not in TRANSPORTS and math.hypot(x2 - wx, y2 - wy) <= 16.0
            )
            has_other_prong = any(
                g["size"] >= 6 and math.hypot(g["cx"] - wx, g["cy"] - wy) >= 25.0
                for g in bucket_all_groups.get(b, ())
            )
            tr = _nearby_transport(wgl, wx, wy, max_d=32.0, max_dt=720)
            is_spec_or_tr = (
                (tr is not None)
                or (kut in SPECIALIST_HARASS_UNITS)
                or (kut in ("HighTemplar", "Disruptor", "DisruptorPhased"))
            )
            # Exclude main-army frontal push (>= 45% of total army or > 12 non-specialist units without secondary prong)
            if (not is_spec_or_tr) and (not has_other_prong) and (local_n > 12 or local_n >= 0.45 * live_n):
                continue
            st: str | None = None
            if tr is not None:
                st = _classify_drop_subtype(tr, Counter({kut: 2}))
            if st is None:
                # Special check: HT/Disruptor/Archon/WidowMine killing workers cleanly with transport anywhere
                if kut == "HighTemplar" and state.transport_sightings[pid]:
                    st = "prism_ht_storm_drop"
                elif kut in ("Disruptor", "DisruptorPhased") and state.transport_sightings[pid]:
                    st = "prism_disruptor_drop"
                elif kut in ("WidowMine", "WidowMineBurrowed"):
                    st = "medivac_mine_drop" if state.transport_sightings[pid] else "runby_terran_other"
                else:
                    st = _classify_runby_subtype(race, Counter({kut: 3}))
            if st is not None:
                raw_harass.append({
                    "gl": wgl, "kind": HARASS_SUBTYPE_META[st][1], "subtype": st,
                    "x": wx, "y": wy, "eb_idx": eb_i, "priority": 2 if HARASS_SUBTYPE_META[st][1] == "drop" else 3,
                })

        # (E) Positional non-lethal runbys / air harass entering enemy mineral lines
        for b in all_buckets:
            if b < 1920 or b > active_end_gl:
                continue
            sec = b / GAME_LOOPS_PER_SEC
            live_n = max(1, _est_live_army(pid, b))
            for g in bucket_off_groups.get(b, ()):
                eb_i = g["eb_idx"]
                if eb_i is None or g["eb_dist"] > 14.0:
                    continue
                if any(t in g["types"] for t in TRANSPORTS) or "NydusCanal" in g["types"]:
                    continue
                is_spec = any(u in SPECIALIST_HARASS_UNITS for u in g["types"])
                has_other_prong = any(
                    g2["size"] >= 6 and math.hypot(g2["cx"] - g["cx"], g2["cy"] - g["cy"]) >= 25.0
                    for g2 in bucket_all_groups.get(b, ())
                )
                if (not is_spec) and (not has_other_prong) and (g["size"] > 12 or g["size"] >= 0.45 * live_n):
                    continue
                st = _classify_runby_subtype(race, g["types"])
                if st is not None:
                    raw_harass.append({
                        "gl": b, "kind": HARASS_SUBTYPE_META[st][1], "subtype": st,
                        "x": g["cx"], "y": g["cy"], "eb_idx": eb_i, "priority": 3,
                    })

        # Deduplicate harass events: priority first (warp_in/nydus > drop > runby), 30s (672f) cooldown per base
        raw_harass.sort(key=lambda e: (e["priority"], e["gl"]))
        harass_events: list[dict[str, Any]] = []
        for ev in raw_harass:
            dup = False
            for kept in harass_events:
                if kept["eb_idx"] == ev["eb_idx"] and abs(kept["gl"] - ev["gl"]) <= 672:
                    # Same base within 30s: keep higher-priority / earlier event unless genuinely different subtype
                    if kept["subtype"] == ev["subtype"] or kept["kind"] != "runby" or ev["kind"] == "runby":
                        dup = True
                        break
            if not dup:
                harass_events.append(ev)
        harass_events.sort(key=lambda e: e["gl"])

        # Credit each dead enemy worker to at most ONE nearest harass event (no double counting!)
        wkills_by_ev = [0] * len(harass_events)
        for wgl, _kut, wx, wy, _ktag, _widx in worker_kills_by_killer[pid]:
            best_ei = None
            best_score = 1e9
            for ei, hev in enumerate(harass_events):
                dt = wgl - hev["gl"]
                if -140 <= dt <= 560:
                    ebx, eby = opp_ths[hev["eb_idx"]][2], opp_ths[hev["eb_idx"]][3]
                    d = min(math.hypot(wx - hev["x"], wy - hev["y"]), math.hypot(wx - ebx, wy - eby))
                    if d <= 18.0:
                        sc = abs(dt) + 20.0 * d
                        if sc < best_score:
                            best_score = sc
                            best_ei = ei
            if best_ei is not None:
                wkills_by_ev[best_ei] += 1

        # Compute Synchronized Harass Rate (+-15s of main-army pressure >= 25t away)
        harass_sync_cnt = 0
        harass_by_kind: dict[str, dict[str, int]] = {
            k: {"count": 0, "worker_kills": 0, "sync": 0}
            for k in ("drop", "warp_in", "nydus", "runby")
        }
        harass_by_subtype: dict[str, dict[str, int]] = {}
        harass_samples: list[dict[str, Any]] = []

        for ei, hev in enumerate(harass_events):
            wk = wkills_by_ev[ei]
            hev["worker_kills"] = wk
            hgl = hev["gl"]
            b0 = int(round(hgl / 240.0)) * 240
            is_sync = False
            for wb in (b0 - 240, b0, b0 + 240):
                for g in bucket_off_groups.get(wb, ()):
                    if g["size"] >= 5 and math.hypot(g["cx"] - hev["x"], g["cy"] - hev["y"]) >= 25.0:
                        if (g["eb_idx"] != hev["eb_idx"] and g["eb_dist"] <= 28.0) or g["size"] >= 7:
                            is_sync = True
                            break
                if is_sync:
                    break
            hev["is_sync"] = is_sync
            if is_sync:
                harass_sync_cnt += 1
            kd = hev["kind"]
            harass_by_kind[kd]["count"] += 1
            harass_by_kind[kd]["worker_kills"] += wk
            harass_by_kind[kd]["sync"] += 1 if is_sync else 0
            st = hev["subtype"]
            if st not in harass_by_subtype:
                harass_by_subtype[st] = {"count": 0, "worker_kills": 0, "sync": 0}
            harass_by_subtype[st]["count"] += 1
            harass_by_subtype[st]["worker_kills"] += wk
            harass_by_subtype[st]["sync"] += 1 if is_sync else 0
            if (wk >= 2 or is_sync) and len(harass_samples) < 3:
                harass_samples.append({
                    "sec": round(hgl / GAME_LOOPS_PER_SEC, 1),
                    "subtype": st,
                    "worker_kills": wk,
                    "sync": is_sync,
                    "replay": replay_name,
                })

        n_harass = len(harass_events)
        tot_harass_wk = sum(wkills_by_ev)
        harass_per_10m = round(n_harass / (active_dur_sec / 600.0), 2)
        sync_harass_pct = round(100.0 * harass_sync_cnt / n_harass, 1) if n_harass > 0 else None
        wk_per_harass = round(tot_harass_wk / n_harass, 2) if n_harass > 0 else None

        # -------------------------------------------------------------------
        # Metric 2: Reinforcement Staging / Link-Up vs. Solo Trickle Deaths
        # -------------------------------------------------------------------
        # Pre-index first-combat entry times for wave-batch detection
        first_entries: list[tuple[int, int, float, float]] = []
        for bgl, tag, ut, _bx, _by, _is_init in state.unit_births[pid]:
            if bgl >= 3360 and tag in first_combat_by_tag and _est_live_army(pid, bgl) >= 6:
                fgl, fx, fy = first_combat_by_tag[tag]
                first_entries.append((fgl, tag, fx, fy))
        first_entries.sort(key=lambda z: z[0])

        our_deaths_sorted = sorted(deaths_by_pid[pid], key=lambda z: z[0])

        reinf_total = 0
        reinf_linked = 0
        reinf_large_linked = 0
        # Two-pointer index into first_entries & our_deaths_sorted
        fe_lo = 0
        od_lo = 0
        for fgl, tag, fx, fy in first_entries:
            reinf_total += 1
            b = int(round(fgl / 240.0)) * 240
            ally_tags_12t: set[int] = set()
            for wb in (b - 240, b, b + 240):
                for t2, u2, x2, y2, _bg2 in grid_units[pid].get(wb, {}).values():
                    if t2 != tag and u2 in ARMY_REINFORCE_UNITS and math.hypot(x2 - fx, y2 - fy) <= 12.0:
                        ally_tags_12t.add(t2)
            # Also count co-arriving reinforcements in +-12s (268f) within 12t (batched staging wave!)
            while fe_lo < len(first_entries) and first_entries[fe_lo][0] < fgl - 268:
                fe_lo += 1
            co_arrivals = 0
            k = fe_lo
            while k < len(first_entries) and first_entries[k][0] <= fgl + 268:
                _fg2, t2, x2, y2 = first_entries[k]
                if t2 != tag and math.hypot(x2 - fx, y2 - fy) <= 12.0:
                    co_arrivals += 1
                    ally_tags_12t.add(t2)
                k += 1
            # Check if an ongoing meatgrinder had friendly deaths right here 2..12s BEFORE u arrived
            while od_lo < len(our_deaths_sorted) and our_deaths_sorted[od_lo][0] < fgl - 268:
                od_lo += 1
            prior_meatgrinder = False
            m = od_lo
            while m < len(our_deaths_sorted) and our_deaths_sorted[m][0] < fgl - 45:
                _dgl, _dut, ddx, ddy, _dt, _kp, _ku, _kt = our_deaths_sorted[m]
                if math.hypot(ddx - fx, ddy - fy) <= 14.0:
                    prior_meatgrinder = True
                    break
                m += 1
            # Linked at safe staging/army wave: >= 5 allies within 12t AND (batched wave >= 2 peers OR fresh engagement!)
            if len(ally_tags_12t) >= 5 and (co_arrivals >= 2 or not prior_meatgrinder):
                reinf_linked += 1
                if len(ally_tags_12t) >= 8:
                    reinf_large_linked += 1

        reinf_linked_pct = round(100.0 * reinf_linked / reinf_total, 1) if reinf_total > 0 else None
        reinf_large_linked_pct = round(100.0 * reinf_large_linked / reinf_total, 1) if reinf_total > 0 else None

        # Solo Trickle Death Rate: combat deaths (sec >= 150s, live_army >= 6) with <= 2 allies within 10t
        deaths_mid = 0
        solo_deaths = 0
        sd_lo = 0
        for dgl, dut, dx, dy, dtag, _kp, _ku, _kt in our_deaths_sorted:
            if dgl < 3360 or dut not in ARMY_REINFORCE_UNITS:
                continue
            if _est_live_army(pid, dgl) < 6:
                continue
            deaths_mid += 1
            b = int(round(dgl / 240.0)) * 240
            allies_10t: set[int] = set()
            for wb in (b - 240, b):
                for t2, u2, x2, y2, _bg2 in grid_units[pid].get(wb, {}).values():
                    if t2 != dtag and u2 in ARMY_REINFORCE_UNITS and math.hypot(x2 - dx, y2 - dy) <= 10.0:
                        allies_10t.add(t2)
            # Include simultaneous friendly deaths (+-112f) so splash wipes never false-trigger solo deaths!
            while sd_lo < len(our_deaths_sorted) and our_deaths_sorted[sd_lo][0] < dgl - 112:
                sd_lo += 1
            m = sd_lo
            while m < len(our_deaths_sorted) and our_deaths_sorted[m][0] <= dgl + 112:
                _g2, u2, x2, y2, t2, *_ = our_deaths_sorted[m]
                if t2 != dtag and u2 in ARMY_REINFORCE_UNITS and math.hypot(x2 - dx, y2 - dy) <= 10.0:
                    allies_10t.add(t2)
                m += 1
            if len(allies_10t) <= 2:
                solo_deaths += 1

        solo_trickle_pct = round(100.0 * solo_deaths / deaths_mid, 1) if deaths_mid > 0 else None

        # -------------------------------------------------------------------
        # Metric 3: Disengage, Back-Off & Regroup vs. Fight-to-Annihilation
        # -------------------------------------------------------------------
        all_combat_deaths = sorted(
            [(r[0], r[3], r[4]) for r in state.combat_death_recs], key=lambda z: z[0]
        )
        ep_raw: list[dict[str, Any]] = []
        for b in all_buckets:
            if b < 2400:
                continue
            our_u = [u for u in grid_units[pid].get(b, {}).values() if u[1] in ARMY_REINFORCE_UNITS]
            if len(our_u) < 5:
                continue
            opp_u = list(grid_units[opp_pid].get(b, {}).values())
            for cl in _cluster_active_units(our_u, radius=14.0):
                if cl["size"] < 5:
                    continue
                near_opp = [e for e in opp_u if math.hypot(e[2] - cl["cx"], e[3] - cl["cy"]) <= 18.0]
                has_death = any(
                    abs(dg - b) <= 240 and math.hypot(ddx - cl["cx"], ddy - cl["cy"]) <= 22.0
                    for dg, ddx, ddy in all_combat_deaths
                )
                if len(near_opp) < 2 and not has_death:
                    continue
                opp_tags = {e[0] for e in near_opp}
                ocx = sum(e[2] for e in near_opp) / len(near_opp) if near_opp else cl["cx"]
                ocy = sum(e[3] for e in near_opp) / len(near_opp) if near_opp else cl["cy"]
                # Merge with active episode if overlapping tags or <= 22t drift within 336f
                merged = False
                for ep in reversed(ep_raw):
                    if b - ep["end_gl"] <= 336:
                        overlap = len(cl["tags"] & ep["peak_tags"])
                        drift = math.hypot(cl["cx"] - ep["cx"], cl["cy"] - ep["cy"])
                        if overlap >= max(2, int(0.25 * min(cl["size"], len(ep["peak_tags"])))) or drift <= 22.0:
                            ep["end_gl"] = b
                            ep["cx"] = cl["cx"]
                            ep["cy"] = cl["cy"]
                            ep["ocx"] = ocx
                            ep["ocy"] = ocy
                            ep["peak_tags"] |= set(cl["tags"])
                            ep["opp_tags"] |= opp_tags
                            merged = True
                            break
                if not merged:
                    ep_raw.append({
                        "start_gl": b, "end_gl": b,
                        "cx": cl["cx"], "cy": cl["cy"],
                        "ocx": ocx, "ocy": ocy,
                        "peak_tags": set(cl["tags"]),
                        "opp_tags": set(opp_tags),
                    })

        eng_total = 0
        backoff_cnt = 0
        regroup_cnt = 0
        annihil_cnt = 0
        cont_total = 0
        cont_regroup = 0
        cont_annihil = 0

        for ep in ep_raw:
            if len(ep["peak_tags"]) < 5 or ep["start_gl"] > dur_gl - 672:
                continue
            eng_total += 1
            dead_ours = {
                t for t in ep["peak_tags"]
                if (t in state.death_gl_by_tag) and (ep["start_gl"] <= state.death_gl_by_tag[t] <= ep["end_gl"] + 224)
            }
            survivors = ep["peak_tags"] - dead_ours
            surv_pct = len(survivors) / len(ep["peak_tags"])

            opp_dead = {
                t for t in ep["opp_tags"]
                if (t in state.death_gl_by_tag) and (ep["start_gl"] <= state.death_gl_by_tag[t] <= ep["end_gl"] + 224)
            }
            opp_surv_pct = (
                (len(ep["opp_tags"]) - len(opp_dead)) / len(ep["opp_tags"])
                if ep["opp_tags"] else 1.0
            )
            is_contested = (opp_surv_pct >= 0.30) or (surv_pct <= 0.80)
            if is_contested:
                cont_total += 1

            is_annihil = surv_pct <= 0.20
            if is_annihil:
                annihil_cnt += 1
                if is_contested:
                    cont_annihil += 1
                continue

            # Check Disengage & Back-Off (surv >= 40%, genuine non-wipe contested fight, quiet break at end_gl + 240)
            if surv_pct >= 0.40 and is_contested:
                next_b = ep["end_gl"] + 240
                still_fighting = sum(
                    1 for t in survivors
                    if t in grid_units[pid].get(next_b, {})
                    and math.hypot(
                        grid_units[pid][next_b][t][2] - ep["cx"],
                        grid_units[pid][next_b][t][3] - ep["cy"],
                    ) <= 14.0
                )
                quiet_break = (still_fighting <= 0.25 * len(survivors))
                if quiet_break:
                    backoff_cnt += 1
                    # Check Regroup (+= 20% new reinforcements) & Re-engage within (end_gl+240 .. end_gl+2016]
                    re_engaged = False
                    for fb in all_buckets:
                        if fb <= ep["end_gl"] + 240:
                            continue
                        if fb > ep["end_gl"] + 2016:
                            break
                        surv_here = [
                            grid_units[pid][fb][t] for t in survivors
                            if t in grid_units[pid].get(fb, {})
                        ]
                        if len(surv_here) < max(2, int(0.30 * len(survivors))):
                            continue
                        rcx = sum(u[2] for u in surv_here) / len(surv_here)
                        rcy = sum(u[3] for u in surv_here) / len(surv_here)
                        new_reinf = sum(
                            1 for t2, u2, x2, y2, _bg2 in grid_units[pid].get(fb, {}).values()
                            if t2 not in ep["peak_tags"]
                            and u2 in ARMY_REINFORCE_UNITS
                            and math.hypot(x2 - rcx, y2 - rcy) <= 14.0
                        )
                        if new_reinf >= max(2, int(0.20 * len(survivors))):
                            re_engaged = True
                            break
                    if re_engaged:
                        regroup_cnt += 1
                        if is_contested:
                            cont_regroup += 1

        backoff_pct = round(100.0 * backoff_cnt / eng_total, 1) if eng_total > 0 else None
        regroup_pct = round(100.0 * regroup_cnt / eng_total, 1) if eng_total > 0 else None
        annihil_pct = round(100.0 * annihil_cnt / eng_total, 1) if eng_total > 0 else None
        cont_regroup_pct = round(100.0 * cont_regroup / cont_total, 1) if cont_total > 0 else None
        cont_annihil_pct = round(100.0 * cont_annihil / cont_total, 1) if cont_total > 0 else None

        # -------------------------------------------------------------------
        # Metric 4: Target Rotation / Base-Switch Tempo (same living army switching defended bases)
        # -------------------------------------------------------------------
        visits: list[tuple[int, int, float, float, frozenset[int], bool]] = []
        rotations_cnt = 0
        rotation_samples: list[dict[str, Any]] = []
        last_rot_b = -9999

        for b in all_buckets:
            if b < 2400 or b > active_end_gl:
                continue
            sec = b / GAME_LOOPS_PER_SEC
            off_gs = [
                g for g in bucket_off_groups.get(b, ())
                if g["size"] >= 4 and g["eb_idx"] is not None and g["eb_dist"] <= 30.0
            ]
            if not off_gs:
                continue
            prim = max(off_gs, key=lambda g: g["size"])
            eb_i = prim["eb_idx"]
            ebx, eby = opp_ths[eb_i][2], opp_ths[eb_i][3]
            # Check if eb_i is defended (>= 4 opp combat units nearby, >= 2 static def, or >= 1 sieged unit)
            opp_def_tags: set[int] = set()
            has_siege_def = False
            for wb in (b - 240, b, b + 240):
                for et, eu, ex, ey, _ebg in grid_units[opp_pid].get(wb, {}).values():
                    if math.hypot(ex - ebx, ey - eby) <= 22.0:
                        opp_def_tags.add(et)
                        if eu in SIEGE_DEFENDERS and math.hypot(ex - ebx, ey - eby) <= 18.0:
                            has_siege_def = True
            sdef_cnt = sum(
                1 for sr in opp_sdefs
                if sr[0] <= sec and sec <= sr[1] and math.hypot(sr[2] - ebx, sr[3] - eby) <= 16.0
            )
            is_defended = (len(opp_def_tags) >= 4) or (sdef_cnt >= 2) or has_siege_def

            if b - last_rot_b >= 448:
                for pb, peb, px, py, ptags, pdef in reversed(visits):
                    if b - pb > 1344:
                        break
                    if peb == eb_i or not pdef:
                        continue
                    # Prior base must STILL be alive (intentional rotation, not moving on after killing it!)
                    if opp_ths[peb][1] <= sec + 5.0:
                        continue
                    base_sep = math.hypot(opp_ths[peb][2] - ebx, opp_ths[peb][3] - eby)
                    move_sep = math.hypot(px - prim["cx"], py - prim["cy"])
                    if max(base_sep, move_sep) < 20.0:
                        continue
                    # Same living army rotated without dying first!
                    shared = len(prim["tags"] & ptags)
                    alive_prev = sum(
                        1 for t in ptags
                        if (t not in state.death_gl_by_tag) or (state.death_gl_by_tag[t] > b)
                    )
                    if (
                        shared >= max(2, int(0.25 * min(len(prim["tags"]), len(ptags))))
                        and alive_prev >= 0.50 * len(ptags)
                    ):
                        rotations_cnt += 1
                        last_rot_b = b
                        if len(rotation_samples) < 3:
                            rotation_samples.append({
                                "sec": round(sec, 1),
                                "arc_t": round(max(base_sep, move_sep), 1),
                                "shared_units": shared,
                                "comp": prim["types"].most_common(2),
                                "replay": replay_name,
                            })
                        break
            visits.append((b, eb_i, prim["cx"], prim["cy"], prim["tags"], is_defended))

        rot_per_10m = round(rotations_cnt / (active_dur_sec / 600.0), 2)

        out[pid] = {
            "replay": replay_name,
            "duration_sec": round(dur_sec, 1),
            "active_duration_sec": round(active_dur_sec, 1),
            "offensive_windows": off_windows,
            "multiprong_windows": multiprong_windows,
            "multiprong_attack_pct": multiprong_pct,
            "avg_active_groups": round(sum(active_group_counts_mid) / len(active_group_counts_mid), 2) if active_group_counts_mid else None,
            "harass_events_total": n_harass,
            "harass_events_per_10m": harass_per_10m,
            "harass_sync_count": harass_sync_cnt,
            "synchronized_harass_pct": sync_harass_pct,
            "harass_worker_kills": tot_harass_wk,
            "worker_kills_per_harass": wk_per_harass,
            "harass_by_kind": harass_by_kind,
            "harass_by_subtype": harass_by_subtype,
            "reinforce_total": reinf_total,
            "reinforce_linked": reinf_linked,
            "reinforce_linked_pct": reinf_linked_pct,
            "reinforce_large_linked_pct": reinf_large_linked_pct,
            "combat_deaths_mid": deaths_mid,
            "solo_trickle_deaths": solo_deaths,
            "solo_trickle_death_pct": solo_trickle_pct,
            "engagements_total": eng_total,
            "disengage_backoff_count": backoff_cnt,
            "disengage_backoff_pct": backoff_pct,
            "disengage_regroup_count": regroup_cnt,
            "disengage_and_regroup_pct": regroup_pct,
            "annihilation_count": annihil_cnt,
            "fight_to_annihilation_pct": annihil_pct,
            "contested_engagements": cont_total,
            "contested_disengage_regroup_pct": cont_regroup_pct,
            "contested_annihilation_pct": cont_annihil_pct,
            "rotations_count": rotations_cnt,
            "rotations_per_10m": rot_per_10m,
            "has_rotation": 1.0 if rotations_cnt > 0 else 0.0,
            "samples": {
                "multiprong": multiprong_samples,
                "rotations": rotation_samples,
                "harass": harass_samples,
            },
        }
    return out


def _parse_mothman_combat_replay(
    args_tuple: tuple[str, int, str, str, str, str, bool]
) -> tuple[str, list[dict[str, Any]], dict[str, Any] | None]:
    """Decode Section 5 combat battles & Section 6 army-group metrics for a single Mothman .SC2Replay (read-only)."""
    rid, our_pid, our_race, opp_race, rp_str, pylibs_str, include_army_groups = args_tuple
    if not rp_str or not os.path.exists(rp_str):
        return rid, [], None
    pylibs_dir = Path(pylibs_str)
    rdb = _get_replay_db_module(pylibs_dir)
    import mpyq  # type: ignore
    try:
        arch = mpyq.MPQArchive(rp_str)
        hdr = rdb._load_protocol(75689, pylibs_dir).decode_replay_header(
            arch.header["user_data_header"]["content"]
        )
        bb = hdr["m_version"]["m_baseBuild"]
        if bb < COMBAT_MIN_BASE_BUILD:
            return rid, [], None
        proto = rdb._load_protocol(bb, pylibs_dir)
        trk_bytes = arch.read_file("replay.tracker.events")
        if not trk_bytes:
            return rid, [], None

        st = _TrackerCombatState()
        for ev in proto.decode_replay_tracker_events(trk_bytes):
            et = ev.get("_event", "")
            gl = int(ev.get("_gameloop", 0))
            if et == "NNet.Replay.Tracker.SUnitInitEvent":
                st.on_unit_appear(
                    gl, int(ev.get("m_controlPlayerId") or 0),
                    int(ev.get("m_unitTagIndex", 0)), int(ev.get("m_unitTagRecycle", 0)),
                    rdb._decode_str(ev.get("m_unitTypeName", b"")),
                    float(ev.get("m_x", 0.0)), float(ev.get("m_y", 0.0)), True,
                )
            elif et == "NNet.Replay.Tracker.SUnitBornEvent":
                st.on_unit_appear(
                    gl, int(ev.get("m_controlPlayerId") or 0),
                    int(ev.get("m_unitTagIndex", 0)), int(ev.get("m_unitTagRecycle", 0)),
                    rdb._decode_str(ev.get("m_unitTypeName", b"")),
                    float(ev.get("m_x", 0.0)), float(ev.get("m_y", 0.0)), False,
                )
            elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
                st.on_type_change(
                    gl, int(ev.get("m_unitTagIndex", 0)), int(ev.get("m_unitTagRecycle", 0)),
                    rdb._decode_str(ev.get("m_unitTypeName", b"")),
                )
            elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
                st.on_died(
                    gl, int(ev.get("m_unitTagIndex", 0)),
                    ev.get("m_x"), ev.get("m_y"),
                    ev.get("m_killerPlayerId"), ev.get("m_killerUnitTagIndex"), ev.get("m_killerUnitTagRecycle"),
                )
            elif et == "NNet.Replay.Tracker.SUnitPositionsEvent":
                st.on_positions(gl, int(ev.get("m_firstUnitIndex", 0)), ev.get("m_items") or [])

        rname = os.path.basename(rp_str)
        battles = compute_combat_battles_from_tracker_state(
            st.deaths, st.combat_snaps, st.th_pos, st.all_bldgs_pts,
            target_pids=(our_pid,),
            replay_name=rname,
        ).get(our_pid, [])
        ag = None
        if include_army_groups:
            opp_pid = 2 if our_pid == 1 else 1
            ag = compute_army_group_metrics_from_tracker_state(
                st, {our_pid: our_race, opp_pid: opp_race},
                target_pids=(our_pid,),
                replay_name=rname,
            ).get(our_pid)
        return rid, battles, ag
    except Exception:
        return rid, [], None

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

def _parse_single_pro_replay(args_tuple: tuple[str, str, float, bool, bool]) -> list[dict[str, Any]]:
    rp_str, pylibs_str, min_dur_sec, include_combat, include_army_groups = args_tuple
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

        # Optional LotV combat positioning & army-group state (single linear pass)
        track_combat = bool((include_combat or include_army_groups) and bb >= COMBAT_MIN_BASE_BUILD)
        cstate = _TrackerCombatState() if track_combat else None

        for ev in proto.decode_replay_tracker_events(trk_bytes):
            etype = ev.get("_event", "")
            loop = int(ev.get("_gameloop", 0))
            sec = loop / GAME_LOOPS_PER_SEC

            if etype == "NNet.Replay.Tracker.SUnitInitEvent":
                pid = int(ev.get("m_controlPlayerId") or 0)
                if pid not in race_by_pid:
                    continue
                ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                idx_u = int(ev.get("m_unitTagIndex", 0))
                rec_u = int(ev.get("m_unitTagRecycle", 0))
                tag = (idx_u << 18) | rec_u
                tag_owner[tag] = pid
                x, y = float(ev.get("m_x", 0.0)), float(ev.get("m_y", 0.0))
                if cstate is not None:
                    cstate.on_unit_appear(loop, pid, idx_u, rec_u, ut, x, y, True)
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
                idx_u = int(ev.get("m_unitTagIndex", 0))
                rec_u = int(ev.get("m_unitTagRecycle", 0))
                tag = (idx_u << 18) | rec_u
                tag_owner[tag] = pid
                x, y = float(ev.get("m_x", 0.0)), float(ev.get("m_y", 0.0))
                if cstate is not None:
                    cstate.on_unit_appear(loop, pid, idx_u, rec_u, ut, x, y, False)
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
                idx_u = int(ev.get("m_unitTagIndex", 0))
                rec_u = int(ev.get("m_unitTagRecycle", 0))
                tag = (idx_u << 18) | rec_u
                pid = tag_owner.get(tag)
                ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                if cstate is not None:
                    cstate.on_type_change(loop, idx_u, rec_u, ut)
                if pid in race_by_pid:
                    if ut in ("OrbitalCommand", "Lair", "Hive", "LurkerMP", "Ravager", "Baneling"):
                        morphs[pid][ut].append(sec)

            elif etype == "NNet.Replay.Tracker.SUnitDiedEvent":
                if cstate is not None:
                    cstate.on_died(
                        loop, int(ev.get("m_unitTagIndex", 0)),
                        ev.get("m_x"), ev.get("m_y"),
                        ev.get("m_killerPlayerId"), ev.get("m_killerUnitTagIndex"), ev.get("m_killerUnitTagRecycle"),
                    )

            elif etype == "NNet.Replay.Tracker.SUnitPositionsEvent":
                if cstate is not None:
                    cstate.on_positions(loop, int(ev.get("m_firstUnitIndex", 0)), ev.get("m_items") or [])

            elif etype == "NNet.Replay.Tracker.SUpgradeEvent":
                pid = int(ev.get("m_playerId") or 0)
                if pid in race_by_pid:
                    uname = rdb._decode_str(ev.get("m_upgradeTypeName", b""))
                    if uname and uname not in upgrades[pid]:
                        upgrades[pid][uname] = sec

        rname = os.path.basename(rp_str)
        combat_by_pid: dict[int, list[dict[str, Any]]] = {1: [], 2: []}
        army_group_by_pid: dict[int, dict[str, Any]] = {}
        if cstate is not None:
            if include_combat and cstate.deaths and cstate.combat_snaps:
                combat_by_pid = compute_combat_battles_from_tracker_state(
                    cstate.deaths, cstate.combat_snaps, cstate.th_pos, cstate.all_bldgs_pts,
                    target_pids=(1, 2),
                    replay_name=rname,
                )
            if include_army_groups:
                army_group_by_pid = compute_army_group_metrics_from_tracker_state(
                    cstate, race_by_pid, target_pids=(1, 2), replay_name=rname,
                )

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
                "combat_battles": combat_by_pid.get(pid, []),
                "army_group": army_group_by_pid.get(pid),
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
    include_combat: bool = True,
    include_army_groups: bool = True,
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, list[dict[str, Any]]], int]:
    """Parse pro_corpus replays in parallel, capping balanced spatial/timing samples AND collecting LotV combat + army-group metrics."""
    replays = sorted(pro_dir.glob("*.SC2Replay"))
    if not replays:
        return {mu: [] for mu in MATCHUPS}, {mu: [] for mu in MATCHUPS}, 0

    by_mu: dict[str, list[dict[str, Any]]] = {mu: [] for mu in MATCHUPS}
    combat_by_mu: dict[str, list[dict[str, Any]]] = {mu: [] for mu in MATCHUPS}
    scanned = 0
    work = [(str(rp), str(pylibs_dir), min_dur_sec, include_combat, include_army_groups) for rp in replays]

    with concurrent.futures.ProcessPoolExecutor(max_workers=max(1, jobs)) as ex:
        for batch in ex.map(_parse_single_pro_replay, work, chunksize=8):
            scanned += 1
            for rec in batch:
                mu = rec["matchup"]
                if mu in by_mu and len(by_mu[mu]) < max_per_matchup:
                    by_mu[mu].append(rec)
                if (
                    (include_combat or include_army_groups)
                    and mu in combat_by_mu
                    and (rec.get("combat_battles") or (not include_combat and rec.get("army_group")))
                    and len(combat_by_mu[mu]) < max_per_matchup
                ):
                    combat_by_mu[mu].append(rec)
            if all(len(by_mu[mu]) >= max_per_matchup for mu in MATCHUPS) and (
                not (include_combat or include_army_groups)
                or all(len(combat_by_mu[mu]) >= max_per_matchup for mu in MATCHUPS)
            ):
                break
    return by_mu, combat_by_mu, scanned


# ---------------------------------------------------------------------------
# Mothman Read-Only SQLite Loader (iter45..iter57+)
# ---------------------------------------------------------------------------

def load_mothman_sqlite(
    db_path: Path,
    run_prefixes: tuple[str, ...],
    min_dur_sec: float = 250.0,
    pylibs_dir: Path | None = None,
    jobs: int = 8,
    include_combat: bool = True,
    include_army_groups: bool = True,
) -> tuple[dict[str, list[dict[str, Any]]], int]:
    """Load Mothman spatial + timing (+ optional combat positioning & army-group) records from read-only `arena_replays.sqlite`."""
    p = os.path.abspath(os.path.expanduser(str(db_path)))
    conn = sqlite3.connect(Path(p).as_uri() + "?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        like_clauses = " OR ".join("m.run_id LIKE ?" for _ in run_prefixes)
        like_params = [f"%{pref}%" for pref in run_prefixes]
        mrows = conn.execute(
            f"""
            SELECT m.replay_id, m.replay_path, m.actual_race, m.our_race, m.opp_race, m.matchup,
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

        combat_by_rid: dict[str, list[dict[str, Any]]] = {}
        ag_by_rid: dict[str, dict[str, Any] | None] = {}
        if (include_combat or include_army_groups) and pylibs_dir is not None:
            cwork = [
                (
                    str(r["replay_id"]),
                    int(r["our_player_id"]),
                    str(r["actual_race"] if r["actual_race"] in RACES else r["our_race"]),
                    str(r["opp_race"]),
                    str(r["replay_path"] or ""),
                    str(pylibs_dir),
                    include_army_groups,
                )
                for r in mrows
                if r["replay_path"] and os.path.exists(str(r["replay_path"]))
            ]
            if cwork:
                with concurrent.futures.ProcessPoolExecutor(max_workers=max(1, jobs)) as ex:
                    for rid, battles, ag in ex.map(_parse_mothman_combat_replay, cwork, chunksize=4):
                        combat_by_rid[rid] = battles if include_combat else []
                        ag_by_rid[rid] = ag

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
                "combat_battles": combat_by_rid.get(str(m["replay_id"]), []),
                "army_group": ag_by_rid.get(str(m["replay_id"])),
            })
        return by_mu, len(mrows)
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Aggregation & Report Rendering
# ---------------------------------------------------------------------------

def _agg_combat_subset(bs: list[dict[str, Any]], n_games: int) -> dict[str, Any]:
    if not bs:
        return {
            "n_games": n_games,
            "n_battles": 0,
            "med_engaged_units": None,
            "frontage_width_t": None,
            "formation_depth_t": None,
            "width_to_depth_ratio": None,
            "concave_wrap_score": None,
            "front_to_rear_separation_t": None,
            "role_inversion_pct": None,
            "caster_exposed_pct": None,
            "in_range_pct": None,
            "n_splash_battles": 0,
            "splash_nn_t": None,
            "max_units_in_2t_radius": None,
            "splash_clump_pct": None,
            "fighting_in_choke_pct": None,
            "fighting_uphill_pct": None,
        }

    def _med(k: str, prec: int = 2) -> float | None:
        xs = [float(b[k]) for b in bs if b.get(k) is not None]
        return round(statistics.median(xs), prec) if xs else None

    def _mean(k: str, prec: int = 2) -> float | None:
        xs = [float(b[k]) for b in bs if b.get(k) is not None]
        return round(sum(xs) / len(xs), prec) if xs else None

    def _rate(k: str) -> float | None:
        xs = [float(b[k]) for b in bs if b.get(k) is not None]
        return round(100.0 * sum(xs) / len(xs), 1) if xs else None

    splash_bs = [b for b in bs if b.get("splash_nn_t") is not None]
    return {
        "n_games": n_games,
        "n_battles": len(bs),
        "med_engaged_units": _med("n_our", 1),
        "frontage_width_t": _med("frontage_width_t", 2),
        "formation_depth_t": _med("formation_depth_t", 2),
        "width_to_depth_ratio": _med("width_to_depth_ratio", 2),
        "concave_wrap_score": _mean("concave_wrap_score", 2),
        "front_to_rear_separation_t": _med("front_to_rear_separation_t", 2),
        "role_inversion_pct": _rate("role_inversion"),
        "caster_exposed_pct": _rate("caster_exposed"),
        "in_range_pct": _mean("in_range_pct", 1),
        "n_splash_battles": len(splash_bs),
        "splash_nn_t": _med("splash_nn_t", 2),
        "max_units_in_2t_radius": _mean("max_units_in_2t_radius", 2),
        "splash_clump_pct": _mean("splash_clump_pct", 1),
        "fighting_in_choke_pct": _rate("fighting_in_choke"),
        "fighting_uphill_pct": _rate("fighting_uphill"),
    }


def aggregate_combat_positioning(records: list[dict[str, Any]]) -> dict[str, Any]:
    """Aggregate combat positioning metrics across all battles (n>=4) and size-matched mid/large battles (n>=10)."""
    games_with_battles = [r for r in records if r.get("combat_battles")]
    all_bs = [b for r in games_with_battles for b in r["combat_battles"]]
    large_bs = [b for b in all_bs if b["n_our"] >= 10]
    summary = _agg_combat_subset(all_bs, len(games_with_battles))
    summary["large_battle_pct"] = round(100.0 * len(large_bs) / len(all_bs), 1) if all_bs else None
    summary["large_battles"] = _agg_combat_subset(large_bs, len(games_with_battles))
    return summary


def _extract_worst_battles(records: list[dict[str, Any]], limit: int = 3) -> dict[str, list[dict[str, Any]]]:
    """Return concrete worst Mothman battles by failure mode for direct tactics actionability."""
    bs = [b for r in records for b in (r.get("combat_battles") or [])]
    convex = sorted(
        [b for b in bs if b.get("concave_wrap_score") is not None and b["n_our"] >= 6],
        key=lambda x: x["concave_wrap_score"],
    )[:limit]
    inverted = sorted(
        [b for b in bs if b.get("role_inversion") == 1.0 and b.get("front_to_rear_separation_t") is not None],
        key=lambda x: x["front_to_rear_separation_t"],
    )[:limit]
    choke_uphill = sorted(
        [b for b in bs if b.get("fighting_uphill") == 1.0 or b.get("fighting_in_choke") == 1.0],
        key=lambda x: (-x["fighting_uphill"], x["width_to_depth_ratio"]),
    )[:limit]
    low_util = sorted(
        [b for b in bs if b.get("in_range_pct") is not None and b["n_our"] >= 6],
        key=lambda x: x["in_range_pct"],
    )[:limit]
    return {
        "convex_column": convex,
        "role_inversion": inverted,
        "choke_or_uphill": choke_uphill,
        "low_firing_utilization": low_util,
    }

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


def _build_combat_deltas(pc: dict[str, Any], mc: dict[str, Any]) -> dict[str, Any]:
    return {
        "med_engaged_units": _diff_opt(mc.get("med_engaged_units"), pc.get("med_engaged_units"), 1),
        "large_battle_pct": _diff_opt(mc.get("large_battle_pct"), pc.get("large_battle_pct"), 1),
        "frontage_width_t": _diff_opt(mc.get("frontage_width_t"), pc.get("frontage_width_t"), 2),
        "formation_depth_t": _diff_opt(mc.get("formation_depth_t"), pc.get("formation_depth_t"), 2),
        "width_to_depth_ratio": _diff_opt(mc.get("width_to_depth_ratio"), pc.get("width_to_depth_ratio"), 2),
        "concave_wrap_score": _diff_opt(mc.get("concave_wrap_score"), pc.get("concave_wrap_score"), 2),
        "front_to_rear_separation_t": _diff_opt(mc.get("front_to_rear_separation_t"), pc.get("front_to_rear_separation_t"), 2),
        "role_inversion_pct": _diff_opt(mc.get("role_inversion_pct"), pc.get("role_inversion_pct"), 1),
        "caster_exposed_pct": _diff_opt(mc.get("caster_exposed_pct"), pc.get("caster_exposed_pct"), 1),
        "in_range_pct": _diff_opt(mc.get("in_range_pct"), pc.get("in_range_pct"), 1),
        "splash_nn_t": _diff_opt(mc.get("splash_nn_t"), pc.get("splash_nn_t"), 2),
        "max_units_in_2t_radius": _diff_opt(mc.get("max_units_in_2t_radius"), pc.get("max_units_in_2t_radius"), 2),
        "splash_clump_pct": _diff_opt(mc.get("splash_clump_pct"), pc.get("splash_clump_pct"), 1),
        "fighting_in_choke_pct": _diff_opt(mc.get("fighting_in_choke_pct"), pc.get("fighting_in_choke_pct"), 1),
        "fighting_uphill_pct": _diff_opt(mc.get("fighting_uphill_pct"), pc.get("fighting_uphill_pct"), 1),
    }


def aggregate_army_group_positioning(race: str, records: list[dict[str, Any]]) -> dict[str, Any]:
    """Aggregate Section 6 macro army-group positioning, rotation, regroup, multiprong & drop/runby taxonomy."""
    ags = [r["army_group"] for r in records if r.get("army_group") is not None]
    n_games = len(ags)
    if n_games == 0:
        return {
            "n_games": 0,
            "total_game_10m": 0.0,
            "offensive_windows": 0,
            "multiprong_attack_pct": None,
            "avg_active_groups": None,
            "harass_events_total": 0,
            "harass_events_per_10m": None,
            "synchronized_harass_pct": None,
            "harass_worker_kills": 0,
            "worker_kills_per_harass": None,
            "worker_kills_harass_per_10m": None,
            "reinforce_total": 0,
            "reinforce_linked_pct": None,
            "reinforce_large_linked_pct": None,
            "combat_deaths_mid": 0,
            "solo_trickle_death_pct": None,
            "engagements_total": 0,
            "disengage_backoff_pct": None,
            "disengage_and_regroup_pct": None,
            "fight_to_annihilation_pct": None,
            "contested_engagements": 0,
            "contested_disengage_regroup_pct": None,
            "contested_annihilation_pct": None,
            "rotations_total": 0,
            "rotations_per_game": None,
            "rotations_per_10m": None,
            "games_with_rotation_pct": None,
            "harass_by_kind": {},
            "harass_by_subtype": {},
        }

    tot_10m = sum(float(a.get("active_duration_sec") or a["duration_sec"]) for a in ags) / 600.0
    off_w = sum(int(a["offensive_windows"]) for a in ags)
    mp_w = sum(int(a["multiprong_windows"]) for a in ags)
    har_tot = sum(int(a["harass_events_total"]) for a in ags)
    har_sync = sum(int(a["harass_sync_count"]) for a in ags)
    har_wk = sum(int(a["harass_worker_kills"]) for a in ags)

    reinf_tot = sum(int(a["reinforce_total"]) for a in ags)
    reinf_lnk = sum(int(a["reinforce_linked"]) for a in ags)
    reinf_large_vals = [
        float(a["reinforce_large_linked_pct"]) * int(a["reinforce_total"]) / 100.0
        for a in ags
        if a.get("reinforce_large_linked_pct") is not None and a["reinforce_total"] > 0
    ]
    deaths_mid = sum(int(a["combat_deaths_mid"]) for a in ags)
    solo_d = sum(int(a["solo_trickle_deaths"]) for a in ags)

    eng_tot = sum(int(a["engagements_total"]) for a in ags)
    bo_tot = sum(int(a["disengage_backoff_count"]) for a in ags)
    rg_tot = sum(int(a["disengage_regroup_count"]) for a in ags)
    an_tot = sum(int(a["annihilation_count"]) for a in ags)
    cont_tot = sum(int(a["contested_engagements"]) for a in ags)
    cont_rg = sum(
        round(float(a["contested_disengage_regroup_pct"]) * int(a["contested_engagements"]) / 100.0)
        for a in ags
        if a.get("contested_disengage_regroup_pct") is not None and a["contested_engagements"] > 0
    )
    cont_an = sum(
        round(float(a["contested_annihilation_pct"]) * int(a["contested_engagements"]) / 100.0)
        for a in ags
        if a.get("contested_annihilation_pct") is not None and a["contested_engagements"] > 0
    )

    rot_tot = sum(int(a["rotations_count"]) for a in ags)
    games_w_rot = sum(1 for a in ags if a["rotations_count"] > 0)

    # Aggregate harass by kind & subtype
    kind_agg: dict[str, dict[str, Any]] = {}
    for k in ("drop", "warp_in", "nydus", "runby"):
        cnt = sum(int((a.get("harass_by_kind") or {}).get(k, {}).get("count", 0)) for a in ags)
        wk = sum(int((a.get("harass_by_kind") or {}).get(k, {}).get("worker_kills", 0)) for a in ags)
        sy = sum(int((a.get("harass_by_kind") or {}).get(k, {}).get("sync", 0)) for a in ags)
        g_adopt = sum(1 for a in ags if int((a.get("harass_by_kind") or {}).get(k, {}).get("count", 0)) > 0)
        kind_agg[k] = {
            "count": cnt,
            "per_10m": round(cnt / tot_10m, 2) if tot_10m > 0 else 0.0,
            "adopt_game_pct": round(100.0 * g_adopt / n_games, 1),
            "worker_kills": wk,
            "worker_kills_per_event": round(wk / cnt, 2) if cnt > 0 else None,
            "sync_pct": round(100.0 * sy / cnt, 1) if cnt > 0 else None,
        }

    subtype_agg: dict[str, dict[str, Any]] = {}
    for st, (st_race, st_kind, st_label) in HARASS_SUBTYPE_META.items():
        if st_race != race:
            continue
        cnt = sum(int((a.get("harass_by_subtype") or {}).get(st, {}).get("count", 0)) for a in ags)
        wk = sum(int((a.get("harass_by_subtype") or {}).get(st, {}).get("worker_kills", 0)) for a in ags)
        sy = sum(int((a.get("harass_by_subtype") or {}).get(st, {}).get("sync", 0)) for a in ags)
        g_adopt = sum(1 for a in ags if int((a.get("harass_by_subtype") or {}).get(st, {}).get("count", 0)) > 0)
        subtype_agg[st] = {
            "label": st_label,
            "kind": st_kind,
            "count": cnt,
            "per_10m": round(cnt / tot_10m, 2) if tot_10m > 0 else 0.0,
            "adopt_game_pct": round(100.0 * g_adopt / n_games, 1),
            "worker_kills": wk,
            "worker_kills_per_event": round(wk / cnt, 2) if cnt > 0 else None,
            "sync_pct": round(100.0 * sy / cnt, 1) if cnt > 0 else None,
        }

    return {
        "n_games": n_games,
        "total_game_10m": round(tot_10m, 2),
        "offensive_windows": off_w,
        "multiprong_attack_pct": round(100.0 * mp_w / off_w, 1) if off_w > 0 else None,
        "avg_active_groups": _avg_opt([a.get("avg_active_groups") for a in ags], 2),
        "harass_events_total": har_tot,
        "harass_events_per_10m": round(har_tot / tot_10m, 2) if tot_10m > 0 else None,
        "synchronized_harass_pct": round(100.0 * har_sync / har_tot, 1) if har_tot > 0 else None,
        "harass_worker_kills": har_wk,
        "worker_kills_per_harass": round(har_wk / har_tot, 2) if har_tot > 0 else None,
        "worker_kills_harass_per_10m": round(har_wk / tot_10m, 2) if tot_10m > 0 else None,
        "reinforce_total": reinf_tot,
        "reinforce_linked_pct": round(100.0 * reinf_lnk / reinf_tot, 1) if reinf_tot > 0 else None,
        "reinforce_large_linked_pct": round(100.0 * sum(reinf_large_vals) / reinf_tot, 1) if reinf_tot > 0 else None,
        "combat_deaths_mid": deaths_mid,
        "solo_trickle_death_pct": round(100.0 * solo_d / deaths_mid, 1) if deaths_mid > 0 else None,
        "engagements_total": eng_tot,
        "disengage_backoff_pct": round(100.0 * bo_tot / eng_tot, 1) if eng_tot > 0 else None,
        "disengage_and_regroup_pct": round(100.0 * rg_tot / eng_tot, 1) if eng_tot > 0 else None,
        "fight_to_annihilation_pct": round(100.0 * an_tot / eng_tot, 1) if eng_tot > 0 else None,
        "contested_engagements": cont_tot,
        "contested_disengage_regroup_pct": round(100.0 * cont_rg / cont_tot, 1) if cont_tot > 0 else None,
        "contested_annihilation_pct": round(100.0 * cont_an / cont_tot, 1) if cont_tot > 0 else None,
        "rotations_total": rot_tot,
        "rotations_per_game": round(rot_tot / n_games, 2),
        "rotations_per_10m": round(rot_tot / tot_10m, 2) if tot_10m > 0 else None,
        "games_with_rotation_pct": round(100.0 * games_w_rot / n_games, 1),
        "harass_by_kind": kind_agg,
        "harass_by_subtype": subtype_agg,
    }


def _build_army_group_deltas(pa: dict[str, Any], ma: dict[str, Any]) -> dict[str, Any]:
    return {
        "multiprong_attack_pct": _diff_opt(ma.get("multiprong_attack_pct"), pa.get("multiprong_attack_pct"), 1),
        "synchronized_harass_pct": _diff_opt(ma.get("synchronized_harass_pct"), pa.get("synchronized_harass_pct"), 1),
        "reinforce_linked_pct": _diff_opt(ma.get("reinforce_linked_pct"), pa.get("reinforce_linked_pct"), 1),
        "solo_trickle_death_pct": _diff_opt(ma.get("solo_trickle_death_pct"), pa.get("solo_trickle_death_pct"), 1),
        "disengage_backoff_pct": _diff_opt(ma.get("disengage_backoff_pct"), pa.get("disengage_backoff_pct"), 1),
        "disengage_and_regroup_pct": _diff_opt(ma.get("disengage_and_regroup_pct"), pa.get("disengage_and_regroup_pct"), 1),
        "fight_to_annihilation_pct": _diff_opt(ma.get("fight_to_annihilation_pct"), pa.get("fight_to_annihilation_pct"), 1),
        "contested_disengage_regroup_pct": _diff_opt(ma.get("contested_disengage_regroup_pct"), pa.get("contested_disengage_regroup_pct"), 1),
        "contested_annihilation_pct": _diff_opt(ma.get("contested_annihilation_pct"), pa.get("contested_annihilation_pct"), 1),
        "rotations_per_game": _diff_opt(ma.get("rotations_per_game"), pa.get("rotations_per_game"), 2),
        "rotations_per_10m": _diff_opt(ma.get("rotations_per_10m"), pa.get("rotations_per_10m"), 2),
        "harass_events_per_10m": _diff_opt(ma.get("harass_events_per_10m"), pa.get("harass_events_per_10m"), 2),
        "worker_kills_per_harass": _diff_opt(ma.get("worker_kills_per_harass"), pa.get("worker_kills_per_harass"), 2),
    }


def _extract_army_group_examples(
    pro_recs: list[dict[str, Any]], mm_recs: list[dict[str, Any]], limit: int = 3
) -> dict[str, Any]:
    """Extract worst Mothman operational games (trickle / annihilation / zero-multiprong) & top Pro benchmarks."""
    mm_ags = [r["army_group"] for r in mm_recs if r.get("army_group") is not None]
    pro_ags = [r["army_group"] for r in pro_recs if r.get("army_group") is not None]

    worst_trickle = sorted(
        [a for a in mm_ags if a.get("solo_trickle_death_pct") is not None and a["combat_deaths_mid"] >= 10],
        key=lambda x: -x["solo_trickle_death_pct"],
    )[:limit]
    worst_annihil = sorted(
        [a for a in mm_ags if a.get("fight_to_annihilation_pct") is not None and a["engagements_total"] >= 2],
        key=lambda x: (-x["fight_to_annihilation_pct"], -x["engagements_total"]),
    )[:limit]
    pro_top_mp = sorted(
        [a for a in pro_ags if a.get("multiprong_attack_pct") is not None and a["offensive_windows"] >= 6],
        key=lambda x: (-x["multiprong_attack_pct"], -x["rotations_count"]),
    )[:limit]
    pro_top_harass = sorted(
        [s for a in pro_ags for s in ((a.get("samples") or {}).get("harass") or [])],
        key=lambda x: (-x["worker_kills"], -int(bool(x["sync"]))),
    )[:limit]

    def _slim(a: dict[str, Any]) -> dict[str, Any]:
        return {
            "replay": a["replay"],
            "duration_sec": a["duration_sec"],
            "multiprong_attack_pct": a["multiprong_attack_pct"],
            "reinforce_linked_pct": a["reinforce_linked_pct"],
            "solo_trickle_death_pct": a["solo_trickle_death_pct"],
            "disengage_and_regroup_pct": a["disengage_and_regroup_pct"],
            "fight_to_annihilation_pct": a["fight_to_annihilation_pct"],
            "rotations_count": a["rotations_count"],
            "harass_events_total": a["harass_events_total"],
            "harass_worker_kills": a["harass_worker_kills"],
            "combat_deaths_mid": a["combat_deaths_mid"],
            "engagements_total": a["engagements_total"],
        }

    return {
        "mothman_worst_trickle": [_slim(a) for a in worst_trickle],
        "mothman_worst_annihilation": [_slim(a) for a in worst_annihil],
        "pro_top_multiprong": [_slim(a) for a in pro_top_mp],
        "pro_top_harass_events": pro_top_harass,
    }


def build_comparison_report(
    pro_by_mu: dict[str, list[dict[str, Any]]],
    mm_by_mu: dict[str, list[dict[str, Any]]],
    meta: dict[str, Any],
    pro_combat_by_mu: dict[str, list[dict[str, Any]]] | None = None,
) -> dict[str, Any]:
    pro_c_map = pro_combat_by_mu if pro_combat_by_mu is not None else pro_by_mu
    by_matchup: dict[str, Any] = {}
    for mu in MATCHUPS:
        race = {"P": "Protoss", "T": "Terran", "Z": "Zerg"}[mu[0]]
        p_agg = aggregate_side(race, pro_by_mu.get(mu, []))
        m_agg = aggregate_side(race, mm_by_mu.get(mu, []))
        p_comb = aggregate_combat_positioning(pro_c_map.get(mu, []))
        m_comb = aggregate_combat_positioning(mm_by_mu.get(mu, []))
        p_ag = aggregate_army_group_positioning(race, pro_c_map.get(mu, []))
        m_ag = aggregate_army_group_positioning(race, mm_by_mu.get(mu, []))
        p_agg["combat_positioning"] = p_comb
        m_agg["combat_positioning"] = m_comb
        p_agg["army_group_positioning"] = p_ag
        m_agg["army_group_positioning"] = m_ag

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
            "combat_deltas": _build_combat_deltas(p_comb, m_comb),
            "army_group_deltas": _build_army_group_deltas(p_ag, m_ag),
            "timing_comparison": timing_deltas,
        }

    # Also build per-race rollups
    by_race: dict[str, Any] = {}
    worst_combat_positioning: dict[str, Any] = {}
    army_group_examples: dict[str, Any] = {}
    for race in RACES:
        mus = [mu for mu in MATCHUPS if mu[0] == RACE_LETTER[race]]
        p_all = [r for mu in mus for r in pro_by_mu.get(mu, [])]
        p_comb_all = [r for mu in mus for r in pro_c_map.get(mu, [])]
        m_all = [r for mu in mus for r in mm_by_mu.get(mu, [])]
        p_r_agg = aggregate_side(race, p_all)
        m_r_agg = aggregate_side(race, m_all)
        p_r_comb = aggregate_combat_positioning(p_comb_all)
        m_r_comb = aggregate_combat_positioning(m_all)
        p_r_ag = aggregate_army_group_positioning(race, p_comb_all)
        m_r_ag = aggregate_army_group_positioning(race, m_all)
        p_r_agg["combat_positioning"] = p_r_comb
        m_r_agg["combat_positioning"] = m_r_comb
        p_r_agg["army_group_positioning"] = p_r_ag
        m_r_agg["army_group_positioning"] = m_r_ag
        by_race[race] = {
            "pro": p_r_agg,
            "mothman": m_r_agg,
            "combat_deltas": _build_combat_deltas(p_r_comb, m_r_comb),
            "army_group_deltas": _build_army_group_deltas(p_r_ag, m_r_ag),
        }
        worst_combat_positioning[race] = _extract_worst_battles(m_all, limit=3)
        army_group_examples[race] = _extract_army_group_examples(p_comb_all, m_all, limit=3)

    return {
        "meta": meta,
        "by_race": by_race,
        "by_matchup": by_matchup,
        "worst_combat_positioning": worst_combat_positioning,
        "army_group_examples": army_group_examples,
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

    # Section 5: Combat Concave, Unit Layout & Positioning vs. Pro (All Combats)
    by_race = report.get("by_race") or {}
    has_combat = any(
        ((by_race.get(r, {}).get("mothman", {}).get("combat_positioning") or {}).get("n_battles", 0) > 0)
        or ((by_race.get(r, {}).get("pro", {}).get("combat_positioning") or {}).get("n_battles", 0) > 0)
        for r in RACES
    )
    if has_combat:
        lines.append("## 5. Combat Concave, Unit Layout & Positioning vs. Pro (All Combats)")
        lines.append("")
        lines.append(
            "Measured at peak engagement snapshots across all LotV battles (`n_our >= 4, n_opp >= 3`) "
            "from `SUnitPositionsEvent` + `SUnitDiedEvent`. Positive `Concave Wrap` indicates flank wings "
            "curving forward around the enemy; negative indicates a convex column/spearhead. "
            "Positive `Role Sep` indicates Frontline ahead of Midline/Rear."
        )
        lines.append("")
        lines.append("### 5.1 Per-Race Combat Positioning (All Combats `n>=4` and Size-Matched Mid/Large `n>=10`)")
        lines.append("")
        lines.append(
            "| Race (Pro/Us Battles) | Med Pack (Pro/Us) | Width / Depth (Pro vs Us) | W:D Ratio (Pro/Us) | "
            "Concave Wrap (Pro/Us) | Role Sep / Inv% (Pro vs Us) | Caster Exp% (Pro/Us) | In-Range% (Pro/Us) | "
            "Splash NN / 2t Clump% (Pro vs Us) | Choke% / Uphill% (Pro vs Us) |"
        )
        lines.append("|---|---:|---|---:|---:|---|---:|---:|---|---|")

        def _comb_row(lbl: str, pc: dict[str, Any], mc: dict[str, Any]) -> str:
            return (
                f"| **{lbl}** ({pc['n_battles']}/{mc['n_battles']}) "
                f"| {_fmt_num(pc['med_engaged_units'],'',1)} / {_fmt_num(mc['med_engaged_units'],'',1)} "
                f"| {_fmt_num(pc['frontage_width_t'],'t')} / {_fmt_num(pc['formation_depth_t'],'t')} vs "
                f"{_fmt_num(mc['frontage_width_t'],'t')} / {_fmt_num(mc['formation_depth_t'],'t')} "
                f"| {_fmt_num(pc['width_to_depth_ratio'],'',2)} / {_fmt_num(mc['width_to_depth_ratio'],'',2)} "
                f"| {_fmt_delta(pc['concave_wrap_score'],'t',2)} / {_fmt_delta(mc['concave_wrap_score'],'t',2)} "
                f"| {_fmt_delta(pc['front_to_rear_separation_t'],'t',1)} ({_fmt_num(pc['role_inversion_pct'],'%')}) vs "
                f"{_fmt_delta(mc['front_to_rear_separation_t'],'t',1)} ({_fmt_num(mc['role_inversion_pct'],'%')}) "
                f"| {_fmt_num(pc['caster_exposed_pct'],'%')} / {_fmt_num(mc['caster_exposed_pct'],'%')} "
                f"| {_fmt_num(pc['in_range_pct'],'%')} / {_fmt_num(mc['in_range_pct'],'%')} "
                f"| {_fmt_num(pc['splash_nn_t'],'t')} ({_fmt_num(pc['splash_clump_pct'],'%')}) vs "
                f"{_fmt_num(mc['splash_nn_t'],'t')} ({_fmt_num(mc['splash_clump_pct'],'%')}) "
                f"| {_fmt_num(pc['fighting_in_choke_pct'],'%')} / {_fmt_num(pc['fighting_uphill_pct'],'%')} vs "
                f"{_fmt_num(mc['fighting_in_choke_pct'],'%')} / {_fmt_num(mc['fighting_uphill_pct'],'%')} |"
            )

        for race in RACES:
            pc = by_race[race]["pro"]["combat_positioning"]
            mc = by_race[race]["mothman"]["combat_positioning"]
            lines.append(_comb_row(f"{race} (All)", pc, mc))
            lines.append(_comb_row(f"{race} (n>=10)", pc["large_battles"], mc["large_battles"]))
        lines.append("")

        lines.append("### 5.2 Per-Matchup Combat Positioning (All 9 Matchups)")
        lines.append("")
        lines.append(
            "| Matchup (Pro/Us Battles) | Med Pack (Pro/Us) | Width / Depth (Pro vs Us) | W:D Ratio (Pro/Us) | "
            "Concave Wrap (Pro/Us) | Role Sep / Inv% (Pro vs Us) | Caster Exp% (Pro/Us) | In-Range% (Pro/Us) | "
            "Splash NN / 2t Clump% (Pro vs Us) | Choke% / Uphill% (Pro vs Us) |"
        )
        lines.append("|---|---:|---|---:|---:|---|---:|---:|---|---|")
        for mu in MATCHUPS:
            pc = by_mu[mu]["pro"]["combat_positioning"]
            mc = by_mu[mu]["mothman"]["combat_positioning"]
            lines.append(_comb_row(mu, pc, mc))
        lines.append("")

        worst = report.get("worst_combat_positioning") or {}
        if any(any(v for v in (worst.get(r) or {}).values()) for r in RACES):
            lines.append("### 5.3 Concrete Worst Mothman Positioning Battles (Actionable Examples)")
            lines.append("")
            for race in RACES:
                rw = worst.get(race) or {}
                lines.append(f"**{race}:**")
                for mode_key, mode_lbl in (
                    ("convex_column", "Convex/Column"),
                    ("role_inversion", "Role Inversion"),
                    ("choke_or_uphill", "Choke/Uphill"),
                    ("low_firing_utilization", "Low Firing Util"),
                ):
                    for b in (rw.get(mode_key) or [])[:2]:
                        oc = ", ".join(f"{u}:{c}" for u, c in (b.get("our_comp") or []))
                        ec = ", ".join(f"{u}:{c}" for u, c in (b.get("opp_comp") or []))
                        lines.append(
                            f"- `{mode_lbl}` `{b['replay']}` @ `{_fmt_sec(b['sec'])}` "
                            f"(`{b['n_our']}v{b['n_opp']}`, width `{b['frontage_width_t']}t`, depth `{b['formation_depth_t']}t`, "
                            f"W:D `{b['width_to_depth_ratio']}`, wrap `{_fmt_delta(b['concave_wrap_score'],'t',2)}`, "
                            f"sep `{_fmt_delta(b['front_to_rear_separation_t'],'t',1)}`, in-range `{_fmt_num(b['in_range_pct'],'%')}`) — "
                            f"Us `[{oc}]` vs Opp `[{ec}]`"
                        )
                lines.append("")

    # Section 6: Macro Army-Group Positioning, Rotation, Regroup, Multiprong & Drop/Runby Taxonomy
    has_ag = any(
        ((by_race.get(r, {}).get("mothman", {}).get("army_group_positioning") or {}).get("n_games", 0) > 0)
        or ((by_race.get(r, {}).get("pro", {}).get("army_group_positioning") or {}).get("n_games", 0) > 0)
        for r in RACES
    )
    if has_ag:
        lines.append("## 6. Macro Army-Group Positioning, Rotation, Regroup & Multiprong vs. Pros")
        lines.append("")
        lines.append(
            "Measured from identical LotV tracker telemetry (`SUnitPositionsEvent` + `SUnitDiedEvent` killer tags + "
            "`SUnitInitEvent` offensive warp-ins & Nydus). Tracks multi-group pressure (`>= 25t` apart across distinct "
            "enemy zones within `15s`), synchronized harass (`±15s` of main-army pressure), reinforcement link-up vs "
            "solo trickle deaths (`<= 2` allies within `10t`), disengage-and-regroup vs fight-to-annihilation (`>= 80%` "
            "losses), base-switch target rotations (`>= 20t` arc away from defended live base), and drop/warp-in/runby taxonomy."
        )
        lines.append("")
        lines.append("### 6.1 Per-Race Macro Army-Group Operations")
        lines.append("")
        lines.append(
            "| Race (Pro/Us Games) | Multiprong% (Pro/Us) | Sync Harass% (Pro/Us) | Reinf Linked% (Pro/Us) | "
            "Solo Trickle Death% (Pro/Us) | Disengage+Regroup% (Pro/Us) | Annihilation% (Pro/Us) | "
            "Rotations / Game (Pro/Us) | Harass / 10m (Pro/Us) | Wk Kills / Harass (Pro/Us) |"
        )
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")

        def _ag_row(lbl: str, pa: dict[str, Any], ma: dict[str, Any]) -> str:
            return (
                f"| **{lbl}** ({pa['n_games']}/{ma['n_games']}) "
                f"| {_fmt_num(pa['multiprong_attack_pct'],'%')} / {_fmt_num(ma['multiprong_attack_pct'],'%')} "
                f"| {_fmt_num(pa['synchronized_harass_pct'],'%')} / {_fmt_num(ma['synchronized_harass_pct'],'%')} "
                f"| {_fmt_num(pa['reinforce_linked_pct'],'%')} / {_fmt_num(ma['reinforce_linked_pct'],'%')} "
                f"| {_fmt_num(pa['solo_trickle_death_pct'],'%')} / {_fmt_num(ma['solo_trickle_death_pct'],'%')} "
                f"| {_fmt_num(pa['disengage_and_regroup_pct'],'%')} / {_fmt_num(ma['disengage_and_regroup_pct'],'%')} "
                f"| {_fmt_num(pa['fight_to_annihilation_pct'],'%')} / {_fmt_num(ma['fight_to_annihilation_pct'],'%')} "
                f"| {_fmt_num(pa['rotations_per_game'],'',2)} / {_fmt_num(ma['rotations_per_game'],'',2)} "
                f"| {_fmt_num(pa['harass_events_per_10m'],'',2)} / {_fmt_num(ma['harass_events_per_10m'],'',2)} "
                f"| {_fmt_num(pa['worker_kills_per_harass'],'',2)} / {_fmt_num(ma['worker_kills_per_harass'],'',2)} |"
            )

        for race in RACES:
            pa = by_race[race]["pro"]["army_group_positioning"]
            ma = by_race[race]["mothman"]["army_group_positioning"]
            lines.append(_ag_row(race, pa, ma))
        lines.append("")

        lines.append("### 6.2 Per-Matchup Macro Army-Group Operations (All 9 Matchups)")
        lines.append("")
        lines.append(
            "| Matchup (Pro/Us Games) | Multiprong% (Pro/Us) | Sync Harass% (Pro/Us) | Reinf Linked% (Pro/Us) | "
            "Solo Trickle% (Pro/Us) | Disengage+Regroup% (Pro/Us) | Annihilation% (Pro/Us) | "
            "Rotations / Game (Pro/Us) | Harass / 10m (Pro/Us) | Wk Kills / Harass (Pro/Us) |"
        )
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for mu in MATCHUPS:
            pa = by_mu[mu]["pro"]["army_group_positioning"]
            ma = by_mu[mu]["mothman"]["army_group_positioning"]
            lines.append(_ag_row(mu, pa, ma))
        lines.append("")

        lines.append("### 6.3 Pro vs. Mothman Drop, Warp-In, Nydus & Runby Taxonomy (Ranked by Pro Impact)")
        lines.append("")
        for race in RACES:
            pa = by_race[race]["pro"]["army_group_positioning"]
            ma = by_race[race]["mothman"]["army_group_positioning"]
            p_sub = pa.get("harass_by_subtype") or {}
            m_sub = ma.get("harass_by_subtype") or {}
            rows = sorted(
                p_sub.items(),
                key=lambda kv: (-kv[1]["per_10m"], -(kv[1]["worker_kills"] or 0)),
            )
            lines.append(f"**{race} (`Pro {pa['n_games']}g` vs `Mothman {ma['n_games']}g`):**")
            lines.append("| Subtype | Kind | Pro / 10m (Adopt%) | Us / 10m (Adopt%) | Pro Wk/Ev (Sync%) | Us Wk/Ev (Sync%) |")
            lines.append("|---|---|---:|---:|---:|---:|")
            for st, ps in rows:
                ms = m_sub.get(st) or {"count": 0, "per_10m": 0.0, "adopt_game_pct": 0.0, "worker_kills_per_event": None, "sync_pct": None}
                if ps["count"] == 0 and ms["count"] == 0:
                    continue
                lines.append(
                    f"| {ps['label']} | `{ps['kind']}` "
                    f"| {ps['per_10m']:.2f} ({ps['adopt_game_pct']:.1f}%) "
                    f"| {ms['per_10m']:.2f} ({ms['adopt_game_pct']:.1f}%) "
                    f"| {_fmt_num(ps['worker_kills_per_event'],'',2)} ({_fmt_num(ps['sync_pct'],'%')}) "
                    f"| {_fmt_num(ms['worker_kills_per_event'],'',2)} ({_fmt_num(ms['sync_pct'],'%')}) |"
                )
            lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description="Deep Pro vs. Mothman spatial, timing, combat positioning, and macro army-group comparison across all 9 matchups.")
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
    ap.add_argument("--jobs", type=int, default=8, help="Parallel worker processes for replay decoding")
    ap.add_argument("--skip-combat-positioning", action="store_true", help="Skip LotV combat concave & positioning extraction")
    ap.add_argument("--skip-army-groups", action="store_true", help="Skip Section 6 macro army-group, rotation, regroup & multiprong extraction")
    ap.add_argument("--out-json", required=True, help="Output structured JSON path")
    ap.add_argument("--out-md", required=True, help="Output Markdown summary path")
    args = ap.parse_args()

    t0 = time.time()
    include_combat = not args.skip_combat_positioning
    include_army_groups = not args.skip_army_groups
    run_prefixes = tuple(s.strip() for s in args.run_prefixes.split(",") if s.strip())
    pro_by_mu, pro_combat_by_mu, pro_scanned = load_pro_corpus(
        Path(args.pro_dir),
        Path(args.pylibs_dir),
        min_dur_sec=args.min_dur_sec,
        max_per_matchup=args.max_per_matchup,
        jobs=args.jobs,
        include_combat=include_combat,
        include_army_groups=include_army_groups,
    )
    mm_by_mu, mm_total = load_mothman_sqlite(
        Path(args.replay_db),
        run_prefixes=run_prefixes,
        min_dur_sec=args.min_dur_sec,
        pylibs_dir=Path(args.pylibs_dir),
        jobs=args.jobs,
        include_combat=include_combat,
        include_army_groups=include_army_groups,
    )
    meta = {
        "pro_replays_scanned": pro_scanned,
        "pro_games_total": sum(len(v) for v in pro_by_mu.values()),
        "pro_combat_games_total": sum(len(v) for v in pro_combat_by_mu.values()),
        "pro_combat_battles_total": sum(len(b) for v in pro_combat_by_mu.values() for r in v for b in [r.get("combat_battles") or []]),
        "pro_army_group_games_total": sum(1 for v in pro_combat_by_mu.values() for r in v if r.get("army_group") is not None),
        "mothman_games_total": sum(len(v) for v in mm_by_mu.values()),
        "mothman_combat_battles_total": sum(len(b) for v in mm_by_mu.values() for r in v for b in [r.get("combat_battles") or []]),
        "mothman_army_group_games_total": sum(1 for v in mm_by_mu.values() for r in v if r.get("army_group") is not None),
        "mothman_rows_matched": mm_total,
        "run_prefixes": list(run_prefixes),
        "min_dur_sec": args.min_dur_sec,
        "max_per_matchup": args.max_per_matchup,
        "include_combat_positioning": include_combat,
        "include_army_groups": include_army_groups,
        "elapsed_sec": round(time.time() - t0, 2),
    }
    report = build_comparison_report(pro_by_mu, mm_by_mu, meta, pro_combat_by_mu=pro_combat_by_mu)
    md = render_markdown(report)

    out_json = Path(args.out_json)
    out_md = Path(args.out_md)
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
    out_md.write_text(md, encoding="utf-8")

    print(
        f"PRO_DEEP_COMPARISON_OK: pro={meta['pro_games_total']} (scanned={pro_scanned}, "
        f"pro_battles={meta['pro_combat_battles_total']}, pro_ag={meta['pro_army_group_games_total']}), "
        f"mothman={meta['mothman_games_total']} ({','.join(run_prefixes)}, "
        f"mm_battles={meta['mothman_combat_battles_total']}, mm_ag={meta['mothman_army_group_games_total']}), "
        f"elapsed={meta['elapsed_sec']}s -> {out_json.name}, {out_md.name}"
    )


if __name__ == "__main__":
    main()
