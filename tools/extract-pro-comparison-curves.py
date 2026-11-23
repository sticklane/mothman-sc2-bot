#!/usr/bin/env python3
"""
tools/extract-pro-comparison-curves.py

Standalone s2protocol extractor for comparative performance curves and
upgrade/structure timings across three cohorts:
  - Mothman   (current arena run, external matches only; self-play excluded)
  - Opponents (exact opponent side of those same external matches)
  - Pros      (LotV 1v1 human replays from replays/pro_corpus/, cached to JSON)

Extracts 8 canonical SC2 metrics (real-time LotV Faster = 22.4 gameloops/sec),
segmented by `all`, `Protoss`, `Terran`, and `Zerg`:
  1. APM  (Actions Per Minute)             - 30s curve (0:00..15:00) + summary
  2. EPM  (Effective Actions Per Minute)   - 30s curve (0:00..15:00) + summary
  3. SPM  (Screens Per Minute)             - 30s curve (0:00..15:00) + summary
  4. Army Value (Minerals)                 - 30s curve (0:00..15:00) + summary
  5. Army Value (Vespene Gas)              - 30s curve (0:00..15:00) + summary
  6. Resource Collection Rate (Minerals)   - 30s curve (0:00..15:00) + summary
  7. Resource Collection Rate (Gas)        - 30s curve (0:00..15:00) + summary
  8. Upgrade & Structure Timings           - expansions, tech/prod, upgrades/race

Pro corpus baseline is cached to `--pro-cache` so subsequent runs only parse the
new Mothman/Opponent replays (<10s total). Pass `--rebuild-pro-cache` to refresh.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import importlib.util
import json
import math
import os
import random
import re
import sqlite3
import sys
import time
from collections import defaultdict
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PRO_DIR = REPO_ROOT / "replays" / "pro_corpus"
DEFAULT_ARENA_DIR = Path.home() / "sc2-local-arena"
DEFAULT_DB_PATH = DEFAULT_ARENA_DIR / "arena_replays.sqlite"
DEFAULT_PYLIBS_DIR = DEFAULT_ARENA_DIR / "pylibs"
DEFAULT_SCRATCH_DIR = Path(
    "/home/sjaconette/.gemini/antigravity/brain/d28d22f4-2d13-41e2-9b7b-32757f58523b/scratch"
)
DEFAULT_PRO_CACHE = DEFAULT_SCRATCH_DIR / "pro_curves_cache.json"
DEFAULT_OUT_JSON = DEFAULT_SCRATCH_DIR / "pro_curves_and_timings.json"

SCHEMA_VERSION = 4
CACHE_SCHEMA_VERSION = 6

GAME_LOOPS_PER_SEC = 22.4
GAME_LOOPS_PER_MIN = 60.0 * GAME_LOOPS_PER_SEC  # 1344.0
LOTV_MIN_BASE_BUILD = 38215

RACES = ("Protoss", "Terran", "Zerg")
SEGMENTS = ("all", "Protoss", "Terran", "Zerg")
MATCHUPS = ("PvP", "PvT", "PvZ", "TvP", "TvT", "TvZ", "ZvP", "ZvT", "ZvZ")
COHORTS = ("mothman", "opponents", "pros")

BUCKETS_16M_SEC = list(range(0, 16 * 60 + 1, 30))   # 0:00..16:00 (30s) for Graph 9
BUCKETS_18M_SEC = list(range(0, 18 * 60 + 1, 60))   # 0:00..18:00 (60s) for Graphs 11 & 12
BUCKETS_TIER_SEC = [120, 240, 360, 480, 600, 720, 840, 960, 1080]  # 2m..18m for Graph 13

FORCE_RATIO_BINS: tuple[tuple[str, float, float], ...] = (
    ("<0.5x", 0.0, 0.5),
    ("0.5-0.75x", 0.5, 0.75),
    ("0.75-1.0x", 0.75, 1.0),
    ("1.0-1.35x", 1.0, 1.35),
    (">1.35x", 1.35, float("inf")),
)

GAS_STRUCTURES = frozenset({
    "Assimilator",
    "AssimilatorRich",
    "Refinery",
    "RefineryRich",
    "Extractor",
    "ExtractorRich",
})

# Explicit LotV 5.0.14 combat unit catalog: unit_name -> (tier, total_resource_value_min_plus_gas)
# Excludes workers, Overlords/Overseers, Larva/Egg, Interceptors, Locusts, Broodlings, Changelings, dummies.
COMBAT_UNIT_SPEC: dict[str, tuple[str, int]] = {
    # Protoss T1
    "Zealot": ("T1", 100),
    "Stalker": ("T1", 175),
    "Adept": ("T1", 125),
    "Sentry": ("T1", 150),
    # Protoss T2
    "Immortal": ("T2", 375),
    "Observer": ("T2", 100),
    "ObserverSiegeMode": ("T2", 100),
    "WarpPrism": ("T2", 250),
    "WarpPrismPhasing": ("T2", 250),
    "Phoenix": ("T2", 250),
    "VoidRay": ("T2", 400),
    "Oracle": ("T2", 300),
    "DarkTemplar": ("T2", 250),
    # Protoss T3
    "Colossus": ("T3", 500),
    "Disruptor": ("T3", 300),
    "HighTemplar": ("T3", 200),
    "Archon": ("T3", 350),
    "Carrier": ("T3", 600),
    "Tempest": ("T3", 425),
    "Mothership": ("T3", 700),
    # Terran T1
    "Marine": ("T1", 50),
    "Marauder": ("T1", 125),
    "Reaper": ("T1", 100),
    # Terran T2
    "Hellion": ("T2", 100),
    "HellionTank": ("T2", 100),
    "WidowMine": ("T2", 100),
    "WidowMineBurrowed": ("T2", 100),
    "Cyclone": ("T2", 175),
    "SiegeTank": ("T2", 275),
    "SiegeTankSieged": ("T2", 275),
    "Medivac": ("T2", 200),
    "VikingFighter": ("T2", 225),
    "VikingAssault": ("T2", 225),
    "Liberator": ("T2", 275),
    "LiberatorAG": ("T2", 275),
    "Banshee": ("T2", 250),
    "Raven": ("T2", 250),
    # Terran T3
    "Ghost": ("T3", 275),
    "Thor": ("T3", 500),
    "ThorAP": ("T3", 500),
    "Battlecruiser": ("T3", 700),
    # Zerg T1
    "Zergling": ("T1", 25),
    "Baneling": ("T1", 75),
    "BanelingBurrowed": ("T1", 75),
    "Roach": ("T1", 100),
    "RoachBurrowed": ("T1", 100),
    "Ravager": ("T1", 200),
    "RavagerBurrowed": ("T1", 200),
    "Queen": ("T1", 150),
    "QueenBurrowed": ("T1", 150),
    # Zerg T2
    "Hydralisk": ("T2", 150),
    "HydraliskBurrowed": ("T2", 150),
    "Mutalisk": ("T2", 200),
    "Corruptor": ("T2", 250),
    "Infestor": ("T2", 250),
    "InfestorBurrowed": ("T2", 250),
    "SwarmHostMP": ("T2", 175),
    "SwarmHostBurrowedMP": ("T2", 175),
    "LurkerMP": ("T2", 300),
    "LurkerMPBurrowed": ("T2", 300),
    # Zerg T3
    "Ultralisk": ("T3", 475),
    "UltraliskBurrowed": ("T3", 475),
    "BroodLord": ("T3", 550),
    "Viper": ("T3", 300),
}

IGNORED_UPGRADE_PREFIXES = ("Spray", "Reward", "GameHeart", "Skin")
IGNORED_UPGRADE_SUFFIXES = ("Skin", "Alternate")

WORKER_UNITS = frozenset({"Probe", "SCV", "Drone"})

# Graph 15: Exact Front-to-Back Layering sets (#1728)
FRONTLINE_LAYER_UNITS = frozenset({
    "Zealot", "Archon",
    "Marauder", "Hellbat", "HellionTank",
    "Zergling", "Baneling", "BanelingBurrowed", "Roach", "RoachBurrowed",
    "Ultralisk", "UltraliskBurrowed",
})
BACKLINE_LAYER_UNITS = frozenset({
    "Stalker", "Immortal", "Colossus", "HighTemplar", "Sentry", "Disruptor",
    "Marine", "SiegeTank", "SiegeTankSieged", "Ghost", "Medivac",
    "Hydralisk", "HydraliskBurrowed", "LurkerMP", "LurkerMPBurrowed",
    "Infestor", "InfestorBurrowed", "Viper",
})

# Graph 18: Canonical combat unit normalization (merging burrowed/sieged/phasing/assault morphs)
CANONICAL_COMBAT_UNIT: dict[str, str] = {
    "ObserverSiegeMode": "Observer",
    "WarpPrismPhasing": "WarpPrism",
    "HellionTank": "Hellbat",
    "WidowMineBurrowed": "WidowMine",
    "SiegeTankSieged": "SiegeTank",
    "VikingFighter": "Viking",
    "VikingAssault": "Viking",
    "LiberatorAG": "Liberator",
    "ThorAP": "Thor",
    "BanelingBurrowed": "Baneling",
    "RoachBurrowed": "Roach",
    "RavagerBurrowed": "Ravager",
    "QueenBurrowed": "Queen",
    "HydraliskBurrowed": "Hydralisk",
    "InfestorBurrowed": "Infestor",
    "SwarmHostMP": "SwarmHost",
    "SwarmHostBurrowedMP": "SwarmHost",
    "LurkerMP": "Lurker",
    "LurkerMPBurrowed": "Lurker",
    "UltraliskBurrowed": "Ultralisk",
}

CANONICAL_UNIT_SHORT: dict[str, str] = {
    "Zergling": "Ling",
    "Baneling": "Bane",
    "Hydralisk": "Hydra",
    "Ultralisk": "Ultra",
    "Mutalisk": "Muta",
    "SiegeTank": "Tank",
    "WidowMine": "Mine",
    "HighTemplar": "HT",
    "DarkTemplar": "DT",
    "Battlecruiser": "BC",
    "WarpPrism": "Prism",
    "Observer": "Obs",
    "Immortal": "Imm",
    "Colossus": "Colossus",
    "Disruptor": "Disruptor",
}

# Utility/macro units included in 2m..18m stacked curves but excluded from archetype clustering vectors
CLUSTER_UTILITY_UNITS = frozenset({"Queen", "Observer", "WarpPrism"})

# Genuine structures (excludes creep tumors, eggs, larva, broodlings, changelings, summons)
REAL_STRUCTURES = frozenset({
    # Protoss
    "Pylon", "Gateway", "WarpGate", "CyberneticsCore", "Forge",
    "PhotonCannon", "ShieldBattery", "RoboticsFacility", "RoboticsBay",
    "TwilightCouncil", "TemplarArchive", "DarkShrine", "Stargate", "FleetBeacon",
    # Terran
    "SupplyDepot", "SupplyDepotLowered", "Barracks", "BarracksFlying",
    "BarracksTechLab", "BarracksReactor", "Factory", "FactoryFlying",
    "FactoryTechLab", "FactoryReactor", "Starport", "StarportFlying",
    "StarportTechLab", "StarportReactor", "EngineeringBay", "Armory",
    "GhostAcademy", "FusionCore", "Bunker", "MissileTurret", "SensorTower",
    # Zerg
    "SpawningPool", "RoachWarren", "BanelingNest", "EvolutionChamber",
    "HydraliskDen", "Spire", "GreaterSpire", "InfestationPit", "LurkerDenMP",
    "UltraliskCavern", "SpineCrawler", "SporeCrawler", "NydusNetwork", "NydusCanal",
})

# -----------------------------------------------------------------------------
# Graphs 19-22 Constants: Production Utilization, Macro Abilities, Energy & Spells
# -----------------------------------------------------------------------------
# Graph 19: Facility group mappings & LotV Faster real-time build times (sec)
PROD_FACILITY_GROUP: dict[str, tuple[str, str]] = {
    # Protoss: (race, facility_group)
    "Gateway": ("Protoss", "Gateway"),
    "WarpGate": ("Protoss", "Gateway"),
    "RoboticsFacility": ("Protoss", "Robo"),
    "Stargate": ("Protoss", "Stargate"),
    "Nexus": ("Protoss", "Nexus"),
    # Terran
    "Barracks": ("Terran", "Barracks"),
    "BarracksFlying": ("Terran", "Barracks"),
    "Factory": ("Terran", "Factory"),
    "FactoryFlying": ("Terran", "Factory"),
    "Starport": ("Terran", "Starport"),
    "StarportFlying": ("Terran", "Starport"),
    "CommandCenter": ("Terran", "CommandCenter"),
    "CommandCenterFlying": ("Terran", "CommandCenter"),
    "OrbitalCommand": ("Terran", "CommandCenter"),
    "OrbitalCommandFlying": ("Terran", "CommandCenter"),
    "PlanetaryFortress": ("Terran", "CommandCenter"),
    # Zerg
    "Hatchery": ("Zerg", "Hatchery"),
    "Lair": ("Zerg", "Hatchery"),
    "Hive": ("Zerg", "Hatchery"),
    "Queen": ("Zerg", "Queen"),
    "QueenBurrowed": ("Zerg", "Queen"),
}

# Reactor addons contribute +1 parallel production slot to their Terran facility group
REACTOR_SLOT_GROUP: dict[str, str] = {
    "BarracksReactor": "Barracks",
    "FactoryReactor": "Factory",
    "StarportReactor": "Starport",
}

RACE_FACILITY_GROUPS: dict[str, tuple[str, ...]] = {
    "Protoss": ("Gateway", "Robo", "Stargate", "Nexus"),
    "Terran": ("Barracks", "Factory", "Starport", "CommandCenter"),
    "Zerg": ("Hatchery", "Queen"),
}

# Unit real-time training seconds (LotV Faster = 22.4 loops/sec) -> (facility_group, build_sec, wg_cd_sec)
TRAINED_UNIT_BUILD_SEC: dict[str, tuple[str, float, float]] = {
    # Protoss Gateway / WarpGate
    "Zealot": ("Gateway", 27.0, 20.0),
    "Stalker": ("Gateway", 30.0, 23.0),
    "Adept": ("Gateway", 30.0, 20.0),
    "Sentry": ("Gateway", 26.0, 23.0),
    "HighTemplar": ("Gateway", 39.0, 32.0),
    "DarkTemplar": ("Gateway", 39.0, 32.0),
    # Protoss Robo
    "Observer": ("Robo", 21.0, 21.0),
    "WarpPrism": ("Robo", 36.0, 36.0),
    "Immortal": ("Robo", 39.0, 39.0),
    "Colossus": ("Robo", 54.0, 54.0),
    "Disruptor": ("Robo", 36.0, 36.0),
    # Protoss Stargate
    "Phoenix": ("Stargate", 25.0, 25.0),
    "Oracle": ("Stargate", 37.0, 37.0),
    "VoidRay": ("Stargate", 43.0, 43.0),
    "Tempest": ("Stargate", 43.0, 43.0),
    "Carrier": ("Stargate", 64.0, 64.0),
    # Protoss Nexus
    "Probe": ("Nexus", 12.0, 12.0),
    # Terran Barracks
    "Marine": ("Barracks", 18.0, 18.0),
    "Marauder": ("Barracks", 21.0, 21.0),
    "Reaper": ("Barracks", 32.0, 32.0),
    "Ghost": ("Barracks", 29.0, 29.0),
    # Terran Factory
    "Hellion": ("Factory", 21.0, 21.0),
    "HellionTank": ("Factory", 21.0, 21.0),
    "WidowMine": ("Factory", 21.0, 21.0),
    "Cyclone": ("Factory", 32.0, 32.0),
    "SiegeTank": ("Factory", 32.0, 32.0),
    "Thor": ("Factory", 43.0, 43.0),
    # Terran Starport
    "VikingFighter": ("Starport", 30.0, 30.0),
    "Medivac": ("Starport", 30.0, 30.0),
    "Liberator": ("Starport", 43.0, 43.0),
    "Raven": ("Starport", 34.0, 34.0),
    "Banshee": ("Starport", 43.0, 43.0),
    "Battlecruiser": ("Starport", 64.0, 64.0),
    # Terran CommandCenter
    "SCV": ("CommandCenter", 12.0, 12.0),
}

# Zerg units spawned from Larva -> larva consumed per born unit (Zergling spawns 2 per 1 Larva)
ZERG_LARVA_CONSUMED: dict[str, float] = {
    "Drone": 1.0,
    "Overlord": 1.0,
    "Zergling": 0.5,
    "Roach": 1.0,
    "Hydralisk": 1.0,
    "Mutalisk": 1.0,
    "Corruptor": 1.0,
    "Infestor": 1.0,
    "SwarmHostMP": 1.0,
    "Ultralisk": 1.0,
    "Viper": 1.0,
}

# Graph 20: Chrono Boost target bucketing
PROTOSS_CHRONO_TARGET_BUCKET: dict[str, str] = {
    "Nexus": "Nexus",
    "Forge": "TechUpgrades",
    "CyberneticsCore": "TechUpgrades",
    "TwilightCouncil": "TechUpgrades",
    "RoboticsBay": "TechUpgrades",
    "TemplarArchive": "TechUpgrades",
    "DarkShrine": "TechUpgrades",
    "FleetBeacon": "TechUpgrades",
    "Gateway": "Gateway",
    "WarpGate": "Gateway",
    "RoboticsFacility": "Robo",
    "Stargate": "Stargate",
}
CHRONO_TARGET_BUCKETS = ("Nexus", "TechUpgrades", "Gateway", "Robo", "Stargate", "Other")
PROTOSS_ENERGY_RECHARGE_TARGETS = frozenset({
    "HighTemplar", "Sentry", "Oracle", "Phoenix", "VoidRay", "Mothership", "Nexus",
})
CHRONO_ABIL_LINKS = frozenset({116, 706, 708, 709, 716, 721, 722, 723})

# Graph 20 Phase & Situation breakdowns (#1750)
MACRO_PHASES: tuple[tuple[str, float, float], ...] = (
    ("0-4m", 0.0, 240.0),
    ("4-8m", 240.0, 480.0),
    ("8-12m", 480.0, 720.0),
    ("12m+", 720.0, float("inf")),
)
MACRO_PHASE_LABELS = tuple(p[0] for p in MACRO_PHASES)
CLOAK_THREAT_UNITS = frozenset({
    "DarkTemplar", "Banshee", "Ghost", "Mothership",
    "WidowMine", "WidowMineBurrowed",
    "LurkerMP", "LurkerMPBurrowed",
    "RoachBurrowed", "BanelingBurrowed", "InfestorBurrowed", "SwarmHostBurrowedMP",
})
CLOAK_THREAT_UPGRADES = frozenset({
    "BansheeCloak", "PersonalCloaking", "Burrow", "TunnelingClaws", "DarkTemplarBlinkUpgrade",
})

# Graph 21: LotV Faster energy physics (0.5625/Blizz-sec * 1.4 = 0.7875/real-time sec)
ENERGY_REGEN_PER_SEC = 0.7875
ENERGY_CAP = 200.0
ENERGY_CAPPED_THRESH = 180.0
MACRO_CASTER_START_ENERGY: dict[str, float] = {
    "Nexus": 50.0,
    "OrbitalCommand": 50.0,
    "Queen": 25.0,
}
MACRO_ABILITY_ENERGY_COST: dict[str, tuple[str, float]] = {
    "chrono_boost": ("Nexus", 50.0),
    "energy_recharge": ("Nexus", 50.0),
    "recall": ("Nexus", 50.0),
    "battery_overcharge": ("Nexus", 50.0),
    "mule": ("OrbitalCommand", 50.0),
    "scan": ("OrbitalCommand", 50.0),
    "supply_drop": ("OrbitalCommand", 50.0),
    "inject": ("Queen", 25.0),
    "creep_tumor_queen": ("Queen", 25.0),
    "transfuse": ("Queen", 50.0),
}

# Graph 22: Complete Active Combat Spell & Mode-Morph Catalog
# (key, label, race, caster_label, caster_units_tuple, source, kind)
# source: "tracker_spawn" | "tracker_morph" | "scmd"
COMBAT_SPELL_CATALOG: tuple[tuple[str, str, str, str, tuple[str, ...], str, str], ...] = (
    # Protoss
    ("blink", "Blink", "Protoss", "Stalker", ("Stalker",), "scmd", "spell"),
    ("shade", "Psionic Transfer (Shade)", "Protoss", "Adept", ("Adept",), "tracker_spawn", "spell"),
    ("force_field", "Force Field", "Protoss", "Sentry", ("Sentry",), "tracker_spawn", "spell"),
    ("guardian_shield", "Guardian Shield", "Protoss", "Sentry", ("Sentry",), "scmd", "spell"),
    ("hallucination", "Hallucination", "Protoss", "Sentry", ("Sentry",), "scmd", "spell"),
    ("psi_storm", "Psionic Storm", "Protoss", "HighTemplar", ("HighTemplar",), "scmd", "spell"),
    ("feedback", "Feedback", "Protoss", "HighTemplar", ("HighTemplar",), "scmd", "spell"),
    ("purification_nova", "Purification Nova", "Protoss", "Disruptor", ("Disruptor",), "tracker_spawn", "spell"),
    ("stasis_ward", "Stasis Ward", "Protoss", "Oracle", ("Oracle",), "tracker_spawn", "spell"),
    ("pulsar_beam", "Pulsar Beam", "Protoss", "Oracle", ("Oracle",), "scmd", "spell"),
    ("recall", "Nexus Mass Recall", "Protoss", "Nexus", ("Nexus",), "scmd", "spell"),
    # Terran
    ("stim", "Stimpack", "Terran", "Marine/Marauder", ("Marine", "Marauder"), "scmd", "spell"),
    ("kd8_charge", "KD8 Charge", "Terran", "Reaper", ("Reaper",), "tracker_spawn", "spell"),
    ("siege_morph", "Siege / Unsiege", "Terran", "SiegeTank", ("SiegeTank", "SiegeTankSieged"), "tracker_morph", "mode_morph"),
    ("widow_mine_burrow", "Widow Mine Burrow", "Terran", "WidowMine", ("WidowMine", "WidowMineBurrowed"), "tracker_morph", "mode_morph"),
    ("liberator_ag", "Liberator Defender Mode", "Terran", "Liberator", ("Liberator", "LiberatorAG"), "tracker_morph", "mode_morph"),
    ("viking_mode", "Viking Mode Switch", "Terran", "Viking", ("VikingFighter", "VikingAssault"), "tracker_morph", "mode_morph"),
    ("hellbat_morph", "Hellion / Hellbat Morph", "Terran", "Hellion/Hellbat", ("Hellion", "HellionTank"), "tracker_morph", "mode_morph"),
    ("emp", "EMP Round", "Terran", "Ghost", ("Ghost",), "scmd", "spell"),
    ("snipe", "Steady Targeting (Snipe)", "Terran", "Ghost", ("Ghost",), "scmd", "spell"),
    ("cloak", "Cloak (Banshee/Ghost)", "Terran", "Banshee/Ghost", ("Banshee", "Ghost"), "scmd", "spell"),
    ("auto_turret", "Auto-Turret", "Terran", "Raven", ("Raven",), "tracker_spawn", "spell"),
    ("interference_matrix", "Interference Matrix", "Terran", "Raven", ("Raven",), "scmd", "spell"),
    ("anti_armor_missile", "Anti-Armor Missile", "Terran", "Raven", ("Raven",), "scmd", "spell"),
    ("yamato", "Yamato Cannon", "Terran", "Battlecruiser", ("Battlecruiser",), "scmd", "spell"),
    ("tactical_jump", "Tactical Jump", "Terran", "Battlecruiser", ("Battlecruiser",), "scmd", "spell"),
    # Zerg
    ("corrosive_bile", "Corrosive Bile", "Zerg", "Ravager", ("Ravager", "RavagerBurrowed"), "scmd", "spell"),
    ("lurker_burrow", "Lurker Burrow", "Zerg", "Lurker", ("LurkerMP", "LurkerMPBurrowed"), "tracker_morph", "mode_morph"),
    ("burrow_combat", "Combat Burrow (Roach/Bane/Inf)", "Zerg", "Roach/Bane/Inf", ("Roach", "RoachBurrowed", "Baneling", "BanelingBurrowed", "Infestor", "InfestorBurrowed"), "tracker_morph", "mode_morph"),
    ("fungal_growth", "Fungal Growth", "Zerg", "Infestor", ("Infestor", "InfestorBurrowed"), "scmd", "spell"),
    ("neural_parasite", "Neural Parasite", "Zerg", "Infestor", ("Infestor", "InfestorBurrowed"), "scmd", "spell"),
    ("abduct", "Abduct", "Zerg", "Viper", ("Viper",), "scmd", "spell"),
    ("blinding_cloud", "Blinding Cloud", "Zerg", "Viper", ("Viper",), "scmd", "spell"),
    ("parasitic_bomb", "Parasitic Bomb", "Zerg", "Viper", ("Viper",), "tracker_spawn", "spell"),
    ("transfuse", "Transfuse", "Zerg", "Queen", ("Queen", "QueenBurrowed"), "scmd", "spell"),
    ("spawn_changeling", "Spawn Changeling", "Zerg", "Overseer", ("Overseer", "OverseerSiegeMode"), "tracker_spawn", "spell"),
)

ALL_CASTER_TRACK_UNITS: frozenset[str] = frozenset(
    u for _k, _l, _r, _cl, units, _s, _kd in COMBAT_SPELL_CATALOG for u in units
)

# Human-friendly upgrade labels for Graph 14 (fallback auto-formats CamelCase)
UPGRADE_FRIENDLY_LABELS: dict[str, str] = {
    "WarpGateResearch": "Warp Gate",
    "BlinkTech": "Blink",
    "Charge": "Charge",
    "AdeptPiercingAttack": "Resonating Glaives",
    "PsiStormTech": "Psionic Storm",
    "ExtendedThermalLance": "Extended Thermal Lance",
    "ObserverGraviticBooster": "Gravitic Boosters (Obs Speed)",
    "GraviticDrive": "Gravitic Drive (Prism Speed)",
    "PhoenixRangeUpgrade": "Anion Pulse-Crystals",
    "VoidRaySpeedUpgrade": "Flux Vanes",
    "DarkTemplarBlinkUpgrade": "Shadow Stride (DT Blink)",
    "TempestGroundAttackUpgrade": "Tectonic Destabilizers",
    "ProtossGroundWeaponsLevel1": "+1 Ground Weapons",
    "ProtossGroundWeaponsLevel2": "+2 Ground Weapons",
    "ProtossGroundWeaponsLevel3": "+3 Ground Weapons",
    "ProtossGroundArmorsLevel1": "+1 Ground Armor",
    "ProtossGroundArmorsLevel2": "+2 Ground Armor",
    "ProtossGroundArmorsLevel3": "+3 Ground Armor",
    "ProtossShieldsLevel1": "+1 Shields",
    "ProtossShieldsLevel2": "+2 Shields",
    "ProtossShieldsLevel3": "+3 Shields",
    "ProtossAirWeaponsLevel1": "+1 Air Weapons",
    "ProtossAirWeaponsLevel2": "+2 Air Weapons",
    "ProtossAirWeaponsLevel3": "+3 Air Weapons",
    "ProtossAirArmorsLevel1": "+1 Air Armor",
    "ProtossAirArmorsLevel2": "+2 Air Armor",
    "ProtossAirArmorsLevel3": "+3 Air Armor",
    "Stimpack": "Stimpack",
    "ShieldWall": "Combat Shield",
    "PunisherGrenades": "Concussive Shells",
    "TerranInfantryWeaponsLevel1": "+1 Infantry Weapons",
    "TerranInfantryWeaponsLevel2": "+2 Infantry Weapons",
    "TerranInfantryWeaponsLevel3": "+3 Infantry Weapons",
    "TerranInfantryArmorsLevel1": "+1 Infantry Armor",
    "TerranInfantryArmorsLevel2": "+2 Infantry Armor",
    "TerranInfantryArmorsLevel3": "+3 Infantry Armor",
    "TerranVehicleWeaponsLevel1": "+1 Vehicle Weapons",
    "TerranVehicleWeaponsLevel2": "+2 Vehicle Weapons",
    "TerranVehicleWeaponsLevel3": "+3 Vehicle Weapons",
    "TerranShipWeaponsLevel1": "+1 Ship Weapons",
    "TerranShipWeaponsLevel2": "+2 Ship Weapons",
    "TerranShipWeaponsLevel3": "+3 Ship Weapons",
    "TerranVehicleAndShipArmorsLevel1": "+1 Mech/Air Armor",
    "TerranVehicleAndShipArmorsLevel2": "+2 Mech/Air Armor",
    "TerranVehicleAndShipArmorsLevel3": "+3 Mech/Air Armor",
    "HighCapacityBarrels": "Infernal Pre-Igniter (Blue Flame)",
    "SmartServos": "Smart Servos",
    "DrillClaws": "Drilling Claws",
    "CycloneLockOnDamageUpgrade": "Mag-Field Accelerator",
    "BansheeCloak": "Banshee Cloak",
    "BansheeSpeed": "Hyperflight Rotors",
    "LiberatorAGRangeUpgrade": "Advanced Ballistics",
    "PersonalCloaking": "Ghost Cloak",
    "EnhancedShockwaves": "Enhanced Shockwaves",
    "BattlecruiserEnableSpecializations": "Weapon Refit (Yamato)",
    "HiSecAutoTracking": "Hi-Sec Auto Tracking",
    "TerranBuildingArmor": "Neosteel Armor",
    "RavenCorvidReactor": "Corvid Reactor",
    "InterferenceMatrix": "Interference Matrix",
    "MedivacCaduceusReactor": "Caduceus Reactor",
    "zerglingmovementspeed": "Metabolic Boost (Ling Speed)",
    "zerglingattackspeed": "Adrenal Glands",
    "CentrificalHooks": "Centrifugal Hooks (Bane Speed)",
    "GlialReconstitution": "Glial Reconstitution (Roach Speed)",
    "TunnelingClaws": "Tunneling Claws",
    "Burrow": "Burrow",
    "overlordspeed": "Pneumatized Carapace (OV Speed)",
    "EvolveGroovedSpines": "Grooved Spines (Hydra Range)",
    "EvolveMuscularAugments": "Muscular Augments (Hydra Speed)",
    "LurkerRange": "Seismic Spines (Lurker Range)",
    "DiggingClaws": "Adaptive Talons (Lurker Burrow)",
    "NeuralParasite": "Neural Parasite",
    "ChitinousPlating": "Chitinous Plating",
    "AnabolicSynthesis": "Anabolic Synthesis",
    "ZergMeleeWeaponsLevel1": "+1 Melee Attacks",
    "ZergMeleeWeaponsLevel2": "+2 Melee Attacks",
    "ZergMeleeWeaponsLevel3": "+3 Melee Attacks",
    "ZergMissileWeaponsLevel1": "+1 Missile Attacks",
    "ZergMissileWeaponsLevel2": "+2 Missile Attacks",
    "ZergMissileWeaponsLevel3": "+3 Missile Attacks",
    "ZergGroundArmorsLevel1": "+1 Ground Carapace",
    "ZergGroundArmorsLevel2": "+2 Ground Carapace",
    "ZergGroundArmorsLevel3": "+3 Ground Carapace",
    "ZergFlyerWeaponsLevel1": "+1 Flyer Attacks",
    "ZergFlyerWeaponsLevel2": "+2 Flyer Attacks",
    "ZergFlyerWeaponsLevel3": "+3 Flyer Attacks",
    "ZergFlyerArmorsLevel1": "+1 Flyer Carapace",
    "ZergFlyerArmorsLevel2": "+2 Flyer Carapace",
    "ZergFlyerArmorsLevel3": "+3 Flyer Carapace",
}

CURVE_METRICS = (
    "apm",
    "epm",
    "spm",
    "army_minerals",
    "army_gas",
    "collection_minerals",
    "collection_gas",
)
RATE_METRICS = frozenset({"apm", "epm", "spm"})
SNAPSHOT_METRICS = frozenset(
    {"army_minerals", "army_gas", "collection_minerals", "collection_gas"}
)

METRIC_META: dict[str, dict[str, str]] = {
    "apm": {
        "label": "Actions Per Minute (APM)",
        "unit": "actions/min",
        "kind": "rate",
    },
    "epm": {
        "label": "Effective Actions Per Minute (EPM)",
        "unit": "actions/min",
        "kind": "rate",
    },
    "spm": {
        "label": "Screens Per Minute (SPM)",
        "unit": "screens/min",
        "kind": "rate",
    },
    "army_minerals": {
        "label": "Army Value (Minerals)",
        "unit": "minerals",
        "kind": "snapshot",
    },
    "army_gas": {
        "label": "Army Value (Vespene Gas)",
        "unit": "gas",
        "kind": "snapshot",
    },
    "collection_minerals": {
        "label": "Mineral Collection Rate",
        "unit": "minerals/min",
        "kind": "snapshot",
    },
    "collection_gas": {
        "label": "Vespene Gas Collection Rate",
        "unit": "gas/min",
        "kind": "snapshot",
    },
}

BAD_MAP_TOKENS = (
    "PCANP",
    "EnemyTower",
    "AI",
    "Mod",
    "Arcade",
    "Unit Tester",
    "Micro",
    "Sandbox",
    "星际",
    "Custom",
    "Practice",
    "Cheat",
)

TOWN_HALLS = frozenset({
    "Nexus",
    "CommandCenter",
    "CommandCenterFlying",
    "OrbitalCommand",
    "OrbitalCommandFlying",
    "PlanetaryFortress",
    "Hatchery",
    "Lair",
    "Hive",
})

# Canonical ordered milestones per race:
# (key, display_label, kind, event_source, unit_or_upgrade_names, nth_1based)
# kind: "expansion" | "structure" | "upgrade"
# event_source:
#   "th_expand" -> nth additional non-self-canceled TownHall init (sec > 5.0)
#   "bldg_init" -> nth non-self-canceled structure init (sec > 2.0)
#   "morph"     -> nth SUnitTypeChangeEvent completion (OrbitalCommand, Lair, Hive)
#   "upgrade"   -> SUpgradeEvent completion time
TIMING_MILESTONES: dict[str, list[tuple[str, str, str, str, tuple[str, ...], int]]] = {
    "Protoss": [
        ("nat", "Natural Nexus", "expansion", "th_expand", ("Nexus",), 1),
        ("third", "3rd Nexus", "expansion", "th_expand", ("Nexus",), 2),
        ("fourth", "4th Nexus", "expansion", "th_expand", ("Nexus",), 3),
        ("pylon_1", "Pylon #1", "structure", "bldg_init", ("Pylon",), 1),
        ("gate_1", "Gateway #1", "structure", "bldg_init", ("Gateway",), 1),
        ("gas_1", "Assimilator #1", "structure", "bldg_init", ("Assimilator", "AssimilatorRich"), 1),
        ("cyber", "Cybernetics Core", "structure", "bldg_init", ("CyberneticsCore",), 1),
        ("robo", "Robotics Facility", "structure", "bldg_init", ("RoboticsFacility",), 1),
        ("twilight", "Twilight Council", "structure", "bldg_init", ("TwilightCouncil",), 1),
        ("stargate", "Stargate", "structure", "bldg_init", ("Stargate",), 1),
        ("forge", "Forge", "structure", "bldg_init", ("Forge",), 1),
        ("robo_bay", "Robotics Bay", "structure", "bldg_init", ("RoboticsBay",), 1),
        ("templar_archive", "Templar Archives", "structure", "bldg_init", ("TemplarArchive",), 1),
        ("dark_shrine", "Dark Shrine", "structure", "bldg_init", ("DarkShrine",), 1),
        ("fleet_beacon", "Fleet Beacon", "structure", "bldg_init", ("FleetBeacon",), 1),
        ("upg_warpgate", "Warp Gate (done)", "upgrade", "upgrade", ("WarpGateResearch",), 1),
        ("upg_blink", "Blink (done)", "upgrade", "upgrade", ("BlinkTech",), 1),
        ("upg_charge", "Charge (done)", "upgrade", "upgrade", ("Charge",), 1),
        ("upg_glaives", "Resonating Glaives (done)", "upgrade", "upgrade", ("AdeptPiercingAttack",), 1),
        ("upg_g_wpn1", "+1 Ground Weapons (done)", "upgrade", "upgrade", ("ProtossGroundWeaponsLevel1",), 1),
        ("upg_g_arm1", "+1 Ground Armor (done)", "upgrade", "upgrade", ("ProtossGroundArmorsLevel1",), 1),
        ("upg_g_wpn2", "+2 Ground Weapons (done)", "upgrade", "upgrade", ("ProtossGroundWeaponsLevel2",), 1),
        ("upg_storm", "Psionic Storm (done)", "upgrade", "upgrade", ("PsiStormTech",), 1),
        ("upg_lance", "Extended Thermal Lance (done)", "upgrade", "upgrade", ("ExtendedThermalLance",), 1),
        ("upg_obs_speed", "Observer Speed (done)", "upgrade", "upgrade", ("ObserverGraviticBooster",), 1),
    ],
    "Terran": [
        ("nat", "Natural CC", "expansion", "th_expand", ("CommandCenter",), 1),
        ("third", "3rd CC", "expansion", "th_expand", ("CommandCenter",), 2),
        ("fourth", "4th CC", "expansion", "th_expand", ("CommandCenter",), 3),
        ("depot_1", "Supply Depot #1", "structure", "bldg_init", ("SupplyDepot",), 1),
        ("rax_1", "Barracks #1", "structure", "bldg_init", ("Barracks",), 1),
        ("gas_1", "Refinery #1", "structure", "bldg_init", ("Refinery", "RefineryRich"), 1),
        ("orbital", "Orbital Command (done)", "structure", "morph", ("OrbitalCommand",), 1),
        ("factory", "Factory", "structure", "bldg_init", ("Factory",), 1),
        ("starport", "Starport", "structure", "bldg_init", ("Starport",), 1),
        ("ebay", "Engineering Bay", "structure", "bldg_init", ("EngineeringBay",), 1),
        ("armory", "Armory", "structure", "bldg_init", ("Armory",), 1),
        ("ghost_acad", "Ghost Academy", "structure", "bldg_init", ("GhostAcademy",), 1),
        ("fusion_core", "Fusion Core", "structure", "bldg_init", ("FusionCore",), 1),
        ("upg_stim", "Stimpack (done)", "upgrade", "upgrade", ("Stimpack",), 1),
        ("upg_combat_shield", "Combat Shield (done)", "upgrade", "upgrade", ("ShieldWall",), 1),
        ("upg_concussive", "Concussive Shells (done)", "upgrade", "upgrade", ("PunisherGrenades",), 1),
        ("upg_bio_wpn1", "+1 Infantry Weapons (done)", "upgrade", "upgrade", ("TerranInfantryWeaponsLevel1",), 1),
        ("upg_bio_arm1", "+1 Infantry Armor (done)", "upgrade", "upgrade", ("TerranInfantryArmorsLevel1",), 1),
        ("upg_bio_wpn2", "+2 Infantry Weapons (done)", "upgrade", "upgrade", ("TerranInfantryWeaponsLevel2",), 1),
        ("upg_bio_arm2", "+2 Infantry Armor (done)", "upgrade", "upgrade", ("TerranInfantryArmorsLevel2",), 1),
        ("upg_mech_wpn1", "+1 Vehicle Weapons (done)", "upgrade", "upgrade", ("TerranVehicleWeaponsLevel1",), 1),
        ("upg_cloak", "Banshee Cloak (done)", "upgrade", "upgrade", ("BansheeCloak",), 1),
        ("upg_drill_claws", "Drilling Claws (done)", "upgrade", "upgrade", ("DrillClaws",), 1),
    ],
    "Zerg": [
        ("nat", "Natural Hatchery", "expansion", "th_expand", ("Hatchery",), 1),
        ("third", "3rd Hatchery", "expansion", "th_expand", ("Hatchery",), 2),
        ("fourth", "4th Hatchery", "expansion", "th_expand", ("Hatchery",), 3),
        ("pool", "Spawning Pool", "structure", "bldg_init", ("SpawningPool",), 1),
        ("gas_1", "Extractor #1", "structure", "bldg_init", ("Extractor", "ExtractorRich"), 1),
        ("lair", "Lair (done)", "structure", "morph", ("Lair",), 1),
        ("hive", "Hive (done)", "structure", "morph", ("Hive",), 1),
        ("rw", "Roach Warren", "structure", "bldg_init", ("RoachWarren",), 1),
        ("bane_nest", "Baneling Nest", "structure", "bldg_init", ("BanelingNest",), 1),
        ("evo", "Evolution Chamber", "structure", "bldg_init", ("EvolutionChamber",), 1),
        ("hydra_den", "Hydralisk Den", "structure", "bldg_init", ("HydraliskDen",), 1),
        ("spire", "Spire", "structure", "bldg_init", ("Spire",), 1),
        ("infest_pit", "Infestation Pit", "structure", "bldg_init", ("InfestationPit",), 1),
        ("lurker_den", "Lurker Den", "structure", "bldg_init", ("LurkerDenMP",), 1),
        ("ultra_cavern", "Ultralisk Cavern", "structure", "bldg_init", ("UltraliskCavern",), 1),
        ("upg_ling_speed", "Metabolic Boost (done)", "upgrade", "upgrade", ("zerglingmovementspeed",), 1),
        ("upg_bane_speed", "Centrifugal Hooks (done)", "upgrade", "upgrade", ("CentrificalHooks",), 1),
        ("upg_roach_speed", "Glial Reconstitution (done)", "upgrade", "upgrade", ("GlialReconstitution",), 1),
        ("upg_hydra_range", "Grooved Spines (done)", "upgrade", "upgrade", ("EvolveGroovedSpines",), 1),
        ("upg_hydra_speed", "Muscular Augments (done)", "upgrade", "upgrade", ("EvolveMuscularAugments",), 1),
        ("upg_melee1", "+1 Melee Attacks (done)", "upgrade", "upgrade", ("ZergMeleeWeaponsLevel1",), 1),
        ("upg_missile1", "+1 Missile Attacks (done)", "upgrade", "upgrade", ("ZergMissileWeaponsLevel1",), 1),
        ("upg_carapace1", "+1 Ground Carapace (done)", "upgrade", "upgrade", ("ZergGroundArmorsLevel1",), 1),
        ("upg_missile2", "+2 Missile Attacks (done)", "upgrade", "upgrade", ("ZergMissileWeaponsLevel2",), 1),
        ("upg_ov_speed", "Pneumatized Carapace (done)", "upgrade", "upgrade", ("overlordspeed",), 1),
        ("upg_adrenal", "Adrenal Glands (done)", "upgrade", "upgrade", ("zerglingattackspeed",), 1),
    ],
}

# Precomputed structure names we care about for fast tracker filtering
TRACKED_STRUCTURES: frozenset[str] = frozenset(
    nm
    for specs in TIMING_MILESTONES.values()
    for _, _, _, src, names, _ in specs
    if src in ("bldg_init", "th_expand")
    for nm in names
) | TOWN_HALLS

TRACKED_MORPHS: frozenset[str] = frozenset(
    nm
    for specs in TIMING_MILESTONES.values()
    for _, _, _, src, names, _ in specs
    if src == "morph"
    for nm in names
)

TRACKED_UPGRADES: frozenset[str] = frozenset(
    nm
    for specs in TIMING_MILESTONES.values()
    for _, _, _, src, names, _ in specs
    if src == "upgrade"
    for nm in names
)

# Canonical SC2 APM / EPM / SPM game event constants
APM_EVENTS = frozenset({
    "NNet.Game.SCmdEvent",
    "NNet.Game.SCmdUpdateTargetPointEvent",
    "NNet.Game.SCmdUpdateTargetUnitEvent",
    "NNet.Game.SSelectionDeltaEvent",
    "NNet.Game.SControlGroupUpdateEvent",
})
CMD_EVENTS = frozenset({
    "NNet.Game.SCmdEvent",
    "NNet.Game.SCmdUpdateTargetPointEvent",
    "NNet.Game.SCmdUpdateTargetUnitEvent",
})
CAMERA_EVENT = "NNet.Game.SCameraUpdateEvent"

# EPM deduplication & SPM jump thresholds (SC2 LotV Faster = 22.4 loops/sec)
EPM_CMD_DEDUP_LOOPS = 16       # 0.71s identical command throttle
EPM_SEL_DEDUP_LOOPS = 16       # 0.71s identical selection throttle
EPM_POINT_BUCKET_TILES = 2.0   # 2-tile spatial grid for point-command dedup
SPM_MIN_JUMP_TILES = 12.0      # >= 12 map tiles = new screen focus
SPM_MIN_DT_LOOPS = 6           # >= 0.27s debounce against smooth panning


_RDB_MOD = None


def _get_replay_db_module(pylibs_dir: Path):
    global _RDB_MOD
    if _RDB_MOD is None:
        spec = importlib.util.spec_from_file_location(
            "replay_db_helper", str(REPO_ROOT / "tools" / "replay-db.py")
        )
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod._ensure_pylibs(pylibs_dir)
        _RDB_MOD = mod
    return _RDB_MOD


def _fmt_sec(v: float | None) -> str | None:
    if v is None:
        return None
    iv = int(round(v))
    return f"{iv // 60}:{iv % 60:02d}"


def _pctiles(vals: list[float], prec: int = 1) -> dict[str, Any]:
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
        "p25": round(_q(0.25), prec),
        "med": round(_q(0.50), prec),
        "p75": round(_q(0.75), prec),
        "mean": round(sum(s) / n, prec),
    }


def _apply_selection_delta(cur: list[int], delta: dict[str, Any]) -> list[int]:
    """Update a player's active selection list from SSelectionDeltaEvent.m_delta."""
    rm = delta.get("m_removeMask") or {}
    if "ZeroIndices" in rm:
        keep = set(rm["ZeroIndices"] or ())
        new_sel = [u for i, u in enumerate(cur) if i in keep]
    elif "OneIndices" in rm:
        drop = set(rm["OneIndices"] or ())
        new_sel = [u for i, u in enumerate(cur) if i not in drop]
    elif "Mask" in rm:
        mask_val = rm["Mask"]
        if isinstance(mask_val, (list, tuple)) and len(mask_val) == 2:
            nbits, raw = int(mask_val[0]), mask_val[1]
            if isinstance(raw, (bytes, bytearray)):
                drop_idx: set[int] = set()
                for bit_i in range(min(nbits, len(cur))):
                    byte_i = bit_i // 8
                    if byte_i < len(raw) and (raw[byte_i] & (0x80 >> (bit_i % 8))):
                        drop_idx.add(bit_i)
                new_sel = [u for i, u in enumerate(cur) if i not in drop_idx]
            else:
                new_sel = list(cur)
        else:
            new_sel = list(cur)
    else:
        # "None": no removals; cap length defensively for Raw-API bots
        new_sel = list(cur) if len(cur) < 512 else []

    add_tags = delta.get("m_addUnitTags") or ()
    if add_tags:
        new_sel.extend(int(t) for t in add_tags)
    return new_sel


def _cmd_signature(ev: dict[str, Any], sel_sig: Any) -> tuple[Any, ...]:
    """Build a canonical deduplication signature for SCmdEvent / SCmdUpdateTarget*."""
    et = ev.get("_event", "")
    if et == "NNet.Game.SCmdEvent":
        abil = ev.get("m_abil")
        if isinstance(abil, dict):
            a_link = abil.get("m_abilLink")
            a_idx = abil.get("m_abilCmdIndex")
        else:
            a_link, a_idx = None, None
        mdata = ev.get("m_data") or {}
        if "TargetPoint" in mdata and isinstance(mdata["TargetPoint"], dict):
            pt = mdata["TargetPoint"]
            bx = int(round((pt.get("x", 0) / 4096.0) / EPM_POINT_BUCKET_TILES))
            by = int(round((pt.get("y", 0) / 4096.0) / EPM_POINT_BUCKET_TILES))
            tgt: Any = ("pt", bx, by)
        elif "TargetUnit" in mdata and isinstance(mdata["TargetUnit"], dict):
            tgt = ("u", mdata["TargetUnit"].get("m_tag"))
        elif "Data" in mdata:
            tgt = ("d", mdata["Data"])
        else:
            tgt = ("n",)
        return ("cmd", sel_sig, a_link, a_idx, tgt)

    if et == "NNet.Game.SCmdUpdateTargetPointEvent":
        pt = ev.get("m_target") or {}
        bx = int(round((pt.get("x", 0) / 4096.0) / EPM_POINT_BUCKET_TILES))
        by = int(round((pt.get("y", 0) / 4096.0) / EPM_POINT_BUCKET_TILES))
        return ("upt", sel_sig, bx, by)

    if et == "NNet.Game.SCmdUpdateTargetUnitEvent":
        tu = ev.get("m_target") or {}
        return ("uu", sel_sig, tu.get("m_tag"))

    return (et, sel_sig)


def _sample_stats_at_buckets(
    stats_series: list[tuple[float, float, float, float, float]],
    buckets_sec: list[int],
    dur_sec: float,
    half_window: float,
) -> dict[str, list[float | None]]:
    """
    Align SPlayerStatsEvent series [(sec, army_min, army_gas, coll_min, coll_gas), ...]
    to `buckets_sec` using nearest sample within `±half_window` for games with `dur_sec >= t`.
    """
    out: dict[str, list[float | None]] = {
        "army_minerals": [],
        "army_gas": [],
        "collection_minerals": [],
        "collection_gas": [],
    }
    n = len(stats_series)
    ptr = 0
    for t in buckets_sec:
        if dur_sec < float(t) or n == 0:
            for k in out:
                out[k].append(None)
            continue
        tf = float(t)
        while ptr + 1 < n and abs(stats_series[ptr + 1][0] - tf) <= abs(stats_series[ptr][0] - tf):
            ptr += 1
        if abs(stats_series[ptr][0] - tf) <= half_window:
            _, am, ag, cm, cg = stats_series[ptr]
            out["army_minerals"].append(round(am, 1))
            out["army_gas"].append(round(ag, 1))
            out["collection_minerals"].append(round(cm, 1))
            out["collection_gas"].append(round(cg, 1))
        else:
            for k in out:
                out[k].append(None)
    return out


def _extract_timings(
    race: str,
    bldg_inits: dict[str, list[tuple[float, int]]],
    th_inits: list[tuple[float, int]],
    self_canceled_tags: set[int],
    morphs: dict[str, list[float]],
    upgrades: dict[str, float],
) -> dict[str, float | None]:
    """Compute canonical milestone timings (real-time seconds) for one player."""
    valid_th = sorted(sec for sec, tag in th_inits if tag not in self_canceled_tags)
    out: dict[str, float | None] = {}
    for key, _label, _kind, source, names, nth in TIMING_MILESTONES.get(race, ()):
        val: float | None = None
        if source == "th_expand":
            if len(valid_th) >= nth:
                val = valid_th[nth - 1]
        elif source == "bldg_init":
            ts = sorted(
                sec
                for nm in names
                for sec, tag in bldg_inits.get(nm, ())
                if tag not in self_canceled_tags
            )
            if len(ts) >= nth:
                val = ts[nth - 1]
        elif source == "morph":
            ts = sorted(sec for nm in names for sec in morphs.get(nm, ()))
            if len(ts) >= nth:
                val = ts[nth - 1]
        elif source == "upgrade":
            cands = [upgrades[nm] for nm in names if nm in upgrades]
            if cands:
                val = min(cands)
        out[key] = round(val, 1) if val is not None else None
    return out


def _friendly_upgrade_label(uname: str) -> str:
    if uname in UPGRADE_FRIENDLY_LABELS:
        return UPGRADE_FRIENDLY_LABELS[uname]
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", uname)
    s = re.sub(r"([A-Za-z])(\d+)$", r"\1 \2", s)
    return s.strip()


def _canon_combat_unit(ut: str) -> str:
    return CANONICAL_COMBAT_UNIT.get(ut, ut)


def _compute_army_fragmentation(
    combat_units: list[tuple[int, int, str, float, float, str]],
    cluster_radius: float = 14.0,
) -> tuple[float | None, int | None]:
    """
    Connected components at `cluster_radius` over alive combat units `(tag_idx, val, tier, x, y, ut)`.
    Requires >= 3 alive combat units. Returns `(fragmentation_pct, cluster_count)`:
      - fragmentation_pct = 100 * (total_val - largest_cluster_val) / total_val (lower = more cohesive)
      - cluster_count     = number of active clusters (>= 1)
    """
    n = len(combat_units)
    if n < 3:
        return None, None
    r2 = cluster_radius * cluster_radius
    parent = list(range(n))

    def _find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(n):
        xi, yi = combat_units[i][3], combat_units[i][4]
        for j in range(i + 1, n):
            dx = xi - combat_units[j][3]
            if dx > cluster_radius or dx < -cluster_radius:
                continue
            dy = yi - combat_units[j][4]
            if dx * dx + dy * dy <= r2:
                ri, rj = _find(i), _find(j)
                if ri != rj:
                    parent[rj] = ri

    comp_val: dict[int, int] = {}
    tot_val = 0
    for i in range(n):
        v = combat_units[i][1]
        tot_val += v
        r = _find(i)
        comp_val[r] = comp_val.get(r, 0) + v
    if tot_val <= 0:
        return None, None
    max_val = max(comp_val.values())
    frag_pct = round(100.0 * (tot_val - max_val) / tot_val, 1)
    return frag_pct, len(comp_val)


def _main_army_centroid(
    combat_units: list[tuple[int, int, str, float, float, str]],
    cluster_radius: float = 14.0,
    min_units: int = 4,
) -> tuple[float, float, int, int] | None:
    """
    Largest value-weighted connected component at `cluster_radius` over alive combat units.
    Requires the largest cluster to contain >= `min_units` combat units.
    Returns `(cx, cy, comp_val, comp_cnt)` or None.
    """
    n = len(combat_units)
    if n < min_units:
        return None
    r2 = cluster_radius * cluster_radius
    parent = list(range(n))

    def _find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for i in range(n):
        xi, yi = combat_units[i][3], combat_units[i][4]
        for j in range(i + 1, n):
            dx = xi - combat_units[j][3]
            if dx > cluster_radius or dx < -cluster_radius:
                continue
            dy = yi - combat_units[j][4]
            if dx * dx + dy * dy <= r2:
                ri, rj = _find(i), _find(j)
                if ri != rj:
                    parent[rj] = ri

    # Accumulate [val, cnt, wx, wy] per component
    comps: dict[int, list[float]] = {}
    for i in range(n):
        v = combat_units[i][1]
        x = combat_units[i][3]
        y = combat_units[i][4]
        r = _find(i)
        acc = comps.get(r)
        if acc is None:
            comps[r] = [float(v), 1.0, float(v) * x, float(v) * y]
        else:
            acc[0] += float(v)
            acc[1] += 1.0
            acc[2] += float(v) * x
            acc[3] += float(v) * y

    best = max(comps.values(), key=lambda a: (a[0], a[1]))
    if best[0] <= 0.0 or int(best[1]) < min_units:
        return None
    return (best[2] / best[0], best[3] / best[0], int(best[0]), int(best[1]))


def _sample_retention_at_buckets(
    ret_series: list[tuple[float, float, float]],
    buckets_sec: list[int],
    dur_sec: float,
    half_window: float = 15.0,
) -> list[float | None]:
    """Align `(sec, act_army, lost_army)` to `buckets_sec`, returning `act / (act + lost)` when cum >= 400."""
    out: list[float | None] = []
    n = len(ret_series)
    ptr = 0
    for t in buckets_sec:
        if dur_sec < float(t) or n == 0:
            out.append(None)
            continue
        tf = float(t)
        while ptr + 1 < n and abs(ret_series[ptr + 1][0] - tf) <= abs(ret_series[ptr][0] - tf):
            ptr += 1
        if abs(ret_series[ptr][0] - tf) <= half_window:
            _, act, lost = ret_series[ptr]
            cum = act + lost
            if cum >= 400.0:
                out.append(round(act / cum, 3))
            else:
                out.append(None)
        else:
            out.append(None)
    return out


def _compute_engage_retreat_clashes(
    deaths: list[tuple[float, int, int, float, float]],
    pos_snaps: list[tuple[float, dict[int, list[tuple[int, int, str, float, float, str]]]]],
    home_xy: dict[int, tuple[float, float]],
    th_lifetimes: dict[int, list[list[Any]]] | None = None,
) -> tuple[
    dict[int, list[list[Any]]],
    dict[int, list[list[Any]]],
    dict[int, list[float]],
]:
    """
    Shared clash analyzer for:
      - Graph 10: Local Force Ratio at `t_start - 4s` & Retreat/Disengage at `t_start + 10s`.
      - Graph 15: Concave Aspect Ratio, Front-to-Back Layering Delta & Splash-Clump Density at `t_start - 4s`.
      - Graph 16c: Off-Front Idle Combat Value Share (%) during major clashes.
    Returns `(clashes_by_pid, concave_by_pid, off_front_idle_by_pid)`.
    """
    out: dict[int, list[list[Any]]] = {1: [], 2: []}
    concave_out: dict[int, list[list[Any]]] = {1: [], 2: []}
    idle_out: dict[int, list[float]] = {1: [], 2: []}
    if not deaths or not pos_snaps:
        return out, concave_out, idle_out

    # Cluster chronological combat deaths into spatial-temporal clashes (10s window, 18t radius)
    clashes: list[dict[str, Any]] = []
    for sec, pid, val, dx, dy in deaths:
        placed = False
        for c in reversed(clashes):
            if sec - c["t_end"] > 10.0:
                break
            if math.hypot(dx - c["cx"], dy - c["cy"]) <= 18.0:
                cnt = c["cnt"]
                c["cx"] = (c["cx"] * cnt + dx) / (cnt + 1)
                c["cy"] = (c["cy"] * cnt + dy) / (cnt + 1)
                c["cnt"] = cnt + 1
                c["val"] += val
                c["t_end"] = sec
                placed = True
                break
        if not placed:
            clashes.append({
                "t_start": sec,
                "t_end": sec,
                "cx": dx,
                "cy": dy,
                "cnt": 1,
                "val": val,
            })

    # Pre-index snap times for fast lookup
    snap_times = [s[0] for s in pos_snaps]
    n_snaps = len(snap_times)

    def _nearest_snap(target_t: float, lo_dt: float, hi_dt: float) -> int | None:
        lo, hi = 0, n_snaps - 1
        while lo < hi:
            mid = (lo + hi) // 2
            if snap_times[mid] < target_t:
                lo = mid + 1
            else:
                hi = mid
        best_i = None
        best_err = float("inf")
        for cand in (lo - 1, lo, lo + 1):
            if 0 <= cand < n_snaps:
                dt_val = snap_times[cand] - target_t
                if lo_dt <= dt_val <= hi_dt and abs(dt_val) < best_err:
                    best_err = abs(dt_val)
                    best_i = cand
        return best_i

    for c in clashes:
        if c["val"] < 400 and c["cnt"] < 3:
            continue
        t0 = c["t_start"]
        cx, cy = c["cx"], c["cy"]
        # Snapshot at t_start - 4s (tolerance [-10s, +6s] around t_start - 4s)
        bi = _nearest_snap(t0 - 4.0, -10.0, 6.0)
        if bi is None:
            continue
        # Snapshot at t_start + 10s (tolerance [-4s, +6s] around t_start + 10s)
        ai = _nearest_snap(t0 + 10.0, -4.0, 6.0)

        t_snap = pos_snaps[bi][0]
        before_map = pos_snaps[bi][1]
        after_map = pos_snaps[ai][1] if ai is not None else None

        # (tidx, uval, ux, uy, ut, dist_c)
        local_units: dict[int, list[tuple[int, int, float, float, str, float]]] = {1: [], 2: []}
        local_val: dict[int, int] = {1: 0, 2: 0}
        for p in (1, 2):
            for tidx, uval, _tier, ux, uy, ut in before_map.get(p, ()):
                dc = math.hypot(ux - cx, uy - cy)
                if dc <= 22.0:
                    local_units[p].append((tidx, uval, ux, uy, ut, dc))
                    local_val[p] += uval

        if local_val[1] < 200 or local_val[2] < 200:
            continue

        for p in (1, 2):
            opp = 2 if p == 1 else 1
            # --- Graph 10: Local Force Ratio & Disengage ---
            ratio = local_val[p] / float(local_val[opp])
            disengaged = 0
            if after_map is not None and p in home_xy:
                hx, hy = home_xy[p]
                after_by_idx = {u[0]: (u[1], u[3], u[4]) for u in after_map.get(p, ())}
                surv_val = 0
                pullbacks: list[float] = []
                for tidx, uval, ux0, uy0, _ut, _dc in local_units[p]:
                    hit = after_by_idx.get(tidx)
                    if hit is not None:
                        surv_val += uval
                        d0 = math.hypot(ux0 - hx, uy0 - hy)
                        d1 = math.hypot(hit[1] - hx, hit[2] - hy)
                        pullbacks.append(d0 - d1)
                if surv_val >= 0.50 * local_val[p] and pullbacks:
                    mean_pb = sum(pullbacks) / len(pullbacks)
                    if mean_pb >= 8.0:
                        disengaged = 1
            out[p].append([round(min(ratio, 9.99), 3), disengaged])

            # --- Graph 15: Concave Aspect, Front-to-Back Layering & Splash-Clump ---
            own_16 = [u for u in local_units[p] if u[5] <= 16.0]
            opp_22 = local_units[opp]
            if len(own_16) >= 4 and len(opp_22) >= 2:
                n_own = len(own_16)
                n_opp = len(opp_22)
                ox = sum(u[2] for u in own_16) / n_own
                oy = sum(u[3] for u in own_16) / n_own
                ex = sum(u[2] for u in opp_22) / n_opp
                ey = sum(u[3] for u in opp_22) / n_opp
                vx, vy = ex - ox, ey - oy
                vnorm = math.hypot(vx, vy)
                aspect: float | None = None
                if vnorm >= 1.0:
                    ax, ay = vx / vnorm, vy / vnorm
                    px, py = -ay, ax
                    sum_d2 = 0.0
                    sum_l2 = 0.0
                    for u in own_16:
                        dx = u[2] - ox
                        dy = u[3] - oy
                        d_proj = dx * ax + dy * ay
                        l_proj = dx * px + dy * py
                        sum_d2 += d_proj * d_proj
                        sum_l2 += l_proj * l_proj
                    depth_std = math.sqrt(sum_d2 / n_own)
                    lat_std = math.sqrt(sum_l2 / n_own)
                    aspect = round(min(lat_std / max(0.75, depth_std), 12.0), 3)

                front = [u for u in own_16 if u[4] in FRONTLINE_LAYER_UNITS]
                back = [u for u in own_16 if u[4] in BACKLINE_LAYER_UNITS]
                layer_delta: float | None = None
                if front and back:
                    df = sum(math.hypot(u[2] - ex, u[3] - ey) for u in front) / len(front)
                    db = sum(math.hypot(u[2] - ex, u[3] - ey) for u in back) / len(back)
                    layer_delta = round(df - db, 2)

                clumped = 0
                for i in range(n_own):
                    xi, yi = own_16[i][2], own_16[i][3]
                    nbrs = 0
                    for j in range(n_own):
                        if i == j:
                            continue
                        dx = xi - own_16[j][2]
                        if dx > 2.5 or dx < -2.5:
                            continue
                        dy = yi - own_16[j][3]
                        if dx * dx + dy * dy <= 6.25:
                            nbrs += 1
                            if nbrs >= 3:
                                clumped += 1
                                break
                clump_pct = round(100.0 * clumped / n_own, 1)
                concave_out[p].append([aspect, layer_delta, clump_pct])

            # --- Graph 16c: Off-Front Idle Combat Value Share (%) ---
            all_own = before_map.get(p, ())
            tot_v = sum(u[1] for u in all_own)
            if tot_v >= 400:
                opp_ths = [
                    (th[2], th[3])
                    for th in (th_lifetimes or {}).get(opp, ())
                    if th[0] <= t_snap <= th[1]
                ]
                idle_v = 0
                for _tidx, uval, _tier, ux, uy, _ut in all_own:
                    if math.hypot(ux - cx, uy - cy) > 22.0:
                        if all(math.hypot(ux - tx, uy - ty) > 22.0 for tx, ty in opp_ths):
                            idle_v += uval
                idle_out[p].append(round(100.0 * idle_v / tot_v, 1))

    return out, concave_out, idle_out


def _compute_rotations_and_multiprong(
    all_deaths: list[tuple[float, int, int, bool, bool, bool, float, float]],
    pos_snaps: list[tuple[float, dict[int, list[tuple[int, int, str, float, float, str]]]]],
    th_lifetimes: dict[int, list[list[Any]]],
    home_xy: dict[int, tuple[float, float]],
    dur_sec: float,
) -> dict[int, dict[str, Any]]:
    """
    Computes Graph 16a/16b (Defensive Rotation Latency/Response & Offensive Base-to-Base Rotations)
    and Graph 17a/17b (Multiprong Pressure & Counter-Backstabs / Runbys) for both players.
    `all_deaths`: chronological list of enemy-inflicted kills
                  `(sec, victim_pid, val, is_worker, is_combat, is_struct, x, y)`.
    """
    out: dict[int, dict[str, Any]] = {
        1: {"def_rotations": [], "off_rot_count": 0, "mp_count": 0, "bs_count": 0, "bs_wk_kills": []},
        2: {"def_rotations": [], "off_rot_count": 0, "mp_count": 0, "bs_count": 0, "bs_wk_kills": []},
    }
    if not all_deaths or not pos_snaps:
        return out

    snap_times = [s[0] for s in pos_snaps]
    n_snaps = len(snap_times)
    centroid_cache: dict[tuple[int, int], tuple[float, float, int, int] | None] = {}

    def _get_mc(si: int, pid: int) -> tuple[float, float, int, int] | None:
        key = (si, pid)
        if key not in centroid_cache:
            centroid_cache[key] = _main_army_centroid(pos_snaps[si][1].get(pid, ()), 14.0, 4)
        return centroid_cache[key]

    def _nearest_snap(target_t: float, lo_dt: float, hi_dt: float) -> int | None:
        lo, hi = 0, n_snaps - 1
        while lo < hi:
            mid = (lo + hi) // 2
            if snap_times[mid] < target_t:
                lo = mid + 1
            else:
                hi = mid
        best_i = None
        best_err = float("inf")
        for cand in (lo - 1, lo, lo + 1):
            if 0 <= cand < n_snaps:
                dt_val = snap_times[cand] - target_t
                if lo_dt <= dt_val <= hi_dt and abs(dt_val) < best_err:
                    best_err = abs(dt_val)
                    best_i = cand
        return best_i

    def _match_nearest_th(pid_owner: int, sec: float, x: float, y: float, max_r: float) -> int | None:
        ths = th_lifetimes.get(pid_owner, ())
        best_id = None
        best_d = max_r + 1e-6
        for idx, th in enumerate(ths):
            if th[0] <= sec <= th[1] + 2.0:
                d = math.hypot(x - th[2], y - th[3])
                if d <= best_d:
                    best_d = d
                    best_id = idx
        return best_id

    for p in (1, 2):
        opp = 2 if p == 1 else 1
        my_ths = th_lifetimes.get(p, ())
        opp_ths = th_lifetimes.get(opp, ())

        # --- Graph 16a: Defensive Rotation Latency & Response Rate ---
        def_by_th: dict[int, list[tuple[float, int]]] = defaultdict(list)
        for sec, vpid, val, _iw, _ic, _is, dx, dy in all_deaths:
            if vpid != p:
                continue
            tid = _match_nearest_th(p, sec, dx, dy, 18.0)
            if tid is not None:
                def_by_th[tid].append((sec, val))

        for tid, evs in def_by_th.items():
            bx, by = my_ths[tid][2], my_ths[tid][3]
            q: list[tuple[float, int]] = []
            q_val = 0
            last_trig = -999.0
            for sec, val in evs:
                q.append((sec, val))
                q_val += val
                while q and sec - q[0][0] > 10.0:
                    _, old_v = q.pop(0)
                    q_val -= old_v
                if (len(q) >= 2 or q_val >= 150) and (sec - last_trig >= 30.0):
                    t_hit = sec
                    last_trig = sec
                    if dur_sec - t_hit < 15.0:
                        continue
                    si = _nearest_snap(t_hit, -6.0, 3.0)
                    if si is None:
                        continue
                    mc0 = _get_mc(si, p)
                    if mc0 is None:
                        continue
                    d0 = math.hypot(mc0[0] - bx, mc0[1] - by)
                    if d0 < 25.0:
                        continue
                    responded = 0
                    lat: float | None = None
                    for sj in range(si + 1, n_snaps):
                        dt_s = snap_times[sj] - t_hit
                        if dt_s > 45.0:
                            break
                        mc = _get_mc(sj, p)
                        if mc is not None:
                            d = math.hypot(mc[0] - bx, mc[1] - by)
                            if d <= 18.0 or (d0 - d) >= 10.0:
                                responded = 1
                                lat = round(max(0.0, dt_s), 1)
                                break
                    out[p]["def_rotations"].append([responded, lat])

        # --- Graph 16b: Offensive Base-to-Base Rotation Rate ---
        off_by_th: dict[int, list[tuple[float, int]]] = defaultdict(list)
        for sec, vpid, val, _iw, _ic, _is, dx, dy in all_deaths:
            if vpid != opp:
                continue
            tid = _match_nearest_th(opp, sec, dx, dy, 18.0)
            if tid is not None:
                off_by_th[tid].append((sec, val))

        base_hits: list[tuple[float, int, float, float]] = []
        for tid, evs in off_by_th.items():
            bx, by = opp_ths[tid][2], opp_ths[tid][3]
            q = []
            q_val = 0
            last_hit = -999.0
            for sec, val in evs:
                q.append((sec, val))
                q_val += val
                while q and sec - q[0][0] > 10.0:
                    _, old_v = q.pop(0)
                    q_val -= old_v
                if (len(q) >= 2 or q_val >= 150) and (sec - last_hit >= 15.0):
                    base_hits.append((sec, tid, bx, by))
                    last_hit = sec

        base_hits.sort(key=lambda x: x[0])
        off_rot_cnt = 0
        last_rot_t = -999.0
        for j in range(1, len(base_hits)):
            t2, b2, x2, y2 = base_hits[j]
            if t2 - last_rot_t < 25.0:
                continue
            for i in range(j - 1, -1, -1):
                t1, b1, x1, y1 = base_hits[i]
                dt_h = t2 - t1
                if dt_h > 45.0:
                    break
                if dt_h >= 2.0 and b2 != b1 and math.hypot(x2 - x1, y2 - y1) >= 25.0:
                    off_rot_cnt += 1
                    last_rot_t = t2
                    break
        out[p]["off_rot_count"] = off_rot_cnt

        # --- Graph 17a: Multiprong Pressure (Enemy-Half Simultaneous Prongs) ---
        if p in home_xy and opp in home_xy:
            mhx, mhy = home_xy[p]
            ohx, ohy = home_xy[opp]
            pockets: list[dict[str, Any]] = []
            for sec, vpid, val, _iw, _ic, _is, dx, dy in all_deaths:
                if vpid != opp:
                    continue
                if math.hypot(dx - ohx, dy - ohy) >= math.hypot(dx - mhx, dy - mhy):
                    continue
                placed = False
                for pk in reversed(pockets):
                    if sec - pk["t_end"] > 15.0:
                        break
                    if math.hypot(dx - pk["cx"], dy - pk["cy"]) <= 18.0:
                        cnt = pk["cnt"]
                        pk["cx"] = (pk["cx"] * cnt + dx) / (cnt + 1)
                        pk["cy"] = (pk["cy"] * cnt + dy) / (cnt + 1)
                        pk["cnt"] = cnt + 1
                        pk["val"] += val
                        pk["t_end"] = sec
                        placed = True
                        break
                if not placed:
                    pockets.append({
                        "t_start": sec,
                        "t_end": sec,
                        "cx": dx,
                        "cy": dy,
                        "cnt": 1,
                        "val": val,
                    })
            qual_pks = [pk for pk in pockets if pk["cnt"] >= 2 or pk["val"] >= 150]
            qual_pks.sort(key=lambda pk: pk["t_start"])
            mp_cnt = 0
            last_mp_t = -999.0
            for j in range(1, len(qual_pks)):
                pj = qual_pks[j]
                if pj["t_start"] - last_mp_t < 25.0:
                    continue
                for i in range(j - 1, -1, -1):
                    pi = qual_pks[i]
                    if pj["t_start"] - pi["t_end"] > 15.0:
                        if pj["t_start"] - pi["t_start"] > 60.0:
                            break
                        continue
                    if math.hypot(pj["cx"] - pi["cx"], pj["cy"] - pi["cy"]) >= 25.0:
                        mp_cnt += 1
                        last_mp_t = pj["t_start"]
                        break
            out[p]["mp_count"] = mp_cnt

        # --- Graph 17b: Counter-Backstabs / Runbys (Enemy Main Army >= 30t Away) ---
        bs_by_th: dict[int, list[tuple[float, int, bool]]] = defaultdict(list)
        for sec, vpid, val, is_wk, _ic, is_st, dx, dy in all_deaths:
            if vpid != opp or not (is_wk or is_st):
                continue
            tid = _match_nearest_th(opp, sec, dx, dy, 16.0)
            if tid is not None:
                bs_by_th[tid].append((sec, val, is_wk))

        bs_cnt = 0
        bs_wks: list[int] = []
        for tid, evs in bs_by_th.items():
            bx, by = opp_ths[tid][2], opp_ths[tid][3]
            # Group into consecutive episodes (gap <= 12.0s)
            eps: list[list[Any]] = []
            for sec, val, is_wk in evs:
                if eps and (sec - eps[-1][1]) <= 12.0:
                    eps[-1][1] = sec
                    eps[-1][2] += 1 if is_wk else 0
                    eps[-1][3] += 1
                    eps[-1][4] += val
                else:
                    eps.append([sec, sec, 1 if is_wk else 0, 1, val])
            last_bs_t = -999.0
            for t_start, _t_end, wk_k, tot_k, tot_v in eps:
                if wk_k < 1 and tot_k < 2 and tot_v < 150:
                    continue
                if t_start - last_bs_t < 25.0:
                    continue
                si = _nearest_snap(t_start, -6.0, 4.0)
                if si is None:
                    continue
                emc = _get_mc(si, opp)
                if emc is None:
                    continue
                if math.hypot(emc[0] - bx, emc[1] - by) >= 30.0:
                    bs_cnt += 1
                    bs_wks.append(wk_k)
                    last_bs_t = t_start
        out[p]["bs_count"] = bs_cnt
        out[p]["bs_wk_kills"] = bs_wks

    return out


# -----------------------------------------------------------------------------
# Graph 18: Pure-Python Deterministic Cosine K-Means Archetype Clustering
# -----------------------------------------------------------------------------
def _l2_normalize_vec(d: dict[str, float]) -> dict[str, float]:
    nrm = math.sqrt(sum(v * v for v in d.values()))
    if nrm <= 1e-12:
        return {}
    return {k: v / nrm for k, v in d.items() if v > 0.0}


def _vec_cosine(a: dict[str, float], b: dict[str, float]) -> float:
    if not a or not b:
        return 0.0
    if len(a) > len(b):
        a, b = b, a
    return sum(v * b.get(k, 0.0) for k, v in a.items())


def _game_comp_vector_6_16m(
    unit_comp_b: list[dict[str, int] | None] | None,
) -> tuple[dict[str, float], dict[str, float]]:
    """
    Build normalized (L1_share_dict, L2_unit_vec) across 6m..16m (BUCKETS_TIER_SEC indices 2..7),
    excluding non-defining utility units (Queen/Observer/WarpPrism) with fallback to full units.
    """
    if not unit_comp_b:
        return {}, {}
    acc_core: dict[str, float] = defaultdict(float)
    acc_all: dict[str, float] = defaultdict(float)
    n_core = 0
    n_all = 0
    for idx in range(2, min(8, len(unit_comp_b))):  # 6m, 8m, 10m, 12m, 14m, 16m
        snap = unit_comp_b[idx]
        if not snap:
            continue
        tot_all = sum(snap.values())
        if tot_all > 0:
            n_all += 1
            for u, v in snap.items():
                acc_all[u] += v / float(tot_all)
        core_items = [(u, v) for u, v in snap.items() if u not in CLUSTER_UTILITY_UNITS]
        tot_core = sum(v for _, v in core_items)
        if tot_core > 0:
            n_core += 1
            for u, v in core_items:
                acc_core[u] += v / float(tot_core)

    if n_core > 0:
        l1 = {u: v / float(n_core) for u, v in acc_core.items() if v > 0.0}
    elif n_all > 0:
        l1 = {u: v / float(n_all) for u, v in acc_all.items() if v > 0.0}
    else:
        return {}, {}
    return l1, _l2_normalize_vec(l1)


def _kmeans_cosine_cluster(
    vecs: list[dict[str, float]],
    k: int,
    seed: int,
    min_size: int = 4,
    restarts: int = 12,
    max_iter: int = 40,
) -> tuple[list[int], list[dict[str, float]], float] | None:
    """Deterministic k-means++ spherical k-means on L2-normalized sparse unit dicts."""
    n = len(vecs)
    if n < k * min_size or k < 1:
        return None
    if k == 1:
        mean_v: dict[str, float] = defaultdict(float)
        for v in vecs:
            for u, val in v.items():
                mean_v[u] += val
        c0 = _l2_normalize_vec(mean_v)
        obj = sum(_vec_cosine(v, c0) for v in vecs)
        return [0] * n, [c0], obj

    rng = random.Random(seed)
    best_res: tuple[list[int], list[dict[str, float]], float] | None = None

    for _ in range(restarts):
        # k-means++ initialization on cosine distance (1 - cos)
        first = rng.randrange(n)
        centroids = [dict(vecs[first])]
        for _ci in range(1, k):
            weights = []
            tot_w = 0.0
            for v in vecs:
                d_min = min(max(0.0, 1.0 - _vec_cosine(v, c)) for c in centroids)
                w = d_min * d_min + 1e-9
                weights.append(w)
                tot_w += w
            pick = rng.random() * tot_w
            acc = 0.0
            chosen = n - 1
            for idx, w in enumerate(weights):
                acc += w
                if acc >= pick:
                    chosen = idx
                    break
            centroids.append(dict(vecs[chosen]))

        assigns = [-1] * n
        for _it in range(max_iter):
            changed = False
            for i, v in enumerate(vecs):
                best_c = 0
                best_s = -2.0
                for ci, c in enumerate(centroids):
                    s = _vec_cosine(v, c)
                    if s > best_s:
                        best_s = s
                        best_c = ci
                if assigns[i] != best_c:
                    assigns[i] = best_c
                    changed = True
            if not changed:
                break
            sums: list[dict[str, float]] = [defaultdict(float) for _ in range(k)]
            cnts = [0] * k
            for i, ci in enumerate(assigns):
                cnts[ci] += 1
                for u, val in vecs[i].items():
                    sums[ci][u] += val
            for ci in range(k):
                if cnts[ci] > 0:
                    centroids[ci] = _l2_normalize_vec(sums[ci])

        counts = [0] * k
        for ci in assigns:
            counts[ci] += 1
        if min(counts) < min_size:
            continue
        obj = sum(_vec_cosine(vecs[i], centroids[assigns[i]]) for i in range(n))
        if best_res is None or obj > best_res[2]:
            best_res = (list(assigns), [dict(c) for c in centroids], obj)

    return best_res


def _cosine_silhouette(vecs: list[dict[str, float]], assigns: list[int], k: int) -> float:
    n = len(vecs)
    if k < 2 or n <= k:
        return -1.0
    by_c: dict[int, list[int]] = defaultdict(list)
    for i, c in enumerate(assigns):
        by_c[c].append(i)
    scores: list[float] = []
    for i in range(n):
        ci = assigns[i]
        own = by_c[ci]
        if len(own) <= 1:
            scores.append(0.0)
            continue
        a_i = sum(max(0.0, 1.0 - _vec_cosine(vecs[i], vecs[j])) for j in own if j != i) / (len(own) - 1)
        b_i = float("inf")
        for cj, idxs in by_c.items():
            if cj == ci or not idxs:
                continue
            d_cj = sum(max(0.0, 1.0 - _vec_cosine(vecs[i], vecs[j])) for j in idxs) / len(idxs)
            if d_cj < b_i:
                b_i = d_cj
        denom = max(a_i, b_i)
        scores.append((b_i - a_i) / denom if denom > 1e-12 else 0.0)
    return sum(scores) / len(scores) if scores else -1.0


def _auto_label_clusters(clusters_l1: list[dict[str, float]]) -> list[str]:
    """Generate clean, unique human-readable SC2 archetype labels from top 2-3 signature units."""
    def _short(u: str) -> str:
        return CANONICAL_UNIT_SHORT.get(u, u)

    raw_labels: list[str] = []
    ranked_lists: list[list[tuple[str, float]]] = []
    for l1 in clusters_l1:
        items = sorted(l1.items(), key=lambda kv: (-kv[1], kv[0]))
        ranked_lists.append(items)
        # Check for Skytoss signature (Carrier/Tempest/VoidRay/Phoenix >= 45% combined)
        skytoss_share = sum(l1.get(u, 0.0) for u in ("Carrier", "Tempest", "VoidRay", "Phoenix", "Mothership"))
        chosen: list[str] = []
        for u, sh in items:
            if len(chosen) < 3 and (sh >= 0.12 or (len(chosen) < 2 and sh >= 0.08)):
                chosen.append(_short(u))
        if not chosen and items:
            chosen = [_short(items[0][0])]
        lbl = "-".join(chosen) if chosen else "Mixed"
        if skytoss_share >= 0.45 and "Carrier" not in lbl and "Tempest" not in lbl:
            lbl = f"Skytoss ({lbl})"
        elif skytoss_share >= 0.50 and ("Carrier" in lbl or "Tempest" in lbl):
            lbl = f"Skytoss ({lbl})"
        raw_labels.append(lbl)

    # Disambiguate any duplicate labels using the unit with largest positive delta vs peer clusters
    counts: dict[str, int] = defaultdict(int)
    for lbl in raw_labels:
        counts[lbl] += 1

    final_labels: list[str] = []
    for idx, lbl in enumerate(raw_labels):
        if counts[lbl] <= 1:
            final_labels.append(lbl)
            continue
        # Find best distinguishing unit not already in label
        peers = [clusters_l1[j] for j in range(len(clusters_l1)) if j != idx and raw_labels[j] == lbl]
        best_u = None
        best_diff = -999.0
        for u, sh in ranked_lists[idx]:
            su = _short(u)
            if su in lbl.split("-"):
                continue
            peer_mean = sum(p.get(u, 0.0) for p in peers) / max(1, len(peers))
            diff = sh - peer_mean
            if diff > best_diff and sh >= 0.05:
                best_diff = diff
                best_u = su
        if best_u is not None:
            final_labels.append(f"{lbl}+{best_u}")
        else:
            final_labels.append(f"{lbl} #{idx + 1}")
    return final_labels


def _bin_force_ratio(r: float) -> str:
    for label, lo, hi in FORCE_RATIO_BINS:
        if lo <= r < hi:
            return label
    return FORCE_RATIO_BINS[-1][0]


def _simulate_macro_energy(
    caster_lifetimes: list[tuple[float, float, int, float]],
    cast_events: list[tuple[float, str, float, tuple[int, ...], str | None, bool]],
    dur_sec: float,
) -> dict[str, Any]:
    """
    Graph 21 exact LotV Faster energy pool simulator for Nexus / OrbitalCommand / Queen.
    `caster_lifetimes`: [(born_sec, died_sec, uidx, start_energy), ...]
    `cast_events`: [(sec, abil_key, cost_energy, pref_uidxs, target_bucket, is_tracker_truth), ...]
    Returns energy efficiency, % time capped >=180e, 0..18m mean energy curve, and
    physically validated cast counts/timestamps for Graph 20 consistency.
    """
    n_b = len(BUCKETS_18M_SEC)
    mean_curve: list[float | None] = [None] * n_b
    accepted_times: dict[str, list[float]] = defaultdict(list)
    accepted_chrono_targets: dict[str, int] = defaultdict(int)
    accepted_chrono_events: list[tuple[float, str]] = []

    if not caster_lifetimes:
        return {
            "alive_sec": 0.0,
            "spend_efficiency_pct": None,
            "time_capped_180_pct": None,
            "mean_energy_overall": None,
            "mean_energy_curve_18m": mean_curve,
            "accepted_times": dict(accepted_times),
            "accepted_chrono_targets": dict(accepted_chrono_targets),
            "accepted_chrono_events": accepted_chrono_events,
        }

    # Build unified sorted timeline: (t, prio, kind, payload)
    # prio: 0=born, 1=sample, 2=cast, 3=died, 4=end
    timeline: list[tuple[float, int, str, Any]] = []
    for born_s, died_s, uidx, start_e in caster_lifetimes:
        bs = max(0.0, min(born_s, dur_sec))
        timeline.append((bs, 0, "born", (uidx, start_e)))
        if died_s < dur_sec:
            timeline.append((max(bs, died_s), 3, "died", uidx))
    for b_idx, tb in enumerate(BUCKETS_18M_SEC):
        if float(tb) <= dur_sec:
            timeline.append((float(tb), 1, "sample", b_idx))
    for ev in cast_events:
        if 0.0 <= ev[0] <= dur_sec:
            timeline.append((ev[0], 2, "cast", ev))
    timeline.append((dur_sec, 4, "end", None))
    timeline.sort(key=lambda x: (x[0], x[1]))

    alive: dict[int, float] = {}
    prev_t = 0.0
    total_alive_sec = 0.0
    total_generated = 0.0
    total_spent = 0.0
    capped_sec = 0.0
    energy_sec_int = 0.0

    def _advance(t_now: float) -> None:
        nonlocal prev_t, total_alive_sec, total_generated, capped_sec, energy_sec_int
        dt_s = t_now - prev_t
        if dt_s > 0.0 and alive:
            gen_step = dt_s * ENERGY_REGEN_PER_SEC
            for u, e0 in alive.items():
                e_raw = e0 + gen_step
                e1 = ENERGY_CAP if e_raw > ENERGY_CAP else e_raw
                total_alive_sec += dt_s
                total_generated += gen_step
                if e0 >= ENERGY_CAPPED_THRESH:
                    capped_sec += dt_s
                elif e1 >= ENERGY_CAPPED_THRESH:
                    t_hit = (ENERGY_CAPPED_THRESH - e0) / ENERGY_REGEN_PER_SEC
                    if dt_s > t_hit:
                        capped_sec += dt_s - t_hit
                if e_raw <= ENERGY_CAP:
                    energy_sec_int += 0.5 * (e0 + e1) * dt_s
                else:
                    t_cap = max(0.0, (ENERGY_CAP - e0) / ENERGY_REGEN_PER_SEC)
                    energy_sec_int += 0.5 * (e0 + ENERGY_CAP) * t_cap + ENERGY_CAP * max(0.0, dt_s - t_cap)
                alive[u] = e1
        prev_t = t_now

    for t_now, _prio, kind, payload in timeline:
        _advance(t_now)
        if kind == "born":
            uidx, start_e = payload
            alive[uidx] = start_e
            total_generated += start_e
        elif kind == "died":
            alive.pop(payload, None)
        elif kind == "sample":
            if alive:
                mean_curve[payload] = round(sum(alive.values()) / len(alive), 1)
        elif kind == "cast":
            sec_c, abil_key, cost_e, pref_uidxs, tgt_bkt, is_truth = payload
            chosen_u: int | None = None
            best_e = -1.0
            # Prefer selected caster with highest energy >= cost - 4.0
            for pu in pref_uidxs:
                ev_u = alive.get(pu)
                if ev_u is not None and ev_u >= cost_e - 4.0 and ev_u > best_e:
                    best_e = ev_u
                    chosen_u = pu
            if chosen_u is None and alive:
                for u, ev_u in alive.items():
                    if ev_u >= cost_e - 4.0 and ev_u > best_e:
                        best_e = ev_u
                        chosen_u = u
            if chosen_u is not None:
                alive[chosen_u] = max(0.0, alive[chosen_u] - cost_e)
                total_spent += cost_e
                accepted_times[abil_key].append(sec_c)
                if abil_key == "chrono_boost" and tgt_bkt is not None:
                    accepted_chrono_targets[tgt_bkt] += 1
                    accepted_chrono_events.append((sec_c, tgt_bkt))
            elif is_truth:
                # Tracker-verified cast (MULE / CreepTumorQueen): always record & drain highest alive
                if alive:
                    top_u = max(alive.keys(), key=lambda u: alive[u])
                    alive[top_u] = max(0.0, alive[top_u] - cost_e)
                    total_spent += cost_e
                accepted_times[abil_key].append(sec_c)

    if total_alive_sec < 30.0 or total_generated <= 0.0:
        eff_pct = None
        cap_pct = None
        mean_e = None
    else:
        eff_pct = round(100.0 * min(total_spent, total_generated) / total_generated, 1)
        cap_pct = round(100.0 * min(capped_sec, total_alive_sec) / total_alive_sec, 1)
        mean_e = round(energy_sec_int / total_alive_sec, 1)

    return {
        "alive_sec": round(total_alive_sec, 1),
        "spend_efficiency_pct": eff_pct,
        "time_capped_180_pct": cap_pct,
        "mean_energy_overall": mean_e,
        "mean_energy_curve_18m": mean_curve,
        "accepted_times": dict(accepted_times),
        "accepted_chrono_targets": dict(accepted_chrono_targets),
        "accepted_chrono_events": accepted_chrono_events,
    }


def _macro_phase_label(sec: float) -> str:
    for lbl, lo, hi in MACRO_PHASES:
        if lo <= sec < hi:
            return lbl
    return MACRO_PHASES[-1][0]


def _has_event_near(sorted_ts: list[float], t: float, half_win: float = 20.0) -> bool:
    """Binary search check whether any timestamp in sorted_ts falls in [t - half_win, t + half_win]."""
    n = len(sorted_ts)
    if n == 0:
        return False
    lo, hi = 0, n
    target = t - half_win
    while lo < hi:
        mid = (lo + hi) // 2
        if sorted_ts[mid] < target:
            lo = mid + 1
        else:
            hi = mid
    return lo < n and sorted_ts[lo] <= t + half_win


def _cum_counts_18m(times: list[float], dur_sec: float) -> list[int | None]:
    """Build cumulative cast count curve at BUCKETS_18M_SEC (0:00..18:00), None after dur_sec."""
    if not times:
        return [0 if dur_sec >= float(t) else None for t in BUCKETS_18M_SEC]
    ts = sorted(times)
    out: list[int | None] = []
    ptr = 0
    n = len(ts)
    for t in BUCKETS_18M_SEC:
        if dur_sec < float(t):
            out.append(None)
            continue
        tf = float(t)
        while ptr < n and ts[ptr] <= tf:
            ptr += 1
        out.append(ptr)
    return out


def _decode_game_events_metrics(
    proto: Any,
    ge_bytes: bytes,
    uid_to_pid: dict[int, int],
    target_pids: tuple[int, ...],
    buckets_sec: list[int],
    bucket_sec: int,
    dur_sec: float,
    race_by_pid: dict[int, str] | None = None,
    base_build: int = 75689,
    tag_ut: dict[int, str] | None = None,
    tag_own: dict[int, int] | None = None,
) -> tuple[bool, dict[int, dict[str, Any]]]:
    """
    Single linear pass over replay.game.events decoding:
      - Graphs 1-3: APM, EPM, SPM per-bucket curves & game-level rates
      - Graph 20/21: Deduplicated macro ability casts (Chrono+Targets, Energy Recharge,
        Recall, Battery Overcharge, Scan, Supply Drop, Inject, Transfuse)
      - Graph 22: Deduplicated SCmdEvent combat spell casts across all LotV patches
    Returns `(ok, per_pid_dict)`. If s2protocol raises, returns `(False, {})`.
    """
    n_buckets = len(buckets_sec)
    bucket_loops = int(round(bucket_sec * GAME_LOOPS_PER_SEC))
    max_bucket_idx = n_buckets - 1
    hi = base_build >= 80000
    r_by_p = race_by_pid or {}
    t_ut = tag_ut or {}
    t_own = tag_own or {}

    apm_b: dict[int, list[int]] = {p: [0] * n_buckets for p in target_pids}
    epm_b: dict[int, list[int]] = {p: [0] * n_buckets for p in target_pids}
    spm_b: dict[int, list[int]] = {p: [0] * n_buckets for p in target_pids}
    apm_tot: dict[int, int] = {p: 0 for p in target_pids}
    epm_tot: dict[int, int] = {p: 0 for p in target_pids}
    spm_tot: dict[int, int] = {p: 0 for p in target_pids}

    # Per-player EPM, SPM & control-group (0..9 + active 10) rolling state
    cgroups: dict[int, dict[int, list[int]]] = {
        p: {g: [] for g in range(11)} for p in target_pids
    }
    last_cmd_gl: dict[int, dict[tuple[Any, ...], int]] = {p: {} for p in target_pids}
    last_sel_sig: dict[int, Any] = {p: None for p in target_pids}
    last_sel_gl: dict[int, int] = {p: -9999 for p in target_pids}
    last_cam: dict[int, tuple[int, float, float] | None] = {p: None for p in target_pids}

    # Graphs 20-22 per-player macro casts & combat spell counts (cooldown-deduplicated)
    # macro_casts[pid]: list of (sec, abil_key, pref_uidxs, target_bucket_or_None)
    macro_casts: dict[int, list[tuple[float, str, tuple[int, ...], str | None]]] = {
        p: [] for p in target_pids
    }
    scmd_spells: dict[int, dict[str, int]] = {p: defaultdict(int) for p in target_pids}
    cd_map: dict[int, dict[Any, float]] = {p: {} for p in target_pids}
    supply_drop_depots: dict[int, set[int]] = {p: set() for p in target_pids}

    def _cd_ok(pid: int, key: Any, sec_now: float, cd_sec: float) -> bool:
        prev_s = cd_map[pid].get(key, -999.0)
        if sec_now - prev_s >= cd_sec:
            cd_map[pid][key] = sec_now
            return True
        return False

    def _pick_ready_caster(
        pid: int, sel_tags: list[int], unit_names: tuple[str, ...], abil_name: str, sec_now: float, cd_sec: float
    ) -> bool:
        matched_any = False
        for t in sel_tags[:24]:
            if t_ut.get(t) in unit_names:
                matched_any = True
                ckey = ("u", abil_name, t)
                if sec_now - cd_map[pid].get(ckey, -999.0) >= cd_sec:
                    cd_map[pid][ckey] = sec_now
                    return True
        if not matched_any:
            # Fallback if selection state was incomplete: per-player cooldown
            return _cd_ok(pid, ("p", abil_name), sec_now, cd_sec)
        return False

    def _classify_cmd_event(pid: int, gl: int, ev: dict[str, Any], sel_now: list[int]) -> None:
        ab = ev.get("m_abil")
        if not isinstance(ab, dict):
            return
        link = int(ab.get("m_abilLink", -1))
        idx = int(ab.get("m_abilCmdIndex", 0))
        race = r_by_p.get(pid)
        if not race:
            return
        sec_now = gl / GAME_LOOPS_PER_SEC
        mdata = ev.get("m_data") or {}

        has_pt = "TargetPoint" in mdata and isinstance(mdata["TargetPoint"], dict)
        has_u = "TargetUnit" in mdata and isinstance(mdata["TargetUnit"], dict)
        has_none = not has_pt and not has_u

        bx4 = by4 = bx2 = by2 = 0
        if has_pt:
            pt = mdata["TargetPoint"]
            px = float(pt.get("x", 0)) / 4096.0
            py = float(pt.get("y", 0)) / 4096.0
            bx4, by4 = int(px // 4.0), int(py // 4.0)
            bx2, by2 = int(px // 2.0), int(py // 2.0)

        ttag: int | None = None
        tut = ""
        trel = ""
        if has_u:
            ttag = mdata["TargetUnit"].get("m_tag")
            if ttag is not None:
                tut = t_ut.get(ttag, "")
                town = t_own.get(ttag, 0)
                trel = "self" if town == pid else ("enemy" if town in (1, 2) else "neut")

        if race == "Protoss":
            # Macro: Chrono Boost
            if link in CHRONO_ABIL_LINKS and idx == 0 and has_u and ttag is not None and trel == "self":
                bkt = PROTOSS_CHRONO_TARGET_BUCKET.get(tut)
                if bkt is not None:
                    if _cd_ok(pid, ("chrono_tgt", ttag), sec_now, 18.0):
                        pref = tuple(t >> 18 for t in sel_now[:16] if t_ut.get(t) == "Nexus")
                        macro_casts[pid].append((sec_now, "chrono_boost", pref, bkt))
                    return
            # Macro: Nexus Energy Recharge (5.0.14)
            if link in (730, 732) and idx == 0 and has_u and ttag is not None and trel == "self":
                if tut in PROTOSS_ENERGY_RECHARGE_TARGETS:
                    if _cd_ok(pid, "energy_recharge", sec_now, 55.0):
                        pref = tuple(t >> 18 for t in sel_now[:16] if t_ut.get(t) == "Nexus")
                        macro_casts[pid].append((sec_now, "energy_recharge", pref, None))
                    return
            # Macro: Battery Overcharge (for Nexus energy accounting)
            if link in (696, 698, 700) and idx == 0 and has_u and trel == "self" and tut == "ShieldBattery":
                if _cd_ok(pid, "battery_overcharge", sec_now, 55.0):
                    pref = tuple(t >> 18 for t in sel_now[:16] if t_ut.get(t) == "Nexus")
                    macro_casts[pid].append((sec_now, "battery_overcharge", pref, None))
                return
            # Macro + Combat: Nexus Mass Recall
            if link in (717, 723, 724) and idx == 0 and has_pt:
                if _cd_ok(pid, "recall", sec_now, 100.0):
                    pref = tuple(t >> 18 for t in sel_now[:16] if t_ut.get(t) == "Nexus")
                    macro_casts[pid].append((sec_now, "recall", pref, None))
                    scmd_spells[pid]["recall"] += 1
                return
            # Combat: Blink
            if link == (220 if hi else 218) and idx == 0 and has_pt:
                if _pick_ready_caster(pid, sel_now, ("Stalker",), "blink", sec_now, 6.0):
                    scmd_spells[pid]["blink"] += 1
                return
            # Combat: Guardian Shield
            if link == (73 if hi else 71) and idx == 0 and has_none:
                if _cd_ok(pid, "gshield_global", sec_now, 4.0) and _pick_ready_caster(
                    pid, sel_now, ("Sentry",), "guardian_shield", sec_now, 12.0
                ):
                    scmd_spells[pid]["guardian_shield"] += 1
                return
            # Combat: Hallucination
            if link in ((84, 80) if hi else (82, 78)) and has_none:
                if _pick_ready_caster(pid, sel_now, ("Sentry",), "hallucination", sec_now, 2.0):
                    scmd_spells[pid]["hallucination"] += 1
                return
            # Combat: Psionic Storm
            if link == (178 if hi else 176) and idx == 0 and has_pt:
                if _cd_ok(pid, ("storm_pt", bx2, by2), sec_now, 1.5) and _pick_ready_caster(
                    pid, sel_now, ("HighTemplar",), "psi_storm", sec_now, 0.5
                ):
                    scmd_spells[pid]["psi_storm"] += 1
                return
            # Combat: Feedback
            if link == (77 if hi else 75) and idx == 0 and has_u and ttag is not None and trel == "enemy":
                if _cd_ok(pid, ("fb_tgt", ttag), sec_now, 0.8):
                    scmd_spells[pid]["feedback"] += 1
                return
            # Combat: Oracle Pulsar Beam activation
            if link in (534, 538, 540) and idx == 0 and has_none:
                if _pick_ready_caster(pid, sel_now, ("Oracle",), "pulsar_beam", sec_now, 6.0):
                    scmd_spells[pid]["pulsar_beam"] += 1
                return

        elif race == "Terran":
            # Macro: Scanner Sweep
            if link == (141 if hi else 139) and idx == 0 and has_pt:
                if _cd_ok(pid, ("scan_pt", bx4, by4), sec_now, 10.0) and _cd_ok(pid, "scan_any", sec_now, 0.8):
                    pref = tuple(t >> 18 for t in sel_now[:16] if t_ut.get(t) == "OrbitalCommand")
                    macro_casts[pid].append((sec_now, "scan", pref, None))
                return
            # Macro: Calldown Extra Supplies (permanent once per depot!)
            if link == (115 if hi else 113) and idx == 0 and has_u and ttag is not None and trel == "self":
                if tut in ("SupplyDepot", "SupplyDepotLowered") and ttag not in supply_drop_depots[pid]:
                    supply_drop_depots[pid].add(ttag)
                    pref = tuple(t >> 18 for t in sel_now[:16] if t_ut.get(t) == "OrbitalCommand")
                    macro_casts[pid].append((sec_now, "supply_drop", pref, None))
                return
            # Combat: Stimpack (Marine + Marauder unified squad action)
            if link in ((133, 114) if hi else (131, 112)) and idx == 0 and has_none:
                if _cd_ok(pid, "stim_squad", sec_now, 7.5):
                    scmd_spells[pid]["stim"] += 1
                return
            # Combat: EMP Round (Ghost)
            if link == (243 if hi else 241) and idx == 0 and has_pt:
                if _cd_ok(pid, ("emp_pt", bx2, by2), sec_now, 1.5) and _pick_ready_caster(
                    pid, sel_now, ("Ghost",), "emp", sec_now, 0.5
                ):
                    scmd_spells[pid]["emp"] += 1
                return
            # Combat: Steady Targeting / Snipe (Ghost)
            if link in ((709, 710) if hi else (708, 709, 710)) and idx == 0 and has_u and trel == "enemy":
                if any(t_ut.get(t) == "Ghost" for t in sel_now[:24]):
                    if _pick_ready_caster(pid, sel_now, ("Ghost",), "snipe", sec_now, 1.5):
                        scmd_spells[pid]["snipe"] += 1
                    return
            # Combat: Cloak (Banshee / Ghost)
            if ((link == (139 if hi else 137) and idx == 0) or (link == (134 if hi else 132) and idx == 0)) and has_none:
                if _pick_ready_caster(pid, sel_now, ("Banshee", "Ghost"), "cloak", sec_now, 5.0):
                    scmd_spells[pid]["cloak"] += 1
                return
            # Combat: Raven Interference Matrix & Anti-Armor Missile
            if has_u and ttag is not None and trel == "enemy" and any(t_ut.get(t) == "Raven" for t in sel_now[:24]):
                if link in ((719, 720) if hi else (715, 717)) and idx == 0:
                    if _cd_ok(pid, ("imat_tgt", ttag), sec_now, 2.0):
                        scmd_spells[pid]["interference_matrix"] += 1
                    return
                if link in ((722,) if hi else (720,)) and idx == 0:
                    if _pick_ready_caster(pid, sel_now, ("Raven",), "anti_armor_missile", sec_now, 2.0):
                        scmd_spells[pid]["anti_armor_missile"] += 1
                    return
            # Combat: Battlecruiser Yamato & Tactical Jump
            if link == (142 if hi else 140) and idx == 0 and has_u and trel == "enemy":
                if _pick_ready_caster(pid, sel_now, ("Battlecruiser",), "yamato", sec_now, 40.0):
                    scmd_spells[pid]["yamato"] += 1
                return
            if link in ((534,) if hi else (532,)) and idx == 0 and has_pt:
                if any(t_ut.get(t) == "Battlecruiser" for t in sel_now[:24]):
                    if _pick_ready_caster(pid, sel_now, ("Battlecruiser",), "tactical_jump", sec_now, 40.0):
                        scmd_spells[pid]["tactical_jump"] += 1
                    return

        elif race == "Zerg":
            # Macro: Inject Larva
            if link == (113 if hi else 111) and idx == 0 and has_u and ttag is not None and trel == "self":
                if tut in ("Hatchery", "Lair", "Hive"):
                    if _cd_ok(pid, ("inject_th", ttag), sec_now, 26.0):
                        pref = tuple(t >> 18 for t in sel_now[:16] if t_ut.get(t) in ("Queen", "QueenBurrowed"))
                        macro_casts[pid].append((sec_now, "inject", pref, None))
                    return
            # Macro + Combat: Transfuse (Queen)
            if link == (247 if hi else 245) and idx == 0 and has_u and ttag is not None and trel == "self":
                if _cd_ok(pid, ("transf_tgt", ttag), sec_now, 0.6) and _pick_ready_caster(
                    pid, sel_now, ("Queen", "QueenBurrowed"), "transfuse", sec_now, 1.0
                ):
                    pref = tuple(t >> 18 for t in sel_now[:16] if t_ut.get(t) in ("Queen", "QueenBurrowed"))
                    macro_casts[pid].append((sec_now, "transfuse", pref, None))
                    scmd_spells[pid]["transfuse"] += 1
                return
            # Combat: Ravager Corrosive Bile
            if link in ((283,) if hi else (281, 517, 518)) and idx == 0 and has_pt:
                if _pick_ready_caster(pid, sel_now, ("Ravager", "RavagerBurrowed"), "corrosive_bile", sec_now, 6.0):
                    scmd_spells[pid]["corrosive_bile"] += 1
                return
            # Combat: Infestor Fungal Growth
            if link == (72 if hi else 70) and idx == 0 and has_pt:
                if _cd_ok(pid, ("fungal_pt", bx2, by2), sec_now, 1.5) and _pick_ready_caster(
                    pid, sel_now, ("Infestor", "InfestorBurrowed"), "fungal_growth", sec_now, 0.5
                ):
                    scmd_spells[pid]["fungal_growth"] += 1
                return
            # Combat: Infestor Neural Parasite
            if link == (112 if hi else 110) and idx == 0 and has_u and ttag is not None and trel == "enemy":
                if _pick_ready_caster(pid, sel_now, ("Infestor", "InfestorBurrowed"), "neural_parasite", sec_now, 8.0):
                    scmd_spells[pid]["neural_parasite"] += 1
                return
            # Combat: Viper Abduct
            if link in ((384, 385) if hi else (372, 373)) and idx == 0 and has_u and ttag is not None and trel == "enemy":
                if _pick_ready_caster(pid, sel_now, ("Viper",), "abduct", sec_now, 1.5):
                    scmd_spells[pid]["abduct"] += 1
                return
            # Combat: Viper Blinding Cloud
            if link in ((382, 383) if hi else (370, 371)) and idx == 0 and has_pt:
                if _cd_ok(pid, ("bcloud_pt", bx2, by2), sec_now, 1.5) and _pick_ready_caster(
                    pid, sel_now, ("Viper",), "blinding_cloud", sec_now, 0.5
                ):
                    scmd_spells[pid]["blinding_cloud"] += 1
                return

    def _flush_loop(gl: int, loop_evs: dict[int, list[dict[str, Any]]]) -> None:
        bi = gl // bucket_loops if bucket_loops > 0 else 0
        in_curve = 0 <= bi <= max_bucket_idx
        for pid, evs in loop_evs.items():
            has_cmd_in_loop = any(e.get("_event") in CMD_EVENTS for e in evs)
            for ev in evs:
                et = ev.get("_event", "")
                if et in APM_EVENTS:
                    apm_tot[pid] += 1
                    if in_curve:
                        apm_b[pid][bi] += 1

                    if et == "NNet.Game.SSelectionDeltaEvent":
                        delta = ev.get("m_delta") or {}
                        cg_id = int(ev.get("m_controlGroupId", 10))
                        if 0 <= cg_id <= 10:
                            prev_sel = cgroups[pid][cg_id]
                            new_sel = _apply_selection_delta(prev_sel, delta)
                            cgroups[pid][cg_id] = new_sel
                            # Genuine human/bot selection switch (exclude Raw-API same-loop prefix)
                            if not has_cmd_in_loop and cg_id == 10 and new_sel != prev_sel:
                                sel_key = tuple(new_sel[:8]) if new_sel else ("empty",)
                                if sel_key != last_sel_sig[pid] or (gl - last_sel_gl[pid]) > EPM_SEL_DEDUP_LOOPS:
                                    epm_tot[pid] += 1
                                    if in_curve:
                                        epm_b[pid][bi] += 1
                                    last_sel_sig[pid] = sel_key
                                    last_sel_gl[pid] = gl

                    elif et == "NNet.Game.SControlGroupUpdateEvent":
                        # 0=set, 1=append, 4=steal-set, 5=steal-append; 2=recall (not EPM)
                        gid = int(ev.get("m_controlGroupIndex", -1))
                        upd = int(ev.get("m_controlGroupUpdate", -1))
                        if 0 <= gid <= 9:
                            if upd in (0, 4):
                                cgroups[pid][gid] = list(cgroups[pid][10])
                            elif upd in (1, 5):
                                seen_g = set(cgroups[pid][gid])
                                cgroups[pid][gid].extend(t for t in cgroups[pid][10] if t not in seen_g)
                            elif upd == 2:
                                cgroups[pid][10] = list(cgroups[pid][gid])
                        if upd in (0, 1, 4, 5):
                            epm_tot[pid] += 1
                            if in_curve:
                                epm_b[pid][bi] += 1

                    else:
                        # SCmdEvent / SCmdUpdateTargetPointEvent / SCmdUpdateTargetUnitEvent
                        sel_now = cgroups[pid][10]
                        if et == "NNet.Game.SCmdEvent" and r_by_p:
                            _classify_cmd_event(pid, gl, ev, sel_now)
                        sel_sig = tuple(sel_now[:8]) if sel_now else ("none",)
                        sig = _cmd_signature(ev, sel_sig)
                        prev_g = last_cmd_gl[pid].get(sig, -9999)
                        if (gl - prev_g) > EPM_CMD_DEDUP_LOOPS:
                            epm_tot[pid] += 1
                            if in_curve:
                                epm_b[pid][bi] += 1
                            last_cmd_gl[pid][sig] = gl
                            # Prevent unbounded dict growth in very long replays
                            if len(last_cmd_gl[pid]) > 4096:
                                cutoff = gl - (EPM_CMD_DEDUP_LOOPS * 4)
                                last_cmd_gl[pid] = {
                                    k: v for k, v in last_cmd_gl[pid].items() if v >= cutoff
                                }

                elif et == CAMERA_EVENT:
                    tgt = ev.get("m_target")
                    if isinstance(tgt, dict) and tgt.get("x") is not None and tgt.get("y") is not None:
                        cx = float(tgt["x"]) / 256.0
                        cy = float(tgt["y"]) / 256.0
                        prev = last_cam[pid]
                        if prev is None:
                            last_cam[pid] = (gl, cx, cy)
                        else:
                            pgl, px, py = prev
                            if (gl - pgl) >= SPM_MIN_DT_LOOPS and math.hypot(cx - px, cy - py) >= SPM_MIN_JUMP_TILES:
                                spm_tot[pid] += 1
                                if in_curve:
                                    spm_b[pid][bi] += 1
                                last_cam[pid] = (gl, cx, cy)

    cur_gl = -1
    buf: dict[int, list[dict[str, Any]]] = defaultdict(list)
    try:
        for ev in proto.decode_replay_game_events(ge_bytes):
            et = ev.get("_event", "")
            if et not in APM_EVENTS and et != CAMERA_EVENT:
                continue
            uid = (ev.get("_userid") or {}).get("m_userId")
            pid = uid_to_pid.get(uid) if uid is not None else None
            if pid not in target_pids:
                continue
            gl = int(ev.get("_gameloop", 0))
            if gl != cur_gl:
                if buf:
                    _flush_loop(cur_gl, buf)
                    buf.clear()
                cur_gl = gl
            buf[pid].append(ev)
        if buf:
            _flush_loop(cur_gl, buf)
    except Exception:
        return False, {}

    dur_min = max(dur_sec / 60.0, 1e-6)
    scale_to_min = 60.0 / float(bucket_sec)

    out: dict[int, dict[str, Any]] = {}
    for pid in target_pids:
        # Per-player sanity guard against AFK/crashed players or silent truncation
        if dur_sec >= 120.0 and apm_tot[pid] < 10:
            continue

        apm_curve: list[float | None] = []
        epm_curve: list[float | None] = []
        spm_curve: list[float | None] = []
        for idx, t in enumerate(buckets_sec):
            # Require full bucket completion so trailing partial buckets never bias curves low
            if dur_sec >= float(t + bucket_sec):
                apm_curve.append(round(apm_b[pid][idx] * scale_to_min, 1))
                epm_curve.append(round(epm_b[pid][idx] * scale_to_min, 1))
                spm_curve.append(round(spm_b[pid][idx] * scale_to_min, 1))
            else:
                apm_curve.append(None)
                epm_curve.append(None)
                spm_curve.append(None)

        out[pid] = {
            "apm_curve": apm_curve,
            "epm_curve": epm_curve,
            "spm_curve": spm_curve,
            "apm_game": round(apm_tot[pid] / dur_min, 1),
            "epm_game": round(epm_tot[pid] / dur_min, 1),
            "spm_game": round(spm_tot[pid] / dur_min, 1),
            "macro_casts": macro_casts[pid],
            "scmd_spells": dict(scmd_spells[pid]),
        }
    return bool(out), out


def _parse_single_replay(args_tuple: tuple[Any, ...]) -> list[dict[str, Any]]:
    """
    Worker function to parse one `.SC2Replay` for all 8 metrics.
    mode == "pro":    filters LotV 1v1 human non-arcade replays; emits both sides as cohort="pros".
    mode == "arena":  excludes self-play; emits Mothman side as "mothman" and opponent side as "opponents".
    """
    (
        rp_str,
        pylibs_str,
        mode,
        min_dur_sec,
        buckets_sec,
        bucket_sec,
        forced_our_pid,
    ) = args_tuple

    pylibs_dir = Path(pylibs_str)
    rdb = _get_replay_db_module(pylibs_dir)
    import mpyq  # type: ignore

    results: list[dict[str, Any]] = []
    rname = os.path.basename(rp_str)

    # Quick filename self-play check for arena mode
    if mode == "arena":
        low = rname.lower()
        if "-sp_" in low or "-sp." in low or "_sp_" in low or "selfplay" in low:
            return results

    try:
        arch = mpyq.MPQArchive(rp_str)
        hdr = rdb._load_protocol(75689, pylibs_dir).decode_replay_header(
            arch.header["user_data_header"]["content"]
        )
        dur_gl = int(hdr.get("m_elapsedGameLoops") or 0)
        dur_sec = dur_gl / GAME_LOOPS_PER_SEC
        if dur_sec < float(min_dur_sec):
            return results

        bb = int(hdr["m_version"]["m_baseBuild"])
        if mode == "pro" and bb < LOTV_MIN_BASE_BUILD:
            return results

        proto = rdb._load_protocol(bb, pylibs_dir)
        det_bytes = arch.read_file("replay.details")
        if not det_bytes:
            return results
        det = proto.decode_replay_details(det_bytes)
        pls = det.get("m_playerList") or []
        if len(pls) != 2:
            return results

        mname = rdb._decode_str(det.get("m_title", b""))
        if mode == "pro" and any(bad.lower() in mname.lower() for bad in BAD_MAP_TOKENS):
            return results

        race_by_pid: dict[int, str] = {}
        name_by_pid: dict[int, str] = {}
        result_by_pid: dict[int, int] = {}
        for idx, pl in enumerate(pls, 1):
            rn = rdb._norm_race(pl.get("m_race"))
            if rn not in RACES:
                return results
            if mode == "pro" and pl.get("m_control") == 3:
                return results
            race_by_pid[idx] = rn
            name_by_pid[idx] = rdb._decode_str(pl.get("m_name", b""))
            result_by_pid[idx] = int(pl.get("m_result") or 0)

        # Determine cohort assignment per player_id
        cohort_by_pid: dict[int, str] = {}
        if mode == "pro":
            cohort_by_pid = {1: "pros", 2: "pros"}
        else:
            p1_moth = "mothman" in name_by_pid[1].lower()
            p2_moth = "mothman" in name_by_pid[2].lower()
            if p1_moth and p2_moth:
                # Self-play match -> exclude
                return results
            if forced_our_pid in (1, 2):
                our_pid = int(forced_our_pid)
            elif p1_moth:
                our_pid = 1
            elif p2_moth:
                our_pid = 2
            elif "mothman" in rname.lower():
                our_pid = 1
            else:
                return results
            opp_pid = 2 if our_pid == 1 else 1
            cohort_by_pid = {our_pid: "mothman", opp_pid: "opponents"}

        trk_bytes = arch.read_file("replay.tracker.events")
        if not trk_bytes:
            return results

        # Single linear tracker pass: SPlayerSetupEvent, SPlayerStatsEvent, structures, morphs,
        # upgrades, live combat/TH/gas state & SUnitPositionsEvent (Graphs 1-14).
        uid_to_pid: dict[int, int] = {}
        stats_series: dict[int, list[tuple[float, float, float, float, float]]] = {1: [], 2: []}
        ret_series: dict[int, list[tuple[float, float, float]]] = {1: [], 2: []}
        bldg_inits: dict[int, dict[str, list[tuple[float, int]]]] = {1: defaultdict(list), 2: defaultdict(list)}
        th_inits: dict[int, list[tuple[float, int]]] = {1: [], 2: []}
        gas_inits: dict[int, list[tuple[float, int]]] = {1: [], 2: []}
        morphs: dict[int, dict[str, list[float]]] = {1: defaultdict(list), 2: defaultdict(list)}
        upgrades: dict[int, dict[str, float]] = {1: {}, 2: {}}
        all_upgrades: dict[int, dict[str, float]] = {1: {}, 2: {}}

        tag_owner: dict[int, int] = {}
        tag_ut: dict[int, str] = {}
        init_tags: set[int] = set()
        done_tags: set[int] = set()
        self_canceled_tags: set[int] = set()

        # Graphs 19-22 tracker state
        # Production facilities & Reactor slots: uidx -> (pid, fac_group, is_reactor)
        prod_active_units: dict[int, tuple[int, str, bool]] = {}
        prod_pending_init: dict[int, tuple[int, str, bool]] = {}
        prod_start_sec: dict[int, tuple[int, str, float]] = {}
        ready_slot_sec: dict[int, dict[str, float]] = {1: defaultdict(float), 2: defaultdict(float)}
        trained_build_sec: dict[int, dict[str, float]] = {1: defaultdict(float), 2: defaultdict(float)}
        warpin_init_by_uidx: dict[int, tuple[int, str]] = {}
        zerg_larva_spent: dict[int, float] = {1: 0.0, 2: 0.0}
        prod_counts_18m: dict[int, dict[str, list[int | None]]] = {
            p: {fg: [None] * len(BUCKETS_18M_SEC) for fg in RACE_FACILITY_GROUPS[race_by_pid[p]]}
            for p in (1, 2)
        }
        peak_prod_counts: dict[int, dict[str, int]] = {
            p: {fg: 0 for fg in RACE_FACILITY_GROUPS[race_by_pid[p]]}
            for p in (1, 2)
        }

        # Macro energy casters (Nexus / OrbitalCommand / Queen) & active creep tumors
        macro_caster_lifetimes: dict[int, dict[str, list[list[Any]]]] = {
            1: {"Nexus": [], "OrbitalCommand": [], "Queen": []},
            2: {"Nexus": [], "OrbitalCommand": [], "Queen": []},
        }
        macro_caster_by_idx: dict[int, list[Any]] = {}
        nexus_pending_uidx: dict[int, int] = {}
        oc_seen_uidxs: set[int] = set()
        tracker_macro_times: dict[int, dict[str, list[float]]] = {
            1: {"mule": [], "creep_tumor_queen": [], "creep_tumor_spread": []},
            2: {"mule": [], "creep_tumor_queen": [], "creep_tumor_spread": []},
        }
        active_tumors_by_idx: dict[int, int] = {}
        active_tumors_18m: dict[int, list[int | None]] = {
            1: [None] * len(BUCKETS_18M_SEC),
            2: [None] * len(BUCKETS_18M_SEC),
        }
        peak_active_tumors: dict[int, int] = {1: 0, 2: 0}

        # Graph 22 tracker-spawned / mode-morph spells & built casters
        seen_special_tags: set[int] = set()
        casters_built: dict[int, set[str]] = {1: set(), 2: set()}
        tracker_spells: dict[int, dict[str, int]] = {1: defaultdict(int), 2: defaultdict(int)}
        wg_done_sec: dict[int, float] = {}
        first_cloak_threat_sec: dict[int, float] = {1: float("inf"), 2: float("inf")}

        # Live unit table keyed by unitTagIndex for O(1) SUnitPositionsEvent updates:
        # idx -> [pid, ut, x, y, val, is_combat, is_th, is_gas, tier, active]
        live_by_idx: dict[int, list[Any]] = {}
        # Lightweight unit death metadata by tag -> (pid, val, is_worker, is_combat, is_struct)
        meta_by_tag: dict[int, tuple[int, int, bool, bool, bool]] = {}
        # TownHall lifetimes per player: [start_sec, end_sec, x, y, tag]
        th_lifetimes_raw: dict[int, list[list[Any]]] = {1: [], 2: []}
        th_rec_by_idx: dict[int, list[Any]] = {}
        home_xy: dict[int, tuple[float, float]] = {}
        combat_deaths: list[tuple[float, int, int, float, float]] = []
        all_deaths: list[tuple[float, int, int, bool, bool, bool, float, float]] = []
        pos_snaps: list[tuple[float, dict[int, list[tuple[int, int, str, float, float, str]]]]] = []

        # Periodic bucketed samples captured along the single linear tracker pass
        frag_pct_b: dict[int, list[float | None]] = {1: [None] * len(BUCKETS_16M_SEC), 2: [None] * len(BUCKETS_16M_SEC)}
        clusters_b: dict[int, list[int | None]] = {1: [None] * len(BUCKETS_16M_SEC), 2: [None] * len(BUCKETS_16M_SEC)}
        th_active_b: dict[int, list[int | None]] = {1: [None] * len(BUCKETS_18M_SEC), 2: [None] * len(BUCKETS_18M_SEC)}
        gas_active_b: dict[int, list[int | None]] = {1: [None] * len(BUCKETS_18M_SEC), 2: [None] * len(BUCKETS_18M_SEC)}
        tier_mix_b: dict[int, list[list[float] | None]] = {1: [None] * len(BUCKETS_TIER_SEC), 2: [None] * len(BUCKETS_TIER_SEC)}
        unit_comp_b: dict[int, list[dict[str, int] | None]] = {1: [None] * len(BUCKETS_TIER_SEC), 2: [None] * len(BUCKETS_TIER_SEC)}
        gas_per_base_4plus_samples: dict[int, list[float]] = {1: [], 2: []}
        peak_active_ths: dict[int, int] = {1: 1, 2: 1}
        peak_active_gas: dict[int, int] = {1: 0, 2: 0}

        next_snap_sec = 30.0
        next_16m_idx = 0
        next_18m_idx = 0
        next_tier_idx = 0

        def _record_special_unit(p_id: int, uname: str, utag: int, sec_s: float) -> None:
            if utag in seen_special_tags:
                return
            if uname == "MULE":
                seen_special_tags.add(utag)
                tracker_macro_times[p_id]["mule"].append(sec_s)
            elif uname == "CreepTumorQueen":
                seen_special_tags.add(utag)
                tracker_macro_times[p_id]["creep_tumor_queen"].append(sec_s)
            elif uname == "CreepTumor":
                seen_special_tags.add(utag)
                tracker_macro_times[p_id]["creep_tumor_spread"].append(sec_s)
            elif uname == "AdeptPhaseShift":
                seen_special_tags.add(utag)
                tracker_spells[p_id]["shade"] += 1
            elif uname == "ForceField":
                seen_special_tags.add(utag)
                tracker_spells[p_id]["force_field"] += 1
            elif uname == "DisruptorPhased":
                seen_special_tags.add(utag)
                tracker_spells[p_id]["purification_nova"] += 1
            elif uname == "OracleStasisTrap":
                seen_special_tags.add(utag)
                tracker_spells[p_id]["stasis_ward"] += 1
            elif uname == "AutoTurret":
                seen_special_tags.add(utag)
                tracker_spells[p_id]["auto_turret"] += 1
            elif uname == "KD8Charge":
                seen_special_tags.add(utag)
                tracker_spells[p_id]["kd8_charge"] += 1
            elif uname == "ParasiticBombRelayDummy":
                seen_special_tags.add(utag)
                tracker_spells[p_id]["parasitic_bomb"] += 1
            elif uname == "Changeling":
                seen_special_tags.add(utag)
                tracker_spells[p_id]["spawn_changeling"] += 1

        def _record_trained_unit(p_id: int, uname: str, sec_s: float) -> None:
            if sec_s <= 5.0:
                return
            tspec = TRAINED_UNIT_BUILD_SEC.get(uname)
            if tspec is not None:
                fg, bsec, wgsec = tspec
                use_s = wgsec if (fg == "Gateway" and p_id in wg_done_sec and sec_s >= wg_done_sec[p_id]) else bsec
                trained_build_sec[p_id][fg] += use_s
            lcost = ZERG_LARVA_CONSUMED.get(uname)
            if lcost is not None and race_by_pid[p_id] == "Zerg":
                zerg_larva_spent[p_id] += lcost

        def _unit_death_meta(p_id: int, uname: str) -> tuple[int, int, bool, bool, bool] | None:
            cs = COMBAT_UNIT_SPEC.get(uname)
            if cs is not None:
                return (p_id, cs[1], False, True, False)
            if uname in WORKER_UNITS:
                return (p_id, 50, True, False, False)
            if uname in TOWN_HALLS:
                return (p_id, 350, False, False, True)
            if uname in GAS_STRUCTURES:
                return (p_id, 50, False, False, True)
            if uname in REAL_STRUCTURES:
                return (p_id, 100, False, False, True)
            return None

        def _snapshot_combat_by_pid() -> dict[int, list[tuple[int, int, str, float, float, str]]]:
            out_c: dict[int, list[tuple[int, int, str, float, float, str]]] = {1: [], 2: []}
            for uidx, u in live_by_idx.items():
                if u[5] and u[9]:  # is_combat and active
                    out_c[u[0]].append((uidx, u[4], u[8], u[2], u[3], u[1]))
            return out_c

        def _advance_time_samples(cur_sec: float) -> None:
            nonlocal next_snap_sec, next_16m_idx, next_18m_idx, next_tier_idx
            need_combat = (
                (cur_sec >= next_snap_sec)
                or (next_16m_idx < len(BUCKETS_16M_SEC) and cur_sec >= BUCKETS_16M_SEC[next_16m_idx])
                or (next_tier_idx < len(BUCKETS_TIER_SEC) and cur_sec >= BUCKETS_TIER_SEC[next_tier_idx])
            )
            c_by_pid = _snapshot_combat_by_pid() if need_combat else None

            while cur_sec >= next_snap_sec:
                assert c_by_pid is not None
                pos_snaps.append((next_snap_sec, c_by_pid))
                next_snap_sec += 5.0

            while next_16m_idx < len(BUCKETS_16M_SEC) and cur_sec >= BUCKETS_16M_SEC[next_16m_idx]:
                assert c_by_pid is not None
                for p in (1, 2):
                    fp, nc = _compute_army_fragmentation(c_by_pid[p], 14.0)
                    frag_pct_b[p][next_16m_idx] = fp
                    clusters_b[p][next_16m_idx] = nc
                next_16m_idx += 1

            while next_18m_idx < len(BUCKETS_18M_SEC) and cur_sec >= BUCKETS_18M_SEC[next_18m_idx]:
                th_c = {1: 0, 2: 0}
                gas_c = {1: 0, 2: 0}
                for u in live_by_idx.values():
                    if u[9]:  # active completed structure
                        if u[6]:
                            th_c[u[0]] += 1
                        elif u[7]:
                            gas_c[u[0]] += 1
                # Graph 19 active completed production facility counts (excluding Reactor addons from building count)
                pc_now: dict[int, dict[str, int]] = {
                    p: {fg: 0 for fg in RACE_FACILITY_GROUPS[race_by_pid[p]]} for p in (1, 2)
                }
                for pp, pfg, is_rx in prod_active_units.values():
                    if not is_rx and pfg in pc_now[pp]:
                        pc_now[pp][pfg] += 1
                # Graph 20 active creep tumors
                tum_c = {1: 0, 2: 0}
                for tp in active_tumors_by_idx.values():
                    tum_c[tp] += 1

                for p in (1, 2):
                    th_active_b[p][next_18m_idx] = th_c[p]
                    gas_active_b[p][next_18m_idx] = gas_c[p]
                    if th_c[p] > peak_active_ths[p]:
                        peak_active_ths[p] = th_c[p]
                    if gas_c[p] > peak_active_gas[p]:
                        peak_active_gas[p] = gas_c[p]
                    if th_c[p] >= 4:
                        gas_per_base_4plus_samples[p].append(gas_c[p] / float(th_c[p]))
                    for fg, cnt_fg in pc_now[p].items():
                        prod_counts_18m[p][fg][next_18m_idx] = cnt_fg
                        if cnt_fg > peak_prod_counts[p][fg]:
                            peak_prod_counts[p][fg] = cnt_fg
                    active_tumors_18m[p][next_18m_idx] = tum_c[p]
                    if tum_c[p] > peak_active_tumors[p]:
                        peak_active_tumors[p] = tum_c[p]
                next_18m_idx += 1

            while next_tier_idx < len(BUCKETS_TIER_SEC) and cur_sec >= BUCKETS_TIER_SEC[next_tier_idx]:
                assert c_by_pid is not None
                for p in (1, 2):
                    t_vals = {"T1": 0, "T2": 0, "T3": 0}
                    u_vals: dict[str, int] = {}
                    for _uidx, uval, utier, _ux, _uy, utype in c_by_pid[p]:
                        if utier in t_vals:
                            t_vals[utier] += uval
                        cu = _canon_combat_unit(utype)
                        u_vals[cu] = u_vals.get(cu, 0) + uval
                    tot_v = t_vals["T1"] + t_vals["T2"] + t_vals["T3"]
                    if tot_v >= 100:
                        tier_mix_b[p][next_tier_idx] = [
                            round(100.0 * t_vals["T1"] / tot_v, 1),
                            round(100.0 * t_vals["T2"] / tot_v, 1),
                            round(100.0 * t_vals["T3"] / tot_v, 1),
                        ]
                        unit_comp_b[p][next_tier_idx] = u_vals
                next_tier_idx += 1

        for ev in proto.decode_replay_tracker_events(trk_bytes):
            et = ev.get("_event", "")
            gl = int(ev.get("_gameloop", 0))
            sec = gl / GAME_LOOPS_PER_SEC
            if sec > 0.0:
                _advance_time_samples(sec)

            if et == "NNet.Replay.Tracker.SPlayerSetupEvent":
                pid = ev.get("m_playerId")
                uid = ev.get("m_userId")
                if pid in (1, 2) and uid is not None:
                    uid_to_pid[int(uid)] = int(pid)

            elif et == "NNet.Replay.Tracker.SPlayerStatsEvent":
                pid = int(ev.get("m_playerId") or 0)
                if pid not in (1, 2):
                    continue
                st = ev.get("m_stats") or {}
                am = float(st.get("m_scoreValueMineralsUsedActiveForces") or 0.0)
                ag = float(st.get("m_scoreValueVespeneUsedActiveForces") or 0.0)
                cm = float(st.get("m_scoreValueMineralsCollectionRate") or 0.0)
                cg = float(st.get("m_scoreValueVespeneCollectionRate") or 0.0)
                la = float(st.get("m_scoreValueMineralsLostArmy") or 0.0) + float(
                    st.get("m_scoreValueVespeneLostArmy") or 0.0
                )
                stats_series[pid].append((sec, am, ag, cm, cg))
                ret_series[pid].append((sec, am + ag, la))

            elif et == "NNet.Replay.Tracker.SUnitInitEvent":
                pid = int(ev.get("m_controlPlayerId") or 0)
                if pid not in (1, 2):
                    continue
                ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                uidx = int(ev.get("m_unitTagIndex", 0))
                tag = (uidx << 18) | int(ev.get("m_unitTagRecycle", 0))
                tag_owner[tag] = pid
                tag_ut[tag] = ut
                _record_special_unit(pid, ut, tag, sec)
                if ut in ("CreepTumor", "CreepTumorQueen", "CreepTumorBurrowed"):
                    active_tumors_by_idx[uidx] = pid
                pfg_spec = PROD_FACILITY_GROUP.get(ut)
                if pfg_spec is not None and pfg_spec[0] == race_by_pid[pid]:
                    prod_pending_init[uidx] = (pid, pfg_spec[1], False)
                elif ut in REACTOR_SLOT_GROUP and race_by_pid[pid] == "Terran":
                    prod_pending_init[uidx] = (pid, REACTOR_SLOT_GROUP[ut], True)
                if ut == "Nexus":
                    nexus_pending_uidx[uidx] = pid
                if ut in TRAINED_UNIT_BUILD_SEC and ut not in WORKER_UNITS:
                    # Warp-in Protoss units fire SUnitInitEvent -> SUnitDoneEvent
                    warpin_init_by_uidx[uidx] = (pid, ut)
                dm = _unit_death_meta(pid, ut)
                if dm is not None:
                    meta_by_tag[tag] = dm
                ux = float(ev.get("m_x", 0.0))
                uy = float(ev.get("m_y", 0.0))
                is_th = ut in TOWN_HALLS
                is_gas = ut in GAS_STRUCTURES
                cspec = COMBAT_UNIT_SPEC.get(ut)
                if ut in TRACKED_STRUCTURES or is_gas:
                    init_tags.add(tag)
                    if is_th and sec > 5.0:
                        th_inits[pid].append((sec, tag))
                    elif is_gas and sec > 2.0:
                        gas_inits[pid].append((sec, tag))
                        if ut in TRACKED_STRUCTURES:
                            bldg_inits[pid][ut].append((sec, tag))
                    elif sec > 2.0:
                        bldg_inits[pid][ut].append((sec, tag))
                if is_th:
                    th_rec = [sec, float("inf"), ux, uy, tag]
                    th_lifetimes_raw[pid].append(th_rec)
                    th_rec_by_idx[uidx] = th_rec
                if cspec is not None or is_th or is_gas:
                    live_by_idx[uidx] = [
                        pid,
                        ut,
                        ux,
                        uy,
                        cspec[1] if cspec else 0,
                        cspec is not None,
                        is_th,
                        is_gas,
                        cspec[0] if cspec else "",
                        False,  # becomes active on SUnitDoneEvent
                    ]

            elif et == "NNet.Replay.Tracker.SUnitDoneEvent":
                uidx = int(ev.get("m_unitTagIndex", 0))
                tag = (uidx << 18) | int(ev.get("m_unitTagRecycle", 0))
                if tag in init_tags:
                    done_tags.add(tag)
                u = live_by_idx.get(uidx)
                if u is not None:
                    u[9] = True
                pinfo = prod_pending_init.pop(uidx, None)
                if pinfo is not None:
                    prod_active_units[uidx] = pinfo
                    prod_start_sec[uidx] = (pinfo[0], pinfo[1], sec)
                npid = nexus_pending_uidx.pop(uidx, None)
                if npid is not None:
                    mc_rec = [sec, float("inf"), uidx, MACRO_CASTER_START_ENERGY["Nexus"]]
                    macro_caster_lifetimes[npid]["Nexus"].append(mc_rec)
                    macro_caster_by_idx[uidx] = mc_rec
                    casters_built[npid].add("Nexus")
                winfo = warpin_init_by_uidx.pop(uidx, None)
                if winfo is not None:
                    wpid, wut = winfo
                    _record_trained_unit(wpid, wut, sec)
                    if wut in CLOAK_THREAT_UNITS and sec < first_cloak_threat_sec[wpid]:
                        first_cloak_threat_sec[wpid] = sec
                    if wut in ALL_CASTER_TRACK_UNITS:
                        casters_built[wpid].add(wut)

            elif et == "NNet.Replay.Tracker.SUnitBornEvent":
                pid = int(ev.get("m_controlPlayerId") or 0)
                if pid not in (1, 2):
                    ut_neut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                    if ut_neut == "ForceField":
                        cidx = ev.get("m_creatorUnitTagIndex")
                        crec = ev.get("m_creatorUnitTagRecycle")
                        if cidx is not None and crec is not None:
                            cpid = tag_owner.get((int(cidx) << 18) | int(crec), 0)
                            if cpid in (1, 2):
                                ftag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                                _record_special_unit(cpid, ut_neut, ftag, sec)
                    continue
                ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                uidx = int(ev.get("m_unitTagIndex", 0))
                tag = (uidx << 18) | int(ev.get("m_unitTagRecycle", 0))
                tag_owner[tag] = pid
                tag_ut[tag] = ut
                _record_special_unit(pid, ut, tag, sec)
                _record_trained_unit(pid, ut, sec)
                if ut in CLOAK_THREAT_UNITS and sec < first_cloak_threat_sec[pid]:
                    first_cloak_threat_sec[pid] = sec
                if ut in ALL_CASTER_TRACK_UNITS:
                    casters_built[pid].add(ut)
                if ut in ("CreepTumor", "CreepTumorQueen", "CreepTumorBurrowed"):
                    active_tumors_by_idx[uidx] = pid
                pfg_spec = PROD_FACILITY_GROUP.get(ut)
                if pfg_spec is not None and pfg_spec[0] == race_by_pid[pid]:
                    prod_active_units[uidx] = (pid, pfg_spec[1], False)
                    prod_start_sec[uidx] = (pid, pfg_spec[1], sec)
                elif ut in REACTOR_SLOT_GROUP and race_by_pid[pid] == "Terran":
                    prod_active_units[uidx] = (pid, REACTOR_SLOT_GROUP[ut], True)
                    prod_start_sec[uidx] = (pid, REACTOR_SLOT_GROUP[ut], sec)
                if ut == "Nexus":
                    mc_rec = [sec, float("inf"), uidx, MACRO_CASTER_START_ENERGY["Nexus"]]
                    macro_caster_lifetimes[pid]["Nexus"].append(mc_rec)
                    macro_caster_by_idx[uidx] = mc_rec
                elif ut == "Queen":
                    mc_rec = [sec, float("inf"), uidx, MACRO_CASTER_START_ENERGY["Queen"]]
                    macro_caster_lifetimes[pid]["Queen"].append(mc_rec)
                    macro_caster_by_idx[uidx] = mc_rec
                dm = _unit_death_meta(pid, ut)
                if dm is not None:
                    meta_by_tag[tag] = dm
                ux = float(ev.get("m_x", 0.0))
                uy = float(ev.get("m_y", 0.0))
                is_th = ut in TOWN_HALLS
                is_gas = ut in GAS_STRUCTURES
                cspec = COMBAT_UNIT_SPEC.get(ut)
                if is_th and pid not in home_xy and sec <= 5.0:
                    home_xy[pid] = (ux, uy)
                if ut in TRACKED_STRUCTURES or is_gas:
                    if is_th and sec > 5.0:
                        th_inits[pid].append((sec, tag))
                    elif is_gas and sec > 2.0:
                        gas_inits[pid].append((sec, tag))
                        if ut in TRACKED_STRUCTURES:
                            bldg_inits[pid][ut].append((sec, tag))
                    elif sec > 2.0:
                        bldg_inits[pid][ut].append((sec, tag))
                if is_th:
                    th_rec = [sec, float("inf"), ux, uy, tag]
                    th_lifetimes_raw[pid].append(th_rec)
                    th_rec_by_idx[uidx] = th_rec
                if cspec is not None or is_th or is_gas:
                    live_by_idx[uidx] = [
                        pid,
                        ut,
                        ux,
                        uy,
                        cspec[1] if cspec else 0,
                        cspec is not None,
                        is_th,
                        is_gas,
                        cspec[0] if cspec else "",
                        True,
                    ]

            elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
                uidx = int(ev.get("m_unitTagIndex", 0))
                tag = (uidx << 18) | int(ev.get("m_unitTagRecycle", 0))
                k_pid = ev.get("m_killerPlayerId")
                if tag in init_tags and tag not in done_tags:
                    owner = tag_owner.get(tag)
                    if k_pid is None or k_pid == owner:
                        self_canceled_tags.add(tag)
                prod_pending_init.pop(uidx, None)
                prod_active_units.pop(uidx, None)
                warpin_init_by_uidx.pop(uidx, None)
                nexus_pending_uidx.pop(uidx, None)
                active_tumors_by_idx.pop(uidx, None)
                ps = prod_start_sec.pop(uidx, None)
                if ps is not None:
                    ready_slot_sec[ps[0]][ps[1]] += max(0.0, sec - ps[2])
                mc_rec = macro_caster_by_idx.pop(uidx, None)
                if mc_rec is not None:
                    mc_rec[1] = sec
                th_rec = th_rec_by_idx.pop(uidx, None)
                if th_rec is not None:
                    th_rec[1] = sec
                u = live_by_idx.pop(uidx, None)
                if u is not None and u[5] and u[9]:
                    dx = float(ev.get("m_x", u[2]))
                    dy = float(ev.get("m_y", u[3]))
                    combat_deaths.append((sec, u[0], u[4], dx, dy))
                dm = meta_by_tag.pop(tag, None)
                if dm is not None:
                    vpid = dm[0]
                    opp_p = 2 if vpid == 1 else 1
                    if k_pid == opp_p:
                        dx = float(ev.get("m_x", u[2] if u is not None else 0.0))
                        dy = float(ev.get("m_y", u[3] if u is not None else 0.0))
                        all_deaths.append((sec, vpid, dm[1], dm[2], dm[3], dm[4], dx, dy))

            elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
                uidx = int(ev.get("m_unitTagIndex", 0))
                tag = (uidx << 18) | int(ev.get("m_unitTagRecycle", 0))
                pid = tag_owner.get(tag)
                if pid in (1, 2):
                    old_ut = tag_ut.get(tag, "")
                    ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                    tag_ut[tag] = ut
                    if ut in CLOAK_THREAT_UNITS and sec < first_cloak_threat_sec[pid]:
                        first_cloak_threat_sec[pid] = sec
                    if ut in ALL_CASTER_TRACK_UNITS:
                        casters_built[pid].add(ut)
                    if ut == "OrbitalCommand" and uidx not in oc_seen_uidxs:
                        oc_seen_uidxs.add(uidx)
                        mc_rec = [sec, float("inf"), uidx, MACRO_CASTER_START_ENERGY["OrbitalCommand"]]
                        macro_caster_lifetimes[pid]["OrbitalCommand"].append(mc_rec)
                        macro_caster_by_idx[uidx] = mc_rec
                    # Graph 22 tracker-exact tactical mode morphs
                    if (old_ut == "SiegeTank" and ut == "SiegeTankSieged") or (old_ut == "SiegeTankSieged" and ut == "SiegeTank"):
                        tracker_spells[pid]["siege_morph"] += 1
                    elif old_ut == "WidowMine" and ut == "WidowMineBurrowed":
                        tracker_spells[pid]["widow_mine_burrow"] += 1
                    elif old_ut == "Liberator" and ut == "LiberatorAG":
                        tracker_spells[pid]["liberator_ag"] += 1
                    elif (old_ut == "VikingFighter" and ut == "VikingAssault") or (old_ut == "VikingAssault" and ut == "VikingFighter"):
                        tracker_spells[pid]["viking_mode"] += 1
                    elif (old_ut == "Hellion" and ut == "HellionTank") or (old_ut == "HellionTank" and ut == "Hellion"):
                        tracker_spells[pid]["hellbat_morph"] += 1
                    elif old_ut == "LurkerMP" and ut == "LurkerMPBurrowed":
                        tracker_spells[pid]["lurker_burrow"] += 1
                    elif (old_ut, ut) in (
                        ("Roach", "RoachBurrowed"),
                        ("Infestor", "InfestorBurrowed"),
                        ("Baneling", "BanelingBurrowed"),
                        ("SwarmHostMP", "SwarmHostBurrowedMP"),
                    ):
                        tracker_spells[pid]["burrow_combat"] += 1
                    dm = _unit_death_meta(pid, ut)
                    if dm is not None:
                        meta_by_tag[tag] = dm
                    if ut in TRACKED_MORPHS:
                        morphs[pid][ut].append(sec)
                    u = live_by_idx.get(uidx)
                    if u is not None:
                        u[1] = ut
                        cspec = COMBAT_UNIT_SPEC.get(ut)
                        if cspec is not None:
                            u[4] = cspec[1]
                            u[5] = True
                            u[8] = cspec[0]
                            u[9] = True
                        elif ut in TOWN_HALLS:
                            u[6] = True
                        elif ut in GAS_STRUCTURES:
                            u[7] = True
                        else:
                            # e.g., BanelingCocoon / LurkerMPEgg / BroodLordCocoon while morphing
                            u[5] = False

            elif et == "NNet.Replay.Tracker.SUnitPositionsEvent":
                first_idx = int(ev.get("m_firstUnitIndex", 0))
                items = ev.get("m_items") or ()
                idx_cur = first_idx
                n_it = len(items)
                k = 0
                while k + 2 < n_it:
                    idx_cur += int(items[k])
                    u = live_by_idx.get(idx_cur)
                    if u is not None:
                        nx = float(items[k + 1])
                        ny = float(items[k + 2])
                        u[2] = nx
                        u[3] = ny
                        if u[6]:
                            tr = th_rec_by_idx.get(idx_cur)
                            if tr is not None:
                                tr[2] = nx
                                tr[3] = ny
                    k += 3

            elif et == "NNet.Replay.Tracker.SUpgradeEvent":
                pid = int(ev.get("m_playerId") or 0)
                if pid in (1, 2) and sec >= 5.0:
                    uname = rdb._decode_str(ev.get("m_upgradeTypeName", b""))
                    if (
                        uname
                        and not uname.startswith(IGNORED_UPGRADE_PREFIXES)
                        and not uname.endswith(IGNORED_UPGRADE_SUFFIXES)
                    ):
                        if uname == "WarpGateResearch" and pid not in wg_done_sec:
                            wg_done_sec[pid] = sec
                        if uname in CLOAK_THREAT_UPGRADES and sec < first_cloak_threat_sec[pid]:
                            first_cloak_threat_sec[pid] = sec
                        if uname not in all_upgrades[pid]:
                            all_upgrades[pid][uname] = round(sec, 1)
                        if uname in TRACKED_UPGRADES and uname not in upgrades[pid]:
                            upgrades[pid][uname] = sec

        # Final time flush up to replay duration & flush surviving production slot-seconds
        _advance_time_samples(dur_sec)
        for _uidx, ps in prod_start_sec.items():
            ready_slot_sec[ps[0]][ps[1]] += max(0.0, dur_sec - ps[2])

        # Clean TownHall lifetimes (exclude self-canceled expansions)
        th_lifetimes: dict[int, list[list[Any]]] = {
            p: [tr for tr in th_lifetimes_raw[p] if tr[4] not in self_canceled_tags]
            for p in (1, 2)
        }

        # Graphs 10, 15, 16c: Shared clash engagement, concave/layering & off-front idle analyzer
        clashes_by_pid, concave_by_pid, off_front_idle_by_pid = _compute_engage_retreat_clashes(
            combat_deaths, pos_snaps, home_xy, th_lifetimes
        )
        # Graphs 16a/b & 17a/b: Army rotations, multiprong pressure & counter-backstabs
        rot_mp_by_pid = _compute_rotations_and_multiprong(
            all_deaths, pos_snaps, th_lifetimes, home_xy, dur_sec
        )

        # Fallback uid -> pid mapping only if SPlayerSetupEvent was absent
        if not uid_to_pid:
            uid_to_pid = {0: 1, 1: 2}

        # Decode replay.game.events for APM / EPM / SPM + Graphs 20-22 SCmdEvent casts
        ge_bytes = arch.read_file("replay.game.events")
        ge_ok = False
        ge_by_pid: dict[int, dict[str, Any]] = {}
        if ge_bytes:
            ge_ok, ge_by_pid = _decode_game_events_metrics(
                proto,
                ge_bytes,
                uid_to_pid,
                (1, 2),
                buckets_sec,
                bucket_sec,
                dur_sec,
                race_by_pid=race_by_pid,
                base_build=bb,
                tag_ut=tag_ut,
                tag_own=tag_owner,
            )
            # In Pro mode, if game events decoded cleanly for only 1 player, the other was AFK -> drop replay
            if mode == "pro" and ge_ok and len(ge_by_pid) < 2:
                return results

        half_win = max(15.0, bucket_sec * 0.5)
        for pid in (1, 2):
            opp_pid = 2 if pid == 1 else 1
            race = race_by_pid[pid]
            opp_race = race_by_pid[opp_pid]
            matchup = f"{race[0]}v{opp_race[0]}"
            ss = stats_series[pid]
            snap_curves = _sample_stats_at_buckets(ss, buckets_sec, dur_sec, half_win)
            ret_curve_16m = _sample_retention_at_buckets(ret_series[pid], BUCKETS_16M_SEC, dur_sec, 15.0)

            # Game-level mean & peak for army value and collection rates
            if ss:
                am_vals = [x[1] for x in ss]
                ag_vals = [x[2] for x in ss]
                cm_vals = [x[3] for x in ss]
                cg_vals = [x[4] for x in ss]
                snap_summary = {
                    "army_minerals": round(sum(am_vals) / len(am_vals), 1),
                    "army_gas": round(sum(ag_vals) / len(ag_vals), 1),
                    "collection_minerals": round(sum(cm_vals) / len(cm_vals), 1),
                    "collection_gas": round(sum(cg_vals) / len(cg_vals), 1),
                    "army_minerals_peak": round(max(am_vals), 1),
                    "army_gas_peak": round(max(ag_vals), 1),
                    "collection_minerals_peak": round(max(cm_vals), 1),
                    "collection_gas_peak": round(max(cg_vals), 1),
                }
            else:
                snap_summary = {
                    "army_minerals": None,
                    "army_gas": None,
                    "collection_minerals": None,
                    "collection_gas": None,
                    "army_minerals_peak": None,
                    "army_gas_peak": None,
                    "collection_minerals_peak": None,
                    "collection_gas_peak": None,
                }

            # Graph 9 game-level cohesion summaries
            fvals = [x for x in frag_pct_b[pid] if x is not None]
            cvals = [x for x in clusters_b[pid] if x is not None]
            rvals = [x for x in ret_curve_16m if x is not None]
            # Also peak-to-cumulative final army retention (directly comparable to v2 investigation)
            peak_to_cum_ret: float | None = None
            if ret_series[pid]:
                pk_act = max(x[1] for x in ret_series[pid])
                fin_act, fin_lost = ret_series[pid][-1][1], ret_series[pid][-1][2]
                if fin_act + fin_lost >= 400.0:
                    peak_to_cum_ret = round(pk_act / (fin_act + fin_lost), 3)

            # Graph 11 & 12 Base #4/#5/#6 & Gas #7/#8/#9/#10 timings (excluding self-cancels)
            valid_th = sorted(s for s, t in th_inits[pid] if t not in self_canceled_tags)
            valid_gas = sorted(s for s, t in gas_inits[pid] if t not in self_canceled_tags)
            base_4plus_timings = {
                "fourth": round(valid_th[2], 1) if len(valid_th) >= 3 else None,
                "fifth": round(valid_th[3], 1) if len(valid_th) >= 4 else None,
                "sixth": round(valid_th[4], 1) if len(valid_th) >= 5 else None,
            }
            gas_7plus_timings = {
                "gas_7": round(valid_gas[6], 1) if len(valid_gas) >= 7 else None,
                "gas_8": round(valid_gas[7], 1) if len(valid_gas) >= 8 else None,
                "gas_9": round(valid_gas[8], 1) if len(valid_gas) >= 9 else None,
                "gas_10": round(valid_gas[9], 1) if len(valid_gas) >= 10 else None,
            }
            reached_4plus = (peak_active_ths[pid] >= 4) or (len(valid_th) >= 3)
            gpb4 = (
                round(sum(gas_per_base_4plus_samples[pid]) / len(gas_per_base_4plus_samples[pid]), 2)
                if gas_per_base_4plus_samples[pid]
                else None
            )

            ge_p = ge_by_pid.get(pid) if ge_ok else None

            # Graph 19: Production facility counts & utilization
            fac_groups = RACE_FACILITY_GROUPS[race]
            util_by_fg: dict[str, float | None] = {}
            army_fgs = ("Gateway", "Robo", "Stargate") if race == "Protoss" else (
                ("Barracks", "Factory", "Starport") if race == "Terran" else ()
            )
            tot_army_train = 0.0
            tot_army_ready = 0.0
            for fg in fac_groups:
                rsec = ready_slot_sec[pid].get(fg, 0.0)
                tsec = trained_build_sec[pid].get(fg, 0.0)
                if fg in ("Hatchery", "Queen"):
                    util_by_fg[fg] = None
                elif rsec >= 30.0:
                    util_by_fg[fg] = round(min(150.0, 100.0 * tsec / rsec), 1)
                else:
                    util_by_fg[fg] = None
                if fg in army_fgs:
                    tot_army_train += tsec
                    tot_army_ready += rsec
            overall_prod_util = (
                round(min(150.0, 100.0 * tot_army_train / tot_army_ready), 1)
                if tot_army_ready >= 30.0
                else None
            )
            larva_per_hatch_min: float | None = None
            queens_per_hatch_10m: float | None = None
            if race == "Zerg":
                h_sec = ready_slot_sec[pid].get("Hatchery", 0.0)
                if h_sec >= 60.0:
                    larva_per_hatch_min = round(zerg_larva_spent[pid] / (h_sec / 60.0), 2)
                h10 = prod_counts_18m[pid]["Hatchery"][10] if len(prod_counts_18m[pid]["Hatchery"]) > 10 else None
                q10 = prod_counts_18m[pid]["Queen"][10] if len(prod_counts_18m[pid]["Queen"]) > 10 else None
                if h10 and h10 > 0 and q10 is not None:
                    queens_per_hatch_10m = round(q10 / float(h10), 2)

            prod_util_rec = {
                "counts_18m": prod_counts_18m[pid],
                "peak_counts": peak_prod_counts[pid],
                "util_pct": util_by_fg,
                "overall_prod_util_pct": overall_prod_util,
                "larva_spent_per_hatch_min": larva_per_hatch_min,
                "queens_per_hatch_10m": queens_per_hatch_10m,
            }

            # Graphs 20 & 21: Macro abilities, targets & exact LotV energy simulation
            caster_key = "Nexus" if race == "Protoss" else ("OrbitalCommand" if race == "Terran" else "Queen")
            energy_cast_evs: list[tuple[float, str, float, tuple[int, ...], str | None, bool]] = []
            if race == "Terran":
                for ts in tracker_macro_times[pid]["mule"]:
                    energy_cast_evs.append((ts, "mule", 50.0, (), None, True))
            elif race == "Zerg":
                for ts in tracker_macro_times[pid]["creep_tumor_queen"]:
                    energy_cast_evs.append((ts, "creep_tumor_queen", 25.0, (), None, True))

            if ge_p is not None:
                for sec_c, ab_k, pref_u, tgt_b in ge_p["macro_casts"]:
                    mc_spec = MACRO_ABILITY_ENERGY_COST.get(ab_k)
                    if mc_spec is not None and mc_spec[0] == caster_key:
                        energy_cast_evs.append((sec_c, ab_k, mc_spec[1], pref_u, tgt_b, False))

            lifetimes_clean = [
                (float(r[0]), float(r[1]), int(r[2]), float(r[3]))
                for r in macro_caster_lifetimes[pid][caster_key]
            ]
            e_sim = _simulate_macro_energy(lifetimes_clean, energy_cast_evs, dur_sec)
            acc_times = e_sim["accepted_times"]

            # Build Graph 20 accepted counts & 18m cumulative curves
            macro_counts: dict[str, int] = {}
            macro_cum_18m: dict[str, list[int | None]] = {}
            if race == "Protoss":
                for ak in ("chrono_boost", "energy_recharge", "recall", "battery_overcharge"):
                    ts_l = acc_times.get(ak, [])
                    macro_counts[ak] = len(ts_l)
                    if ak in ("chrono_boost", "energy_recharge"):
                        macro_cum_18m[ak] = _cum_counts_18m(ts_l, dur_sec)
            elif race == "Terran":
                # MULE comes from tracker truth (always valid); scan & supply_drop from energy-validated ge_p
                mule_ts = tracker_macro_times[pid]["mule"]
                macro_counts["mule"] = len(mule_ts)
                macro_cum_18m["mule"] = _cum_counts_18m(mule_ts, dur_sec)
                for ak in ("scan", "supply_drop"):
                    ts_l = acc_times.get(ak, [])
                    macro_counts[ak] = len(ts_l)
                    macro_cum_18m[ak] = _cum_counts_18m(ts_l, dur_sec)
            else:
                # Creep tumors from tracker truth; inject & transfuse from energy-validated ge_p
                for ak in ("creep_tumor_queen", "creep_tumor_spread"):
                    ts_l = tracker_macro_times[pid][ak]
                    macro_counts[ak] = len(ts_l)
                    macro_cum_18m[ak] = _cum_counts_18m(ts_l, dur_sec)
                for ak in ("inject", "transfuse"):
                    ts_l = acc_times.get(ak, [])
                    macro_counts[ak] = len(ts_l)
                    macro_cum_18m[ak] = _cum_counts_18m(ts_l, dur_sec)

            # Graph 20 Phase & Situation splits (#1750)
            own_pressure_ts = sorted(
                [d[0] for d in all_deaths if d[1] == pid]
                + [cd[0] for cd in combat_deaths if cd[1] == pid]
            )
            opp_cloak_t = first_cloak_threat_sec[opp_pid]
            phase_mins = {
                lbl: round(max(0.0, min(dur_sec, hi) - lo) / 60.0, 3)
                for lbl, lo, hi in MACRO_PHASES
            }

            chrono_by_phase: dict[str, dict[str, int]] = {}
            chrono_by_sit: dict[str, dict[str, int]] = {}
            er_by_phase: dict[str, int] = {}
            oc_by_phase: dict[str, dict[str, int]] = {}
            oc_by_sit: dict[str, dict[str, int]] = {}
            oc_by_cloak: dict[str, dict[str, int]] = {}
            queen_by_phase: dict[str, dict[str, int]] = {}
            queen_by_sit: dict[str, dict[str, int]] = {}

            if race == "Protoss":
                chrono_by_phase = {ph: defaultdict(int) for ph in MACRO_PHASE_LABELS}
                chrono_by_sit = {"peaceful": defaultdict(int), "under_pressure": defaultdict(int)}
                for sec_c, bkt in e_sim["accepted_chrono_events"]:
                    ph = _macro_phase_label(sec_c)
                    sit = "under_pressure" if _has_event_near(own_pressure_ts, sec_c, 20.0) else "peaceful"
                    chrono_by_phase[ph][bkt] += 1
                    chrono_by_sit[sit][bkt] += 1
                chrono_by_phase = {ph: dict(d_c) for ph, d_c in chrono_by_phase.items()}
                chrono_by_sit = {s: dict(d_c) for s, d_c in chrono_by_sit.items()}
                er_by_phase = {ph: 0 for ph in MACRO_PHASE_LABELS}
                for sec_c in acc_times.get("energy_recharge", ()):
                    er_by_phase[_macro_phase_label(sec_c)] += 1

            elif race == "Terran":
                oc_by_phase = {ph: {"MULE": 0, "Scan": 0, "SupplyDrop": 0} for ph in MACRO_PHASE_LABELS}
                oc_by_sit = {
                    "peaceful": {"MULE": 0, "Scan": 0, "SupplyDrop": 0},
                    "under_pressure": {"MULE": 0, "Scan": 0, "SupplyDrop": 0},
                }
                oc_by_cloak = {
                    "no_cloak": {"MULE": 0, "Scan": 0, "SupplyDrop": 0},
                    "cloak_seen": {"MULE": 0, "Scan": 0, "SupplyDrop": 0},
                }
                for ak, lbl_oc in (("mule", "MULE"), ("scan", "Scan"), ("supply_drop", "SupplyDrop")):
                    ts_src = tracker_macro_times[pid]["mule"] if ak == "mule" else acc_times.get(ak, ())
                    for sec_c in ts_src:
                        ph = _macro_phase_label(sec_c)
                        sit = "under_pressure" if _has_event_near(own_pressure_ts, sec_c, 20.0) else "peaceful"
                        clk = "cloak_seen" if sec_c >= opp_cloak_t else "no_cloak"
                        oc_by_phase[ph][lbl_oc] += 1
                        oc_by_sit[sit][lbl_oc] += 1
                        oc_by_cloak[clk][lbl_oc] += 1

            else:
                queen_by_phase = {ph: {"Inject": 0, "CreepTumor": 0, "Transfuse": 0} for ph in MACRO_PHASE_LABELS}
                queen_by_sit = {
                    "peaceful": {"Inject": 0, "CreepTumor": 0, "Transfuse": 0},
                    "under_pressure": {"Inject": 0, "CreepTumor": 0, "Transfuse": 0},
                }
                for ak, lbl_q, ecost in (
                    ("inject", "Inject", 25),
                    ("creep_tumor_queen", "CreepTumor", 25),
                    ("transfuse", "Transfuse", 50),
                ):
                    ts_src = tracker_macro_times[pid]["creep_tumor_queen"] if ak == "creep_tumor_queen" else acc_times.get(ak, ())
                    for sec_c in ts_src:
                        ph = _macro_phase_label(sec_c)
                        sit = "under_pressure" if _has_event_near(own_pressure_ts, sec_c, 20.0) else "peaceful"
                        queen_by_phase[ph][lbl_q] += ecost
                        queen_by_sit[sit][lbl_q] += ecost

            macro_abil_rec = {
                "counts": macro_counts,
                "cum_18m": macro_cum_18m,
                "chrono_targets": e_sim["accepted_chrono_targets"] if race == "Protoss" else {},
                "active_tumors_6_10_14_pk": (
                    [
                        active_tumors_18m[pid][6],
                        active_tumors_18m[pid][10],
                        active_tumors_18m[pid][14],
                        peak_active_tumors[pid],
                    ]
                    if race == "Zerg"
                    else None
                ),
                "phase_mins": phase_mins,
                "chrono_by_phase": chrono_by_phase,
                "chrono_by_situation": chrono_by_sit,
                "energy_recharge_by_phase": er_by_phase,
                "oc_by_phase": oc_by_phase,
                "oc_by_situation": oc_by_sit,
                "oc_by_cloak": oc_by_cloak,
                "queen_by_phase": queen_by_phase,
                "queen_by_situation": queen_by_sit,
            }
            macro_energy_rec = {
                "caster": caster_key,
                "alive_sec": e_sim["alive_sec"],
                "spend_efficiency_pct": e_sim["spend_efficiency_pct"] if ge_p is not None else None,
                "time_capped_180_pct": e_sim["time_capped_180_pct"] if ge_p is not None else None,
                "mean_energy_overall": e_sim["mean_energy_overall"] if ge_p is not None else None,
                "mean_energy_curve_18m": e_sim["mean_energy_curve_18m"] if ge_p is not None else None,
            }

            # Graph 22: Combat spell & mode-morph counts + built casters
            merged_spells: dict[str, int] = dict(tracker_spells[pid])
            if ge_p is not None:
                for sk, sv in ge_p["scmd_spells"].items():
                    merged_spells[sk] = merged_spells.get(sk, 0) + int(sv)
                # Keep Transfuse & Recall aligned with energy-validated counts
                if race == "Zerg":
                    merged_spells["transfuse"] = macro_counts.get("transfuse", 0)
                elif race == "Protoss":
                    merged_spells["recall"] = macro_counts.get("recall", 0)
            combat_spells_rec = {
                "casters_built": sorted(casters_built[pid]),
                "counts": merged_spells,
            }

            curves_rec = {
                "apm": ge_p["apm_curve"] if ge_p else None,
                "epm": ge_p["epm_curve"] if ge_p else None,
                "spm": ge_p["spm_curve"] if ge_p else None,
                "army_minerals": snap_curves["army_minerals"],
                "army_gas": snap_curves["army_gas"],
                "collection_minerals": snap_curves["collection_minerals"],
                "collection_gas": snap_curves["collection_gas"],
            }
            summary_rec = {
                "apm": ge_p["apm_game"] if ge_p else None,
                "epm": ge_p["epm_game"] if ge_p else None,
                "spm": ge_p["spm_game"] if ge_p else None,
                **snap_summary,
                "army_fragmentation_pct": round(sum(fvals) / len(fvals), 1) if fvals else None,
                "active_clusters": round(sum(cvals) / len(cvals), 2) if cvals else None,
                "army_retention_ratio": round(sum(rvals) / len(rvals), 3) if rvals else None,
                "peak_to_cum_retention": peak_to_cum_ret,
                "peak_active_bases": peak_active_ths[pid],
                "peak_active_gas": peak_active_gas[pid],
                "reached_4plus_bases": reached_4plus,
                "gas_per_base_4plus": gpb4,
            }
            timings_rec = _extract_timings(
                race,
                bldg_inits[pid],
                th_inits[pid],
                self_canceled_tags,
                morphs[pid],
                upgrades[pid],
            )
            results.append({
                "cohort": cohort_by_pid[pid],
                "race": race,
                "matchup": matchup,
                "won": bool(result_by_pid[pid] == 1),
                "result_code": result_by_pid[pid],
                "duration_sec": round(dur_sec, 1),
                "base_build": bb,
                "replay": rname,
                "game_events_ok": bool(ge_p is not None),
                "curves": curves_rec,
                "summary": summary_rec,
                "timings": timings_rec,
                # Graphs 9-14 per-game payloads
                "cohesion_16m": {
                    "army_fragmentation_pct": frag_pct_b[pid],
                    "active_clusters": clusters_b[pid],
                    "army_retention_ratio": ret_curve_16m,
                },
                "clashes": clashes_by_pid[pid],
                "expansions_18m": {
                    "active_townhalls": th_active_b[pid],
                    "active_gas_geysers": gas_active_b[pid],
                    "base_4plus_timings": base_4plus_timings,
                    "gas_7plus_timings": gas_7plus_timings,
                },
                "tier_mix": tier_mix_b[pid],
                "all_upgrades": all_upgrades[pid],
                # Graphs 15-18 per-game payloads (schema v3)
                "concave_samples": concave_by_pid[pid],
                "rotation_mp": {
                    "def_rotations": rot_mp_by_pid[pid]["def_rotations"],
                    "off_rot_count": rot_mp_by_pid[pid]["off_rot_count"],
                    "off_front_idle_pcts": off_front_idle_by_pid[pid],
                    "mp_count": rot_mp_by_pid[pid]["mp_count"],
                    "bs_count": rot_mp_by_pid[pid]["bs_count"],
                    "bs_wk_kills": rot_mp_by_pid[pid]["bs_wk_kills"],
                },
                "unit_comp_2_18m": unit_comp_b[pid],
                # Graphs 19-22 per-game payloads (schema v4)
                "prod_util": prod_util_rec,
                "macro_abil": macro_abil_rec,
                "macro_energy": macro_energy_rec,
                "combat_spells": combat_spells_rec,
            })
    except Exception:
        return []
    return results


def load_or_build_pro_cache(
    pro_dir: Path,
    cache_path: Path,
    pylibs_dir: Path,
    buckets_sec: list[int],
    bucket_sec: int,
    min_dur_sec: float,
    jobs: int,
    rebuild: bool,
) -> tuple[list[dict[str, Any]], bool, int]:
    """Load Pro GM per-player records from cache or parse `pro_dir` and persist cache."""
    replays = sorted(pro_dir.glob("*.SC2Replay"))
    sig = {
        "cache_schema_version": CACHE_SCHEMA_VERSION,
        "pro_dir": str(pro_dir.resolve()),
        "replay_count": len(replays),
        "bucket_sec": bucket_sec,
        "max_time_sec": buckets_sec[-1],
        "min_dur_sec_pro": float(min_dur_sec),
        "lotv_min_base_build": LOTV_MIN_BASE_BUILD,
    }

    if not rebuild and cache_path.is_file():
        try:
            cached = json.loads(cache_path.read_text(encoding="utf-8"))
            if cached.get("signature") == sig and isinstance(cached.get("records"), list):
                return cached["records"], True, int(cached.get("valid_replays") or 0)
        except Exception:
            pass

    work = [
        (str(rp), str(pylibs_dir), "pro", float(min_dur_sec), buckets_sec, bucket_sec, None)
        for rp in replays
    ]
    records: list[dict[str, Any]] = []
    valid_replays = 0
    if work:
        with concurrent.futures.ProcessPoolExecutor(max_workers=max(1, jobs)) as ex:
            for batch in ex.map(_parse_single_replay, work, chunksize=8):
                if batch:
                    valid_replays += 1
                    records.extend(batch)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "signature": sig,
        "valid_replays": valid_replays,
        "records": records,
    }
    cache_path.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    return records, False, valid_replays


def load_arena_replays_from_dir(
    run_dir: Path,
    pylibs_dir: Path,
    buckets_sec: list[int],
    bucket_sec: int,
    min_dur_sec: float,
    jobs: int,
) -> tuple[list[dict[str, Any]], str, Path]:
    """Parse external Mothman + Opponent replays from a run directory."""
    rep_dir = run_dir / "replays" if (run_dir / "replays").is_dir() else run_dir
    run_id = run_dir.name if run_dir.name != "replays" else run_dir.parent.name
    replays = sorted(rep_dir.glob("*.SC2Replay"))
    work = [
        (str(rp), str(pylibs_dir), "arena", float(min_dur_sec), buckets_sec, bucket_sec, None)
        for rp in replays
    ]
    records: list[dict[str, Any]] = []
    if work:
        with concurrent.futures.ProcessPoolExecutor(max_workers=max(1, jobs)) as ex:
            for batch in ex.map(_parse_single_replay, work, chunksize=4):
                if batch:
                    records.extend(batch)
    return records, run_id, rep_dir


def load_arena_replays_from_sqlite(
    db_path: Path,
    run_prefixes: list[str],
    pylibs_dir: Path,
    buckets_sec: list[int],
    bucket_sec: int,
    min_dur_sec: float,
    jobs: int,
) -> tuple[list[dict[str, Any]], str, Path]:
    """Load non-selfplay replay paths from read-only SQLite and parse both sides."""
    p = os.path.abspath(os.path.expanduser(str(db_path)))
    conn = sqlite3.connect(Path(p).as_uri() + "?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        like_clauses = " OR ".join("run_id LIKE ?" for _ in run_prefixes)
        params = [f"%{pref}%" for pref in run_prefixes] + [float(min_dur_sec)]
        rows = conn.execute(
            f"""
            SELECT replay_path, our_player_id, run_id
            FROM matches
            WHERE ({like_clauses})
              AND COALESCE(is_selfplay, 0) = 0
              AND COALESCE(duration_sec, 0) >= ?
            ORDER BY replay_mtime DESC
            """,
            params,
        ).fetchall()
    finally:
        conn.close()

    work = [
        (
            str(r["replay_path"]),
            str(pylibs_dir),
            "arena",
            float(min_dur_sec),
            buckets_sec,
            bucket_sec,
            int(r["our_player_id"]) if r["our_player_id"] in (1, 2) else None,
        )
        for r in rows
        if r["replay_path"] and os.path.exists(str(r["replay_path"]))
    ]
    records: list[dict[str, Any]] = []
    if work:
        with concurrent.futures.ProcessPoolExecutor(max_workers=max(1, jobs)) as ex:
            for batch in ex.map(_parse_single_replay, work, chunksize=4):
                if batch:
                    records.extend(batch)
    run_label = ",".join(run_prefixes)
    return records, run_label, db_path


def aggregate_all(
    records: list[dict[str, Any]],
    buckets_sec: list[int],
    meta: dict[str, Any],
) -> dict[str, Any]:
    """Aggregate per-player records into curves, game summaries, and race timings."""
    by_cohort: dict[str, list[dict[str, Any]]] = {c: [] for c in COHORTS}
    for r in records:
        c = r["cohort"]
        if c in by_cohort:
            by_cohort[c].append(r)

    # Cohort counts metadata
    cohort_labels = {
        "mothman": "Mothman",
        "opponents": "Opponents",
        "pros": "Pro GM (LotV)",
    }
    cohorts_meta: dict[str, Any] = {}
    for c in COHORTS:
        crecs = by_cohort[c]
        cohorts_meta[c] = {
            "label": cohort_labels[c],
            "games": len(crecs),
            "game_events_games": sum(1 for r in crecs if r.get("game_events_ok")),
            "by_race": {
                rc: sum(1 for r in crecs if r["race"] == rc) for rc in RACES
            },
            "median_duration_sec": _pctiles([r["duration_sec"] for r in crecs])["med"],
        }
    meta["cohorts"] = cohorts_meta

    # Build curves[segment][metric][cohort] and summary[segment][metric][cohort]
    curves_out: dict[str, Any] = {}
    summary_out: dict[str, Any] = {}

    for seg in SEGMENTS:
        curves_out[seg] = {}
        summary_out[seg] = {}
        seg_by_cohort: dict[str, list[dict[str, Any]]] = {
            c: [r for r in by_cohort[c] if seg == "all" or r["race"] == seg]
            for c in COHORTS
        }

        for metric in CURVE_METRICS:
            curves_out[seg][metric] = {}
            summary_out[seg][metric] = {}

            for c in COHORTS:
                crecs = seg_by_cohort[c]

                # 30s bucketed curves
                pts: list[dict[str, Any]] = []
                for idx, t in enumerate(buckets_sec):
                    vals: list[float] = []
                    for r in crecs:
                        arr = r["curves"].get(metric)
                        if arr is not None and idx < len(arr) and arr[idx] is not None:
                            vals.append(float(arr[idx]))
                    st = _pctiles(vals, prec=1)
                    pts.append({"t": t, **st})
                curves_out[seg][metric][c] = pts

                # Game-level summary
                gvals = [
                    float(r["summary"][metric])
                    for r in crecs
                    if r["summary"].get(metric) is not None
                ]
                sdict = _pctiles(gvals, prec=1)
                if metric in SNAPSHOT_METRICS:
                    pk_key = f"{metric}_peak"
                    pvals = [
                        float(r["summary"][pk_key])
                        for r in crecs
                        if r["summary"].get(pk_key) is not None
                    ]
                    sdict["peak"] = _pctiles(pvals, prec=1)
                summary_out[seg][metric][c] = sdict

    # Build timings[race] (ordered list of milestones)
    timings_out: dict[str, list[dict[str, Any]]] = {}
    for race in RACES:
        rows: list[dict[str, Any]] = []
        race_by_cohort = {
            c: [r for r in by_cohort[c] if r["race"] == race] for c in COHORTS
        }
        for key, label, kind, _src, _names, _nth in TIMING_MILESTONES[race]:
            entry: dict[str, Any] = {
                "key": key,
                "label": label,
                "kind": kind,
            }
            for c in COHORTS:
                crecs = race_by_cohort[c]
                total = len(crecs)
                tvals = [
                    float(r["timings"][key])
                    for r in crecs
                    if r["timings"].get(key) is not None
                ]
                st = _pctiles(tvals, prec=1)
                adopt_pct = round(100.0 * st["n"] / total, 1) if total > 0 else 0.0
                entry[c] = {
                    **st,
                    "total": total,
                    "adopt_pct": adopt_pct,
                    "med_fmt": _fmt_sec(st["med"]),
                }
            rows.append(entry)
        timings_out[race] = rows

    # -------------------------------------------------------------------------
    # Graph 9: Army Fragmentation, Active Clusters & Retention (0:00..16:00)
    # -------------------------------------------------------------------------
    cohesion_metrics = (
        ("army_fragmentation_pct", 1),
        ("active_clusters", 2),
        ("army_retention_ratio", 3),
    )
    cohesion_curves: dict[str, Any] = {}
    cohesion_summary: dict[str, Any] = {}
    for seg in SEGMENTS:
        cohesion_curves[seg] = {}
        cohesion_summary[seg] = {}
        seg_by_cohort = {
            c: [r for r in by_cohort[c] if seg == "all" or r["race"] == seg]
            for c in COHORTS
        }
        for mkey, prec in cohesion_metrics:
            cohesion_curves[seg][mkey] = {}
            cohesion_summary[seg][mkey] = {}
            for c in COHORTS:
                crecs = seg_by_cohort[c]
                pts: list[dict[str, Any]] = []
                for idx, t in enumerate(BUCKETS_16M_SEC):
                    vals = [
                        float(r["cohesion_16m"][mkey][idx])
                        for r in crecs
                        if r.get("cohesion_16m")
                        and r["cohesion_16m"].get(mkey)
                        and idx < len(r["cohesion_16m"][mkey])
                        and r["cohesion_16m"][mkey][idx] is not None
                    ]
                    pts.append({"t": t, **_pctiles(vals, prec=prec)})
                cohesion_curves[seg][mkey][c] = pts
                gvals = [
                    float(r["summary"][mkey])
                    for r in crecs
                    if r.get("summary") and r["summary"].get(mkey) is not None
                ]
                sdict = _pctiles(gvals, prec=prec)
                if mkey == "army_retention_ratio":
                    p2c = [
                        float(r["summary"]["peak_to_cum_retention"])
                        for r in crecs
                        if r.get("summary") and r["summary"].get("peak_to_cum_retention") is not None
                    ]
                    sdict["peak_to_cum"] = _pctiles(p2c, prec=3)
                cohesion_summary[seg][mkey][c] = sdict

    army_cohesion_out = {
        "buckets_sec": BUCKETS_16M_SEC,
        "buckets_label": [_fmt_sec(float(t)) for t in BUCKETS_16M_SEC],
        "cluster_radius_tiles": 14.0,
        "curves": cohesion_curves,
        "summary": cohesion_summary,
    }

    # -------------------------------------------------------------------------
    # Graph 10: When Pros Engage vs. Retreat (Force-Ratio Curves & Thresholds)
    # -------------------------------------------------------------------------
    engage_retreat_by_seg: dict[str, Any] = {}
    bin_labels = [b[0] for b in FORCE_RATIO_BINS]
    for seg in SEGMENTS:
        engage_retreat_by_seg[seg] = {}
        for c in COHORTS:
            crecs = [r for r in by_cohort[c] if seg == "all" or r["race"] == seg]
            all_clashes: list[tuple[float, int]] = []
            for r in crecs:
                for pair in r.get("clashes") or ():
                    all_clashes.append((float(pair[0]), int(pair[1])))
            n_tot = len(all_clashes)
            eng_ratios = [r for r, d in all_clashes if d == 0]
            ret_ratios = [r for r, d in all_clashes if d == 1]
            all_ratios = [r for r, _ in all_clashes]
            outnum = [(r, d) for r, d in all_clashes if r < 0.75]
            outnum_dis = [r for r, d in outnum if d == 1]

            bins_data: list[dict[str, Any]] = []
            for blbl, lo, hi in FORCE_RATIO_BINS:
                sub = [(r, d) for r, d in all_clashes if lo <= r < hi]
                nc = len(sub)
                nd = sum(d for _, d in sub)
                bins_data.append({
                    "bin": blbl,
                    "clashes": nc,
                    "share_pct": round(100.0 * nc / n_tot, 1) if n_tot > 0 else 0.0,
                    "disengage_cnt": nd,
                    "disengage_pct": round(100.0 * nd / nc, 1) if nc > 0 else None,
                })

            engage_retreat_by_seg[seg][c] = {
                "games": len(crecs),
                "clashes_total": n_tot,
                "median_clash_ratio": _pctiles(all_ratios, prec=2)["med"],
                "median_engage_ratio": _pctiles(eng_ratios, prec=2)["med"],
                "median_retreat_ratio": _pctiles(ret_ratios, prec=2)["med"],
                "outnumbered_engage_pct": round(100.0 * len(outnum) / n_tot, 1) if n_tot > 0 else None,
                "outnumbered_disengage_pct": round(100.0 * len(outnum_dis) / len(outnum), 1) if outnum else None,
                "overall_disengage_pct": round(100.0 * len(ret_ratios) / n_tot, 1) if n_tot > 0 else None,
                "bins_data": bins_data,
            }

    engage_retreat_out = {
        "bins": bin_labels,
        "clash_radius_tiles": 18.0,
        "local_force_radius_tiles": 22.0,
        "disengage_pullback_tiles": 8.0,
        "disengage_survival_min": 0.50,
        "by_segment": engage_retreat_by_seg,
    }

    # -------------------------------------------------------------------------
    # Graph 11: Expansions & Base 4+ Scaling (0:00..18:00 + Base #4/#5/#6 Timings)
    # -------------------------------------------------------------------------
    exp_active_th: dict[str, Any] = {}
    exp_reach_4plus: dict[str, Any] = {}
    for seg in SEGMENTS:
        exp_active_th[seg] = {}
        exp_reach_4plus[seg] = {}
        for c in COHORTS:
            crecs = [r for r in by_cohort[c] if seg == "all" or r["race"] == seg]
            pts: list[dict[str, Any]] = []
            for idx, t in enumerate(BUCKETS_18M_SEC):
                vals = [
                    float(r["expansions_18m"]["active_townhalls"][idx])
                    for r in crecs
                    if r.get("expansions_18m")
                    and r["expansions_18m"].get("active_townhalls")
                    and idx < len(r["expansions_18m"]["active_townhalls"])
                    and r["expansions_18m"]["active_townhalls"][idx] is not None
                ]
                pts.append({"t": t, **_pctiles(vals, prec=2)})
            exp_active_th[seg][c] = pts

            n_all = len(crecs)
            r_all = sum(1 for r in crecs if r.get("summary", {}).get("reached_4plus_bases"))
            g10 = [r for r in crecs if float(r.get("duration_sec", 0.0)) >= 600.0]
            r10 = sum(1 for r in g10 if r.get("summary", {}).get("reached_4plus_bases"))
            g14 = [r for r in crecs if float(r.get("duration_sec", 0.0)) >= 840.0]
            r14 = sum(1 for r in g14 if r.get("summary", {}).get("reached_4plus_bases"))
            pk_b = [
                float(r["summary"]["peak_active_bases"])
                for r in crecs
                if r.get("summary", {}).get("peak_active_bases") is not None
            ]
            exp_reach_4plus[seg][c] = {
                "n_all": n_all,
                "pct_all": round(100.0 * r_all / n_all, 1) if n_all > 0 else 0.0,
                "n_ge10m": len(g10),
                "pct_ge10m": round(100.0 * r10 / len(g10), 1) if g10 else 0.0,
                "n_ge14m": len(g14),
                "pct_ge14m": round(100.0 * r14 / len(g14), 1) if g14 else 0.0,
                "peak_bases": _pctiles(pk_b, prec=2),
            }

    base_4plus_milestones = (
        ("fourth", "4th Base"),
        ("fifth", "5th Base"),
        ("sixth", "6th Base"),
    )
    base_4plus_timings_out: dict[str, list[dict[str, Any]]] = {}
    for seg in SEGMENTS:
        brows: list[dict[str, Any]] = []
        for bkey, blbl in base_4plus_milestones:
            entry: dict[str, Any] = {"key": bkey, "label": blbl}
            for c in COHORTS:
                crecs = [r for r in by_cohort[c] if seg == "all" or r["race"] == seg]
                total = len(crecs)
                tvals = [
                    float(r["expansions_18m"]["base_4plus_timings"][bkey])
                    for r in crecs
                    if r.get("expansions_18m", {}).get("base_4plus_timings", {}).get(bkey) is not None
                ]
                st = _pctiles(tvals, prec=1)
                entry[c] = {
                    **st,
                    "total": total,
                    "adopt_pct": round(100.0 * st["n"] / total, 1) if total > 0 else 0.0,
                    "med_fmt": _fmt_sec(st["med"]),
                }
            brows.append(entry)
        base_4plus_timings_out[seg] = brows

    expansions_4plus_out = {
        "buckets_sec": BUCKETS_18M_SEC,
        "buckets_label": [_fmt_sec(float(t)) for t in BUCKETS_18M_SEC],
        "active_townhalls": exp_active_th,
        "reach_4plus": exp_reach_4plus,
        "base_timings": base_4plus_timings_out,
    }

    # -------------------------------------------------------------------------
    # Graph 12: Gas Geysers (7+, Bases 4+) Over Time & Timings (0:00..18:00)
    # -------------------------------------------------------------------------
    gas_active_out: dict[str, Any] = {}
    gas_per_base_4plus_out: dict[str, Any] = {}
    for seg in SEGMENTS:
        gas_active_out[seg] = {}
        gas_per_base_4plus_out[seg] = {}
        for c in COHORTS:
            crecs = [r for r in by_cohort[c] if seg == "all" or r["race"] == seg]
            pts = []
            for idx, t in enumerate(BUCKETS_18M_SEC):
                vals = [
                    float(r["expansions_18m"]["active_gas_geysers"][idx])
                    for r in crecs
                    if r.get("expansions_18m")
                    and r["expansions_18m"].get("active_gas_geysers")
                    and idx < len(r["expansions_18m"]["active_gas_geysers"])
                    and r["expansions_18m"]["active_gas_geysers"][idx] is not None
                ]
                pts.append({"t": t, **_pctiles(vals, prec=2)})
            gas_active_out[seg][c] = pts
            gpb_vals = [
                float(r["summary"]["gas_per_base_4plus"])
                for r in crecs
                if r.get("summary", {}).get("gas_per_base_4plus") is not None
            ]
            pk_g = [
                float(r["summary"]["peak_active_gas"])
                for r in crecs
                if r.get("summary", {}).get("peak_active_gas") is not None
            ]
            gas_per_base_4plus_out[seg][c] = {
                **_pctiles(gpb_vals, prec=2),
                "peak_gas": _pctiles(pk_g, prec=2),
            }

    gas_7plus_milestones = (
        ("gas_7", "Gas #7 (4th Base)"),
        ("gas_8", "Gas #8 (4th Base)"),
        ("gas_9", "Gas #9 (5th Base)"),
        ("gas_10", "Gas #10 (5th Base)"),
    )
    gas_7plus_timings_out: dict[str, list[dict[str, Any]]] = {}
    for seg in SEGMENTS:
        grows: list[dict[str, Any]] = []
        for gkey, glbl in gas_7plus_milestones:
            entry = {"key": gkey, "label": glbl}
            for c in COHORTS:
                crecs = [r for r in by_cohort[c] if seg == "all" or r["race"] == seg]
                total = len(crecs)
                tvals = [
                    float(r["expansions_18m"]["gas_7plus_timings"][gkey])
                    for r in crecs
                    if r.get("expansions_18m", {}).get("gas_7plus_timings", {}).get(gkey) is not None
                ]
                st = _pctiles(tvals, prec=1)
                entry[c] = {
                    **st,
                    "total": total,
                    "adopt_pct": round(100.0 * st["n"] / total, 1) if total > 0 else 0.0,
                    "med_fmt": _fmt_sec(st["med"]),
                }
            grows.append(entry)
        gas_7plus_timings_out[seg] = grows

    gas_7plus_out = {
        "buckets_sec": BUCKETS_18M_SEC,
        "buckets_label": [_fmt_sec(float(t)) for t in BUCKETS_18M_SEC],
        "active_gas_geysers": gas_active_out,
        "gas_per_base_4plus": gas_per_base_4plus_out,
        "gas_timings": gas_7plus_timings_out,
    }

    # -------------------------------------------------------------------------
    # Graph 13: T1 / T2 / T3 Unit Composition Mix (2m..18m, by Race & 9 Matchups)
    # -------------------------------------------------------------------------
    def _agg_tier_slice(crecs: list[dict[str, Any]]) -> list[dict[str, Any]]:
        pts = []
        for idx, t in enumerate(BUCKETS_TIER_SEC):
            t1s: list[float] = []
            t2s: list[float] = []
            t3s: list[float] = []
            for r in crecs:
                tm = r.get("tier_mix")
                if tm and idx < len(tm) and tm[idx] is not None:
                    t1s.append(float(tm[idx][0]))
                    t2s.append(float(tm[idx][1]))
                    t3s.append(float(tm[idx][2]))
            n = len(t1s)
            if n > 0:
                m1 = round(sum(t1s) / n, 1)
                m2 = round(sum(t2s) / n, 1)
                m3 = round(max(0.0, 100.0 - m1 - m2), 1)
                pts.append({
                    "t": t,
                    "label": _fmt_sec(float(t)),
                    "n": n,
                    "t1_pct": m1,
                    "t2_pct": m2,
                    "t3_pct": m3,
                    "t1_med": _pctiles(t1s, 1)["med"],
                    "t2_med": _pctiles(t2s, 1)["med"],
                    "t3_med": _pctiles(t3s, 1)["med"],
                })
            else:
                pts.append({
                    "t": t,
                    "label": _fmt_sec(float(t)),
                    "n": 0,
                    "t1_pct": None,
                    "t2_pct": None,
                    "t3_pct": None,
                    "t1_med": None,
                    "t2_med": None,
                    "t3_med": None,
                })
        return pts

    tier_by_seg = {
        seg: {
            c: _agg_tier_slice([r for r in by_cohort[c] if seg == "all" or r["race"] == seg])
            for c in COHORTS
        }
        for seg in SEGMENTS
    }
    tier_by_mu = {
        mu: {
            c: _agg_tier_slice([r for r in by_cohort[c] if r.get("matchup") == mu])
            for c in COHORTS
        }
        for mu in MATCHUPS
    }
    tier_composition_out = {
        "buckets_sec": BUCKETS_TIER_SEC,
        "buckets_label": [_fmt_sec(float(t)) for t in BUCKETS_TIER_SEC],
        "by_segment": tier_by_seg,
        "by_matchup": tier_by_mu,
    }

    # -------------------------------------------------------------------------
    # Graph 14: ALL Upgrade Timings (Complete Exhaustive Catalog by Race & Matchup)
    # -------------------------------------------------------------------------
    def _agg_all_upgrades(slice_by_cohort: dict[str, list[dict[str, Any]]]) -> list[dict[str, Any]]:
        seen: set[str] = set()
        for c in COHORTS:
            for r in slice_by_cohort[c]:
                seen.update((r.get("all_upgrades") or {}).keys())
        urows: list[dict[str, Any]] = []
        for uname in sorted(seen):
            entry: dict[str, Any] = {
                "key": uname,
                "label": _friendly_upgrade_label(uname),
            }
            for c in COHORTS:
                crecs = slice_by_cohort[c]
                total = len(crecs)
                tvals = [
                    float(r["all_upgrades"][uname])
                    for r in crecs
                    if r.get("all_upgrades") and uname in r["all_upgrades"]
                ]
                st = _pctiles(tvals, prec=1)
                entry[c] = {
                    **st,
                    "total": total,
                    "adopt_pct": round(100.0 * st["n"] / total, 1) if total > 0 else 0.0,
                    "med_fmt": _fmt_sec(st["med"]),
                }
            mm_med = entry["mothman"]["med"]
            pr_med = entry["pros"]["med"]
            entry["delta_vs_pro_sec"] = (
                round(mm_med - pr_med, 1) if (mm_med is not None and pr_med is not None) else None
            )
            urows.append(entry)
        urows.sort(
            key=lambda x: (
                -(x["pros"]["adopt_pct"] or 0.0),
                -(x["mothman"]["adopt_pct"] or 0.0),
                x["pros"]["med"] if x["pros"]["med"] is not None else 99999.0,
                x["key"],
            )
        )
        return urows

    all_upg_by_race = {
        race: _agg_all_upgrades({c: [r for r in by_cohort[c] if r["race"] == race] for c in COHORTS})
        for race in RACES
    }
    all_upg_by_mu = {
        mu: _agg_all_upgrades({c: [r for r in by_cohort[c] if r.get("matchup") == mu] for c in COHORTS})
        for mu in MATCHUPS
    }
    all_upgrades_out = {
        "by_race": all_upg_by_race,
        "by_matchup": all_upg_by_mu,
    }

    # -------------------------------------------------------------------------
    # Graph 15: Concave Geometry & Front-to-Back Layering (by Race & 9 Matchups)
    # -------------------------------------------------------------------------
    def _agg_concave_slice(crecs: list[dict[str, Any]]) -> dict[str, Any]:
        aspects: list[float] = []
        deltas: list[float] = []
        clumps: list[float] = []
        clashes_m = 0
        for r in crecs:
            for item in r.get("concave_samples") or ():
                clashes_m += 1
                if item[0] is not None:
                    aspects.append(float(item[0]))
                if item[1] is not None:
                    deltas.append(float(item[1]))
                if item[2] is not None:
                    clumps.append(float(item[2]))
        inv_cnt = sum(1 for d in deltas if d > 0.0)
        return {
            "games": len(crecs),
            "clashes_measured": clashes_m,
            "layered_clashes": len(deltas),
            "concave_aspect": _pctiles(aspects, prec=2),
            "layering_delta_tiles": _pctiles(deltas, prec=2),
            "role_inversion_pct": round(100.0 * inv_cnt / len(deltas), 1) if deltas else None,
            "splash_clump_pct": _pctiles(clumps, prec=1),
        }

    concave_layering_out = {
        "clash_radius_tiles": 16.0,
        "enemy_radius_tiles": 22.0,
        "clump_radius_tiles": 2.5,
        "clump_min_neighbors": 3,
        "by_segment": {
            seg: {
                c: _agg_concave_slice([r for r in by_cohort[c] if seg == "all" or r["race"] == seg])
                for c in COHORTS
            }
            for seg in SEGMENTS
        },
        "by_matchup": {
            mu: {
                c: _agg_concave_slice([r for r in by_cohort[c] if r.get("matchup") == mu])
                for c in COHORTS
            }
            for mu in MATCHUPS
        },
    }

    # -------------------------------------------------------------------------
    # Graph 16: Army Rotation & Multi-Base Defense Response (by Race & Matchup)
    # -------------------------------------------------------------------------
    def _agg_rotation_slice(crecs: list[dict[str, Any]]) -> dict[str, Any]:
        n_games = len(crecs)
        def_opps = 0
        def_resp = 0
        def_lats: list[float] = []
        off_rates: list[float] = []
        off_games_hit = 0
        off_tot_ev = 0
        idle_vals: list[float] = []

        for r in crecs:
            rmp = r.get("rotation_mp") or {}
            dur_10m = max(float(r.get("duration_sec") or 60.0), 60.0) / 600.0
            for pair in rmp.get("def_rotations") or ():
                def_opps += 1
                if int(pair[0]) == 1:
                    def_resp += 1
                    if pair[1] is not None:
                        def_lats.append(float(pair[1]))
            oc = int(rmp.get("off_rot_count") or 0)
            off_tot_ev += oc
            if oc > 0:
                off_games_hit += 1
            off_rates.append(oc / dur_10m)
            for iv in rmp.get("off_front_idle_pcts") or ():
                idle_vals.append(float(iv))

        return {
            "games": n_games,
            "def_opportunities": def_opps,
            "def_responded": def_resp,
            "def_response_rate_pct": round(100.0 * def_resp / def_opps, 1) if def_opps > 0 else None,
            "def_latency_sec": _pctiles(def_lats, prec=1),
            "off_rotation_games_pct": round(100.0 * off_games_hit / n_games, 1) if n_games > 0 else 0.0,
            "off_rotation_total_events": off_tot_ev,
            "off_rotations_per_10m": _pctiles(off_rates, prec=2),
            "off_front_idle_pct": _pctiles(idle_vals, prec=1),
        }

    army_rotation_out = {
        "def_base_radius_tiles": 18.0,
        "def_away_min_tiles": 25.0,
        "def_window_sec": 45.0,
        "off_switch_min_tiles": 25.0,
        "off_switch_window_sec": 45.0,
        "off_front_idle_radius_tiles": 22.0,
        "by_segment": {
            seg: {
                c: _agg_rotation_slice([r for r in by_cohort[c] if seg == "all" or r["race"] == seg])
                for c in COHORTS
            }
            for seg in SEGMENTS
        },
        "by_matchup": {
            mu: {
                c: _agg_rotation_slice([r for r in by_cohort[c] if r.get("matchup") == mu])
                for c in COHORTS
            }
            for mu in MATCHUPS
        },
    }

    # -------------------------------------------------------------------------
    # Graph 17: Multiprong Pressure & Counter-Backstabs / Runbys
    # -------------------------------------------------------------------------
    def _agg_mp_slice(crecs: list[dict[str, Any]]) -> dict[str, Any]:
        n_games = len(crecs)
        mp_games = 0
        mp_tot = 0
        mp_rates: list[float] = []
        bs_games = 0
        bs_tot = 0
        bs_rates: list[float] = []
        bs_wks: list[float] = []

        for r in crecs:
            rmp = r.get("rotation_mp") or {}
            dur_10m = max(float(r.get("duration_sec") or 60.0), 60.0) / 600.0
            mc = int(rmp.get("mp_count") or 0)
            mp_tot += mc
            if mc > 0:
                mp_games += 1
            mp_rates.append(mc / dur_10m)

            bc = int(rmp.get("bs_count") or 0)
            bs_tot += bc
            if bc > 0:
                bs_games += 1
            bs_rates.append(bc / dur_10m)
            for wk in rmp.get("bs_wk_kills") or ():
                bs_wks.append(float(wk))

        return {
            "games": n_games,
            "multiprong_games_pct": round(100.0 * mp_games / n_games, 1) if n_games > 0 else 0.0,
            "multiprong_total_events": mp_tot,
            "multiprong_per_10m": _pctiles(mp_rates, prec=2),
            "backstab_games_pct": round(100.0 * bs_games / n_games, 1) if n_games > 0 else 0.0,
            "backstab_total_events": bs_tot,
            "backstab_per_10m": _pctiles(bs_rates, prec=2),
            "backstab_workers_killed": {
                **_pctiles(bs_wks, prec=2),
                "total_workers_killed": int(sum(bs_wks)),
            },
        }

    multiprong_backstabs_out = {
        "multiprong_sep_tiles": 25.0,
        "multiprong_window_sec": 15.0,
        "backstab_base_radius_tiles": 16.0,
        "backstab_enemy_away_tiles": 30.0,
        "by_segment": {
            seg: {
                c: _agg_mp_slice([r for r in by_cohort[c] if seg == "all" or r["race"] == seg])
                for c in COHORTS
            }
            for seg in SEGMENTS
        },
        "by_matchup": {
            mu: {
                c: _agg_mp_slice([r for r in by_cohort[c] if r.get("matchup") == mu])
                for c in COHORTS
            }
            for mu in MATCHUPS
        },
    }

    # -------------------------------------------------------------------------
    # Graph 18: Per-Matchup Unit-Type Comp (2m..18m) & Pro Archetype Clusters
    # -------------------------------------------------------------------------
    def _build_unit_curve(
        crecs: list[dict[str, Any]],
        top_units: list[str],
    ) -> list[dict[str, Any]]:
        top_set = set(top_units)
        pts: list[dict[str, Any]] = []
        for idx, t in enumerate(BUCKETS_TIER_SEC):
            acc: dict[str, float] = {u: 0.0 for u in top_units}
            other_acc = 0.0
            n = 0
            for r in crecs:
                uc = r.get("unit_comp_2_18m")
                if not uc or idx >= len(uc) or not uc[idx]:
                    continue
                snap = uc[idx]
                tot = sum(snap.values())
                if tot <= 0:
                    continue
                n += 1
                for u, v in snap.items():
                    sh = 100.0 * v / float(tot)
                    if u in top_set:
                        acc[u] += sh
                    else:
                        other_acc += sh
            if n > 0:
                shares: dict[str, float] = {}
                rem = 100.0
                for u in top_units:
                    val_r = round(acc[u] / n, 1)
                    shares[u] = val_r
                    rem -= val_r
                oth_r = round(max(0.0, other_acc / n), 1)
                if oth_r > 0.0:
                    shares["Other"] = round(max(0.0, rem), 1)
                pts.append({"t": t, "label": _fmt_sec(float(t)), "n": n, "shares": shares})
            else:
                pts.append({"t": t, "label": _fmt_sec(float(t)), "n": 0, "shares": {}})
        return pts

    def _mean_l1(l1_list: list[dict[str, float]]) -> dict[str, float]:
        if not l1_list:
            return {}
        acc: dict[str, float] = defaultdict(float)
        for d in l1_list:
            for u, v in d.items():
                acc[u] += v
        n = float(len(l1_list))
        return {u: v / n for u, v in acc.items() if v > 0.0}

    def _win_rate_stats(recs: list[dict[str, Any]]) -> tuple[float | None, int]:
        dec = [r for r in recs if r.get("result_code") in (1, 2)]
        if not dec:
            return None, 0
        wins = sum(1 for r in dec if r.get("won"))
        return round(100.0 * wins / len(dec), 1), len(dec)

    unit_comp_by_mu: dict[str, Any] = {}
    for mu_idx, mu in enumerate(MATCHUPS):
        mu_cohorts = {
            c: [r for r in by_cohort[c] if r.get("matchup") == mu] for c in COHORTS
        }
        # Rank canonical unit types across all cohorts in this matchup (weighted by average bucket share)
        unit_weight: dict[str, float] = defaultdict(float)
        for c in COHORTS:
            crecs = mu_cohorts[c]
            if not crecs:
                continue
            w_cohort = 1.5 if c == "pros" else 1.0
            for r in crecs:
                uc = r.get("unit_comp_2_18m") or ()
                for snap in uc:
                    if not snap:
                        continue
                    tot = sum(snap.values())
                    if tot <= 0:
                        continue
                    for u, v in snap.items():
                        unit_weight[u] += w_cohort * (v / float(tot)) / max(1, len(crecs))
        top_units = [
            u for u, _w in sorted(unit_weight.items(), key=lambda kv: (-kv[1], kv[0]))[:8]
        ]

        curves_mu = {c: _build_unit_curve(mu_cohorts[c], top_units) for c in COHORTS}

        # Pro Archetype Clustering (games >= 6:00 with non-empty 6m..16m vector)
        pro_elig_recs: list[dict[str, Any]] = []
        pro_l1s: list[dict[str, float]] = []
        pro_l2s: list[dict[str, float]] = []
        for r in mu_cohorts["pros"]:
            if float(r.get("duration_sec") or 0.0) < 360.0:
                continue
            l1, l2 = _game_comp_vector_6_16m(r.get("unit_comp_2_18m"))
            if l2:
                pro_elig_recs.append(r)
                pro_l1s.append(l1)
                pro_l2s.append(l2)

        n_pro_elig = len(pro_elig_recs)
        chosen_k = 0
        chosen_sil: float | None = None
        chosen_assigns: list[int] = []

        if n_pro_elig > 0:
            best_score = -999.0
            best_tuple: tuple[int, float, list[int]] | None = None
            for cand_k in (2, 3, 4):
                if n_pro_elig < 4 * cand_k:
                    continue
                res = _kmeans_cosine_cluster(
                    pro_l2s, cand_k, seed=42 + 1000 * cand_k + mu_idx * 97, min_size=4
                )
                if res is None:
                    continue
                assigns_c, _cents_c, _obj_c = res
                sil = _cosine_silhouette(pro_l2s, assigns_c, cand_k)
                # Slight preference for k=3 when rich sample (N >= 24) and silhouette is within 0.02
                adj_score = sil + (0.02 if (cand_k == 3 and n_pro_elig >= 24) else 0.0)
                if adj_score > best_score:
                    best_score = adj_score
                    best_tuple = (cand_k, sil, assigns_c)

            if best_tuple is not None:
                chosen_k, chosen_sil, chosen_assigns = best_tuple
            else:
                chosen_k = 1
                chosen_sil = None
                chosen_assigns = [0] * n_pro_elig

        clusters_out: list[dict[str, Any]] = []
        cluster_l2_centroids: list[dict[str, float]] = []
        if chosen_k > 0:
            raw_groups: list[tuple[int, list[int]]] = []
            for ci in range(chosen_k):
                idxs = [i for i, a in enumerate(chosen_assigns) if a == ci]
                if idxs:
                    raw_groups.append((ci, idxs))
            # Order clusters descending by size (n)
            raw_groups.sort(key=lambda kv: (-len(kv[1]), kv[0]))
            group_l1s = [_mean_l1([pro_l1s[i] for i in idxs]) for _ci, idxs in raw_groups]
            labels = _auto_label_clusters(group_l1s)

            for new_cid, ((_old_ci, idxs), cl1, clbl) in enumerate(
                zip(raw_groups, group_l1s, labels), start=1
            ):
                crecs_c = [pro_elig_recs[i] for i in idxs]
                wr_pct, dec_n = _win_rate_stats(crecs_c)
                cl2 = _l2_normalize_vec(cl1)
                cluster_l2_centroids.append(cl2)
                top_u_c = [
                    {"unit": u, "share_pct": round(100.0 * sh, 1)}
                    for u, sh in sorted(cl1.items(), key=lambda kv: (-kv[1], kv[0]))[:6]
                ]
                clusters_out.append({
                    "cluster_id": new_cid,
                    "label": clbl,
                    "n": len(idxs),
                    "share_pct": round(100.0 * len(idxs) / n_pro_elig, 1),
                    "win_rate_pct": wr_pct,
                    "decided_games": dec_n,
                    "top_units": top_u_c,
                    "curve_2_18m": _build_unit_curve(crecs_c, top_units),
                })

        # Mothman nearest Pro cluster & optional Mothman sub-clusters
        mm_elig_recs: list[dict[str, Any]] = []
        mm_l1s: list[dict[str, float]] = []
        mm_l2s: list[dict[str, float]] = []
        for r in mu_cohorts["mothman"]:
            if float(r.get("duration_sec") or 0.0) < 360.0:
                continue
            l1, l2 = _game_comp_vector_6_16m(r.get("unit_comp_2_18m"))
            if l2:
                mm_elig_recs.append(r)
                mm_l1s.append(l1)
                mm_l2s.append(l2)

        mm_wr, mm_dec = _win_rate_stats(mm_elig_recs)
        mm_mean_l1 = _mean_l1(mm_l1s)
        mm_mean_l2 = _l2_normalize_vec(mm_mean_l1)
        mm_top_units = [
            {"unit": u, "share_pct": round(100.0 * sh, 1)}
            for u, sh in sorted(mm_mean_l1.items(), key=lambda kv: (-kv[1], kv[0]))[:6]
        ]

        pro_sims: list[dict[str, Any]] = []
        nearest_pro: dict[str, Any] | None = None
        if mm_mean_l2 and clusters_out:
            # Per-game nearest cluster counts
            mm_assign_cnt = [0] * len(clusters_out)
            for gl2 in mm_l2s:
                best_j = max(
                    range(len(cluster_l2_centroids)),
                    key=lambda j: _vec_cosine(gl2, cluster_l2_centroids[j]),
                )
                mm_assign_cnt[best_j] += 1
            for j, cl in enumerate(clusters_out):
                sim = round(_vec_cosine(mm_mean_l2, cluster_l2_centroids[j]), 3)
                pro_sims.append({
                    "cluster_id": cl["cluster_id"],
                    "label": cl["label"],
                    "cosine_similarity": sim,
                    "mothman_assigned_n": mm_assign_cnt[j],
                    "mothman_assigned_pct": round(100.0 * mm_assign_cnt[j] / len(mm_l2s), 1),
                })
            best_sim_item = max(pro_sims, key=lambda x: x["cosine_similarity"])
            nearest_pro = {
                "cluster_id": best_sim_item["cluster_id"],
                "label": best_sim_item["label"],
                "cosine_similarity": best_sim_item["cosine_similarity"],
            }

        # Optional Mothman sub-clusters if Mothman plays >= 2 distinct styles (n >= 6, min_size >= 2, sil >= 0.25)
        mm_subclusters: list[dict[str, Any]] = []
        if len(mm_elig_recs) >= 6:
            mres = _kmeans_cosine_cluster(
                mm_l2s, 2, seed=420 + mu_idx * 31, min_size=2, restarts=12
            )
            if mres is not None:
                m_assigns, _mcents, _mobj = mres
                m_sil = _cosine_silhouette(mm_l2s, m_assigns, 2)
                if m_sil >= 0.25:
                    mgroups = [
                        (ci, [i for i, a in enumerate(m_assigns) if a == ci])
                        for ci in range(2)
                    ]
                    mgroups.sort(key=lambda kv: (-len(kv[1]), kv[0]))
                    ml1s_g = [_mean_l1([mm_l1s[i] for i in idxs]) for _ci, idxs in mgroups]
                    mlabels = _auto_label_clusters(ml1s_g)
                    for sc_id, ((_ci, idxs), scl1, sclbl) in enumerate(
                        zip(mgroups, ml1s_g, mlabels), start=1
                    ):
                        sc_recs = [mm_elig_recs[i] for i in idxs]
                        sc_wr, sc_dec = _win_rate_stats(sc_recs)
                        scl2 = _l2_normalize_vec(scl1)
                        sc_nearest = None
                        sc_sim = None
                        if cluster_l2_centroids:
                            bj = max(
                                range(len(cluster_l2_centroids)),
                                key=lambda j: _vec_cosine(scl2, cluster_l2_centroids[j]),
                            )
                            sc_nearest = clusters_out[bj]["label"]
                            sc_sim = round(_vec_cosine(scl2, cluster_l2_centroids[bj]), 3)
                        mm_subclusters.append({
                            "subcluster_id": sc_id,
                            "label": sclbl,
                            "n": len(idxs),
                            "share_pct": round(100.0 * len(idxs) / len(mm_elig_recs), 1),
                            "win_rate_pct": sc_wr,
                            "decided_games": sc_dec,
                            "nearest_pro_cluster": sc_nearest,
                            "cosine_similarity": sc_sim,
                            "top_units": [
                                {"unit": u, "share_pct": round(100.0 * sh, 1)}
                                for u, sh in sorted(scl1.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
                            ],
                            "curve_2_18m": _build_unit_curve(sc_recs, top_units),
                        })

        unit_comp_by_mu[mu] = {
            "unit_types": top_units,
            "curves": curves_mu,
            "pro_clustering": {
                "eligible_games": n_pro_elig,
                "k": chosen_k,
                "silhouette": round(chosen_sil, 3) if chosen_sil is not None else None,
                "clusters": clusters_out,
            },
            "mothman_match": {
                "eligible_games": len(mm_elig_recs),
                "win_rate_pct": mm_wr,
                "decided_games": mm_dec,
                "top_units": mm_top_units,
                "nearest_pro_cluster": nearest_pro,
                "pro_cluster_similarities": pro_sims,
                "mothman_subclusters": mm_subclusters,
            },
        }

    unit_comp_clusters_out = {
        "buckets_sec": BUCKETS_TIER_SEC,
        "buckets_label": [_fmt_sec(float(t)) for t in BUCKETS_TIER_SEC],
        "cluster_window_sec": [360, 960],
        "clustering_method": "deterministic cosine k-means++ (seed=42, k in 2..4, min_cluster_size=4)",
        "utility_units_excluded_from_clustering": sorted(CLUSTER_UTILITY_UNITS),
        "by_matchup": unit_comp_by_mu,
    }

    # -------------------------------------------------------------------------
    # Graph 19: Production Facility Counts & Utilization (0:00..18:00)
    # -------------------------------------------------------------------------
    prod_by_race: dict[str, Any] = {}
    for race in RACES:
        fgs = RACE_FACILITY_GROUPS[race]
        counts_18m_out: dict[str, Any] = {}
        for fg in fgs:
            counts_18m_out[fg] = {}
            for c in COHORTS:
                crecs = [r for r in by_cohort[c] if r["race"] == race]
                pts: list[dict[str, Any]] = []
                for idx, t in enumerate(BUCKETS_18M_SEC):
                    vals = [
                        float(r["prod_util"]["counts_18m"][fg][idx])
                        for r in crecs
                        if r.get("prod_util")
                        and r["prod_util"].get("counts_18m")
                        and fg in r["prod_util"]["counts_18m"]
                        and idx < len(r["prod_util"]["counts_18m"][fg])
                        and r["prod_util"]["counts_18m"][fg][idx] is not None
                    ]
                    pts.append({"t": t, **_pctiles(vals, prec=2)})
                counts_18m_out[fg][c] = pts

        util_out: dict[str, Any] = {}
        for c in COHORTS:
            crecs = [r for r in by_cohort[c] if r["race"] == race]
            fg_util: dict[str, Any] = {}
            fg_peak: dict[str, Any] = {}
            for fg in fgs:
                uvals = [
                    float(r["prod_util"]["util_pct"][fg])
                    for r in crecs
                    if r.get("prod_util") and r["prod_util"].get("util_pct", {}).get(fg) is not None
                ]
                pvals = [
                    float(r["prod_util"]["peak_counts"][fg])
                    for r in crecs
                    if r.get("prod_util") and r["prod_util"].get("peak_counts", {}).get(fg) is not None
                ]
                fg_util[fg] = _pctiles(uvals, prec=1)
                fg_peak[fg] = _pctiles(pvals, prec=1)
            ov_vals = [
                float(r["prod_util"]["overall_prod_util_pct"])
                for r in crecs
                if r.get("prod_util") and r["prod_util"].get("overall_prod_util_pct") is not None
            ]
            entry_u: dict[str, Any] = {
                "games": len(crecs),
                "by_facility_util_pct": fg_util,
                "by_facility_peak_count": fg_peak,
                "overall_prod_util_pct": _pctiles(ov_vals, prec=1),
            }
            if race == "Zerg":
                lvals = [
                    float(r["prod_util"]["larva_spent_per_hatch_min"])
                    for r in crecs
                    if r.get("prod_util") and r["prod_util"].get("larva_spent_per_hatch_min") is not None
                ]
                qhvals = [
                    float(r["prod_util"]["queens_per_hatch_10m"])
                    for r in crecs
                    if r.get("prod_util") and r["prod_util"].get("queens_per_hatch_10m") is not None
                ]
                entry_u["larva_spent_per_hatch_min"] = _pctiles(lvals, prec=2)
                entry_u["queens_per_hatch_10m"] = _pctiles(qhvals, prec=2)
            util_out[c] = entry_u

        prod_by_race[race] = {
            "facility_groups": list(fgs),
            "counts_18m": counts_18m_out,
            "utilization": util_out,
        }

    production_utilization_out = {
        "buckets_sec": BUCKETS_18M_SEC,
        "buckets_label": [_fmt_sec(float(t)) for t in BUCKETS_18M_SEC],
        "notes": "Utilization % = 100 * sum(trained_unit_build_sec) / sum(ready_facility_slot_sec). Terran Reactors add +1 production slot; Protoss uses WarpGate cooldowns after WarpGateResearch completes; Zerg reports larva-units spent per ready Hatchery-minute.",
        "by_race": prod_by_race,
    }

    # -------------------------------------------------------------------------
    # Graph 20: Macro Ability Usage & Targets (0:00..18:00)
    # -------------------------------------------------------------------------
    def _agg_macro_abil_series(
        crecs: list[dict[str, Any]],
        abil_key: str,
        require_ge: bool,
        include_curve: bool = True,
    ) -> dict[str, Any]:
        elig = [r for r in crecs if (not require_ge or r.get("game_events_ok"))]
        per_min_vals: list[float] = []
        tot_vals: list[float] = []
        used_games = 0
        for r in elig:
            cnt = int((r.get("macro_abil") or {}).get("counts", {}).get(abil_key, 0))
            dur_m = max(float(r.get("duration_sec") or 60.0), 60.0) / 60.0
            per_min_vals.append(cnt / dur_m)
            tot_vals.append(float(cnt))
            if cnt > 0:
                used_games += 1
        out_s: dict[str, Any] = {
            "games": len(elig),
            "adopt_pct": round(100.0 * used_games / len(elig), 1) if elig else 0.0,
            "per_min": _pctiles(per_min_vals, prec=2),
            "total_casts": _pctiles(tot_vals, prec=1),
            "sum_casts": int(sum(tot_vals)),
        }
        if include_curve:
            pts: list[dict[str, Any]] = []
            for idx, t in enumerate(BUCKETS_18M_SEC):
                vals = [
                    float(r["macro_abil"]["cum_18m"][abil_key][idx])
                    for r in elig
                    if r.get("macro_abil")
                    and abil_key in (r["macro_abil"].get("cum_18m") or {})
                    and idx < len(r["macro_abil"]["cum_18m"][abil_key])
                    and r["macro_abil"]["cum_18m"][abil_key][idx] is not None
                ]
                pts.append({"t": t, **_pctiles(vals, prec=1)})
            out_s["cum_curve_18m"] = pts
        return out_s

    def _agg_split_table(
        recs_by_coh: dict[str, list[dict[str, Any]]],
        field_key: str,
        group_keys: tuple[str, ...],
        bucket_keys: tuple[str, ...],
        total_label: str = "total_casts",
        counts_label: str = "counts",
    ) -> dict[str, Any]:
        res: dict[str, Any] = {}
        for gk in group_keys:
            res[gk] = {}
            for c in COHORTS:
                sums = {bk: 0 for bk in bucket_keys}
                for r in recs_by_coh[c]:
                    sub = ((r.get("macro_abil") or {}).get(field_key) or {}).get(gk) or {}
                    for bk, val in sub.items():
                        if bk in sums:
                            sums[bk] += int(val)
                        elif "Other" in sums:
                            sums["Other"] += int(val)
                tot = sum(sums.values())
                res[gk][c] = {
                    "games": len(recs_by_coh[c]),
                    total_label: tot,
                    counts_label: sums,
                    "shares_pct": {
                        bk: round(100.0 * sums[bk] / tot, 1) if tot > 0 else 0.0
                        for bk in bucket_keys
                    },
                }
        return res

    macro_by_race: dict[str, Any] = {}

    # Protoss macro abilities + Chrono Boost target split + Energy Recharge + Phase/Situation
    p_chrono: dict[str, Any] = {}
    p_erech: dict[str, Any] = {}
    p_chrono_split: dict[str, Any] = {}
    p_ge_50e_by_coh: dict[str, list[dict[str, Any]]] = {}
    p_er_by_coh: dict[str, list[dict[str, Any]]] = {}
    for c in COHORTS:
        precs = [r for r in by_cohort[c] if r["race"] == "Protoss"]
        # Exclude LotV 3.x (base_build < 60000) where Chrono Boost was a 0-energy permanent toggle
        precs_50e = [r for r in precs if c != "pros" or int(r.get("base_build") or 0) >= 60000]
        p_chrono[c] = _agg_macro_abil_series(precs_50e, "chrono_boost", require_ge=True, include_curve=True)
        # Energy Recharge is Patch 5.0.14 (arena 75689 custom/5.0.14 or Pro bb >= 93000)
        er_elig = [
            r for r in precs
            if r.get("game_events_ok") and (c != "pros" or int(r.get("base_build") or 0) >= 93000)
        ]
        p_er_by_coh[c] = er_elig
        p_erech[c] = _agg_macro_abil_series(er_elig, "energy_recharge", require_ge=True, include_curve=True)
        # Chrono target split (pooled across ge_ok 50e-Chrono games)
        ge_p_recs = [r for r in precs_50e if r.get("game_events_ok")]
        p_ge_50e_by_coh[c] = ge_p_recs
        bkt_sums = {b: 0 for b in CHRONO_TARGET_BUCKETS}
        for r in ge_p_recs:
            ct = (r.get("macro_abil") or {}).get("chrono_targets") or {}
            for b, v in ct.items():
                if b in bkt_sums:
                    bkt_sums[b] += int(v)
                else:
                    bkt_sums["Other"] += int(v)
        tot_c = sum(bkt_sums.values())
        p_chrono_split[c] = {
            "games": len(ge_p_recs),
            "total_casts": tot_c,
            "counts": bkt_sums,
            "shares_pct": {
                b: round(100.0 * bkt_sums[b] / tot_c, 1) if tot_c > 0 else 0.0
                for b in CHRONO_TARGET_BUCKETS
            },
        }
    p_er_phase_out: dict[str, Any] = {}
    for ph in MACRO_PHASE_LABELS:
        p_er_phase_out[ph] = {}
        for c in COHORTS:
            er_recs = p_er_by_coh[c]
            tot_m = 0.0
            tot_casts = 0
            g_reach = 0
            for r in er_recs:
                pm = float(((r.get("macro_abil") or {}).get("phase_mins") or {}).get(ph, 0.0))
                if pm > 0.05:
                    g_reach += 1
                    tot_m += pm
                    tot_casts += int(((r.get("macro_abil") or {}).get("energy_recharge_by_phase") or {}).get(ph, 0))
            p_er_phase_out[ph][c] = {
                "games_reaching_phase": g_reach,
                "phase_minutes_total": round(tot_m, 1),
                "total_casts": tot_casts,
                "casts_per_min": round(tot_casts / tot_m, 3) if tot_m > 0.0 else None,
            }
    macro_by_race["Protoss"] = {
        "chrono_boost": p_chrono,
        "energy_recharge": p_erech,
        "chrono_target_split": p_chrono_split,
        "chrono_target_by_phase": _agg_split_table(
            p_ge_50e_by_coh, "chrono_by_phase", MACRO_PHASE_LABELS, CHRONO_TARGET_BUCKETS
        ),
        "chrono_target_by_situation": _agg_split_table(
            p_ge_50e_by_coh, "chrono_by_situation", ("peaceful", "under_pressure"), CHRONO_TARGET_BUCKETS
        ),
        "energy_recharge_by_phase": p_er_phase_out,
    }

    # Terran macro abilities + OC energy split + Phase/Situation/Cloak
    t_mule: dict[str, Any] = {}
    t_scan: dict[str, Any] = {}
    t_sdrop: dict[str, Any] = {}
    t_oc_split: dict[str, Any] = {}
    t_ge_by_coh: dict[str, list[dict[str, Any]]] = {}
    for c in COHORTS:
        trecs = [r for r in by_cohort[c] if r["race"] == "Terran"]
        t_mule[c] = _agg_macro_abil_series(trecs, "mule", require_ge=False, include_curve=True)
        t_scan[c] = _agg_macro_abil_series(trecs, "scan", require_ge=True, include_curve=True)
        t_sdrop[c] = _agg_macro_abil_series(trecs, "supply_drop", require_ge=True, include_curve=True)
        ge_t_recs = [r for r in trecs if r.get("game_events_ok")]
        t_ge_by_coh[c] = ge_t_recs
        sm = sum(int((r.get("macro_abil") or {}).get("counts", {}).get("mule", 0)) for r in ge_t_recs)
        ss = sum(int((r.get("macro_abil") or {}).get("counts", {}).get("scan", 0)) for r in ge_t_recs)
        sd = sum(int((r.get("macro_abil") or {}).get("counts", {}).get("supply_drop", 0)) for r in ge_t_recs)
        tot_oc = sm + ss + sd
        t_oc_split[c] = {
            "games": len(ge_t_recs),
            "total_casts": tot_oc,
            "counts": {"MULE": sm, "Scan": ss, "SupplyDrop": sd},
            "shares_pct": {
                "MULE": round(100.0 * sm / tot_oc, 1) if tot_oc > 0 else 0.0,
                "Scan": round(100.0 * ss / tot_oc, 1) if tot_oc > 0 else 0.0,
                "SupplyDrop": round(100.0 * sd / tot_oc, 1) if tot_oc > 0 else 0.0,
            },
        }
    oc_bkts = ("MULE", "Scan", "SupplyDrop")
    macro_by_race["Terran"] = {
        "mule": t_mule,
        "scan": t_scan,
        "supply_drop": t_sdrop,
        "oc_energy_split": t_oc_split,
        "oc_energy_by_phase": _agg_split_table(t_ge_by_coh, "oc_by_phase", MACRO_PHASE_LABELS, oc_bkts),
        "oc_energy_by_situation": _agg_split_table(
            t_ge_by_coh, "oc_by_situation", ("peaceful", "under_pressure"), oc_bkts
        ),
        "oc_energy_by_cloak": _agg_split_table(t_ge_by_coh, "oc_by_cloak", ("no_cloak", "cloak_seen"), oc_bkts),
    }

    # Zerg macro abilities + active tumors @ 6m/10m/14m + Queen energy split + Phase/Situation
    z_inj: dict[str, Any] = {}
    z_ctq: dict[str, Any] = {}
    z_cts: dict[str, Any] = {}
    z_trf: dict[str, Any] = {}
    z_tum_ckpt: dict[str, Any] = {}
    z_q_split: dict[str, Any] = {}
    z_ge_by_coh: dict[str, list[dict[str, Any]]] = {}
    for c in COHORTS:
        zrecs = [r for r in by_cohort[c] if r["race"] == "Zerg"]
        z_inj[c] = _agg_macro_abil_series(zrecs, "inject", require_ge=True, include_curve=True)
        z_ctq[c] = _agg_macro_abil_series(zrecs, "creep_tumor_queen", require_ge=False, include_curve=True)
        z_cts[c] = _agg_macro_abil_series(zrecs, "creep_tumor_spread", require_ge=False, include_curve=True)
        z_trf[c] = _agg_macro_abil_series(zrecs, "transfuse", require_ge=True, include_curve=True)
        t6 = [float(r["macro_abil"]["active_tumors_6_10_14_pk"][0]) for r in zrecs if (r.get("macro_abil") or {}).get("active_tumors_6_10_14_pk") and r["macro_abil"]["active_tumors_6_10_14_pk"][0] is not None]
        t10 = [float(r["macro_abil"]["active_tumors_6_10_14_pk"][1]) for r in zrecs if (r.get("macro_abil") or {}).get("active_tumors_6_10_14_pk") and r["macro_abil"]["active_tumors_6_10_14_pk"][1] is not None]
        t14 = [float(r["macro_abil"]["active_tumors_6_10_14_pk"][2]) for r in zrecs if (r.get("macro_abil") or {}).get("active_tumors_6_10_14_pk") and r["macro_abil"]["active_tumors_6_10_14_pk"][2] is not None]
        tpk = [float(r["macro_abil"]["active_tumors_6_10_14_pk"][3]) for r in zrecs if (r.get("macro_abil") or {}).get("active_tumors_6_10_14_pk") and r["macro_abil"]["active_tumors_6_10_14_pk"][3] is not None]
        z_tum_ckpt[c] = {
            "6m": _pctiles(t6, prec=1),
            "10m": _pctiles(t10, prec=1),
            "14m": _pctiles(t14, prec=1),
            "peak": _pctiles(tpk, prec=1),
        }
        ge_z_recs = [r for r in zrecs if r.get("game_events_ok")]
        z_ge_by_coh[c] = ge_z_recs
        e_inj = sum(int((r.get("macro_abil") or {}).get("counts", {}).get("inject", 0)) * 25 for r in ge_z_recs)
        e_ctq = sum(int((r.get("macro_abil") or {}).get("counts", {}).get("creep_tumor_queen", 0)) * 25 for r in ge_z_recs)
        e_trf = sum(int((r.get("macro_abil") or {}).get("counts", {}).get("transfuse", 0)) * 50 for r in ge_z_recs)
        tot_qe = e_inj + e_ctq + e_trf
        z_q_split[c] = {
            "games": len(ge_z_recs),
            "total_energy_spent": tot_qe,
            "energy_by_ability": {"Inject": e_inj, "CreepTumor": e_ctq, "Transfuse": e_trf},
            "shares_pct": {
                "Inject": round(100.0 * e_inj / tot_qe, 1) if tot_qe > 0 else 0.0,
                "CreepTumor": round(100.0 * e_ctq / tot_qe, 1) if tot_qe > 0 else 0.0,
                "Transfuse": round(100.0 * e_trf / tot_qe, 1) if tot_qe > 0 else 0.0,
            },
        }
    q_bkts = ("Inject", "CreepTumor", "Transfuse")
    macro_by_race["Zerg"] = {
        "inject": z_inj,
        "creep_tumor_queen": z_ctq,
        "creep_tumor_spread": z_cts,
        "transfuse": z_trf,
        "active_tumors_checkpoints": z_tum_ckpt,
        "queen_energy_split": z_q_split,
        "queen_energy_by_phase": _agg_split_table(
            z_ge_by_coh, "queen_by_phase", MACRO_PHASE_LABELS, q_bkts,
            total_label="total_energy_spent", counts_label="energy_by_ability",
        ),
        "queen_energy_by_situation": _agg_split_table(
            z_ge_by_coh, "queen_by_situation", ("peaceful", "under_pressure"), q_bkts,
            total_label="total_energy_spent", counts_label="energy_by_ability",
        ),
    }

    macro_abilities_out = {
        "buckets_sec": BUCKETS_18M_SEC,
        "buckets_label": [_fmt_sec(float(t)) for t in BUCKETS_18M_SEC],
        "phases": list(MACRO_PHASE_LABELS),
        "situations": ["peaceful", "under_pressure"],
        "cloak_states": ["no_cloak", "cloak_seen"],
        "pressure_window_sec": 20.0,
        "by_race": macro_by_race,
    }

    # -------------------------------------------------------------------------
    # Graph 21: Queen & TownHall Energy Management (0:00..18:00)
    # -------------------------------------------------------------------------
    energy_by_caster: dict[str, Any] = {}
    caster_race_pairs = (("Nexus", "Protoss"), ("OrbitalCommand", "Terran"), ("Queen", "Zerg"))
    for ckey, race in caster_race_pairs:
        energy_by_caster[ckey] = {"race": race}
        for c in COHORTS:
            crecs = [
                r for r in by_cohort[c]
                if r["race"] == race
                and r.get("game_events_ok")
                and (ckey != "Nexus" or c != "pros" or int(r.get("base_build") or 0) >= 60000)
                and (r.get("macro_energy") or {}).get("spend_efficiency_pct") is not None
            ]
            eff_v = [float(r["macro_energy"]["spend_efficiency_pct"]) for r in crecs]
            cap_v = [float(r["macro_energy"]["time_capped_180_pct"]) for r in crecs]
            me_v = [float(r["macro_energy"]["mean_energy_overall"]) for r in crecs]
            pts = []
            for idx, t in enumerate(BUCKETS_18M_SEC):
                vals = [
                    float(r["macro_energy"]["mean_energy_curve_18m"][idx])
                    for r in crecs
                    if r["macro_energy"].get("mean_energy_curve_18m")
                    and idx < len(r["macro_energy"]["mean_energy_curve_18m"])
                    and r["macro_energy"]["mean_energy_curve_18m"][idx] is not None
                ]
                pts.append({"t": t, **_pctiles(vals, prec=1)})
            energy_by_caster[ckey][c] = {
                "games": len(crecs),
                "spend_efficiency_pct": _pctiles(eff_v, prec=1),
                "time_capped_180_pct": _pctiles(cap_v, prec=1),
                "mean_energy_overall": _pctiles(me_v, prec=1),
                "mean_energy_curve_18m": pts,
            }

    macro_energy_out = {
        "buckets_sec": BUCKETS_18M_SEC,
        "buckets_label": [_fmt_sec(float(t)) for t in BUCKETS_18M_SEC],
        "energy_regen_per_realtime_sec": ENERGY_REGEN_PER_SEC,
        "energy_regen_per_blizz_sec": 0.5625,
        "energy_cap": ENERGY_CAP,
        "capped_threshold": ENERGY_CAPPED_THRESH,
        "by_caster": energy_by_caster,
    }

    # -------------------------------------------------------------------------
    # Graph 22: Combat Spell & Active Ability Usage (Per-Unit-Game Normalized)
    # -------------------------------------------------------------------------
    spells_by_race: dict[str, list[dict[str, Any]]] = {rc: [] for rc in RACES}
    spells_all_flat: list[dict[str, Any]] = []

    for skey, slbl, srace, clbl, cunits, src, skind in COMBAT_SPELL_CATALOG:
        cunit_set = set(cunits)
        req_ge = src == "scmd"
        row: dict[str, Any] = {
            "key": skey,
            "label": slbl,
            "race": srace,
            "caster_label": clbl,
            "source": src,
            "kind": skind,
        }
        for c in COHORTS:
            elig = [
                r for r in by_cohort[c]
                if r["race"] == srace and (not req_ge or r.get("game_events_ok"))
            ]
            caster_games = [
                r for r in elig
                if bool(set((r.get("combat_spells") or {}).get("casters_built") or ()) & cunit_set)
            ]
            rates_10m: list[float] = []
            used_n = 0
            tot_c = 0
            for r in caster_games:
                cnt = int((r.get("combat_spells") or {}).get("counts", {}).get(skey, 0))
                dur_10m = max(float(r.get("duration_sec") or 60.0), 60.0) / 600.0
                rates_10m.append(cnt / dur_10m)
                tot_c += cnt
                if cnt > 0:
                    used_n += 1
            n_el = len(elig)
            n_cg = len(caster_games)
            row[c] = {
                "eligible_games": n_el,
                "caster_games": n_cg,
                "caster_build_pct": round(100.0 * n_cg / n_el, 1) if n_el > 0 else 0.0,
                "used_games": used_n,
                "adoption_pct": round(100.0 * used_n / n_cg, 1) if n_cg > 0 else None,
                "casts_per_10m_caster_games": _pctiles(rates_10m, prec=2),
                "total_casts": tot_c,
            }
        mm_m = row["mothman"]["casts_per_10m_caster_games"]["mean"]
        pr_m = row["pros"]["casts_per_10m_caster_games"]["mean"]
        if mm_m is not None and pr_m is not None and pr_m > 0.0:
            row["mothman_vs_pro_ratio"] = round(mm_m / pr_m, 2)
        else:
            row["mothman_vs_pro_ratio"] = None
        spells_by_race[srace].append(row)
        spells_all_flat.append(row)

    # Sort all_flat so Pro-used spells with largest Mothman deficit surface cleanly at top
    spells_all_flat.sort(
        key=lambda x: (
            0 if (x["pros"]["caster_games"] >= 5 and (x["pros"]["casts_per_10m_caster_games"]["mean"] or 0.0) >= 0.5) else 1,
            x["mothman_vs_pro_ratio"] if x["mothman_vs_pro_ratio"] is not None else 999.0,
            -(x["pros"]["casts_per_10m_caster_games"]["mean"] or 0.0),
            x["key"],
        )
    )

    combat_spells_out = {
        "by_race": spells_by_race,
        "all_flat": spells_all_flat,
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "meta": meta,
        "buckets_sec": buckets_sec,
        "buckets_label": [_fmt_sec(float(t)) for t in buckets_sec],
        "segments": list(SEGMENTS),
        "matchups": list(MATCHUPS),
        "curves": curves_out,
        "summary": summary_out,
        "timings": timings_out,
        # Graphs 9-14 (schema v2 additive keys — 100% backwards-compatible)
        "army_cohesion": army_cohesion_out,
        "engage_retreat": engage_retreat_out,
        "expansions_4plus": expansions_4plus_out,
        "gas_7plus": gas_7plus_out,
        "tier_composition": tier_composition_out,
        "all_upgrades": all_upgrades_out,
        # Graphs 15-18 (schema v3 additive keys — 100% backwards-compatible)
        "concave_layering": concave_layering_out,
        "army_rotation": army_rotation_out,
        "multiprong_backstabs": multiprong_backstabs_out,
        "unit_comp_clusters": unit_comp_clusters_out,
        # Graphs 19-22 (schema v4 additive keys — 100% backwards-compatible)
        "production_utilization": production_utilization_out,
        "macro_abilities": macro_abilities_out,
        "macro_energy": macro_energy_out,
        "combat_spells": combat_spells_out,
    }


def _print_console_summary(out: dict[str, Any], elapsed_sec: float) -> None:
    meta = out["meta"]
    print(f"=== Pro Comparison Curves & Timings ({meta['run_id']}) ===")
    print(
        f"Elapsed: {elapsed_sec:.2f}s | Pro cache hit: {meta['pro_cache_hit']} | "
        f"Buckets: {len(out['buckets_sec'])} ({out['buckets_label'][0]}..{out['buckets_label'][-1]})"
    )
    for c in COHORTS:
        cm = meta["cohorts"][c]
        print(
            f"  {cm['label']:<15} n={cm['games']:>3} (ge_ok={cm['game_events_games']:>3}, "
            f"med_dur={_fmt_sec(cm['median_duration_sec'])}) "
            f"P={cm['by_race']['Protoss']} T={cm['by_race']['Terran']} Z={cm['by_race']['Zerg']}"
        )

    print("\n--- Game-Level Summary (Segment: all, Median [p25..p75]) ---")
    s_all = out["summary"]["all"]
    for m in CURVE_METRICS:
        parts = []
        for c in COHORTS:
            d = s_all[m][c]
            pk = f" (pk {d['peak']['med']})" if "peak" in d and d["peak"]["med"] is not None else ""
            parts.append(f"{c}={d['med']} [{d['p25']}..{d['p75']}]{pk}")
        print(f"  {m:<20}: " + " | ".join(parts))

    print("\n--- Snapshot Curve Checkpoints (all, Median at 3:00 / 6:00 / 9:00 / 12:00) ---")
    bsec = out["buckets_sec"]
    ckpts = [t for t in (180, 360, 540, 720) if t in bsec]
    for m in CURVE_METRICS:
        line = f"  {m:<20}:"
        for t in ckpts:
            idx = bsec.index(t)
            mm = out["curves"]["all"][m]["mothman"][idx]["med"]
            op = out["curves"]["all"][m]["opponents"][idx]["med"]
            pr = out["curves"]["all"][m]["pros"][idx]["med"]
            line += f"  @{_fmt_sec(float(t))} M={mm}/O={op}/P={pr}"
        print(line)

    print("\n--- Key Timings Preview (Median | Adopt%) ---")
    preview_keys = {
        "Protoss": ("nat", "third", "cyber", "robo", "upg_warpgate", "upg_blink", "upg_charge"),
        "Terran": ("nat", "third", "orbital", "factory", "starport", "upg_stim", "upg_combat_shield"),
        "Zerg": ("nat", "third", "pool", "lair", "spire", "upg_ling_speed", "upg_roach_speed"),
    }
    for race in RACES:
        print(f"  [{race}]")
        by_k = {row["key"]: row for row in out["timings"][race]}
        for k in preview_keys[race]:
            r = by_k[k]
            mm, op, pr = r["mothman"], r["opponents"], r["pros"]
            print(
                f"    {r['label']:<28} "
                f"M={mm['med_fmt'] or '-':>5} ({mm['adopt_pct']:>5.1f}%) | "
                f"O={op['med_fmt'] or '-':>5} ({op['adopt_pct']:>5.1f}%) | "
                f"P={pr['med_fmt'] or '-':>5} ({pr['adopt_pct']:>5.1f}%)"
            )


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Extract 8 comparative performance curves & timings (Mothman vs Opponents vs Pros)."
    )
    src_grp = ap.add_mutually_exclusive_group(required=True)
    src_grp.add_argument(
        "--run-dir",
        type=Path,
        help="Path to arena run directory (or its replays/ subdirectory).",
    )
    src_grp.add_argument(
        "--run-prefix",
        nargs="+",
        help="One or more run_id prefixes to query from read-only --replay-db.",
    )
    ap.add_argument("--replay-db", type=Path, default=DEFAULT_DB_PATH, help="Read-only arena_replays.sqlite path.")
    ap.add_argument("--pro-dir", type=Path, default=DEFAULT_PRO_DIR, help="Pro replay corpus directory.")
    ap.add_argument("--pro-cache", type=Path, default=DEFAULT_PRO_CACHE, help="Pro baseline JSON cache path.")
    ap.add_argument("--rebuild-pro-cache", action="store_true", help="Force rebuild of Pro baseline cache.")
    ap.add_argument("--pylibs-dir", type=Path, default=DEFAULT_PYLIBS_DIR, help="Path to s2protocol/mpyq pylibs.")
    ap.add_argument("--bucket-sec", type=int, default=30, help="Curve bucket width in real-time seconds (default: 30).")
    ap.add_argument("--max-time-min", type=int, default=15, help="Max curve horizon in minutes (default: 15).")
    ap.add_argument(
        "--min-dur-sec-bot",
        type=float,
        default=60.0,
        help="Min duration (sec) for Mothman/Opponent matches (default: 60s to keep full EXT_78).",
    )
    ap.add_argument(
        "--min-dur-sec-pro",
        type=float,
        default=250.0,
        help="Min duration (sec) for Pro LotV matches (default: 250s matching pro-deep-comparison.py).",
    )
    ap.add_argument("--jobs", type=int, default=8, help="Parallel worker processes (default: 8).")
    ap.add_argument("--out-json", type=Path, default=DEFAULT_OUT_JSON, help="Output JSON path.")
    ap.add_argument("--quiet", action="store_true", help="Suppress console summary table.")
    args = ap.parse_args()

    t0 = time.monotonic()
    max_time_sec = int(args.max_time_min) * 60
    bucket_sec = int(args.bucket_sec)
    buckets_sec = list(range(0, max_time_sec + 1, bucket_sec))

    # 1. Load or build Pro GM baseline cache
    pro_recs, cache_hit, pro_valid_replays = load_or_build_pro_cache(
        pro_dir=args.pro_dir,
        cache_path=args.pro_cache,
        pylibs_dir=args.pylibs_dir,
        buckets_sec=buckets_sec,
        bucket_sec=bucket_sec,
        min_dur_sec=args.min_dur_sec_pro,
        jobs=args.jobs,
        rebuild=args.rebuild_pro_cache,
    )

    # 2. Parse current Mothman + Opponent external replays
    if args.run_dir is not None:
        arena_recs, run_id, source_path = load_arena_replays_from_dir(
            run_dir=args.run_dir,
            pylibs_dir=args.pylibs_dir,
            buckets_sec=buckets_sec,
            bucket_sec=bucket_sec,
            min_dur_sec=args.min_dur_sec_bot,
            jobs=args.jobs,
        )
    else:
        arena_recs, run_id, source_path = load_arena_replays_from_sqlite(
            db_path=args.replay_db,
            run_prefixes=args.run_prefix,
            pylibs_dir=args.pylibs_dir,
            buckets_sec=buckets_sec,
            bucket_sec=bucket_sec,
            min_dur_sec=args.min_dur_sec_bot,
            jobs=args.jobs,
        )

    meta: dict[str, Any] = {
        "run_id": run_id,
        "source_path": str(source_path),
        "pro_dir": str(args.pro_dir),
        "pro_cache_path": str(args.pro_cache),
        "pro_cache_hit": cache_hit,
        "pro_valid_replays": pro_valid_replays,
        "game_loops_per_sec": GAME_LOOPS_PER_SEC,
        "clock_basis": "real-time (LotV Faster = 22.4 gameloops/sec)",
        "bucket_sec": bucket_sec,
        "max_time_sec": max_time_sec,
        "min_dur_sec_bot": float(args.min_dur_sec_bot),
        "min_dur_sec_pro": float(args.min_dur_sec_pro),
        "pro_min_base_build": LOTV_MIN_BASE_BUILD,
        "metrics": METRIC_META,
        "notes": [
            "Clock: All timestamps, buckets, and per-minute rates use SC2 LotV Faster real-time (22.4 gameloops/sec; 1,344 gameloops/min).",
            "Self-play matches (Mothman-*-SP) are excluded so Mothman and Opponents represent the exact external arena match pairs.",
            "APM/EPM Bot vs Human Caveat: Raw-API SC2 bots emit synthetic SSelectionDeltaEvent records on the same gameloop as SCmdEvent, and unthrottled AI opponents routinely emit 2,000-30,000 raw actions/min (use log scale or Y-cap on APM/EPM charts so Mothman and Pro curves remain readable). EPM deduplicates identical commands within 0.71s (16 loops), ignores control-group recall spam, and strips same-loop synthetic selections.",
            "SPM Caveat: Most raw-API opponent bots never issue SCameraUpdateEvent camera moves (0.0 SPM), whereas Mothman actively drives its camera (~20-35 SPM) and human Pros actively jump screens (~15-30 SPM; >=12 map tiles per jump).",
            "Pro Baseline: Valid LotV 1v1 human non-arcade replays (base_build >= 38215, duration >= 250s) from replays/pro_corpus/. Replays whose newer game-event wire schema cannot be decoded by s2protocol are excluded from APM/EPM/SPM while retained for tracker-based Army Value, Collection Rate, and Upgrade/Structure Timings.",
            "Timing Conventions: Expansions and structures record start time (SUnitInitEvent, excluding self-canceled Extractor/Hatch tricks); Morphs (Orbital, Lair, Hive) and Upgrades (SUpgradeEvent) record completion time.",
        ],
    }

    out = aggregate_all(pro_recs + arena_recs, buckets_sec, meta)
    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    args.out_json.write_text(json.dumps(out, indent=2), encoding="utf-8")

    elapsed = time.monotonic() - t0
    if not args.quiet:
        _print_console_summary(out, elapsed)
        print(f"\nWrote: {args.out_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
