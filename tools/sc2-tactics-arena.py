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

# Canonical SC2 UnitTypeIds (Blizzard 4.10 — synced with add-arena-scenario skill)
UNIT_IDS: dict[str, int] = {
    # Terran (21)
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
    # Protoss (18)
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
    # Zerg (27 — incl. burrowed variants for burrow micro / ambushes)
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
    "drone": 104,
    "drone-burrowed": 116,
}

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
    104: 50.0,    # drone
    116: 50.0,    # drone-burrowed
}

DEFAULT_MAX_LOOPS = 960          # ~42.9s real Faster SC2 combat
STALEMATE_NO_DAMAGE_LOOPS = 168  # 7.5s with zero HP/shield damage or unit deaths -> stalemate stop
POINTS_WIN_TRADE = 1.25          # trade >= 1.25x on timeout/stalemate -> Points Win
POINTS_LOSS_TRADE = 0.80         # trade <= 0.80x on timeout/stalemate -> Points Loss

TOWNHALL_IDS = {18, 59, 86, 100, 101, 130, 132}
WORKER_IDS = {45, 84, 104, 116}
COMBAT_IDS = set(UNIT_VALUES) - WORKER_IDS
AIR_UNIT_IDS = {
    54, 35, 55, 56, 689, 734, 57,  # Terran air
    78, 495, 80, 79, 496, 82, 81,  # Protoss air
    108, 112, 499, 114, 129,       # Zerg air
}
MINERAL_IDS = {146, 147, 341, 483, 665, 666, 796, 797, 884, 885}

# Exact SC2 4.10 weapon/combat capability tables for unarmed/incapable-survivor termination
PURE_UNARMED_IDS = {54, 82, 81, 129}  # medivac, observer, warp-prism, overseer
# Energy-gated spellcasters with no standard auto-attack: uid -> (min_energy, can_hit_ground, can_hit_air)
ENERGY_CASTER_CAPS: dict[int, tuple[float, bool, bool]] = {
    56: (50.0, True, True),     # raven (Auto-Turret 50e -> G+A)
    111: (75.0, True, True),    # infestor (Fungal Growth 75e -> G+A)
    127: (75.0, True, True),    # infestor-burrowed
    499: (125.0, False, True),  # viper alone (Parasitic Bomb 125e -> Air; Abduct deals 0 dmg alone)
    495: (15.0, True, False),   # oracle (Pulsar Beam -> Ground only)
}
GROUND_ONLY_WEAPON_IDS = {
    51, 33, 32, 53, 484, 49, 55, 45,                     # Terran G-only
    73, 311, 83, 4, 694, 76, 84,                         # Protoss G-only
    105, 119, 9, 115, 110, 118, 109, 131, 114, 502, 503, 494, 493, 104, 116,  # Zerg G-only
}
AIR_ONLY_WEAPON_IDS = {112}  # corruptor (Caustic Spray targets structures only)
BOTH_WEAPON_IDS = {
    48, 50, 52, 498, 500, 692, 57,                       # Terran G+A
    74, 77, 141, 80, 79, 496,                            # Protoss G+A
    688, 690, 107, 117, 108, 126, 125,                   # Zerg G+A
}
MASSIVE_GROUND_IDS = {52, 4, 141, 109, 131}  # thor, colossus, archon, ultralisk (immune to Graviton Beam)


def unit_attack_caps(u: Any, allies: list[Any], is_dummy: bool = False) -> tuple[bool, bool]:
    """Return (can_hit_ground, can_hit_air) for SC2 unit `u` given its current energy & allies."""
    uid = int(u.unit_type)
    if uid in PURE_UNARMED_IDS:
        return (False, False)
    if uid in ENERGY_CASTER_CAPS:
        min_e, cg, ca = ENERGY_CASTER_CAPS[uid]
        if float(getattr(u, "energy", 0.0)) >= min_e:
            return (cg, ca)
        return (False, False)
    if uid == 75:  # high-templar: PsiBlast hits Ground; PsiStorm (75e) hits Ground+Air
        return (True, float(getattr(u, "energy", 0.0)) >= 75.0)
    if uid == 78:  # phoenix: Air weapon; Graviton Beam lifts non-massive Ground if >=2 Phoenixes & >=50e
        can_lift = (
            sum(1 for a in allies if int(a.unit_type) == 78) >= 2
            and float(getattr(u, "energy", 0.0)) >= 50.0
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
    "NeuralParasite": ("Zerg", 94, 1455, False, None, 101),
    # Protoss
    "Blink": ("Protoss", 65, 1593, True, None, None),
    "Charge": ("Protoss", 65, 1592, True, None, None),
    "ResonatingGlaives": ("Protoss", 65, 1594, True, None, None),
    "ThermalLance": ("Protoss", 70, 1097, True, None, None),
    "PsiStorm": ("Protoss", 68, 1126, True, None, None),
    # Terran (TechLab addons built in-place on parent Barracks/Factory/Starport via 421/454/487)
    "Stim": ("Terran", 37, 730, False, (21, 421), None),
    "CombatShield": ("Terran", 37, 731, False, (21, 421), None),
    "ConcussiveShells": ("Terran", 37, 732, False, (21, 421), None),
    "DrillingClaws": ("Terran", 39, 764, False, (27, 454), 29),
    "SmartServos": ("Terran", 39, 766, False, (27, 454), 29),
    "InfernalPreigniter": ("Terran", 39, 761, False, (27, 454), None),
    "BansheeCloak": ("Terran", 41, 790, False, (28, 487), None),
    "AdvancedBallistics": ("Terran", 41, 805, False, (28, 487), 30),
    "PersonalCloaking": ("Terran", 26, 820, False, None, None),
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
    "neuralparasite": ["NeuralParasite"],
    "blink": ["Blink"],
    "charge": ["Charge"],
    "resonatingglaives": ["ResonatingGlaives"],
    "thermallance": ["ThermalLance"],
    "thermal-lance": ["ThermalLance"],
    "extendedthermallance": ["ThermalLance"],
    "psistorm": ["PsiStorm"],
    "psi-storm": ["PsiStorm"],
    "stim": ["Stim"],
    "stimpack": ["Stim"],
    "combatshield": ["CombatShield"],
    "combat-shield": ["CombatShield"],
    "concussiveshells": ["ConcussiveShells"],
    "drillingclaws": ["DrillingClaws"],
    "drilling-claws": ["DrillingClaws"],
    "smartservos": ["SmartServos"],
    "infernalpreigniter": ["InfernalPreigniter"],
    "bansheecloak": ["BansheeCloak"],
    "banshee-cloak": ["BansheeCloak"],
    "personalcloaking": ["PersonalCloaking"],
    "personal-cloaking": ["PersonalCloaking"],
    "advancedballistics": ["AdvancedBallistics"],
    "cloak": ["BansheeCloak", "PersonalCloaking"],
}


def normalize_upgrades(raw_list: list[str] | None) -> list[str]:
    out: list[str] = []
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
            if item not in out:
                out.append(item)
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
    patterns: list[str] = field(default_factory=list)
    p1_upgrades: list[str] = field(default_factory=list)
    p2_upgrades: list[str] = field(default_factory=list)
    p1_pre_burrowed: list[str] = field(default_factory=list)
    p2_pre_burrowed: list[str] = field(default_factory=list)
    p1_pre_cloaked: bool = False
    p2_pre_cloaked: bool = False
    pre_sieged: bool = False


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
        terrain = str(sc.get("terrain", "open"))
        if terrain not in VALID_TERRAINS:
            raise ValueError(f"Scenario {sid!r} has invalid terrain {terrain!r} (valid: {VALID_TERRAINS})")
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
        specs.append(SkirmishSpec(
            id=sid,
            our_race=our_race,
            enemy_race=enemy_race,
            description=str(sc.get("description", sid)),
            p1_units=_parse_unit_entries(sc["p1_units"], sid, "p1_units", p1_pre_b, pre_s),
            p2_units=_parse_unit_entries(sc["p2_units"], sid, "p2_units", p2_pre_b, pre_s),
            max_loops=int(sc.get("max_loops", DEFAULT_MAX_LOOPS)),
            terrain=terrain,
            high_ground_side=str(sc.get("high_ground_side", "p1")),
            source=str(sc.get("source", "core")),
            patterns=[str(p) for p in (sc.get("patterns") or [])],
            p1_upgrades=p1_upgs,
            p2_upgrades=p2_upgs,
            p1_pre_burrowed=p1_pre_b,
            p2_pre_burrowed=p2_pre_b,
            p1_pre_cloaked=bool(sc.get("p1_pre_cloaked", False)),
            p2_pre_cloaked=bool(sc.get("p2_pre_cloaked", False)),
            pre_sieged=pre_s,
        ))
    return specs


def filter_scenarios(
    scenarios: list[SkirmishSpec],
    race: str,
    scenario_filter: str = "",
    enemy_race: str = "",
    terrain_filter: str = "",
    source_filter: str = "",
) -> list[SkirmishSpec]:
    """Filter scenarios by our_race, enemy_race, terrain, source, and substring on id."""
    out = (
        list(scenarios)
        if race.lower() == "all"
        else [s for s in scenarios if s.our_race.lower() == race.lower()]
    )
    if enemy_race and enemy_race.lower() != "all":
        out = [s for s in out if s.enemy_race.lower() == enemy_race.lower()]
    if terrain_filter:
        tf = terrain_filter.lower()
        out = [s for s in out if s.terrain.lower() == tf]
    if source_filter:
        sf = source_filter.lower()
        out = [s for s in out if s.source.lower() == sf]
    if scenario_filter:
        needle = scenario_filter.lower()
        out = [s for s in out if needle in s.id.lower()]
    if not out:
        raise ValueError(
            f"No scenarios matched race={race!r} enemy_race={enemy_race!r} "
            f"terrain={terrain_filter!r} source={source_filter!r} scenario={scenario_filter!r}"
        )
    return out


def partition_duel_batches(
    matched_specs: list[SkirmishSpec],
) -> list[tuple[str, str, int, list[SkirmishSpec]]]:
    """Partition scenarios by (our_race, enemy_race) into minimal monotonic upgrade chains.

    Because SC2 upgrades persist for the entire match, every batch guarantees
    p1_upgrades(s_i) <= p1_upgrades(s_{i+1}) and p2_upgrades(s_i) <= p2_upgrades(s_{i+1}),
    ensuring 100% exact per-scenario upgrades with zero cross-duel leakage.
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
            key=lambda it: (len(it[1].p1_upgrades) + len(it[1].p2_upgrades), it[0]),
        )
        chains: list[list[SkirmishSpec]] = []
        for _orig_idx, s in items:
            s_p1 = set(s.p1_upgrades)
            s_p2 = set(s.p2_upgrades)
            best_ci: int | None = None
            best_len = -1
            for ci, ch in enumerate(chains):
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
        for b_idx, ch in enumerate(chains):
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
        pts_w = sum(1 for s in w_rows if s.get("win_type") == "points")
        ko_l = sum(1 for s in l_rows if s.get("win_type", "ko") == "ko")
        pts_l = sum(1 for s in l_rows if s.get("win_type") == "points")
        w, l, d = len(w_rows), len(l_rows), len(d_rows)
        return {
            "mothman_wins": w,
            "ko_wins": ko_w,
            "points_wins": pts_w,
            "p2_wins": l,
            "ko_losses": ko_l,
            "points_losses": pts_l,
            "draws": d,
            "timeouts": d,  # backward-compatible alias
            "record_str": f"{w}W-{l}L-{d}D (KO {ko_w}/Pts {pts_w} - KO {ko_l}/Pts {pts_l} - {d}D)",
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
        "by_race": by_race,
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


def run_host_driver(args: argparse.Namespace) -> int:
    t0 = time.monotonic()
    repo_dir = Path(args.repo_dir).resolve()
    opp_mode = getattr(args, "opponent", "dummy")
    all_specs = load_scenarios(getattr(args, "scenarios", ""), repo_dir)
    matched_specs = filter_scenarios(
        all_specs,
        args.race,
        getattr(args, "scenario", ""),
        getattr(args, "enemy_race", ""),
        getattr(args, "terrain", ""),
        getattr(args, "source", ""),
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
                race_reports_for_render.append({
                    "race": btag,
                    "bot": f"Mothman-{r1[0]} vs Mothman-{r2[0]}" if opp_mode == "self" else f"Mothman-{r1[0]}",
                    "map_path": map_host_path,
                    "replay_path": sr["replay_path"],
                    "duels": sr.get("scenarios", []),
                })

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
        render_res = renderer.render_arena_replays_parallel(
            race_specs=race_reports_for_render,
            out_dir=render_dir,
            step=args.render_step,
            fps=args.render_fps,
            render_size=(960, 720),
            minimap_size=(180, 180),
            webp_size=(800, 600),
            workers=min(max_workers, len(race_reports_for_render)),
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
            f"[ARENA 2.0 {opp_mode}] {rsum['record_str']} | Trade={rsum.get('agg_trade_ratio')}x | "
            f"A:M={rsum.get('am_ratio')} | wall={report.get('total_wall_ms')}ms",
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
    ) -> list[tuple[float, float]]:
        """Find `count` clean buildable 3x3 (or 5x3 with Terran addon) building centers near anchor."""
        chosen: list[tuple[float, float]] = []
        avoid_pts = list(avoid or [])
        ax, ay = int(round(anchor_x)), int(round(anchor_y))
        x_hi = 4 if with_addon else 2

        def _ok(cx: int, cy: int) -> bool:
            if any(math.hypot(cx - ox, cy - oy) < 5.5 for ox, oy in avoid_pts):
                return False
            if any(math.hypot(cx - ox, cy - oy) < min_spacing for ox, oy in chosen):
                return False
            for dx in range(-1, x_hi):
                for dy in range(-1, 2):
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

    def _find_open_site(self, rx: int, ry: int, fallback: ArenaSite | None = None) -> ArenaSite:
        cx0, cy0 = self.w // 2, self.h // 2
        for rad in range(0, 50, 2):
            for dx in range(-rad, rad + 1, 2):
                for dy in (-rad, rad) if abs(dx) < rad else range(-rad, rad + 1, 2):
                    tx, ty = cx0 + dx, cy0 + dy
                    if all(
                        self.is_pathable(tx + ox, ty + oy, margin=14)
                        for ox in range(-rx, rx + 1, 2)
                        for oy in range(-ry, ry + 1, 2)
                    ):
                        return ArenaSite(terrain="open" if rx <= 8 else "flank-surround", cx=float(tx), cy=float(ty))
        return fallback or ArenaSite(terrain="open", cx=float(cx0), cy=float(cy0))

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
        """Find an unoccupied expansion mineral line directly from SC2 mineral field units."""
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

    def resolve_spawn_point(
        self,
        scen: SkirmishSpec,
        unit_name: str,
        dx: float,
        dy: float,
    ) -> tuple[float, float]:
        site = self.sites.get(scen.terrain) or self.sites["open"]
        if scen.terrain == "open":
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
        scenarios = filter_scenarios(
            all_specs,
            args.race,
            getattr(args, "scenario", ""),
            getattr(args, "enemy_race", ""),
            getattr(args, "terrain", ""),
            getattr(args, "source", ""),
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
                        "orig_th_positions": [],
                        "mineral_refined": False,
                        "scen_idx": 0,
                        # wait_init -> clearing -> upgrade_spawn -> upgrade_issue -> upgrade_wait -> spawning -> fighting -> done
                        "phase": "wait_init",
                        "phase_start_loop": 0,
                        "p2_clear_ok": False,
                        "cheats_enabled_p1": False,
                        "cheats_enabled_p2": False,
                        "p1_done_upgrades": set(),
                        "p2_done_upgrades": set(),
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
                        an: MapTerrainAnalyzer | None = dstate["analyzer"]
                        if an is None:
                            return ArenaSite(terrain="open", cx=88.0, cy=88.0)
                        return an.sites.get(scen.terrain) or an.sites["open"]

                    async def _issue_owner_upgrades(
                        ws: aiohttp.ClientWebSocketResponse,
                        obs: Any,
                        pending: list[tuple[str, int, int, float, float]],
                    ) -> bool:
                        if not pending:
                            return True
                        acts: list[Any] = []
                        used_tags: set[int] = set()
                        for _uname, bldg_uid, ab_id, bx, by in pending:
                            cands = [
                                u for u in obs.raw_data.units
                                if u.alliance == 1 and u.unit_type == bldg_uid
                                and u.tag not in used_tags and u.build_progress >= 0.99
                            ]
                            if not cands:
                                continue
                            bldg = min(cands, key=lambda u: math.hypot(u.pos.x - bx, u.pos.y - by))
                            used_tags.add(bldg.tag)
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
                            bad = [r for r in aresp.action.result if r != 1]
                            if bad:
                                dstate["errors"].append(f"upgrade_action_results={bad} pending={[(u, b, a) for u, b, a, _, _ in pending]}")
                            return True
                        return False

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
                        elif phase == "upgrade_addons":
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
                                    if acts_a:
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
                        elif phase == "upgrade_issue" and not dstate["p2_upg_issued"]:
                            if not dstate["p2_pending_upgrades"]:
                                dstate["p2_upg_issued"] = True
                            else:
                                ok = await _issue_owner_upgrades(sc2_ws2, obs, dstate["p2_pending_upgrades"])
                                if ok:
                                    dstate["p2_upg_issued"] = True
                        elif phase == "upgrade_wait":
                            p2_uids = {b for _, b, _, _, _ in dstate["p2_pending_upgrades"]}
                            dstate["p2_upg_busy"] = any(
                                u.alliance == 1 and u.unit_type in p2_uids and len(u.orders) > 0
                                for u in obs.raw_data.units
                            )
                        elif phase == "fighting" and dstate["p2_pre_cloak_pending"]:
                            await _issue_pre_cloak(sc2_ws2, obs)
                            dstate["p2_pre_cloak_pending"] = False

                    async def p2_aggressive_micro_loop() -> None:
                        await dstate["p1_joined"].wait()
                        await rpc(sc2_ws2, make_mp_join(RACE_ENUM.get(enemy_race, common_pb2.Terran), "MicroDummy"))
                        step_n = max(1, args.step_size)
                        while not dstate["done"].is_set():
                            obs_r = await rpc(sc2_ws2, sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation()))
                            obs = obs_r.observation.observation
                            await _p2_housekeeping(obs)
                            if dstate["phase"] == "fighting":
                                scen_p2 = scenarios[min(dstate["scen_idx"], len(scenarios) - 1)]
                                want_workers_p2 = bool(
                                    {UNIT_IDS[u] for u, _, _, _ in (scen_p2.p1_units + scen_p2.p2_units)} & WORKER_IDS
                                )
                                cx_a, cy_a = dstate["arena_cx"], dstate["arena_cy"]
                                my_u = [
                                    u for u in obs.raw_data.units
                                    if u.display_type == 1 and u.alliance == 1
                                    and u.unit_type not in PURE_UNARMED_IDS
                                    and (u.unit_type in COMBAT_IDS or (want_workers_p2 and u.unit_type in WORKER_IDS and math.hypot(u.pos.x - cx_a, u.pos.y - cy_a) < 35.0))
                                ]
                                # Ignore undetected cloaked/burrowed units (CloakState.Cloaked == 1) so MicroDummy doesn't freeze!
                                en_u = [
                                    u for u in obs.raw_data.units
                                    if u.display_type == 1 and u.alliance == 4 and u.cloak != 1
                                    and (u.unit_type in COMBAT_IDS or (want_workers_p2 and u.unit_type in WORKER_IDS and math.hypot(u.pos.x - cx_a, u.pos.y - cy_a) < 35.0))
                                ]
                                en_armed = [u for u in en_u if u.unit_type not in PURE_UNARMED_IDS]
                                en_targets = en_armed if en_armed else en_u
                                if my_u and en_targets:
                                    cx_my = sum(u.pos.x for u in my_u) / len(my_u)
                                    cy_my = sum(u.pos.y for u in my_u) / len(my_u)
                                    en_gnd = [e for e in en_targets if not (bool(getattr(e, "is_flying", False)) or e.unit_type in AIR_UNIT_IDS)]
                                    en_air = [e for e in en_targets if bool(getattr(e, "is_flying", False)) or e.unit_type in AIR_UNIT_IDS]
                                    acts_p2: list[Any] = []
                                    g_only_tags = [u.tag for u in my_u if unit_attack_caps(u, my_u, is_dummy=True) == (True, False)]
                                    a_only_tags = [u.tag for u in my_u if unit_attack_caps(u, my_u, is_dummy=True) == (False, True)]
                                    both_tags = [u.tag for u in my_u if u.tag not in set(g_only_tags) and u.tag not in set(a_only_tags)]
                                    if both_tags:
                                        tgt = min(en_targets, key=lambda e: (math.hypot(e.pos.x - cx_my, e.pos.y - cy_my), e.health + e.shield))
                                        acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt.tag, unit_tags=both_tags))))
                                    if g_only_tags and en_gnd:
                                        tgt_g = min(en_gnd, key=lambda e: (math.hypot(e.pos.x - cx_my, e.pos.y - cy_my), e.health + e.shield))
                                        acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt_g.tag, unit_tags=g_only_tags))))
                                    if a_only_tags and en_air:
                                        tgt_a = min(en_air, key=lambda e: (math.hypot(e.pos.x - cx_my, e.pos.y - cy_my), e.health + e.shield))
                                        acts_p2.append(sc2api_pb2.Action(action_raw=raw_pb2.ActionRaw(unit_command=raw_pb2.ActionRawUnitCommand(ability_id=23, target_unit_tag=tgt_a.tag, unit_tags=a_only_tags))))
                                    if acts_p2:
                                        await rpc(sc2_ws2, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=acts_p2)))
                                elif my_u:
                                    # Attack-move toward arena center if all remaining enemies are burrowed/cloaked
                                    act = sc2api_pb2.Action(
                                        action_raw=raw_pb2.ActionRaw(
                                            unit_command=raw_pb2.ActionRawUnitCommand(
                                                ability_id=23,
                                                target_world_space_pos=common_pb2.Point2D(x=cx_a, y=cy_a),
                                                unit_tags=[u.tag for u in my_u],
                                            )
                                        )
                                    )
                                    await rpc(sc2_ws2, sc2api_pb2.Request(action=sc2api_pb2.RequestAction(actions=[act])))
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
                                    await _p2_housekeeping(resp.observation.observation)

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
                        scen = scenarios[dstate["scen_idx"]]
                        p1_lost = max(0.0, dstate["p1_start_val"] - dstate["p1_rem_val"])
                        p2_lost = max(0.0, dstate["p2_start_val"] - dstate["p2_rem_val"])
                        trade = round(p2_lost / max(1.0, p1_lost), 2) if p1_lost > 0 else (99.0 if p2_lost > 0 else 1.0)
                        p2_trade = round(p1_lost / max(1.0, p2_lost), 2) if p2_lost > 0 else (99.0 if p1_lost > 0 else 1.0)
                        p1_tag = "Mothman-P1" if opp_mode == "self" else "Mothman"
                        p2_tag = "Mothman-P2" if opp_mode == "self" else "MicroDummy"
                        if ko_winner_side == 1:
                            winner = p1_tag
                            win_type = "ko"
                        elif ko_winner_side == 2:
                            winner = p2_tag
                            win_type = "ko"
                        elif trade >= POINTS_WIN_TRADE:
                            winner = p1_tag
                            win_type = "points"
                        elif trade <= POINTS_LOSS_TRADE:
                            winner = p2_tag
                            win_type = "points"
                        else:
                            winner = "Draw"
                            win_type = "draw"
                        start_loop = int(dstate.get("fight_start_loop") or dstate["phase_start_loop"])
                        p1_lbl = ", ".join(f"{c} {u}" for u, c, _, _ in scen.p1_units)
                        p2_lbl = ", ".join(f"{c} {u}" for u, c, _, _ in scen.p2_units)
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
                            f"ATK={dstate['attack_cmds']}, MOV={dstate['move_cmds']}, Spells={dstate['spell_cmds']}{p2_ctx_extra})."
                        )
                        rec: dict[str, Any] = {
                            "id": scen.id,
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
                        if opp_mode == "self":
                            rec["p2_attack_unit_cmds"] = dstate["p2_attack_cmds"]
                            rec["p2_move_unit_cmds"] = dstate["p2_move_cmds"]
                            rec["p2_spell_unit_cmds"] = dstate["p2_spell_cmds"]
                            rec["p2_am_ratio"] = round(dstate["p2_attack_cmds"] / max(1, dstate["p2_move_cmds"]), 2)
                            rec["p2_ability_breakdown"] = dict(
                                sorted(dstate["p2_ability_counts"].items(), key=lambda kv: -kv[1])[:10]
                            )
                        dstate["results"].append(rec)

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
                                    # Suppress bot1 actions during upgrade research so Mothman never cancels research;
                                    # in self-play also suppress during clearing/spawning so both start clean.
                                    if dstate["phase"] in ("upgrade_spawn", "upgrade_addons", "upgrade_issue", "upgrade_wait") or (
                                        opp_mode == "self" and dstate["phase"] != "fighting"
                                    ):
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
                                    if not dstate["mineral_refined"] and dstate["analyzer"] is not None and len(dstate["orig_th_positions"]) >= 2:
                                        dstate["analyzer"].refine_mineral_site(obs, dstate["orig_th_positions"])
                                        dstate["mineral_refined"] = True

                                    if dstate["phase"] == "wait_init" and gl >= 4:
                                        kill_tags = [
                                            u.tag for u in obs.raw_data.units
                                            if u.alliance in (1, 4) and u.tag not in dstate["orig_th_tags"]
                                            and u.unit_type not in TOWNHALL_IDS
                                        ]
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
                                            if u.display_type == 1 and u.alliance == 1
                                            and u.tag not in dstate["orig_th_tags"]
                                            and not (dstate["p1_orig_th_tag"] is None and u.unit_type in TOWNHALL_IDS)
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
                                            need_p1 = [u for u in scen.p1_upgrades if u not in dstate["p1_done_upgrades"]]
                                            need_p2 = [u for u in scen.p2_upgrades if u not in dstate["p2_done_upgrades"]]
                                            if need_p1 or need_p2:
                                                dstate["phase"] = "upgrade_spawn"
                                                dstate["phase_start_loop"] = gl
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
                                                dstate["p1_pending_addons"] = []
                                                dstate["p2_pending_addons"] = []
                                            else:
                                                dstate["phase"] = "spawning"
                                                dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "upgrade_spawn":
                                        scen = scenarios[dstate["scen_idx"]]
                                        need_p1 = [u for u in scen.p1_upgrades if u not in dstate["p1_done_upgrades"]]
                                        need_p2 = [u for u in scen.p2_upgrades if u not in dstate["p2_done_upgrades"]]
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
                                            avoid_pts = list(dstate["orig_th_positions"]) + [(open_site.cx, open_site.cy)]
                                            addon_spots = (
                                                an.find_buildable_spots(base_pos[0], base_pos[1], need_addon_cnt, avoid=avoid_pts, with_addon=True, min_spacing=6.5)
                                                if (an is not None and need_addon_cnt > 0) else []
                                            )
                                            avoid_pts2 = avoid_pts + addon_spots
                                            plain_spots = (
                                                an.find_buildable_spots(base_pos[0], base_pos[1], need_plain_cnt, avoid=avoid_pts2, with_addon=False, min_spacing=5.0)
                                                if (an is not None and need_plain_cnt > 0) else []
                                            )
                                            ai, pi = 0, 0
                                            for pr_uid in prereqs:
                                                px, py = plain_spots[pi] if pi < len(plain_spots) else (base_pos[0] + 6.0, base_pos[1])
                                                pi += 1
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
                                                        py_x, py_y = (an.snap_pathable(bx, by - 3.0, max_rad=4) if an is not None else (bx, by - 3.0))
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
                                                if acts_a1:
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
                                                ok1 = await _issue_owner_upgrades(sc2_ws, obs, dstate["p1_pending_upgrades"])
                                                if ok1 or gl >= dstate["phase_start_loop"] + 20:
                                                    dstate["p1_upg_issued"] = True
                                        if dstate["p1_upg_issued"] and (dstate["p2_upg_issued"] or gl >= dstate["phase_start_loop"] + 24):
                                            dstate["phase"] = "upgrade_wait"
                                            dstate["phase_start_loop"] = gl

                                    elif dstate["phase"] == "upgrade_wait" and gl >= dstate["phase_start_loop"] + 12:
                                        p1_uids = {b for _, b, _, _, _ in dstate["p1_pending_upgrades"]}
                                        dstate["p1_upg_busy"] = any(
                                            u.alliance == 1 and u.unit_type in p1_uids and len(u.orders) > 0
                                            for u in obs.raw_data.units
                                        )
                                        if (not dstate["p1_upg_busy"] and not dstate["p2_upg_busy"]) or gl >= dstate["phase_start_loop"] + 180:
                                            for unm, _, _, _, _ in dstate["p1_pending_upgrades"]:
                                                dstate["p1_done_upgrades"].add(unm)
                                            for unm, _, _, _, _ in dstate["p2_pending_upgrades"]:
                                                dstate["p2_done_upgrades"].add(unm)
                                            dstate["p1_pending_upgrades"] = []
                                            dstate["p2_pending_upgrades"] = []
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

                                    elif dstate["phase"] == "spawning" and gl >= dstate["phase_start_loop"] + 2:
                                        scen = scenarios[dstate["scen_idx"]]
                                        an = dstate["analyzer"]
                                        site = _site_for_scen(scen)
                                        dstate["arena_cx"], dstate["arena_cy"] = site.cx, site.cy
                                        dbg = []
                                        for uname, cnt, dx, dy in scen.p1_units:
                                            sx, sy = an.resolve_spawn_point(scen, uname, dx, dy) if an is not None else (site.cx + dx, site.cy + dy)
                                            dbg.append(debug_pb2.DebugCommand(
                                                create_unit=debug_pb2.DebugCreateUnit(
                                                    unit_type=UNIT_IDS[uname], owner=1,
                                                    pos=common_pb2.Point2D(x=sx, y=sy), quantity=cnt,
                                                )
                                            ))
                                        for uname, cnt, dx, dy in scen.p2_units:
                                            sx, sy = an.resolve_spawn_point(scen, uname, dx, dy) if an is not None else (site.cx + dx, site.cy + dy)
                                            dbg.append(debug_pb2.DebugCommand(
                                                create_unit=debug_pb2.DebugCreateUnit(
                                                    unit_type=UNIT_IDS[uname], owner=2,
                                                    pos=common_pb2.Point2D(x=sx, y=sy), quantity=cnt,
                                                )
                                            ))
                                        await rpc(sc2_ws, sc2api_pb2.Request(debug=sc2api_pb2.RequestDebug(debug=dbg)))
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
                                        dstate["p2_pre_cloak_pending"] = False

                                    elif dstate["phase"] == "fighting":
                                        scen = scenarios[dstate["scen_idx"]]
                                        cx, cy = dstate["arena_cx"], dstate["arena_cy"]
                                        want_workers = bool(
                                            {UNIT_IDS[u] for u, _, _, _ in (scen.p1_units + scen.p2_units)} & WORKER_IDS
                                        )
                                        p1u = [
                                            u for u in obs.raw_data.units
                                            if u.display_type == 1 and u.alliance == 1
                                            and (u.unit_type in COMBAT_IDS or (want_workers and u.unit_type in WORKER_IDS and math.hypot(u.pos.x - cx, u.pos.y - cy) < 35.0))
                                        ]
                                        p2u = [
                                            u for u in obs.raw_data.units
                                            if u.display_type == 1 and u.alliance == 4
                                            and (u.unit_type in COMBAT_IDS or (want_workers and u.unit_type in WORKER_IDS and math.hypot(u.pos.x - cx, u.pos.y - cy) < 35.0))
                                        ]
                                        exp_p1 = sum(cnt for _, cnt, _, _ in scen.p1_units)
                                        exp_p2 = sum(cnt for _, cnt, _, _ in scen.p2_units)
                                        if dstate["p1_start_cnt"] == 0 and (len(p1u) >= exp_p1 and len(p2u) >= exp_p2 or (gl >= dstate["phase_start_loop"] + 16 and p1u and p2u)):
                                            dstate["fight_start_loop"] = gl
                                            dstate["last_combat_event_loop"] = gl
                                            dstate["prev_unit_hp_map"] = {
                                                u.tag: float(u.health) + float(u.shield) for u in (p1u + p2u)
                                            }
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
                                            if scen.p1_pre_cloaked:
                                                await _issue_pre_cloak(sc2_ws, obs)
                                            if scen.p2_pre_cloaked:
                                                dstate["p2_pre_cloak_pending"] = True
                                        if dstate["p1_start_cnt"] > 0:
                                            p2_is_dummy = (opp_mode != "self")
                                            dstate["p1_alive_cnt"] = len(p1u)
                                            dstate["p2_alive_cnt"] = len(p2u)
                                            dstate["p1_combat_alive_cnt"] = count_combat_capable(p1u, is_dummy=False)
                                            dstate["p2_combat_alive_cnt"] = count_combat_capable(p2u, is_dummy=p2_is_dummy)
                                            dstate["p1_rem_val"] = sum(UNIT_VALUES.get(u.unit_type, 100.0) for u in p1u)
                                            dstate["p2_rem_val"] = sum(UNIT_VALUES.get(u.unit_type, 100.0) for u in p2u)

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

                                            if not p1u and not p2u:
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

                                            if end_reason is None:
                                                if fight_elapsed >= STALEMATE_NO_DAMAGE_LOOPS and no_dmg_elapsed >= STALEMATE_NO_DAMAGE_LOOPS:
                                                    end_reason = "no_damage_stalemate"
                                                elif fight_elapsed >= scen.max_loops:
                                                    end_reason = "max_loops"

                                            if end_reason is not None:
                                                finalize_current_round(gl, end_reason=end_reason, ko_winner_side=ko_side)
                                                dstate["scen_idx"] += 1
                                                if dstate["scen_idx"] >= len(scenarios):
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
                        deadline = time.monotonic() + 240.0
                        while not dstate["done"].is_set():
                            if time.monotonic() >= deadline:
                                raise TimeoutError("Arena duel exceeded 240s wall timeout")
                            if bot_proc1.poll() is not None and not dstate["done"].is_set():
                                dstate["errors"].append(f"bot_proc1 exited prematurely rc={bot_proc1.returncode}")
                                dstate["done"].set()
                                return
                            if bot_proc2 is not None and bot_proc2.poll() is not None and not dstate["done"].is_set():
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
    parser = argparse.ArgumentParser(description="Real-SC2_x64 RequestDebug Micro Skirmish Arena 2.0")
    parser.add_argument("--in-container", action="store_true")
    parser.add_argument("--mode", choices=["probe", "duel"], default="duel")
    parser.add_argument("--opponent", choices=["dummy", "self"], default="dummy", help="P2 opponent: dummy (MicroDummy, default) or self (live Mothman-vs-Mothman)")
    parser.add_argument("--race", default="all", help="Protoss | Terran | Zerg | all")
    parser.add_argument("--enemy-race", default="", help="Optional filter on scenario enemy_race")
    parser.add_argument("--scenarios", default="", help="Optional path to arena scenarios JSON catalog (defaults to tools/arena-scenarios.json)")
    parser.add_argument("--scenario", default="", help="Optional case-insensitive substring filter on scenario ID (e.g. 'p04' or 'burrow')")
    parser.add_argument("--terrain", default="", help="Optional filter on scenario terrain (open | high-ground-ramp | flank-surround | cliff-air-chasm | mineral-line-harass)")
    parser.add_argument("--source", default="", help="Optional filter on scenario source (core | match-forensics | pro-db | pattern-coverage)")
    parser.add_argument("--workers", type=int, default=3, help="Max parallel containers / 3D render workers (default: 3)")
    parser.add_argument("--map", default=DEFAULT_MAP)
    parser.add_argument("--step-size", type=int, default=4)
    parser.add_argument("--image", default=DEFAULT_IMAGE)
    parser.add_argument("--repo-dir", default=str(DEFAULT_REPO_DIR))
    parser.add_argument("--maps-dir", default=str(DEFAULT_MAPS_DIR))
    parser.add_argument("--arena-dir", default=str(DEFAULT_ARENA_DIR))
    parser.add_argument("--out", "--json-out", dest="out", default="", help="Output JSON report path")
    parser.add_argument("--compare", default="", help="Optional baseline JSON path to emit A/B delta comparison")
    parser.add_argument("--render-dir", default="", help="Optional output directory to render real-3D SC2_x64 WebP clips + Peak PNGs for all duels")
    parser.add_argument("--save-replays-dir", default="", help="Optional host directory to save raw .SC2Replay files from duels")
    parser.add_argument("--render-step", type=int, default=2, help="SC2 game loops per rendered 3D frame (default: 2)")
    parser.add_argument("--render-fps", type=int, default=16, help="Output animated WebP FPS (default: 16)")
    parser.add_argument("--scenario-ids", default="", help=argparse.SUPPRESS)
    parser.add_argument("--save-replay-path", default="", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.in_container:
        return asyncio.run(run_in_container(args))
    return run_host_driver(args)


if __name__ == "__main__":
    raise SystemExit(main())
