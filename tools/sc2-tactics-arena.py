#!/usr/bin/env python3
"""
Real-SC2_x64 Physics-Accurate Micro Skirmish Arena 2.0 (`tools/sc2-tactics-arena.py`)

Runs deterministic, multi-scenario real-SC2_x64 (Blizzard 4.10) micro skirmishes
inside `docker.io/aiarena/arenaclient-combined:v0.8.0` using SC2 `RequestDebug`
(`DebugCreateUnit` + `DebugKillUnit` + `DebugGameState`), resetting units cleanly
between scenarios WITHOUT rebooting SC2_x64.

Modes:
  --mode probe             : Standalone 1-SC2 RequestDebug feasibility check.
  --mode duel              : 2-Participant real-SC2_x64 physics skirmish arena:
      --opponent dummy     : (Default) P1 = LIVE Mothman vs P2 = Focus-Firing MicroDummy.
      --opponent self      : Mothman-vs-Mothman Self-Play (LIVE Mothman on BOTH P1 & P2,
                             matching each scenario's `our_race` and `enemy_race`!).

Terrain Modes (computed directly from real SC2 map grids & mineral patches):
  open | high-ground-ramp | flank-surround | cliff-air-chasm | mineral-line-harass

Selective Per-Player Upgrades & Unit States:
  Supports per-scenario `upgrades`, `p1_upgrades`, `p2_upgrades` (Burrow, TunnelingClaws,
  GlialReconstitution, MetabolicBoost, CentrifugalHooks, LurkerRange, AdaptiveTalons,
  GroovedSpines, MuscularAugments, Blink, Charge, ThermalLance, PsiStorm, Stim,
  CombatShield, ConcussiveShells, DrillingClaws, SmartServos, Cloak/BansheeCloak/
  PersonalCloaking, AdvancedBallistics), pre-burrowed & pre-sieged units, and pre-cloak.

Usage (from host):
  python3 tools/sc2-tactics-arena.py --mode duel --race all --out out.json --render-dir visuals/
  python3 tools/sc2-tactics-arena.py --mode duel --opponent self --scenario z09 --render-dir /tmp/self_z09
  python3 tools/sc2-tactics-arena.py --mode duel --terrain high-ground-ramp --out /tmp/ramps.json
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
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DEFAULT_IMAGE = "docker.io/aiarena/arenaclient-combined:v0.8.0"
DEFAULT_MAPS_DIR = Path("/home/sjaconette/sc2-local-arena/maps")
DEFAULT_ARENA_DIR = Path("/home/sjaconette/sc2-local-arena")
DEFAULT_REPO_DIR = Path("/home/sjaconette/repos/mothman-sc2-bot")
DEFAULT_MAP = "AcropolisAIE.SC2Map"
DEFAULT_SCENARIOS_FILE = Path(__file__).resolve().parent / "arena-scenarios.json"

VALID_TERRAINS = (
    "open",
    "high-ground-ramp",
    "flank-surround",
    "cliff-air-chasm",
    "mineral-line-harass",
)
VALID_TIERS = ("canonical", "regression", "econ-harass")
VALID_SCORING_MODES = ("combat", "mineral-defense", "worker-runby")
VALID_CATEGORIES = (
    "detection-snipe",
    "stalker-blink",
    "runby-offense",
    "runby-defense",
    "stasis-ward",
    "yamato-jump",
    "transport-nydus",
    "burrow-micro",
    "spellcasters",
    "kiting-concave",
    "flank-surround",
    "high-ground-ramp",
    "air-superiority",
    "early-rush-defense",
    "capital-endgame",
    "regression",
)
VALID_RACES = ("Protoss", "Terran", "Zerg")
VALID_P2_WORKER_MICROS = ("brawl", "cooldown-weave-kite")
MINING_ORDER_ABILITY_IDS = {295, 296, 298, 299, 1183, 1184, 3666}
CARRYING_MINERAL_BUFF_IDS = {271, 272}

# Canonical SC2 UnitTypeIds (Blizzard 4.10 Base75689 — synced with add-arena-scenario skill)
UNIT_IDS: dict[str, int] = {
    # Terran (24)
    "marine": 48,
    "reaper": 49,
    "marauder": 51,
    "medivac": 54,
    "siege-tank": 33,
    "siege-tank-sieged": 32,
    "hellion": 53,
    "hellbat": 484,
    "ghost": 50,
    "raven": 56,
    "thor": 52,
    "viking-fighter": 35,
    "viking-assault": 34,
    "banshee": 55,
    "widow-mine": 498,
    "widow-mine-burrowed": 500,
    "liberator": 689,
    "liberator-ag": 734,
    "cyclone": 692,
    "battlecruiser": 57,
    "scv": 45,
    "planetary-fortress": 130,
    "missile-turret": 23,
    "bunker": 24,
    # Protoss (23)
    "zealot": 73,
    "stalker": 74,
    "sentry": 77,
    "adept": 311,
    "immortal": 83,
    "colossus": 4,
    "disruptor": 694,
    "high-templar": 75,
    "dark-templar": 76,
    "archon": 141,
    "phoenix": 78,
    "oracle": 495,
    "void-ray": 80,
    "carrier": 79,
    "tempest": 496,
    "observer": 82,
    "warp-prism": 81,
    "probe": 84,
    "photon-cannon": 66,
    "pylon": 60,
    "shield-battery": 1910,
    "oracle-stasis-trap": 732,
    "stasis-trap": 732,
    # Zerg (35 — incl. burrowed variants, static detectors, Dropperlord & Nydus)
    "zergling": 105,
    "zergling-burrowed": 119,
    "baneling": 9,
    "baneling-burrowed": 115,
    "roach": 110,
    "roach-burrowed": 118,
    "ravager": 688,
    "ravager-burrowed": 690,
    "hydralisk": 107,
    "hydralisk-burrowed": 117,
    "mutalisk": 108,
    "corruptor": 112,
    "queen": 126,
    "queen-burrowed": 125,
    "ultralisk": 109,
    "ultralisk-burrowed": 131,
    "infestor": 111,
    "infestor-burrowed": 127,
    "swarm-host": 494,
    "swarm-host-burrowed": 493,
    "viper": 499,
    "brood-lord": 114,
    "lurker-mp": 502,
    "lurker-mp-burrowed": 503,
    "overseer": 129,
    "overlord": 106,
    "overlord-transport": 893,
    "dropperlord": 893,
    "spore-crawler": 99,
    "spine-crawler": 98,
    "nydus-canal": 142,
    "nydus-worm": 142,
    "nydus-network": 95,
    "creep-tumor-burrowed": 137,
    "drone": 104,
    "drone-burrowed": 116,
}

# Canonical primary display name per UnitTypeId (avoids alias collisions)
CANONICAL_UNIT_NAMES: dict[int, str] = {}
for _uname, _uid in UNIT_IDS.items():
    if _uid not in CANONICAL_UNIT_NAMES:
        CANONICAL_UNIT_NAMES[_uid] = _uname

# Approximate mineral + 1.5*gas weighted combat value per unit (synced with add-arena-scenario skill)
UNIT_VALUES: dict[int, float] = {
    # Terran
    48: 50.0,     # marine
    49: 125.0,    # reaper
    51: 137.5,    # marauder
    54: 250.0,    # medivac
    33: 337.5,    # siege-tank
    32: 337.5,    # siege-tank-sieged
    53: 100.0,    # hellion
    484: 100.0,   # hellbat
    50: 337.5,    # ghost
    56: 400.0,    # raven
    52: 600.0,    # thor
    691: 600.0,   # thor-ap (high-impact payload)
    35: 262.5,    # viking-fighter
    34: 262.5,    # viking-assault
    55: 300.0,    # banshee
    498: 112.5,   # widow-mine
    500: 112.5,   # widow-mine-burrowed
    689: 375.0,   # liberator
    734: 375.0,   # liberator-ag
    692: 300.0,   # cyclone
    57: 850.0,    # battlecruiser
    45: 50.0,     # scv
    130: 775.0,   # planetary-fortress (550M + 1.5*150G)
    23: 100.0,    # missile-turret
    24: 100.0,    # bunker
    # Protoss
    73: 100.0,    # zealot
    74: 200.0,    # stalker
    77: 200.0,    # sentry
    311: 137.5,   # adept
    83: 425.0,    # immortal
    4: 600.0,     # colossus
    694: 375.0,   # disruptor
    75: 275.0,    # high-templar
    76: 312.5,    # dark-templar
    141: 550.0,   # archon
    78: 300.0,    # phoenix
    495: 375.0,   # oracle
    80: 475.0,    # void-ray
    79: 725.0,    # carrier
    496: 512.5,   # tempest
    82: 137.5,    # observer
    81: 250.0,    # warp-prism
    84: 50.0,     # probe
    66: 150.0,    # photon-cannon
    60: 100.0,    # pylon
    1910: 100.0,  # shield-battery
    732: 50.0,    # oracle-stasis-trap
    # Zerg
    105: 25.0,    # zergling
    119: 25.0,    # zergling-burrowed
    9: 87.5,      # baneling
    115: 87.5,    # baneling-burrowed
    110: 112.5,   # roach
    118: 112.5,   # roach-burrowed
    688: 250.0,   # ravager
    690: 250.0,   # ravager-burrowed
    107: 175.0,   # hydralisk
    117: 175.0,   # hydralisk-burrowed
    108: 250.0,   # mutalisk
    112: 300.0,   # corruptor
    126: 150.0,   # queen
    125: 150.0,   # queen-burrowed
    109: 575.0,   # ultralisk
    131: 575.0,   # ultralisk-burrowed
    111: 325.0,   # infestor
    127: 325.0,   # infestor-burrowed
    494: 212.5,   # swarm-host
    493: 212.5,   # swarm-host-burrowed
    499: 400.0,   # viper
    114: 675.0,   # brood-lord
    502: 375.0,   # lurker-mp
    503: 375.0,   # lurker-mp-burrowed
    129: 225.0,   # overseer
    106: 100.0,   # overlord
    893: 150.0,   # overlord-transport (Dropperlord)
    99: 125.0,    # spore-crawler
    98: 150.0,    # spine-crawler
    142: 100.0,   # nydus-canal / nydus-worm
    95: 450.0,    # nydus-network
    137: 0.0,     # creep-tumor-burrowed
    104: 50.0,    # drone
    116: 50.0,    # drone-burrowed
}

DEFAULT_MAX_LOOPS = 960          # ~42.9s real Faster SC2 combat
STALEMATE_NO_DAMAGE_LOOPS = 168  # 7.5s with zero HP/shield damage or unit deaths -> stalemate stop
POINTS_WIN_TRADE = 1.25          # trade >= 1.25x on timeout/stalemate -> Points Win
POINTS_LOSS_TRADE = 0.80         # trade <= 0.80x on timeout/stalemate -> Points Loss
MAX_SCENARIOS_PER_BATCH = 10     # cap monotonic upgrade chain batch length to keep containers crisp

TOWNHALL_IDS = {18, 59, 86, 100, 101, 130, 132}
STRUCTURE_IDS = {130, 23, 66, 99, 98, 60, 1910, 24, 142, 95}
STATIC_TRAP_IDS = {732, 137}  # oracle-stasis-trap, creep-tumor-burrowed (pathable spawn, unarmed)
STRUCTURE_FOOTPRINTS: dict[int, int] = {
    130: 5, 23: 2, 66: 2, 99: 2, 98: 2, 60: 2, 1910: 2, 24: 3, 142: 3, 95: 3,
}
DETECTOR_IDS = {23, 66, 99, 82, 56, 129}  # missile-turret, photon-cannon, spore-crawler, observer, raven, overseer
TRANSPORT_IDS = {54, 81, 893, 142, 95, 24}  # medivac, warp-prism, overlord-transport, nydus-canal, nydus-network, bunker
TRANSPORT_LOAD_ABILITIES: dict[int, int] = {
    54: 394,    # LOAD_MEDIVAC
    81: 911,    # LOAD_WARPPRISM
    893: 1406,  # LOAD_OVERLORD
    142: 2370,  # LOAD_NYDUSWORM
    95: 1437,   # LOAD_NYDUSNETWORK
    24: 407,    # LOAD_BUNKER
}
WORKER_IDS = {45, 84, 104, 116}
COMBAT_IDS = set(UNIT_VALUES) - WORKER_IDS
AIR_UNIT_IDS = {
    54, 35, 55, 56, 689, 734, 57,       # Terran air
    78, 495, 80, 79, 496, 82, 81,       # Protoss air
    108, 112, 499, 114, 129, 106, 893,  # Zerg air
}
MINERAL_IDS = {146, 147, 341, 483, 665, 666, 796, 797, 884, 885}
GEYSER_IDS = {342, 343, 344, 345, 608, 880, 881}
RACE_WORKER_IDS: dict[str, int] = {"Terran": 45, "Protoss": 84, "Zerg": 104}
STARTER_BUILDING_SPECS: dict[str, dict[str, Any]] = {
    "spawning-pool": {
        "unit_id": 89, "race": "Zerg", "footprint": 3, "build_ability": 1155,
        "builder_uid": 104, "build_loops": 1030, "on_geyser": False, "needs_pylon": False, "needs_creep": True,
    },
    "supply-depot": {
        "unit_id": 19, "race": "Terran", "footprint": 2, "build_ability": 319,
        "builder_uid": 45, "build_loops": 470, "on_geyser": False, "needs_pylon": False, "needs_creep": False,
    },
    "barracks": {
        "unit_id": 21, "race": "Terran", "footprint": 3, "build_ability": 321,
        "builder_uid": 45, "build_loops": 1030, "on_geyser": False, "needs_pylon": False, "needs_creep": False,
    },
    "pylon": {
        "unit_id": 60, "race": "Protoss", "footprint": 2, "build_ability": 881,
        "builder_uid": 84, "build_loops": 403, "on_geyser": False, "needs_pylon": False, "needs_creep": False,
    },
    "gateway": {
        "unit_id": 62, "race": "Protoss", "footprint": 3, "build_ability": 883,
        "builder_uid": 84, "build_loops": 1030, "on_geyser": False, "needs_pylon": True, "needs_creep": False,
    },
    "assimilator": {
        "unit_id": 61, "race": "Protoss", "footprint": 3, "build_ability": 882,
        "builder_uid": 84, "build_loops": 470, "on_geyser": True, "needs_pylon": False, "needs_creep": False,
    },
    "refinery": {
        "unit_id": 20, "race": "Terran", "footprint": 3, "build_ability": 320,
        "builder_uid": 45, "build_loops": 470, "on_geyser": True, "needs_pylon": False, "needs_creep": False,
    },
    "extractor": {
        "unit_id": 88, "race": "Zerg", "footprint": 3, "build_ability": 1154,
        "builder_uid": 104, "build_loops": 470, "on_geyser": True, "needs_pylon": False, "needs_creep": False,
    },
}
STARTER_BUILDING_UIDS: set[int] = {int(v["unit_id"]) for v in STARTER_BUILDING_SPECS.values()}

# Exact SC2 4.10 weapon/combat capability tables for unarmed/incapable-survivor termination
PURE_UNARMED_IDS = {
    54, 82, 81, 129,             # medivac, observer, warp-prism, overseer
    60, 1910, 24, 732,           # pylon, shield-battery, bunker (unless loaded), oracle-stasis-trap
    142, 95, 106, 893, 137,      # nydus-canal, nydus-network, overlord, overlord-transport, creep-tumor-burrowed
}
# Energy-gated spellcasters with no standard auto-attack: uid -> (min_energy, can_hit_ground, can_hit_air)
ENERGY_CASTER_CAPS: dict[int, tuple[float, bool, bool]] = {
    56: (50.0, True, True),     # raven (Auto-Turret 50e -> G+A)
    111: (75.0, True, True),    # infestor (Fungal Growth 75e -> G+A)
    127: (75.0, True, True),    # infestor-burrowed
    499: (125.0, False, True),  # viper alone (Parasitic Bomb 125e -> Air; Abduct deals 0 dmg alone)
    495: (15.0, True, False),   # oracle (Pulsar Beam -> Ground only)
}
GROUND_ONLY_WEAPON_IDS = {
    51, 33, 32, 53, 484, 49, 55, 45, 130,                                        # Terran G-only (incl. planetary-fortress)
    73, 311, 83, 4, 694, 76, 84,                                                 # Protoss G-only
    105, 119, 9, 115, 110, 118, 109, 131, 114, 502, 503, 494, 493, 98, 104, 116, # Zerg G-only (incl. spine-crawler)
}
AIR_ONLY_WEAPON_IDS = {112, 23, 99}  # corruptor, missile-turret, spore-crawler
BOTH_WEAPON_IDS = {
    48, 50, 52, 691, 498, 500, 692, 57,                  # Terran G+A (incl. thor-ap)
    74, 77, 141, 80, 79, 496, 66,                        # Protoss G+A (incl. photon-cannon)
    688, 690, 107, 117, 108, 126, 125,                   # Zerg G+A
}
MASSIVE_ARMORED_AIR_IDS = {57, 79, 496, 114, 112}  # battlecruiser, carrier, tempest, brood-lord, corruptor
MASSIVE_GROUND_IDS = {52, 4, 141, 109, 131}  # thor, colossus, archon, ultralisk (immune to Graviton Beam)


def _uid_attack_caps_basic(uid: int, energy: float, allies: list[Any], is_dummy: bool = False) -> tuple[bool, bool]:
    if uid in PURE_UNARMED_IDS:
        return (False, False)
    if uid in ENERGY_CASTER_CAPS:
        min_e, cg, ca = ENERGY_CASTER_CAPS[uid]
        if energy >= min_e:
            return (cg, ca)
        return (False, False)
    if uid == 75:  # high-templar: PsiBlast hits Ground; PsiStorm (75e) hits Ground+Air
        return (True, energy >= 75.0)
    if uid == 78:  # phoenix: Air weapon; Graviton Beam lifts non-massive Ground if >=2 Phoenixes & >=50e
        can_lift = (
            sum(1 for a in allies if int(a.unit_type) == 78) >= 2
            and energy >= 50.0
        )
        return (can_lift, True)
    if uid in (35, 689):  # viking-fighter, liberator (MicroDummy never morphs)
        return (False, True) if is_dummy else (True, True)
    if uid in (34, 734):  # viking-assault, liberator-ag (MicroDummy never morphs)
        return (True, False) if is_dummy else (True, True)
    if uid in BOTH_WEAPON_IDS:
        return (True, True)
    if uid in GROUND_ONLY_WEAPON_IDS:
        return (True, False)
    if uid in AIR_ONLY_WEAPON_IDS:
        return (False, True)
    return (True, True)


def unit_attack_caps(u: Any, allies: list[Any], is_dummy: bool = False) -> tuple[bool, bool]:
    """Return (can_hit_ground, can_hit_air) for SC2 unit `u` (including any loaded passengers)."""
    uid = int(u.unit_type)
    cg, ca = _uid_attack_caps_basic(uid, float(getattr(u, "energy", 0.0)), allies, is_dummy=is_dummy)
    passengers = getattr(u, "passengers", None) or ()
    if passengers:
        for p in passengers:
            pcg, pca = _uid_attack_caps_basic(int(p.unit_type), float(getattr(p, "energy", 0.0)), allies, is_dummy=is_dummy)
            cg = cg or pcg
            ca = ca or pca
    return (cg, ca)


def units_total_value(units: list[Any]) -> float:
    """Sum resource value of visible units PLUS any passengers inside transports/bunkers/nydus."""
    total = 0.0
    for u in units:
        total += UNIT_VALUES.get(int(u.unit_type), 100.0)
        for p in getattr(u, "passengers", None) or ():
            total += UNIT_VALUES.get(int(p.unit_type), 100.0)
    return total


def units_total_count(units: list[Any]) -> int:
    """Count visible units PLUS any passengers inside transports/bunkers/nydus."""
    total = 0
    for u in units:
        total += 1 + len(getattr(u, "passengers", None) or ())
    return total


def units_type_counts(units: list[Any]) -> dict[str, int]:
    """Aggregate canonical unit name counts including loaded passengers."""
    counts: dict[str, int] = {}
    for u in units:
        nm = CANONICAL_UNIT_NAMES.get(int(u.unit_type), str(u.unit_type))
        counts[nm] = counts.get(nm, 0) + 1
        for p in getattr(u, "passengers", None) or ():
            pnm = CANONICAL_UNIT_NAMES.get(int(p.unit_type), str(p.unit_type))
            counts[pnm] = counts.get(pnm, 0) + 1
    return counts


def count_matching_unit_ids(units: list[Any], id_set: set[int]) -> int:
    """Count units (including passengers) whose unit_type is in `id_set`."""
    cnt = 0
    for u in units:
        if int(u.unit_type) in id_set:
            cnt += 1
        for p in getattr(u, "passengers", None) or ():
            if int(p.unit_type) in id_set:
                cnt += 1
    return cnt


def count_combat_capable(units: list[Any], is_dummy: bool = False) -> int:
    """Count surviving units that possess an active weapon or damage-dealing spell."""
    cnt = 0
    for u in units:
        cg, ca = unit_attack_caps(u, units, is_dummy=is_dummy)
        if cg or ca:
            cnt += 1
    return cnt


def side_can_damage_other(atk_units: list[Any], def_units: list[Any], is_dummy: bool = False) -> bool:
    """Return True iff at least one unit in `atk_units` can damage at least one unit in `def_units`."""
    if not atk_units or not def_units:
        return False
    for a in atk_units:
        cg, ca = unit_attack_caps(a, atk_units, is_dummy=is_dummy)
        if not (cg or ca):
            continue
        auid = int(a.unit_type)
        for d in def_units:
            duid = int(d.unit_type)
            is_air = bool(getattr(d, "is_flying", False)) or (duid in AIR_UNIT_IDS)
            if is_air:
                if ca:
                    return True
            else:
                if cg and not (auid == 78 and duid in MASSIVE_GROUND_IDS):
                    return True
    return False

BURROWED_UNIT_MAP: dict[str, str] = {
    "zergling": "zergling-burrowed",
    "baneling": "baneling-burrowed",
    "roach": "roach-burrowed",
    "ravager": "ravager-burrowed",
    "hydralisk": "hydralisk-burrowed",
    "queen": "queen-burrowed",
    "ultralisk": "ultralisk-burrowed",
    "infestor": "infestor-burrowed",
    "swarm-host": "swarm-host-burrowed",
    "lurker-mp": "lurker-mp-burrowed",
    "widow-mine": "widow-mine-burrowed",
    "drone": "drone-burrowed",
}
SIEGED_UNIT_MAP: dict[str, str] = {
    "siege-tank": "siege-tank-sieged",
    "liberator": "liberator-ag",
}

# Selective Upgrade Registry:
# canonical_name -> (race, research_bldg_unit_id, research_ability_id, needs_pylon, addon_parent_and_ab_or_None, prereq_bldg_or_None)
UPGRADE_SPECS: dict[str, tuple[str, int, int, bool, tuple[int, int] | None, int | None]] = {
    # Zerg (Hive=101 satisfies both Lair & Hive requirements)
    "Burrow": ("Zerg", 86, 1225, False, None, None),
    "TunnelingClaws": ("Zerg", 97, 217, False, None, 101),
    "GlialReconstitution": ("Zerg", 97, 216, False, None, 101),
    "MetabolicBoost": ("Zerg", 89, 1253, False, None, None),
    "AdrenalGlands": ("Zerg", 89, 1252, False, None, 101),
    "CentrifugalHooks": ("Zerg", 96, 1482, False, None, 101),
    "LurkerRange": ("Zerg", 504, 3710, False, None, 101),
    "AdaptiveTalons": ("Zerg", 504, 3709, False, None, 101),
    "GroovedSpines": ("Zerg", 91, 1282, False, None, 101),
    "MuscularAugments": ("Zerg", 91, 1283, False, None, 101),
    "ChitinousPlating": ("Zerg", 93, 265, False, None, 101),
    "AnabolicSynthesis": ("Zerg", 93, 263, False, None, 101),
    "NeuralParasite": ("Zerg", 94, 1455, False, None, 101),
    "OverlordSpeed": ("Zerg", 86, 1223, False, None, None),
    # Protoss
    "Blink": ("Protoss", 65, 1593, True, None, None),
    "Charge": ("Protoss", 65, 1592, True, None, None),
    "ResonatingGlaives": ("Protoss", 65, 1594, True, None, None),
    "ThermalLance": ("Protoss", 70, 1097, True, None, None),
    "GraviticDrive": ("Protoss", 70, 1094, True, None, None),
    "GraviticBoosters": ("Protoss", 70, 1093, True, None, None),
    "PsiStorm": ("Protoss", 68, 1126, True, None, None),
    "ShadowStride": ("Protoss", 69, 2720, True, None, None),
    "ProtossGroundWeapons1": ("Protoss", 63, 1062, True, None, None),
    "ProtossGroundWeapons2": ("Protoss", 63, 1063, True, None, 65),
    "ProtossGroundWeapons3": ("Protoss", 63, 1064, True, None, 65),
    # Terran (TechLab addons built in-place on parent Barracks/Factory/Starport via 421/454/487)
    "Stim": ("Terran", 37, 730, False, (21, 421), None),
    "CombatShield": ("Terran", 37, 731, False, (21, 421), None),
    "ConcussiveShells": ("Terran", 37, 732, False, (21, 421), None),
    "DrillingClaws": ("Terran", 39, 764, False, (27, 454), 29),
    "SmartServos": ("Terran", 39, 766, False, (27, 454), 29),
    "InfernalPreigniter": ("Terran", 39, 761, False, (27, 454), None),
    "BansheeCloak": ("Terran", 41, 790, False, (28, 487), None),
    "HyperflightRotors": ("Terran", 41, 799, False, (28, 487), 30),
    "AdvancedBallistics": ("Terran", 41, 805, False, (28, 487), 30),
    "PersonalCloaking": ("Terran", 26, 820, False, None, None),
    "WeaponRefit": ("Terran", 30, 1532, False, None, None),
}

UPGRADE_ALIASES: dict[str, list[str]] = {
    "burrow": ["Burrow"],
    "tunnelingclaws": ["TunnelingClaws"],
    "tunneling-claws": ["TunnelingClaws"],
    "glialreconstitution": ["GlialReconstitution"],
    "glial-reconstitution": ["GlialReconstitution"],
    "roachspeed": ["GlialReconstitution"],
    "metabolicboost": ["MetabolicBoost"],
    "metabolic-boost": ["MetabolicBoost"],
    "lingspeed": ["MetabolicBoost"],
    "adrenalglands": ["AdrenalGlands"],
    "adrenal-glands": ["AdrenalGlands"],
    "centrifugalhooks": ["CentrifugalHooks"],
    "centrifugal-hooks": ["CentrifugalHooks"],
    "banespeed": ["CentrifugalHooks"],
    "lurkerrange": ["LurkerRange"],
    "lurker-range": ["LurkerRange"],
    "seismicspines": ["LurkerRange"],
    "adaptivetalons": ["AdaptiveTalons"],
    "adaptive-talons": ["AdaptiveTalons"],
    "groovedspines": ["GroovedSpines"],
    "grooved-spines": ["GroovedSpines"],
    "muscularaugments": ["MuscularAugments"],
    "muscular-augments": ["MuscularAugments"],
    "chitinousplating": ["ChitinousPlating"],
    "chitinous-plating": ["ChitinousPlating"],
    "anabolicsynthesis": ["AnabolicSynthesis"],
    "anabolic-synthesis": ["AnabolicSynthesis"],
    "ultraspeed": ["AnabolicSynthesis"],
    "neuralparasite": ["NeuralParasite"],
    "neural-parasite": ["NeuralParasite"],
    "overlordspeed": ["OverlordSpeed"],
    "overlord-speed": ["OverlordSpeed"],
    "pneumatizedcarapace": ["OverlordSpeed"],
    "pneumatized-carapace": ["OverlordSpeed"],
    # In LotV 4.10 Dropperlord (`overlord-transport` 893) is morphed individually rather than a global upgrade;
    # alias VentralSacks -> OverlordSpeed so upgrade specs stay valid alongside spawned `overlord-transport` units.
    "ventralsacks": ["OverlordSpeed"],
    "ventral-sacks": ["OverlordSpeed"],
    "blink": ["Blink"],
    "charge": ["Charge"],
    "resonatingglaives": ["ResonatingGlaives"],
    "resonating-glaives": ["ResonatingGlaives"],
    "thermallance": ["ThermalLance"],
    "thermal-lance": ["ThermalLance"],
    "extendedthermallance": ["ThermalLance"],
    "graviticdrive": ["GraviticDrive"],
    "gravitic-drive": ["GraviticDrive"],
    "prismspeed": ["GraviticDrive"],
    "graviticboosters": ["GraviticBoosters"],
    "gravitic-boosters": ["GraviticBoosters"],
    "obsspeed": ["GraviticBoosters"],
    "psistorm": ["PsiStorm"],
    "psi-storm": ["PsiStorm"],
    "shadowstride": ["ShadowStride"],
    "shadow-stride": ["ShadowStride"],
    "shadowstrike": ["ShadowStride"],
    "shadow-strike": ["ShadowStride"],
    "dtblink": ["ShadowStride"],
    "dt-blink": ["ShadowStride"],
    "protossgroundweapons1": ["ProtossGroundWeapons1"],
    "protoss-ground-weapons-1": ["ProtossGroundWeapons1"],
    "groundweapons1": ["ProtossGroundWeapons1"],
    "protossgroundweapons2": ["ProtossGroundWeapons2"],
    "protoss-ground-weapons-2": ["ProtossGroundWeapons2"],
    "groundweapons2": ["ProtossGroundWeapons2"],
    "protossgroundweapons3": ["ProtossGroundWeapons3"],
    "protoss-ground-weapons-3": ["ProtossGroundWeapons3"],
    "groundweapons3": ["ProtossGroundWeapons3"],
    "protossgroundweapons+3": ["ProtossGroundWeapons1", "ProtossGroundWeapons2", "ProtossGroundWeapons3"],
    "stim": ["Stim"],
    "stimpack": ["Stim"],
    "combatshield": ["CombatShield"],
    "combat-shield": ["CombatShield"],
    "concussiveshells": ["ConcussiveShells"],
    "concussive-shells": ["ConcussiveShells"],
    "drillingclaws": ["DrillingClaws"],
    "drilling-claws": ["DrillingClaws"],
    "smartservos": ["SmartServos"],
    "smart-servos": ["SmartServos"],
    "infernalpreigniter": ["InfernalPreigniter"],
    "infernal-preigniter": ["InfernalPreigniter"],
    "blueflame": ["InfernalPreigniter"],
    "blue-flame": ["InfernalPreigniter"],
    "bansheecloak": ["BansheeCloak"],
    "banshee-cloak": ["BansheeCloak"],
    "hyperflightrotors": ["HyperflightRotors"],
    "hyperflight-rotors": ["HyperflightRotors"],
    "bansheespeed": ["HyperflightRotors"],
    "personalcloaking": ["PersonalCloaking"],
    "personal-cloaking": ["PersonalCloaking"],
    "advancedballistics": ["AdvancedBallistics"],
    "advanced-ballistics": ["AdvancedBallistics"],
    "weaponrefit": ["WeaponRefit"],
    "weapon-refit": ["WeaponRefit"],
    "yamato": ["WeaponRefit"],
    "yamato-cannon": ["WeaponRefit"],
    "cloak": ["BansheeCloak", "PersonalCloaking"],
}


# Sequential upgrade prerequisites (e.g., +2 requires +1 completed first; +3 requires +2)
UPGRADE_PREREQ_UPGRADES: dict[str, str] = {
    "ProtossGroundWeapons2": "ProtossGroundWeapons1",
    "ProtossGroundWeapons3": "ProtossGroundWeapons2",
}


def normalize_upgrades(raw_list: list[str] | None) -> list[str]:
    out: list[str] = []

    def _add_with_prereqs(name: str) -> None:
        req = UPGRADE_PREREQ_UPGRADES.get(name)
        if req is not None:
            _add_with_prereqs(req)
        if name not in out:
            out.append(name)

    for raw in raw_list or []:
        key = str(raw).strip()
        if not key:
            continue
        if key in UPGRADE_SPECS:
            items = [key]
        else:
            lk = key.lower().replace("_", "").replace(" ", "")
            lk_dash = key.lower().replace("_", "-").replace(" ", "-")
            items = UPGRADE_ALIASES.get(lk) or UPGRADE_ALIASES.get(lk_dash)
            if not items:
                raise ValueError(f"Unknown upgrade {raw!r}. Supported: {sorted(UPGRADE_SPECS)}")
        for item in items:
            _add_with_prereqs(item)
    return out


@dataclass
class SkirmishSpec:
    id: str
    our_race: str        # Protoss | Terran | Zerg
    enemy_race: str
    description: str
    p1_units: list[tuple[str, int, float, float]]  # (unit_name, count, dx, dy)
    p2_units: list[tuple[str, int, float, float]]
    max_loops: int = DEFAULT_MAX_LOOPS  # ~42.9s Faster SC2 combat
    terrain: str = "open"
    high_ground_side: str = "p1"
    source: str = "core"
    tier: str = "canonical"              # canonical | regression | econ-harass
    category: str = "kiting-concave"     # tactical category (16 categories)
    fast_core: bool = False              # True -> included in `--suite core` (~65 flagships)
    scoring_mode: str = "combat"         # combat | mineral-defense | worker-runby
    pass_net_econ_min: float = 0.0       # mineral-defense net econ pass threshold
    pass_workers_killed_min: int = 4     # worker-runby minimum enemy workers killed to pass
    origin_match_id: str = ""            # replay-extract provenance tag for regression tier
    use_main_base: bool = False          # spawn at P1's live starting TownHall + main minerals
    use_p2_main_base: bool = False       # spawn at P2's live starting TownHall + main minerals (worker-runby)
    patterns: list[str] = field(default_factory=list)
    p1_upgrades: list[str] = field(default_factory=list)
    p2_upgrades: list[str] = field(default_factory=list)
    p1_pre_burrowed: list[str] = field(default_factory=list)
    p2_pre_burrowed: list[str] = field(default_factory=list)
    p1_pre_cloaked: bool = False
    p2_pre_cloaked: bool = False
    pre_sieged: bool = False
    p1_loaded_transports: list[dict[str, Any]] = field(default_factory=list)
    p2_loaded_transports: list[dict[str, Any]] = field(default_factory=list)
    p2_worker_micro: str = "brawl"       # brawl | cooldown-weave-kite
    p1_minerals: int = 0                 # optional target starting mineral bank for P1 (0 = default 50M)
    p1_starter_buildings: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class ArenaSite:
    terrain: str
    cx: float
    cy: float
    ux: float = 1.0
    uy: float = 0.0
    px: float = 0.0
    py: float = 1.0
    high_height: int | None = None
    low_height: int | None = None


def extract_main_mineral_info(
    units: list[Any],
    th_pos: tuple[float, float],
    max_dist: float = 12.0,
) -> tuple[list[int], list[tuple[float, float]]]:
    """Extract deterministically arc-sorted mineral patch (tags, positions) around `th_pos`
    from the owning player's own SC2 observation namespace."""
    th_x, th_y = float(th_pos[0]), float(th_pos[1])
    near = [
        u for u in units
        if int(getattr(u, "unit_type", 0)) in MINERAL_IDS
        and math.hypot(float(u.pos.x) - th_x, float(u.pos.y) - th_y) <= max_dist
    ]
    near.sort(key=lambda u: math.atan2(float(u.pos.y) - th_y, float(u.pos.x) - th_x))
    return (
        [int(u.tag) for u in near],
        [(float(u.pos.x), float(u.pos.y)) for u in near],
    )


def build_site_from_mineral_positions(
    th_pos: tuple[float, float],
    mineral_positions: list[tuple[float, float]],
    map_center: tuple[float, float] = (88.0, 88.0),
) -> ArenaSite:
    """Build a main-base ArenaSite centered on `th_pos` with +u pointing away from minerals."""
    th_x, th_y = float(th_pos[0]), float(th_pos[1])
    if mineral_positions:
        mx = sum(p[0] for p in mineral_positions) / len(mineral_positions)
        my = sum(p[1] for p in mineral_positions) / len(mineral_positions)
        vx, vy = th_x - mx, th_y - my
    else:
        vx, vy = float(map_center[0]) - th_x, float(map_center[1]) - th_y
    vlen = math.hypot(vx, vy)
    ux, uy = (vx / vlen, vy / vlen) if vlen > 0.2 else (1.0, 0.0)
    return ArenaSite(
        terrain="mineral-line-harass",
        cx=th_x,
        cy=th_y,
        ux=ux,
        uy=uy,
        px=-uy,
        py=ux,
    )


def compute_per_patch_worker_positions(
    mineral_positions: list[tuple[float, float]],
    th_pos: tuple[float, float],
    count: int,
    shift_toward_th: float = 1.35,
) -> list[tuple[float, float]]:
    """Distribute `count` workers cleanly 2-per-mineral-patch along a TownHall's live mineral arc."""
    if count <= 0:
        return []
    th_x, th_y = float(th_pos[0]), float(th_pos[1])
    if not mineral_positions:
        return [(th_x - 3.0, th_y) for _ in range(count)]
    n_p = len(mineral_positions)
    out: list[tuple[float, float]] = []
    for i in range(count):
        mx, my = mineral_positions[(i // 2) % n_p]
        vx, vy = th_x - mx, th_y - my
        vlen = max(0.1, math.hypot(vx, vy))
        ux, uy = vx / vlen, vy / vlen
        px, py = -uy, ux
        lat = -0.35 if (i % 2 == 0) else 0.35
        out.append((mx + shift_toward_th * ux + lat * px, my + shift_toward_th * uy + lat * py))
    return out


def evaluate_combat_verdict(
    scen: SkirmishSpec,
    p1_tag: str,
    p2_tag: str,
    trade: float,
    p1_lost: float,
    p2_lost: float,
    end_reason: str,
    ko_winner_side: int,
    p1_bc_start: int = 0,
    p1_bc_alive: int = 0,
    p1_jump_cmds: int = 0,
) -> tuple[str, str]:
    """Evaluate combat-mode `(winner, win_type)` with principled BC escape-jump & spellcaster trade rules."""
    # BC tactical-jump hull preservation (`y07`, `t15`): don't penalize a successful escape-jump as a stall Draw/Loss!
    if (
        end_reason == "no_damage_stalemate"
        and p1_bc_start > 0
        and p1_bc_alive >= p1_bc_start
        and p1_jump_cmds > 0
    ):
        if "bc-tactical-jump-escape" in scen.patterns and p2_lost >= 350.0:
            return p1_tag, "escape_jump_pass"
        if "bc-tactical-jump" in scen.patterns and trade >= 1.0:
            return p1_tag, "points"

    # Positive-trade spellcaster/support survivor (`z14`, `n01`): don't award P2 an artificial KO loss
    # when P1 already traded ahead (`trade >= 1.05`) and only energy casters / transports survived!
    eff_ko = ko_winner_side
    if end_reason in ("ko_unarmed_only", "ko_incapable_survivors") and ko_winner_side == 2 and trade >= 1.05:
        eff_ko = 0

    if eff_ko == 1:
        return p1_tag, "ko"
    if eff_ko == 2:
        return p2_tag, "ko"
    if trade >= POINTS_WIN_TRADE:
        return p1_tag, "points"
    if trade <= POINTS_LOSS_TRADE:
        return p2_tag, "points"
    return "Draw", "draw"


def is_p2_worker_rush_spec(scen: SkirmishSpec) -> bool:
    """Return True when P2's entire spawned force is a pure worker rush (>= 4 workers, 0 combat units)."""
    if not scen.p2_units or scen.p2_loaded_transports or scen.scoring_mode == "worker-runby":
        return False
    total_w = 0
    for uname, cnt, _dx, _dy in scen.p2_units:
        if UNIT_IDS.get(uname, 0) not in WORKER_IDS:
            return False
        total_w += int(cnt)
    return total_w >= 4


def plan_worker_rush_orders(
    my_workers: list[Any],
    en_gnd: list[Any],
    site: ArenaSite,
    use_main_base: bool,
    worker_micro: str = "brawl",
    p2_mineral_tags: list[int] | None = None,
    p2_home_pos: tuple[float, float] | None = None,
) -> list[tuple[int, int | None, tuple[float, float] | None, list[int]]]:
    """Compute per-worker rush orders for pure worker-rush P2 forces.

    Returns `(ability_id, target_unit_tag_or_None, target_pos_or_None, unit_tags)`:
    - `"brawl"` (default): aggressive surround (`ability_id=23, target_unit_tag`) on nearest
      visible ground target; moves past TownHall into mineral pocket when no enemy is in sight.
    - `"cooldown-weave-kite"`: realistic cooldown-weaving + home-mineral-walk (`3666`) kiting:
      * When `weapon_cooldown > 0` (within 18t of P1 base) OR wounded (`hp+shield < 70%` with
        unfinished shields or enemy within 4t, inside a 13.5t–18.5t leash): mineral-walk (`3666`)
        toward P2's home mineral patch (phasing through unit collision & pulling naive chasers).
      * When wounded outside the 13.5t leash & safe (`d_en > 4.5t`) while shields regen: `Stop (4)`
        so Probes recharge shields right outside P1's main and re-dive once healthy.
      * When off-cooldown & healthy: focus-fire nearest (lowest-HP tie-broken) P1 worker/defender.
    """
    if not my_workers:
        return []
    if en_gnd:
        if worker_micro == "cooldown-weave-kite":
            kite_tags: list[int] = []
            hold_tags: list[int] = []
            by_tgt: dict[int, list[int]] = {}
            en_workers = [e for e in en_gnd if int(getattr(e, "unit_type", 0)) in WORKER_IDS]
            for w in my_workers:
                wx, wy = float(w.pos.x), float(w.pos.y)
                w_hp = float(getattr(w, "health", 0.0))
                w_hp_max = float(getattr(w, "health_max", 0.0))
                w_sh = float(getattr(w, "shield", 0.0))
                w_sh_max = float(getattr(w, "shield_max", 0.0))
                w_cd = float(getattr(w, "weapon_cooldown", 0.0))
                tot_max = max(1.0, w_hp_max + w_sh_max)
                hp_ratio = (w_hp + w_sh) / tot_max
                dist_site = math.hypot(wx - site.cx, wy - site.cy)
                nearest_any = min(
                    en_gnd,
                    key=lambda e: math.hypot(float(e.pos.x) - wx, float(e.pos.y) - wy),
                )
                d_en = math.hypot(float(nearest_any.pos.x) - wx, float(nearest_any.pos.y) - wy)
                shields_depleted = (w_sh_max > 0.0 and w_sh < w_sh_max - 0.5)
                wounded = (hp_ratio < 0.70) and (shields_depleted or d_en <= 4.0)

                if w_cd > 0.0 and dist_site < 18.0:
                    kite_tags.append(int(w.tag))
                elif wounded:
                    if dist_site < 13.5 or (dist_site < 18.5 and d_en <= 4.5):
                        kite_tags.append(int(w.tag))
                    elif shields_depleted and d_en > 4.5:
                        hold_tags.append(int(w.tag))
                    else:
                        # Outside leash, safe, non-shielded or shields already full -> re-engage
                        pool = en_workers if (en_workers and d_en > 2.2) else en_gnd
                        tgt = min(
                            pool,
                            key=lambda e: (
                                math.hypot(float(e.pos.x) - wx, float(e.pos.y) - wy)
                                + 0.06 * (float(e.health) + float(getattr(e, "shield", 0.0))),
                                float(e.health) + float(getattr(e, "shield", 0.0)),
                            ),
                        )
                        by_tgt.setdefault(int(tgt.tag), []).append(int(w.tag))
                else:
                    # Off-cooldown & healthy: dive nearest/weakest P1 worker (or point-blank combat threat)
                    near_workers = [
                        e for e in en_workers
                        if math.hypot(float(e.pos.x) - wx, float(e.pos.y) - wy) <= 9.0
                    ]
                    if d_en <= 2.2 and int(getattr(nearest_any, "unit_type", 0)) not in WORKER_IDS:
                        tgt = nearest_any
                    else:
                        pool = near_workers if near_workers else (en_workers if en_workers else en_gnd)
                        tgt = min(
                            pool,
                            key=lambda e: (
                                math.hypot(float(e.pos.x) - wx, float(e.pos.y) - wy)
                                + 0.06 * (float(e.health) + float(getattr(e, "shield", 0.0))),
                                float(e.health) + float(getattr(e, "shield", 0.0)),
                            ),
                        )
                    by_tgt.setdefault(int(tgt.tag), []).append(int(w.tag))

            out_orders: list[tuple[int, int | None, tuple[float, float] | None, list[int]]] = []
            if kite_tags:
                if p2_mineral_tags:
                    out_orders.append((3666, int(p2_mineral_tags[0]), None, kite_tags))
                else:
                    ret_pos = p2_home_pos or (site.cx + 12.0 * site.ux, site.cy + 12.0 * site.uy)
                    out_orders.append((16, None, ret_pos, kite_tags))
            if hold_tags:
                out_orders.append((4, None, None, hold_tags))
            for tid, tags in by_tgt.items():
                out_orders.append((23, tid, None, tags))
            return out_orders

        by_tgt_b: dict[int, list[int]] = {}
        for w in my_workers:
            tgt = min(
                en_gnd,
                key=lambda e: (
                    math.hypot(float(e.pos.x) - float(w.pos.x), float(e.pos.y) - float(w.pos.y)),
                    float(e.health) + float(getattr(e, "shield", 0.0)),
                ),
            )
            by_tgt_b.setdefault(int(tgt.tag), []).append(int(w.tag))
        return [(23, tid, None, tags) for tid, tags in by_tgt_b.items()]

    if use_main_base:
        rx = site.cx - 3.0 * site.ux
        ry = site.cy - 3.0 * site.uy
        avg_d = sum(math.hypot(float(w.pos.x) - rx, float(w.pos.y) - ry) for w in my_workers) / len(my_workers)
        if avg_d > 4.5:
            return [(16, None, (rx, ry), [int(w.tag) for w in my_workers])]
        return [(23, None, (site.cx, site.cy), [int(w.tag) for w in my_workers])]
    return [(23, None, (site.cx, site.cy), [int(w.tag) for w in my_workers])]


DEFAULT_SKIRMISHES: list[SkirmishSpec] = [
    SkirmishSpec(
        id="sc2-real-p01-zealot-stalker-vs-bio",
        our_race="Protoss",
        enemy_race="Terran",
        description="Real SC2: 4 Zealots + 4 Stalkers vs 12 Marines + 3 Marauders (melee + ranged stutter-step)",
        p1_units=[("zealot", 4, -3.5, 0.0), ("stalker", 4, -5.0, 0.0)],
        p2_units=[("marine", 12, 4.5, 0.0), ("marauder", 3, 5.5, 0.0)],
        max_loops=DEFAULT_MAX_LOOPS,
    ),
]


def _parse_unit_entries(
    entries: list[Any],
    sid: str,
    side: str,
    pre_burrowed: list[str] | None = None,
    pre_sieged: bool = False,
) -> list[tuple[str, int, float, float]]:
    burrow_set = set(pre_burrowed or [])
    parsed: list[tuple[str, int, float, float]] = []
    for item in entries:
        if not isinstance(item, (list, tuple)) or len(item) != 4:
            raise ValueError(f"Scenario {sid!r} {side} entry must be [unit, count, dx, dy], got {item!r}")
        uname, cnt, dx, dy = str(item[0]), int(item[1]), float(item[2]), float(item[3])
        if uname in burrow_set and uname in BURROWED_UNIT_MAP:
            uname = BURROWED_UNIT_MAP[uname]
        if pre_sieged and uname in SIEGED_UNIT_MAP:
            uname = SIEGED_UNIT_MAP[uname]
        if uname not in UNIT_IDS:
            raise ValueError(f"Scenario {sid!r} {side} has unknown unit {uname!r}")
        parsed.append((uname, cnt, dx, dy))
    return parsed


def _parse_loaded_transports(
    entries: list[Any] | None,
    sid: str,
    side: str,
) -> list[dict[str, Any]]:
    """Parse & validate pre-loaded transport specs: {transport, dx, dy, cargo: [[unit, cnt], ...]}."""
    parsed: list[dict[str, Any]] = []
    for idx, item in enumerate(entries or []):
        if not isinstance(item, dict):
            raise ValueError(f"Scenario {sid!r} {side}[{idx}] must be an object, got {item!r}")
        t_name = str(item.get("transport", "")).strip()
        if t_name not in UNIT_IDS or UNIT_IDS[t_name] not in TRANSPORT_IDS:
            raise ValueError(
                f"Scenario {sid!r} {side}[{idx}] invalid transport {t_name!r} "
                f"(valid: {[k for k, v in UNIT_IDS.items() if v in TRANSPORT_IDS]})"
            )
        dx = float(item.get("dx", -5.0 if side.startswith("p1") else 5.0))
        dy = float(item.get("dy", 0.0))
        raw_cargo = item.get("cargo") or []
        if not isinstance(raw_cargo, list) or not raw_cargo:
            raise ValueError(f"Scenario {sid!r} {side}[{idx}] must specify non-empty cargo list")
        cargo: list[tuple[str, int]] = []
        for c_item in raw_cargo:
            if not isinstance(c_item, (list, tuple)) or len(c_item) != 2:
                raise ValueError(f"Scenario {sid!r} {side}[{idx}] cargo item must be [unit, count], got {c_item!r}")
            cu, cc = str(c_item[0]), int(c_item[1])
            if cu not in UNIT_IDS:
                raise ValueError(f"Scenario {sid!r} {side}[{idx}] unknown cargo unit {cu!r}")
            if cc <= 0:
                raise ValueError(f"Scenario {sid!r} {side}[{idx}] cargo count must be > 0, got {cc}")
            cargo.append((cu, cc))
        parsed.append({"transport": t_name, "dx": dx, "dy": dy, "cargo": cargo})
    return parsed


def _parse_starter_buildings(
    entries: list[Any] | None,
    sid: str,
) -> list[dict[str, Any]]:
    """Parse & validate P1 starter production/econ buildings: {unit, dx, dy, progress, halted, on_geyser}."""
    parsed: list[dict[str, Any]] = []
    for idx, item in enumerate(entries or []):
        if not isinstance(item, dict):
            raise ValueError(f"Scenario {sid!r} p1_starter_buildings[{idx}] must be an object, got {item!r}")
        uname = str(item.get("unit", "")).strip()
        if uname not in STARTER_BUILDING_SPECS:
            raise ValueError(
                f"Scenario {sid!r} p1_starter_buildings[{idx}] invalid building {uname!r} "
                f"(valid: {sorted(STARTER_BUILDING_SPECS)})"
            )
        spec = STARTER_BUILDING_SPECS[uname]
        dx = float(item.get("dx", 4.0))
        dy = float(item.get("dy", 4.0))
        progress = float(item.get("progress", 1.0))
        halted = bool(item.get("halted", False))
        on_geyser = bool(item.get("on_geyser", spec["on_geyser"]))
        parsed.append({
            "unit": uname,
            "dx": dx,
            "dy": dy,
            "progress": progress,
            "halted": halted,
            "on_geyser": on_geyser,
        })
    return parsed


def load_scenarios(scenarios_path: str = "", repo_dir: Path | None = None) -> list[SkirmishSpec]:
    """Load skirmish scenarios from --scenarios path, tools/arena-scenarios.json, or fallback."""
    cand: Path | None = None
    if scenarios_path:
        cand = Path(scenarios_path).resolve()
        if not cand.is_file():
            raise FileNotFoundError(f"Scenarios file not found: {cand}")
    else:
        search: list[Path] = []
        if repo_dir is not None:
            search.append(repo_dir / "tools" / "arena-scenarios.json")
        search.append(DEFAULT_SCENARIOS_FILE)
        for p in search:
            if p.is_file():
                cand = p
                break
    if cand is None:
        return list(DEFAULT_SKIRMISHES)

    raw = json.loads(cand.read_text(encoding="utf-8"))
    items = raw.get("scenarios", []) if isinstance(raw, dict) else raw
    if not isinstance(items, list) or not items:
        raise ValueError(f"Scenarios catalog {cand} contains no scenarios")
    specs: list[SkirmishSpec] = []
    for idx, sc in enumerate(items):
        if not isinstance(sc, dict):
            raise ValueError(f"Scenario #{idx} in {cand} is not an object")
        sid = str(sc["id"])
        our_race = str(sc["our_race"])
        enemy_race = str(sc["enemy_race"])
        if our_race not in VALID_RACES:
            raise ValueError(f"Scenario {sid!r} has invalid our_race {our_race!r}")
        if enemy_race not in VALID_RACES:
            raise ValueError(f"Scenario {sid!r} has invalid enemy_race {enemy_race!r}")
        terrain = str(sc.get("terrain", "open"))
        if terrain not in VALID_TERRAINS:
            raise ValueError(f"Scenario {sid!r} has invalid terrain {terrain!r} (valid: {VALID_TERRAINS})")
        tier = str(sc.get("tier", "canonical"))
        if tier not in VALID_TIERS:
            raise ValueError(f"Scenario {sid!r} has invalid tier {tier!r} (valid: {VALID_TIERS})")
        scoring_mode = str(sc.get("scoring_mode", "combat"))
        if scoring_mode not in VALID_SCORING_MODES:
            raise ValueError(f"Scenario {sid!r} has invalid scoring_mode {scoring_mode!r} (valid: {VALID_SCORING_MODES})")
        category = str(sc.get("category", "regression" if tier == "regression" else ("runby-offense" if scoring_mode == "worker-runby" else ("runby-defense" if scoring_mode == "mineral-defense" else "kiting-concave"))))
        if category not in VALID_CATEGORIES:
            raise ValueError(f"Scenario {sid!r} has invalid category {category!r} (valid: {VALID_CATEGORIES})")
        shared_upgs = normalize_upgrades(sc.get("upgrades"))
        p1_upgs = normalize_upgrades(sc.get("p1_upgrades"))
        p2_upgs = normalize_upgrades(sc.get("p2_upgrades"))
        for u in shared_upgs:
            urace = UPGRADE_SPECS[u][0]
            if urace == our_race and u not in p1_upgs:
                p1_upgs.append(u)
            if urace == enemy_race and u not in p2_upgs:
                p2_upgs.append(u)
        p1_pre_b = [str(x) for x in (sc.get("p1_pre_burrowed") or [])]
        p2_pre_b = [str(x) for x in (sc.get("p2_pre_burrowed") or [])]
        pre_s = bool(sc.get("pre_sieged", False))
        p1_u = _parse_unit_entries(sc.get("p1_units") or [], sid, "p1_units", p1_pre_b, pre_s)
        p2_u = _parse_unit_entries(sc.get("p2_units") or [], sid, "p2_units", p2_pre_b, pre_s)
        p1_lt = _parse_loaded_transports(sc.get("p1_loaded_transports"), sid, "p1_loaded_transports")
        p2_lt = _parse_loaded_transports(sc.get("p2_loaded_transports"), sid, "p2_loaded_transports")
        p1_sb = _parse_starter_buildings(sc.get("p1_starter_buildings"), sid)
        p2_wm = str(sc.get("p2_worker_micro", "brawl")).strip() or "brawl"
        if p2_wm not in VALID_P2_WORKER_MICROS:
            raise ValueError(
                f"Scenario {sid!r} has invalid p2_worker_micro {p2_wm!r} (valid: {VALID_P2_WORKER_MICROS})"
            )
        p1_mins = int(sc.get("p1_minerals", 0) or 0)
        if not p1_u and not p1_lt:
            raise ValueError(f"Scenario {sid!r} must have at least one p1_units or p1_loaded_transports entry")
        if not p2_u and not p2_lt:
            raise ValueError(f"Scenario {sid!r} must have at least one p2_units or p2_loaded_transports entry")
        specs.append(SkirmishSpec(
            id=sid,
            our_race=our_race,
            enemy_race=enemy_race,
            description=str(sc.get("description", sid)),
            p1_units=p1_u,
            p2_units=p2_u,
            max_loops=int(sc.get("max_loops", DEFAULT_MAX_LOOPS)),
            terrain=terrain,
            high_ground_side=str(sc.get("high_ground_side", "p1")),
            source=str(sc.get("source", "core")),
            tier=tier,
            category=category,
            fast_core=bool(sc.get("fast_core", False)),
            scoring_mode=scoring_mode,
            pass_net_econ_min=float(sc.get("pass_net_econ_min", 0.0)),
            pass_workers_killed_min=int(sc.get("pass_workers_killed_min", 4)),
            origin_match_id=str(sc.get("origin_match_id", "")),
            use_main_base=bool(sc.get("use_main_base", scoring_mode == "mineral-defense")),
            use_p2_main_base=bool(sc.get("use_p2_main_base", scoring_mode == "worker-runby")),
            patterns=[str(p) for p in (sc.get("patterns") or [])],
            p1_upgrades=p1_upgs,
            p2_upgrades=p2_upgs,
            p1_pre_burrowed=p1_pre_b,
            p2_pre_burrowed=p2_pre_b,
            p1_pre_cloaked=bool(sc.get("p1_pre_cloaked", False)),
            p2_pre_cloaked=bool(sc.get("p2_pre_cloaked", False)),
            pre_sieged=pre_s,
            p1_loaded_transports=p1_lt,
            p2_loaded_transports=p2_lt,
            p2_worker_micro=p2_wm,
            p1_minerals=p1_mins,
            p1_starter_buildings=p1_sb,
        ))
    return specs


def validate_scenarios(specs: list[SkirmishSpec]) -> list[str]:
    """Run deep structural, uniqueness, race/upgrade, and category coverage checks."""
    errs: list[str] = []
    seen_ids: set[str] = set()
    cats_present: set[str] = set()
    fast_core_cats: set[str] = set()
    for s in specs:
        if s.id in seen_ids:
            errs.append(f"Duplicate scenario id: {s.id!r}")
        seen_ids.add(s.id)
        if s.max_loops < 120 or s.max_loops > 3600:
            errs.append(f"{s.id}: unreasonable max_loops={s.max_loops}")
        for side_lbl, entries in (("p1", s.p1_units), ("p2", s.p2_units)):
            for uname, cnt, dx, dy in entries:
                if cnt <= 0:
                    errs.append(f"{s.id}: {side_lbl} unit {uname!r} has non-positive count {cnt}")
                if abs(dx) > 25.0 or abs(dy) > 25.0:
                    errs.append(f"{s.id}: {side_lbl} unit {uname!r} offset ({dx}, {dy}) out of bounds")
        for u in s.p1_upgrades:
            ur = UPGRADE_SPECS[u][0]
            if ur != s.our_race:
                errs.append(f"{s.id}: p1_upgrade {u!r} ({ur}) mismatches our_race={s.our_race!r}")
        for u in s.p2_upgrades:
            ur = UPGRADE_SPECS[u][0]
            if ur != s.enemy_race:
                errs.append(f"{s.id}: p2_upgrade {u!r} ({ur}) mismatches enemy_race={s.enemy_race!r}")
        if s.p2_worker_micro not in VALID_P2_WORKER_MICROS:
            errs.append(f"{s.id}: invalid p2_worker_micro={s.p2_worker_micro!r}")
        if s.p2_worker_micro != "brawl" and not is_p2_worker_rush_spec(s):
            errs.append(f"{s.id}: p2_worker_micro={s.p2_worker_micro!r} requires a pure P2 worker rush")
        if s.p1_minerals < 0 or s.p1_minerals > 2000:
            errs.append(f"{s.id}: p1_minerals={s.p1_minerals} out of [0, 2000]")
        if (s.p1_minerals > 0 or s.p1_starter_buildings) and not s.use_main_base:
            errs.append(f"{s.id}: p1_minerals/p1_starter_buildings requires use_main_base=true")
        for sb_idx, sb in enumerate(s.p1_starter_buildings):
            bname = sb["unit"]
            bspec = STARTER_BUILDING_SPECS.get(bname)
            if bspec is None:
                errs.append(f"{s.id}: p1_starter_buildings[{sb_idx}] unknown building {bname!r}")
                continue
            if bspec["race"] != s.our_race:
                errs.append(f"{s.id}: p1_starter_buildings[{sb_idx}] {bname!r} ({bspec['race']}) mismatches our_race={s.our_race!r}")
            prog = float(sb.get("progress", 1.0))
            if prog <= 0.0 or prog > 1.0:
                errs.append(f"{s.id}: p1_starter_buildings[{sb_idx}] {bname!r} progress={prog} out of (0, 1]")
            if sb.get("halted") and prog >= 0.99:
                errs.append(f"{s.id}: p1_starter_buildings[{sb_idx}] {bname!r} halted=true requires progress < 1.0")
            if sb.get("halted") and s.our_race != "Terran":
                errs.append(f"{s.id}: p1_starter_buildings[{sb_idx}] {bname!r} halted=true is only valid for Terran")
            if abs(float(sb.get("dx", 0.0))) > 25.0 or abs(float(sb.get("dy", 0.0))) > 25.0:
                errs.append(f"{s.id}: p1_starter_buildings[{sb_idx}] {bname!r} offset out of bounds")
        if s.scoring_mode == "mineral-defense":
            if not s.use_main_base:
                errs.append(f"{s.id}: mineral-defense should enable use_main_base")
            if not any(UNIT_IDS[u] in WORKER_IDS for u, _, _, _ in s.p1_units):
                errs.append(f"{s.id}: mineral-defense requires P1 mining workers")
        if s.scoring_mode == "worker-runby":
            if not s.use_p2_main_base:
                errs.append(f"{s.id}: worker-runby should enable use_p2_main_base")
            if not any(UNIT_IDS[u] in WORKER_IDS for u, _, _, _ in s.p2_units):
                errs.append(f"{s.id}: worker-runby requires P2 mining workers")
            if s.pass_workers_killed_min <= 0:
                errs.append(f"{s.id}: worker-runby requires pass_workers_killed_min > 0")
        if s.use_main_base and s.use_p2_main_base:
            errs.append(f"{s.id}: cannot set both use_main_base and use_p2_main_base")
        cats_present.add(s.category)
        if s.fast_core:
            fast_core_cats.add(s.category)
    missing_fc = sorted(cats_present - fast_core_cats)
    if missing_fc and fast_core_cats:
        errs.append(f"Categories missing from fast_core (--suite core): {missing_fc}")
    return errs


def print_scenario_listing(specs: list[SkirmishSpec], validated: bool = False) -> None:
    """Print human-readable Tactics Arena 3.0 catalog summary and per-scenario rows."""
    by_cat: dict[str, int] = {}
    by_cat_fc: dict[str, int] = {}
    by_tier: dict[str, int] = {}
    by_race: dict[str, int] = {}
    by_mode: dict[str, int] = {}
    for s in specs:
        by_cat[s.category] = by_cat.get(s.category, 0) + 1
        if s.fast_core:
            by_cat_fc[s.category] = by_cat_fc.get(s.category, 0) + 1
        by_tier[s.tier] = by_tier.get(s.tier, 0) + 1
        by_race[s.our_race] = by_race.get(s.our_race, 0) + 1
        by_mode[s.scoring_mode] = by_mode.get(s.scoring_mode, 0) + 1
    fc_total = sum(1 for s in specs if s.fast_core)
    status_tag = " [VALIDATED OK]" if validated else ""
    print(f"Mothman Real-SC2 Tactics Arena 3.0 Catalog{status_tag}: {len(specs)} scenarios ({fc_total} fast_core)")
    print(f"  By tier   : " + ", ".join(f"{k}={by_tier.get(k, 0)}" for k in VALID_TIERS if by_tier.get(k, 0)))
    print(f"  By race   : " + ", ".join(f"{k}={by_race.get(k, 0)}" for k in VALID_RACES if by_race.get(k, 0)))
    print(f"  By scoring: " + ", ".join(f"{k}={by_mode.get(k, 0)}" for k in VALID_SCORING_MODES if by_mode.get(k, 0)))
    print("  By category (total / fast_core):")
    for cat in VALID_CATEGORIES:
        if by_cat.get(cat, 0):
            print(f"    - {cat:<20s}: {by_cat[cat]:3d} total ({by_cat_fc.get(cat, 0):2d} core)")
    print("")
    for idx, s in enumerate(specs, 1):
        fc_mk = "*" if s.fast_core else " "
        lt_tag = ""
        if s.p1_loaded_transports or s.p2_loaded_transports:
            lt_tag += f" [loaded:{len(s.p1_loaded_transports)}/{len(s.p2_loaded_transports)}]"
        if s.p2_worker_micro != "brawl":
            lt_tag += f" [{s.p2_worker_micro}]"
        if s.p1_starter_buildings:
            lt_tag += f" [bldgs:{len(s.p1_starter_buildings)}]"
        if s.p1_minerals > 0:
            lt_tag += f" [{s.p1_minerals}M]"
        print(
            f"{idx:3d}. [{fc_mk}] {s.id:<58s} {s.our_race[0]}v{s.enemy_race[0]} "
            f"| {s.category:<18s} | {s.scoring_mode:<15s} | {s.terrain:<19s}{lt_tag}"
        )


def resolve_effective_suite(
    suite_arg: str,
    scenario_filter: str = "",
    category_filter: str = "",
    scenario_ids: str = "",
) -> str:
    """Default to `core` (~65 flagship scenarios) unless narrowed by --scenario/--category/--scenario-ids."""
    s = (suite_arg or "").strip().lower()
    if s in ("core", "all"):
        return s
    if scenario_filter or category_filter or scenario_ids:
        return "all"
    return "core"


def filter_scenarios(
    scenarios: list[SkirmishSpec],
    race: str,
    scenario_filter: str = "",
    enemy_race: str = "",
    terrain_filter: str = "",
    source_filter: str = "",
    tier_filter: str = "",
    category_filter: str = "",
    suite_filter: str = "all",
) -> list[SkirmishSpec]:
    """Filter scenarios by suite, our_race, enemy_race, terrain, source, tier, category, and id substring."""
    out = list(scenarios)
    if suite_filter and suite_filter.lower() == "core":
        fc = [s for s in out if s.fast_core]
        if fc:
            out = fc
    if race.lower() != "all":
        out = [s for s in out if s.our_race.lower() == race.lower()]
    if enemy_race and enemy_race.lower() != "all":
        out = [s for s in out if s.enemy_race.lower() == enemy_race.lower()]
    if terrain_filter:
        tf = terrain_filter.lower()
        out = [s for s in out if s.terrain.lower() == tf]
    if source_filter:
        sf = source_filter.lower()
        out = [s for s in out if s.source.lower() == sf]
    if tier_filter and tier_filter.lower() != "all":
        trf = tier_filter.lower()
        out = [s for s in out if s.tier.lower() == trf]
    if category_filter and category_filter.lower() != "all":
        want_cats = {c.strip().lower() for c in category_filter.split(",") if c.strip()}
        out = [s for s in out if s.category.lower() in want_cats]
    if scenario_filter:
        needles = [tok.strip().lower() for tok in scenario_filter.split(",") if tok.strip()]
        if needles:
            out = [s for s in out if any(n in s.id.lower() for n in needles)]
    if not out:
        raise ValueError(
            f"No scenarios matched suite={suite_filter!r} race={race!r} enemy_race={enemy_race!r} "
            f"terrain={terrain_filter!r} source={source_filter!r} tier={tier_filter!r} "
            f"category={category_filter!r} scenario={scenario_filter!r}"
        )
    return out


def _needs_isolated_batch(s: SkirmishSpec) -> bool:
    """Return True when a scenario requires a clean fresh match (exact 50M bank & fresh game_loop)."""
    return bool(s.p1_minerals > 0 or s.p1_starter_buildings or s.p2_worker_micro != "brawl")


def partition_duel_batches(
    matched_specs: list[SkirmishSpec],
    max_batch_size: int = MAX_SCENARIOS_PER_BATCH,
) -> list[tuple[str, str, int, list[SkirmishSpec]]]:
    """Partition scenarios by (our_race, enemy_race) into minimal monotonic upgrade chains.

    Because SC2 upgrades persist for the entire match, every batch guarantees
    p1_upgrades(s_i) <= p1_upgrades(s_{i+1}) and p2_upgrades(s_i) <= p2_upgrades(s_{i+1}),
    ensuring 100% exact per-scenario upgrades with zero cross-duel leakage. Chains longer
    than `max_batch_size` are split into bounded sub-batches for fast parallel execution.
    Full-lifecycle econ/kiting drills (`p1_minerals`, `p1_starter_buildings`, or
    `p2_worker_micro != "brawl"`) always get their own isolated fresh match container so
    P1 starts at exact 50M and fresh early game_loop with zero prior-round carryover.
    """
    by_pair: dict[tuple[str, str], list[tuple[int, SkirmishSpec]]] = {}
    pair_order: list[tuple[str, str]] = []
    for idx, s in enumerate(matched_specs):
        pair = (s.our_race, s.enemy_race)
        if pair not in by_pair:
            by_pair[pair] = []
            pair_order.append(pair)
        by_pair[pair].append((idx, s))

    batches: list[tuple[str, str, int, list[SkirmishSpec]]] = []
    for r1, r2 in pair_order:
        items = sorted(
            by_pair[(r1, r2)],
            key=lambda it: (
                len(it[1].p1_upgrades) + len(it[1].p2_upgrades),
                1 if it[1].scoring_mode in ("mineral-defense", "worker-runby") else 0,
                it[0],
            ),
        )
        chains: list[list[SkirmishSpec]] = []
        isolated: list[list[SkirmishSpec]] = []
        for _orig_idx, s in items:
            if _needs_isolated_batch(s):
                isolated.append([s])
                continue
            s_p1 = set(s.p1_upgrades)
            s_p2 = set(s.p2_upgrades)
            best_ci: int | None = None
            best_len = -1
            for ci, ch in enumerate(chains):
                if len(ch) >= max_batch_size:
                    continue
                tail = ch[-1]
                t_p1 = set(tail.p1_upgrades)
                t_p2 = set(tail.p2_upgrades)
                if t_p1 <= s_p1 and t_p2 <= s_p2:
                    t_len = len(t_p1) + len(t_p2)
                    if t_len > best_len:
                        best_len = t_len
                        best_ci = ci
            if best_ci is not None:
                chains[best_ci].append(s)
            else:
                chains.append([s])
        for b_idx, ch in enumerate(chains + isolated):
            batches.append((r1, r2, b_idx, ch))
    return batches


def run_single_container(
    args: argparse.Namespace,
    race: str,
    save_replays_dir: Path | None = None,
    enemy_race: str = "",
    scenario_ids: list[str] | None = None,
    batch_tag: str = "",
) -> dict[str, Any]:
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
    custom_scenarios_in_container = ""
    if getattr(args, "scenarios", ""):
        custom_sc = Path(args.scenarios).resolve()
        if not custom_sc.is_file():
            raise FileNotFoundError(f"Scenarios file not found: {custom_sc}")
        custom_scenarios_in_container = "/harness/custom-scenarios.json"
        mounts.extend(["-v", f"{custom_sc}:{custom_scenarios_in_container}:ro"])
    replay_host_path: Path | None = None
    opp_mode = getattr(args, "opponent", "dummy")
    if save_replays_dir is not None and args.mode == "duel":
        save_replays_dir.mkdir(parents=True, exist_ok=True)
        if batch_tag:
            replay_name = f"arena_{opp_mode}_{batch_tag}.SC2Replay"
        elif opp_mode == "self" and enemy_race:
            replay_name = f"arena_self_{race}_vs_{enemy_race}.SC2Replay"
        else:
            replay_name = f"arena_{race}.SC2Replay"
        replay_host_path = save_replays_dir.resolve() / replay_name
        mounts.extend(["-v", f"{save_replays_dir.resolve()}:/out-replays:rw"])
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
        "--opponent", opp_mode,
        "--map", args.map,
        "--race", race,
        "--step-size", str(args.step_size),
    ]
    if enemy_race:
        inner_cmd.extend(["--enemy-race", enemy_race])
    if custom_scenarios_in_container:
        inner_cmd.extend(["--scenarios", custom_scenarios_in_container])
    if scenario_ids:
        inner_cmd.extend(["--scenario-ids", ",".join(scenario_ids)])
    else:
        if getattr(args, "scenario", ""):
            inner_cmd.extend(["--scenario", args.scenario])
        if getattr(args, "terrain", ""):
            inner_cmd.extend(["--terrain", args.terrain])
        if getattr(args, "source", ""):
            inner_cmd.extend(["--source", args.source])
        if getattr(args, "tier", "") and getattr(args, "tier", "") != "all":
            inner_cmd.extend(["--tier", args.tier])
        if getattr(args, "category", ""):
            inner_cmd.extend(["--category", args.category])
        if getattr(args, "suite", ""):
            inner_cmd.extend(["--suite", args.suite])
    if replay_host_path is not None:
        inner_cmd.extend(["--save-replay-path", f"/out-replays/{replay_host_path.name}"])
    cmd = ["podman", "run", "--rm", "--network", "none", *mounts, args.image, *inner_cmd]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"Container failed for race={race} enemy_race={enemy_race or 'any'} opp={opp_mode} "
            f"batch={batch_tag or 'single'} (rc={proc.returncode}):\n{proc.stderr}\n{proc.stdout}"
        )
    out = json.loads(proc.stdout)
    if replay_host_path is not None:
        out["replay_path"] = str(replay_host_path)
    return out


def _load_3d_renderer(repo_dir: Path) -> Any:
    loop_dir = repo_dir / "tools" / "iteration-loop"
    if not (loop_dir / "sc2_3d_renderer.py").is_file():
        loop_dir = DEFAULT_REPO_DIR / "tools" / "iteration-loop"
    if not (loop_dir / "sc2_3d_renderer.py").is_file():
        raise FileNotFoundError(f"3D renderer not found in {loop_dir}")
    loop_dir_str = str(loop_dir.resolve())
    if loop_dir_str not in sys.path:
        sys.path.insert(0, loop_dir_str)
    import sc2_3d_renderer  # type: ignore[import-not-found]
    return sc2_3d_renderer


def _build_aggregate_report(
    args: argparse.Namespace,
    all_scens: list[dict[str, Any]],
    sc2_wall_ms: float,
    opp_mode: str,
) -> dict[str, Any]:
    win_tag = "Mothman-P1" if opp_mode == "self" else "Mothman"
    loss_tags = ("Mothman-P2",) if opp_mode == "self" else ("MicroDummy",)

    def _tally_slice(rows: list[dict[str, Any]]) -> dict[str, Any]:
        w_rows = [s for s in rows if s.get("winner") == win_tag]
        l_rows = [s for s in rows if s.get("winner") in loss_tags]
        d_rows = [s for s in rows if s.get("winner") not in (win_tag, *loss_tags)]
        ko_w = sum(1 for s in w_rows if s.get("win_type", "ko") == "ko")
        pts_w = sum(1 for s in w_rows if s.get("win_type") in ("points", "escape_jump_pass"))
        econ_w = sum(1 for s in w_rows if s.get("win_type") == "econ_pass")
        runby_w = sum(1 for s in w_rows if s.get("win_type") == "runby_pass")
        ko_l = sum(1 for s in l_rows if s.get("win_type", "ko") == "ko")
        pts_l = sum(1 for s in l_rows if s.get("win_type") == "points")
        econ_l = sum(1 for s in l_rows if s.get("win_type") == "econ_fail")
        runby_l = sum(1 for s in l_rows if s.get("win_type") == "runby_fail")
        w, l, d = len(w_rows), len(l_rows), len(d_rows)
        if econ_w or econ_l or runby_w or runby_l:
            rec_str = (
                f"{w}W-{l}L-{d}D (KO {ko_w}/Pts {pts_w}/Econ {econ_w}/Runby {runby_w} "
                f"- KO {ko_l}/Pts {pts_l}/Econ {econ_l}/Runby {runby_l} - {d}D)"
            )
        else:
            rec_str = f"{w}W-{l}L-{d}D (KO {ko_w}/Pts {pts_w} - KO {ko_l}/Pts {pts_l} - {d}D)"
        return {
            "mothman_wins": w,
            "ko_wins": ko_w,
            "points_wins": pts_w,
            "econ_wins": econ_w,
            "runby_wins": runby_w,
            "p2_wins": l,
            "ko_losses": ko_l,
            "points_losses": pts_l,
            "econ_losses": econ_l,
            "runby_losses": runby_l,
            "draws": d,
            "timeouts": d,  # backward-compatible alias
            "record_str": rec_str,
        }

    tot_t = _tally_slice(all_scens)
    tot_p1_lost = sum(float(s.get("p1_lost_val", 0.0)) for s in all_scens)
    tot_p2_lost = sum(float(s.get("p2_lost_val", 0.0)) for s in all_scens)
    agg_trade = round(tot_p2_lost / max(1.0, tot_p1_lost), 2) if tot_p1_lost > 0 else 99.0
    tot_atk = sum(int(s.get("mothman_attack_unit_cmds", 0)) for s in all_scens)
    tot_mov = sum(int(s.get("mothman_move_unit_cmds", 0)) for s in all_scens)
    tot_spl = sum(int(s.get("mothman_spell_unit_cmds", 0)) for s in all_scens)
    by_race: dict[str, Any] = {}
    for r in ["Protoss", "Terran", "Zerg"]:
        rs = [s for s in all_scens if s.get("race") == r]
        if not rs:
            continue
        r_p1 = sum(float(s.get("p1_lost_val", 0.0)) for s in rs)
        r_p2 = sum(float(s.get("p2_lost_val", 0.0)) for s in rs)
        r_atk = sum(int(s.get("mothman_attack_unit_cmds", 0)) for s in rs)
        r_mov = sum(int(s.get("mothman_move_unit_cmds", 0)) for s in rs)
        r_spl = sum(int(s.get("mothman_spell_unit_cmds", 0)) for s in rs)
        rt = _tally_slice(rs)
        by_race[r] = {
            "total": len(rs),
            **rt,
            "agg_trade_ratio": round(r_p2 / max(1.0, r_p1), 2) if r_p1 > 0 else 99.0,
            "attack_unit_cmds": r_atk,
            "move_unit_cmds": r_mov,
            "spell_unit_cmds": r_spl,
            "am_ratio": round(r_atk / max(1, r_mov), 2),
        }
    by_tier: dict[str, Any] = {}
    for tname in VALID_TIERS:
        ts = [s for s in all_scens if s.get("tier", "canonical") == tname]
        if not ts:
            continue
        t_p1 = sum(float(s.get("p1_lost_val", 0.0)) for s in ts)
        t_p2 = sum(float(s.get("p2_lost_val", 0.0)) for s in ts)
        t_atk = sum(int(s.get("mothman_attack_unit_cmds", 0)) for s in ts)
        t_mov = sum(int(s.get("mothman_move_unit_cmds", 0)) for s in ts)
        t_spl = sum(int(s.get("mothman_spell_unit_cmds", 0)) for s in ts)
        tt = _tally_slice(ts)
        t_entry: dict[str, Any] = {
            "total": len(ts),
            **tt,
            "agg_trade_ratio": round(t_p2 / max(1.0, t_p1), 2) if t_p1 > 0 else 99.0,
            "attack_unit_cmds": t_atk,
            "move_unit_cmds": t_mov,
            "spell_unit_cmds": t_spl,
            "am_ratio": round(t_atk / max(1, t_mov), 2),
        }
        econ_rows = [s for s in ts if s.get("scoring_mode") == "mineral-defense"]
        if econ_rows:
            t_entry["econ_passes"] = sum(1 for s in econ_rows if s.get("win_type") == "econ_pass")
            t_entry["econ_fails"] = sum(1 for s in econ_rows if s.get("win_type") != "econ_pass")
            t_entry["avg_net_econ_score"] = round(sum(float(s.get("net_econ_score", 0.0)) for s in econ_rows) / len(econ_rows), 1)
            t_entry["avg_minerals_gathered"] = round(sum(float(s.get("minerals_gathered", 0.0)) for s in econ_rows) / len(econ_rows), 1)
            t_entry["avg_mining_uptime_pct"] = round(sum(float(s.get("mining_uptime_pct", 0.0)) for s in econ_rows) / len(econ_rows), 1)
            t_entry["total_workers_lost"] = sum(int(s.get("workers_lost", 0)) for s in econ_rows)
        runby_rows = [s for s in ts if s.get("scoring_mode") == "worker-runby"]
        if runby_rows:
            t_entry["runby_passes"] = sum(1 for s in runby_rows if s.get("win_type") == "runby_pass")
            t_entry["runby_fails"] = sum(1 for s in runby_rows if s.get("win_type") != "runby_pass")
            t_entry["avg_runby_score"] = round(sum(float(s.get("runby_score", 0.0)) for s in runby_rows) / len(runby_rows), 1)
            t_entry["total_enemy_workers_killed"] = sum(int(s.get("enemy_workers_killed", 0)) for s in runby_rows)
            t_entry["avg_enemy_minerals_denied"] = round(sum(float(s.get("enemy_minerals_denied", 0.0)) for s in runby_rows) / len(runby_rows), 1)
        by_tier[tname] = t_entry

    by_category: dict[str, Any] = {}
    for cname in VALID_CATEGORIES:
        cs = [s for s in all_scens if s.get("category") == cname]
        if not cs:
            continue
        c_p1 = sum(float(s.get("p1_lost_val", 0.0)) for s in cs)
        c_p2 = sum(float(s.get("p2_lost_val", 0.0)) for s in cs)
        ct = _tally_slice(cs)
        c_entry: dict[str, Any] = {
            "total": len(cs),
            **ct,
            "agg_trade_ratio": round(c_p2 / max(1.0, c_p1), 2) if c_p1 > 0 else 99.0,
            "detectors_destroyed": sum(int(s.get("detectors_destroyed", 0)) for s in cs),
            "enemy_workers_killed": sum(int(s.get("enemy_workers_killed", 0)) for s in cs),
        }
        by_category[cname] = c_entry

    summary: dict[str, Any] = {
        "total": len(all_scens),
        **tot_t,
        "agg_trade_ratio": agg_trade,
        "total_p1_lost_val": round(tot_p1_lost, 1),
        "total_p2_lost_val": round(tot_p2_lost, 1),
        "total_attack_unit_cmds": tot_atk,
        "total_move_unit_cmds": tot_mov,
        "total_spell_unit_cmds": tot_spl,
        "am_ratio": round(tot_atk / max(1, tot_mov), 2),
        "total_detectors_destroyed": sum(int(s.get("detectors_destroyed", 0)) for s in all_scens),
        "total_enemy_workers_killed": sum(int(s.get("enemy_workers_killed", 0)) for s in all_scens),
        "by_race": by_race,
        "by_tier": by_tier,
        "by_category": by_category,
    }
    if opp_mode == "self":
        tot_p2_atk = sum(int(s.get("p2_attack_unit_cmds", 0)) for s in all_scens)
        tot_p2_mov = sum(int(s.get("p2_move_unit_cmds", 0)) for s in all_scens)
        tot_p2_spl = sum(int(s.get("p2_spell_unit_cmds", 0)) for s in all_scens)
        summary["p2_total_attack_unit_cmds"] = tot_p2_atk
        summary["p2_total_move_unit_cmds"] = tot_p2_mov
        summary["p2_total_spell_unit_cmds"] = tot_p2_spl
        summary["p2_am_ratio"] = round(tot_p2_atk / max(1, tot_p2_mov), 2)
    return {
        "mode": "duel",
        "opponent_mode": opp_mode,
        "engine": "SC2_x64_Base75689",
        "map": args.map,
        "sc2_duel_wall_ms": sc2_wall_ms,
        "total_wall_ms": sc2_wall_ms,
        "summary": summary,
        "scenarios": all_scens,
    }


DEFAULT_P1_COLOR: tuple[int, int, int] = (225, 55, 55)
DEFAULT_P2_COLOR: tuple[int, int, int] = (55, 145, 255)
DEFAULT_MAX_RENDER_FRAMES: int = 480
DEFAULT_VIDEO_FORMAT: str = "mp4"


def format_arena_player_names(r1: str, r2: str, opp_mode: str) -> tuple[str, str]:
    r1_s = (r1 or "P").strip()[:1].upper() or "P"
    r2_s = (r2 or "T").strip()[:1].upper() or "T"
    p1_name = f"Mothman-{r1_s}"
    p2_name = f"Mothman-{r2_s}-SP" if opp_mode == "self" else "MicroDummy"
    return p1_name, p2_name


def build_render_race_spec(
    r1: str,
    r2: str,
    btag: str,
    opp_mode: str,
    map_host_path: str,
    replay_path: str,
    duels: list[dict[str, Any]],
    p1_color: tuple[int, int, int] = DEFAULT_P1_COLOR,
    p2_color: tuple[int, int, int] = DEFAULT_P2_COLOR,
) -> dict[str, Any]:
    p1_name, p2_name = format_arena_player_names(r1, r2, opp_mode)
    enriched_duels = []
    for d in duels:
        ed = dict(d)
        ed.setdefault("race", r1)
        ed.setdefault("enemy_race", r2)
        ed.setdefault("opponent_mode", opp_mode)
        ed["p1_name"] = ed.get("p1_name") or p1_name
        ed["p2_name"] = ed.get("p2_name") or p2_name
        ed["bot"] = ed.get("bot") or ed["p1_name"]
        ed["p2_bot"] = ed.get("p2_bot") or ed["p2_name"]
        ed["p1_color"] = tuple(ed.get("p1_color") or p1_color)
        ed["p2_color"] = tuple(ed.get("p2_color") or p2_color)
        enriched_duels.append(ed)
    return {
        "race": btag,
        "our_race": r1,
        "enemy_race": r2,
        "opponent_mode": opp_mode,
        "bot": f"{p1_name} vs {p2_name}" if opp_mode == "self" else p1_name,
        "p1_name": p1_name,
        "p2_name": p2_name,
        "p1_color": tuple(p1_color),
        "p2_color": tuple(p2_color),
        "map_path": map_host_path,
        "replay_path": replay_path,
        "duels": enriched_duels,
    }


def extract_sc2_early_game_end(
    resp_status: int,
    player_results: Any,
    ended_status: int = 4,
) -> tuple[bool, str | None, int]:
    """Detect early SC2 match termination (`Defeat`/`Victory`/`Tie` or `status == ended`).

    Returns `(ended_now, end_reason, ko_winner_side)` where `ko_winner_side` is `1` (P1 win),
    `2` (P2 win), or `0` (tie/unknown). Ensures early-ended batch duels (e.g., home TownHall
    destroyed mid-duel) are always finalized & recorded in output JSON instead of dropped.
    """
    p1_res = None
    p2_res = None
    for pr in (player_results or ()):
        pid = int(getattr(pr, "player_id", 0))
        rcode = int(getattr(pr, "result", 0))
        if pid == 1:
            p1_res = rcode
        elif pid == 2:
            p2_res = rcode
    if p1_res == 1:
        return True, "sc2_game_victory", 1
    if p1_res == 2:
        return True, "sc2_game_defeat", 2
    if p1_res == 3:
        return True, "sc2_game_tie", 0
    if p2_res == 1:
        return True, "sc2_game_defeat", 2
    if p2_res == 2:
        return True, "sc2_game_victory", 1
    if p2_res == 3:
        return True, "sc2_game_tie", 0
    if int(resp_status or 0) == int(ended_status):
        return True, "sc2_game_ended", 0
    return False, None, 0


def run_host_driver(args: argparse.Namespace) -> int:
    t0 = time.monotonic()
    repo_dir = Path(args.repo_dir).resolve()
    opp_mode = getattr(args, "opponent", "dummy")
    all_specs = load_scenarios(getattr(args, "scenarios", ""), repo_dir)
    if getattr(args, "validate", False):
        errs = validate_scenarios(all_specs)
        if errs:
            for e in errs:
                print(f"VALIDATION ERROR: {e}", file=sys.stderr)
            return 1
        if not getattr(args, "list", False):
            fc_n = sum(1 for s in all_specs if s.fast_core)
            print(f"VALIDATED OK: {len(all_specs)} scenarios ({fc_n} fast_core) across {len({s.category for s in all_specs})} categories.")
            return 0
    eff_suite = resolve_effective_suite(
        getattr(args, "suite", ""),
        getattr(args, "scenario", ""),
        getattr(args, "category", ""),
        getattr(args, "scenario_ids", ""),
    )
    if getattr(args, "list", False):
        list_suite = getattr(args, "suite", "") or "all"
        listed_specs = filter_scenarios(
            all_specs,
            args.race,
            getattr(args, "scenario", ""),
            getattr(args, "enemy_race", ""),
            getattr(args, "terrain", ""),
            getattr(args, "source", ""),
            getattr(args, "tier", "all"),
            getattr(args, "category", ""),
            list_suite,
        )
        print_scenario_listing(listed_specs, validated=bool(getattr(args, "validate", False)))
        return 0
    matched_specs = filter_scenarios(
        all_specs,
        args.race,
        getattr(args, "scenario", ""),
        getattr(args, "enemy_race", ""),
        getattr(args, "terrain", ""),
        getattr(args, "source", ""),
        getattr(args, "tier", "all"),
        getattr(args, "category", ""),
        eff_suite,
    )

    render_dir = Path(args.render_dir).resolve() if getattr(args, "render_dir", "") else None
    save_replays_dir: Path | None = None
    if getattr(args, "save_replays_dir", ""):
        save_replays_dir = Path(args.save_replays_dir).resolve()
    elif render_dir is not None:
        save_replays_dir = render_dir / "replays"
    map_host_path = str((Path(args.maps_dir).resolve() / args.map))
    max_workers = max(1, int(getattr(args, "workers", 3)))

    race_reports_for_render: list[dict[str, Any]] = []
    if args.mode == "duel":
        batches = partition_duel_batches(matched_specs)
        batch_keys: list[tuple[str, str, int, list[SkirmishSpec]]] = batches
        with concurrent.futures.ThreadPoolExecutor(max_workers=min(max_workers, max(1, len(batch_keys)))) as pool:
            futs = {}
            for r1, r2, b_idx, b_specs in batch_keys:
                btag = f"{r1}_vs_{r2}_b{b_idx}"
                fut = pool.submit(
                    run_single_container,
                    args,
                    r1,
                    save_replays_dir,
                    r2,
                    [s.id for s in b_specs],
                    btag,
                )
                futs[fut] = (r1, r2, b_idx, btag)
            sub_reports: dict[str, dict[str, Any]] = {}
            for fut in concurrent.futures.as_completed(futs):
                r1, r2, b_idx, btag = futs[fut]
                sub_reports[btag] = fut.result()

        by_id_res: dict[str, dict[str, Any]] = {}
        extra_res: list[dict[str, Any]] = []
        for r1, r2, b_idx, _b_specs in batch_keys:
            btag = f"{r1}_vs_{r2}_b{b_idx}"
            sr = sub_reports[btag]
            for sc_res in sr.get("scenarios", []):
                sid = sc_res.get("id")
                if sid:
                    by_id_res[sid] = sc_res
                else:
                    extra_res.append(sc_res)
            if sr.get("debug_errors") or sr.get("bot1_log_tail") or sr.get("bot2_log_tail"):
                print(
                    f"[DEBUG {opp_mode} {btag}] phase={sr.get('debug_phase')} errors={sr.get('debug_errors')}\n"
                    f"  bot1_tail={sr.get('bot1_log_tail', '')[-400:]}\n"
                    f"  bot2_tail={sr.get('bot2_log_tail', '')[-400:]}",
                    file=sys.stderr,
                )
            if sr.get("replay_path"):
                race_reports_for_render.append(
                    build_render_race_spec(
                        r1=r1,
                        r2=r2,
                        btag=btag,
                        opp_mode=opp_mode,
                        map_host_path=map_host_path,
                        replay_path=sr["replay_path"],
                        duels=sr.get("scenarios", []),
                        p1_color=DEFAULT_P1_COLOR,
                        p2_color=DEFAULT_P2_COLOR,
                    )
                )

        # L46-P0-3a: If an early SC2 Defeat/Victory ended a multi-scenario container mid-batch,
        # automatically run a single clean recovery wave for any unrun trailing scenarios so
        # every requested scenario (`66/66`) is always recorded & rendered!
        missing_specs = [s for s in matched_specs if s.id not in by_id_res]
        if missing_specs:
            retry_batches = partition_duel_batches(missing_specs)
            with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(max_workers, max(1, len(retry_batches)))
            ) as retry_pool:
                retry_futs = {}
                for r1, r2, b_idx, b_specs in retry_batches:
                    btag = f"{r1}_vs_{r2}_retry_b{b_idx}"
                    fut = retry_pool.submit(
                        run_single_container,
                        args,
                        r1,
                        save_replays_dir,
                        r2,
                        [s.id for s in b_specs],
                        btag,
                    )
                    retry_futs[fut] = (r1, r2, b_idx, btag)
                retry_reports: dict[str, dict[str, Any]] = {}
                for fut in concurrent.futures.as_completed(retry_futs):
                    r1, r2, b_idx, btag = retry_futs[fut]
                    retry_reports[btag] = fut.result()
            for r1, r2, b_idx, _b_specs in retry_batches:
                btag = f"{r1}_vs_{r2}_retry_b{b_idx}"
                sr = retry_reports[btag]
                for sc_res in sr.get("scenarios", []):
                    sid = sc_res.get("id")
                    if sid and sid not in by_id_res:
                        by_id_res[sid] = sc_res
                if sr.get("debug_errors") or sr.get("bot1_log_tail") or sr.get("bot2_log_tail"):
                    print(
                        f"[DEBUG {opp_mode} {btag}] phase={sr.get('debug_phase')} errors={sr.get('debug_errors')}\n"
                        f"  bot1_tail={sr.get('bot1_log_tail', '')[-400:]}\n"
                        f"  bot2_tail={sr.get('bot2_log_tail', '')[-400:]}",
                        file=sys.stderr,
                    )
                if sr.get("replay_path"):
                    race_reports_for_render.append(
                        build_render_race_spec(
                            r1=r1,
                            r2=r2,
                            btag=btag,
                            opp_mode=opp_mode,
                            map_host_path=map_host_path,
                            replay_path=sr["replay_path"],
                            duels=sr.get("scenarios", []),
                            p1_color=DEFAULT_P1_COLOR,
                            p2_color=DEFAULT_P2_COLOR,
                        )
                    )

        all_scens = [by_id_res[s.id] for s in matched_specs if s.id in by_id_res] + extra_res
        sc2_wall_ms = round((time.monotonic() - t0) * 1000.0, 1)
        report = _build_aggregate_report(args, all_scens, sc2_wall_ms, opp_mode)
    else:
        target_race = matched_specs[0].our_race if args.race.lower() != "all" else args.race
        target_enemy = getattr(args, "enemy_race", "")
        report = run_single_container(args, target_race, save_replays_dir, enemy_race=target_enemy)
        sc2_wall_ms = round((time.monotonic() - t0) * 1000.0, 1)
        report["sc2_duel_wall_ms"] = sc2_wall_ms

    if render_dir is not None and args.mode == "duel" and race_reports_for_render:
        t_ren0 = time.monotonic()
        render_dir.mkdir(parents=True, exist_ok=True)
        renderer = _load_3d_renderer(Path(args.repo_dir).resolve())
        video_fmt = str(getattr(args, "video_format", DEFAULT_VIDEO_FORMAT) or DEFAULT_VIDEO_FORMAT).strip().lower()
        max_render_frames = max(1, int(getattr(args, "max_render_frames", DEFAULT_MAX_RENDER_FRAMES)))
        global_p1_name = (
            race_reports_for_render[0]["p1_name"]
            if len(race_reports_for_render) == 1
            else "Mothman"
        )
        global_p2_name = (
            race_reports_for_render[0]["p2_name"]
            if len(race_reports_for_render) == 1
            else ("Mothman-SP" if opp_mode == "self" else "MicroDummy")
        )
        render_res = renderer.render_arena_replays_parallel(
            race_specs=race_reports_for_render,
            out_dir=render_dir,
            step=args.render_step,
            fps=args.render_fps,
            render_size=(960, 720),
            minimap_size=(180, 180),
            webp_size=(800, 600),
            max_frames_per_duel=max_render_frames,
            workers=min(max_workers, len(race_reports_for_render)),
            video_format=video_fmt,
            p1_name=global_p1_name,
            p2_name=global_p2_name,
            p1_color=DEFAULT_P1_COLOR,
            p2_color=DEFAULT_P2_COLOR,
        )
        render_wall_ms = round((time.monotonic() - t_ren0) * 1000.0, 1)
        report["render_3d_wall_ms"] = render_wall_ms
        report["total_wall_ms"] = round((time.monotonic() - t0) * 1000.0, 1)
        report["visuals"] = render_res if isinstance(render_res, dict) else {"render_dir": str(render_dir)}

    if args.compare:
        base_path = Path(args.compare)
        if base_path.is_file():
            base_doc = json.loads(base_path.read_text(encoding="utf-8"))
            base_by_id = {s["id"]: s for s in base_doc.get("scenarios", []) if "id" in s}
            cur_by_id = {s["id"]: s for s in report.get("scenarios", []) if "id" in s}
            common_ids = [sid for sid in cur_by_id if sid in base_by_id]
            win_set = {"Mothman", "Mothman-P1"}
            c_wins_base = sum(1 for sid in common_ids if base_by_id[sid].get("winner") in win_set)
            c_wins_cur = sum(1 for sid in common_ids if cur_by_id[sid].get("winner") in win_set)
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
                "flipped_to_win": [x["id"] for x in per_scen if x["prev_winner"] not in win_set and x["winner"] in win_set],
                "flipped_from_win": [x["id"] for x in per_scen if x["prev_winner"] in win_set and x["winner"] not in win_set],
                "by_scenario": per_scen,
            }

    out_target = args.out or getattr(args, "json_out", "")
    if out_target:
        out_path = Path(out_target)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    rsum = report.get("summary") or {}
    if rsum.get("record_str"):
        print(
            f"[ARENA 3.0 {opp_mode}] {rsum['record_str']} | Trade={rsum.get('agg_trade_ratio')}x | "
            f"A:M={rsum.get('am_ratio')} | wall={report.get('total_wall_ms')}ms",
            file=sys.stderr,
        )
        bt = rsum.get("by_tier") or {}
        if bt:
            parts = []
            for tn in VALID_TIERS:
                if tn in bt:
                    te = bt[tn]
                    sub: list[str] = []
                    if "econ_passes" in te:
                        sub.append(
                            f"def={te['econ_passes']}P-{te['econ_fails']}F "
                            f"(net={te['avg_net_econ_score']}M, mined={te['avg_minerals_gathered']}M, "
                            f"up={te['avg_mining_uptime_pct']}%, wlost={te['total_workers_lost']})"
                        )
                    if "runby_passes" in te:
                        sub.append(
                            f"runby={te['runby_passes']}P-{te['runby_fails']}F "
                            f"(score={te['avg_runby_score']}, wkills={te['total_enemy_workers_killed']}, "
                            f"denied={te['avg_enemy_minerals_denied']}M)"
                        )
                    if sub:
                        parts.append(f"{tn}: {'; '.join(sub)}")
                    else:
                        parts.append(f"{tn}: {te['mothman_wins']}W-{te['p2_wins']}L-{te['draws']}D ({te['agg_trade_ratio']}x)")
            if parts:
                print(f"[ARENA 3.0 by_tier] {' | '.join(parts)}", file=sys.stderr)
        vis = report.get("visuals") or {}
        if isinstance(vis, dict) and vis.get("clips_count") is not None:
            vfmt_out = vis.get("video_format") or "mp4"
            vbytes = int(vis.get("total_video_bytes") or vis.get("total_mp4_bytes") or vis.get("total_webp_bytes") or 0)
            print(
                f"[ARENA 3.0 3d] fmt={vfmt_out} clips={vis.get('clips_count')} "
                f"max_frames={vis.get('max_frames_per_duel')} bytes={vbytes} "
                f"wall={report.get('render_3d_wall_ms')}ms",
                file=sys.stderr,
            )
    print(json.dumps(report, indent=2))
    return 0


# -----------------------------------------------------------------------------
# In-Container Real-SC2 Map Terrain Geometry Analyzer
# -----------------------------------------------------------------------------
class MapTerrainAnalyzer:
    """Computes real SC2 map arena sites for all 5 terrain modes."""

    def __init__(self, game_info: Any) -> None:
        sr = game_info.start_raw
        self.pg = sr.pathing_grid
        self.plg = sr.placement_grid
        self.th = sr.terrain_height
        self.w = int(self.pg.size.x)
        self.h = int(self.pg.size.y)
        self.pg_data = self.pg.data
        self.pg_bpp = int(self.pg.bits_per_pixel)
        self.plg_data = self.plg.data
        self.plg_bpp = int(self.plg.bits_per_pixel)
        self.th_data = self.th.data
        self.th_w = int(self.th.size.x)
        self.th_h = int(self.th.size.y)
        self.start_locs = [(float(p.x), float(p.y)) for p in sr.start_locations]
        self.sites: dict[str, ArenaSite] = {}
        self.sites["open"] = self._find_open_site(rx=8, ry=5)
        self.sites["flank-surround"] = self._find_open_site(rx=10, ry=8, fallback=self.sites["open"])
        self.sites["high-ground-ramp"] = self._find_ramp_site(fallback=self.sites["open"])
        self.sites["cliff-air-chasm"] = self._find_cliff_chasm_site(fallback=self.sites["open"])
        self.sites["mineral-line-harass"] = self.sites["open"]  # refined once obs minerals arrive

    def is_pathable(self, x: int, y: int, margin: int = 8) -> bool:
        if x < margin or y < margin or x >= self.w - margin or y >= self.h - margin:
            return False
        idx = y * self.w + x
        if self.pg_bpp == 1:
            return bool((self.pg_data[idx // 8] >> (7 - (idx % 8))) & 1)
        return self.pg_data[idx] != 0

    def is_buildable(self, x: int, y: int, margin: int = 8) -> bool:
        if x < margin or y < margin or x >= self.w - margin or y >= self.h - margin:
            return False
        idx = y * self.w + x
        if self.plg_bpp == 1:
            return bool((self.plg_data[idx // 8] >> (7 - (idx % 8))) & 1)
        return self.plg_data[idx] != 0

    def find_buildable_spots(
        self,
        anchor_x: float,
        anchor_y: float,
        count: int,
        avoid: list[tuple[float, float]] | None = None,
        with_addon: bool = False,
        min_spacing: float = 5.5,
        avoid_large: list[tuple[float, float]] | None = None,
        large_radius: float = 12.0,
    ) -> list[tuple[float, float]]:
        """Find `count` clean buildable 3x3 (or 5x3+margin with Terran addon) building centers near anchor."""
        chosen: list[tuple[float, float]] = []
        avoid_pts = list(avoid or [])
        avoid_big = list(avoid_large or [])
        ax, ay = int(round(anchor_x)), int(round(anchor_y))
        x_hi = 5 if with_addon else 2
        y_lo = -2 if with_addon else -1

        def _ok(cx: int, cy: int) -> bool:
            bx, by = cx + 0.5, cy + 0.5
            if any(math.hypot(bx - ox, by - oy) < large_radius for ox, oy in avoid_big):
                return False
            if with_addon and any(
                math.hypot((bx + 2.5) - ox, (by - 0.5) - oy) < max(6.0, large_radius - 1.5)
                for ox, oy in avoid_big
            ):
                return False
            if any(math.hypot(bx - ox, by - oy) < 5.5 for ox, oy in avoid_pts):
                return False
            if any(math.hypot(bx - ox, by - oy) < min_spacing for ox, oy in chosen):
                return False
            for dx in range(-1, x_hi):
                for dy in range(y_lo, 2):
                    if not self.is_buildable(cx + dx, cy + dy, margin=10):
                        return False
            return True

        for rad in range(4, 34, 2):
            for dx in range(-rad, rad + 1, 2):
                for dy in (-rad, rad) if abs(dx) < rad else range(-rad, rad + 1, 2):
                    tx, ty = ax + dx, ay + dy
                    if _ok(tx, ty):
                        chosen.append((tx + 0.5, ty + 0.5))
                        if len(chosen) >= count:
                            return chosen
        while len(chosen) < count:
            fx, fy = self.snap_pathable(anchor_x + len(chosen) * 5.0, anchor_y, max_rad=8)
            chosen.append((float(round(fx)) + 0.5, float(round(fy)) + 0.5))
        return chosen

    def height_at(self, x: int, y: int) -> int:
        cx = max(0, min(self.th_w - 1, int(round(x))))
        cy = max(0, min(self.th_h - 1, int(round(y))))
        return int(self.th_data[cy * self.th_w + cx])

    def near_start(self, x: float, y: float, min_dist: float = 24.0) -> bool:
        return any(math.hypot(x - sx, y - sy) < min_dist for sx, sy in self.start_locs)

    def snap_buildable_footprint(
        self,
        x: float,
        y: float,
        footprint_size: int = 2,
        avoid: list[tuple[float, float, float]] | None = None,
        max_rad: int = 12,
        creep_img: Any = None,
    ) -> tuple[float, float]:
        """Find closest buildable grid center for an NxN structure (5x5 uses .5 center, 2x2 uses integer center)."""
        half_off = 0.5 if (footprint_size % 2 == 1) else 0.0
        lo = -(footprint_size // 2)
        hi = lo + footprint_size
        ix, iy = int(round(x - half_off)), int(round(y - half_off))
        avoid_list = avoid or []

        def _is_creep(cx_t: int, cy_t: int) -> bool:
            if creep_img is None or not getattr(creep_img, "data", None):
                return True
            cw = int(creep_img.size.x)
            ch = int(creep_img.size.y)
            if cx_t < 0 or cy_t < 0 or cx_t >= cw or cy_t >= ch:
                return False
            idx = cy_t * cw + cx_t
            bpp = int(creep_img.bits_per_pixel)
            if bpp == 1:
                return bool((creep_img.data[idx // 8] >> (7 - (idx % 8))) & 1)
            return creep_img.data[idx] != 0

        def ok(cx_i: int, cy_i: int, check_creep: bool) -> bool:
            cx_f, cy_f = cx_i + half_off, cy_i + half_off
            if any(math.hypot(cx_f - ax, cy_f - ay) < ar for ax, ay, ar in avoid_list):
                return False
            for ox in range(lo, hi):
                for oy in range(lo, hi):
                    if not self.is_buildable(cx_i + ox, cy_i + oy, margin=8):
                        return False
                    if check_creep and not _is_creep(cx_i + ox, cy_i + oy):
                        return False
            return True

        passes = (True, False) if (creep_img is not None and getattr(creep_img, "data", None)) else (False,)
        for check_creep in passes:
            if ok(ix, iy, check_creep):
                return float(ix) + half_off, float(iy) + half_off
            for rad in range(1, max_rad + 1):
                best: tuple[float, float, float] | None = None
                for dx in range(-rad, rad + 1):
                    for dy in range(-rad, rad + 1):
                        if max(abs(dx), abs(dy)) != rad:
                            continue
                        tx, ty = ix + dx, iy + dy
                        if ok(tx, ty, check_creep):
                            cx_f, cy_f = tx + half_off, ty + half_off
                            d2 = (cx_f - x) ** 2 + (cy_f - y) ** 2
                            if best is None or d2 < best[0]:
                                best = (d2, cx_f, cy_f)
                if best is not None:
                    return best[1], best[2]
        return float(ix) + half_off, float(iy) + half_off

    def site_offset_world(self, site: ArenaSite, dx: float, dy: float) -> tuple[float, float]:
        """Project local (dx, dy) in `site` frame into clamped world coordinates."""
        wx = site.cx + dx * site.ux + dy * site.px
        wy = site.cy + dx * site.uy + dy * site.py
        wx = max(8.0, min(float(self.w - 8), wx))
        wy = max(8.0, min(float(self.h - 8), wy))
        return wx, wy

    def snap_pathable(
        self,
        x: float,
        y: float,
        max_rad: int = 5,
        target_height: int | None = None,
    ) -> tuple[float, float]:
        ix, iy = int(round(x)), int(round(y))

        def ok(tx: int, ty: int) -> bool:
            if not self.is_pathable(tx, ty, margin=6):
                return False
            if target_height is not None and abs(self.height_at(tx, ty) - target_height) > 6:
                return False
            return True

        if ok(ix, iy):
            return float(x), float(y)
        for rad in range(1, max_rad + 1):
            best: tuple[float, int, int] | None = None
            for dx in range(-rad, rad + 1):
                for dy in range(-rad, rad + 1):
                    if max(abs(dx), abs(dy)) != rad:
                        continue
                    tx, ty = ix + dx, iy + dy
                    if ok(tx, ty):
                        d2 = (tx - x) ** 2 + (ty - y) ** 2
                        if best is None or d2 < best[0]:
                            best = (d2, tx, ty)
            if best is not None:
                return float(best[1]), float(best[2])
        if target_height is not None:
            return self.snap_pathable(x, y, max_rad=max_rad + 2, target_height=None)
        return float(x), float(y)

    def _find_open_site(
        self,
        rx: int,
        ry: int,
        fallback: ArenaSite | None = None,
        min_start_dist: float = 28.0,
    ) -> ArenaSite:
        cx0, cy0 = self.w // 2, self.h // 2
        site_kind = "open" if rx <= 8 else "flank-surround"
        for req_dist in ((min_start_dist, 0.0) if min_start_dist > 0.0 else (0.0,)):
            for rad in range(0, 56, 2):
                for dx in range(-rad, rad + 1, 2):
                    for dy in (-rad, rad) if abs(dx) < rad else range(-rad, rad + 1, 2):
                        tx, ty = cx0 + dx, cy0 + dy
                        if req_dist > 0.0 and self.near_start(float(tx), float(ty), min_dist=req_dist):
                            continue
                        if all(
                            self.is_pathable(tx + ox, ty + oy, margin=14)
                            for ox in range(-rx, rx + 1, 2)
                            for oy in range(-ry, ry + 1, 2)
                        ):
                            return ArenaSite(terrain=site_kind, cx=float(tx), cy=float(ty))
        return fallback or ArenaSite(terrain=site_kind, cx=float(cx0), cy=float(cy0))

    def _find_ramp_site(self, fallback: ArenaSite) -> ArenaSite:
        """Locate a walkable ramp transitioning between two distinct SC2 elevation plateaus."""
        dirs = [
            (1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0),
            (0.7071, 0.7071), (-0.7071, 0.7071), (0.7071, -0.7071), (-0.7071, -0.7071),
        ]
        best: tuple[float, ArenaSite] | None = None
        cx0, cy0 = self.w / 2.0, self.h / 2.0
        for y in range(22, self.h - 22, 2):
            for x in range(22, self.w - 22, 2):
                if not self.is_pathable(x, y, margin=14):
                    continue
                if self.near_start(x, y, min_dist=26.0):
                    continue
                for ux, uy in dirs:
                    px, py = -uy, ux
                    hx = int(round(x - 5.0 * ux))
                    hy = int(round(y - 5.0 * uy))
                    lx = int(round(x + 5.0 * ux))
                    ly = int(round(y + 5.0 * uy))
                    if not (self.is_pathable(hx, hy, margin=12) and self.is_pathable(lx, ly, margin=12)):
                        continue
                    hh = self.height_at(hx, hy)
                    lh = self.height_at(lx, ly)
                    if hh - lh < 12:
                        continue
                    # Confirm walkable transition through midpoint & flat plateaus on both sides
                    mid_ok = all(
                        self.is_pathable(int(round(x + s * ux)), int(round(y + s * uy)), margin=12)
                        for s in (-3, -1, 0, 1, 3)
                    )
                    if not mid_ok:
                        continue
                    hi_ok = sum(
                        1
                        for a in (-3, -5, -7)
                        for b in (-2, 0, 2)
                        if self.is_pathable(int(round(x + a * ux + b * px)), int(round(y + a * uy + b * py)), margin=10)
                        and abs(self.height_at(int(round(x + a * ux + b * px)), int(round(y + a * uy + b * py))) - hh) <= 5
                    )
                    lo_ok = sum(
                        1
                        for a in (3, 5, 7)
                        for b in (-2, 0, 2)
                        if self.is_pathable(int(round(x + a * ux + b * px)), int(round(y + a * uy + b * py)), margin=10)
                        and abs(self.height_at(int(round(x + a * ux + b * px)), int(round(y + a * uy + b * py))) - lh) <= 5
                    )
                    if hi_ok >= 7 and lo_ok >= 7:
                        # Prefer central ramps with clean 9/9 plateau support
                        dist_center = math.hypot(x - cx0, y - cy0)
                        score = (hi_ok + lo_ok) * 10.0 - dist_center * 0.4 + min(hh - lh, 32)
                        site = ArenaSite(
                            terrain="high-ground-ramp",
                            cx=float(x),
                            cy=float(y),
                            ux=ux,
                            uy=uy,
                            px=px,
                            py=py,
                            high_height=hh,
                            low_height=lh,
                        )
                        if best is None or score > best[0]:
                            best = (score, site)
        return best[1] if best is not None else fallback

    def _find_cliff_chasm_site(self, fallback: ArenaSite) -> ArenaSite:
        """Locate a pathable ground edge directly overlooking unpathable air chasm/deadspace."""
        dirs = [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)]
        best: tuple[float, ArenaSite] | None = None
        cx0, cy0 = self.w / 2.0, self.h / 2.0
        for y in range(20, self.h - 20, 3):
            for x in range(20, self.w - 20, 3):
                if self.near_start(x, y, min_dist=26.0):
                    continue
                for ux, uy in dirs:
                    px, py = -uy, ux
                    gnd_ok = sum(
                        1
                        for a in (-3, -5, -7)
                        for b in (-3, 0, 3)
                        if self.is_pathable(int(round(x + a * ux + b * px)), int(round(y + a * uy + b * py)), margin=10)
                    )
                    if gnd_ok < 8:
                        continue
                    chasm_ok = sum(
                        1
                        for a in (2, 4, 6, 8)
                        for b in (-3, 0, 3)
                        if not self.is_pathable(int(round(x + a * ux + b * px)), int(round(y + a * uy + b * py)), margin=4)
                        and 8 <= int(round(x + a * ux + b * px)) < self.w - 8
                        and 8 <= int(round(y + a * uy + b * py)) < self.h - 8
                    )
                    if chasm_ok >= 10:
                        dist_center = math.hypot(x - cx0, y - cy0)
                        score = gnd_ok * 6.0 + chasm_ok * 8.0 - dist_center * 0.35
                        site = ArenaSite(
                            terrain="cliff-air-chasm",
                            cx=float(x),
                            cy=float(y),
                            ux=ux,
                            uy=uy,
                            px=px,
                            py=py,
                        )
                        if best is None or score > best[0]:
                            best = (score, site)
        return best[1] if best is not None else fallback

    def refine_mineral_site(self, obs: Any, th_positions: list[tuple[float, float]]) -> None:
        """Find an unoccupied expansion mineral line directly from SC2 mineral field units
        and ensure open/flank-surround sites stay >= 28t clear of ALL starting TownHalls."""
        for tx, ty in th_positions:
            if not any(math.hypot(tx - sx, ty - sy) < 4.0 for sx, sy in self.start_locs):
                self.start_locs.append((float(tx), float(ty)))
        for s_key, rx, ry in (("open", 8, 5), ("flank-surround", 10, 8)):
            cur_s = self.sites.get(s_key)
            if cur_s is not None and self.near_start(cur_s.cx, cur_s.cy, min_dist=28.0):
                self.sites[s_key] = self._find_open_site(
                    rx=rx, ry=ry, fallback=self.sites.get("open"), min_start_dist=28.0,
                )
        mins = [
            (float(u.pos.x), float(u.pos.y))
            for u in obs.raw_data.units
            if u.unit_type in MINERAL_IDS
        ]
        if not mins:
            return
        # Connected-component cluster mineral patches within 10t
        visited = [False] * len(mins)
        clusters: list[list[tuple[float, float]]] = []
        for i in range(len(mins)):
            if visited[i]:
                continue
            q = deque([i])
            visited[i] = True
            comp: list[tuple[float, float]] = []
            while q:
                cur = q.popleft()
                comp.append(mins[cur])
                for j in range(len(mins)):
                    if not visited[j] and math.hypot(mins[cur][0] - mins[j][0], mins[cur][1] - mins[j][1]) <= 10.0:
                        visited[j] = True
                        q.append(j)
            if len(comp) >= 6:
                clusters.append(comp)
        if not clusters:
            return

        # Pick an unoccupied expansion mineral line (far from both starting TownHalls)
        best_site: tuple[float, ArenaSite] | None = None
        cx0, cy0 = self.w / 2.0, self.h / 2.0
        for comp in clusters:
            mx = sum(p[0] for p in comp) / len(comp)
            my = sum(p[1] for p in comp) / len(comp)
            min_th_d = min((math.hypot(mx - tx, my - ty) for tx, ty in th_positions), default=99.0)
            if min_th_d < 22.0:
                continue
            # Find direction away from the mineral arc into the open expansion interior
            best_dir: tuple[float, float, float] | None = None
            for deg in range(0, 360, 15):
                rad = math.radians(deg)
                ux, uy = math.cos(rad), math.sin(rad)
                bx, by = mx + 6.5 * ux, my + 6.5 * uy
                clear = sum(
                    1
                    for ox in (-2, 0, 2)
                    for oy in (-2, 0, 2)
                    if self.is_pathable(int(round(bx + ox)), int(round(by + oy)), margin=10)
                    and all(math.hypot(bx + ox - pmx, by + oy - pmy) >= 2.2 for pmx, pmy in comp)
                )
                if clear >= 8:
                    # Prefer outward direction toward map center
                    to_ctr = (cx0 - mx) * ux + (cy0 - my) * uy
                    sc = clear * 20.0 + to_ctr * 0.2
                    if best_dir is None or sc > best_dir[0]:
                        best_dir = (sc, ux, uy)
            if best_dir is None:
                continue
            _, ux, uy = best_dir
            px, py = -uy, ux
            # Center arena 5.5t out from mineral centroid so dx=-3..0 sits right inside mineral line & dx=+4..6 approaches it
            acx, acy = mx + 5.5 * ux, my + 5.5 * uy
            dist_center = math.hypot(acx - cx0, acy - cy0)
            score = min(min_th_d, 60.0) * 1.5 - dist_center * 0.5 + len(comp) * 2.0
            site = ArenaSite(
                terrain="mineral-line-harass",
                cx=float(acx),
                cy=float(acy),
                ux=ux,
                uy=uy,
                px=px,
                py=py,
            )
            if best_site is None or score > best_site[0]:
                best_site = (score, site)
        if best_site is not None:
            self.sites["mineral-line-harass"] = best_site[1]

    def compute_main_mineral_site(
        self,
        obs: Any,
        th_pos: tuple[float, float],
    ) -> tuple[ArenaSite, list[int], list[tuple[float, float]]]:
        """Build a spawn-symmetric site centered on a player's actual starting main TownHall & mineral line.

        Axis +u points FROM the mineral centroid THROUGH the TownHall into the open base front, so:
          - dx < 0 sits directly between the TownHall and real starting mineral patches (mining workers)
          - dx ~ +1.5..+2.5 sits on the front side of the TownHall (home defenders)
          - dx ~ +8.5..+9.5 sits right outside the starting main (harass entry vector)
        """
        mtags, mpos = extract_main_mineral_info(obs.raw_data.units, th_pos, max_dist=12.0)
        site = build_site_from_mineral_positions(th_pos, mpos, map_center=(self.w / 2.0, self.h / 2.0))
        return site, mtags, mpos

    def resolve_spawn_point(
        self,
        scen: SkirmishSpec,
        unit_name: str,
        dx: float,
        dy: float,
        site_override: ArenaSite | None = None,
    ) -> tuple[float, float]:
        site = site_override or self.sites.get(scen.terrain) or self.sites["open"]
        if scen.terrain == "open" and site_override is None:
            return site.cx + dx, site.cy + dy
        ux, uy, px, py = site.ux, site.uy, site.px, site.py
        if scen.terrain == "high-ground-ramp" and scen.high_ground_side == "p2":
            ux, uy, px, py = -ux, -uy, -px, -py
        wx = site.cx + dx * ux + dy * px
        wy = site.cy + dx * uy + dy * py
        wx = max(8.0, min(float(self.w - 8), wx))
        wy = max(8.0, min(float(self.h - 8), wy))
        uid = UNIT_IDS[unit_name]
        if uid in AIR_UNIT_IDS:
            return wx, wy
        target_h: int | None = None
        if scen.terrain == "high-ground-ramp":
            if dx <= -1.5:
                target_h = site.high_height if scen.high_ground_side == "p1" else site.low_height
            elif dx >= 1.5:
                target_h = site.low_height if scen.high_ground_side == "p1" else site.high_height
        return self.snap_pathable(wx, wy, max_rad=6, target_height=target_h)


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
    PROXY_PORT_1 = 8081
    PROXY_PORT_2 = 8082

    RACE_ENUM = {
        "Protoss": common_pb2.Protoss,
        "Terran": common_pb2.Terran,
        "Zerg": common_pb2.Zerg,
    }
    BOT_MAP = {
        "Protoss": ("Mothman-P", "/mothman-repo/bots/mothman-protoss.rkt"),
        "Terran": ("Mothman-T", "/mothman-repo/bots/mothman-terran.rkt"),
        "Zerg": ("Mothman-Z", "/mothman-repo/bots/mothman-zerg.rkt"),
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

    all_specs = load_scenarios(getattr(args, "scenarios", ""), Path("/mothman-repo"))
    if getattr(args, "scenario_ids", ""):
        by_id = {s.id: s for s in all_specs}
        want_ids = [sid.strip() for sid in args.scenario_ids.split(",") if sid.strip()]
        scenarios = [by_id[sid] for sid in want_ids if sid in by_id]
        if not scenarios:
            raise ValueError(f"No scenarios matched --scenario-ids={args.scenario_ids!r}")
    else:
        eff_suite_in = resolve_effective_suite(
            getattr(args, "suite", ""),
            getattr(args, "scenario", ""),
            getattr(args, "category", ""),
            getattr(args, "scenario_ids", ""),
        )
        scenarios = filter_scenarios(
            all_specs,
            args.race,
            getattr(args, "scenario", ""),
            getattr(args, "enemy_race", ""),
            getattr(args, "terrain", ""),
            getattr(args, "source", ""),
            getattr(args, "tier", "all"),
            getattr(args, "category", ""),
            eff_suite_in,
        )

    opp_mode = getattr(args, "opponent", "dummy")

    try:
        async with aiohttp.ClientSession() as session:
            t_boot0 = time.monotonic()
            sc2_ws = await wait_sc2_port(session, SC2_PORT)
            boot_ms = round((time.monotonic() - t_boot0) * 1000.0, 1)

            if args.mode == "duel":
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
                    bname1, bpath1 = BOT_MAP.get(our_race, BOT_MAP["Protoss"])
                    bname2, bpath2 = BOT_MAP.get(enemy_race, BOT_MAP["Terran"])
                    p2_label = bname2 if opp_mode == "self" else "MicroDummy"

                    def _prepare_bot_dir(bot_name: str, bot_race: str, bot_path: str) -> Path:
                        bdir = Path(tempfile.mkdtemp(prefix=f"mothman_duel_{bot_name}_"))
                        (bdir / "data").mkdir(exist_ok=True)
                        (bdir / "config.json").write_text(
                            json.dumps({"BotName": bot_name, "BotRace": bot_race, "BotPath": bot_path}, indent=2),
                            encoding="utf-8",
                        )
                        (bdir / "data" / "mirror_mind_opponents.json").write_text(
                            json.dumps({"bot_name": bot_name, "opponents": {}}, indent=2), encoding="utf-8"
                        )
                        return bdir

                    bot_dir1 = _prepare_bot_dir(bname1, our_race, bpath1)
                    bot_dir2 = _prepare_bot_dir(bname2, enemy_race, bpath2) if opp_mode == "self" else None

                    dstate: dict[str, Any] = {
                        "analyzer": None,
                        "arena_cx": 88.0,
                        "arena_cy": 88.0,
                        "orig_th_tags": set(),
                        "p1_orig_th_tag": None,
                        "p2_orig_th_tag": None,
                        "p1_orig_th_pos": None,
                        "p2_orig_th_pos": None,
                        "p1_main_mineral_site": None,
                        "p1_main_mineral_tags": [],
                        "p1_main_mineral_positions": [],
                        "p2_main_mineral_site": None,
                        "p2_main_mineral_tags": [],
                        "p2_main_mineral_positions": [],
                        "warmup_spawned_p1_workers": False,
                        "warmup_spawned_p2_workers": False,
                        "warmup_spawned_creep_tumors": False,
                        "warmup_p1_mine_issued": False,
                        "warmup_p2_mine_issued": False,
                        "carrier_fill_cheats_on": False,
                        "carrier_fill_issued_p1": False,
                        "carrier_fill_issued_p2": False,
                        "p2_disruptor_cd": {},
                        "p2_disruptor_next_global": 0,
                        "p1_bc_start_cnt": 0,
                        "p1_bc_alive_cnt": 0,
                        "orig_th_positions": [],
                        "mineral_refined": False,
                        "scen_idx": 0,
                        # wait_init -> clearing -> upgrade_* -> preload_* -> spawning -> fighting -> done
                        "phase": "wait_init",
                        "phase_start_loop": 0,
                        "p2_clear_ok": False,
                        "p1_preload_ready": True,
                        "p2_preload_ready": True,
                        "p1_preload_last_loop": -100,
                        "p2_preload_last_loop": -100,
                        "p2_runby_mine_issued": False,
                        "p2_econ_start_minerals": 0.0,
                        "p2_econ_cur_minerals": 0.0,
                        "p2_pf_start_cnt": 0,
                        "p2_pf_alive_cnt": 0,
                        "p2_det_start_cnt": 0,
                        "p2_det_alive_cnt": 0,
                        "p2_w_start_cnt": 0,
                        "p2_w_alive_cnt": 0,
                        "cheats_enabled_p1": False,
                        "cheats_enabled_p2": False,
                        "pre_setup_free_on": False,
                        "p1_starter_bldg_tags": set(),
                        "pre_setup_placed": [],
                        "pre_setup_instant_positions": {},
                        "pre_setup_inprog": [],
                        "pre_setup_temp_worker_tags": set(),
                        "pre_setup_claimed_geysers": set(),
                        "pre_setup_info": [],
                        "pre_setup_max_loops": 0,
                        "pre_bank_mine_issued": False,
                        "p1_fight_start_minerals": 0,
                        "p2_repair_bank_granted": False,
                        "p2_own_units": None,
                        "p2_own_units_loop": -1,
                        "p1_done_upgrades": set(),
                        "p2_done_upgrades": set(),
                        "p1_accepted_upgrades": set(),
                        "p2_accepted_upgrades": set(),
                        "upg_wave_attempts": 0,
                        "p1_pending_upgrades": [],  # list[(upg_name, bldg_uid, research_ab, x, y)]
                        "p2_pending_upgrades": [],
                        "p1_pending_addons": [],    # list[(parent_uid, addon_ab, addon_uid, x, y)]
                        "p2_pending_addons": [],
                        "p1_addons_issued": False,
                        "p2_addons_issued": False,
                        "p1_addons_ready": False,
                        "p2_addons_ready": False,
                        "p1_upg_issued": False,
                        "p2_upg_issued": False,
                        "p1_upg_busy": False,
                        "p2_upg_busy": False,
                        "p1_upgrade_ids_obs": [],
                        "p2_upgrade_ids_obs": [],
                        "p2_pre_cloak_pending": False,
                        "econ_start_minerals": 0.0,
                        "econ_cur_minerals": 0.0,
                        "econ_start_workers": 0,
                        "econ_seen_worker_tags": set(),
                        "econ_cur_worker_tags": set(),
                        "econ_worker_mining_ticks": 0,
                        "econ_worker_total_ticks": 0,
                        "round_t0": time.monotonic(),
                        "attack_cmds": 0,
                        "move_cmds": 0,
                        "spell_cmds": 0,
                        "ability_counts": {},
                        "p2_attack_cmds": 0,
                        "p2_move_cmds": 0,
                        "p2_spell_cmds": 0,
                        "p2_ability_counts": {},
                        "p1_start_cnt": 0,
                        "p2_start_cnt": 0,
                        "p1_start_types": {},
                        "p2_start_types": {},
                        "p1_start_val": 0.0,
                        "p2_start_val": 0.0,
                        "p1_alive_cnt": 0,
                        "p2_alive_cnt": 0,
                        "p1_combat_alive_cnt": 0,
                        "p2_combat_alive_cnt": 0,
                        "p1_rem_val": 0.0,
                        "p2_rem_val": 0.0,
                        "last_combat_event_loop": 0,
                        "prev_unit_hp_map": {},
                        "results": [],
                        "errors": [],
                        "sc2_ended_reason": None,
                        "sc2_ended_ko_side": 0,
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

                    def _site_for_scen(scen: SkirmishSpec) -> ArenaSite:
                        if scen.use_p2_main_base and dstate["p2_main_mineral_site"] is not None:
                            return dstate["p2_main_mineral_site"]
                        if scen.use_main_base and dstate["p1_main_mineral_site"] is not None:
                            return dstate["p1_main_mineral_site"]
                        an: MapTerrainAnalyzer | None = dstate["analyzer"]
                        if an is None:
                            return ArenaSite(terrain="open", cx=88.0, cy=88.0)
                        return an.sites.get(scen.terrain) or an.sites["open"]

                    async def _issue_preload_cmds(
                        ws: aiohttp.ClientWebSocketResponse,
                        obs: Any,
                        lt_specs: list[dict[str, Any]],
                    ) -> bool:
                        """Issue SC2 Load + Smart commands to pack pre-loaded transports; returns True when loaded."""
                        if not lt_specs:
                            return True
                        t_uids = {UNIT_IDS[lt["transport"]] for lt in lt_specs}
                        c_uids = {UNIT_IDS[cu] for lt in lt_specs for cu, _ in lt["cargo"]}
                        transports = [
                            u for u in obs.raw_data.units
                            if u.alliance == 1 and u.unit_type in t_uids and u.tag not in dstate["orig_th_tags"]
                        ]
                        cargo_loose = [
                            u for u in obs.raw_data.units
                            if u.alliance == 1 and u.unit_type in c_uids and u.tag not in dstate["orig_th_tags"]
                        ]
                        if not transports:
                            return False
                        if not cargo_loose:
                            return True
                        acts_l: list[Any] = []
                        for cu in cargo_loose:
                            tr = min(
                                transports,
                                key=lambda t: (
                                    getattr(t, "cargo_space_taken", 0),
                                    math.hypot(t.pos.x - cu.pos.x, t.pos.y - cu.pos.y),
                                ),
                            )
                            load_ab = TRANSPORT_LOAD_ABILITIES.get(int(tr.unit_type), 3668)
                            acts_l.append(sc2api_pb2.Action(
                                action_raw=raw_pb2.ActionRaw(
                                    unit_command=raw_pb2.ActionRawUnitCommand(
                                        ability_id=load_ab,
                                        target_unit_tag=cu.tag,
                                        unit_tags=[tr.tag],
                                    )
                                )
                            ))
                            acts_l.append(sc2api_pb2.Action(
                                action_raw=raw_pb2.ActionRaw(
                                    unit_command=raw_pb2.ActionRawUnitCommand(
                                        ability_id=1,
                                        target_unit_tag=tr.tag,
                                        unit_tags=[cu.tag],
                                    )
                                )
                            ))
                        if acts_l:
                            await rpc(ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts_l)))
                        return False

                    async def _issue_owner_upgrades(
                        ws: aiohttp.ClientWebSocketResponse,
                        obs: Any,
                        pending: list[tuple[str, int, int, float, float]],
                    ) -> tuple[bool, set[str]]:
                        if not pending:
                            return True, set()
                        acts: list[Any] = []
                        act_unames: list[str] = []
                        used_tags: set[int] = set()
                        for uname, bldg_uid, ab_id, bx, by in pending:
                            cands = [
                                u for u in obs.raw_data.units
                                if u.alliance == 1 and u.unit_type == bldg_uid
                                and u.tag not in used_tags and u.build_progress >= 0.99
                            ]
                            if not cands:
                                continue
                            bldg = min(cands, key=lambda u: math.hypot(u.pos.x - bx, u.pos.y - by))
                            used_tags.add(bldg.tag)
                            act_unames.append(uname)
                            acts.append(sc2api_pb2.Action(
                                action_raw=raw_pb2.ActionRaw(
                                    unit_command=raw_pb2.ActionRawUnitCommand(
                                        ability_id=ab_id,
                                        unit_tags=[bldg.tag],
                                    )
                                )
                            ))
                        if acts:
                            aresp = await rpc(ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts)))
                            accepted = {
                                act_unames[i]
                                for i, r in enumerate(aresp.action.result)
                                if i < len(act_unames) and r == 1
                            }
                            bad = [r for r in aresp.action.result if r != 1]
                            if bad:
                                dstate["errors"].append(f"upgrade_action_results={bad} pending={[(u, b, a) for u, b, a, _, _ in pending]}")
                            return (len(accepted) >= len(pending)), accepted
                        return False, set()

                    async def _issue_pre_cloak(ws: aiohttp.ClientWebSocketResponse, obs: Any) -> None:
                        acts: list[Any] = []
                        banshees = [u.tag for u in obs.raw_data.units if u.alliance == 1 and u.unit_type == 55 and u.cloak == 3]
                        ghosts = [u.tag for u in obs.raw_data.units if u.alliance == 1 and u.unit_type == 50 and u.cloak == 3]
                        if banshees:
                            acts.append(sc2api_pb2.Action(
                                action_raw=raw_pb2.ActionRaw(
                                    unit_command=raw_pb2.ActionRawUnitCommand(ability_id=392, unit_tags=banshees)
                                )
                            ))
                        if ghosts:
                            acts.append(sc2api_pb2.Action(
                                action_raw=raw_pb2.ActionRaw(
                                    unit_command=raw_pb2.ActionRawUnitCommand(ability_id=382, unit_tags=ghosts)
                                )
                            ))
                        if acts:
                            await rpc(ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts)))

                    async def _p2_housekeeping(obs: Any) -> None:
                        """Shared P2 clearing / upgrade / pre-cloak helper for both dummy and self-play."""
                        dstate["p2_upgrade_ids_obs"] = list(obs.raw_data.player.upgrade_ids)
                        if dstate["p2_orig_th_tag"] is None:
                            for u in obs.raw_data.units:
                                if u.alliance == 1 and u.unit_type in TOWNHALL_IDS:
                                    dstate["p2_orig_th_tag"] = u.tag
                                    dstate["p2_orig_th_pos"] = (float(u.pos.x), float(u.pos.y))
                                    dstate["orig_th_tags"].add(u.tag)
                                    dstate["orig_th_positions"].append((float(u.pos.x), float(u.pos.y)))
                                    break
                        # Populate `p2_main_mineral_tags` strictly from P2's OWN `sc2_ws2` observation namespace!
                        # (SC2 assigns distinct neutral unit tags per client; P1's mineral tags are silently rejected on sc2_ws2!)
                        if dstate["p2_orig_th_pos"] is not None and not dstate["p2_main_mineral_tags"]:
                            mtags2, mpos2 = extract_main_mineral_info(obs.raw_data.units, dstate["p2_orig_th_pos"], max_dist=12.0)
                            if mtags2:
                                an2: MapTerrainAnalyzer | None = dstate["analyzer"]
                                ctr2 = (an2.w / 2.0, an2.h / 2.0) if an2 is not None else (88.0, 88.0)
                                dstate["p2_main_mineral_tags"] = mtags2
                                dstate["p2_main_mineral_positions"] = mpos2
                                dstate["p2_main_mineral_site"] = build_site_from_mineral_positions(
                                    dstate["p2_orig_th_pos"], mpos2, map_center=ctr2,
                                )
                        phase = dstate["phase"]
                        if phase == "clearing":
                            p2_kill = [
                                u.tag for u in obs.raw_data.units
                                if u.alliance == 1 and u.tag not in dstate["orig_th_tags"]
                                and not (dstate["p2_orig_th_tag"] is None and u.unit_type in TOWNHALL_IDS)
                            ]
                            if p2_kill:
                                dstate["p2_clear_ok"] = False
                                await rpc(sc2_ws2, sc2api_pb2.Request(
                                    debug=sc2api_pb2.RequestDebug(
                                        debug=[debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=p2_kill))]
                                    )
                                ))
                            else:
                                dstate["p2_clear_ok"] = True
                        elif phase == "upgrade_addons" and obs.game_loop >= dstate["phase_start_loop"] + 4:
                            if not dstate["p2_addons_issued"]:
                                if not dstate["p2_pending_addons"]:
                                    dstate["p2_addons_issued"] = True
                                    dstate["p2_addons_ready"] = True
                                else:
                                    acts_a: list[Any] = []
                                    used_a: set[int] = set()
                                    for p_uid, a_ab, _a_uid, bx, by in dstate["p2_pending_addons"]:
                                        cands = [u for u in obs.raw_data.units if u.alliance == 1 and u.unit_type == p_uid and u.tag not in used_a and u.build_progress >= 0.99]
                                        if cands:
                                            b = min(cands, key=lambda u: math.hypot(u.pos.x - bx, u.pos.y - by))
                                            used_a.add(b.tag)
                                            acts_a.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=a_ab, unit_tags=[b.tag]))))
                                    if acts_a and (len(acts_a) >= len(dstate["p2_pending_addons"]) or obs.game_loop >= dstate["phase_start_loop"] + 20):
                                        await rpc(sc2_ws2, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts_a)))
                                        dstate["p2_addons_issued"] = True
                            if dstate["p2_addons_issued"] and not dstate["p2_addons_ready"]:
                                need_counts: dict[int, int] = {}
                                for _pu, _aa, a_uid, _, _ in dstate["p2_pending_addons"]:
                                    need_counts[a_uid] = need_counts.get(a_uid, 0) + 1
                                ready_ok = all(
                                    sum(1 for u in obs.raw_data.units if u.alliance == 1 and u.unit_type == au and u.build_progress >= 0.99) >= cnt
                                    for au, cnt in need_counts.items()
                                )
                                if ready_ok:
                                    dstate["p2_addons_ready"] = True
                        elif phase == "upgrade_issue" and not dstate["p2_upg_issued"] and obs.game_loop >= dstate["phase_start_loop"] + 4:
                            if not dstate["p2_pending_upgrades"]:
                                dstate["p2_upg_issued"] = True
                            else:
                                rem_p2 = [it for it in dstate["p2_pending_upgrades"] if it[0] not in dstate["p2_accepted_upgrades"]]
                                if not rem_p2:
                                    dstate["p2_upg_issued"] = True
                                else:
                                    ok, acc2 = await _issue_owner_upgrades(sc2_ws2, obs, rem_p2)
                                    dstate["p2_accepted_upgrades"].update(acc2)
                                    if ok or len(dstate["p2_accepted_upgrades"]) >= len(dstate["p2_pending_upgrades"]) or obs.game_loop >= dstate["phase_start_loop"] + 20:
                                        dstate["p2_upg_issued"] = True
                        elif phase == "upgrade_wait":
                            p2_uids = {b for _, b, _, _, _ in dstate["p2_pending_upgrades"]}
                            dstate["p2_upg_busy"] = bool(p2_uids) and any(
                                u.alliance == 1 and u.unit_type in p2_uids and len(u.orders) > 0
                                for u in obs.raw_data.units
                            )
                        elif phase == "mine_warmup_wait":
                            if dstate["warmup_spawned_p2_workers"] and not dstate["warmup_p2_mine_issued"]:
                                mtags2 = list(dstate["p2_main_mineral_tags"])
                                p2_ws_wu = [
                                    u for u in obs.raw_data.units
                                    if u.display_type == 1 and u.alliance == 1
                                    and u.tag not in dstate["orig_th_tags"]
                                    and u.unit_type in WORKER_IDS
                                ]
                                if p2_ws_wu and mtags2:
                                    # Sort workers along the mineral arc around P2's TownHall for exact 2-per-patch saturation!
                                    th2_x, th2_y = dstate["p2_orig_th_pos"] or (dstate["arena_cx"], dstate["arena_cy"])
                                    p2_ws_wu.sort(key=lambda wu: math.atan2(float(wu.pos.y) - th2_y, float(wu.pos.x) - th2_x))
                                    g_wu = [
                                        sc2api_pb2.Action(
                                            action_raw=raw_pb2.ActionRaw(
                                                unit_command=raw_pb2.ActionRawUnitCommand(
                                                    ability_id=3666,
                                                    target_unit_tag=mtags2[(i_w // 2) % len(mtags2)],
                                                    unit_tags=[wu.tag],
                                                )
                                            )
                                        )
                                        for i_w, wu in enumerate(p2_ws_wu)
                                    ]
                                    await rpc(sc2_ws2, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=g_wu)))
                                    dstate["warmup_p2_mine_issued"] = True
                        elif phase == "carrier_fill" and dstate["carrier_fill_cheats_on"] and not dstate["carrier_fill_issued_p2"]:
                            p2_carriers = [u.tag for u in obs.raw_data.units if u.alliance == 1 and u.unit_type == 79]
                            if p2_carriers:
                                acts_ic2 = [
                                    sc2api_pb2.Action(
                                        action_raw=raw_pb2.ActionRaw(
                                            unit_command=raw_pb2.ActionRawUnitCommand(
                                                ability_id=1042,
                                                unit_tags=p2_carriers,
                                            )
                                        )
                                    )
                                    for _ in range(4)
                                ]
                                await rpc(sc2_ws2, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts_ic2)))
                            dstate["carrier_fill_issued_p2"] = True
                        elif phase == "preload_wait":
                            scen_pl = scenarios[min(dstate["scen_idx"], len(scenarios) - 1)]
                            if not scen_pl.p2_loaded_transports:
                                dstate["p2_preload_ready"] = True
                            elif not dstate["p2_preload_ready"] and obs.game_loop >= dstate["p2_preload_last_loop"] + 4:
                                dstate["p2_preload_last_loop"] = int(obs.game_loop)
                                dstate["p2_preload_ready"] = await _issue_preload_cmds(sc2_ws2, obs, scen_pl.p2_loaded_transports)
                        elif phase == "fighting":
                            scen_hk = scenarios[min(dstate["scen_idx"], len(scenarios) - 1)]
                            want_w_hk = bool(
                                {UNIT_IDS[u] for u, _, _, _ in (scen_hk.p1_units + scen_hk.p2_units)} & WORKER_IDS
                            )
                            p2_wr_hk = is_p2_worker_rush_spec(scen_hk)
                            cx_hk, cy_hk = dstate["arena_cx"], dstate["arena_cy"]
                            dstate["p2_own_units"] = [
                                u for u in obs.raw_data.units
                                if u.display_type == 1 and u.alliance == 1
                                and u.tag not in dstate["orig_th_tags"]
                                and (
                                    u.unit_type in COMBAT_IDS
                                    or (
                                        want_w_hk
                                        and u.unit_type in WORKER_IDS
                                        and (p2_wr_hk or math.hypot(u.pos.x - cx_hk, u.pos.y - cy_hk) < 35.0)
                                    )
                                )
                            ]
                            dstate["p2_own_units_loop"] = int(obs.game_loop)
                            if obs.HasField("score"):
                                cur_p2_cm = float(getattr(obs.score.score_details, "collected_minerals", 0.0))
                                if not dstate["p2_runby_mine_issued"] and scen_hk.scoring_mode == "worker-runby":
                                    dstate["p2_econ_start_minerals"] = cur_p2_cm
                                dstate["p2_econ_cur_minerals"] = cur_p2_cm
                            if scen_hk.use_p2_main_base and not dstate["p2_runby_mine_issued"]:
                                p2_ws = [
                                    u for u in dstate["p2_own_units"]
                                    if u.unit_type in WORKER_IDS
                                    and not any(o.ability_id in MINING_ORDER_ABILITY_IDS for o in u.orders)
                                ]
                                mtags2 = list(dstate["p2_main_mineral_tags"])
                                if p2_ws and mtags2:
                                    g_acts2 = [
                                        sc2api_pb2.Action(
                                            action_raw=raw_pb2.ActionRaw(
                                                unit_command=raw_pb2.ActionRawUnitCommand(
                                                    ability_id=3666,
                                                    target_unit_tag=mtags2[(i // 2) % len(mtags2)],
                                                    unit_tags=[wu.tag],
                                                )
                                            )
                                        )
                                        for i, wu in enumerate(p2_ws)
                                    ]
                                    await rpc(sc2_ws2, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=g_acts2)))
                                dstate["p2_runby_mine_issued"] = True
                            if dstate["p2_pre_cloak_pending"]:
                                await _issue_pre_cloak(sc2_ws2, obs)
                                dstate["p2_pre_cloak_pending"] = False

                    def _encode_worker_rush_actions(
                        my_workers: list[Any],
                        en_gnd: list[Any],
                        scen_p2: SkirmishSpec,
                    ) -> list[Any]:
                        site_p2 = _site_for_scen(scen_p2)
                        plan = plan_worker_rush_orders(
                            my_workers,
                            en_gnd,
                            site_p2,
                            scen_p2.use_main_base,
                            worker_micro=scen_p2.p2_worker_micro,
                            p2_mineral_tags=list(dstate["p2_main_mineral_tags"]),
                            p2_home_pos=dstate["p2_orig_th_pos"],
                        )
                        out: list[Any] = []
                        for ab_id, tid, pos, tags in plan:
                            if tid is not None:
                                ucmd = raw_pb2.ActionRawUnitCommand(
                                    ability_id=ab_id,
                                    target_unit_tag=tid,
                                    unit_tags=tags,
                                )
                            elif pos is not None:
                                px, py = pos
                                ucmd = raw_pb2.ActionRawUnitCommand(
                                    ability_id=ab_id,
                                    target_world_space_pos=common_pb2.Point2D(x=px, y=py),
                                    unit_tags=tags,
                                )
                            elif ab_id == 4:
                                ucmd = raw_pb2.ActionRawUnitCommand(
                                    ability_id=ab_id,
                                    unit_tags=tags,
                                )
                            else:
                                px, py = (site_p2.cx, site_p2.cy)
                                ucmd = raw_pb2.ActionRawUnitCommand(
                                    ability_id=ab_id,
                                    target_world_space_pos=common_pb2.Point2D(x=px, y=py),
                                    unit_tags=tags,
                                )
                            out.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=ucmd)))
                        return out

                    async def _drive_p2_worker_rush(obs: Any, scen_p2: SkirmishSpec) -> None:
                        """Keep P2 rush workers attacking/kiting P1 in `--opponent self` instead of mining."""
                        cx_a, cy_a = dstate["arena_cx"], dstate["arena_cy"]
                        my_w = [
                            u for u in obs.raw_data.units
                            if u.display_type == 1 and u.alliance == 1
                            and u.tag not in dstate["orig_th_tags"]
                            and u.unit_type in WORKER_IDS
                        ]
                        if not my_w:
                            return
                        en_gnd = [
                            u for u in obs.raw_data.units
                            if u.display_type == 1 and u.alliance == 4 and u.cloak != 1
                            and u.tag not in dstate["orig_th_tags"]
                            and u.tag not in dstate["p1_starter_bldg_tags"]
                            and not (bool(getattr(u, "is_flying", False)) or u.unit_type in AIR_UNIT_IDS)
                            and (u.unit_type in COMBAT_IDS or (u.unit_type in WORKER_IDS and math.hypot(u.pos.x - cx_a, u.pos.y - cy_a) < 35.0))
                        ]
                        acts = _encode_worker_rush_actions(my_w, en_gnd, scen_p2)
                        if acts:
                            for a in acts:
                                uc = a.action_raw.unit_command
                                ab = uc.ability_id
                                n_tags = len(uc.unit_tags)
                                dstate["p2_ability_counts"][str(ab)] = dstate["p2_ability_counts"].get(str(ab), 0) + n_tags
                                if ab == 23:
                                    dstate["p2_attack_cmds"] += n_tags
                                elif ab in (16, 3666):
                                    dstate["p2_move_cmds"] += n_tags
                            await rpc(sc2_ws2, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts)))

                    async def p2_aggressive_micro_loop() -> None:
                        await dstate["p1_joined"].wait()
                        await rpc(sc2_ws2, make_mp_join(RACE_ENUM.get(enemy_race, common_pb2.Terran), "MicroDummy"))
                        step_n = max(1, args.step_size)
                        while not dstate["done"].is_set():
                            obs_r = await rpc(sc2_ws2, sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation()))
                            obs = obs_r.observation.observation
                            p2_ended_now, p2_end_reason, p2_ko_side = extract_sc2_early_game_end(
                                obs_r.status,
                                obs_r.observation.player_result,
                                sc2api_pb2.ended,
                            )
                            if p2_ended_now and not dstate["sc2_ended_reason"]:
                                dstate["sc2_ended_reason"] = p2_end_reason
                                dstate["sc2_ended_ko_side"] = p2_ko_side
                            await _p2_housekeeping(obs)
                            if dstate["phase"] == "fighting":
                                scen_p2 = scenarios[min(dstate["scen_idx"], len(scenarios) - 1)]
                                want_workers_p2 = bool(
                                    {UNIT_IDS[u] for u, _, _, _ in (scen_p2.p1_units + scen_p2.p2_units)} & WORKER_IDS
                                )
                                p2_wr_spec = is_p2_worker_rush_spec(scen_p2)
                                cx_a, cy_a = dstate["arena_cx"], dstate["arena_cy"]
                                my_u = [
                                    u for u in obs.raw_data.units
                                    if u.display_type == 1 and u.alliance == 1
                                    and u.tag not in dstate["orig_th_tags"]
                                    and u.unit_type not in PURE_UNARMED_IDS
                                    and (
                                        u.unit_type in COMBAT_IDS
                                        or (
                                            want_workers_p2
                                            and u.unit_type in WORKER_IDS
                                            and (p2_wr_spec or math.hypot(u.pos.x - cx_a, u.pos.y - cy_a) < 35.0)
                                        )
                                    )
                                ]
                                # Ignore undetected cloaked/burrowed units (CloakState.Cloaked == 1) so MicroDummy doesn't freeze!
                                en_u = [
                                    u for u in obs.raw_data.units
                                    if u.display_type == 1 and u.alliance == 4 and u.cloak != 1
                                    and u.tag not in dstate["orig_th_tags"]
                                    and u.tag not in dstate["p1_starter_bldg_tags"]
                                    and (u.unit_type in COMBAT_IDS or (want_workers_p2 and u.unit_type in WORKER_IDS and math.hypot(u.pos.x - cx_a, u.pos.y - cy_a) < 35.0))
                                ]
                                en_armed = [u for u in en_u if u.unit_type not in PURE_UNARMED_IDS]
                                en_targets = en_armed if en_armed else en_u
                                if (scen_p2.scoring_mode == "mineral-defense" or p2_wr_spec) and scen_p2.p2_worker_micro != "cooldown-weave-kite":
                                    en_workers = [u for u in en_targets if u.unit_type in WORKER_IDS]
                                    if en_workers:
                                        en_targets = en_workers
                                acts_p2: list[Any] = []
                                # Planetary Fortress (`130`) SCV Repair (`316`) & structure handling:
                                # never issue Move/point-attack-move to static structures (`130`/`23`);
                                # keep SCVs near a live PF ready to repair (`316`) immediately once damaged!
                                pfs_alive = [u for u in my_u if u.unit_type == 130]
                                pfs_damaged = [u for u in pfs_alive if float(u.health) < float(u.health_max) - 1.0]
                                repair_scv_tags: set[int] = set()
                                if pfs_alive:
                                    for u in my_u:
                                        if u.unit_type == 45:
                                            nearest_pf = min(pfs_alive, key=lambda pf: math.hypot(u.pos.x - pf.pos.x, u.pos.y - pf.pos.y))
                                            if math.hypot(u.pos.x - nearest_pf.pos.x, u.pos.y - nearest_pf.pos.y) <= 14.0:
                                                repair_scv_tags.add(u.tag)
                                    if repair_scv_tags and not dstate["p2_repair_bank_granted"]:
                                        dstate["p2_repair_bank_granted"] = True
                                        try:
                                            # Grant ONLY gas (NOT minerals, which is global in SC2 and would let P1 build at its home Nexus);
                                            # P2's starting 50M + gas bank supports ~545 HP of SCV Planetary Fortress repair (`316`).
                                            await rpc(sc2_ws2, sc2api_pb2.Request(
                                                debug=sc2api_pb2.RequestDebug(debug=[
                                                    debug_pb2.DebugCommand(game_state=debug_pb2.gas),
                                                ])
                                            ))
                                        except Exception:
                                            pass
                                if pfs_damaged and repair_scv_tags:
                                    dmg_pf = min(pfs_damaged, key=lambda pf: float(pf.health))
                                    acts_p2.append(sc2api_pb2.Action(
                                        action_raw=raw_pb2.ActionRaw(
                                            unit_command=raw_pb2.ActionRawUnitCommand(
                                                ability_id=316,
                                                target_unit_tag=dmg_pf.tag,
                                                unit_tags=sorted(repair_scv_tags),
                                            )
                                        )
                                    ))

                                # In any `use_p2_main_base` scenario (`worker-runby`, `s01`, `y06`, `n05`), keep P2's base workers
                                # realistically mining minerals (2-per-patch) while P2's combat defenders fight!
                                p2_mining_worker_tags: set[int] = set()
                                if scen_p2.use_p2_main_base:
                                    mtags_rb = list(dstate["p2_main_mineral_tags"])
                                    for i_w, wu in enumerate(my_u):
                                        if wu.unit_type in WORKER_IDS:
                                            p2_mining_worker_tags.add(wu.tag)
                                            if mtags_rb and not any(o.ability_id in MINING_ORDER_ABILITY_IDS for o in wu.orders):
                                                acts_p2.append(sc2api_pb2.Action(
                                                    action_raw=raw_pb2.ActionRaw(
                                                        unit_command=raw_pb2.ActionRawUnitCommand(
                                                            ability_id=3666,
                                                            target_unit_tag=mtags_rb[(i_w // 2) % len(mtags_rb)],
                                                            unit_tags=[wu.tag],
                                                        )
                                                    )
                                                ))

                                # MicroDummy loaded air transport drop (`396` Medivac / `913` WarpPrism / `1408` Dropperlord)
                                loaded_p2_air = [
                                    u for u in obs.raw_data.units
                                    if u.display_type == 1 and u.alliance == 1
                                    and u.unit_type in (54, 81, 893)
                                    and len(getattr(u, "passengers", ())) > 0
                                ]
                                if loaded_p2_air:
                                    drop_targets = [e for e in en_targets if e.unit_type in WORKER_IDS] if scen_p2.scoring_mode == "mineral-defense" else en_targets
                                    if drop_targets:
                                        dx_t = sum(float(e.pos.x) for e in drop_targets) / len(drop_targets)
                                        dy_t = sum(float(e.pos.y) for e in drop_targets) / len(drop_targets)
                                    else:
                                        site_d = _site_for_scen(scen_p2)
                                        dx_t = site_d.cx - 2.5 * site_d.ux
                                        dy_t = site_d.cy - 2.5 * site_d.uy
                                    unload_ab_map = {54: 396, 81: 913, 893: 1408}
                                    for lt_u in loaded_p2_air:
                                        acts_p2.append(sc2api_pb2.Action(
                                            action_raw=raw_pb2.ActionRaw(
                                                unit_command=raw_pb2.ActionRawUnitCommand(
                                                    ability_id=unload_ab_map[int(lt_u.unit_type)],
                                                    target_world_space_pos=common_pb2.Point2D(x=dx_t, y=dy_t),
                                                    unit_tags=[lt_u.tag],
                                                )
                                            )
                                        ))

                                # MicroDummy Widow Mine burrow (`2095`), Oracle Pulsar Beam (`2375`), Liberator AG (`2558`)
                                special_p2_tags: set[int] = set()
                                if en_targets:
                                    wm_burrow_tags = [
                                        u.tag for u in my_u
                                        if u.unit_type == 498
                                        and any(math.hypot(e.pos.x - u.pos.x, e.pos.y - u.pos.y) <= 7.5 for e in en_targets)
                                    ]
                                    if wm_burrow_tags:
                                        special_p2_tags.update(wm_burrow_tags)
                                        acts_p2.append(sc2api_pb2.Action(
                                            action_raw=raw_pb2.ActionRaw(
                                                unit_command=raw_pb2.ActionRawUnitCommand(
                                                    ability_id=2095,
                                                    unit_tags=wm_burrow_tags,
                                                )
                                            )
                                        ))
                                    orc_beam_tags = [
                                        u.tag for u in my_u
                                        if u.unit_type == 495 and 56 not in list(u.buff_ids) and float(getattr(u, "energy", 0.0)) >= 25.0
                                        and any(math.hypot(e.pos.x - u.pos.x, e.pos.y - u.pos.y) <= 9.0 for e in en_targets)
                                    ]
                                    if orc_beam_tags:
                                        acts_p2.append(sc2api_pb2.Action(
                                            action_raw=raw_pb2.ActionRaw(
                                                unit_command=raw_pb2.ActionRawUnitCommand(
                                                    ability_id=2375,
                                                    unit_tags=orc_beam_tags,
                                                )
                                            )
                                        ))
                                    if scen_p2.scoring_mode == "mineral-defense":
                                        en_gnd_lib = [e for e in en_targets if not (bool(getattr(e, "is_flying", False)) or e.unit_type in AIR_UNIT_IDS)]
                                        if en_gnd_lib:
                                            lx_t = sum(float(e.pos.x) for e in en_gnd_lib) / len(en_gnd_lib)
                                            ly_t = sum(float(e.pos.y) for e in en_gnd_lib) / len(en_gnd_lib)
                                            for lu in my_u:
                                                if lu.unit_type == 689 and math.hypot(lu.pos.x - lx_t, lu.pos.y - ly_t) <= 10.5:
                                                    special_p2_tags.add(lu.tag)
                                                    acts_p2.append(sc2api_pb2.Action(
                                                        action_raw=raw_pb2.ActionRaw(
                                                            unit_command=raw_pb2.ActionRawUnitCommand(
                                                                ability_id=2558,
                                                                target_world_space_pos=common_pb2.Point2D(x=lx_t, y=ly_t),
                                                                unit_tags=[lu.tag],
                                                            )
                                                        )
                                                    ))

                                    # MicroDummy Disruptor Purification Nova (`2346`, staggered waves) + Nova ball (`733`) steer (`u07`!)
                                    en_gnd_sp = [e for e in en_targets if not (bool(getattr(e, "is_flying", False)) or e.unit_type in AIR_UNIT_IDS)]
                                    if en_gnd_sp:
                                        p2_novas = [
                                            u for u in obs.raw_data.units
                                            if u.display_type == 1 and u.alliance == 1 and u.unit_type == 733
                                        ]
                                        for nb in p2_novas:
                                            tgt_nb = max(
                                                en_gnd_sp,
                                                key=lambda e: (
                                                    sum(1 for e2 in en_gnd_sp if math.hypot(e2.pos.x - e.pos.x, e2.pos.y - e.pos.y) <= 1.8),
                                                    -math.hypot(e.pos.x - nb.pos.x, e.pos.y - nb.pos.y),
                                                ),
                                            )
                                            acts_p2.append(sc2api_pb2.Action(
                                                action_raw=raw_pb2.ActionRaw(
                                                    unit_command=raw_pb2.ActionRawUnitCommand(
                                                        ability_id=16,
                                                        target_world_space_pos=common_pb2.Point2D(x=float(tgt_nb.pos.x), y=float(tgt_nb.pos.y)),
                                                        unit_tags=[nb.tag],
                                                    )
                                                )
                                            ))
                                        gl_p2 = int(obs.game_loop)
                                        if gl_p2 >= int(dstate["p2_disruptor_next_global"]):
                                            cd_map = dstate["p2_disruptor_cd"]
                                            for du in my_u:
                                                if du.unit_type == 694 and gl_p2 >= int(cd_map.get(du.tag, 0)):
                                                    in_rng_d = [e for e in en_gnd_sp if math.hypot(e.pos.x - du.pos.x, e.pos.y - du.pos.y) <= 12.5]
                                                    if in_rng_d:
                                                        tgt_d = max(
                                                            in_rng_d,
                                                            key=lambda e: (
                                                                sum(1 for e2 in in_rng_d if math.hypot(e2.pos.x - e.pos.x, e2.pos.y - e.pos.y) <= 1.8),
                                                                1 if e.unit_type in (502, 503) else 0,
                                                                -math.hypot(e.pos.x - du.pos.x, e.pos.y - du.pos.y),
                                                            ),
                                                        )
                                                        special_p2_tags.add(du.tag)
                                                        cd_map[du.tag] = gl_p2 + 480
                                                        dstate["p2_disruptor_next_global"] = gl_p2 + 36
                                                        acts_p2.append(sc2api_pb2.Action(
                                                            action_raw=raw_pb2.ActionRaw(
                                                                unit_command=raw_pb2.ActionRawUnitCommand(
                                                                    ability_id=2346,
                                                                    target_world_space_pos=common_pb2.Point2D(x=float(tgt_d.pos.x), y=float(tgt_d.pos.y)),
                                                                    unit_tags=[du.tag],
                                                                )
                                                            )
                                                        ))
                                                        break
                                    # MicroDummy Thor High-Impact Payload (`2362`) vs Massive/Armored Air (keep Explosive vs Mutalisks!)
                                    if any(e.unit_type in MASSIVE_ARMORED_AIR_IDS for e in en_targets):
                                        thor_tags = [u.tag for u in my_u if u.unit_type == 52]
                                        if thor_tags:
                                            special_p2_tags.update(thor_tags)
                                            acts_p2.append(sc2api_pb2.Action(
                                                action_raw=raw_pb2.ActionRaw(
                                                    unit_command=raw_pb2.ActionRawUnitCommand(
                                                        ability_id=2362,
                                                        unit_tags=thor_tags,
                                                    )
                                                )
                                            ))

                                mobile_my_u = [
                                    u for u in my_u
                                    if u.unit_type not in STRUCTURE_IDS
                                    and u.unit_type not in STATIC_TRAP_IDS
                                    and u.tag not in repair_scv_tags
                                    and u.tag not in p2_mining_worker_tags
                                    and u.tag not in special_p2_tags
                                ]
                                struct_my_u = [u for u in my_u if u.unit_type in STRUCTURE_IDS]

                                p2_is_worker_rush = bool(mobile_my_u) and (
                                    is_p2_worker_rush_spec(scen_p2)
                                    or (len(mobile_my_u) >= 4 and all(u.unit_type in WORKER_IDS for u in mobile_my_u))
                                )
                                if p2_is_worker_rush:
                                    en_gnd_wr = [
                                        e for e in en_targets
                                        if not (bool(getattr(e, "is_flying", False)) or e.unit_type in AIR_UNIT_IDS)
                                    ]
                                    acts_p2.extend(_encode_worker_rush_actions(mobile_my_u, en_gnd_wr, scen_p2))
                                elif en_targets:
                                    en_gnd = [e for e in en_targets if not (bool(getattr(e, "is_flying", False)) or e.unit_type in AIR_UNIT_IDS)]
                                    en_air = [e for e in en_targets if bool(getattr(e, "is_flying", False)) or e.unit_type in AIR_UNIT_IDS]
                                    if mobile_my_u:
                                        cx_my = sum(u.pos.x for u in mobile_my_u) / len(mobile_my_u)
                                        cy_my = sum(u.pos.y for u in mobile_my_u) / len(mobile_my_u)
                                        g_only_tags = [u.tag for u in mobile_my_u if unit_attack_caps(u, mobile_my_u, is_dummy=True) == (True, False)]
                                        a_only_tags = [u.tag for u in mobile_my_u if unit_attack_caps(u, mobile_my_u, is_dummy=True) == (False, True)]
                                        both_tags = [u.tag for u in mobile_my_u if u.tag not in set(g_only_tags) and u.tag not in set(a_only_tags)]
                                        if both_tags:
                                            tgt = min(en_targets, key=lambda e: (math.hypot(e.pos.x - cx_my, e.pos.y - cy_my), e.health + e.shield))
                                            acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt.tag, unit_tags=both_tags))))
                                        if g_only_tags and en_gnd:
                                            tgt_g = min(en_gnd, key=lambda e: (math.hypot(e.pos.x - cx_my, e.pos.y - cy_my), e.health + e.shield))
                                            acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt_g.tag, unit_tags=g_only_tags))))
                                        if a_only_tags and en_air:
                                            tgt_a = min(en_air, key=lambda e: (math.hypot(e.pos.x - cx_my, e.pos.y - cy_my), e.health + e.shield))
                                            acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt_a.tag, unit_tags=a_only_tags))))
                                    # Static structures focus-fire nearest valid in-range enemy only (never Move!)
                                    for st in struct_my_u:
                                        if st.unit_type == 130 and en_gnd:
                                            in_rng = [e for e in en_gnd if math.hypot(e.pos.x - st.pos.x, e.pos.y - st.pos.y) <= 8.8]
                                            if in_rng:
                                                tgt_pf = min(in_rng, key=lambda e: (math.hypot(e.pos.x - st.pos.x, e.pos.y - st.pos.y), e.health + e.shield))
                                                acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt_pf.tag, unit_tags=[st.tag]))))
                                        elif st.unit_type in (23, 99) and en_air:
                                            in_rng = [e for e in en_air if math.hypot(e.pos.x - st.pos.x, e.pos.y - st.pos.y) <= 8.5]
                                            if in_rng:
                                                tgt_mt = min(in_rng, key=lambda e: (math.hypot(e.pos.x - st.pos.x, e.pos.y - st.pos.y), e.health + e.shield))
                                                acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt_mt.tag, unit_tags=[st.tag]))))
                                        elif st.unit_type == 66 and en_targets:
                                            in_rng = [e for e in en_targets if math.hypot(e.pos.x - st.pos.x, e.pos.y - st.pos.y) <= 8.5]
                                            if in_rng:
                                                tgt_pc = min(in_rng, key=lambda e: (math.hypot(e.pos.x - st.pos.x, e.pos.y - st.pos.y), e.health + e.shield))
                                                acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt_pc.tag, unit_tags=[st.tag]))))
                                        elif st.unit_type == 98 and en_gnd:
                                            in_rng = [e for e in en_gnd if math.hypot(e.pos.x - st.pos.x, e.pos.y - st.pos.y) <= 8.0]
                                            if in_rng:
                                                tgt_sc = min(in_rng, key=lambda e: (math.hypot(e.pos.x - st.pos.x, e.pos.y - st.pos.y), e.health + e.shield))
                                                acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt_sc.tag, unit_tags=[st.tag]))))
                                elif mobile_my_u:
                                    # Attack-move mobile defenders toward arena center if all remaining enemies are burrowed/cloaked
                                    acts_p2.append(sc2api_pb2.Action(
                                        action_raw=raw_pb2.ActionRaw(
                                            unit_command=raw_pb2.ActionRawUnitCommand(
                                                ability_id=23,
                                                target_world_space_pos=common_pb2.Point2D(x=cx_a, y=cy_a),
                                                unit_tags=[u.tag for u in mobile_my_u],
                                            )
                                        )
                                    ))
                                if acts_p2:
                                    await rpc(sc2_ws2, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts_p2)))
                            await rpc(sc2_ws2, sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=step_n)))

                    async def duel_ws_handler_p2(http_req: web.Request) -> web.WebSocketResponse:
                        """Live Mothman-P2 WebSocket proxy for --opponent self."""
                        bot_ws2 = web.WebSocketResponse(max_msg_size=128 * 1024 * 1024)
                        await bot_ws2.prepare(http_req)
                        try:
                            async for msg in bot_ws2:
                                if msg.type != aiohttp.WSMsgType.BINARY:
                                    continue
                                req = sc2api_pb2.Request()
                                req.ParseFromString(msg.data)

                                if req.HasField("join_game"):
                                    await dstate["p1_joined"].wait()
                                    resp = await rpc(sc2_ws2, make_mp_join(RACE_ENUM.get(enemy_race, common_pb2.Terran), f"{bname2}-P2"))
                                    await bot_ws2.send_bytes(resp.SerializeToString())
                                    continue

                                if req.HasField("action"):
                                    if dstate["phase"] != "fighting":
                                        # Suppress macro/worker actions during clearing/upgrading/spawning!
                                        dummy_resp = sc2api_pb2.Response(
                                            action=sc2api_pb2.ResponseAction(),
                                            status=sc2api_pb2.in_game,
                                        )
                                        await bot_ws2.send_bytes(dummy_resp.SerializeToString())
                                        continue
                                    scen_p2_cur = scenarios[min(dstate["scen_idx"], len(scenarios) - 1)]
                                    if is_p2_worker_rush_spec(scen_p2_cur):
                                        # Keep P2 worker-rush attackers focused on P1 instead of mining/retreating home
                                        kept_actions = [
                                            a for a in req.action.actions
                                            if a.HasField("action_raw") and a.action_raw.HasField("unit_command")
                                            and a.action_raw.unit_command.ability_id == 23
                                        ]
                                        if not kept_actions:
                                            dummy_resp = sc2api_pb2.Response(
                                                action=sc2api_pb2.ResponseAction(),
                                                status=sc2api_pb2.in_game,
                                            )
                                            await bot_ws2.send_bytes(dummy_resp.SerializeToString())
                                            continue
                                        req = sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=kept_actions))
                                    for a in req.action.actions:
                                        if a.HasField("action_raw") and a.action_raw.HasField("unit_command"):
                                            ab = a.action_raw.unit_command.ability_id
                                            n_tags = len(a.action_raw.unit_command.unit_tags)
                                            dstate["p2_ability_counts"][str(ab)] = dstate["p2_ability_counts"].get(str(ab), 0) + n_tags
                                            if ab == 23:
                                                dstate["p2_attack_cmds"] += n_tags
                                            elif ab == 16:
                                                dstate["p2_move_cmds"] += n_tags
                                            elif ab not in (298, 299, 3666):
                                                dstate["p2_spell_cmds"] += n_tags

                                if dstate["done"].is_set():
                                    break
                                if req.HasField("step"):
                                    rpc_task = asyncio.create_task(rpc(sc2_ws2, req))
                                    done_task = asyncio.create_task(dstate["done"].wait())
                                    finished, pending_t = await asyncio.wait({rpc_task, done_task}, return_when=asyncio.FIRST_COMPLETED)
                                    for pt in pending_t:
                                        pt.cancel()
                                    if dstate["done"].is_set() and rpc_task not in finished:
                                        break
                                    resp = rpc_task.result()
                                else:
                                    resp = await rpc(sc2_ws2, req)
                                if req.HasField("observation") and resp.HasField("observation"):
                                    p2_ended_now, p2_end_reason, p2_ko_side = extract_sc2_early_game_end(
                                        resp.status,
                                        resp.observation.player_result,
                                        sc2api_pb2.ended,
                                    )
                                    if p2_ended_now and not dstate["sc2_ended_reason"]:
                                        dstate["sc2_ended_reason"] = p2_end_reason
                                        dstate["sc2_ended_ko_side"] = p2_ko_side
                                    await _p2_housekeeping(resp.observation.observation)
                                    if dstate["phase"] == "fighting":
                                        scen_p2_cur = scenarios[min(dstate["scen_idx"], len(scenarios) - 1)]
                                        if is_p2_worker_rush_spec(scen_p2_cur):
                                            await _drive_p2_worker_rush(resp.observation.observation, scen_p2_cur)

                                await bot_ws2.send_bytes(resp.SerializeToString())
                                if dstate["done"].is_set():
                                    break
                        except Exception as exc:
                            dstate["errors"].append(f"p2_ws: {type(exc).__name__}: {exc}")
                        finally:
                            dstate["done"].set()
                        return bot_ws2

                    def finalize_current_round(
                        cur_loop: int,
                        end_reason: str = "max_loops",
                        ko_winner_side: int = 0,
                    ) -> None:
                        if dstate["scen_idx"] >= len(scenarios):
                            return
                        scen = scenarios[dstate["scen_idx"]]
                        if any(r.get("id") == scen.id for r in dstate["results"]):
                            return
                        p1_lost = max(0.0, dstate["p1_start_val"] - dstate["p1_rem_val"])
                        p2_lost = max(0.0, dstate["p2_start_val"] - dstate["p2_rem_val"])
                        trade = round(p2_lost / max(1.0, p1_lost), 2) if p1_lost > 0 else (99.0 if p2_lost > 0 else 1.0)
                        p2_trade = round(p1_lost / max(1.0, p2_lost), 2) if p2_lost > 0 else (99.0 if p1_lost > 0 else 1.0)
                        p1_tag = "Mothman-P1" if opp_mode == "self" else "Mothman"
                        p2_tag = "Mothman-P2" if opp_mode == "self" else "MicroDummy"
                        pf_start = int(dstate.get("p2_pf_start_cnt", 0))
                        pf_alive = int(dstate.get("p2_pf_alive_cnt", 0))
                        pf_destroyed = bool(pf_start > 0 and pf_alive == 0)
                        pf_destroyed_cnt = max(0, pf_start - pf_alive)
                        det_start = int(dstate.get("p2_det_start_cnt", 0))
                        det_alive = int(dstate.get("p2_det_alive_cnt", 0))
                        detectors_destroyed = max(0, det_start - det_alive)
                        en_w_start = int(dstate.get("p2_w_start_cnt", 0))
                        en_w_alive = int(dstate.get("p2_w_alive_cnt", 0))
                        enemy_workers_killed = max(0, en_w_start - en_w_alive)
                        start_loop = int(dstate.get("fight_start_loop") or dstate["phase_start_loop"])
                        fight_loops = max(1, int(cur_loop) - start_loop)
                        econ_extra: dict[str, Any] = {}
                        econ_ctx = ""
                        if scen.scoring_mode == "mineral-defense":
                            mins_gath = round(max(0.0, float(dstate["econ_cur_minerals"]) - float(dstate["econ_start_minerals"])), 1)
                            up_pct = round(100.0 * float(dstate["econ_worker_mining_ticks"]) / max(1.0, float(dstate["econ_worker_total_ticks"])), 1)
                            w_lost = len(dstate["econ_seen_worker_tags"] - dstate["econ_cur_worker_tags"])
                            en_killed = round(p2_lost, 1)
                            net_econ = round(mins_gath + en_killed - 50.0 * w_lost, 1)
                            kite_wipe_ok = True
                            kite_req_kills = 0
                            if scen.p2_worker_micro == "cooldown-weave-kite" and en_w_start > 0:
                                kite_req_kills = max(1, en_w_start - 3)
                                kite_wipe_ok = (enemy_workers_killed >= kite_req_kills)
                            passed_econ = (
                                (net_econ >= scen.pass_net_econ_min)
                                and (len(dstate["econ_cur_worker_tags"]) > 0)
                                and (ko_winner_side != 2)
                                and kite_wipe_ok
                            )
                            winner = p1_tag if passed_econ else p2_tag
                            win_type = "econ_pass" if passed_econ else "econ_fail"
                            econ_extra = {
                                "minerals_gathered": mins_gath,
                                "mining_uptime_pct": up_pct,
                                "workers_lost": w_lost,
                                "enemy_killed_val": en_killed,
                                "net_econ_score": net_econ,
                                "pass_net_econ_min": scen.pass_net_econ_min,
                            }
                            if kite_req_kills > 0:
                                econ_extra["pass_kite_kills_min"] = kite_req_kills
                            econ_ctx = (
                                f" | ECON net={net_econ:.1f}/{scen.pass_net_econ_min:.0f}M "
                                f"(mined={mins_gath:.0f}M, up={up_pct:.1f}%, wlost={w_lost}, kill={en_killed:.0f}"
                                + (f", wkills={enemy_workers_killed}/{en_w_start}" if kite_req_kills > 0 else "")
                                + ")"
                            )
                        elif scen.scoring_mode == "worker-runby":
                            p2_mins_gath = round(max(0.0, float(dstate["p2_econ_cur_minerals"]) - float(dstate["p2_econ_start_minerals"])), 1)
                            expected_p2_mins = 0.95 * (fight_loops / 22.4) * min(max(1, en_w_start), 16)
                            enemy_minerals_denied = round(max(0.0, expected_p2_mins - p2_mins_gath), 1)
                            our_units_lost_val = round(p1_lost, 1)
                            enemy_combat_killed_val = round(max(0.0, p2_lost - 50.0 * enemy_workers_killed), 1)
                            runby_score = round(
                                enemy_workers_killed * 100.0
                                - 0.5 * our_units_lost_val
                                + 0.5 * enemy_combat_killed_val,
                                1,
                            )
                            passed_runby = (enemy_workers_killed >= scen.pass_workers_killed_min) and (runby_score > 0.0)
                            winner = p1_tag if passed_runby else p2_tag
                            win_type = "runby_pass" if passed_runby else "runby_fail"
                            econ_extra = {
                                "enemy_minerals_gathered": p2_mins_gath,
                                "enemy_minerals_denied": enemy_minerals_denied,
                                "our_units_lost_val": our_units_lost_val,
                                "enemy_combat_killed_val": enemy_combat_killed_val,
                                "runby_score": runby_score,
                                "pass_workers_killed_min": scen.pass_workers_killed_min,
                            }
                            econ_ctx = (
                                f" | RUNBY wkills={enemy_workers_killed}/{scen.pass_workers_killed_min} "
                                f"score={runby_score:.1f} denied={enemy_minerals_denied:.0f}M "
                                f"lost={our_units_lost_val:.0f} ckill={enemy_combat_killed_val:.0f}"
                            )
                        else:
                            winner, win_type = evaluate_combat_verdict(
                                scen=scen,
                                p1_tag=p1_tag,
                                p2_tag=p2_tag,
                                trade=trade,
                                p1_lost=p1_lost,
                                p2_lost=p2_lost,
                                end_reason=end_reason,
                                ko_winner_side=ko_winner_side,
                                p1_bc_start=int(dstate.get("p1_bc_start_cnt", 0)),
                                p1_bc_alive=int(dstate.get("p1_bc_alive_cnt", 0)),
                                p1_jump_cmds=int(dstate["ability_counts"].get("2358", 0)),
                            )
                        p1_lbl_parts = [f"{c} {u}" for u, c, _, _ in scen.p1_units]
                        for lt in scen.p1_loaded_transports:
                            c_str = "+".join(f"{cc} {cu}" for cu, cc in lt["cargo"])
                            p1_lbl_parts.append(f"1 {lt['transport']}({c_str})")
                        p2_lbl_parts = [f"{c} {u}" for u, c, _, _ in scen.p2_units]
                        for lt in scen.p2_loaded_transports:
                            c_str = "+".join(f"{cc} {cu}" for cu, cc in lt["cargo"])
                            p2_lbl_parts.append(f"1 {lt['transport']}({c_str})")
                        p1_lbl = ", ".join(p1_lbl_parts)
                        p2_lbl = ", ".join(p2_lbl_parts)
                        p2_ctx_extra = (
                            f" | P2 ATK={dstate['p2_attack_cmds']}, MOV={dstate['p2_move_cmds']}, Spells={dstate['p2_spell_cmds']}"
                            if opp_mode == "self"
                            else ""
                        )
                        context = (
                            f"{scen.description} [{scen.terrain}] | {bname1} ({p1_lbl}) vs {p2_label} ({p2_lbl}) -> "
                            f"{winner} ({win_type}/{end_reason}, {trade:.2f}x trade; alive {dstate['p1_alive_cnt']}/{dstate['p1_start_cnt']} "
                            f"[combat {dstate['p1_combat_alive_cnt']}] vs {dstate['p2_alive_cnt']}/{dstate['p2_start_cnt']} "
                            f"[combat {dstate['p2_combat_alive_cnt']}]; "
                            f"ATK={dstate['attack_cmds']}, MOV={dstate['move_cmds']}, Spells={dstate['spell_cmds']}{econ_ctx}{p2_ctx_extra})."
                        )
                        rec: dict[str, Any] = {
                            "id": scen.id,
                            "tier": scen.tier,
                            "category": scen.category,
                            "fast_core": scen.fast_core,
                            "scoring_mode": scen.scoring_mode,
                            "opponent_mode": opp_mode,
                            "bot": bname1,
                            "p1_bot": bname1,
                            "p2_bot": p2_label,
                            "race": scen.our_race,
                            "enemy_race": scen.enemy_race,
                            "terrain": scen.terrain,
                            "source": scen.source,
                            "patterns": scen.patterns,
                            "p1_upgrades": scen.p1_upgrades,
                            "p2_upgrades": scen.p2_upgrades,
                            "applied_p1_upgrade_ids": sorted(set(dstate["p1_upgrade_ids_obs"])),
                            "applied_p2_upgrade_ids": sorted(set(dstate["p2_upgrade_ids_obs"])),
                            "description": scen.description,
                            "context": context,
                            "winner": winner,
                            "win_type": win_type,
                            "end_reason": end_reason,
                            "start_loop": start_loop,
                            "end_loop": int(cur_loop),
                            "arena_cx": round(float(dstate["arena_cx"]), 2),
                            "arena_cy": round(float(dstate["arena_cy"]), 2),
                            "p1_spec": p1_lbl,
                            "p2_spec": p2_lbl,
                            "p1_start_cnt": dstate["p1_start_cnt"],
                            "p2_start_cnt": dstate["p2_start_cnt"],
                            "p1_start_types": dstate["p1_start_types"],
                            "p2_start_types": dstate["p2_start_types"],
                            "p1_alive_cnt": dstate["p1_alive_cnt"],
                            "p2_alive_cnt": dstate["p2_alive_cnt"],
                            "p1_combat_alive_cnt": dstate["p1_combat_alive_cnt"],
                            "p2_combat_alive_cnt": dstate["p2_combat_alive_cnt"],
                            "p1_lost_val": round(p1_lost, 1),
                            "p2_lost_val": round(p2_lost, 1),
                            "trade_ratio": trade,
                            "p1_trade_ratio": trade,
                            "p2_trade_ratio": p2_trade,
                            "pf_destroyed": pf_destroyed,
                            "pf_destroyed_cnt": pf_destroyed_cnt,
                            "detectors_start_cnt": det_start,
                            "detectors_destroyed": detectors_destroyed,
                            "enemy_workers_start_cnt": en_w_start,
                            "enemy_workers_killed": enemy_workers_killed,
                            "mothman_attack_unit_cmds": dstate["attack_cmds"],
                            "mothman_move_unit_cmds": dstate["move_cmds"],
                            "mothman_spell_unit_cmds": dstate["spell_cmds"],
                            "mothman_ability_breakdown": dict(
                                sorted(dstate["ability_counts"].items(), key=lambda kv: -kv[1])[:10]
                            ),
                            "first_action_loop_offset": dstate.get("first_action_loop_offset", -1),
                            "loops_simulated": cur_loop - dstate["phase_start_loop"],
                            "wall_ms": round((time.monotonic() - dstate["round_t0"]) * 1000.0, 1),
                        }
                        if scen.origin_match_id:
                            rec["origin_match_id"] = scen.origin_match_id
                        if scen.p2_worker_micro != "brawl":
                            rec["p2_worker_micro"] = scen.p2_worker_micro
                        if scen.p1_minerals > 0:
                            rec["p1_minerals_target"] = scen.p1_minerals
                            rec["p1_fight_start_minerals"] = int(dstate.get("p1_fight_start_minerals", 0))
                        if scen.p1_starter_buildings:
                            rec["p1_starter_buildings_actual"] = list(dstate.get("pre_setup_info", []))
                        if econ_extra:
                            rec.update(econ_extra)
                        if opp_mode == "self":
                            rec["p2_attack_unit_cmds"] = dstate["p2_attack_cmds"]
                            rec["p2_move_unit_cmds"] = dstate["p2_move_cmds"]
                            rec["p2_spell_unit_cmds"] = dstate["p2_spell_cmds"]
                            rec["p2_am_ratio"] = round(dstate["p2_attack_cmds"] / max(1, dstate["p2_move_cmds"]), 2)
                            rec["p2_ability_breakdown"] = dict(
                                sorted(dstate["p2_ability_counts"].items(), key=lambda kv: -kv[1])[:10]
                            )
                        dstate["results"].append(rec)

                    def _ensure_active_round_finalized(fallback_reason: str = "early_match_end") -> None:
                        if (
                            dstate["phase"] == "fighting"
                            and dstate["scen_idx"] < len(scenarios)
                            and dstate["p1_start_cnt"] > 0
                        ):
                            reason = dstate.get("sc2_ended_reason") or fallback_reason
                            ko_side = int(dstate.get("sc2_ended_ko_side") or 0)
                            end_gl = int(dstate.get("last_obs_loop") or dstate["phase_start_loop"])
                            finalize_current_round(end_gl, end_reason=reason, ko_winner_side=ko_side)
                            dstate["scen_idx"] += 1
                            dstate["phase"] = "done"

                    async def duel_ws_handler(http_req: web.Request) -> web.WebSocketResponse:
                        bot_ws = web.WebSocketResponse(max_msg_size=128 * 1024 * 1024)
                        await bot_ws.prepare(http_req)
                        try:
                            async for msg in bot_ws:
                                if msg.type != aiohttp.WSMsgType.BINARY:
                                    continue
                                req = sc2api_pb2.Request()
                                req.ParseFromString(msg.data)

                                if req.HasField("action"):
                                    # Suppress ALL bot1 actions until `phase == "fighting"` (matching P2 symmetry!)
                                    # so Mothman never queues premature workers (-50M / 17th SCV) during wait_init/clearing/
                                    # upgrade/pre_setup/pre_bank/mine_warmup/preload/spawning/carrier_fill!
                                    if dstate["phase"] != "fighting":
                                        dummy_resp = sc2api_pb2.Response(
                                            action=sc2api_pb2.ResponseAction(),
                                            status=sc2api_pb2.in_game,
                                        )
                                        await bot_ws.send_bytes(dummy_resp.SerializeToString())
                                        continue
                                    if dstate["phase"] == "fighting":
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
                                    resp = await rpc(sc2_ws, make_mp_join(RACE_ENUM.get(our_race, common_pb2.Protoss), bname1))
                                    await bot_ws.send_bytes(resp.SerializeToString())
                                    continue

                                resp = await rpc(sc2_ws, req)
                                if req.HasField("game_info") and resp.HasField("game_info"):
                                    an = MapTerrainAnalyzer(resp.game_info)
                                    dstate["analyzer"] = an
                                    dstate["arena_cx"], dstate["arena_cy"] = an.sites["open"].cx, an.sites["open"].cy

                                if req.HasField("observation") and resp.HasField("observation"):
                                    obs = resp.observation.observation
                                    gl = obs.game_loop
                                    dstate["last_obs_loop"] = gl
                                    dstate["p1_upgrade_ids_obs"] = list(obs.raw_data.player.upgrade_ids)

                                    if dstate["p1_orig_th_tag"] is None:
                                        for u in obs.raw_data.units:
                                            if u.alliance == 1 and u.unit_type in TOWNHALL_IDS:
                                                dstate["p1_orig_th_tag"] = u.tag
                                                dstate["p1_orig_th_pos"] = (float(u.pos.x), float(u.pos.y))
                                                dstate["orig_th_tags"].add(u.tag)
                                                dstate["orig_th_positions"].append((float(u.pos.x), float(u.pos.y)))
                                                break
                                    if dstate["p1_main_mineral_site"] is None and dstate["p1_orig_th_pos"] is not None and dstate["analyzer"] is not None:
                                        msite, mtags, mpos = dstate["analyzer"].compute_main_mineral_site(obs, dstate["p1_orig_th_pos"])
                                        if mtags:
                                            dstate["p1_main_mineral_site"] = msite
                                            dstate["p1_main_mineral_tags"] = mtags
                                            dstate["p1_main_mineral_positions"] = mpos
                                    # Note: `p2_main_mineral_tags` & `p2_main_mineral_site` are populated strictly from
                                    # P2's OWN `sc2_ws2` observation in `_p2_housekeeping` (never P1's tag namespace!).
                                    if not dstate["mineral_refined"] and dstate["analyzer"] is not None and len(dstate["orig_th_positions"]) >= 2:
                                        dstate["analyzer"].refine_mineral_site(obs, dstate["orig_th_positions"])
                                        dstate["mineral_refined"] = True

                                    def _needs_warmup(sc_w: SkirmishSpec) -> bool:
                                        p1_has_w = sc_w.use_main_base and any(UNIT_IDS[u] in WORKER_IDS for u, _, _, _ in sc_w.p1_units)
                                        p2_has_w = sc_w.use_p2_main_base and any(UNIT_IDS[u] in WORKER_IDS for u, _, _, _ in sc_w.p2_units)
                                        has_tumor = any(u == "creep-tumor-burrowed" for u, _, _, _ in (sc_w.p1_units + sc_w.p2_units))
                                        return bool(p1_has_w or p2_has_w or has_tumor)

                                    def _advance_pipeline(after_stage: str, sc_n: SkirmishSpec, cur_gl: int, obs_n: Any) -> None:
                                        """Uniform phase router: clearing -> upgrade -> pre_setup -> pre_bank -> mine_warmup -> preload -> spawning."""
                                        order = ("clearing", "upgrade", "pre_setup", "pre_bank", "mine_warmup", "preload", "spawning")
                                        start_i = order.index(after_stage) + 1
                                        cur_m_n = int(getattr(obs_n.player_common, "minerals", 50))
                                        for stg in order[start_i:]:
                                            if stg == "upgrade":
                                                need_p1_n = [u for u in sc_n.p1_upgrades if u not in dstate["p1_done_upgrades"]]
                                                need_p2_n = [u for u in sc_n.p2_upgrades if u not in dstate["p2_done_upgrades"]]
                                                if need_p1_n or need_p2_n:
                                                    dstate["phase"] = "upgrade_spawn"
                                                    dstate["phase_start_loop"] = cur_gl
                                                    dstate["p1_addons_issued"] = False
                                                    dstate["p2_addons_issued"] = False
                                                    dstate["p1_addons_ready"] = False
                                                    dstate["p2_addons_ready"] = False
                                                    dstate["p1_upg_issued"] = False
                                                    dstate["p2_upg_issued"] = False
                                                    dstate["p1_upg_busy"] = True
                                                    dstate["p2_upg_busy"] = True
                                                    dstate["p1_pending_upgrades"] = []
                                                    dstate["p2_pending_upgrades"] = []
                                                    dstate["p1_accepted_upgrades"] = set()
                                                    dstate["p2_accepted_upgrades"] = set()
                                                    dstate["p1_pending_addons"] = []
                                                    dstate["p2_pending_addons"] = []
                                                    return
                                            elif stg == "pre_setup":
                                                if sc_n.p1_starter_buildings:
                                                    dstate["phase"] = "pre_setup_spawn"
                                                    dstate["phase_start_loop"] = cur_gl
                                                    return
                                            elif stg == "pre_bank":
                                                if sc_n.p1_minerals > cur_m_n:
                                                    dstate["phase"] = "pre_bank_spawn"
                                                    dstate["phase_start_loop"] = cur_gl
                                                    return
                                            elif stg == "mine_warmup":
                                                if _needs_warmup(sc_n):
                                                    dstate["phase"] = "mine_warmup_spawn"
                                                    dstate["phase_start_loop"] = cur_gl
                                                    return
                                            elif stg == "preload":
                                                if sc_n.p1_loaded_transports or sc_n.p2_loaded_transports:
                                                    dstate["phase"] = "preload_spawn"
                                                    dstate["phase_start_loop"] = cur_gl
                                                    dstate["p1_preload_ready"] = not bool(sc_n.p1_loaded_transports)
                                                    dstate["p2_preload_ready"] = not bool(sc_n.p2_loaded_transports)
                                                    dstate["p1_preload_last_loop"] = -100
                                                    dstate["p2_preload_last_loop"] = -100
                                                    return
                                            elif stg == "spawning":
                                                dstate["phase"] = "spawning"
                                                dstate["phase_start_loop"] = cur_gl
                                                return

                                    if dstate["phase"] == "wait_init" and gl >= 4:
                                        first_sc = scenarios[0] if scenarios else None
                                        keep_p1_larva = bool(
                                            first_sc is not None
                                            and first_sc.our_race == "Zerg"
                                            and first_sc.use_main_base
                                            and (first_sc.p1_starter_buildings or first_sc.p1_minerals > 0)
                                        )
                                        kill_tags = [
                                            u.tag for u in obs.raw_data.units
                                            if u.alliance in (1, 4) and u.tag not in dstate["orig_th_tags"]
                                            and u.unit_type not in TOWNHALL_IDS
                                            and not (keep_p1_larva and u.alliance == 1 and u.unit_type == 151)
                                        ]
                                        dbg = [debug_pb2.DebugCommand(game_state=debug_pb2.show_map)]
                                        if kill_tags:
                                            dbg.append(debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=kill_tags)))
                                        await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg)))
                                        dstate["p2_clear_ok"] = False
                                        dstate["phase"] = "clearing"
                                        dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "clearing":
                                        next_sc = scenarios[dstate["scen_idx"]] if dstate["scen_idx"] < len(scenarios) else None
                                        keep_p1_larva = bool(
                                            next_sc is not None
                                            and next_sc.our_race == "Zerg"
                                            and next_sc.use_main_base
                                            and (next_sc.p1_starter_buildings or next_sc.p1_minerals > 0)
                                        )
                                        rem_u = [
                                            u for u in obs.raw_data.units
                                            if u.display_type == 1 and u.alliance == 1
                                            and u.tag not in dstate["orig_th_tags"]
                                            and not (dstate["p1_orig_th_tag"] is None and u.unit_type in TOWNHALL_IDS)
                                            and not (keep_p1_larva and u.unit_type == 151)
                                        ]
                                        # Only kill non-original units (incl. temp upgrade buildings & workers)
                                        if rem_u:
                                            await rpc(sc2_ws, sc2api_pb2.Request(
                                                debug=sc2api_pb2.RequestDebug(
                                                    debug=[debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=[u.tag for u in rem_u]))]
                                                )
                                            ))
                                        elif dstate["p2_clear_ok"] and gl >= dstate["phase_start_loop"] + 4:
                                            scen = scenarios[dstate["scen_idx"]]
                                            need_p2_mtags = bool(scen.use_p2_main_base or scen.p2_worker_micro != "brawl")
                                            if need_p2_mtags and not dstate["p2_main_mineral_tags"] and gl < dstate["phase_start_loop"] + 28:
                                                # Wait for P2's own observation to populate `p2_main_mineral_tags`
                                                pass
                                            else:
                                                dstate["p1_starter_bldg_tags"] = set()
                                                dstate["pre_setup_info"] = []
                                                dstate["warmup_spawned_p1_workers"] = False
                                                dstate["warmup_spawned_p2_workers"] = False
                                                dstate["warmup_spawned_creep_tumors"] = False
                                                dstate["warmup_p1_mine_issued"] = False
                                                dstate["warmup_p2_mine_issued"] = False
                                                dstate["carrier_fill_issued_p1"] = False
                                                dstate["carrier_fill_issued_p2"] = False
                                                dstate["p2_disruptor_cd"] = {}
                                                dstate["p2_disruptor_next_global"] = 0
                                                dstate["p1_bc_start_cnt"] = 0
                                                dstate["p1_bc_alive_cnt"] = 0
                                                if dstate["pre_setup_free_on"]:
                                                    await rpc(sc2_ws, sc2api_pb2.Request(
                                                        debug=sc2api_pb2.RequestDebug(debug=[debug_pb2.DebugCommand(game_state=debug_pb2.free)])
                                                    ))
                                                    dstate["pre_setup_free_on"] = False
                                                if dstate["carrier_fill_cheats_on"]:
                                                    await rpc(sc2_ws, sc2api_pb2.Request(
                                                        debug=sc2api_pb2.RequestDebug(debug=[
                                                            debug_pb2.DebugCommand(game_state=debug_pb2.fast_build),
                                                            debug_pb2.DebugCommand(game_state=debug_pb2.free),
                                                        ])
                                                    ))
                                                    dstate["carrier_fill_cheats_on"] = False
                                                # Restore starting TownHall HP/Shields if any prior main-base round chipped it
                                                heal_th: list[Any] = []
                                                for u in obs.raw_data.units:
                                                    if u.tag in dstate["orig_th_tags"]:
                                                        if float(u.health) < float(u.health_max) - 1.0:
                                                            heal_th.append(debug_pb2.DebugCommand(
                                                                unit_value=debug_pb2.DebugSetUnitValue(
                                                                    unit_value=debug_pb2.DebugSetUnitValue.Life,
                                                                    value=float(u.health_max),
                                                                    unit_tag=u.tag,
                                                                )
                                                            ))
                                                        if float(getattr(u, "shield_max", 0.0)) > 0.0 and float(u.shield) < float(u.shield_max) - 1.0:
                                                            heal_th.append(debug_pb2.DebugCommand(
                                                                unit_value=debug_pb2.DebugSetUnitValue(
                                                                    unit_value=debug_pb2.DebugSetUnitValue.Shields,
                                                                    value=float(u.shield_max),
                                                                    unit_tag=u.tag,
                                                                )
                                                            ))
                                                if heal_th:
                                                    await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=heal_th)))
                                                _advance_pipeline("clearing", scen, gl, obs)

                                    elif dstate["phase"] == "upgrade_spawn":
                                        scen = scenarios[dstate["scen_idx"]]
                                        all_need_p1 = [u for u in scen.p1_upgrades if u not in dstate["p1_done_upgrades"]]
                                        all_need_p2 = [u for u in scen.p2_upgrades if u not in dstate["p2_done_upgrades"]]

                                        def _ready_upgrade_wave(need: list[str], done: set[str]) -> list[str]:
                                            wave: list[str] = []
                                            for u in need:
                                                req_u = UPGRADE_PREREQ_UPGRADES.get(u)
                                                if req_u is not None and req_u not in done:
                                                    continue
                                                wave.append(u)
                                            return wave or need[:1]

                                        need_p1 = _ready_upgrade_wave(all_need_p1, dstate["p1_done_upgrades"]) if all_need_p1 else []
                                        need_p2 = _ready_upgrade_wave(all_need_p2, dstate["p2_done_upgrades"]) if all_need_p2 else []
                                        an: MapTerrainAnalyzer | None = dstate["analyzer"]
                                        open_site = an.sites["open"] if an is not None else ArenaSite("open", 88.0, 88.0)
                                        dbg_u: list[Any] = []
                                        # Enable ONLY fast_build + free (NO tech_tree!) so upgrades stay 100% selective per player!
                                        if not dstate["cheats_enabled_p1"]:
                                            dbg_u.extend([
                                                debug_pb2.DebugCommand(game_state=debug_pb2.fast_build),
                                                debug_pb2.DebugCommand(game_state=debug_pb2.free),
                                            ])
                                            dstate["cheats_enabled_p1"] = True

                                        def _queue_owner_bldgs(
                                            owner: int,
                                            upgs: list[str],
                                        ) -> tuple[list[tuple[str, int, int, float, float]], list[tuple[int, int, int, float, float]]]:
                                            pending_u: list[tuple[str, int, int, float, float]] = []
                                            pending_a: list[tuple[int, int, int, float, float]] = []
                                            if not upgs:
                                                return pending_u, pending_a
                                            base_pos = (
                                                dstate["p1_orig_th_pos"] if owner == 1 else dstate["p2_orig_th_pos"]
                                            ) or (open_site.cx, open_site.cy)
                                            # Determine unique prereqs needed for this owner
                                            prereqs: list[int] = []
                                            for unm in upgs:
                                                pr = UPGRADE_SPECS[unm][5]
                                                if pr is not None and pr not in prereqs:
                                                    prereqs.append(pr)
                                            need_addon_cnt = sum(1 for u in upgs if UPGRADE_SPECS[u][4] is not None)
                                            need_plain_cnt = len(prereqs) + sum(
                                                1 for u in upgs
                                                if UPGRADE_SPECS[u][4] is None
                                                and not (UPGRADE_SPECS[u][1] == 86 and ((owner == 1 and our_race == "Zerg") or (owner == 2 and enemy_race == "Zerg")))
                                            )
                                            avoid_pts = [(open_site.cx, open_site.cy)]
                                            avoid_th = list(dstate["orig_th_positions"])
                                            addon_spots = (
                                                an.find_buildable_spots(
                                                    base_pos[0], base_pos[1], need_addon_cnt,
                                                    avoid=avoid_pts, with_addon=True, min_spacing=6.5,
                                                    avoid_large=avoid_th, large_radius=12.0,
                                                )
                                                if (an is not None and need_addon_cnt > 0) else []
                                            )
                                            avoid_pts2 = avoid_pts + addon_spots
                                            plain_spots = (
                                                an.find_buildable_spots(
                                                    base_pos[0], base_pos[1], need_plain_cnt,
                                                    avoid=avoid_pts2, with_addon=False, min_spacing=5.5,
                                                    avoid_large=avoid_th, large_radius=12.0,
                                                )
                                                if (an is not None and need_plain_cnt > 0) else []
                                            )
                                            ai, pi = 0, 0
                                            for pr_uid in prereqs:
                                                px, py = plain_spots[pi] if pi < len(plain_spots) else (base_pos[0] + 6.0, base_pos[1])
                                                pi += 1
                                                if any(UPGRADE_SPECS[u][3] for u in upgs if UPGRADE_SPECS[u][5] == pr_uid):
                                                    py_x, py_y = (
                                                        an.snap_buildable_footprint(px, py - 3.0, 2, avoid=[(px, py, 2.6)])
                                                        if an is not None else (px, py - 3.0)
                                                    )
                                                    dbg_u.append(debug_pb2.DebugCommand(
                                                        create_unit=debug_pb2.DebugCreateUnit(
                                                            unit_type=60, owner=owner,
                                                            pos=common_pb2.Point2D(x=py_x, y=py_y), quantity=1,
                                                        )
                                                    ))
                                                dbg_u.append(debug_pb2.DebugCommand(
                                                    create_unit=debug_pb2.DebugCreateUnit(
                                                        unit_type=pr_uid, owner=owner,
                                                        pos=common_pb2.Point2D(x=px, y=py), quantity=1,
                                                    )
                                                ))
                                            for unm in upgs:
                                                _ur, bldg_uid, ab_id, needs_pyl, addon_info, _pr = UPGRADE_SPECS[unm]
                                                if bldg_uid == 86 and ((owner == 1 and our_race == "Zerg") or (owner == 2 and enemy_race == "Zerg")):
                                                    pending_u.append((unm, 86, ab_id, base_pos[0], base_pos[1]))
                                                    continue
                                                if addon_info is not None:
                                                    parent_uid, addon_ab = addon_info
                                                    bx, by = addon_spots[ai] if ai < len(addon_spots) else (base_pos[0] + 8.0, base_pos[1])
                                                    ai += 1
                                                    dbg_u.append(debug_pb2.DebugCommand(
                                                        create_unit=debug_pb2.DebugCreateUnit(
                                                            unit_type=parent_uid, owner=owner,
                                                            pos=common_pb2.Point2D(x=bx, y=by), quantity=1,
                                                        )
                                                    ))
                                                    pending_a.append((parent_uid, addon_ab, bldg_uid, bx, by))
                                                    pending_u.append((unm, bldg_uid, ab_id, bx + 2.5, by - 0.5))
                                                else:
                                                    bx, by = plain_spots[pi] if pi < len(plain_spots) else (base_pos[0] + 8.0, base_pos[1])
                                                    pi += 1
                                                    if needs_pyl:
                                                        py_x, py_y = (
                                                            an.snap_buildable_footprint(bx, by - 3.0, 2, avoid=[(bx, by, 2.6)])
                                                            if an is not None else (bx, by - 3.0)
                                                        )
                                                        dbg_u.append(debug_pb2.DebugCommand(
                                                            create_unit=debug_pb2.DebugCreateUnit(
                                                                unit_type=60, owner=owner,
                                                                pos=common_pb2.Point2D(x=py_x, y=py_y), quantity=1,
                                                            )
                                                        ))
                                                    dbg_u.append(debug_pb2.DebugCommand(
                                                        create_unit=debug_pb2.DebugCreateUnit(
                                                            unit_type=bldg_uid, owner=owner,
                                                            pos=common_pb2.Point2D(x=bx, y=by), quantity=1,
                                                        )
                                                    ))
                                                    pending_u.append((unm, bldg_uid, ab_id, bx, by))
                                            return pending_u, pending_a

                                        p1_u, p1_a = _queue_owner_bldgs(1, need_p1)
                                        p2_u, p2_a = _queue_owner_bldgs(2, need_p2)
                                        dstate["p1_pending_upgrades"] = p1_u
                                        dstate["p2_pending_upgrades"] = p2_u
                                        dstate["p1_pending_addons"] = p1_a
                                        dstate["p2_pending_addons"] = p2_a
                                        dstate["p1_upg_busy"] = bool(p1_u)
                                        dstate["p2_upg_busy"] = bool(p2_u)
                                        if dbg_u:
                                            await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg_u)))
                                        dstate["phase"] = "upgrade_addons" if (p1_a or p2_a) else "upgrade_issue"
                                        dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "upgrade_addons" and gl >= dstate["phase_start_loop"] + 4:
                                        if not dstate["p1_addons_issued"]:
                                            if not dstate["p1_pending_addons"]:
                                                dstate["p1_addons_issued"] = True
                                                dstate["p1_addons_ready"] = True
                                            else:
                                                acts_a1: list[Any] = []
                                                used_a1: set[int] = set()
                                                for p_uid, a_ab, _a_uid, bx, by in dstate["p1_pending_addons"]:
                                                    cands = [u for u in obs.raw_data.units if u.alliance == 1 and u.unit_type == p_uid and u.tag not in used_a1 and u.build_progress >= 0.99]
                                                    if cands:
                                                        b = min(cands, key=lambda u: math.hypot(u.pos.x - bx, u.pos.y - by))
                                                        used_a1.add(b.tag)
                                                        acts_a1.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=a_ab, unit_tags=[b.tag]))))
                                                if acts_a1 and (len(acts_a1) >= len(dstate["p1_pending_addons"]) or gl >= dstate["phase_start_loop"] + 20):
                                                    await rpc(sc2_ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts_a1)))
                                                    dstate["p1_addons_issued"] = True
                                        if dstate["p1_addons_issued"] and not dstate["p1_addons_ready"]:
                                            need_c1: dict[int, int] = {}
                                            for _pu, _aa, a_uid, _, _ in dstate["p1_pending_addons"]:
                                                need_c1[a_uid] = need_c1.get(a_uid, 0) + 1
                                            if all(
                                                sum(1 for u in obs.raw_data.units if u.alliance == 1 and u.unit_type == au and u.build_progress >= 0.99) >= cnt
                                                for au, cnt in need_c1.items()
                                            ):
                                                dstate["p1_addons_ready"] = True
                                        if (dstate["p1_addons_ready"] and dstate["p2_addons_ready"]) or gl >= dstate["phase_start_loop"] + 80:
                                            dstate["phase"] = "upgrade_issue"
                                            dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "upgrade_issue" and gl >= dstate["phase_start_loop"] + 4:
                                        if not dstate["p1_upg_issued"]:
                                            if not dstate["p1_pending_upgrades"]:
                                                dstate["p1_upg_issued"] = True
                                            else:
                                                rem_p1 = [it for it in dstate["p1_pending_upgrades"] if it[0] not in dstate["p1_accepted_upgrades"]]
                                                if not rem_p1:
                                                    dstate["p1_upg_issued"] = True
                                                else:
                                                    ok1, acc1 = await _issue_owner_upgrades(sc2_ws, obs, rem_p1)
                                                    dstate["p1_accepted_upgrades"].update(acc1)
                                                    if ok1 or len(dstate["p1_accepted_upgrades"]) >= len(dstate["p1_pending_upgrades"]) or gl >= dstate["phase_start_loop"] + 20:
                                                        dstate["p1_upg_issued"] = True
                                        if dstate["p1_upg_issued"] and (dstate["p2_upg_issued"] or gl >= dstate["phase_start_loop"] + 24):
                                            dstate["phase"] = "upgrade_wait"
                                            dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "upgrade_wait" and gl >= dstate["phase_start_loop"] + 12:
                                        p1_uids = {b for _, b, _, _, _ in dstate["p1_pending_upgrades"]}
                                        dstate["p1_upg_busy"] = bool(p1_uids) and any(
                                            u.alliance == 1 and u.unit_type in p1_uids and len(u.orders) > 0
                                            for u in obs.raw_data.units
                                        )
                                        if (not dstate["p1_upg_busy"] and not dstate["p2_upg_busy"]) or gl >= dstate["phase_start_loop"] + 360:
                                            dstate["upg_wave_attempts"] += 1
                                            # Mark accepted upgrades done (or all pending after max retry waves to avoid deadlock)
                                            force_mark = dstate["upg_wave_attempts"] >= 6
                                            for unm, _, _, _, _ in dstate["p1_pending_upgrades"]:
                                                if force_mark or unm in dstate["p1_accepted_upgrades"]:
                                                    dstate["p1_done_upgrades"].add(unm)
                                            for unm, _, _, _, _ in dstate["p2_pending_upgrades"]:
                                                if force_mark or unm in dstate["p2_accepted_upgrades"]:
                                                    dstate["p2_done_upgrades"].add(unm)
                                            dstate["p1_pending_upgrades"] = []
                                            dstate["p2_pending_upgrades"] = []
                                            dstate["p1_accepted_upgrades"] = set()
                                            dstate["p2_accepted_upgrades"] = set()
                                            dstate["p1_pending_addons"] = []
                                            dstate["p2_pending_addons"] = []
                                            kill_tmp = [
                                                u.tag for u in obs.raw_data.units
                                                if u.alliance in (1, 4) and u.tag not in dstate["orig_th_tags"]
                                                and not (dstate["p2_orig_th_tag"] is None and u.unit_type in TOWNHALL_IDS)
                                            ]
                                            dbg_done: list[Any] = []
                                            if kill_tmp:
                                                dbg_done.append(debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=kill_tmp)))
                                            if dstate["cheats_enabled_p1"]:
                                                dbg_done.extend([
                                                    debug_pb2.DebugCommand(game_state=debug_pb2.fast_build),
                                                    debug_pb2.DebugCommand(game_state=debug_pb2.free),
                                                ])
                                                dstate["cheats_enabled_p1"] = False
                                            if dbg_done:
                                                await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg_done)))
                                            dstate["p2_clear_ok"] = False
                                            dstate["phase"] = "clearing"
                                            dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "preload_spawn" and gl >= dstate["phase_start_loop"] + 2:
                                        scen = scenarios[dstate["scen_idx"]]
                                        an = dstate["analyzer"]
                                        site = _site_for_scen(scen)
                                        dstate["arena_cx"], dstate["arena_cy"] = site.cx, site.cy
                                        site_ov = site if (scen.use_main_base or scen.use_p2_main_base) else None
                                        dbg_pl: list[Any] = []
                                        pl_structs: list[tuple[float, float, float]] = (
                                            [(site.cx, site.cy, 3.2)]
                                            if (scen.use_main_base or scen.use_p2_main_base)
                                            else []
                                        )
                                        for owner_pl, lt_list in ((1, scen.p1_loaded_transports), (2, scen.p2_loaded_transports)):
                                            for lt in lt_list:
                                                t_name = lt["transport"]
                                                t_uid = UNIT_IDS[t_name]
                                                tx0, ty0 = (
                                                    an.resolve_spawn_point(scen, t_name, lt["dx"], lt["dy"], site_override=site_ov)
                                                    if an is not None else (site.cx + lt["dx"], site.cy + lt["dy"])
                                                )
                                                if t_uid in STRUCTURE_IDS:
                                                    fp = STRUCTURE_FOOTPRINTS.get(t_uid, 3)
                                                    tx, ty = (
                                                        an.snap_buildable_footprint(tx0, ty0, fp, avoid=pl_structs)
                                                        if an is not None else (tx0, ty0)
                                                    )
                                                    pl_structs.append((tx, ty, 3.0))
                                                else:
                                                    tx, ty = tx0, ty0
                                                dbg_pl.append(debug_pb2.DebugCommand(
                                                    create_unit=debug_pb2.DebugCreateUnit(
                                                        unit_type=t_uid, owner=owner_pl,
                                                        pos=common_pb2.Point2D(x=tx, y=ty), quantity=1,
                                                    )
                                                ))
                                                # Spawn cargo directly beneath/adjacent to transport on pathable ground
                                                c_gx, c_gy = (
                                                    an.snap_pathable(tx + (2.4 if t_uid in STRUCTURE_IDS else 0.0), ty, max_rad=5)
                                                    if an is not None else (tx, ty)
                                                )
                                                for cu_name, cu_cnt in lt["cargo"]:
                                                    dbg_pl.append(debug_pb2.DebugCommand(
                                                        create_unit=debug_pb2.DebugCreateUnit(
                                                            unit_type=UNIT_IDS[cu_name], owner=owner_pl,
                                                            pos=common_pb2.Point2D(x=c_gx, y=c_gy), quantity=cu_cnt,
                                                        )
                                                    ))
                                        if dbg_pl:
                                            await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg_pl)))
                                        dstate["phase"] = "preload_wait"
                                        dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "preload_wait" and gl >= dstate["phase_start_loop"] + 2:
                                        scen = scenarios[dstate["scen_idx"]]
                                        if not scen.p1_loaded_transports:
                                            dstate["p1_preload_ready"] = True
                                        elif not dstate["p1_preload_ready"] and gl >= dstate["p1_preload_last_loop"] + 4:
                                            dstate["p1_preload_last_loop"] = int(gl)
                                            dstate["p1_preload_ready"] = await _issue_preload_cmds(sc2_ws, obs, scen.p1_loaded_transports)
                                        if (dstate["p1_preload_ready"] and dstate["p2_preload_ready"]) or gl >= dstate["phase_start_loop"] + 48:
                                            _advance_pipeline("preload", scen, gl, obs)

                                    elif dstate["phase"] == "pre_setup_spawn" and gl >= dstate["phase_start_loop"] + 2:
                                        scen = scenarios[dstate["scen_idx"]]
                                        an = dstate["analyzer"]
                                        site = _site_for_scen(scen)
                                        dstate["arena_cx"], dstate["arena_cy"] = site.cx, site.cy
                                        dstate["p1_starter_bldg_tags"] = set()
                                        dstate["pre_setup_instant_positions"] = {}
                                        dstate["pre_setup_temp_worker_tags"] = set()
                                        dstate["pre_setup_claimed_geysers"] = set()
                                        dstate["pre_setup_info"] = []
                                        placed_ps: list[tuple[float, float, float]] = [(site.cx, site.cy, 3.6)]
                                        for u_env in obs.raw_data.units:
                                            if u_env.unit_type in MINERAL_IDS or u_env.unit_type in GEYSER_IDS:
                                                if math.hypot(float(u_env.pos.x) - site.cx, float(u_env.pos.y) - site.cy) <= 13.0:
                                                    placed_ps.append((float(u_env.pos.x), float(u_env.pos.y), 2.5))

                                        dbg_ps: list[Any] = []
                                        inprog_list: list[dict[str, Any]] = []
                                        for sb in scen.p1_starter_buildings:
                                            bname = sb["unit"]
                                            bspec = STARTER_BUILDING_SPECS[bname]
                                            prog = float(sb.get("progress", 1.0))
                                            halted = bool(sb.get("halted", False))
                                            on_geyser = bool(sb.get("on_geyser", bspec["on_geyser"]))
                                            if prog >= 0.99 and not on_geyser:
                                                fp = int(bspec["footprint"])
                                                if bspec["needs_pylon"] and "pylon" in dstate["pre_setup_instant_positions"]:
                                                    py_x, py_y = dstate["pre_setup_instant_positions"]["pylon"]
                                                    sx0, sy0 = py_x + 3.0 * site.ux, py_y + 3.0 * site.uy
                                                else:
                                                    sx0, sy0 = (
                                                        an.site_offset_world(site, float(sb["dx"]), float(sb["dy"]))
                                                        if an is not None else (site.cx + float(sb["dx"]), site.cy + float(sb["dy"]))
                                                    )
                                                creep_im = getattr(getattr(obs.raw_data, "map_state", None), "creep", None) if bspec["needs_creep"] else None
                                                sx, sy = (
                                                    an.snap_buildable_footprint(sx0, sy0, fp, avoid=placed_ps, creep_img=creep_im)
                                                    if an is not None else (sx0, sy0)
                                                )
                                                placed_ps.append((sx, sy, 3.0 if fp >= 3 else 2.4))
                                                dstate["pre_setup_instant_positions"][bname] = (sx, sy)
                                                dbg_ps.append(debug_pb2.DebugCommand(
                                                    create_unit=debug_pb2.DebugCreateUnit(
                                                        unit_type=int(bspec["unit_id"]),
                                                        owner=1,
                                                        pos=common_pb2.Point2D(x=sx, y=sy),
                                                        quantity=1,
                                                    )
                                                ))
                                                dstate["pre_setup_info"].append({
                                                    "unit": bname, "mode": "instant", "target_progress": 1.0,
                                                    "actual_progress": 1.0, "halted": False,
                                                })
                                            else:
                                                b_loops = int(bspec["build_loops"])
                                                est_bank = 65 if (scen.p1_minerals > 50 and not halted) else 0
                                                adj_loops = max(24, int(round(b_loops * prog)) - est_bank)
                                                adj_prog = max(0.04, min(0.95, adj_loops / float(b_loops)))
                                                inprog_list.append({
                                                    "unit": bname,
                                                    "unit_id": int(bspec["unit_id"]),
                                                    "footprint": int(bspec["footprint"]),
                                                    "build_ability": int(bspec["build_ability"]),
                                                    "builder_uid": int(bspec["builder_uid"]),
                                                    "needs_pylon": bool(bspec["needs_pylon"]),
                                                    "needs_creep": bool(bspec["needs_creep"]),
                                                    "on_geyser": on_geyser,
                                                    "dx": float(sb["dx"]),
                                                    "dy": float(sb["dy"]),
                                                    "target_progress": prog,
                                                    "adj_target_loops": adj_loops,
                                                    "adj_target_prog": adj_prog,
                                                    "halted": halted,
                                                    "state": "pending",
                                                    "target_pos": None,
                                                    "target_tag": None,
                                                    "bldg_tag": None,
                                                    "spawn_loop": -1,
                                                    "last_cmd_loop": -100,
                                                    "actual_progress": 0.0,
                                                })
                                        max_adj = max((it["adj_target_loops"] for it in inprog_list), default=0)
                                        for it in inprog_list:
                                            it["start_offset"] = max(0, max_adj - it["adj_target_loops"])
                                        dstate["pre_setup_placed"] = placed_ps
                                        dstate["pre_setup_inprog"] = inprog_list
                                        dstate["pre_setup_max_loops"] = max_adj
                                        if dbg_ps:
                                            await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg_ps)))
                                        dstate["phase"] = "pre_setup_wait"
                                        dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "pre_setup_wait" and gl >= dstate["phase_start_loop"] + 6:
                                        scen = scenarios[dstate["scen_idx"]]
                                        an = dstate["analyzer"]
                                        site = _site_for_scen(scen)
                                        for u_st in obs.raw_data.units:
                                            if u_st.alliance == 1 and u_st.tag not in dstate["orig_th_tags"] and u_st.unit_type in STARTER_BUILDING_UIDS:
                                                dstate["p1_starter_bldg_tags"].add(u_st.tag)
                                        inprog = dstate["pre_setup_inprog"]
                                        if not inprog:
                                            _advance_pipeline("pre_setup", scen, gl, obs)
                                        else:
                                            any_need_free = any(it["state"] in ("pending", "worker_spawned") for it in inprog)
                                            if any_need_free and not dstate["pre_setup_free_on"]:
                                                await rpc(sc2_ws, sc2api_pb2.Request(
                                                    debug=sc2api_pb2.RequestDebug(debug=[debug_pb2.DebugCommand(game_state=debug_pb2.free)])
                                                ))
                                                dstate["pre_setup_free_on"] = True
                                            elif not any_need_free and dstate["pre_setup_free_on"]:
                                                await rpc(sc2_ws, sc2api_pb2.Request(
                                                    debug=sc2api_pb2.RequestDebug(debug=[debug_pb2.DebugCommand(game_state=debug_pb2.free)])
                                                ))
                                                dstate["pre_setup_free_on"] = False

                                            elapsed_ps = gl - (dstate["phase_start_loop"] + 6)
                                            dbg_step: list[Any] = []
                                            acts_step: list[Any] = []
                                            kill_w_step: list[int] = []

                                            for it in inprog:
                                                st = it["state"]
                                                if st == "pending" and elapsed_ps >= it["start_offset"]:
                                                    if it["on_geyser"]:
                                                        g_cands = [
                                                            u_g for u_g in obs.raw_data.units
                                                            if u_g.unit_type in GEYSER_IDS and u_g.alliance == 3
                                                            and u_g.tag not in dstate["pre_setup_claimed_geysers"]
                                                            and math.hypot(float(u_g.pos.x) - site.cx, float(u_g.pos.y) - site.cy) <= 14.0
                                                        ]
                                                        if not g_cands:
                                                            it["state"] = "fallback"
                                                            continue
                                                        g_best = min(g_cands, key=lambda u_g: math.hypot(float(u_g.pos.x) - site.cx, float(u_g.pos.y) - site.cy))
                                                        dstate["pre_setup_claimed_geysers"].add(g_best.tag)
                                                        it["target_tag"] = int(g_best.tag)
                                                        tx, ty = float(g_best.pos.x), float(g_best.pos.y)
                                                        it["target_pos"] = (tx, ty)
                                                    else:
                                                        fp = int(it["footprint"])
                                                        if it["needs_pylon"] and "pylon" in dstate["pre_setup_instant_positions"]:
                                                            py_x, py_y = dstate["pre_setup_instant_positions"]["pylon"]
                                                            sx0, sy0 = py_x + 3.0 * site.ux, py_y + 3.0 * site.uy
                                                            tx, ty = (
                                                                an.snap_buildable_footprint(sx0, sy0, fp, avoid=dstate["pre_setup_placed"], max_rad=5)
                                                                if an is not None else (sx0, sy0)
                                                            )
                                                        else:
                                                            sx0, sy0 = (
                                                                an.site_offset_world(site, it["dx"], it["dy"])
                                                                if an is not None else (site.cx + it["dx"], site.cy + it["dy"])
                                                            )
                                                            creep_im = getattr(getattr(obs.raw_data, "map_state", None), "creep", None) if it["needs_creep"] else None
                                                            tx, ty = (
                                                                an.snap_buildable_footprint(sx0, sy0, fp, avoid=dstate["pre_setup_placed"], max_rad=10, creep_img=creep_im)
                                                                if an is not None else (sx0, sy0)
                                                            )
                                                        dstate["pre_setup_placed"].append((tx, ty, 3.0 if fp >= 3 else 2.4))
                                                        it["target_pos"] = (tx, ty)
                                                    wx0, wy0 = (
                                                        an.snap_pathable(tx - 2.2 * site.ux, ty - 2.2 * site.uy, max_rad=4)
                                                        if an is not None else (tx - 2.2, ty)
                                                    )
                                                    dbg_step.append(debug_pb2.DebugCommand(
                                                        create_unit=debug_pb2.DebugCreateUnit(
                                                            unit_type=int(it["builder_uid"]),
                                                            owner=1,
                                                            pos=common_pb2.Point2D(x=wx0, y=wy0),
                                                            quantity=1,
                                                        )
                                                    ))
                                                    it["state"] = "worker_spawned"
                                                    it["spawn_loop"] = int(gl)

                                                elif st == "worker_spawned":
                                                    tx, ty = it["target_pos"]
                                                    found_b = [
                                                        u_b for u_b in obs.raw_data.units
                                                        if u_b.alliance == 1 and u_b.unit_type == it["unit_id"]
                                                        and u_b.tag not in dstate["p1_starter_bldg_tags"]
                                                        and math.hypot(float(u_b.pos.x) - tx, float(u_b.pos.y) - ty) <= 4.5
                                                    ]
                                                    if found_b:
                                                        b_u = min(found_b, key=lambda u_b: math.hypot(float(u_b.pos.x) - tx, float(u_b.pos.y) - ty))
                                                        it["state"] = "building"
                                                        it["bldg_tag"] = int(b_u.tag)
                                                        dstate["p1_starter_bldg_tags"].add(int(b_u.tag))
                                                    elif gl >= it["spawn_loop"] + 88:
                                                        it["state"] = "fallback"
                                                    elif gl >= it["last_cmd_loop"] + 8:
                                                        w_cands = [
                                                            u_w for u_w in obs.raw_data.units
                                                            if u_w.alliance == 1 and u_w.unit_type == it["builder_uid"]
                                                            and math.hypot(float(u_w.pos.x) - tx, float(u_w.pos.y) - ty) <= 10.0
                                                        ]
                                                        if w_cands:
                                                            bw = min(w_cands, key=lambda u_w: math.hypot(float(u_w.pos.x) - tx, float(u_w.pos.y) - ty))
                                                            dstate["pre_setup_temp_worker_tags"].add(int(bw.tag))
                                                            if it["target_tag"] is not None:
                                                                ucmd = raw_pb2.ActionRawUnitCommand(
                                                                    ability_id=int(it["build_ability"]),
                                                                    target_unit_tag=int(it["target_tag"]),
                                                                    unit_tags=[bw.tag],
                                                                )
                                                            else:
                                                                ucmd = raw_pb2.ActionRawUnitCommand(
                                                                    ability_id=int(it["build_ability"]),
                                                                    target_world_space_pos=common_pb2.Point2D(x=tx, y=ty),
                                                                    unit_tags=[bw.tag],
                                                                )
                                                            acts_step.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=ucmd)))
                                                            it["last_cmd_loop"] = int(gl)

                                                elif st == "building":
                                                    b_tag = it["bldg_tag"]
                                                    b_matches = [u_b for u_b in obs.raw_data.units if u_b.tag == b_tag]
                                                    if not b_matches:
                                                        it["state"] = "fallback"
                                                    else:
                                                        b_u = b_matches[0]
                                                        it["actual_progress"] = round(float(b_u.build_progress), 3)
                                                        if float(b_u.build_progress) >= float(it["adj_target_prog"]) - 0.015:
                                                            it["state"] = "ready"
                                                            if it["halted"]:
                                                                # Kill the building SCV right at target progress -> genuine halted Terran building!
                                                                for u_w in obs.raw_data.units:
                                                                    if u_w.alliance == 1 and u_w.unit_type == it["builder_uid"] and math.hypot(float(u_w.pos.x) - float(b_u.pos.x), float(u_w.pos.y) - float(b_u.pos.y)) <= 5.5:
                                                                        kill_w_step.append(int(u_w.tag))

                                            if kill_w_step:
                                                dbg_step.append(debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=sorted(set(kill_w_step)))))
                                            if dbg_step:
                                                await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg_step)))
                                            if acts_step:
                                                await rpc(sc2_ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts_step)))

                                            all_done_ps = all(it["state"] in ("ready", "fallback") for it in inprog)
                                            timed_out_ps = elapsed_ps >= int(dstate["pre_setup_max_loops"]) + 160
                                            if all_done_ps or timed_out_ps:
                                                dbg_fin: list[Any] = []
                                                stray_ws = [
                                                    u_w.tag for u_w in obs.raw_data.units
                                                    if u_w.alliance == 1 and u_w.unit_type in WORKER_IDS
                                                ]
                                                if stray_ws:
                                                    dbg_fin.append(debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=stray_ws)))
                                                if dstate["pre_setup_free_on"]:
                                                    dbg_fin.append(debug_pb2.DebugCommand(game_state=debug_pb2.free))
                                                    dstate["pre_setup_free_on"] = False
                                                for it in inprog:
                                                    mode_lbl = it["state"]
                                                    if it["state"] != "ready" and not it["on_geyser"] and it["bldg_tag"] is None:
                                                        tx, ty = it["target_pos"] or (site.cx + it["dx"], site.cy + it["dy"])
                                                        dbg_fin.append(debug_pb2.DebugCommand(
                                                            create_unit=debug_pb2.DebugCreateUnit(
                                                                unit_type=int(it["unit_id"]),
                                                                owner=1,
                                                                pos=common_pb2.Point2D(x=tx, y=ty),
                                                                quantity=1,
                                                            )
                                                        ))
                                                        mode_lbl = "fallback_debug_create"
                                                        it["actual_progress"] = 1.0
                                                    dstate["pre_setup_info"].append({
                                                        "unit": it["unit"],
                                                        "mode": mode_lbl,
                                                        "target_progress": it["target_progress"],
                                                        "actual_progress": it["actual_progress"],
                                                        "halted": it["halted"],
                                                    })
                                                if dbg_fin:
                                                    await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg_fin)))
                                                _advance_pipeline("pre_setup", scen, gl, obs)

                                    elif dstate["phase"] == "pre_bank_spawn" and gl >= dstate["phase_start_loop"] + 4:
                                        scen = scenarios[dstate["scen_idx"]]
                                        an = dstate["analyzer"]
                                        site = _site_for_scen(scen)
                                        dstate["arena_cx"], dstate["arena_cy"] = site.cx, site.cy
                                        cur_m = int(getattr(obs.player_common, "minerals", 50))
                                        need_m = max(0, int(scen.p1_minerals) - cur_m)
                                        if need_m <= 0:
                                            _advance_pipeline("pre_bank", scen, gl, obs)
                                        else:
                                            n_miners = min(8, max(1, (need_m + 4) // 5))
                                            w_uid = RACE_WORKER_IDS.get(scen.our_race, 45)
                                            mx0, my0 = (
                                                an.site_offset_world(site, -3.0, 0.0)
                                                if an is not None else (site.cx - 3.0, site.cy)
                                            )
                                            if an is not None:
                                                mx0, my0 = an.snap_pathable(mx0, my0, max_rad=4)
                                            await rpc(sc2_ws, sc2api_pb2.Request(
                                                debug=sc2api_pb2.RequestDebug(debug=[
                                                    debug_pb2.DebugCommand(
                                                        create_unit=debug_pb2.DebugCreateUnit(
                                                            unit_type=w_uid,
                                                            owner=1,
                                                            pos=common_pb2.Point2D(x=mx0, y=my0),
                                                            quantity=n_miners,
                                                        )
                                                    )
                                                ])
                                            ))
                                            dstate["pre_bank_mine_issued"] = False
                                            dstate["phase"] = "pre_bank_wait"
                                            dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "pre_bank_wait" and gl >= dstate["phase_start_loop"] + 2:
                                        scen = scenarios[dstate["scen_idx"]]
                                        cur_m = int(getattr(obs.player_common, "minerals", 50))
                                        bank_ws = [
                                            u_w for u_w in obs.raw_data.units
                                            if u_w.alliance == 1 and u_w.unit_type in WORKER_IDS
                                        ]
                                        if not dstate["pre_bank_mine_issued"] and bank_ws and dstate["p1_main_mineral_tags"]:
                                            mtags_b = list(dstate["p1_main_mineral_tags"])
                                            # Prefer closest mineral patches so 1 trip completes in ~60 loops
                                            m_pos_map = {
                                                int(u_m.tag): (float(u_m.pos.x), float(u_m.pos.y))
                                                for u_m in obs.raw_data.units
                                                if int(u_m.tag) in set(mtags_b)
                                            }
                                            mtags_sorted = sorted(
                                                mtags_b,
                                                key=lambda mt: math.hypot(
                                                    m_pos_map.get(mt, (0.0, 0.0))[0] - dstate["arena_cx"],
                                                    m_pos_map.get(mt, (0.0, 0.0))[1] - dstate["arena_cy"],
                                                ),
                                            )
                                            g_b_acts = [
                                                sc2api_pb2.Action(
                                                    action_raw=raw_pb2.ActionRaw(
                                                        unit_command=raw_pb2.ActionRawUnitCommand(
                                                            ability_id=3666,
                                                            target_unit_tag=mtags_sorted[i % len(mtags_sorted)],
                                                            unit_tags=[wu.tag],
                                                        )
                                                    )
                                                )
                                                for i, wu in enumerate(bank_ws)
                                            ]
                                            await rpc(sc2_ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=g_b_acts)))
                                            dstate["pre_bank_mine_issued"] = True
                                        if cur_m >= int(scen.p1_minerals) or gl >= dstate["phase_start_loop"] + 160:
                                            if bank_ws:
                                                await rpc(sc2_ws, sc2api_pb2.Request(
                                                    debug=sc2api_pb2.RequestDebug(debug=[
                                                        debug_pb2.DebugCommand(kill_unit=debug_pb2.DebugKillUnit(tag=[u_w.tag for u_w in bank_ws]))
                                                    ])
                                                ))
                                            _advance_pipeline("pre_bank", scen, gl, obs)

                                    elif dstate["phase"] == "mine_warmup_spawn" and gl >= dstate["phase_start_loop"] + 4:
                                        scen = scenarios[dstate["scen_idx"]]
                                        an = dstate["analyzer"]
                                        site = _site_for_scen(scen)
                                        dstate["arena_cx"], dstate["arena_cy"] = site.cx, site.cy
                                        site_ov = site if (scen.use_main_base or scen.use_p2_main_base) else None
                                        dbg_wu: list[Any] = []
                                        if scen.use_main_base and dstate["p1_orig_th_pos"] is not None:
                                            for uname, cnt, _dx, _dy in scen.p1_units:
                                                if UNIT_IDS[uname] in WORKER_IDS:
                                                    w_pts = compute_per_patch_worker_positions(
                                                        dstate["p1_main_mineral_positions"],
                                                        dstate["p1_orig_th_pos"],
                                                        cnt,
                                                    )
                                                    for wx, wy in w_pts:
                                                        if an is not None:
                                                            wx, wy = an.snap_pathable(wx, wy, max_rad=3)
                                                        dbg_wu.append(debug_pb2.DebugCommand(
                                                            create_unit=debug_pb2.DebugCreateUnit(
                                                                unit_type=UNIT_IDS[uname], owner=1,
                                                                pos=common_pb2.Point2D(x=wx, y=wy), quantity=1,
                                                            )
                                                        ))
                                                    dstate["warmup_spawned_p1_workers"] = True
                                        if scen.use_p2_main_base and dstate["p2_orig_th_pos"] is not None:
                                            for uname, cnt, _dx, _dy in scen.p2_units:
                                                if UNIT_IDS[uname] in WORKER_IDS:
                                                    w_pts2 = compute_per_patch_worker_positions(
                                                        dstate["p2_main_mineral_positions"],
                                                        dstate["p2_orig_th_pos"],
                                                        cnt,
                                                    )
                                                    for wx, wy in w_pts2:
                                                        if an is not None:
                                                            wx, wy = an.snap_pathable(wx, wy, max_rad=3)
                                                        dbg_wu.append(debug_pb2.DebugCommand(
                                                            create_unit=debug_pb2.DebugCreateUnit(
                                                                unit_type=UNIT_IDS[uname], owner=2,
                                                                pos=common_pb2.Point2D(x=wx, y=wy), quantity=1,
                                                            )
                                                        ))
                                                    dstate["warmup_spawned_p2_workers"] = True
                                        for owner_ct, entries_ct in ((1, scen.p1_units), (2, scen.p2_units)):
                                            for uname, cnt, dx, dy in entries_ct:
                                                if uname == "creep-tumor-burrowed":
                                                    tx, ty = (
                                                        an.resolve_spawn_point(scen, uname, dx, dy, site_override=site_ov)
                                                        if an is not None else (site.cx + dx, site.cy + dy)
                                                    )
                                                    dbg_wu.append(debug_pb2.DebugCommand(
                                                        create_unit=debug_pb2.DebugCreateUnit(
                                                            unit_type=UNIT_IDS[uname], owner=owner_ct,
                                                            pos=common_pb2.Point2D(x=tx, y=ty), quantity=cnt,
                                                        )
                                                    ))
                                                    dstate["warmup_spawned_creep_tumors"] = True
                                        if dbg_wu:
                                            await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg_wu)))
                                            dstate["warmup_p1_mine_issued"] = False
                                            dstate["warmup_p2_mine_issued"] = False
                                            dstate["phase"] = "mine_warmup_wait"
                                            dstate["phase_start_loop"] = gl
                                        else:
                                            _advance_pipeline("mine_warmup", scen, gl, obs)

                                    elif dstate["phase"] == "mine_warmup_wait" and gl >= dstate["phase_start_loop"] + 2:
                                        scen = scenarios[dstate["scen_idx"]]
                                        if dstate["warmup_spawned_p1_workers"] and not dstate["warmup_p1_mine_issued"]:
                                            mtags1 = list(dstate["p1_main_mineral_tags"])
                                            mpos1 = list(dstate["p1_main_mineral_positions"])
                                            p1_ws_wu = [
                                                u for u in obs.raw_data.units
                                                if u.display_type == 1 and u.alliance == 1
                                                and u.tag not in dstate["orig_th_tags"]
                                                and u.unit_type in WORKER_IDS
                                            ]
                                            if p1_ws_wu and mtags1:
                                                th1_x, th1_y = dstate["p1_orig_th_pos"] or (dstate["arena_cx"], dstate["arena_cy"])
                                                p1_ws_wu.sort(key=lambda wu: math.atan2(float(wu.pos.y) - th1_y, float(wu.pos.x) - th1_x))
                                                g_wu1 = [
                                                    sc2api_pb2.Action(
                                                        action_raw=raw_pb2.ActionRaw(
                                                            unit_command=raw_pb2.ActionRawUnitCommand(
                                                                ability_id=3666,
                                                                target_unit_tag=mtags1[(i_w // 2) % len(mtags1)],
                                                                unit_tags=[wu.tag],
                                                            )
                                                        )
                                                    )
                                                    for i_w, wu in enumerate(p1_ws_wu)
                                                ]
                                                await rpc(sc2_ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=g_wu1)))
                                                dstate["warmup_p1_mine_issued"] = True
                                        # 40f when exact p1_minerals bank requested (< 1 return trip so bank stays exact!), 48f otherwise
                                        wu_loops = 40 if scen.p1_minerals > 0 else 48
                                        if gl >= dstate["phase_start_loop"] + wu_loops:
                                            _advance_pipeline("mine_warmup", scen, gl, obs)

                                    elif dstate["phase"] == "spawning" and gl >= dstate["phase_start_loop"] + (4 if (scenarios[dstate["scen_idx"]].p1_starter_buildings or scenarios[dstate["scen_idx"]].p1_minerals > 0) else 2):
                                        scen = scenarios[dstate["scen_idx"]]
                                        an = dstate["analyzer"]
                                        site = _site_for_scen(scen)
                                        dstate["arena_cx"], dstate["arena_cy"] = site.cx, site.cy
                                        dstate["upg_wave_attempts"] = 0
                                        if dstate["pre_setup_free_on"]:
                                            await rpc(sc2_ws, sc2api_pb2.Request(
                                                debug=sc2api_pb2.RequestDebug(debug=[debug_pb2.DebugCommand(game_state=debug_pb2.free)])
                                            ))
                                            dstate["pre_setup_free_on"] = False
                                        if scen.p1_starter_buildings:
                                            for u_sb in obs.raw_data.units:
                                                if u_sb.alliance == 1 and u_sb.tag not in dstate["orig_th_tags"] and u_sb.unit_type in STARTER_BUILDING_UIDS:
                                                    dstate["p1_starter_bldg_tags"].add(u_sb.tag)
                                        site_ov = site if (scen.use_main_base or scen.use_p2_main_base) else None
                                        dbg = []
                                        placed_structs: list[tuple[float, float, float]] = (
                                            [(site.cx, site.cy, 3.2)]
                                            if (scen.use_main_base or scen.use_p2_main_base)
                                            else []
                                        )

                                        def _spawn_side_entries(entries: list[tuple[str, int, float, float]], owner: int) -> None:
                                            # Ensure any Photon Cannon (`66`) has a powering Pylon (`60`) on that side!
                                            eff_entries = []
                                            for item in entries:
                                                uname_i = item[0]
                                                if owner == 1 and dstate["warmup_spawned_p1_workers"] and UNIT_IDS[uname_i] in WORKER_IDS:
                                                    continue
                                                if owner == 2 and dstate["warmup_spawned_p2_workers"] and UNIT_IDS[uname_i] in WORKER_IDS:
                                                    continue
                                                if dstate["warmup_spawned_creep_tumors"] and uname_i == "creep-tumor-burrowed":
                                                    continue
                                                eff_entries.append(item)
                                            has_cannon = [it for it in eff_entries if UNIT_IDS[it[0]] == 66]
                                            has_pylon = any(UNIT_IDS[it[0]] == 60 for it in eff_entries)
                                            if has_cannon and not has_pylon:
                                                c_dx, c_dy = has_cannon[0][2], has_cannon[0][3]
                                                eff_entries.append(("pylon", 1, c_dx + (1.5 if c_dx >= 0 else -1.5), c_dy))
                                            # Spawn static structures FIRST on exact buildable grid centers, then mobile units cleanly outside footprints!
                                            struct_items = [(u, c, dx, dy) for u, c, dx, dy in eff_entries if UNIT_IDS[u] in STRUCTURE_IDS]
                                            mobile_items = [(u, c, dx, dy) for u, c, dx, dy in eff_entries if UNIT_IDS[u] not in STRUCTURE_IDS]
                                            for uname, cnt, dx, dy in struct_items:
                                                uid = UNIT_IDS[uname]
                                                fp = STRUCTURE_FOOTPRINTS.get(uid, 2)
                                                sx0, sy0 = an.resolve_spawn_point(scen, uname, dx, dy, site_override=site_ov) if an is not None else (site.cx + dx, site.cy + dy)
                                                for _k in range(cnt):
                                                    sx, sy = (
                                                        an.snap_buildable_footprint(sx0, sy0, fp, avoid=placed_structs)
                                                        if an is not None else (sx0, sy0)
                                                    )
                                                    placed_structs.append((sx, sy, 3.8 if fp >= 5 else 2.4))
                                                    dbg.append(debug_pb2.DebugCommand(
                                                        create_unit=debug_pb2.DebugCreateUnit(
                                                            unit_type=uid, owner=owner,
                                                            pos=common_pb2.Point2D(x=sx, y=sy), quantity=1,
                                                        )
                                                    ))
                                            for uname, cnt, dx, dy in mobile_items:
                                                uid = UNIT_IDS[uname]
                                                sx, sy = an.resolve_spawn_point(scen, uname, dx, dy, site_override=site_ov) if an is not None else (site.cx + dx, site.cy + dy)
                                                if uid not in AIR_UNIT_IDS and placed_structs:
                                                    for stx, sty, st_rad in placed_structs:
                                                        min_clr = st_rad - 0.5
                                                        d_st = math.hypot(sx - stx, sy - sty)
                                                        if d_st < min_clr:
                                                            vx = (sx - stx) if d_st > 0.05 else (1.0 if dx >= 0 else -1.0)
                                                            vy = (sy - sty) if d_st > 0.05 else 0.0
                                                            vn = max(0.05, math.hypot(vx, vy))
                                                            sx = stx + (vx / vn) * (min_clr + 0.4)
                                                            sy = sty + (vy / vn) * (min_clr + 0.4)
                                                            if an is not None:
                                                                sx, sy = an.snap_pathable(sx, sy, max_rad=4)
                                                dbg.append(debug_pb2.DebugCommand(
                                                    create_unit=debug_pb2.DebugCreateUnit(
                                                        unit_type=uid, owner=owner,
                                                        pos=common_pb2.Point2D(x=sx, y=sy), quantity=cnt,
                                                    )
                                                ))

                                        _spawn_side_entries(scen.p1_units, 1)
                                        _spawn_side_entries(scen.p2_units, 2)
                                        if dbg:
                                            await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg)))
                                        has_carriers = any(u == "carrier" for u, _, _, _ in (scen.p1_units + scen.p2_units))
                                        if has_carriers:
                                            dstate["carrier_fill_cheats_on"] = False
                                            dstate["carrier_fill_issued_p1"] = False
                                            dstate["carrier_fill_issued_p2"] = False
                                            dstate["phase"] = "carrier_fill"
                                        else:
                                            dstate["phase"] = "fighting"
                                        dstate["phase_start_loop"] = gl
                                        dstate["fight_start_loop"] = gl
                                        dstate["round_t0"] = time.monotonic()
                                        dstate["attack_cmds"] = 0
                                        dstate["move_cmds"] = 0
                                        dstate["spell_cmds"] = 0
                                        dstate["ability_counts"] = {}
                                        dstate["p2_attack_cmds"] = 0
                                        dstate["p2_move_cmds"] = 0
                                        dstate["p2_spell_cmds"] = 0
                                        dstate["p2_ability_counts"] = {}
                                        dstate["first_action_loop_offset"] = -1
                                        dstate["p1_start_cnt"] = 0
                                        dstate["p2_start_cnt"] = 0
                                        dstate["p1_start_val"] = 0.0
                                        dstate["p2_start_val"] = 0.0
                                        dstate["p1_bc_start_cnt"] = 0
                                        dstate["p1_bc_alive_cnt"] = 0
                                        dstate["p2_pf_start_cnt"] = 0
                                        dstate["p2_pf_alive_cnt"] = 0
                                        dstate["p2_det_start_cnt"] = 0
                                        dstate["p2_det_alive_cnt"] = 0
                                        dstate["p2_w_start_cnt"] = 0
                                        dstate["p2_w_alive_cnt"] = 0
                                        dstate["p2_own_units"] = None
                                        dstate["p2_own_units_loop"] = -1
                                        dstate["p2_pre_cloak_pending"] = False
                                        dstate["p2_runby_mine_issued"] = False
                                        dstate["p2_econ_start_minerals"] = 0.0
                                        dstate["p2_econ_cur_minerals"] = 0.0
                                        dstate["econ_start_minerals"] = 0.0
                                        dstate["econ_cur_minerals"] = 0.0
                                        dstate["econ_start_workers"] = 0
                                        dstate["econ_seen_worker_tags"] = set()
                                        dstate["econ_cur_worker_tags"] = set()
                                        dstate["econ_worker_mining_ticks"] = 0
                                        dstate["econ_worker_total_ticks"] = 0

                                    elif dstate["phase"] == "carrier_fill" and gl >= dstate["phase_start_loop"] + 2:
                                        # Top off debug-spawned Carriers from SC2's default 4/8 -> full 8/8 Interceptors (`1042`)!
                                        if not dstate["carrier_fill_cheats_on"]:
                                            await rpc(sc2_ws, sc2api_pb2.Request(
                                                debug=sc2api_pb2.RequestDebug(debug=[
                                                    debug_pb2.DebugCommand(game_state=debug_pb2.fast_build),
                                                    debug_pb2.DebugCommand(game_state=debug_pb2.free),
                                                ])
                                            ))
                                            dstate["carrier_fill_cheats_on"] = True
                                        elif not dstate["carrier_fill_issued_p1"]:
                                            p1_carriers = [u.tag for u in obs.raw_data.units if u.alliance == 1 and u.unit_type == 79]
                                            if p1_carriers:
                                                acts_ic1 = [
                                                    sc2api_pb2.Action(
                                                        action_raw=raw_pb2.ActionRaw(
                                                            unit_command=raw_pb2.ActionRawUnitCommand(
                                                                ability_id=1042,
                                                                unit_tags=p1_carriers,
                                                            )
                                                        )
                                                    )
                                                    for _ in range(4)
                                                ]
                                                await rpc(sc2_ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts_ic1)))
                                            dstate["carrier_fill_issued_p1"] = True
                                        elif gl >= dstate["phase_start_loop"] + 16:
                                            if dstate["carrier_fill_cheats_on"]:
                                                await rpc(sc2_ws, sc2api_pb2.Request(
                                                    debug=sc2api_pb2.RequestDebug(debug=[
                                                        debug_pb2.DebugCommand(game_state=debug_pb2.fast_build),
                                                        debug_pb2.DebugCommand(game_state=debug_pb2.free),
                                                    ])
                                                ))
                                                dstate["carrier_fill_cheats_on"] = False
                                            dstate["phase"] = "fighting"
                                            dstate["phase_start_loop"] = gl
                                            dstate["fight_start_loop"] = gl
                                            dstate["round_t0"] = time.monotonic()

                                    elif dstate["phase"] == "fighting":
                                        scen = scenarios[dstate["scen_idx"]]
                                        cx, cy = dstate["arena_cx"], dstate["arena_cy"]
                                        want_workers = bool(
                                            {UNIT_IDS[u] for u, _, _, _ in (scen.p1_units + scen.p2_units)} & WORKER_IDS
                                        )
                                        p2_wr_f = is_p2_worker_rush_spec(scen)
                                        if dstate["p1_start_cnt"] == 0 and scen.p1_starter_buildings:
                                            for u_sb in obs.raw_data.units:
                                                if u_sb.alliance == 1 and u_sb.tag not in dstate["orig_th_tags"] and u_sb.unit_type in STARTER_BUILDING_UIDS:
                                                    dstate["p1_starter_bldg_tags"].add(u_sb.tag)
                                        p1u = [
                                            u for u in obs.raw_data.units
                                            if u.display_type == 1 and u.alliance == 1
                                            and u.tag not in dstate["orig_th_tags"]
                                            and u.tag not in dstate["p1_starter_bldg_tags"]
                                            and (u.unit_type in COMBAT_IDS or (want_workers and u.unit_type in WORKER_IDS and math.hypot(u.pos.x - cx, u.pos.y - cy) < 35.0))
                                        ]
                                        # Fog-immune P2 unit view from P2's own `sc2_ws2` observation (`alliance == 1`),
                                        # preventing backline SCVs/Medivacs/Tanks/burrowed units from being missed in P1's sight!
                                        p2_obs_fresh = (
                                            dstate["p2_own_units"] is not None
                                            and dstate["p2_own_units_loop"] >= dstate["phase_start_loop"]
                                        )
                                        if p2_obs_fresh:
                                            p2u = list(dstate["p2_own_units"])
                                        else:
                                            p2u = [
                                                u for u in obs.raw_data.units
                                                if u.display_type == 1 and u.alliance == 4
                                                and u.tag not in dstate["orig_th_tags"]
                                                and (
                                                    u.unit_type in COMBAT_IDS
                                                    or (
                                                        want_workers
                                                        and u.unit_type in WORKER_IDS
                                                        and (p2_wr_f or math.hypot(u.pos.x - cx, u.pos.y - cy) < 35.0)
                                                    )
                                                )
                                            ]
                                        exp_p1 = sum(cnt for _, cnt, _, _ in scen.p1_units) + sum(
                                            1 + sum(cc for _, cc in lt["cargo"]) for lt in scen.p1_loaded_transports
                                        )
                                        exp_p2 = sum(cnt for _, cnt, _, _ in scen.p2_units) + sum(
                                            1 + sum(cc for _, cc in lt["cargo"]) for lt in scen.p2_loaded_transports
                                        )
                                        p1_tot_c = units_total_count(p1u)
                                        p2_tot_c = units_total_count(p2u)
                                        if dstate["p1_start_cnt"] == 0 and (p1_tot_c >= exp_p1 and p2_tot_c >= exp_p2 or (gl >= dstate["phase_start_loop"] + 16 and p1u and p2u)):
                                            dstate["fight_start_loop"] = gl
                                            dstate["last_combat_event_loop"] = gl
                                            dstate["p1_fight_start_minerals"] = int(getattr(obs.player_common, "minerals", 0))
                                            dstate["prev_unit_hp_map"] = {
                                                u.tag: float(u.health) + float(u.shield) for u in (p1u + p2u)
                                            }
                                            dstate["p1_start_cnt"] = p1_tot_c
                                            dstate["p2_start_cnt"] = p2_tot_c
                                            dstate["p1_start_types"] = units_type_counts(p1u)
                                            dstate["p2_start_types"] = units_type_counts(p2u)
                                            dstate["p1_start_val"] = units_total_value(p1u)
                                            dstate["p2_start_val"] = units_total_value(p2u)
                                            dstate["p1_bc_start_cnt"] = count_matching_unit_ids(p1u, {57})
                                            dstate["p1_bc_alive_cnt"] = dstate["p1_bc_start_cnt"]
                                            dstate["p2_pf_start_cnt"] = count_matching_unit_ids(p2u, {130})
                                            dstate["p2_pf_alive_cnt"] = dstate["p2_pf_start_cnt"]
                                            dstate["p2_det_start_cnt"] = count_matching_unit_ids(p2u, DETECTOR_IDS)
                                            dstate["p2_det_alive_cnt"] = dstate["p2_det_start_cnt"]
                                            dstate["p2_w_start_cnt"] = count_matching_unit_ids(p2u, WORKER_IDS)
                                            dstate["p2_w_alive_cnt"] = dstate["p2_w_start_cnt"]
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
                                            if scen.scoring_mode == "mineral-defense":
                                                cur_cm = float(getattr(obs.score.score_details, "collected_minerals", 0.0)) if obs.HasField("score") else 0.0
                                                dstate["econ_start_minerals"] = cur_cm
                                                dstate["econ_cur_minerals"] = cur_cm
                                                w_units = [u for u in p1u if u.unit_type in WORKER_IDS]
                                                dstate["econ_start_workers"] = len(w_units)
                                                dstate["econ_seen_worker_tags"] = {u.tag for u in w_units}
                                                dstate["econ_cur_worker_tags"] = {u.tag for u in w_units}
                                                dstate["econ_worker_mining_ticks"] = 0
                                                dstate["econ_worker_total_ticks"] = 0
                                            if scen.use_main_base:
                                                # Only assign idle P1 workers (preserve active 2-per-patch warmup miners!)
                                                w_units_mb = [
                                                    u for u in p1u
                                                    if u.unit_type in WORKER_IDS
                                                    and not any(o.ability_id in MINING_ORDER_ABILITY_IDS for o in u.orders)
                                                ]
                                                mtags = list(dstate["p1_main_mineral_tags"])
                                                if w_units_mb and mtags:
                                                    g_acts = [
                                                        sc2api_pb2.Action(
                                                            action_raw=raw_pb2.ActionRaw(
                                                                unit_command=raw_pb2.ActionRawUnitCommand(
                                                                    ability_id=3666,
                                                                    target_unit_tag=mtags[(i // 2) % len(mtags)],
                                                                    unit_tags=[wu.tag],
                                                                )
                                                            )
                                                        )
                                                        for i, wu in enumerate(w_units_mb)
                                                    ]
                                                    await rpc(sc2_ws, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=g_acts)))
                                            if scen.p1_pre_cloaked:
                                                await _issue_pre_cloak(sc2_ws, obs)
                                            if scen.p2_pre_cloaked:
                                                dstate["p2_pre_cloak_pending"] = True
                                        if dstate["p1_start_cnt"] > 0:
                                            p2_is_dummy = (opp_mode != "self")
                                            dstate["p1_alive_cnt"] = p1_tot_c
                                            dstate["p2_alive_cnt"] = p2_tot_c
                                            dstate["p1_combat_alive_cnt"] = count_combat_capable(p1u, is_dummy=False)
                                            dstate["p2_combat_alive_cnt"] = count_combat_capable(p2u, is_dummy=p2_is_dummy)
                                            dstate["p1_rem_val"] = units_total_value(p1u)
                                            dstate["p2_rem_val"] = units_total_value(p2u)
                                            dstate["p1_bc_alive_cnt"] = count_matching_unit_ids(p1u, {57})
                                            dstate["p2_pf_alive_cnt"] = count_matching_unit_ids(p2u, {130})
                                            dstate["p2_det_alive_cnt"] = count_matching_unit_ids(p2u, DETECTOR_IDS)
                                            dstate["p2_w_alive_cnt"] = count_matching_unit_ids(p2u, WORKER_IDS)

                                            if scen.scoring_mode == "mineral-defense":
                                                if obs.HasField("score"):
                                                    dstate["econ_cur_minerals"] = float(getattr(obs.score.score_details, "collected_minerals", dstate["econ_cur_minerals"]))
                                                cur_ws = [u for u in p1u if u.unit_type in WORKER_IDS]
                                                cur_wtags = {u.tag for u in cur_ws}
                                                dstate["econ_seen_worker_tags"].update(cur_wtags)
                                                dstate["econ_cur_worker_tags"] = cur_wtags
                                                mining_now = sum(
                                                    1 for u in cur_ws
                                                    if any(o.ability_id in MINING_ORDER_ABILITY_IDS for o in u.orders)
                                                    or any(b in CARRYING_MINERAL_BUFF_IDS for b in u.buff_ids)
                                                )
                                                dstate["econ_worker_mining_ticks"] += min(mining_now, max(1, dstate["econ_start_workers"]))
                                                dstate["econ_worker_total_ticks"] += max(1, dstate["econ_start_workers"])

                                            # Track HP/shield damage or unit deaths for smart no-damage stalemate early-stop
                                            cur_hp = {u.tag: float(u.health) + float(u.shield) for u in (p1u + p2u)}
                                            prev_hp = dstate["prev_unit_hp_map"]
                                            dmg_or_death = any(t not in cur_hp for t in prev_hp) or any(
                                                (t in prev_hp and hp < prev_hp[t] - 0.5) for t, hp in cur_hp.items()
                                            )
                                            if dmg_or_death:
                                                dstate["last_combat_event_loop"] = gl
                                            dstate["prev_unit_hp_map"] = cur_hp

                                            fight_elapsed = gl - dstate["fight_start_loop"]
                                            no_dmg_elapsed = gl - dstate["last_combat_event_loop"]
                                            end_reason: str | None = None
                                            ko_side = 0

                                            if scen.scoring_mode == "mineral-defense":
                                                # Run full duration so gathered minerals reflect real mining uptime;
                                                # stop early if all P1 workers/combat are eliminated OR all P2 worker-rush units are wiped!
                                                if not p1u or (len(dstate["econ_cur_worker_tags"]) == 0 and dstate["p1_combat_alive_cnt"] == 0):
                                                    end_reason, ko_side = "ko_eliminated", 2
                                                elif p2_wr_f and not p2u and dstate["p2_start_cnt"] > 0:
                                                    end_reason, ko_side = "worker_rush_wiped", 1
                                                elif fight_elapsed >= scen.max_loops:
                                                    end_reason = "mineral_defense_complete"
                                            elif scen.scoring_mode == "worker-runby":
                                                if dstate["p2_w_alive_cnt"] == 0 and dstate["p2_w_start_cnt"] > 0:
                                                    end_reason, ko_side = "runby_workers_wiped", 1
                                                elif not p1u or dstate["p1_combat_alive_cnt"] == 0:
                                                    end_reason = "runby_raiders_spent"
                                                elif fight_elapsed >= STALEMATE_NO_DAMAGE_LOOPS and no_dmg_elapsed >= STALEMATE_NO_DAMAGE_LOOPS:
                                                    end_reason = "no_damage_stalemate"
                                                elif fight_elapsed >= scen.max_loops:
                                                    end_reason = "runby_complete"
                                            elif not p1u and not p2u:
                                                end_reason = "mutual_eliminated"
                                            elif not p2u:
                                                end_reason, ko_side = "ko_eliminated", 1
                                            elif not p1u:
                                                end_reason, ko_side = "ko_eliminated", 2
                                            elif dstate["p1_combat_alive_cnt"] == 0 and dstate["p2_combat_alive_cnt"] == 0:
                                                end_reason = "mutual_unarmed"
                                            elif dstate["p2_combat_alive_cnt"] == 0 and dstate["p1_combat_alive_cnt"] > 0:
                                                end_reason, ko_side = "ko_unarmed_only", 1
                                            elif dstate["p1_combat_alive_cnt"] == 0 and dstate["p2_combat_alive_cnt"] > 0:
                                                end_reason, ko_side = "ko_unarmed_only", 2
                                            elif fight_elapsed >= 24:
                                                p1_can = side_can_damage_other(p1u, p2u, is_dummy=False)
                                                p2_can = side_can_damage_other(p2u, p1u, is_dummy=p2_is_dummy)
                                                if not p1_can and not p2_can:
                                                    end_reason = "mutual_incapable"
                                                elif p1_can and not p2_can:
                                                    end_reason, ko_side = "ko_incapable_survivors", 1
                                                elif p2_can and not p1_can:
                                                    end_reason, ko_side = "ko_incapable_survivors", 2

                                            if end_reason is None and scen.scoring_mode not in ("mineral-defense", "worker-runby"):
                                                if fight_elapsed >= STALEMATE_NO_DAMAGE_LOOPS and no_dmg_elapsed >= STALEMATE_NO_DAMAGE_LOOPS:
                                                    end_reason = "no_damage_stalemate"
                                                elif fight_elapsed >= scen.max_loops:
                                                    end_reason = "max_loops"

                                            ended_now, sc2_end_reason, sc2_ko_side = extract_sc2_early_game_end(
                                                resp.status,
                                                resp.observation.player_result,
                                                sc2api_pb2.ended,
                                            )
                                            if ended_now:
                                                dstate["sc2_ended_reason"] = sc2_end_reason
                                                dstate["sc2_ended_ko_side"] = sc2_ko_side
                                                if end_reason is None:
                                                    end_reason = sc2_end_reason
                                                    ko_side = sc2_ko_side

                                            if end_reason is not None:
                                                finalize_current_round(gl, end_reason=end_reason, ko_winner_side=ko_side)
                                                dstate["scen_idx"] += 1
                                                if ended_now or dstate["scen_idx"] >= len(scenarios):
                                                    dstate["phase"] = "done"
                                                    dstate["done"].set()
                                                else:
                                                    kill_tags = [
                                                        u.tag for u in obs.raw_data.units
                                                        if u.alliance in (1, 4) and u.tag not in dstate["orig_th_tags"]
                                                    ]
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
                        except Exception as exc:
                            dstate["errors"].append(f"p1_ws: {type(exc).__name__}: {exc}")
                        finally:
                            _ensure_active_round_finalized("early_match_end")
                            dstate["done"].set()
                        return bot_ws

                    app1 = web.Application()
                    app1.router.add_get("/sc2api", duel_ws_handler)
                    runner1 = web.AppRunner(app1)
                    await runner1.setup()
                    site1 = web.TCPSite(runner1, "127.0.0.1", PROXY_PORT_1)
                    await site1.start()

                    runner2: web.AppRunner | None = None
                    p2_task: asyncio.Task[Any] | None = None
                    bot_proc2: subprocess.Popen[bytes] | None = None
                    bot_log2 = None

                    if opp_mode == "self":
                        app2 = web.Application()
                        app2.router.add_get("/sc2api", duel_ws_handler_p2)
                        runner2 = web.AppRunner(app2)
                        await runner2.setup()
                        site2 = web.TCPSite(runner2, "127.0.0.1", PROXY_PORT_2)
                        await site2.start()
                        bot_cmd2 = [
                            "/usr/local/bin/racket", "-U", "-X", "/usr/share/racket/collects",
                            "-G", "/etc/racket-portable",
                            "/mothman-repo/sim/racket-sc2-ladder-main.rkt",
                            "--BotName", bname2,
                            "--GamePort", str(PROXY_PORT_2),
                            "--LadderServer", "127.0.0.1",
                            "--StartPort", "8190",
                            "--OpponentId", bname1,
                        ]
                        assert bot_dir2 is not None
                        bot_log2 = (bot_dir2 / "bot.log").open("wb")
                        bot_proc2 = subprocess.Popen(bot_cmd2, cwd=str(bot_dir2), stdout=bot_log2, stderr=subprocess.STDOUT)
                    else:
                        p2_task = asyncio.create_task(p2_aggressive_micro_loop())

                    bot_cmd1 = [
                        "/usr/local/bin/racket", "-U", "-X", "/usr/share/racket/collects",
                        "-G", "/etc/racket-portable",
                        "/mothman-repo/sim/racket-sc2-ladder-main.rkt",
                        "--BotName", bname1,
                        "--GamePort", str(PROXY_PORT_1),
                        "--LadderServer", "127.0.0.1",
                        "--StartPort", "8090",
                        "--OpponentId", p2_label,
                    ]
                    bot_log1 = (bot_dir1 / "bot.log").open("wb")
                    bot_proc1 = subprocess.Popen(bot_cmd1, cwd=str(bot_dir1), stdout=bot_log1, stderr=subprocess.STDOUT)
                    async def _watch_done_or_crash() -> None:
                        wall_budget = max(240.0, 35.0 * max(1, len(scenarios)))
                        deadline = time.monotonic() + wall_budget
                        while not dstate["done"].is_set():
                            if time.monotonic() >= deadline:
                                raise TimeoutError(f"Arena duel exceeded {wall_budget:.0f}s wall timeout ({len(scenarios)} scenarios)")
                            if bot_proc1.poll() is not None and not dstate["done"].is_set():
                                if not (bot_proc1.returncode == 0 and dstate.get("sc2_ended_reason")):
                                    dstate["errors"].append(f"bot_proc1 exited prematurely rc={bot_proc1.returncode}")
                                dstate["done"].set()
                                return
                            if bot_proc2 is not None and bot_proc2.poll() is not None and not dstate["done"].is_set():
                                if not (bot_proc2.returncode == 0 and dstate.get("sc2_ended_reason")):
                                    dstate["errors"].append(f"bot_proc2 exited prematurely rc={bot_proc2.returncode}")
                                dstate["done"].set()
                                return
                            if p2_task is not None and p2_task.done() and not dstate["done"].is_set():
                                exc = p2_task.exception() if not p2_task.cancelled() else None
                                dstate["errors"].append(f"p2_task stopped early: {exc!r}")
                                dstate["done"].set()
                                return
                            try:
                                await asyncio.wait_for(dstate["done"].wait(), timeout=0.25)
                            except asyncio.TimeoutError:
                                pass

                    try:
                        await _watch_done_or_crash()
                    finally:
                        dstate["done"].set()
                        if p2_task is not None:
                            p2_task.cancel()
                        for bp in (bot_proc1, bot_proc2):
                            if bp is not None:
                                bp.terminate()
                                try:
                                    bp.wait(timeout=3.0)
                                except Exception:
                                    bp.kill()
                        bot_log1.close()
                        if bot_log2 is not None:
                            bot_log2.close()
                        await runner1.cleanup()
                        if runner2 is not None:
                            await runner2.cleanup()
                        if p2_task is not None:
                            try:
                                await p2_task
                            except (asyncio.CancelledError, Exception):
                                pass

                    _ensure_active_round_finalized("early_match_end")
                    replay_bytes = 0
                    if getattr(args, "save_replay_path", ""):
                        save_resp = await rpc(
                            sc2_ws,
                            sc2api_pb2.Request(save_replay=sc2api_pb2.RequestSaveReplay()),
                            timeout=30.0,
                        )
                        if not (save_resp.HasField("save_replay") and save_resp.save_replay.data):
                            raise RuntimeError(f"RequestSaveReplay returned empty data for race={our_race}")
                        rp = Path(args.save_replay_path)
                        rp.parent.mkdir(parents=True, exist_ok=True)
                        rp.write_bytes(save_resp.save_replay.data)
                        replay_bytes = len(save_resp.save_replay.data)

                    res = dstate["results"]
                    win_tag = "Mothman-P1" if opp_mode == "self" else "Mothman"
                    wins = sum(1 for s in res if s["winner"] == win_tag)
                    tot_p1 = sum(s["p1_lost_val"] for s in res)
                    tot_p2 = sum(s["p2_lost_val"] for s in res)
                    report: dict[str, Any] = {
                        "mode": "duel",
                        "opponent_mode": opp_mode,
                        "engine": "SC2_x64_Base75689",
                        "bot": bname1,
                        "p2_bot": p2_label,
                        "race": our_race,
                        "enemy_race": enemy_race if opp_mode == "self" else "mixed",
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
                    if dstate["errors"] or not res:
                        report["debug_phase"] = dstate["phase"]
                        report["debug_errors"] = dstate["errors"]
                        try:
                            report["bot1_log_tail"] = (bot_dir1 / "bot.log").read_text(encoding="utf-8", errors="ignore")[-1200:]
                        except Exception:
                            pass
                        if bot_dir2 is not None:
                            try:
                                report["bot2_log_tail"] = (bot_dir2 / "bot.log").read_text(encoding="utf-8", errors="ignore")[-1200:]
                            except Exception:
                                pass
                    if getattr(args, "save_replay_path", ""):
                        report["replay_path"] = args.save_replay_path
                        report["replay_bytes"] = replay_bytes
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
            an = MapTerrainAnalyzer(gi_resp.game_info)
            arena_cx, arena_cy = an.sites["open"].cx, an.sites["open"].cy

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
                    sx, sy = an.resolve_spawn_point(scen, uname, dx, dy)
                    dbg_cmds.append(debug_pb2.DebugCommand(
                        create_unit=debug_pb2.DebugCreateUnit(unit_type=UNIT_IDS[uname], owner=1, pos=common_pb2.Point2D(x=sx, y=sy), quantity=cnt)
                    ))
                for uname, cnt, dx, dy in scen.p2_units:
                    sx, sy = an.resolve_spawn_point(scen, uname, dx, dy)
                    dbg_cmds.append(debug_pb2.DebugCommand(
                        create_unit=debug_pb2.DebugCreateUnit(unit_type=UNIT_IDS[uname], owner=2, pos=common_pb2.Point2D(x=sx, y=sy), quantity=cnt)
                    ))
                await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg_cmds)))
                await rpc(sc2_ws, sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=2)))

                obs0 = (await rpc(sc2_ws, sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation()))).observation.observation
                site = an.sites.get(scen.terrain) or an.sites["open"]
                p1_start = [u for u in obs0.raw_data.units if u.alliance == 1 and u.unit_type not in TOWNHALL_IDS and math.hypot(u.pos.x - site.cx, u.pos.y - site.cy) < 35.0]
                p2_start = [u for u in obs0.raw_data.units if u.alliance == 4 and u.unit_type not in TOWNHALL_IDS and math.hypot(u.pos.x - site.cx, u.pos.y - site.cy) < 35.0]
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
                    p1_alive = [u for u in obs_now.raw_data.units if u.alliance == 1 and u.unit_type not in TOWNHALL_IDS and math.hypot(u.pos.x - site.cx, u.pos.y - site.cy) < 38.0]
                    p2_alive = [u for u in obs_now.raw_data.units if u.alliance == 4 and u.unit_type not in TOWNHALL_IDS and math.hypot(u.pos.x - site.cx, u.pos.y - site.cy) < 38.0]
                    for u in p1_alive:
                        if u.weapon_cooldown > 0.0:
                            observed_wcd.append(round(float(u.weapon_cooldown), 3))
                results.append({
                    "id": scen.id,
                    "terrain": scen.terrain,
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
    parser = argparse.ArgumentParser(description="Real-SC2_x64 RequestDebug Micro Skirmish Arena 3.0")
    parser.add_argument("--in-container", action="store_true")
    parser.add_argument("--list", action="store_true", help="List matching scenarios & category/tier/race counts and exit")
    parser.add_argument("--validate", action="store_true", help="Validate entire scenario catalog (IDs, units, upgrades, transports, categories) and exit")
    parser.add_argument("--mode", choices=["probe", "duel"], default="duel")
    parser.add_argument("--opponent", choices=["dummy", "self"], default="dummy", help="P2 opponent: dummy (MicroDummy, default) or self (live Mothman-vs-Mothman)")
    parser.add_argument("--suite", choices=["core", "all", ""], default="", help="Scenario suite: core (~65 flagships across all categories, default for unfiltered runs) or all (all 200+ scenarios)")
    parser.add_argument("--category", default="", help=f"Optional comma-separated filter on scenario category ({', '.join(VALID_CATEGORIES)})")
    parser.add_argument("--race", default="all", help="Protoss | Terran | Zerg | all")
    parser.add_argument("--enemy-race", default="", help="Optional filter on scenario enemy_race")
    parser.add_argument("--scenarios", default="", help="Optional path to arena scenarios JSON catalog (defaults to tools/arena-scenarios.json)")
    parser.add_argument("--scenario", default="", help="Optional case-insensitive substring filter on scenario ID (e.g. 'p04' or 'burrow')")
    parser.add_argument("--terrain", default="", help="Optional filter on scenario terrain (open | high-ground-ramp | flank-surround | cliff-air-chasm | mineral-line-harass)")
    parser.add_argument("--source", default="", help="Optional filter on scenario source (core | match-forensics | pro-db | pattern-coverage | replay-extract | custom)")
    parser.add_argument("--tier", choices=["canonical", "regression", "econ-harass", "all"], default="all", help="Optional filter on scenario tier (canonical | regression | econ-harass | all)")
    parser.add_argument("--workers", type=int, default=3, help="Max parallel containers / 3D render workers (default: 3)")
    parser.add_argument("--map", default=DEFAULT_MAP)
    parser.add_argument("--step-size", type=int, default=4)
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--repo-dir", default=str(DEFAULT_REPO_DIR))
    parser.add_argument("--maps-dir", default=str(DEFAULT_MAPS_DIR))
    parser.add_argument("--arena-dir", default=str(DEFAULT_ARENA_DIR))
    parser.add_argument("--out", "--json-out", dest="out", default="", help="Output JSON report path")
    parser.add_argument("--compare", default="", help="Optional baseline JSON path to emit A/B delta comparison")
    parser.add_argument("--render-dir", default="", help="Optional output directory to render real-3D SC2_x64 full-length MP4/WebP clips + Peak PNGs for all duels")
    parser.add_argument("--save-replays-dir", default="", help="Optional host directory to save raw .SC2Replay files from duels")
    parser.add_argument("--render-step", type=int, default=2, help="SC2 game loops per rendered 3D frame (default: 2)")
    parser.add_argument("--render-fps", type=int, default=16, help="Output 3D video FPS (default: 16)")
    parser.add_argument("--video-format", choices=["mp4", "webp"], default=DEFAULT_VIDEO_FORMAT, help="Output 3D video container/codec: mp4 (default H.264) or webp")
    parser.add_argument("--max-render-frames", type=int, default=DEFAULT_MAX_RENDER_FRAMES, help="Max rendered 3D frames per duel (default: 480 = full 960 loops @ step=2)")
    parser.add_argument("--scenario-ids", default="", help=argparse.SUPPRESS)
    parser.add_argument("--save-replay-path", default="", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.in_container:
        return asyncio.run(run_in_container(args))
    return run_host_driver(args)


if __name__ == "__main__":
    raise SystemExit(main())
