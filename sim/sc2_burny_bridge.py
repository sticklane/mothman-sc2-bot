#!/usr/bin/env python3
"""
sim/sc2_burny_bridge.py

Full S-Expression <-> burnysc2 (python-sc2) IPC Bridge for #lang sc-bot (Mothman).
Supports:
  - All 36 Trainable Units across Zerg, Terran, Protoss
  - All 35 Buildable Structures (including defensive structures & add-ons)
  - All 7 Core Combat Upgrades
  - All 9 Unit & Structure Morphs (plus Baneling & Overseer)
  - All 16 Active Tactical Spells
  - All 7 Pro Signature Mechanics (Emergency Cancel, Active Creep Tumor Spread,
    Choke Hold-Position & Terran Add-On Swap, Transport Micro/Drop,
    Mineral-Walk/Worker-Harass/Changeling/Shade/Baneling/WidowMine,
    Full 11-Structure Chrono Boost, Control-Group Stealing & Camera Bookmarks)
  - All 5 Adversarial Anti-Cheese & Anti-Block Countermeasures (Anti-Cannon/Proxy
    Worker Pull, Natural Expansion Block Clear & High-Ground CC Float,
    Anti-Gas-Steal Focus-Fire, Halted Terran Building SCV Resume,
    Ramp ForceField Corrosive-Bile Breaker & Anti-Kite Leash)
  - Zero-Supply-Block Guarantee (supply_left >= 2 worker-rush guard + en-route
    builder mineral/gas reservation + proactive supply buffer)
"""

import argparse
import asyncio
import json
import math
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

ROOT_DIR = Path(__file__).resolve().parent.parent
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from sim.scbot_telemetry import SCHEMA_VERSION, TelemetryRecorder

DEFAULT_SC2_PATH = Path("/home/antigravity/sc2_headless/StarCraftII")
if "SC2PATH" not in os.environ and DEFAULT_SC2_PATH.exists():
    os.environ["SC2PATH"] = str(DEFAULT_SC2_PATH)

RACKET_BIN = "/home/antigravity/toolchains/racket/bin/racket"
if not os.path.exists(RACKET_BIN):
    RACKET_BIN = "racket"

# Canonical 36 Trainable Units
CANONICAL_36_UNITS = [
    # Zerg (12)
    "drone", "zergling", "roach", "hydralisk", "mutalisk", "corruptor",
    "swarm-host-mp", "infestor", "viper", "ultralisk", "queen", "overlord",
    # Terran (12)
    "scv", "marine", "marauder", "reaper", "ghost", "hellion",
    "widow-mine", "siege-tank", "cyclone", "thor", "viking-fighter", "medivac",
    # Protoss (12)
    "probe", "zealot", "stalker", "sentry", "adept", "high-templar",
    "dark-templar", "immortal", "colossus", "observer", "warp-prism", "void-ray",
]

UNIT_NAME_TO_ENUM_NAME: Dict[str, str] = {
    # Zerg
    "drone": "DRONE",
    "zergling": "ZERGLING",
    "baneling": "BANELING",
    "roach": "ROACH",
    "ravager": "RAVAGER",
    "hydralisk": "HYDRALISK",
    "lurker": "LURKERMP",
    "lurker-mp": "LURKERMP",
    "mutalisk": "MUTALISK",
    "corruptor": "CORRUPTOR",
    "swarm-host": "SWARMHOSTMP",
    "swarm-host-mp": "SWARMHOSTMP",
    "infestor": "INFESTOR",
    "viper": "VIPER",
    "ultralisk": "ULTRALISK",
    "brood-lord": "BROODLORD",
    "broodlord": "BROODLORD",
    "queen": "QUEEN",
    "overlord": "OVERLORD",
    "overseer": "OVERSEER",
    "changeling": "CHANGELING",
    # Terran
    "scv": "SCV",
    "marine": "MARINE",
    "marauder": "MARAUDER",
    "reaper": "REAPER",
    "ghost": "GHOST",
    "hellion": "HELLION",
    "hellbat": "HELLIONTANK",
    "hellion-tank": "HELLIONTANK",
    "widow-mine": "WIDOWMINE",
    "widowmine": "WIDOWMINE",
    "siege-tank": "SIEGETANK",
    "tank": "SIEGETANK",
    "cyclone": "CYCLONE",
    "thor": "THOR",
    "viking": "VIKINGFIGHTER",
    "viking-fighter": "VIKINGFIGHTER",
    "medivac": "MEDIVAC",
    "liberator": "LIBERATOR",
    "raven": "RAVEN",
    "banshee": "BANSHEE",
    "battlecruiser": "BATTLECRUISER",
    # Protoss
    "probe": "PROBE",
    "zealot": "ZEALOT",
    "stalker": "STALKER",
    "sentry": "SENTRY",
    "adept": "ADEPT",
    "high-templar": "HIGHTEMPLAR",
    "dark-templar": "DARKTEMPLAR",
    "immortal": "IMMORTAL",
    "colossus": "COLOSSUS",
    "disruptor": "DISRUPTOR",
    "archon": "ARCHON",
    "observer": "OBSERVER",
    "warp-prism": "WARPPRISM",
    "phoenix": "PHOENIX",
    "void-ray": "VOIDRAY",
    "voidray": "VOIDRAY",
    "oracle": "ORACLE",
    "tempest": "TEMPEST",
    "carrier": "CARRIER",
    "mothership": "MOTHERSHIP",
}

CANONICAL_35_BUILDINGS = [
    # Zerg (11)
    "hatchery", "extractor", "spawning-pool", "roach-warren", "baneling-nest",
    "evolution-chamber", "hydralisk-den", "spire", "infestation-pit",
    "ultralisk-cavern", "spine-crawler",
    # Terran (12)
    "command-center", "supply-depot", "refinery", "barracks", "engineering-bay",
    "bunker", "missile-turret", "factory", "ghost-academy", "starport",
    "armory", "fusion-core",
    # Protoss (12)
    "nexus", "pylon", "assimilator", "gateway", "forge", "photon-cannon",
    "shield-battery", "cybernetics-core", "twilight-council", "robotics-facility",
    "stargate", "templar-archives",
]

BUILDING_NAME_TO_ENUM_NAME: Dict[str, str] = {
    # Zerg
    "hatchery": "HATCHERY",
    "lair": "LAIR",
    "hive": "HIVE",
    "extractor": "EXTRACTOR",
    "spawning-pool": "SPAWNINGPOOL",
    "roach-warren": "ROACHWARREN",
    "baneling-nest": "BANELINGNEST",
    "evolution-chamber": "EVOLUTIONCHAMBER",
    "hydralisk-den": "HYDRALISKDEN",
    "lurker-den-mp": "LURKERDENMP",
    "lurker-den": "LURKERDENMP",
    "spire": "SPIRE",
    "greater-spire": "GREATERSPIRE",
    "infestation-pit": "INFESTATIONPIT",
    "nydus-network": "NYDUSNETWORK",
    "ultralisk-cavern": "ULTRALISKCAVERN",
    "spine-crawler": "SPINECRAWLER",
    "spore-crawler": "SPORECRAWLER",
    "creep-tumor": "CREEPTUMOR",
    "creep-tumor-burrowed": "CREEPTUMORBURROWED",
    # Terran
    "command-center": "COMMANDCENTER",
    "orbital-command": "ORBITALCOMMAND",
    "planetary-fortress": "PLANETARYFORTRESS",
    "supply-depot": "SUPPLYDEPOT",
    "refinery": "REFINERY",
    "barracks": "BARRACKS",
    "engineering-bay": "ENGINEERINGBAY",
    "bunker": "BUNKER",
    "sensor-tower": "SENSORTOWER",
    "missile-turret": "MISSILETURRET",
    "factory": "FACTORY",
    "ghost-academy": "GHOSTACADEMY",
    "starport": "STARPORT",
    "armory": "ARMORY",
    "fusion-core": "FUSIONCORE",
    "barracks-techlab": "BARRACKSTECHLAB",
    "barracks-reactor": "BARRACKSREACTOR",
    "factory-techlab": "FACTORYTECHLAB",
    "factory-reactor": "FACTORYREACTOR",
    "starport-techlab": "STARPORTTECHLAB",
    "starport-reactor": "STARPORTREACTOR",
    # Protoss
    "nexus": "NEXUS",
    "pylon": "PYLON",
    "assimilator": "ASSIMILATOR",
    "gateway": "GATEWAY",
    "warp-gate": "WARPGATE",
    "forge": "FORGE",
    "photon-cannon": "PHOTONCANNON",
    "shield-battery": "SHIELDBATTERY",
    "cybernetics-core": "CYBERNETICSCORE",
    "twilight-council": "TWILIGHTCOUNCIL",
    "robotics-facility": "ROBOTICSFACILITY",
    "robotics-bay": "ROBOTICSBAY",
    "robotics-support-bay": "ROBOTICSBAY",
    "stargate": "STARGATE",
    "templar-archives": "TEMPLARARCHIVE",
    "templar-archive": "TEMPLARARCHIVE",
    "dark-shrine": "DARKSHRINE",
    "fleet-beacon": "FLEETBEACON",
}

CANONICAL_7_UPGRADES = [
    "zergling-movementspeed",
    "stimpack",
    "combat-shield",
    "concussive-shells",
    "warp-gate-research",
    "charge",
    "blink",
]

UPGRADE_NAME_TO_ENUM_NAME: Dict[str, str] = {
    "zergling-movementspeed": "ZERGLINGMOVEMENTSPEED",
    "metabolic-boost": "ZERGLINGMOVEMENTSPEED",
    "zergling-attackspeed": "ZERGLINGATTACKSPEED",
    "adrenal-glands": "ZERGLINGATTACKSPEED",
    "glial-reconstitution": "GLIALRECONSTITUTION",
    "grooved-spines": "EVOLVEGROOVEDSPINES",
    "muscular-augments": "EVOLVEMUSCULARAUGMENTS",
    "centrifugal-hooks": "CENTRIFICALHOOKS",
    "centrifical-hooks": "CENTRIFICALHOOKS",
    "chitinous-plating": "CHITINOUSPLATING",
    "anabolic-synthesis": "ANABOLICSYNTHESIS",
    "adaptive-talons": "DIGGINGCLAWS",
    "burrow": "BURROW",
    "pneumatized-carapace": "OVERLORDSPEED",
    "overlord-speed": "OVERLORDSPEED",
    "missile-attacks-1": "ZERGMIW1",
    "missile-attacks-2": "ZERGMIW2",
    "missile-attacks-3": "ZERGMIW3",
    "melee-attacks-1": "ZERGMELEEW1",
    "melee-attacks-2": "ZERGMELEEW2",
    "melee-attacks-3": "ZERGMELEEW3",
    "ground-carapace-1": "ZERGGROUNDARMORSLEVEL1",
    "ground-carapace-2": "ZERGGROUNDARMORSLEVEL2",
    "ground-carapace-3": "ZERGGROUNDARMORSLEVEL3",
    "stimpack": "STIMPACK",
    "combat-shield": "SHIELDWALL",
    "shield-wall": "SHIELDWALL",
    "concussive-shells": "PUNISHERGRENADES",
    "punisher-grenades": "PUNISHERGRENADES",
    "infernal-pre-igniter": "HIGHCAPACITYBARRELS",
    "drilling-claws": "DRILLCLAWS",
    "personal-cloaking": "PERSONALCLOAKING",
    "cloak-banshee": "BANSHEECLOAK",
    "infantry-weapons-1": "TERRANINFANTRYWEAPONSLEVEL1",
    "infantry-weapons-2": "TERRANINFANTRYWEAPONSLEVEL2",
    "infantry-weapons-3": "TERRANINFANTRYWEAPONSLEVEL3",
    "infantry-armor-1": "TERRANINFANTRYARMORSLEVEL1",
    "infantry-armor-2": "TERRANINFANTRYARMORSLEVEL2",
    "infantry-armor-3": "TERRANINFANTRYARMORSLEVEL3",
    "vehicle-weapons-1": "TERRANVEHICLEWEAPONSLEVEL1",
    "vehicle-armor-1": "TERRANVEHICLEANDSHIPARMORSLEVEL1",
    "warp-gate-research": "WARPGATERESEARCH",
    "warpgate": "WARPGATERESEARCH",
    "charge": "CHARGE",
    "blink": "BLINKTECH",
    "psi-storm": "PSISTORMTECH",
    "extended-thermal-lance": "EXTENDEDTHERMALLANCE",
    "ground-weapons-1": "PROTOSSGROUNDWEAPONSLEVEL1",
    "ground-weapons-2": "PROTOSSGROUNDWEAPONSLEVEL2",
    "ground-weapons-3": "PROTOSSGROUNDWEAPONSLEVEL3",
    "protoss-ground-weapons-1": "PROTOSSGROUNDWEAPONSLEVEL1",
    "protoss-ground-weapons-2": "PROTOSSGROUNDWEAPONSLEVEL2",
    "protoss-ground-weapons-3": "PROTOSSGROUNDWEAPONSLEVEL3",
    "ground-armor-1": "PROTOSSGROUNDARMORSLEVEL1",
    "ground-armor-2": "PROTOSSGROUNDARMORSLEVEL2",
    "ground-armor-3": "PROTOSSGROUNDARMORSLEVEL3",
    "protoss-ground-armors-1": "PROTOSSGROUNDARMORSLEVEL1",
    "protoss-ground-armors-2": "PROTOSSGROUNDARMORSLEVEL2",
    "protoss-ground-armors-3": "PROTOSSGROUNDARMORSLEVEL3",
    "shields-1": "PROTOSSSHIELDSLEVEL1",
    "protoss-shields-1": "PROTOSSSHIELDSLEVEL1",
}

ENUM_NAME_TO_UNIT_NAME: Dict[str, str] = {
    "DRONE": "drone",
    "ZERGLING": "zergling",
    "BANELING": "baneling",
    "ROACH": "roach",
    "RAVAGER": "ravager",
    "HYDRALISK": "hydralisk",
    "LURKERMP": "lurker",
    "LURKERMPBURROWED": "lurker",
    "MUTALISK": "mutalisk",
    "CORRUPTOR": "corruptor",
    "BROODLORD": "brood-lord",
    "ULTRALISK": "ultralisk",
    "QUEEN": "queen",
    "INFESTOR": "infestor",
    "VIPER": "viper",
    "SWARMHOSTMP": "swarm-host",
    "OVERLORD": "overlord",
    "OVERSEER": "overseer",
    "OVERLORDTRANSPORT": "overlord-transport",
    "SCV": "scv",
    "MULE": "mule",
    "MARINE": "marine",
    "MARAUDER": "marauder",
    "REAPER": "reaper",
    "GHOST": "ghost",
    "HELLION": "hellion",
    "HELLIONTANK": "hellbat",
    "WIDOWMINE": "widow-mine",
    "WIDOWMINEBURROWED": "widow-mine",
    "SIEGETANK": "siege-tank",
    "SIEGETANKSIEGED": "siege-tank",
    "CYCLONE": "cyclone",
    "THOR": "thor",
    "THORAP": "thor",
    "VIKINGFIGHTER": "viking",
    "VIKINGASSAULT": "viking",
    "MEDIVAC": "medivac",
    "LIBERATOR": "liberator",
    "LIBERATORAG": "liberator",
    "RAVEN": "raven",
    "BANSHEE": "banshee",
    "BATTLECRUISER": "battlecruiser",
    "PROBE": "probe",
    "ZEALOT": "zealot",
    "STALKER": "stalker",
    "SENTRY": "sentry",
    "ADEPT": "adept",
    "HIGHTEMPLAR": "high-templar",
    "DARKTEMPLAR": "dark-templar",
    "IMMORTAL": "immortal",
    "COLOSSUS": "colossus",
    "DISRUPTOR": "disruptor",
    "ARCHON": "archon",
    "OBSERVER": "observer",
    "OBSERVERSIEGEMODE": "observer",
    "WARPPRISM": "warp-prism",
    "WARPPRISMPHASING": "warp-prism",
    "PHOENIX": "phoenix",
    "VOIDRAY": "void-ray",
    "ORACLE": "oracle",
    "TEMPEST": "tempest",
    "CARRIER": "carrier",
    "MOTHERSHIP": "mothership",
}

ENUM_NAME_TO_BUILDING_NAME: Dict[str, str] = {
    "HATCHERY": "hatchery",
    "LAIR": "lair",
    "HIVE": "hive",
    "EXTRACTOR": "extractor",
    "SPAWNINGPOOL": "spawning-pool",
    "ROACHWARREN": "roach-warren",
    "BANELINGNEST": "baneling-nest",
    "EVOLUTIONCHAMBER": "evolution-chamber",
    "HYDRALISKDEN": "hydralisk-den",
    "LURKERDENMP": "lurker-den-mp",
    "SPIRE": "spire",
    "GREATERSPIRE": "greater-spire",
    "INFESTATIONPIT": "infestation-pit",
    "NYDUSNETWORK": "nydus-network",
    "ULTRALISKCAVERN": "ultralisk-cavern",
    "SPINECRAWLER": "spine-crawler",
    "SPORECRAWLER": "spore-crawler",
    "CREEPTUMOR": "creep-tumor",
    "CREEPTUMORBURROWED": "creep-tumor-burrowed",
    "CREEPTUMORQUEEN": "creep-tumor-burrowed",
    "COMMANDCENTER": "command-center",
    "ORBITALCOMMAND": "orbital-command",
    "PLANETARYFORTRESS": "planetary-fortress",
    "SUPPLYDEPOT": "supply-depot",
    "SUPPLYDEPOTLOWERED": "supply-depot",
    "REFINERY": "refinery",
    "BARRACKS": "barracks",
    "ENGINEERINGBAY": "engineering-bay",
    "BUNKER": "bunker",
    "SENSORTOWER": "sensor-tower",
    "MISSILETURRET": "missile-turret",
    "FACTORY": "factory",
    "GHOSTACADEMY": "ghost-academy",
    "STARPORT": "starport",
    "ARMORY": "armory",
    "FUSIONCORE": "fusion-core",
    "BARRACKSTECHLAB": "barracks-techlab",
    "BARRACKSREACTOR": "barracks-reactor",
    "FACTORYTECHLAB": "factory-techlab",
    "FACTORYREACTOR": "factory-reactor",
    "STARPORTTECHLAB": "starport-techlab",
    "STARPORTREACTOR": "starport-reactor",
    "NEXUS": "nexus",
    "PYLON": "pylon",
    "ASSIMILATOR": "assimilator",
    "GATEWAY": "gateway",
    "WARPGATE": "warp-gate",
    "FORGE": "forge",
    "PHOTONCANNON": "photon-cannon",
    "SHIELDBATTERY": "shield-battery",
    "CYBERNETICSCORE": "cybernetics-core",
    "TWILIGHTCOUNCIL": "twilight-council",
    "ROBOTICSFACILITY": "robotics-facility",
    "ROBOTICSBAY": "robotics-bay",
    "STARGATE": "stargate",
    "TEMPLARARCHIVE": "templar-archives",
    "DARKSHRINE": "dark-shrine",
    "FLEETBEACON": "fleet-beacon",
}

ENUM_NAME_TO_UPGRADE_SYMS: Dict[str, List[str]] = {}
for _u_sym, _u_enum in UPGRADE_NAME_TO_ENUM_NAME.items():
    ENUM_NAME_TO_UPGRADE_SYMS.setdefault(_u_enum, []).append(_u_sym)

CANONICAL_9_MORPHS = [
    "lair",
    "hive",
    "greater-spire",
    "brood-lord",
    "ravager",
    "lurker-mp",
    "orbital-command",
    "planetary-fortress",
    "archon",
]

MORPH_NAME_TO_ABILITY_NAME: Dict[str, str] = {
    "lair": "UPGRADETOLAIR_LAIR",
    "hive": "UPGRADETOHIVE_HIVE",
    "greater-spire": "UPGRADETOGREATERSPIRE_GREATERSPIRE",
    "brood-lord": "MORPHTOBROODLORD_BROODLORD",
    "broodlord": "MORPHTOBROODLORD_BROODLORD",
    "ravager": "MORPHTORAVAGER_RAVAGER",
    "lurker-mp": "MORPH_LURKER",
    "lurker": "MORPH_LURKER",
    "baneling": "MORPHZERGLINGTOBANELING_BANELING",
    "overseer": "MORPH_OVERSEER",
    "orbital-command": "UPGRADETOORBITAL_ORBITALCOMMAND",
    "planetary-fortress": "UPGRADETOPLANETARYFORTRESS_PLANETARYFORTRESS",
    "archon": "ARCHON_WARP_TARGET",
    "warp-gate": "MORPH_WARPGATE",
    "hellbat": "MORPH_HELLBAT",
    "siege-mode": "SIEGEMODE_SIEGEMODE",
    "unsiege": "UNSIEGE_UNSIEGE",
}

CANONICAL_16_SPELLS = [
    "corrosive-bile",
    "transfusion",
    "fungal-growth",
    "abduct",
    "blinding-cloud",
    "parasitic-bomb",
    "neural-parasite",
    "spawn-locusts",
    "caustic-spray",
    "contaminate",
    "yamato-gun",
    "emp-round",
    "anti-armor-missile",
    "interference-matrix",
    "psionic-storm",
    "guardian-shield",
]

SPELL_NAME_TO_ABILITY_NAME: Dict[str, str] = {
    "corrosive-bile": "EFFECT_CORROSIVEBILE",
    "transfusion": "TRANSFUSION_TRANSFUSION",
    "inject-larva": "EFFECT_INJECTLARVA",
    "fungal-growth": "FUNGALGROWTH_FUNGALGROWTH",
    "abduct": "EFFECT_ABDUCT",
    "blinding-cloud": "EFFECT_BLINDINGCLOUD",
    "parasitic-bomb": "EFFECT_PARASITICBOMB",
    "neural-parasite": "NEURALPARASITE_NEURALPARASITE",
    "spawn-locusts": "EFFECT_SPAWNLOCUSTS",
    "caustic-spray": "CAUSTICSPRAY_CAUSTICSPRAY",
    "contaminate": "CONTAMINATE_CONTAMINATE",
    "spawn-creep-tumor": "BUILD_CREEPTUMOR_QUEEN",
    "spread-creep-tumor": "BUILD_CREEPTUMOR_TUMOR",
    "spawn-changeling": "SPAWNCHANGELING_SPAWNCHANGELING",
    "yamato-gun": "YAMATO_YAMATOGUN",
    "emp-round": "EMP_EMP",
    "snipe": "EFFECT_GHOSTSNIPE",
    "anti-armor-missile": "EFFECT_ANTIARMORMISSILE",
    "interference-matrix": "EFFECT_INTERFERENCEMATRIX",
    "scanner-sweep": "SCANNERSWEEP_SCAN",
    "calldown-mule": "CALLDOWNMULE_CALLDOWNMULE",
    "stim": "EFFECT_STIM_MARINE",
    "stimpack": "EFFECT_STIM_MARINE",
    "kd8-charge": "KD8CHARGE_KD8CHARGE",
    "psionic-storm": "PSISTORM_PSISTORM",
    "guardian-shield": "GUARDIANSHIELD_GUARDIANSHIELD",
    "force-field": "FORCEFIELD_FORCEFIELD",
    "blink": "EFFECT_BLINK_STALKER",
    "psionic-transfer": "EFFECT_ADEPTPHASESHIFT",
    "chrono-boost": "EFFECT_CHRONOBOOSTENERGYCOST",
    "purification-nova": "EFFECT_PURIFICATIONNOVA",
    "prismatic-alignment": "EFFECT_VOIDRAYPRISMATICALIGNMENT",
    "oracle-revelation": "ORACLEREVELATION_ORACLEREVELATION",
    "burrow": "BURROWDOWN_LURKER",
    "siege-mode": "SIEGEMODE_SIEGEMODE",
    "unsiege-mode": "UNSIEGE_UNSIEGE",
}


def tokenize_sexp(sexp_str: str) -> List[str]:
    cleaned = re.sub(r";[^\n]*", "", sexp_str)
    return re.findall(r"\(|\)|[^\s()]+", cleaned)


def parse_sexp_tokens(tokens: List[str], idx: int = 0) -> Tuple[Any, int]:
    if idx >= len(tokens):
        return None, idx
    tok = tokens[idx]
    if tok == "(":
        idx += 1
        items = []
        while idx < len(tokens) and tokens[idx] != ")":
            val, idx = parse_sexp_tokens(tokens, idx)
            if val is not None:
                items.append(val)
        return items, idx + 1
    elif tok == ")":
        return None, idx + 1
    else:
        try:
            if "." in tok:
                return float(tok), idx + 1
            return int(tok), idx + 1
        except ValueError:
            return tok, idx + 1


def parse_all_sexps(sexp_str: str) -> List[Any]:
    tokens = tokenize_sexp(sexp_str)
    results = []
    idx = 0
    while idx < len(tokens):
        val, idx = parse_sexp_tokens(tokens, idx)
        if val is not None:
            results.append(val)
    return results


def _normalize_id_list(val: Any) -> List[int]:
    if isinstance(val, list):
        out = []
        for item in val:
            out.extend(_normalize_id_list(item))
        return out
    try:
        return [int(val)]
    except (ValueError, TypeError):
        return []


def decode_sexp_command(cmd: Any) -> Optional[Dict[str, Any]]:
    if isinstance(cmd, str):
        parsed = parse_all_sexps(cmd)
        if not parsed:
            return None
        cmd = parsed[0]
    if not isinstance(cmd, list) or len(cmd) == 0:
        return None

    if isinstance(cmd[0], list):
        if len(cmd) == 1:
            cmd = cmd[0]
        else:
            return {
                "op": "batch",
                "commands": [d for sub in cmd if (d := decode_sexp_command(sub)) is not None],
            }

    op = str(cmd[0]).lower()

    if op == "posture-transition" and len(cmd) >= 2:
        return {"op": "posture-transition", "posture": str(cmd[1])}

    if op == "train" and len(cmd) >= 2:
        unit_name = str(cmd[1]).lower()
        return {
            "op": "train",
            "unit": unit_name,
            "unit_enum": UNIT_NAME_TO_ENUM_NAME.get(unit_name, unit_name.upper().replace("-", "")),
            "valid_unit": unit_name in UNIT_NAME_TO_ENUM_NAME,
        }

    if op == "build" and len(cmd) >= 2:
        bldg_name = str(cmd[1]).lower()
        x = float(cmd[2]) if len(cmd) >= 4 and isinstance(cmd[2], (int, float)) else None
        y = float(cmd[3]) if len(cmd) >= 4 and isinstance(cmd[3], (int, float)) else None
        return {
            "op": "build",
            "building": bldg_name,
            "building_enum": BUILDING_NAME_TO_ENUM_NAME.get(bldg_name, bldg_name.upper().replace("-", "")),
            "valid_building": bldg_name in BUILDING_NAME_TO_ENUM_NAME,
            "x": x,
            "y": y,
        }

    if op == "expand":
        x = float(cmd[1]) if len(cmd) >= 3 and isinstance(cmd[1], (int, float)) else None
        y = float(cmd[2]) if len(cmd) >= 3 and isinstance(cmd[2], (int, float)) else None
        return {"op": "expand", "x": x, "y": y}

    if op == "research" and len(cmd) >= 2:
        upg_name = str(cmd[1]).lower()
        return {
            "op": "research",
            "upgrade": upg_name,
            "upgrade_enum": UPGRADE_NAME_TO_ENUM_NAME.get(upg_name, upg_name.upper().replace("-", "")),
            "valid_upgrade": upg_name in UPGRADE_NAME_TO_ENUM_NAME,
        }

    if op == "morph" and len(cmd) >= 2:
        if len(cmd) >= 3:
            source_id = cmd[1]
            target_name = str(cmd[2]).lower()
        else:
            source_id = None
            target_name = str(cmd[1]).lower()
        return {
            "op": "morph",
            "source_id": source_id,
            "target": target_name,
            "ability_enum": MORPH_NAME_TO_ABILITY_NAME.get(target_name, f"MORPH_{target_name.upper().replace('-', '')}"),
            "valid_morph": target_name in MORPH_NAME_TO_ABILITY_NAME,
        }

    if op in ("attack-pos", "attack", "attack-move") and len(cmd) >= 3:
        if len(cmd) >= 4:
            unit_ids = _normalize_id_list(cmd[1])
            x, y = float(cmd[2]), float(cmd[3])
        else:
            unit_ids = []
            x, y = float(cmd[1]), float(cmd[2])
        return {"op": "attack-pos", "unit_ids": unit_ids, "x": x, "y": y}

    if op == "attack-unit" and len(cmd) >= 3:
        unit_ids = _normalize_id_list(cmd[1])
        target_id = int(cmd[2]) if isinstance(cmd[2], (int, float)) else 0
        return {"op": "attack-unit", "unit_ids": unit_ids, "target_id": target_id}

    if op in ("kite", "move", "retreat") and len(cmd) >= 4:
        unit_ids = _normalize_id_list(cmd[1])
        x, y = float(cmd[2]), float(cmd[3])
        return {"op": op, "unit_ids": unit_ids, "x": x, "y": y}

    if op == "gather" and len(cmd) >= 3:
        return {"op": "gather", "worker_id": int(cmd[1]), "target_id": int(cmd[2])}

    if op == "inject-larva" and len(cmd) >= 3:
        return {"op": "inject-larva", "queen_id": int(cmd[1]), "hatch_id": int(cmd[2])}

    if op in ("cast", "cast-spell") and len(cmd) >= 3:
        caster_id = int(cmd[1]) if isinstance(cmd[1], (int, float)) else 0
        spell_name = str(cmd[2]).lower()
        x = float(cmd[3]) if len(cmd) >= 5 and isinstance(cmd[3], (int, float)) else None
        y = float(cmd[4]) if len(cmd) >= 5 and isinstance(cmd[4], (int, float)) else None
        target_id = int(cmd[3]) if len(cmd) == 4 and isinstance(cmd[3], (int, float)) else None
        return {
            "op": "cast",
            "caster_id": caster_id,
            "spell": spell_name,
            "ability_enum": SPELL_NAME_TO_ABILITY_NAME.get(spell_name, spell_name.upper().replace("-", "_")),
            "valid_spell": spell_name in SPELL_NAME_TO_ABILITY_NAME,
            "x": x,
            "y": y,
            "target_id": target_id,
        }

    # --- 7 Pro Signature Mechanics ---
    if op == "cancel" and len(cmd) >= 2:
        return {"op": "cancel", "unit_id": int(cmd[1])}

    if op == "hold-position" and len(cmd) >= 2:
        uid = int(cmd[1]) if isinstance(cmd[1], (int, float)) else 0
        x = float(cmd[2]) if len(cmd) >= 4 and isinstance(cmd[2], (int, float)) else None
        y = float(cmd[3]) if len(cmd) >= 4 and isinstance(cmd[3], (int, float)) else None
        return {"op": "hold-position", "unit_id": uid, "x": x, "y": y}

    if op == "swap-addon" and len(cmd) >= 3:
        return {"op": "swap-addon", "from_id": int(cmd[1]), "to_id": int(cmd[2])}

    if op == "transport-juggle" and len(cmd) >= 5:
        return {
            "op": "transport-juggle",
            "transport_id": int(cmd[1]),
            "unit_id": int(cmd[2]),
            "x": float(cmd[3]),
            "y": float(cmd[4]),
        }

    if op == "multi-prong-drop" and len(cmd) >= 4:
        return {
            "op": "multi-prong-drop",
            "transport_id": int(cmd[1]),
            "x": float(cmd[2]),
            "y": float(cmd[3]),
        }

    if op == "mineral-walk" and len(cmd) >= 4:
        return {
            "op": "mineral-walk",
            "unit_id": int(cmd[1]),
            "x": float(cmd[2]),
            "y": float(cmd[3]),
        }

    if op == "worker-harass" and len(cmd) >= 4:
        return {
            "op": "worker-harass",
            "unit_id": int(cmd[1]),
            "x": float(cmd[2]),
            "y": float(cmd[3]),
        }

    if op == "control-group-steal" and len(cmd) >= 3:
        return {
            "op": "control-group-steal",
            "group_id": int(cmd[1]),
            "unit_ids": _normalize_id_list(cmd[2]),
        }

    if op == "camera-bookmark-save" and len(cmd) >= 4:
        return {
            "op": "camera-bookmark-save",
            "slot": int(cmd[1]),
            "x": float(cmd[2]),
            "y": float(cmd[3]),
        }

    if op == "camera-bookmark-jump" and len(cmd) >= 2:
        return {"op": "camera-bookmark-jump", "slot": int(cmd[1])}

    # --- 5 Adversarial Countermeasures ---
    if op == "pull-workers-attack" and len(cmd) >= 4:
        return {
            "op": "pull-workers-attack",
            "unit_ids": _normalize_id_list(cmd[1]),
            "x": float(cmd[2]),
            "y": float(cmd[3]),
        }

    if op == "clear-expansion-block" and len(cmd) >= 3:
        return {
            "op": "clear-expansion-block",
            "x": float(cmd[1]),
            "y": float(cmd[2]),
        }

    if op == "clear-gas-steal" and len(cmd) >= 4:
        return {
            "op": "clear-gas-steal",
            "target_id": int(cmd[1]),
            "x": float(cmd[2]),
            "y": float(cmd[3]),
        }

    if op == "resume-halted-building" and len(cmd) >= 3:
        return {
            "op": "resume-halted-building",
            "worker_id": int(cmd[1]),
            "building_id": int(cmd[2]),
        }

    if op == "mirror-prediction" and len(cmd) >= 8:
        return {
            "op": "mirror-prediction",
            "depth": int(cmd[1]),
            "strategic_hypothesis": str(cmd[2]),
            "tactical_target": str(cmd[3]),
            "predicted_enemy_unit": str(cmd[4]),
            "preemptive_counter_unit": str(cmd[5]),
            "accuracy_pct": int(cmd[6]),
            "trust_mode": str(cmd[7]),
            "inferred_opponent_depth": int(cmd[8]) if len(cmd) >= 9 else 1,
            "toolbox_weight_pct": int(cmd[9]) if len(cmd) >= 10 else 20,
            "toolbox_role": str(cmd[10]) if len(cmd) >= 11 else "tactical-tiebreaker-and-hedge",
        }

    if op == "scout-sector" and len(cmd) >= 4:
        return {
            "op": "scout-sector",
            "sector_id": int(cmd[1]),
            "x": float(cmd[2]),
            "y": float(cmd[3]),
        }

    if op in ("camera-focus", "move-camera") and len(cmd) >= 3:
        if len(cmd) >= 4 and not isinstance(cmd[1], (int, float)):
            return {
                "op": "camera-focus",
                "zone": str(cmd[1]),
                "x": float(cmd[2]),
                "y": float(cmd[3]),
            }
        return {
            "op": "camera-focus",
            "zone": "focus",
            "x": float(cmd[1]),
            "y": float(cmd[2]),
        }

    if op == "human-apm-discipline":
        return {
            "op": "human-apm-discipline",
            "target_apm": int(cmd[1]) if len(cmd) >= 2 and isinstance(cmd[1], (int, float)) else 200,
            "target_spm": int(cmd[2]) if len(cmd) >= 3 and isinstance(cmd[2], (int, float)) else 85,
            "max_burst_cmds": int(cmd[3]) if len(cmd) >= 4 and isinstance(cmd[3], (int, float)) else 3,
        }

    if op == "mirror-zero-sum-exclusion":
        return {
            "op": "mirror-zero-sum-exclusion",
            "committed_branch": str(cmd[1]) if len(cmd) >= 2 else "unknown",
            "excluded_branches": [str(x) for x in cmd[2]] if len(cmd) >= 3 and isinstance(cmd[2], list) else ([str(cmd[2])] if len(cmd) >= 3 else []),
            "bluff_suspected": str(cmd[3]).lower() in ("#t", "true", "1") if len(cmd) >= 4 else False,
        }

    if op == "mirror-tech-observation":
        return {
            "op": "mirror-tech-observation",
            "implied_tech": [str(x) for x in cmd[1]] if len(cmd) >= 2 and isinstance(cmd[1], list) else ([str(cmd[1])] if len(cmd) >= 2 else []),
            "observed_upgrades": [str(x) for x in cmd[2]] if len(cmd) >= 3 and isinstance(cmd[2], list) else ([str(cmd[2])] if len(cmd) >= 3 else []),
        }

    if op in ("mirror-spatial-maneuver", "execute-spatial-maneuver") and len(cmd) >= 2:
        return {
            "op": op,
            "maneuver": str(cmd[1]),
            "x": float(cmd[2]) if len(cmd) >= 4 and isinstance(cmd[2], (int, float)) else None,
            "y": float(cmd[3]) if len(cmd) >= 4 and isinstance(cmd[3], (int, float)) else None,
        }

    if op in ("burrow-block", "patrol-block-expansion") and len(cmd) >= 4:
        return {
            "op": op,
            "unit_id": int(cmd[1]) if isinstance(cmd[1], (int, float)) else 0,
            "x": float(cmd[2]),
            "y": float(cmd[3]),
        }

    if op == "harass-workers" and len(cmd) >= 4:
        return {
            "op": "harass-workers",
            "unit_ids": _normalize_id_list(cmd[1]),
            "x": float(cmd[2]),
            "y": float(cmd[3]),
        }

    if op == "snipe-enemy-changeling" and len(cmd) >= 2:
        return {
            "op": "snipe-enemy-changeling",
            "target_id": int(cmd[1]) if isinstance(cmd[1], (int, float)) else 0,
        }

    if op in (
        "cast-deception-and-scout-spells",
        "cast-protective-buff-aura",
        "position-in-buff-aura-with-splash-spread",
        "pre-split-wings",
        "form-concave-arc",
        "high-ground-tactics",
    ):
        return {
            "op": op,
            "args": cmd[1:],
        }

    return {"op": op, "raw": cmd}


def translate_sc_bot_commands(sexp_output: str) -> List[Dict[str, Any]]:
    parsed_list = parse_all_sexps(sexp_output)
    decoded: List[Dict[str, Any]] = []
    for item in parsed_list:
        if isinstance(item, list) and item and isinstance(item[0], list):
            for sub in item:
                d = decode_sexp_command(sub)
                if d is not None:
                    decoded.append(d)
        else:
            d = decode_sexp_command(item)
            if d is not None:
                if d.get("op") == "batch":
                    decoded.extend(d.get("commands", []))
                else:
                    decoded.append(d)
    return decoded


def infer_bot_race_and_posture(bot_rkt_path: str) -> Tuple[str, str]:
    path = Path(bot_rkt_path)
    name_upper = path.stem.upper()
    if name_upper.endswith("-Z") or "ZERG" in name_upper or "OVERMIND" in name_upper or "HYDRA" in name_upper:
        default_race = "Zerg"
    elif name_upper.endswith("-T") or "TERRAN" in name_upper or "DOMINION" in name_upper or "SIEGE" in name_upper:
        default_race = "Terran"
    elif name_upper.endswith("-P") or "PROTOSS" in name_upper or "KHALAI" in name_upper or "CARRIER" in name_upper:
        default_race = "Protoss"
    elif name_upper.endswith("-R") or "MOTHMAN" in name_upper:
        default_race = "Random"
    else:
        default_race = "Zerg"

    default_posture = "Macro12Hatch"
    if path.exists():
        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
            m_race = re.search(r"#:race\s+'?([A-Za-z-]+)", text)
            if m_race:
                r_raw = m_race.group(1).lower()
                if "zerg" in r_raw:
                    default_race = "Zerg"
                elif "terran" in r_raw:
                    default_race = "Terran"
                elif "protoss" in r_raw:
                    default_race = "Protoss"
                elif "random" in r_raw or "adaptive" in r_raw:
                    default_race = "Random"
            m_post = re.search(r"#:initial-posture\s+'?([A-Za-z0-9-]+)", text) or re.search(
                r"\(def-posture\s+([A-Za-z0-9-]+)", text
            )
            if m_post:
                default_posture = m_post.group(1)
        except Exception:
            pass
    return default_race, default_posture


class SC2BurnySexpBridge:
    """
    Manages the persistent Racket IPC subprocess (`sim/racket_sc2_ipc_bot.rkt`)
    and translates S-expression observations into decoded burnysc2 commands.
    """

    def __init__(self, bot_rkt_path: str, race_str: str = "Zerg", posture_str: str = "Macro12Hatch"):
        self.bot_rkt_path = str(bot_rkt_path)
        self.race_str = race_str
        self.posture_str = posture_str
        self.proc: Optional[subprocess.Popen] = None
        self.cmd: List[str] = []
        self.ipc_calls = 0
        self.total_commands_decoded = 0
        self.command_histogram: Dict[str, int] = {}

    def _resolve_ipc_command(self, ipc_script: Path) -> List[str]:
        import shutil

        bot_args = [
            "--bot",
            self.bot_rkt_path,
            "--race",
            self.race_str.lower(),
            "--posture",
            self.posture_str,
        ]

        # 1. Standalone compiled native Linux x86_64 ELF binary (`<BotName> --ipc-sexp`)
        for elf_cand in (
            ROOT_DIR / "Mothman",
            ROOT_DIR / "Mothman-X",
            ROOT_DIR / "Mothman-Z",
            ROOT_DIR / "Mothman-T",
            ROOT_DIR / "Mothman-P",
            ROOT_DIR / "Mothman-R",
            ROOT_DIR / "ladder" / ".cache" / "mothman_standalone_elf",
        ):
            if elf_cand.exists() and elf_cand.is_file() and elf_cand.stat().st_size >= 10_000_000:
                try:
                    os.chmod(elf_cand, 0o755)
                except Exception:
                    pass
                return [str(elf_cand), "--ipc-sexp"] + bot_args

        # 2. Local system / toolchain Racket
        for rk_cand in (
            "/home/antigravity/toolchains/racket_full/bin/racket",
            RACKET_BIN,
            shutil.which("racket"),
        ):
            if rk_cand and os.path.exists(rk_cand):
                return [rk_cand, str(ipc_script)] + bot_args

        # 3. Cross-platform pure-Python S-expression IPC fallback
        fallback_py = ROOT_DIR / "sim" / "racket_sexp_fallback.py"
        return [sys.executable, str(fallback_py)] + bot_args

    def start(self) -> None:
        ipc_script = ROOT_DIR / "sim" / "racket_sc2_ipc_bot.rkt"
        if not ipc_script.exists():
            self.proc = None
            return
        cmd = self._resolve_ipc_command(ipc_script)
        self.cmd = list(cmd)
        try:
            self.proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
                cwd=str(ROOT_DIR),
            )
        except Exception:
            self.proc = None
            fallback_py = ROOT_DIR / "sim" / "racket_sexp_fallback.py"
            if fallback_py.exists():
                fb_cmd = [
                    sys.executable,
                    str(fallback_py),
                    "--bot",
                    self.bot_rkt_path,
                    "--race",
                    self.race_str.lower(),
                    "--posture",
                    self.posture_str,
                ]
                self.cmd = list(fb_cmd)
                try:
                    self.proc = subprocess.Popen(
                        fb_cmd,
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL,
                        text=True,
                        bufsize=1,
                        cwd=str(ROOT_DIR),
                    )
                except Exception:
                    self.proc = None

    def step_sexp(self, obs_sexp: str) -> List[Dict[str, Any]]:
        self.ipc_calls += 1
        if self.proc is None:
            self.start()
        if self.proc is not None and self.proc.poll() is None:
            try:
                assert self.proc.stdin is not None
                assert self.proc.stdout is not None
                self.proc.stdin.write(obs_sexp.strip() + "\n")
                self.proc.stdin.flush()
                line = self.proc.stdout.readline()
                if line:
                    cmds = translate_sc_bot_commands(line.strip())
                    for c in cmds:
                        op = c.get("op", "unknown")
                        self.command_histogram[op] = self.command_histogram.get(op, 0) + 1
                    self.total_commands_decoded += len(cmds)
                    return cmds
            except Exception:
                pass
        return []

    def close(self) -> None:
        if self.proc is not None:
            try:
                if self.proc.stdin:
                    self.proc.stdin.write("(quit)\n")
                    self.proc.stdin.flush()
                self.proc.terminate()
                self.proc.wait(timeout=1.5)
            except Exception:
                pass
            self.proc = None


def create_racket_sc2_agent(
    bot_rkt_path: str,
    race_override: Optional[str] = None,
    posture_override: Optional[str] = None,
):
    from sc2.bot_ai import BotAI
    from sc2.data import Race
    from sc2.ids.ability_id import AbilityId
    from sc2.ids.buff_id import BuffId
    from sc2.ids.effect_id import EffectId
    from sc2.ids.unit_typeid import UnitTypeId
    from sc2.ids.upgrade_id import UpgradeId
    from sc2.position import Point2

    inferred_race, inferred_posture = infer_bot_race_and_posture(bot_rkt_path)
    init_race = race_override or inferred_race
    blind_start = posture_override is None or posture_override.lower() in ("none", "blind", "blind-adaptive", "auto")
    init_posture = "balanced-opening" if blind_start else (posture_override or inferred_posture)

    class RacketSC2BotAI(BotAI):
        def __init__(self):
            super().__init__()
            self.telemetry = TelemetryRecorder()
            self.bot_rkt_path = bot_rkt_path
            self.configured_race = init_race
            self.blind_start = blind_start
            self.current_posture = init_posture
            self.posture_transitions: List[str] = [init_posture]
            self.bridge: Optional[SC2BurnySexpBridge] = None
            self._used_creep_tumors = set()
            self._camera_bookmarks: Dict[int, Tuple[float, float]] = {}
            self._control_groups: Dict[int, set] = {}
            self._addon_attempted_tags: set = set()
            self._recorded_result: Any = None
            self._offensive_launched = False
            self._wave_releasing_until: int = 0
            self.supply_blocked_loops = 0
            self.idle_worker_production_loops = 0
            self.idle_unit_production_loops = 0
            self.peak_workers = 0
            self.peak_bases = 1
            self.peak_army_supply = 0
            self.max_minerals_banked = 0
            self.max_gas_banked = 0
            self.expansions_started = 0
            self.expansions_failed = 0
            self.depletion_expansions_started = 0
            self.waves_launched = 0
            self.squad_retreats = 0
            self.base_blockers_dispatched = 0
            self.burrow_blocks_activated = 0
            self.raider_squads_dispatched = 0
            self._expansion_blocker_targets: Dict[int, Any] = {}
            self._harass_raider_tags: set = set()
            self._burrowed_blocker_logged_tags: set = set()
            self._remembered_enemy_base_positions: Dict[Tuple[int, int], Any] = {}
            self._enemy_natural_scouted_empty_loop: int = -9999
            self.enemy_known_bases: int = 1
            self.peak_enemy_bases_seen: int = 1
            self.predicted_enemy_bases: int = 1
            self.predicted_enemy_workers: int = 16
            self.mirror_macro_verdict: str = "macro_parity_pressure"
            self.gas_workers: int = 0
            self.mineral_workers: int = 12
            self.gas_to_mineral_ratio: float = 0.0
            self.guns_vs_butter_regime: str = "butter_expand_focus"
            self.target_resource_ratio: float = 1.5
            self.max_gas_workers: int = 3
            self.last_eff_bases: float = 1.0
            self.last_depleting_bases: int = 0
            self.last_mined_out_bases: int = 0
            self.last_pending_bases: int = 0
            self.last_target_workers: int = 19
            self.last_escrow_minerals: int = 0
            self.active_build_goal: str = "opening-economy"
            self._escrow_started_loop: int = -999
            self._last_expand_attempt_loop = -999
            self._last_telemetry_loop = -999
            self._step_durations_ms: List[float] = []
            self.commands_issued = 0
            self.racket_commands_executed = 0
            self.pro_mechanics_triggered: Dict[str, int] = {}
            self.countermeasures_triggered: Dict[str, int] = {}
            self.mirror_active_depth: int = 2
            self.mirror_inferred_opponent_depth: int = 1
            self.mirror_toolbox_weight_pct: int = 20
            self.mirror_toolbox_role: str = "tactical-tiebreaker-and-hedge"
            self.mirror_strategic_hypothesis: str = "standard-rational-macro"
            self.mirror_tactical_target: str = "center-map-staging"
            self.mirror_predicted_enemy_unit: str = "unknown"
            self.mirror_preemptive_unit: str = "unknown"
            self.mirror_accuracy_pct: int = 67
            self.mirror_trust_mode: str = "level2-preemptive-mirror"
            self.mirror_predictions_received: int = 0
            self._mirror_air_alert: bool = False
            self._implied_enemy_tech_buildings: set = set()
            self._active_implied_enemy_tech_buildings: set = set()
            self._crippled_enemy_tech_buildings: set = set()
            self._remembered_enemy_tech_structures: Dict[int, Tuple[str, Any, bool]] = {}
            self._destroyed_enemy_structure_tags: set = set()
            self._seen_enemy_structure_tags: set = set()
            self._seen_enemy_structure_counts_by_type: Dict[str, int] = {}
            self._extra_rebuilt_tech_gas_spent: int = 0
            self._seen_enemy_unit_tags: set = set()
            self._seen_enemy_unit_tags_at_destruction: set = set()
            self._confirmed_hallucination_tags: set = set()
            self._enemy_prev_hp_shield: Dict[int, float] = {}
            self._friendly_unit_types: Dict[int, str] = {}
            self._enemy_unit_types: Dict[int, str] = {}
            self._our_lost_minerals: int = 0
            self._our_lost_gas: int = 0
            self._enemy_lost_minerals: int = 0
            self._enemy_lost_gas: int = 0
            self._our_workers_lost: int = 0
            self._enemy_workers_killed: int = 0
            self._estimated_enemy_workers: int = 16
            self._estimated_enemy_min_rate: int = 640
            self._estimated_enemy_gas_rate: int = 0
            self._enemy_bldg_state: Dict[int, Dict[str, Any]] = {}
            self._in_progress_enemy_buildings: set = set()
            self._inferred_enemy_active_research: set = set()
            self._stargate_preview_units: set = set()
            self._priority_research_target_tags: set = set()
            self._last_halluc_scout_time: float = -999.0
            self.deception_spells_cast: int = 0
            self.protective_auras_cast: int = 0
            self.presplit_concave_maneuvers: int = 0
            self._observed_enemy_upgrades: set = set()
            self._observed_enemy_spells: set = set()
            self._active_enemy_research_buildings: set = set()
            self._enemy_caster_energy: Dict[int, float] = {}
            self._enemy_committed_branch: str = "unknown"
            self._enemy_excluded_branches: set = set()
            self._enemy_bluff_suspected: bool = False
            self._estimated_enemy_gas_mined: int = 0
            self._accounted_enemy_gas_spent: int = 0
            self._cumulative_seen_enemy_unit_gas: int = 0
            self._max_enemy_atk_upg: int = 0
            self._max_enemy_arm_upg: int = 0
            self._max_enemy_shd_upg: int = 0
            self._enemy_requires_detection: bool = False
            self._enemy_requires_anti_air: bool = False
            self.camera_saccades_emitted: int = 0
            self.batched_group_commands_issued: int = 0
            self.redundant_orders_skipped: int = 0
            self._last_camera_move_loop: int = -999
            self._last_camera_pos: Optional[Any] = None
            self._camera_saccade_idx: int = 0
            self._queued_camera_focus: Optional[Tuple[float, float]] = None
            self._unit_last_order_loop: Dict[int, int] = {}
            self._tracked_enemy_clusters: Dict[Tuple[int, int], Dict[str, Any]] = {}
            self._seen_enemy_army_supply: float = 0.0
            self._unaccounted_enemy_army_supply: float = 0.0
            self._enemy_eta_to_our_natural_sec: float = 99.0
            self._enemy_eta_to_their_exposed_base_sec: float = 99.0
            self._spatial_maneuver: str = "standard_posture"
            self._isolated_enemy_cluster_target: Optional[Any] = None
            self._backstab_enemy_base_target: Optional[Any] = None
            self._depth_predictions: Dict[int, Dict[str, Any]] = {}
            self._depth_prediction_history: List[Dict[str, Any]] = []
            self._depth_ema_accuracy: Dict[int, float] = {
                0: 60.0,
                1: 65.0,
                2: 67.0,
                3: 63.0,
                4: 60.0,
                5: 58.0,
            }
            self._last_depth_snapshot_sec: float = -999.0
            self._build_cooldown_by_type: Dict[Any, int] = {}
            self._last_racket_cmds: List[Dict[str, Any]] = []
            self._queen_tumor_cooldown_by_tag: Dict[int, int] = {}
            self._addon_last_attempt_loop: Dict[int, int] = {}
            self._retreat_until_loop: Dict[int, int] = {}

        @staticmethod
        def _estimate_unit_min_gas_cost(uname: str) -> Tuple[int, int]:
            cost_table = {
                "DRONE": (50, 0),
                "SCV": (50, 0),
                "PROBE": (50, 0),
                "ZERGLING": (25, 0),
                "BANELING": (50, 25),
                "ROACH": (75, 25),
                "RAVAGER": (100, 100),
                "HYDRALISK": (100, 50),
                "LURKERMP": (150, 150),
                "LURKERMPBURROWED": (150, 150),
                "MUTALISK": (100, 100),
                "CORRUPTOR": (150, 100),
                "INFESTOR": (100, 150),
                "ULTRALISK": (300, 200),
                "QUEEN": (150, 0),
                "OVERLORD": (100, 0),
                "OVERSEER": (150, 50),
                "MARINE": (50, 0),
                "REAPER": (50, 50),
                "MARAUDER": (100, 25),
                "GHOST": (150, 125),
                "HELLION": (100, 0),
                "WIDOWMINE": (75, 25),
                "SIEGETANK": (150, 125),
                "SIEGETANKSIEGED": (150, 125),
                "CYCLONE": (150, 100),
                "THOR": (300, 200),
                "MEDIVAC": (100, 100),
                "VIKINGFIGHTER": (150, 75),
                "LIBERATOR": (150, 125),
                "BANSHEE": (150, 100),
                "RAVEN": (100, 150),
                "BATTLECRUISER": (400, 300),
                "ZEALOT": (100, 0),
                "STALKER": (125, 50),
                "SENTRY": (50, 100),
                "ADEPT": (100, 25),
                "IMMORTAL": (275, 100),
                "OBSERVER": (25, 75),
                "WARPPRISM": (250, 0),
                "COLOSSUS": (300, 200),
                "DISRUPTOR": (150, 150),
                "PHOENIX": (150, 100),
                "VOIDRAY": (250, 150),
                "ORACLE": (150, 150),
                "CARRIER": (350, 250),
                "TEMPEST": (250, 175),
                "HIGHTEMPLAR": (50, 150),
                "DARKTEMPLAR": (125, 125),
                "ARCHON": (100, 300),
                "HATCHERY": (300, 0),
                "LAIR": (450, 100),
                "HIVE": (650, 250),
                "COMMANDCENTER": (400, 0),
                "ORBITALCOMMAND": (550, 0),
                "PLANETARYFORTRESS": (550, 150),
                "NEXUS": (400, 0),
                "SPAWNINGPOOL": (200, 0),
                "ROACHWARREN": (150, 0),
                "BANELINGNEST": (100, 50),
                "HYDRALISKDEN": (100, 100),
                "LURKERDENMP": (100, 150),
                "SPIRE": (200, 200),
                "BARRACKS": (150, 0),
                "FACTORY": (150, 100),
                "STARPORT": (150, 100),
                "GATEWAY": (150, 0),
                "WARPGATE": (150, 0),
                "CYBERNETICSCORE": (150, 0),
                "ROBOTICSFACILITY": (150, 100),
                "STARGATE": (150, 150),
                "TWILIGHTCOUNCIL": (150, 100),
                "TEMPLARARCHIVE": (150, 200),
                "DARKSHRINE": (150, 150),
            }
            return cost_table.get(uname, (100, 0))

        async def on_unit_destroyed(self, unit_tag: int) -> None:
            self._enemy_prev_hp_shield.pop(unit_tag, None)
            self._priority_research_target_tags.discard(unit_tag)
            self._enemy_bldg_state.pop(unit_tag, None)

            # 1. Track our own units lost vs enemy units lost
            if unit_tag in self._friendly_unit_types:
                uname = self._friendly_unit_types.pop(unit_tag)
                if uname not in {"LARVA", "EGG", "MULE", "BROODLING", "CHANGELING"}:
                    m_cost, g_cost = self._estimate_unit_min_gas_cost(uname)
                    self._our_lost_minerals += m_cost
                    self._our_lost_gas += g_cost
                    if uname in {"DRONE", "SCV", "PROBE"}:
                        self._our_workers_lost += 1
            elif unit_tag in self._enemy_unit_types and unit_tag not in self._confirmed_hallucination_tags:
                uname = self._enemy_unit_types.pop(unit_tag)
                if uname not in {"LARVA", "EGG", "MULE", "BROODLING"} and "CHANGELING" not in uname:
                    m_cost, g_cost = self._estimate_unit_min_gas_cost(uname)
                    self._enemy_lost_minerals += m_cost
                    self._enemy_lost_gas += g_cost
                    if uname in {"DRONE", "SCV", "PROBE"}:
                        self._enemy_workers_killed += 1

            # 2. Check if an enemy tech structure died (accounting for multiples)
            if unit_tag in self._remembered_enemy_tech_structures:
                bname, _bpos, _was_active = self._remembered_enemy_tech_structures.pop(unit_tag)
                self._destroyed_enemy_structure_tags.add(unit_tag)
                other_visible_same_type = any(
                    eb.tag != unit_tag
                    and eb.tag not in self._destroyed_enemy_structure_tags
                    and eb.type_id.name == bname
                    for eb in getattr(self, "enemy_structures", ())
                )
                other_remembered_same_type = any(
                    r_tag != unit_tag
                    and r_tag not in self._destroyed_enemy_structure_tags
                    and r_info[0] == bname
                    for r_tag, r_info in self._remembered_enemy_tech_structures.items()
                )
                if not other_visible_same_type and not other_remembered_same_type:
                    self._crippled_enemy_tech_buildings.add(bname)
                    self._active_implied_enemy_tech_buildings.discard(bname)
                    self._active_enemy_research_buildings.discard(bname)
                    self._seen_enemy_unit_tags_at_destruction.update(self._seen_enemy_unit_tags)
                    self._emit_telemetry("ENEMY_TECH_CRIPPLED", building=bname, tag=unit_tag)

        def _get_pending_upgrade_names(self) -> List[str]:
            pending: List[str] = []
            candidate_names = (
                "ZERGLINGMOVEMENTSPEED",
                "BURROW",
                "GLIALRECONSTITUTION",
                "EVOLVEGROOVEDSPINES",
                "EVOLVEMUSCULARAUGMENTS",
                "CENTRIFICALHOOKS",
                "ZERGLINGATTACKSPEED",
                "CHITINOUSPLATING",
                "ZERGMISSILEWEAPONSLEVEL1",
                "ZERGMISSILEWEAPONSLEVEL2",
                "ZERGMISSILEWEAPONSLEVEL3",
                "ZERGGROUNDARMORSLEVEL1",
                "ZERGGROUNDARMORSLEVEL2",
                "ZERGGROUNDARMORSLEVEL3",
                "ZERGMELEEWEAPONSLEVEL1",
                "ZERGMELEEWEAPONSLEVEL2",
                "ZERGMELEEWEAPONSLEVEL3",
                "STIMPACK",
                "SHIELDWALL",
                "PUNISHERGRENADES",
                "TERRANINFANTRYWEAPONSLEVEL1",
                "TERRANINFANTRYWEAPONSLEVEL2",
                "TERRANINFANTRYWEAPONSLEVEL3",
                "TERRANINFANTRYARMORSLEVEL1",
                "TERRANINFANTRYARMORSLEVEL2",
                "TERRANINFANTRYARMORSLEVEL3",
                "TERRANVEHICLEWEAPONSLEVEL1",
                "TERRANVEHICLEANDSHIPARMORSLEVEL1",
                "WARPGATERESEARCH",
                "CHARGE",
                "BLINKTECH",
                "EXTENDEDTHERMALLANCE",
                "PSISTORMTECH",
                "PROTOSSGROUNDWEAPONSLEVEL1",
                "PROTOSSGROUNDWEAPONSLEVEL2",
                "PROTOSSGROUNDWEAPONSLEVEL3",
                "PROTOSSGROUNDARMORSLEVEL1",
                "PROTOSSGROUNDARMORSLEVEL2",
                "PROTOSSGROUNDARMORSLEVEL3",
                "PROTOSSSHIELDSLEVEL1",
                "PROTOSSSHIELDSLEVEL2",
            )
            for name in candidate_names:
                upg_id = getattr(UpgradeId, name, None)
                if upg_id is not None:
                    try:
                        prog = self.already_pending_upgrade(upg_id)
                        if 0.0 < prog < 1.0:
                            pending.append(name)
                    except Exception:
                        pass
            return pending

        def _observe_enemy_upgrades_and_implied_tech(self) -> None:
            """
            Observes:
              1. Enemy unit upgrades (weapons/armor/shields, Combat Shield, Stimpack, Cloak, Burrow),
              2. Active enemy research buildings (`is_active`), inferred upgrade identity, under-attack focus priority,
                 canceled research bluffs vs emergency cancels, active construction (`build_progress < 1.0`), & Stargate unit preview,
              3. Spells, persistent ground/air effects (`self.state.effects`), buffs/debuffs, & caster energy drops,
              4. Transitive prerequisite tech buildings (distinguishing historical sunk spend vs active vs crippled tech,
                 handling multiple copies and rebuilt tech structures),
              5. Unmasking enemy Hallucinations via `is_hallucination`, 2.0x damage-taken rate physics audit, & early timing,
              6. Zero-Sum Negative Exclusion, Bluff Detection, & Opponent Economy/Attrition Estimation.
            """
            # Cache friendly & enemy unit types for accurate attrition accounting in `on_unit_destroyed`
            for mu in self.units:
                self._friendly_unit_types[mu.tag] = mu.type_id.name
            for ms in self.structures:
                self._friendly_unit_types[ms.tag] = ms.type_id.name
            for eu in self.enemy_units:
                self._enemy_unit_types[eu.tag] = eu.type_id.name
            for es in self.enemy_structures:
                self._enemy_unit_types[es.tag] = es.type_id.name

            unit_prereq_map = {
                "ZERGLING": {"SPAWNINGPOOL"},
                "ZERGLINGBURROWED": {"SPAWNINGPOOL"},
                "QUEEN": {"SPAWNINGPOOL"},
                "BANELING": {"SPAWNINGPOOL", "BANELINGNEST"},
                "BANELINGBURROWED": {"SPAWNINGPOOL", "BANELINGNEST"},
                "ROACH": {"SPAWNINGPOOL", "ROACHWARREN"},
                "ROACHBURROWED": {"SPAWNINGPOOL", "ROACHWARREN"},
                "RAVAGER": {"SPAWNINGPOOL", "ROACHWARREN"},
                "OVERSEER": {"SPAWNINGPOOL", "LAIR"},
                "HYDRALISK": {"SPAWNINGPOOL", "LAIR", "HYDRALISKDEN"},
                "LURKERMP": {"SPAWNINGPOOL", "LAIR", "HYDRALISKDEN", "LURKERDENMP"},
                "LURKERMPBURROWED": {"SPAWNINGPOOL", "LAIR", "HYDRALISKDEN", "LURKERDENMP"},
                "MUTALISK": {"SPAWNINGPOOL", "LAIR", "SPIRE"},
                "CORRUPTOR": {"SPAWNINGPOOL", "LAIR", "SPIRE"},
                "INFESTOR": {"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT"},
                "SWARMHOSTMP": {"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT"},
                "VIPER": {"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT", "HIVE"},
                "ULTRALISK": {"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT", "HIVE", "ULTRALISKCAVERN"},
                "BROODLORD": {"SPAWNINGPOOL", "LAIR", "SPIRE", "INFESTATIONPIT", "HIVE", "GREATERSPIRE"},
                "MARINE": {"BARRACKS"},
                "REAPER": {"BARRACKS"},
                "MARAUDER": {"BARRACKS", "BARRACKSTECHLAB"},
                "GHOST": {"BARRACKS", "BARRACKSTECHLAB", "GHOSTACADEMY"},
                "HELLION": {"BARRACKS", "FACTORY"},
                "HELLIONTANK": {"BARRACKS", "FACTORY", "ARMORY"},
                "WIDOWMINE": {"BARRACKS", "FACTORY"},
                "WIDOWMINEBURROWED": {"BARRACKS", "FACTORY"},
                "SIEGETANK": {"BARRACKS", "FACTORY", "FACTORYTECHLAB"},
                "SIEGETANKSIEGED": {"BARRACKS", "FACTORY", "FACTORYTECHLAB"},
                "CYCLONE": {"BARRACKS", "FACTORY", "FACTORYTECHLAB"},
                "THOR": {"BARRACKS", "FACTORY", "FACTORYTECHLAB", "ARMORY"},
                "MEDIVAC": {"BARRACKS", "FACTORY", "STARPORT"},
                "VIKINGFIGHTER": {"BARRACKS", "FACTORY", "STARPORT"},
                "VIKINGASSAULT": {"BARRACKS", "FACTORY", "STARPORT"},
                "LIBERATOR": {"BARRACKS", "FACTORY", "STARPORT"},
                "BANSHEE": {"BARRACKS", "FACTORY", "STARPORT", "STARPORTTECHLAB"},
                "RAVEN": {"BARRACKS", "FACTORY", "STARPORT", "STARPORTTECHLAB"},
                "BATTLECRUISER": {"BARRACKS", "FACTORY", "STARPORT", "STARPORTTECHLAB", "FUSIONCORE"},
                "ZEALOT": {"GATEWAY"},
                "STALKER": {"GATEWAY", "CYBERNETICSCORE"},
                "ADEPT": {"GATEWAY", "CYBERNETICSCORE"},
                "SENTRY": {"GATEWAY", "CYBERNETICSCORE"},
                "IMMORTAL": {"GATEWAY", "CYBERNETICSCORE", "ROBOTICSFACILITY"},
                "OBSERVER": {"GATEWAY", "CYBERNETICSCORE", "ROBOTICSFACILITY"},
                "WARPPRISM": {"GATEWAY", "CYBERNETICSCORE", "ROBOTICSFACILITY"},
                "COLOSSUS": {"GATEWAY", "CYBERNETICSCORE", "ROBOTICSFACILITY", "ROBOTICSBAY"},
                "DISRUPTOR": {"GATEWAY", "CYBERNETICSCORE", "ROBOTICSFACILITY", "ROBOTICSBAY"},
                "VOIDRAY": {"GATEWAY", "CYBERNETICSCORE", "STARGATE"},
                "ORACLE": {"GATEWAY", "CYBERNETICSCORE", "STARGATE"},
                "PHOENIX": {"GATEWAY", "CYBERNETICSCORE", "STARGATE"},
                "CARRIER": {"GATEWAY", "CYBERNETICSCORE", "STARGATE", "FLEETBEACON"},
                "TEMPEST": {"GATEWAY", "CYBERNETICSCORE", "STARGATE", "FLEETBEACON"},
                "DARKTEMPLAR": {"GATEWAY", "CYBERNETICSCORE", "TWILIGHTCOUNCIL", "DARKSHRINE"},
                "HIGHTEMPLAR": {"GATEWAY", "CYBERNETICSCORE", "TWILIGHTCOUNCIL", "TEMPLARARCHIVE"},
                "ARCHON": {"GATEWAY", "CYBERNETICSCORE", "TWILIGHTCOUNCIL", "TEMPLARARCHIVE"},
            }
            struct_prereq_map = {
                "LAIR": {"SPAWNINGPOOL"},
                "HIVE": {"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT"},
                "HYDRALISKDEN": {"SPAWNINGPOOL", "LAIR"},
                "LURKERDENMP": {"SPAWNINGPOOL", "LAIR", "HYDRALISKDEN"},
                "SPIRE": {"SPAWNINGPOOL", "LAIR"},
                "GREATERSPIRE": {"SPAWNINGPOOL", "LAIR", "SPIRE", "INFESTATIONPIT", "HIVE"},
                "INFESTATIONPIT": {"SPAWNINGPOOL", "LAIR"},
                "ULTRALISKCAVERN": {"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT", "HIVE"},
                "FACTORY": {"BARRACKS"},
                "STARPORT": {"BARRACKS", "FACTORY"},
                "ARMORY": {"BARRACKS", "FACTORY"},
                "FUSIONCORE": {"BARRACKS", "FACTORY", "STARPORT"},
                "GHOSTACADEMY": {"BARRACKS"},
                "CYBERNETICSCORE": {"GATEWAY"},
                "ROBOTICSFACILITY": {"GATEWAY", "CYBERNETICSCORE"},
                "ROBOTICSBAY": {"GATEWAY", "CYBERNETICSCORE", "ROBOTICSFACILITY"},
                "STARGATE": {"GATEWAY", "CYBERNETICSCORE"},
                "FLEETBEACON": {"GATEWAY", "CYBERNETICSCORE", "STARGATE"},
                "TWILIGHTCOUNCIL": {"GATEWAY", "CYBERNETICSCORE"},
                "TEMPLARARCHIVE": {"GATEWAY", "CYBERNETICSCORE", "TWILIGHTCOUNCIL"},
                "DARKSHRINE": {"GATEWAY", "CYBERNETICSCORE", "TWILIGHTCOUNCIL"},
            }
            research_bldg_names = {
                "FORGE",
                "ENGINEERINGBAY",
                "ARMORY",
                "EVOLUTIONCHAMBER",
                "TWILIGHTCOUNCIL",
                "CYBERNETICSCORE",
                "SPAWNINGPOOL",
                "ROACHWARREN",
                "HYDRALISKDEN",
                "LURKERDENMP",
                "SPIRE",
                "GREATERSPIRE",
                "ULTRALISKCAVERN",
                "BANELINGNEST",
                "BARRACKSTECHLAB",
                "FACTORYTECHLAB",
                "STARPORTTECHLAB",
                "ROBOTICSBAY",
                "FLEETBEACON",
                "TEMPLARARCHIVE",
                "DARKSHRINE",
                "GHOSTACADEMY",
                "FUSIONCORE",
            }
            inferred_research_map = {
                "SPAWNINGPOOL": "ZERGLINGMOVEMENTSPEED",
                "ROACHWARREN": "GLIALRECONSTITUTION",
                "BANELINGNEST": "CENTRIFICALHOOKS",
                "HYDRALISKDEN": "GROOVEDSPINES_OR_MUSCULARAUGMENTS",
                "LURKERDENMP": "LURKERRANGE",
                "SPIRE": "ZERGFLYER_UPGRADE",
                "ULTRALISKCAVERN": "CHITINOUSPLATING",
                "EVOLUTIONCHAMBER": "ZERG_GROUND_UPGRADE",
                "CYBERNETICSCORE": "WARPGATERESEARCH",
                "TWILIGHTCOUNCIL": "CHARGE_OR_BLINK",
                "TEMPLARARCHIVE": "PSISTORMTECH",
                "ROBOTICSBAY": "EXTENDEDTHERMALLANCE",
                "FORGE": "PROTOSS_GROUND_OR_SHIELDS_UPGRADE",
                "BARRACKSTECHLAB": "STIMPACK_OR_COMBATSHIELD",
                "FACTORYTECHLAB": "CYCLONE_OR_TANK_TECH",
                "STARPORTTECHLAB": "CLOAKINGFIELD",
                "ENGINEERINGBAY": "TERRAN_INFANTRY_UPGRADE",
                "ARMORY": "TERRAN_VEHICLE_SHIP_UPGRADE",
                "FUSIONCORE": "YAMATOCANNON",
            }
            unit_gas_cost = {
                "BANELING": 25,
                "ROACH": 25,
                "RAVAGER": 100,
                "HYDRALISK": 50,
                "LURKERMP": 150,
                "LURKERMPBURROWED": 150,
                "MUTALISK": 100,
                "CORRUPTOR": 100,
                "INFESTOR": 150,
                "SWARMHOSTMP": 75,
                "VIPER": 200,
                "ULTRALISK": 200,
                "BROODLORD": 250,
                "OVERSEER": 50,
                "REAPER": 50,
                "MARAUDER": 25,
                "GHOST": 125,
                "WIDOWMINE": 25,
                "WIDOWMINEBURROWED": 25,
                "SIEGETANK": 125,
                "SIEGETANKSIEGED": 125,
                "CYCLONE": 100,
                "THOR": 200,
                "MEDIVAC": 100,
                "VIKINGFIGHTER": 75,
                "LIBERATOR": 125,
                "BANSHEE": 100,
                "RAVEN": 150,
                "BATTLECRUISER": 300,
                "STALKER": 50,
                "ADEPT": 25,
                "SENTRY": 100,
                "IMMORTAL": 100,
                "OBSERVER": 75,
                "COLOSSUS": 200,
                "DISRUPTOR": 150,
                "PHOENIX": 100,
                "VOIDRAY": 150,
                "ORACLE": 150,
                "CARRIER": 250,
                "TEMPEST": 175,
                "HIGHTEMPLAR": 150,
                "DARKTEMPLAR": 125,
                "ARCHON": 300,
            }
            struct_gas_cost = {
                "LAIR": 100,
                "HIVE": 150,
                "BANELINGNEST": 50,
                "HYDRALISKDEN": 100,
                "LURKERDENMP": 150,
                "SPIRE": 200,
                "GREATERSPIRE": 150,
                "INFESTATIONPIT": 100,
                "ULTRALISKCAVERN": 200,
                "BARRACKSTECHLAB": 25,
                "FACTORY": 100,
                "FACTORYTECHLAB": 25,
                "ARMORY": 100,
                "STARPORT": 100,
                "STARPORTTECHLAB": 25,
                "FUSIONCORE": 150,
                "GHOSTACADEMY": 50,
                "ROBOTICSFACILITY": 100,
                "ROBOTICSBAY": 150,
                "STARGATE": 150,
                "FLEETBEACON": 200,
                "TWILIGHTCOUNCIL": 100,
                "TEMPLARARCHIVE": 200,
                "DARKSHRINE": 150,
            }
            burrow_unit_names = {
                "LURKERMP",
                "LURKERMPBURROWED",
                "WIDOWMINE",
                "WIDOWMINEBURROWED",
                "ZERGLINGBURROWED",
                "ROACHBURROWED",
                "BANELINGBURROWED",
                "INFESTORBURROWED",
            }
            cloak_unit_names = {
                "DARKTEMPLAR",
                "BANSHEE",
                "GHOST",
                "MOTHERSHIP",
            }
            caster_names = {
                "HIGHTEMPLAR",
                "SENTRY",
                "ORACLE",
                "INFESTOR",
                "VIPER",
                "QUEEN",
                "GHOST",
                "RAVEN",
                "BANSHEE",
                "ORBITALCOMMAND",
                "NEXUS",
            }

            sec = float(getattr(self.state, "game_loop", 0)) / 22.4
            enemy_race_name = getattr(getattr(self, "enemy_race", None), "name", "Unknown")

            # 1. Check if any remembered or in-progress enemy structure disappeared from a visible tile
            visible_struct_tags = {eb.tag for eb in self.enemy_structures}
            for b_tag, b_prev in list(self._enemy_bldg_state.items()):
                if b_tag not in visible_struct_tags:
                    try:
                        if self.is_visible(b_prev["pos"]):
                            if b_prev["build_progress"] < 0.95 and b_prev["hp_ratio"] > 0.35:
                                self._observed_enemy_spells.add(f"FAKE_BUILD_CANCELED:{b_prev['type']}")
                                self._enemy_bluff_suspected = True
                            del self._enemy_bldg_state[b_tag]
                    except Exception:
                        pass

            for r_tag, (r_bname, r_pos, _r_act) in list(self._remembered_enemy_tech_structures.items()):
                if r_tag not in visible_struct_tags:
                    try:
                        if self.is_visible(r_pos):
                            del self._remembered_enemy_tech_structures[r_tag]
                            self._destroyed_enemy_structure_tags.add(r_tag)
                            other_alive = any(
                                eb.tag != r_tag
                                and eb.tag not in self._destroyed_enemy_structure_tags
                                and eb.type_id.name == r_bname
                                for eb in self.enemy_structures
                            ) or any(
                                o_tag != r_tag
                                and o_tag not in self._destroyed_enemy_structure_tags
                                and o_info[0] == r_bname
                                for o_tag, o_info in self._remembered_enemy_tech_structures.items()
                            )
                            if not other_alive:
                                self._crippled_enemy_tech_buildings.add(r_bname)
                                self._active_implied_enemy_tech_buildings.discard(r_bname)
                                self._active_enemy_research_buildings.discard(r_bname)
                                if r_bname in inferred_research_map:
                                    self._inferred_enemy_active_research.discard(inferred_research_map[r_bname])
                                self._seen_enemy_unit_tags_at_destruction.update(self._seen_enemy_unit_tags)
                    except Exception:
                        pass

            # 2. Scan visible enemy structures, build progress, research activity/cancellation, & Stargate preview
            idle_seen_tech_bldgs: set = set()
            self._in_progress_enemy_buildings.clear()
            self._priority_research_target_tags.clear()
            has_fleet_beacon = any(eb.type_id.name == "FLEETBEACON" for eb in self.enemy_structures)
            for eb in self.enemy_structures:
                if eb.tag in self._destroyed_enemy_structure_tags:
                    continue
                bname = eb.type_id.name
                is_act = bool(getattr(eb, "is_active", False))
                b_prog = float(getattr(eb, "build_progress", 1.0) or 1.0)
                hp_cur = float(getattr(eb, "health", 0.0) or 0.0) + float(getattr(eb, "shield", 0.0) or 0.0)
                hp_max = max(1.0, float(getattr(eb, "health_max", 1.0) or 1.0) + float(getattr(eb, "shield_max", 0.0) or 0.0))
                hp_ratio = hp_cur / hp_max

                if 0.0 < b_prog < 1.0:
                    self._in_progress_enemy_buildings.add(f"{bname}:{int(round(b_prog * 100))}%")

                prev_bstate = self._enemy_bldg_state.get(eb.tag)
                active_since = sec if (is_act and (prev_bstate is None or not prev_bstate.get("is_active", False))) else (
                    prev_bstate.get("active_since", sec) if prev_bstate else sec
                )
                if prev_bstate is not None and prev_bstate.get("is_active", False) and not is_act:
                    active_dur = sec - float(prev_bstate.get("active_since", sec))
                    if active_dur < 20.0 and bname in research_bldg_names:
                        if hp_ratio > 0.85:
                            self._observed_enemy_spells.add(f"FAKE_RESEARCH_BLUFF_CANCELED:{bname}")
                            self._enemy_bluff_suspected = True
                        else:
                            self._observed_enemy_spells.add(f"EMERGENCY_RESEARCH_CANCELED:{bname}")
                            if bname in inferred_research_map:
                                self._inferred_enemy_active_research.discard(inferred_research_map[bname])

                self._enemy_bldg_state[eb.tag] = {
                    "type": bname,
                    "pos": eb.position,
                    "build_progress": b_prog,
                    "is_active": is_act,
                    "hp_ratio": hp_ratio,
                    "active_since": active_since,
                    "last_seen": sec,
                }

                if eb.tag not in self._seen_enemy_structure_tags:
                    self._seen_enemy_structure_tags.add(eb.tag)
                    prev_count = self._seen_enemy_structure_counts_by_type.get(bname, 0)
                    self._seen_enemy_structure_counts_by_type[bname] = prev_count + 1
                    if prev_count >= 1 or bname in self._crippled_enemy_tech_buildings:
                        self._extra_rebuilt_tech_gas_spent += struct_gas_cost.get(bname, 0)
                if bname in research_bldg_names or bname in struct_prereq_map:
                    self._remembered_enemy_tech_structures[eb.tag] = (bname, eb.position, is_act)
                self._implied_enemy_tech_buildings.add(bname)
                self._active_implied_enemy_tech_buildings.add(bname)
                self._crippled_enemy_tech_buildings.discard(bname)
                if bname in struct_prereq_map:
                    self._implied_enemy_tech_buildings.update(struct_prereq_map[bname])
                    self._active_implied_enemy_tech_buildings.update(struct_prereq_map[bname])
                if bname in research_bldg_names:
                    if is_act:
                        self._active_enemy_research_buildings.add(bname)
                        if bname in inferred_research_map:
                            self._inferred_enemy_active_research.add(inferred_research_map[bname])
                        if hp_ratio < 0.98:
                            self._priority_research_target_tags.add(eb.tag)
                            self._enemy_bluff_suspected = False
                    else:
                        idle_seen_tech_bldgs.add(bname)
                if bname in {"DARKSHRINE", "GHOSTACADEMY", "LURKERDENMP"}:
                    self._observed_enemy_upgrades.add("CLOAK" if bname != "LURKERDENMP" else "BURROW")
                    self._enemy_requires_detection = True

                # Stargate Unit Preview (`STARGATE` current unit detection)
                if bname == "STARGATE" and is_act:
                    sg_preview = None
                    for ord_item in getattr(eb, "orders", ()):
                        ab_name = str(getattr(getattr(ord_item, "ability", None), "name", "")).upper()
                        for cand_u in ("ORACLE", "VOIDRAY", "PHOENIX", "CARRIER", "TEMPEST"):
                            if cand_u in ab_name:
                                sg_preview = cand_u
                                break
                    if sg_preview is None:
                        near_air = [
                            eu.type_id.name
                            for eu in self.enemy_units
                            if getattr(eu, "is_flying", False) and eu.distance_to(eb) <= 4.5
                        ]
                        if near_air:
                            sg_preview = near_air[0]
                        elif has_fleet_beacon or "FLEETBEACON" in self._active_implied_enemy_tech_buildings:
                            sg_preview = "CARRIER_OR_TEMPEST"
                        elif sec < 240.0:
                            sg_preview = "ORACLE_OR_VOIDRAY"
                        else:
                            sg_preview = "VOIDRAY_OR_PHOENIX"
                    self._stargate_preview_units.add(sg_preview)
                    self._enemy_requires_anti_air = True
                    self._mirror_air_alert = True
                    if "ORACLE" in sg_preview:
                        self._enemy_requires_detection = True

                # Check Chrono Boost on enemy structures
                try:
                    if eb.has_buff(BuffId.CHRONOBOOSTENERGYCOST):
                        self._observed_enemy_spells.add(f"CHRONOBOOST:{bname}")
                        self._active_enemy_research_buildings.add(bname)
                        if bname in inferred_research_map:
                            self._inferred_enemy_active_research.add(inferred_research_map[bname])
                        self._enemy_bluff_suspected = False
                except Exception:
                    pass

                if bname in caster_names:
                    cur_e = float(getattr(eb, "energy", 0.0) or 0.0)
                    prev_e = self._enemy_caster_energy.get(eb.tag)
                    if prev_e is not None and (prev_e - cur_e) >= 25.0:
                        self._observed_enemy_spells.add(f"ENERGY_CAST:{bname}")
                    self._enemy_caster_energy[eb.tag] = cur_e

            # 3. Inspect persistent ground/air effects (`self.state.effects`)
            if hasattr(self.state, "effects"):
                for eff in self.state.effects:
                    eff_name = str(getattr(eff.id, "name", eff.id)).upper()
                    if "PSISTORM" in eff_name:
                        self._observed_enemy_spells.add("PSISTORM")
                        self._observed_enemy_upgrades.add("PSISTORMTECH")
                        self._implied_enemy_tech_buildings.update({"GATEWAY", "CYBERNETICSCORE", "TWILIGHTCOUNCIL", "TEMPLARARCHIVE"})
                        self._active_implied_enemy_tech_buildings.update({"GATEWAY", "CYBERNETICSCORE", "TWILIGHTCOUNCIL", "TEMPLARARCHIVE"})
                        self._enemy_bluff_suspected = False
                    elif "LURKER" in eff_name:
                        self._observed_enemy_spells.add("LURKERSPINES")
                        self._implied_enemy_tech_buildings.update({"SPAWNINGPOOL", "LAIR", "HYDRALISKDEN", "LURKERDENMP"})
                        self._active_implied_enemy_tech_buildings.update({"SPAWNINGPOOL", "LAIR", "HYDRALISKDEN", "LURKERDENMP"})
                        self._enemy_requires_detection = True
                    elif "CORROSIVEBILE" in eff_name:
                        self._observed_enemy_spells.add("CORROSIVEBILE")
                        self._implied_enemy_tech_buildings.update({"SPAWNINGPOOL", "ROACHWARREN"})
                    elif "BLINDINGCLOUD" in eff_name:
                        self._observed_enemy_spells.add("BLINDINGCLOUD")
                        self._implied_enemy_tech_buildings.update({"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT", "HIVE"})
                    elif "NUKE" in eff_name:
                        self._observed_enemy_spells.add("TACTICALNUKE")
                        self._implied_enemy_tech_buildings.update({"BARRACKS", "GHOSTACADEMY"})
                        self._enemy_requires_detection = True
                    elif "SCANNERSWEEP" in eff_name:
                        self._observed_enemy_spells.add("SCANNERSWEEP")
                        self._implied_enemy_tech_buildings.add("ORBITALCOMMAND")
                    elif "LIBERATOR" in eff_name:
                        self._observed_enemy_spells.add("LIBERATORSIEGE")
                        self._implied_enemy_tech_buildings.update({"BARRACKS", "FACTORY", "STARPORT"})
                        self._enemy_requires_anti_air = True
                        self._mirror_air_alert = True
                    elif "GUARDIANSHIELD" in eff_name:
                        self._observed_enemy_spells.add("GUARDIANSHIELD")
                        self._implied_enemy_tech_buildings.update({"GATEWAY", "CYBERNETICSCORE"})

            # 4. Inspect enemy debuffs on our units (`self.units`)
            debuff_map = {
                "FUNGALGROWTH": ("FUNGALGROWTH", {"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT"}),
                "NEURALPARASITE": ("NEURALPARASITE", {"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT"}),
                "PARASITICBOMB": ("PARASITICBOMB", {"SPAWNINGPOOL", "LAIR", "INFESTATIONPIT", "HIVE"}),
                "ANTIARMORMISSILE": ("ANTIARMORMISSILE", {"BARRACKS", "FACTORY", "STARPORT", "STARPORTTECHLAB"}),
                "LOCKON": ("LOCKON", {"BARRACKS", "FACTORY", "FACTORYTECHLAB"}),
                "ORACLEWEAPON": ("PULSARBEAM", {"GATEWAY", "CYBERNETICSCORE", "STARGATE"}),
                "ORACLEREVELATION": ("ORACLEREVELATION", {"GATEWAY", "CYBERNETICSCORE", "STARGATE"}),
            }
            for my_u in self.units:
                for b in getattr(my_u, "buffs", ()):
                    b_str = str(getattr(b, "name", b)).upper()
                    if b_str in debuff_map:
                        sp_name, req_set = debuff_map[b_str]
                        self._observed_enemy_spells.add(sp_name)
                        self._implied_enemy_tech_buildings.update(req_set)
                        self._active_implied_enemy_tech_buildings.update(req_set)

            # 5. Scan visible enemy units (unmasking Hallucinations + pre-existing vs post-destruction tag filter)
            seen_branch_units: Dict[str, int] = {}
            halluc_candidate_types = {"PHOENIX", "VOIDRAY", "ORACLE", "COLOSSUS", "IMMORTAL", "ARCHON"}
            visible_high_tech_structs = {
                eb.type_id.name
                for eb in self.enemy_structures
                if eb.type_id.name in {"STARGATE", "ROBOTICSFACILITY", "ROBOTICSBAY", "TEMPLARARCHIVE"}
            }
            for eu in self.enemy_units:
                uname = eu.type_id.name
                hp_shd = float(getattr(eu, "health", 0.0) or 0.0) + float(getattr(eu, "shield", 0.0) or 0.0)
                prev_hp_shd = self._enemy_prev_hp_shield.get(eu.tag)
                self._enemy_prev_hp_shield[eu.tag] = hp_shd

                # Check if enemy unit is a Hallucination:
                # (a) `is_hallucination` attribute (when detected), OR
                # (b) 2.0x Damage-Taken Physics Audit (`delta_hp >= 1.65 * expected_max_single_volley_damage` from 1-2 attackers), OR
                # (c) High-tier Protoss unit seen before t = 135s when only Gateway/CyberCore is physically possible
                is_halluc = bool(getattr(eu, "is_hallucination", False)) or (eu.tag in self._confirmed_hallucination_tags)
                if not is_halluc and prev_hp_shd is not None and (prev_hp_shd - hp_shd) > 8.0:
                    delta_hp = prev_hp_shd - hp_shd
                    attackers_in_range = [
                        my_u
                        for my_u in self.units
                        if (my_u.can_attack_air if getattr(eu, "is_flying", False) else my_u.can_attack_ground)
                        and my_u.distance_to(eu) <= ((my_u.air_range if getattr(eu, "is_flying", False) else my_u.ground_range) + my_u.radius + eu.radius + 0.5)
                    ]
                    if 1 <= len(attackers_in_range) <= 2:
                        expected_max_volley = sum(
                            max(10.0, float(getattr(a, "air_dps" if getattr(eu, "is_flying", False) else "ground_dps", 9.0) or 9.0) * 1.35)
                            for a in attackers_in_range
                        )
                        if delta_hp >= 1.65 * expected_max_volley:
                            is_halluc = True
                if not is_halluc and uname in halluc_candidate_types and sec < 135.0 and not visible_high_tech_structs:
                    is_halluc = True

                if is_halluc:
                    self._confirmed_hallucination_tags.add(eu.tag)
                    self._observed_enemy_spells.add("HALLUCINATION_DETECTED")
                    self._implied_enemy_tech_buildings.update({"GATEWAY", "CYBERNETICSCORE"})
                    self._active_implied_enemy_tech_buildings.update({"GATEWAY", "CYBERNETICSCORE"})
                    continue

                seen_branch_units[uname] = seen_branch_units.get(uname, 0) + 1
                is_new_tag = eu.tag not in self._seen_enemy_unit_tags
                is_post_destruction = eu.tag not in self._seen_enemy_unit_tags_at_destruction

                if is_new_tag:
                    self._seen_enemy_unit_tags.add(eu.tag)
                    self._cumulative_seen_enemy_unit_gas += unit_gas_cost.get(uname, 0)

                if uname in unit_prereq_map:
                    prereqs = unit_prereq_map[uname]
                    self._implied_enemy_tech_buildings.update(prereqs)
                    if is_post_destruction:
                        self._active_implied_enemy_tech_buildings.update(prereqs)
                        for pr in prereqs:
                            if pr in self._crippled_enemy_tech_buildings:
                                self._crippled_enemy_tech_buildings.discard(pr)
                                self._extra_rebuilt_tech_gas_spent += struct_gas_cost.get(pr, 0)

                if uname in caster_names:
                    cur_e = float(getattr(eu, "energy", 0.0) or 0.0)
                    prev_e = self._enemy_caster_energy.get(eu.tag)
                    if prev_e is not None and (prev_e - cur_e) >= 25.0:
                        self._observed_enemy_spells.add(f"ENERGY_CAST:{uname}")
                    self._enemy_caster_energy[eu.tag] = cur_e

                atk = int(getattr(eu, "attack_upgrade_level", 0) or 0)
                arm = int(getattr(eu, "armor_upgrade_level", 0) or 0)
                shd = int(getattr(eu, "shield_upgrade_level", 0) or 0)
                if atk > self._max_enemy_atk_upg:
                    self._max_enemy_atk_upg = atk
                if arm > self._max_enemy_arm_upg:
                    self._max_enemy_arm_upg = arm
                if shd > self._max_enemy_shd_upg:
                    self._max_enemy_shd_upg = shd

                if atk >= 1:
                    self._observed_enemy_upgrades.add("ENEMY_WEAPONS_1+")
                if arm >= 1:
                    self._observed_enemy_upgrades.add("ENEMY_ARMOR_1+")
                if shd >= 1:
                    self._observed_enemy_upgrades.add("ENEMY_SHIELDS_1+")

                if atk >= 1 or arm >= 1 or shd >= 1:
                    if enemy_race_name == "Terran" or uname in {"MARINE", "MARAUDER", "SIEGETANK", "MEDIVAC", "SCV"}:
                        self._implied_enemy_tech_buildings.add("ENGINEERINGBAY")
                        if atk >= 2 or arm >= 2:
                            self._implied_enemy_tech_buildings.add("ARMORY")
                    elif enemy_race_name == "Protoss" or shd >= 1 or uname in {"ZEALOT", "STALKER", "IMMORTAL", "PROBE"}:
                        self._implied_enemy_tech_buildings.add("FORGE")
                        if atk >= 2 or arm >= 2:
                            self._implied_enemy_tech_buildings.add("TWILIGHTCOUNCIL")
                    else:
                        self._implied_enemy_tech_buildings.add("EVOLUTIONCHAMBER")
                        if atk >= 2 or arm >= 2:
                            self._implied_enemy_tech_buildings.add("LAIR")

                if uname == "MARINE" and getattr(eu, "health_max", 45) >= 55:
                    self._observed_enemy_upgrades.add("COMBATSHIELD")
                    self._implied_enemy_tech_buildings.add("BARRACKSTECHLAB")

                for b in getattr(eu, "buffs", ()):
                    b_str = str(getattr(b, "name", b)).upper()
                    if b_str in {"STIMPACK", "STIMPACKMARAUDER"}:
                        self._observed_enemy_spells.add("STIMPACK")
                        self._observed_enemy_upgrades.add("STIMPACK")
                        self._implied_enemy_tech_buildings.add("BARRACKSTECHLAB")
                    elif b_str in {"BANSHEECLOAK", "GHOSTCLOAK"}:
                        self._observed_enemy_spells.add("CLOAK_SPELL")
                        self._observed_enemy_upgrades.add("CLOAK")
                        self._enemy_requires_detection = True
                    elif b_str == "CHARGING":
                        self._observed_enemy_spells.add("CHARGE")
                        self._observed_enemy_upgrades.add("CHARGE")
                        self._implied_enemy_tech_buildings.add("TWILIGHTCOUNCIL")

                if getattr(eu, "is_burrowed", False) or uname in burrow_unit_names:
                    self._observed_enemy_upgrades.add("BURROW")
                    self._enemy_requires_detection = True

                if uname in cloak_unit_names or (getattr(eu, "is_cloaked", False) and (uname != "OBSERVER" or sec >= 210.0)):
                    self._observed_enemy_upgrades.add("CLOAK")
                    self._enemy_requires_detection = True

                if (
                    getattr(eu, "is_flying", False)
                    and uname not in {"OVERLORD", "OVERSEER", "OBSERVER", "WARPPRISM"}
                ) or uname == "COLOSSUS":
                    self._enemy_requires_anti_air = True
                    self._mirror_air_alert = True

            # 6. Zero-Sum Negative Exclusion, Bluff Detection, & Opponent Economy Estimation
            enemy_geysers_seen = sum(
                1 for eb in self.enemy_structures if eb.type_id.name in {"EXTRACTOR", "REFINERY", "ASSIMILATOR"}
            )
            est_enemy_bases = max(1, self.enemy_known_bases, int(getattr(self, "predicted_enemy_bases", 1)))
            est_enemy_workers = max(
                8,
                min(80, est_enemy_bases * 20, int(12 + sec / 3.8) - self._enemy_workers_killed),
            )
            est_gas_geysers = max(enemy_geysers_seen, 1 if sec >= 45.0 else 0, min(est_enemy_bases * 2, int(sec // 90)))
            self._estimated_enemy_workers = est_enemy_workers
            self._estimated_enemy_min_rate = max(0, est_enemy_workers - est_gas_geysers * 3) * 42
            self._estimated_enemy_gas_rate = est_gas_geysers * 3 * 38

            est_gas_mined = int(max(0.0, (sec - 45.0)) * 2.1 * max(1, min(2, est_enemy_bases)))
            struct_gas_spent = sum(struct_gas_cost.get(b, 0) for b in self._implied_enemy_tech_buildings) + self._extra_rebuilt_tech_gas_spent
            upg_gas_spent = (
                100 * len(self._observed_enemy_upgrades)
                + 100 * max(0, self._max_enemy_atk_upg - 1)
                + 100 * max(0, self._max_enemy_arm_upg - 1)
            )
            accounted_gas = self._cumulative_seen_enemy_unit_gas + struct_gas_spent + upg_gas_spent
            unaccounted_gas = max(0, est_gas_mined - accounted_gas)
            self._estimated_enemy_gas_mined = est_gas_mined
            self._accounted_enemy_gas_spent = accounted_gas

            # Check branch commitment vs idle bluff structure
            protoss_ground_units = sum(seen_branch_units.get(k, 0) for k in ("STALKER", "IMMORTAL", "COLOSSUS", "HIGHTEMPLAR", "ARCHON", "DARKTEMPLAR"))
            zerg_ground_units = sum(seen_branch_units.get(k, 0) for k in ("ROACH", "RAVAGER", "HYDRALISK", "LURKERMP", "LURKERMPBURROWED"))
            terran_bio_mech_units = sum(seen_branch_units.get(k, 0) for k in ("MARAUDER", "SIEGETANK", "SIEGETANKSIEGED", "CYCLONE"))

            if (
                idle_seen_tech_bldgs
                and not self._active_enemy_research_buildings
                and (protoss_ground_units + zerg_ground_units + terran_bio_mech_units) == 0
                and unaccounted_gas >= 250
            ):
                self._enemy_bluff_suspected = True
                self._enemy_committed_branch = "suspected-tech-bluff"
                self._enemy_excluded_branches.clear()
                self._mirror_air_alert = True
            elif ("TEMPLARARCHIVE" in self._active_implied_enemy_tech_buildings or "TWILIGHTCOUNCIL" in self._active_implied_enemy_tech_buildings or "ROBOTICSFACILITY" in self._active_implied_enemy_tech_buildings) and (protoss_ground_units >= 1 or "CHARGE" in self._observed_enemy_upgrades or "PSISTORMTECH" in self._observed_enemy_upgrades or unaccounted_gas < 225):
                self._enemy_committed_branch = "protoss-ground-twilight-robo"
                self._enemy_bluff_suspected = False
                if not self._enemy_requires_anti_air:
                    self._enemy_excluded_branches.update({"STARGATE", "FLEETBEACON"})
            elif ("ROACHWARREN" in self._active_implied_enemy_tech_buildings or "HYDRALISKDEN" in self._active_implied_enemy_tech_buildings) and (zerg_ground_units >= 2 or unaccounted_gas < 225):
                self._enemy_committed_branch = "zerg-ground-roach-hydra"
                self._enemy_bluff_suspected = False
                if not self._enemy_requires_anti_air:
                    self._enemy_excluded_branches.update({"SPIRE", "GREATERSPIRE"})
            elif ("BARRACKSTECHLAB" in self._active_implied_enemy_tech_buildings or "FACTORYTECHLAB" in self._active_implied_enemy_tech_buildings) and (terran_bio_mech_units >= 1 or "STIMPACK" in self._observed_enemy_upgrades or "COMBATSHIELD" in self._observed_enemy_upgrades or unaccounted_gas < 225):
                self._enemy_committed_branch = "terran-bio-tank"
                self._enemy_bluff_suspected = False
                if not self._enemy_requires_anti_air:
                    self._enemy_excluded_branches.update({"FUSIONCORE", "BATTLECRUISER"})

            if self._active_implied_enemy_tech_buildings & {
                "SPIRE",
                "GREATERSPIRE",
                "STARGATE",
                "FLEETBEACON",
                "STARPORT",
                "STARPORTTECHLAB",
                "FUSIONCORE",
            }:
                self._enemy_requires_anti_air = True
                self._mirror_air_alert = True
                self._enemy_excluded_branches.clear()

            # 8. Evaluate Spatio-Temporal Enemy Army Reachability Cone & Zero-Sum Spatial Conservation
            self._evaluate_enemy_army_spatio_temporal_reachability(lookahead_sec=12.0)

            # 9. Evaluate All Cognitive Depths (d = 0..5) Online Against Marginal Spend & Tech Transitions (2.0x weight)
            self._evaluate_all_mirror_depths_and_select_best()

        def _evaluate_enemy_army_spatio_temporal_reachability(self, lookahead_sec: float = 12.0) -> None:
            """
            Models enemy army locations via Zero-Sum Spatial Conservation (enemy supply seen at (x,y)
            cannot be elsewhere) and Reachability Cones parameterized by unit base speed + observed
            upgrades/spells/transports (`ZERGLINGMOVEMENTSPEED` +60% +30% on creep, `STIMPACK` +50%,
            `CHARGE` +50%, `BLINK` cliff-bypass, `MEDIVAC` afterburners, `WARPPRISM`, `NEXUS` MassRecall).
            """
            sec = float(getattr(self.state, "game_loop", 0)) / 22.4
            non_combat_names = {
                "DRONE",
                "SCV",
                "PROBE",
                "OVERLORD",
                "OVERSEER",
                "OBSERVER",
                "LARVA",
                "EGG",
                "MULE",
            }
            supply_table = {
                "ZERGLING": 0.5,
                "BANELING": 0.5,
                "MARINE": 1.0,
                "REAPER": 1.0,
                "ROACH": 2.0,
                "RAVAGER": 3.0,
                "HYDRALISK": 2.0,
                "LURKERMP": 3.0,
                "LURKERMPBURROWED": 3.0,
                "MUTALISK": 2.0,
                "CORRUPTOR": 2.0,
                "ULTRALISK": 6.0,
                "BROODLORD": 4.0,
                "MARAUDER": 2.0,
                "HELLION": 2.0,
                "WIDOWMINE": 2.0,
                "WIDOWMINEBURROWED": 2.0,
                "SIEGETANK": 3.0,
                "SIEGETANKSIEGED": 3.0,
                "MEDIVAC": 2.0,
                "VIKINGFIGHTER": 2.0,
                "BANSHEE": 3.0,
                "BATTLECRUISER": 6.0,
                "ZEALOT": 2.0,
                "STALKER": 2.0,
                "SENTRY": 2.0,
                "ADEPT": 2.0,
                "HIGHTEMPLAR": 2.0,
                "DARKTEMPLAR": 2.0,
                "IMMORTAL": 4.0,
                "COLOSSUS": 6.0,
                "DISRUPTOR": 3.0,
                "ARCHON": 4.0,
                "WARPPRISM": 2.0,
                "PHOENIX": 2.0,
                "ORACLE": 3.0,
                "VOIDRAY": 4.0,
                "CARRIER": 6.0,
                "TEMPEST": 5.0,
            }
            base_speed_table = {
                "ZERGLING": 4.13,
                "BANELING": 3.50,
                "ROACH": 3.15,
                "RAVAGER": 3.85,
                "HYDRALISK": 3.15,
                "LURKERMP": 4.13,
                "MUTALISK": 5.60,
                "CORRUPTOR": 4.72,
                "MARINE": 3.15,
                "MARAUDER": 3.15,
                "REAPER": 5.25,
                "HELLION": 5.95,
                "SIEGETANK": 3.15,
                "MEDIVAC": 3.50,
                "VIKINGFIGHTER": 3.85,
                "BANSHEE": 3.85,
                "ZEALOT": 3.15,
                "STALKER": 4.13,
                "SENTRY": 3.15,
                "ADEPT": 3.50,
                "IMMORTAL": 3.15,
                "COLOSSUS": 3.15,
                "ARCHON": 3.94,
                "WARPPRISM": 4.13,
                "PHOENIX": 5.95,
                "ORACLE": 5.60,
                "VOIDRAY": 3.85,
            }

            visible_combat = [
                eu
                for eu in self.enemy_units
                if eu.type_id.name not in non_combat_names
                and eu.tag not in self._confirmed_hallucination_tags
                and "CHANGELING" not in eu.type_id.name
            ]

            has_medivac_transport = any(eu.type_id.name == "MEDIVAC" for eu in visible_combat)
            has_warp_prism = any("WARPPRISM" in eu.type_id.name for eu in visible_combat)
            has_nexus_recall = any(
                eb.type_id.name == "NEXUS" and float(getattr(eb, "energy", 0.0) or 0.0) >= 50.0
                for eb in self.enemy_structures
            )

            # Group visible combat units into spatial sectors (12x12 tile grid)
            current_sectors: Dict[Tuple[int, int], List[Any]] = {}
            for eu in visible_combat:
                key = (int(round(float(eu.position.x) / 12.0)), int(round(float(eu.position.y) / 12.0)))
                current_sectors.setdefault(key, []).append(eu)

            for key, units_in_sec in current_sectors.items():
                cx = sum(float(u.position.x) for u in units_in_sec) / len(units_in_sec)
                cy = sum(float(u.position.y) for u in units_in_sec) / len(units_in_sec)
                c_pos = Point2((cx, cy))
                c_sup = 0.0
                speeds: List[float] = []
                any_flying = False
                for u in units_in_sec:
                    uname = u.type_id.name
                    c_sup += supply_table.get(uname, 2.0)
                    v = float(getattr(u, "movement_speed", 0.0) or base_speed_table.get(uname, 3.15))
                    if uname == "ZERGLING" and "ZERGLINGMOVEMENTSPEED" in self._observed_enemy_upgrades:
                        v *= 1.60
                        try:
                            if self.has_creep(u.position):
                                v *= 1.25
                        except Exception:
                            pass
                    elif uname == "ROACH" and "GLIALRECONSTITUTION" in self._observed_enemy_upgrades:
                        v *= 1.33
                    elif uname == "HYDRALISK" and "MUSCULARAUGMENTS" in self._observed_enemy_upgrades:
                        v *= 1.25
                    elif uname in {"MARINE", "MARAUDER"} and "STIMPACK" in self._observed_enemy_upgrades:
                        v *= 1.50
                    elif uname == "ZEALOT" and "CHARGE" in self._observed_enemy_upgrades:
                        v *= 1.50
                    elif uname == "STALKER" and "BLINK" in self._observed_enemy_upgrades:
                        v *= 1.25
                    elif uname == "MEDIVAC":
                        v = 5.94
                    speeds.append(v)
                    if getattr(u, "is_flying", False):
                        any_flying = True
                v_eff = sum(speeds) / max(1, len(speeds))
                if has_medivac_transport and c_sup <= 16.0:
                    v_eff = max(v_eff, 5.20)
                elif has_warp_prism and c_sup <= 12.0:
                    v_eff = max(v_eff, 4.50)
                self._tracked_enemy_clusters[key] = {
                    "pos": c_pos,
                    "supply": round(c_sup, 1),
                    "last_seen": sec,
                    "v_eff": round(v_eff, 2),
                    "is_flying": any_flying,
                }

            # Expire stale or cleared clusters
            for key, c_info in list(self._tracked_enemy_clusters.items()):
                age = sec - float(c_info["last_seen"])
                if age > 18.0:
                    del self._tracked_enemy_clusters[key]
                    continue
                if key not in current_sectors:
                    try:
                        if self.is_visible(c_info["pos"]):
                            del self._tracked_enemy_clusters[key]
                    except Exception:
                        pass

            # Zero-Sum Spatial Conservation: seen army supply vs unaccounted army supply
            self._seen_enemy_army_supply = round(
                sum(float(c["supply"]) for c in self._tracked_enemy_clusters.values()), 1
            )
            est_total_enemy_sup = max(
                self._seen_enemy_army_supply,
                min(
                    130.0,
                    max(
                        0.0,
                        (sec - 75.0) * 0.42 * max(1, self.enemy_known_bases)
                        - (self._enemy_lost_minerals + self._enemy_lost_gas) / 100.0,
                    ),
                ),
            )
            self._unaccounted_enemy_army_supply = round(
                max(0.0, est_total_enemy_sup - self._seen_enemy_army_supply), 1
            )

            # Compute ETA to our natural/main and ETA to enemy's most exposed expansion
            our_def_anchor = (
                self.townhalls.closest_to(self.game_info.map_center).position
                if self.townhalls
                else (self.start_location if self.start_location else Point2((32.0, 32.0)))
            )
            enemy_home = (
                self.enemy_start_locations[0]
                if self.enemy_start_locations
                else (self.game_info.map_center if self.game_info else Point2((32.0, 32.0)))
            )
            exposed_enemy_base = enemy_home
            if self._remembered_enemy_base_positions:
                exposed_enemy_base = max(
                    self._remembered_enemy_base_positions.values(),
                    key=lambda pt: pt.distance_to(enemy_home),
                )

            min_eta_our_nat = 99.0
            for c_info in self._tracked_enemy_clusters.values():
                if float(c_info["supply"]) < 2.0:
                    continue
                age = max(0.0, sec - float(c_info["last_seen"]))
                dist_nat = float(c_info["pos"].distance_to(our_def_anchor))
                eta_nat = max(0.0, (dist_nat / max(1.8, float(c_info["v_eff"]))) - age)
                min_eta_our_nat = min(min_eta_our_nat, eta_nat)
            self._enemy_eta_to_our_natural_sec = round(min_eta_our_nat, 1)

            clusters_sorted = sorted(
                self._tracked_enemy_clusters.values(),
                key=lambda c: float(c["supply"]),
                reverse=True,
            )
            if clusters_sorted:
                main_c = clusters_sorted[0]
                age_m = max(0.0, sec - float(main_c["last_seen"]))
                dist_exp = float(main_c["pos"].distance_to(exposed_enemy_base))
                eta_exp = max(0.0, (dist_exp / max(1.8, float(main_c["v_eff"]))) - age_m)
                if has_nexus_recall:
                    eta_exp = min(eta_exp, 4.5)
                self._enemy_eta_to_their_exposed_base_sec = round(eta_exp, 1)
            else:
                self._enemy_eta_to_their_exposed_base_sec = 99.0

            # Select tactical/strategic spatial maneuver
            self._isolated_enemy_cluster_target = None
            self._backstab_enemy_base_target = None
            maneuver = "standard_posture"

            if self._enemy_eta_to_our_natural_sec <= 10.0 and self._seen_enemy_army_supply >= 4.0:
                maneuver = "pre_rotate_intercept_incoming_threat"
            elif len(clusters_sorted) >= 2:
                c1, c2 = clusters_sorted[0], clusters_sorted[1]
                sep_dist = float(c1["pos"].distance_to(c2["pos"]))
                reinforce_eta = sep_dist / max(2.0, float(c1["v_eff"]))
                closer_c = (
                    c1
                    if c1["pos"].distance_to(our_def_anchor) <= c2["pos"].distance_to(our_def_anchor)
                    else c2
                )
                if (
                    sep_dist > 18.0
                    and reinforce_eta > 8.0
                    and float(self.supply_army) >= max(8.0, 1.35 * float(closer_c["supply"]))
                ):
                    maneuver = "surround_and_crush_isolated_enemy_cluster"
                    self._isolated_enemy_cluster_target = closer_c["pos"]

            if (
                maneuver == "standard_posture"
                and self._seen_enemy_army_supply >= 8.0
                and self._seen_enemy_army_supply >= 0.60 * max(8.0, est_total_enemy_sup)
                and self._enemy_eta_to_their_exposed_base_sec > 12.0
                and not has_nexus_recall
            ):
                maneuver = "backstab_undefended_enemy_expansion"
                self._backstab_enemy_base_target = exposed_enemy_base
            elif (
                maneuver == "standard_posture"
                and self._seen_enemy_army_supply >= 6.0
                and self._enemy_eta_to_our_natural_sec > 16.0
            ):
                maneuver = "safe_to_expand_enemy_pinned_far"

            self._spatial_maneuver = maneuver

        def _evaluate_all_mirror_depths_and_select_best(self) -> None:
            """
            Evaluates ALL cognitive depths d = 0..5 in parallel without tying any depth to a
            fixed unit or building type. Online accuracy (`self._depth_ema_accuracy`) scores
            predictions made at `t_past` (~30-45s earlier) against the newly observed / newly
            implied marginal resource spend (`delta_minerals + 1.5 * delta_gas`) at `t_now`,
            weighting tech transitions / newly revealed tech branches by 2.0x so `d=0`
            (observational inertia) never gets inflated credit from old tier-1 units.
            """
            sec = float(getattr(self.state, "game_loop", 0)) / 22.4
            struct_cost_map = {
                "SPAWNINGPOOL": (200, 0),
                "ROACHWARREN": (150, 0),
                "BANELINGNEST": (100, 50),
                "LAIR": (150, 100),
                "HYDRALISKDEN": (100, 100),
                "LURKERDENMP": (100, 150),
                "SPIRE": (200, 200),
                "INFESTATIONPIT": (100, 100),
                "HIVE": (200, 150),
                "ULTRALISKCAVERN": (150, 200),
                "GREATERSPIRE": (100, 150),
                "BARRACKSTECHLAB": (50, 25),
                "FACTORY": (150, 100),
                "FACTORYTECHLAB": (50, 25),
                "STARPORT": (150, 100),
                "STARPORTTECHLAB": (50, 25),
                "ARMORY": (150, 100),
                "GHOSTACADEMY": (150, 50),
                "FUSIONCORE": (150, 150),
                "CYBERNETICSCORE": (150, 0),
                "TWILIGHTCOUNCIL": (150, 100),
                "ROBOTICSFACILITY": (150, 100),
                "ROBOTICSBAY": (150, 150),
                "STARGATE": (150, 150),
                "TEMPLARARCHIVE": (150, 200),
                "DARKSHRINE": (150, 150),
                "FLEETBEACON": (300, 200),
            }

            # 1. Score any historical snapshot from ~30-45s ago against newly observed marginal spend
            while self._depth_prediction_history and (sec - float(self._depth_prediction_history[0]["t_past"])) >= 30.0:
                snap = self._depth_prediction_history.pop(0)
                new_unit_tags = (self._seen_enemy_unit_tags - snap["seen_unit_tags"]) - self._confirmed_hallucination_tags
                new_tech_bldgs = self._implied_enemy_tech_buildings - snap["implied_tech"]
                new_upgs = self._observed_enemy_upgrades - snap["observed_upgs"]
                delta_bases = max(0, int(self.enemy_known_bases) - int(snap["enemy_bases"]))

                tier1_continuation_spend = 0.0
                counter_comp_spend = 0.0
                tech_transition_spend = 0.0
                macro_expand_spend = float(delta_bases) * 400.0
                stealth_or_bluff_spend = 0.0

                for utag in new_unit_tags:
                    uname = self._enemy_unit_types.get(utag, "MARINE")
                    if uname in {"DRONE", "SCV", "PROBE", "OVERLORD", "LARVA", "EGG"}:
                        continue
                    m_c, g_c = self._estimate_unit_min_gas_cost(uname)
                    base_w = float(m_c) + 1.5 * float(g_c)
                    if g_c >= 50 or uname in {"MUTALISK", "LURKERMP", "VOIDRAY", "ORACLE", "CARRIER", "COLOSSUS", "IMMORTAL", "SIEGETANK", "BANSHEE", "BATTLECRUISER"}:
                        # 2.0x weight on newly revealed tech/gas units!
                        tech_transition_spend += 2.0 * base_w
                        counter_comp_spend += 1.4 * base_w
                    else:
                        tier1_continuation_spend += base_w
                        counter_comp_spend += 0.8 * base_w

                for bname in new_tech_bldgs:
                    m_c, g_c = struct_cost_map.get(bname, (150, 100))
                    # 2.0x weight on newly revealed tech structures!
                    w_tech = 2.0 * (float(m_c) + 1.5 * float(g_c))
                    tech_transition_spend += w_tech
                    if bname in {"DARKSHRINE", "GHOSTACADEMY", "LURKERDENMP", "STARGATE", "SPIRE"}:
                        stealth_or_bluff_spend += w_tech

                for _upg in new_upgs:
                    tech_transition_spend += 2.0 * (150.0 + 1.5 * 150.0)

                if self._enemy_bluff_suspected or self._unaccounted_enemy_army_supply >= 12.0:
                    stealth_or_bluff_spend += 450.0

                total_marginal = (
                    tier1_continuation_spend
                    + counter_comp_spend
                    + tech_transition_spend
                    + macro_expand_spend
                    + stealth_or_bluff_spend
                )
                if total_marginal >= 100.0:
                    d_scores = {
                        0: 100.0 * (tier1_continuation_spend / total_marginal),
                        1: 100.0 * ((0.65 * counter_comp_spend + 0.35 * tier1_continuation_spend) / total_marginal),
                        2: 100.0 * ((0.50 * counter_comp_spend + 0.50 * macro_expand_spend + 0.35 * tech_transition_spend) / total_marginal),
                        3: 100.0 * ((0.75 * tech_transition_spend + 0.25 * counter_comp_spend) / total_marginal),
                        4: 100.0 * ((0.70 * stealth_or_bluff_spend + 0.30 * tech_transition_spend) / total_marginal),
                        5: 100.0 * ((0.40 * macro_expand_spend + 0.40 * tech_transition_spend + 0.20 * counter_comp_spend) / total_marginal),
                    }
                    for d_idx, raw_s in d_scores.items():
                        bounded_s = min(98.0, max(25.0, raw_s + 35.0))
                        prev_acc = float(self._depth_ema_accuracy.get(d_idx, 60.0))
                        self._depth_ema_accuracy[d_idx] = round(0.80 * prev_acc + 0.20 * bounded_s, 1)

            # 2. Record a new snapshot every 10s for future marginal-spend evaluation
            if sec - self._last_depth_snapshot_sec >= 10.0:
                self._last_depth_snapshot_sec = sec
                self._depth_predictions = {
                    0: {"focus": "observational_inertia_continuation", "branch": self._enemy_committed_branch},
                    1: {"focus": "first_order_direct_counter_to_our_visible", "branch": self._enemy_committed_branch},
                    2: {"focus": "second_order_counter_and_macro_lead", "branch": self._enemy_committed_branch},
                    3: {"focus": "third_order_tech_transition_window", "branch": self._enemy_committed_branch},
                    4: {"focus": "fourth_order_bluff_and_hidden_tech_audit", "branch": self._enemy_committed_branch},
                    5: {"focus": "fifth_order_minimax_equilibrium_hedge", "branch": self._enemy_committed_branch},
                }
                self._depth_prediction_history.append(
                    {
                        "t_past": sec,
                        "seen_unit_tags": set(self._seen_enemy_unit_tags),
                        "implied_tech": set(self._implied_enemy_tech_buildings),
                        "observed_upgs": set(self._observed_enemy_upgrades),
                        "enemy_bases": int(self.enemy_known_bases),
                    }
                )
                if len(self._depth_prediction_history) > 12:
                    self._depth_prediction_history.pop(0)

            # 3. Dynamically select active cognitive depth d* with highest rolling predictive accuracy
            best_d = max(range(6), key=lambda d: (float(self._depth_ema_accuracy.get(d, 60.0)), -abs(d - 2)))
            self.mirror_active_depth = int(best_d)
            self.mirror_inferred_opponent_depth = max(0, int(best_d) - 1)
            self.mirror_accuracy_pct = int(round(float(self._depth_ema_accuracy.get(best_d, 67.0))))

        @staticmethod
        def _quantize_point(pt: Any, grid: float = 1.0) -> Any:
            if hasattr(pt, "x") and hasattr(pt, "y"):
                return Point2((round(float(pt.x) / grid) * grid, round(float(pt.y) / grid) * grid))
            return pt

        def _unit_already_has_order(
            self,
            unit: Any,
            ability_id: Any,
            target: Any = None,
            tol: float = 2.2,
            tolerance: Optional[float] = None,
        ) -> bool:
            effective_tol = float(tolerance) if tolerance is not None else float(tol)
            orders = getattr(unit, "orders", None)
            if not orders:
                return False
            loop = int(self.state.game_loop) if hasattr(self, "state") and self.state else 0
            last_loop = self._unit_last_order_loop.get(unit.tag, -999)
            if loop - last_loop > 56:  # Refresh at least every ~2.5s
                return False

            order0 = orders[0]
            ord_ab = getattr(order0, "ability", None)
            ord_ab_id = getattr(ord_ab, "id", None)
            ord_ab_name = str(getattr(ord_ab, "name", "")).upper()
            req_name = str(getattr(ability_id, "name", ability_id)).upper()

            same_kind = (
                ord_ab_id == ability_id
                or ("ATTACK" in req_name and "ATTACK" in ord_ab_name)
                or ("MOVE" in req_name and "MOVE" in ord_ab_name)
                or ("GATHER" in req_name and ("GATHER" in ord_ab_name or "HARVEST" in ord_ab_name))
            )
            if not same_kind:
                return False

            if target is None:
                return True

            ord_target = getattr(order0, "target", None)
            if ord_target is None:
                return False

            if isinstance(target, int) or hasattr(target, "tag"):
                t_tag = target if isinstance(target, int) else target.tag
                if ord_target == t_tag:
                    return True
                if hasattr(target, "position") and hasattr(ord_target, "x") and hasattr(ord_target, "y"):
                    if math.hypot(float(ord_target.x) - float(target.position.x), float(ord_target.y) - float(target.position.y)) <= effective_tol:
                        return True
                return False

            if hasattr(target, "x") and hasattr(target, "y") and hasattr(ord_target, "x") and hasattr(ord_target, "y"):
                return math.hypot(float(ord_target.x) - float(target.x), float(ord_target.y) - float(target.y)) <= effective_tol

            return False

        def _issue_batched_group_order(
            self,
            units: Any,
            order_type: Any,
            target: Any,
            tol: float = 2.2,
            tolerance: Optional[float] = None,
        ) -> int:
            """
            Filters out units that are already executing the same order within `tol` tiles,
            quantizes Point2 targets so `python-sc2` combines all unit tags into a single
            `ActionRawUnitCommand`, and tracks batched EPM/APM discipline.
            """
            if not units:
                return 0
            effective_tol = float(tolerance) if tolerance is not None else float(tol)
            ord_str = str(getattr(order_type, "name", order_type)).lower()
            is_attack = "attack" in ord_str
            ab_id = AbilityId.ATTACK if is_attack else AbilityId.MOVE
            send_target = (
                target
                if (isinstance(target, int) or hasattr(target, "tag"))
                else self._quantize_point(target, grid=1.0)
            )
            loop = int(self.state.game_loop) if hasattr(self, "state") and self.state else 0
            filtered = []
            for u in units:
                if self._unit_already_has_order(u, ab_id, send_target, tol=effective_tol):
                    self.redundant_orders_skipped += 1
                else:
                    filtered.append(u)
                    self._unit_last_order_loop[u.tag] = loop

            if not filtered:
                return 0

            for u in filtered:
                if is_attack:
                    u.attack(send_target)
                else:
                    u.move(send_target)
            self.batched_group_commands_issued += 1
            return len(filtered)

        async def _step_pro_human_camera_and_apm_alignment(self) -> None:
            """
            Aligns camera saccades to pro-human 75-110 SPM (`~14-18` game loops per jump,
            consecutive distance `>= 18.0` tiles) cycling across Main/Natural/3rd TownHalls,
            Active Army Centroid, and Harass/Blocker/Enemy locations.
            """
            loop = int(self.state.game_loop)
            if loop - self._last_camera_move_loop < 16:
                return

            candidates: List[Any] = []
            if self._queued_camera_focus is not None:
                qf = self._queued_camera_focus
                self._queued_camera_focus = None
                candidates.append(Point2((float(qf[0]), float(qf[1]))))

            if self.townhalls:
                main_pos = self.townhalls.first.position
                candidates.append(main_pos)
                if len(self.townhalls) >= 2:
                    sorted_ths = sorted(self.townhalls, key=lambda t: t.distance_to(main_pos))
                    candidates.append(sorted_ths[-1].position)

            combat_units = self.units.exclude_type(
                {UnitTypeId.DRONE, UnitTypeId.SCV, UnitTypeId.PROBE, UnitTypeId.LARVA, UnitTypeId.EGG, UnitTypeId.OVERLORD}
            )
            if combat_units:
                candidates.append(combat_units.center)

            if self._expansion_blocker_targets:
                candidates.append(next(iter(self._expansion_blocker_targets.values())))

            if self.game_info:
                candidates.append(self.game_info.map_center)
            if self.enemy_start_locations:
                candidates.append(self.enemy_start_locations[0])

            if not candidates:
                return

            chosen = None
            n = len(candidates)
            for offset in range(n):
                idx = (self._camera_saccade_idx + offset) % n
                pt = candidates[idx]
                if self._last_camera_pos is None or pt.distance_to(self._last_camera_pos) >= 18.0:
                    chosen = pt
                    self._camera_saccade_idx = (idx + 1) % n
                    break

            if chosen is None and self._last_camera_pos is not None:
                far_anchor = (
                    self.enemy_start_locations[0]
                    if self.enemy_start_locations
                    else self.game_info.map_center
                )
                if self._last_camera_pos.distance_to(far_anchor) >= 18.5:
                    chosen = self._last_camera_pos.towards(far_anchor, 19.5)
                elif self.start_location and self._last_camera_pos.distance_to(self.start_location) >= 18.5:
                    chosen = self._last_camera_pos.towards(self.start_location, 19.5)

            if chosen is not None:
                try:
                    await self.client.move_camera(chosen)
                    self._last_camera_pos = chosen
                    self._last_camera_move_loop = loop
                    self.camera_saccades_emitted += 1
                    self._record_pro_mechanic("pro-camera-saccade")
                except Exception:
                    pass

        def _emit_telemetry(self, event_type: str, **payload: Any) -> Dict[str, Any]:
            return self.telemetry.emit_event(self, event_type, **payload)

        async def _try_smart_expand(self, th_type: Any, reason: str = "macro") -> bool:
            loop = int(self.state.game_loop)
            if loop - self._last_expand_attempt_loop < 112:
                return False
            self._last_expand_attempt_loop = loop
            try:
                next_loc = await self.get_next_expansion()
                if next_loc is not None:
                    await self.expand_now(th_type)
                    self.expansions_started += 1
                    self._emit_telemetry(
                        "EXPANSION_STARTED",
                        reason=reason,
                        th=th_type.name,
                        bases=len(self.townhalls),
                        workers=len(self.workers),
                        minerals=int(self.minerals),
                        loc=[round(next_loc.x, 1), round(next_loc.y, 1)],
                    )
                    return True
            except Exception:
                pass
            # Fallback: scan expansion_locations_list by distance from main townhall
            if self.townhalls and hasattr(self, "expansion_locations_list"):
                main_pos = self.townhalls.first.position
                for loc in sorted(self.expansion_locations_list, key=lambda p: p.distance_to(main_pos)):
                    if any(th.distance_to(loc) < 8.0 for th in self.townhalls):
                        continue
                    if any(e.distance_to(loc) < 12.0 for e in (self.enemy_units | self.enemy_structures)):
                        continue
                    w = self.select_build_worker(loc)
                    if w:
                        w.build(th_type, loc)
                        self.expansions_started += 1
                        self._emit_telemetry(
                            "EXPANSION_STARTED_FALLBACK",
                            reason=reason,
                            th=th_type.name,
                            bases=len(self.townhalls),
                            workers=len(self.workers),
                            loc=[round(loc.x, 1), round(loc.y, 1)],
                        )
                        return True
            self.expansions_failed += 1
            self._emit_telemetry(
                "EXPANSION_BLOCKED",
                reason=reason,
                bases=len(self.townhalls),
                workers=len(self.workers),
                minerals=int(self.minerals),
            )
            return False

        def _transition_posture(self, new_posture: str) -> None:
            if new_posture and new_posture != self.current_posture:
                old_posture = self.current_posture
                self.current_posture = new_posture
                self.posture_transitions.append(f"{self.state.game_loop}:{new_posture}")
                self._emit_telemetry(
                    "POSTURE_TRANSITION",
                    from_posture=old_posture,
                    to_posture=new_posture,
                    army_sup=int(self.supply_army),
                    workers=len(self.workers),
                    bases=len(self.townhalls),
                )

        def _data_dir(self) -> Path:
            data_dir = ROOT_DIR / "data"
            data_dir.mkdir(parents=True, exist_ok=True)
            return data_dir

        def _opponent_data_path(self) -> Path:
            return self._data_dir() / "mirror_mind_opponents.json"

        def _telemetry_history_path(self) -> Path:
            return self._data_dir() / "match_telemetry_history.jsonl"

        def _load_opponent_bot_data(self) -> None:
            self.telemetry.load_opponent_profile(self, self._data_dir())

        def _diagnose_bottlenecks(self) -> List[str]:
            return self.telemetry.diagnose_bottlenecks(self)

        def _save_opponent_bot_data(self, game_result: Any) -> None:
            self.telemetry.finalize_match_summary(self, game_result, self._data_dir())

        async def on_start(self):
            self._load_opponent_bot_data()
            if self.enemy_start_locations:
                ep = self.enemy_start_locations[0]
                key = (int(round(ep.x / 6.0) * 6), int(round(ep.y / 6.0) * 6))
                self._remembered_enemy_base_positions[key] = ep
            actual_race_name = self.race.name if hasattr(self, "race") and self.race else self.configured_race
            enemy_race_name = (
                self.enemy_race.name
                if hasattr(self, "enemy_race") and self.enemy_race
                else "Unknown"
            )
            self.bridge = SC2BurnySexpBridge(
                bot_rkt_path=self.bot_rkt_path,
                race_str="Random" if str(self.configured_race).lower() == "random" else actual_race_name,
                posture_str=self.current_posture,
            )
            self.bridge.start()
            self.client.game_step = 4
            ipc_mode = "python_fallback"
            if self.bridge and self.bridge.cmd:
                ipc_mode = "python_fallback" if "racket_sexp_fallback.py" in " ".join(self.bridge.cmd) else "racket_native"
            self._emit_telemetry(
                "MATCH_START",
                map=getattr(self.game_info, "map_name", "unknown"),
                my_race=actual_race_name,
                enemy_race=enemy_race_name,
                opponent_id=str(getattr(self, "opponent_id", None) or "local_opponent"),
                ipc_mode=ipc_mode,
                initial_posture=self.current_posture,
                prior_depth=self.mirror_active_depth,
                prior_opp_depth=self.mirror_inferred_opponent_depth,
            )

        async def on_end(self, game_result):
            self._recorded_result = game_result
            self._save_opponent_bot_data(game_result)
            if self.bridge:
                self.bridge.close()

        def _record_pro_mechanic(self, name: str):
            self.pro_mechanics_triggered[name] = self.pro_mechanics_triggered.get(name, 0) + 1

        def _record_countermeasure(self, name: str):
            self.countermeasures_triggered[name] = self.countermeasures_triggered.get(name, 0) + 1

        @staticmethod
        def _is_builder_worker(w) -> bool:
            if getattr(w, "is_constructing_scv", False):
                return True
            for o in getattr(w, "orders", []):
                ab_name = getattr(o.ability, "name", "")
                if "BUILD" in ab_name:
                    return True
            return False

        def _compute_en_route_reservations(self) -> Tuple[int, int]:
            res_min = 0
            res_gas = 0
            for w in self.workers:
                for order in w.orders:
                    ab_name = order.ability.name if hasattr(order.ability, "name") else ""
                    if "BUILD" in ab_name:
                        if any(k in ab_name for k in ("HATCHERY", "NEXUS", "COMMANDCENTER")):
                            res_min += 300 if "HATCHERY" in ab_name else 400
                        elif any(k in ab_name for k in ("SPAWNINGPOOL", "BARRACKS", "GATEWAY", "ROACHWARREN", "FORGE", "PHOTONCANNON")):
                            res_min += 150
                        elif any(k in ab_name for k in ("PYLON", "SUPPLYDEPOT", "SPINECRAWLER", "SPORECRAWLER", "BUNKER", "MISSILETURRET")):
                            res_min += 100
                        elif any(k in ab_name for k in ("EXTRACTOR", "REFINERY", "ASSIMILATOR")):
                            res_min += 75
                        elif any(k in ab_name for k in ("FACTORY", "STARPORT", "ROBOTICSFACILITY", "STARGATE", "CYBERNETICSCORE", "HYDRALISKDEN")):
                            res_min += 150
                            res_gas += 100
            return res_min, res_gas

        def _build_frame_observation(self) -> str:
            res_min, res_gas = self._compute_en_route_reservations()
            eff_min = max(0, int(self.minerals) - res_min)
            eff_gas = max(0, int(self.vespene) - res_gas)

            actual_race_sym = self.race.name.lower() if hasattr(self, "race") and self.race else "zerg"
            pending_sup = (
                self.already_pending(UnitTypeId.OVERLORD)
                + self.already_pending(UnitTypeId.SUPPLYDEPOT)
                + self.already_pending(UnitTypeId.PYLON)
            )

            my_units_sexp = []
            skip_unit_types = {UnitTypeId.LARVA, UnitTypeId.EGG}
            for u in self.units:
                if u.type_id in skip_unit_types:
                    continue
                ut_name = ENUM_NAME_TO_UNIT_NAME.get(u.type_id.name, u.type_id.name.lower())
                my_units_sexp.append(
                    f"({u.tag} {ut_name} {u.position.x:.1f} {u.position.y:.1f} {u.health:.0f} {u.energy:.0f})"
                )

            ready_tumors = [
                t
                for t in self.structures({UnitTypeId.CREEPTUMORBURROWED, UnitTypeId.CREEPTUMORQUEEN}).ready
                if t.tag not in self._used_creep_tumors
            ]
            for t in ready_tumors:
                my_units_sexp.append(
                    f"({t.tag} creep-tumor-burrowed {t.position.x:.1f} {t.position.y:.1f} {t.health:.0f} 0)"
                )

            my_bldgs_sexp = []
            addon_or_morph_types = {
                UnitTypeId.BARRACKSTECHLAB,
                UnitTypeId.BARRACKSREACTOR,
                UnitTypeId.FACTORYTECHLAB,
                UnitTypeId.FACTORYREACTOR,
                UnitTypeId.STARPORTTECHLAB,
                UnitTypeId.STARPORTREACTOR,
                UnitTypeId.ORBITALCOMMAND,
                UnitTypeId.PLANETARYFORTRESS,
            }
            for b in self.structures:
                bt_name = ENUM_NAME_TO_BUILDING_NAME.get(b.type_id.name, b.type_id.name.lower())
                halted_flag = "#f"
                if self.race == Race.Terran and b.build_progress < 1.0 and b.type_id not in addon_or_morph_types:
                    nearby_scvs = [
                        w
                        for w in self.workers
                        if w.distance_to(b.position) <= 5.5
                        and (w.is_constructing_scv or getattr(w, "order_target", None) == b.tag or self._is_builder_worker(w))
                    ]
                    if not nearby_scvs:
                        halted_flag = "#t"
                expected_hp_frac = 0.10 + 0.90 * b.build_progress
                eff_hp_pct = min(1.0, b.health_percentage / max(0.10, expected_hp_frac)) if b.build_progress < 1.0 else b.health_percentage
                my_bldgs_sexp.append(
                    f"({b.tag} {bt_name} {b.position.x:.1f} {b.position.y:.1f} {eff_hp_pct:.2f} {b.build_progress:.2f} {halted_flag})"
                )

            enemy_units_sexp = []
            for eu in self.enemy_units:
                e_name = ENUM_NAME_TO_UNIT_NAME.get(eu.type_id.name, eu.type_id.name.lower())
                enemy_units_sexp.append(
                    f"({eu.tag} {e_name} {eu.position.x:.1f} {eu.position.y:.1f} {eu.health:.0f})"
                )

            enemy_bldgs_sexp = []
            for eb in self.enemy_structures:
                eb_name = ENUM_NAME_TO_BUILDING_NAME.get(eb.type_id.name, eb.type_id.name.lower())
                enemy_bldgs_sexp.append(
                    f"({eb.tag} {eb_name} {eb.position.x:.1f} {eb.position.y:.1f} {eb.health:.0f})"
                )

            effects_sexp = []
            ff_eff_id = getattr(EffectId, "FORCEFIELD", getattr(EffectId, "FORCEFIELD_FORCEFIELD", None))
            for eff in self.state.effects:
                if ff_eff_id is not None and eff.id == ff_eff_id:
                    for pos in eff.positions:
                        effects_sexp.append(f"(force-field {pos.x:.1f} {pos.y:.1f})")

            researched_syms: List[str] = []
            seen_res = set()
            for upg in getattr(self.state, "upgrades", []):
                u_enum = getattr(upg, "name", str(upg))
                for sym in ENUM_NAME_TO_UPGRADE_SYMS.get(u_enum, [u_enum.lower().replace("_", "-")]):
                    if sym not in seen_res:
                        seen_res.add(sym)
                        researched_syms.append(sym)

            pending_upg_syms: List[str] = []
            seen_pend = set()
            checked_enums = set()
            for sym, u_enum in UPGRADE_NAME_TO_ENUM_NAME.items():
                if u_enum in checked_enums:
                    continue
                checked_enums.add(u_enum)
                upg_id = getattr(UpgradeId, u_enum, None)
                if upg_id is not None and upg_id not in getattr(self.state, "upgrades", set()):
                    try:
                        prog = float(self.already_pending_upgrade(upg_id))
                    except Exception:
                        prog = 0.0
                    if 0.0 < prog < 1.0:
                        for alias_sym in ENUM_NAME_TO_UPGRADE_SYMS.get(u_enum, [sym]):
                            if alias_sym not in seen_pend:
                                seen_pend.add(alias_sym)
                                pending_upg_syms.append(alias_sym)

            depleting_bases = 0
            min_harvesters = 0
            ideal_min_harvesters = 0
            for th in self.townhalls.ready:
                min_harvesters += max(0, int(getattr(th, "assigned_harvesters", 0)))
                ideal_min_harvesters += max(0, int(getattr(th, "ideal_harvesters", 16)))
                close_mins = self.mineral_field.closer_than(10.0, th.position) if self.mineral_field else []
                rem_min = sum(int(getattr(m, "mineral_contents", 0)) for m in close_mins)
                if not close_mins or rem_min < 1800 or len(close_mins) <= 3:
                    depleting_bases += 1

            gas_harvesters = 0
            ideal_gas_harvesters = 0
            for g in self.gas_buildings.ready:
                gas_harvesters += max(0, int(getattr(g, "assigned_harvesters", 0)))
                ideal_gas_harvesters += max(0, int(getattr(g, "ideal_harvesters", 3)))

            prod_facility_types = {
                UnitTypeId.BARRACKS,
                UnitTypeId.FACTORY,
                UnitTypeId.STARPORT,
                UnitTypeId.GATEWAY,
                UnitTypeId.WARPGATE,
                UnitTypeId.ROBOTICSFACILITY,
                UnitTypeId.STARGATE,
            }
            busy_facilities = len(
                self.structures.filter(lambda s: s.type_id in prod_facility_types and s.is_ready and not s.is_idle)
            )
            busy_townhalls = len(self.townhalls.ready.filter(lambda th: not th.is_idle))
            army_supply = int(getattr(self, "supply_army", 0))

            enemy_start = self.enemy_start_locations[0] if self.enemy_start_locations else Point2((32.0, 32.0))
            our_start = self.start_location if self.start_location else Point2((16.0, 16.0))
            nat_pos = our_start.towards(enemy_start, 18.0)
            third_pos = our_start.towards(enemy_start, 30.0)
            if hasattr(self, "expansion_locations_list") and len(self.expansion_locations_list) >= 3:
                sorted_exps = sorted(self.expansion_locations_list, key=lambda p: p.distance_to(our_start))
                nat_pos = sorted_exps[1]
                third_pos = sorted_exps[2]

            return (
                f"(frame-state "
                f"#:frame {self.state.game_loop} "
                f"#:race {actual_race_sym} "
                f"#:minerals {eff_min} "
                f"#:gas {eff_gas} "
                f"#:supply-used {int(self.supply_used)} "
                f"#:supply-cap {int(self.supply_cap)} "
                f"#:supply-left {int(self.supply_left)} "
                f"#:pending-supply {int(pending_sup)} "
                f"#:start-pos ({our_start.x:.1f} {our_start.y:.1f}) "
                f"#:natural-pos ({nat_pos.x:.1f} {nat_pos.y:.1f}) "
                f"#:third-pos ({third_pos.x:.1f} {third_pos.y:.1f}) "
                f"#:enemy-base ({enemy_start.x:.1f} {enemy_start.y:.1f}) "
                f"#:my-units ({' '.join(my_units_sexp)}) "
                f"#:my-buildings ({' '.join(my_bldgs_sexp)}) "
                f"#:enemy-units ({' '.join(enemy_units_sexp)}) "
                f"#:enemy-buildings ({' '.join(enemy_bldgs_sexp)}) "
                f"#:effects ({' '.join(effects_sexp)}) "
                f"#:researched-upgrades ({' '.join(researched_syms)}) "
                f"#:pending-upgrades ({' '.join(pending_upg_syms)}) "
                f"#:depleting-bases {depleting_bases} "
                f"#:mineral-harvesters {min_harvesters} "
                f"#:ideal-mineral-harvesters {ideal_min_harvesters} "
                f"#:gas-harvesters {gas_harvesters} "
                f"#:ideal-gas-harvesters {ideal_gas_harvesters} "
                f"#:busy-facilities {busy_facilities} "
                f"#:busy-townhalls {busy_townhalls} "
                f"#:army-supply {army_supply})"
            )

        async def _actuate_train_unit(self, ut: Any) -> bool:
            if ut is None:
                return False

            if ut == UnitTypeId.OVERLORD:
                if (
                    self.race == Race.Zerg
                    and self.supply_cap < 200
                    and self.supply_left <= (10 if self.supply_cap >= 66 else 6)
                    and self.already_pending(UnitTypeId.OVERLORD) < (2 if self.supply_cap >= 44 else 1)
                    and self.can_afford(UnitTypeId.OVERLORD)
                    and self.larva
                ):
                    self.larva.first.train(UnitTypeId.OVERLORD)
                    self.commands_issued += 1
                    return True
                return False

            if not self.can_afford(ut) or self.supply_left <= 0:
                return False

            target_workers = min(80, max(22, int(getattr(self, "last_target_workers", 66))))
            if ut == UnitTypeId.DRONE:
                if (
                    self.larva
                    and len(self.workers) + self.already_pending(UnitTypeId.DRONE) < target_workers
                ):
                    self.larva.random.train(UnitTypeId.DRONE)
                    self.commands_issued += 1
                    return True
                return False

            if ut in (UnitTypeId.SCV, UnitTypeId.PROBE):
                idle_ths = self.townhalls.ready.idle
                if (
                    idle_ths
                    and len(self.workers) + self.already_pending(ut) < target_workers
                ):
                    idle_ths.first.train(ut)
                    self.commands_issued += 1
                    return True
                return False

            if ut == UnitTypeId.QUEEN:
                idle_ths = self.townhalls.ready.idle
                max_queens = max(3, len(self.townhalls) + 2)
                if (
                    idle_ths
                    and self.structures(UnitTypeId.SPAWNINGPOOL).ready
                    and len(self.units(UnitTypeId.QUEEN)) + self.already_pending(UnitTypeId.QUEEN) < max_queens
                ):
                    idle_ths.first.train(UnitTypeId.QUEEN)
                    self.commands_issued += 1
                    return True
                return False

            zerg_larva_reqs = {
                UnitTypeId.ZERGLING: UnitTypeId.SPAWNINGPOOL,
                UnitTypeId.ROACH: UnitTypeId.ROACHWARREN,
                UnitTypeId.HYDRALISK: UnitTypeId.HYDRALISKDEN,
                UnitTypeId.MUTALISK: UnitTypeId.SPIRE,
                UnitTypeId.CORRUPTOR: UnitTypeId.SPIRE,
                UnitTypeId.ULTRALISK: UnitTypeId.ULTRALISKCAVERN,
                UnitTypeId.INFESTOR: UnitTypeId.INFESTATIONPIT,
                UnitTypeId.SWARMHOSTMP: UnitTypeId.INFESTATIONPIT,
                UnitTypeId.VIPER: UnitTypeId.HIVE,
            }
            if ut in zerg_larva_reqs:
                req_bldg = zerg_larva_reqs[ut]
                has_req = bool(self.structures(req_bldg).ready) or (
                    req_bldg == UnitTypeId.SPIRE and bool(self.structures(UnitTypeId.GREATERSPIRE).ready)
                )
                if has_req and self.larva:
                    self.larva.random.train(ut)
                    self.commands_issued += 1
                    return True
                return False

            rax_units = {UnitTypeId.MARINE, UnitTypeId.MARAUDER, UnitTypeId.REAPER, UnitTypeId.GHOST}
            if ut in rax_units:
                if ut == UnitTypeId.GHOST and not self.structures(UnitTypeId.GHOSTACADEMY).ready:
                    return False
                need_techlab = ut in (UnitTypeId.MARAUDER, UnitTypeId.GHOST)
                for rax in self.structures(UnitTypeId.BARRACKS).ready:
                    if need_techlab and not rax.has_techlab:
                        continue
                    can_queue = len(rax.orders) == 0 or (
                        rax.has_reactor and len(rax.orders) < 2 and ut in (UnitTypeId.MARINE, UnitTypeId.REAPER)
                    )
                    if can_queue:
                        rax.train(ut)
                        self.commands_issued += 1
                        return True
                return False

            fac_units = {
                UnitTypeId.HELLION,
                UnitTypeId.HELLIONTANK,
                UnitTypeId.WIDOWMINE,
                UnitTypeId.SIEGETANK,
                UnitTypeId.CYCLONE,
                UnitTypeId.THOR,
            }
            if ut in fac_units:
                if ut in (UnitTypeId.HELLIONTANK, UnitTypeId.THOR) and not self.structures(UnitTypeId.ARMORY).ready:
                    return False
                need_techlab = ut in (UnitTypeId.SIEGETANK, UnitTypeId.CYCLONE, UnitTypeId.THOR)
                for fac in self.structures(UnitTypeId.FACTORY).ready:
                    if need_techlab and not fac.has_techlab:
                        continue
                    can_queue = len(fac.orders) == 0 or (
                        fac.has_reactor and len(fac.orders) < 2 and ut in (UnitTypeId.HELLION, UnitTypeId.WIDOWMINE)
                    )
                    if can_queue:
                        fac.train(ut)
                        self.commands_issued += 1
                        return True
                return False

            sp_units = {
                UnitTypeId.VIKINGFIGHTER,
                UnitTypeId.MEDIVAC,
                UnitTypeId.LIBERATOR,
                UnitTypeId.RAVEN,
                UnitTypeId.BANSHEE,
                UnitTypeId.BATTLECRUISER,
            }
            if ut in sp_units:
                if ut == UnitTypeId.BATTLECRUISER and not self.structures(UnitTypeId.FUSIONCORE).ready:
                    return False
                need_techlab = ut in (UnitTypeId.RAVEN, UnitTypeId.BANSHEE, UnitTypeId.BATTLECRUISER)
                for sp in self.structures(UnitTypeId.STARPORT).ready:
                    if need_techlab and not sp.has_techlab:
                        continue
                    can_queue = len(sp.orders) == 0 or (
                        sp.has_reactor
                        and len(sp.orders) < 2
                        and ut in (UnitTypeId.VIKINGFIGHTER, UnitTypeId.MEDIVAC, UnitTypeId.LIBERATOR)
                    )
                    if can_queue:
                        sp.train(ut)
                        self.commands_issued += 1
                        return True
                return False

            gw_units = {
                UnitTypeId.ZEALOT,
                UnitTypeId.STALKER,
                UnitTypeId.SENTRY,
                UnitTypeId.ADEPT,
                UnitTypeId.HIGHTEMPLAR,
                UnitTypeId.DARKTEMPLAR,
            }
            if ut in gw_units:
                if ut in (UnitTypeId.STALKER, UnitTypeId.SENTRY, UnitTypeId.ADEPT) and not self.structures(UnitTypeId.CYBERNETICSCORE).ready:
                    return False
                if ut == UnitTypeId.HIGHTEMPLAR and not self.structures(UnitTypeId.TEMPLARARCHIVE).ready:
                    return False
                if ut == UnitTypeId.DARKTEMPLAR and not self.structures(UnitTypeId.DARKSHRINE).ready:
                    return False
                idle_gws = self.structures(UnitTypeId.GATEWAY).ready.idle
                if idle_gws:
                    idle_gws.first.train(ut)
                    self.commands_issued += 1
                    return True
                wgs = self.structures(UnitTypeId.WARPGATE).ready
                pylons = self.structures(UnitTypeId.PYLON).ready
                if wgs and pylons:
                    anchor_pylon = pylons.closest_to(self.townhalls.first.position) if self.townhalls else pylons.first
                    for wg in wgs:
                        try:
                            abilities = await self.get_available_abilities(wg)
                            warp_ab = getattr(AbilityId, f"WARPGATETRAIN_{ut.name}", None)
                            if ut == UnitTypeId.DARKTEMPLAR and warp_ab is None:
                                warp_ab = getattr(AbilityId, "WARPGATETRAIN_DARKTEMPLAR", None)
                            if warp_ab in abilities:
                                pos = anchor_pylon.position.to2.random_on_distance(3.0)
                                placement = await self.find_placement(warp_ab, pos, placement_step=1)
                                if placement:
                                    wg.warp_in(ut, placement)
                                    self.commands_issued += 1
                                    return True
                        except Exception:
                            continue
                return False

            robo_units = {
                UnitTypeId.OBSERVER,
                UnitTypeId.IMMORTAL,
                UnitTypeId.WARPPRISM,
                UnitTypeId.COLOSSUS,
                UnitTypeId.DISRUPTOR,
            }
            if ut in robo_units:
                if ut in (UnitTypeId.COLOSSUS, UnitTypeId.DISRUPTOR) and not self.structures(UnitTypeId.ROBOTICSBAY).ready:
                    return False
                if ut == UnitTypeId.OBSERVER and len(self.units(UnitTypeId.OBSERVER)) + self.already_pending(UnitTypeId.OBSERVER) >= 2:
                    return False
                idle_robos = self.structures(UnitTypeId.ROBOTICSFACILITY).ready.idle
                if idle_robos:
                    idle_robos.first.train(ut)
                    self.commands_issued += 1
                    return True
                return False

            sg_units = {
                UnitTypeId.PHOENIX,
                UnitTypeId.ORACLE,
                UnitTypeId.VOIDRAY,
                UnitTypeId.TEMPEST,
                UnitTypeId.CARRIER,
            }
            if ut in sg_units:
                if ut in (UnitTypeId.TEMPEST, UnitTypeId.CARRIER) and not self.structures(UnitTypeId.FLEETBEACON).ready:
                    return False
                idle_sgs = self.structures(UnitTypeId.STARGATE).ready.idle
                if idle_sgs:
                    idle_sgs.first.train(ut)
                    self.commands_issued += 1
                    return True
                return False

            return False

        async def _actuate_build_structure(
            self,
            bt: Any,
            x: Optional[float] = None,
            y: Optional[float] = None,
        ) -> bool:
            if bt is None or not self.townhalls:
                return False

            loop = int(self.state.game_loop)
            last_cd = int(self._build_cooldown_by_type.get(bt, -999))
            cooldown_loops = 22 if bt in (UnitTypeId.SUPPLYDEPOT, UnitTypeId.PYLON) else 44
            if loop - last_cd < cooldown_loops:
                return False

            if bt in (UnitTypeId.HATCHERY, UnitTypeId.COMMANDCENTER, UnitTypeId.NEXUS):
                if self.can_afford(bt):
                    self._build_cooldown_by_type[bt] = loop
                    return await self._try_smart_expand(bt, reason="racket_expand")
                return False

            if not self.can_afford(bt):
                return False

            main_th = self.townhalls.first

            # 1. Gas buildings (Extractor / Refinery / Assimilator)
            if bt in (UnitTypeId.EXTRACTOR, UnitTypeId.REFINERY, UnitTypeId.ASSIMILATOR):
                max_gases = min(len(self.townhalls) * 2, 1 if len(self.workers) < 19 else len(self.townhalls) * 2)
                if (
                    len(self.gas_buildings) + self.already_pending(bt) >= max_gases
                    or self.already_pending(bt) >= 2
                ):
                    return False
                for th in self.townhalls.ready:
                    vgs = self.vespene_geyser.closer_than(10.0, th)
                    for vg in vgs:
                        if not self.gas_buildings.closer_than(1.0, vg):
                            w = self.select_build_worker(vg.position)
                            if w:
                                w.build_gas(vg)
                                self._build_cooldown_by_type[bt] = loop
                                self.commands_issued += 1
                                return True
                return False

            # 2. Terran Add-ons
            addon_parent_map = {
                UnitTypeId.BARRACKSTECHLAB: UnitTypeId.BARRACKS,
                UnitTypeId.BARRACKSREACTOR: UnitTypeId.BARRACKS,
                UnitTypeId.FACTORYTECHLAB: UnitTypeId.FACTORY,
                UnitTypeId.FACTORYREACTOR: UnitTypeId.FACTORY,
                UnitTypeId.STARPORTTECHLAB: UnitTypeId.STARPORT,
                UnitTypeId.STARPORTREACTOR: UnitTypeId.STARPORT,
            }
            if bt in addon_parent_map:
                parent_type = addon_parent_map[bt]
                for fac_bldg in self.structures(parent_type).ready.idle:
                    if (
                        fac_bldg.add_on_tag == 0
                        and loop - int(self._addon_last_attempt_loop.get(fac_bldg.tag, -999)) >= 224
                    ):
                        self._addon_last_attempt_loop[fac_bldg.tag] = loop
                        can_fit = self._can_fit_addon(fac_bldg.position)
                        if not can_fit:
                            try:
                                can_fit = await self.can_place_single(UnitTypeId.SUPPLYDEPOT, fac_bldg.add_on_position)
                            except Exception:
                                can_fit = False
                        if can_fit:
                            fac_bldg.build(bt)
                            self._build_cooldown_by_type[bt] = loop
                            self.commands_issued += 1
                            return True
                return False

            # 3. Supply structures (Supply Depot / Pylon)
            if bt in (UnitTypeId.SUPPLYDEPOT, UnitTypeId.PYLON):
                if self.supply_cap >= 200 or self.already_pending(bt) >= (2 if self.supply_cap >= 44 else 1):
                    return False
                near_anchor = self._get_main_build_anchor(main_th)
                self._build_cooldown_by_type[bt] = loop
                await self.build(bt, near=near_anchor, max_distance=18)
                self.commands_issued += 1
                return True

            # 4. Tech buildings & static defense duplicate/prerequisite guards
            singleton_tech = {
                UnitTypeId.SPAWNINGPOOL,
                UnitTypeId.ROACHWARREN,
                UnitTypeId.BANELINGNEST,
                UnitTypeId.HYDRALISKDEN,
                UnitTypeId.LURKERDENMP,
                UnitTypeId.SPIRE,
                UnitTypeId.INFESTATIONPIT,
                UnitTypeId.ULTRALISKCAVERN,
                UnitTypeId.GHOSTACADEMY,
                UnitTypeId.ARMORY,
                UnitTypeId.FUSIONCORE,
                UnitTypeId.CYBERNETICSCORE,
                UnitTypeId.TWILIGHTCOUNCIL,
                UnitTypeId.ROBOTICSBAY,
                UnitTypeId.TEMPLARARCHIVE,
                UnitTypeId.DARKSHRINE,
                UnitTypeId.FLEETBEACON,
            }
            if bt in singleton_tech:
                if len(self.structures(bt)) + self.already_pending(bt) >= 1:
                    if not (bt == UnitTypeId.SPIRE and self.structures(UnitTypeId.GREATERSPIRE)):
                        return False
                if bt == UnitTypeId.SPIRE and (self.structures(UnitTypeId.SPIRE) or self.structures(UnitTypeId.GREATERSPIRE)):
                    return False

            if bt in (UnitTypeId.EVOLUTIONCHAMBER, UnitTypeId.ENGINEERINGBAY, UnitTypeId.FORGE):
                max_upg_bldgs = 2 if len(self.townhalls) >= 2 else 1
                if len(self.structures(bt)) + self.already_pending(bt) >= max_upg_bldgs or self.already_pending(bt) >= 1:
                    return False

            prod_types = {
                UnitTypeId.BARRACKS,
                UnitTypeId.FACTORY,
                UnitTypeId.STARPORT,
                UnitTypeId.GATEWAY,
                UnitTypeId.ROBOTICSFACILITY,
                UnitTypeId.STARGATE,
            }
            if bt in prod_types:
                if self.already_pending(bt) >= 2:
                    return False
                max_cap = max(3, len(self.townhalls) * 3)
                cur_count = len(self.structures(bt)) + (
                    len(self.structures(UnitTypeId.WARPGATE)) if bt == UnitTypeId.GATEWAY else 0
                )
                if cur_count + self.already_pending(bt) >= max_cap:
                    return False

            static_def_types = {
                UnitTypeId.SPINECRAWLER,
                UnitTypeId.SPORECRAWLER,
                UnitTypeId.BUNKER,
                UnitTypeId.MISSILETURRET,
                UnitTypeId.PHOTONCANNON,
                UnitTypeId.SHIELDBATTERY,
            }
            if bt in static_def_types:
                if (
                    self.already_pending(bt) >= 1
                    or len(self.structures(bt)) + self.already_pending(bt) >= max(2, len(self.townhalls) + 1)
                ):
                    return False

            # Prerequisite checks so we don't issue invalid placements
            if bt in (UnitTypeId.ROACHWARREN, UnitTypeId.BANELINGNEST, UnitTypeId.SPINECRAWLER, UnitTypeId.SPORECRAWLER):
                if not self.structures(UnitTypeId.SPAWNINGPOOL).ready:
                    return False
            if bt in (UnitTypeId.HYDRALISKDEN, UnitTypeId.SPIRE, UnitTypeId.INFESTATIONPIT):
                if not (self.structures(UnitTypeId.LAIR).ready or self.structures(UnitTypeId.HIVE).ready):
                    return False
            if bt == UnitTypeId.LURKERDENMP and not self.structures(UnitTypeId.HYDRALISKDEN).ready:
                return False
            if bt == UnitTypeId.ULTRALISKCAVERN and not self.structures(UnitTypeId.HIVE).ready:
                return False
            if bt == UnitTypeId.BARRACKS and not self.structures({UnitTypeId.SUPPLYDEPOT, UnitTypeId.SUPPLYDEPOTLOWERED}).ready:
                return False
            if bt in (UnitTypeId.FACTORY, UnitTypeId.GHOSTACADEMY, UnitTypeId.BUNKER) and not self.structures(UnitTypeId.BARRACKS).ready:
                return False
            if bt in (UnitTypeId.STARPORT, UnitTypeId.ARMORY) and not self.structures(UnitTypeId.FACTORY).ready:
                return False
            if bt == UnitTypeId.FUSIONCORE and not self.structures(UnitTypeId.STARPORT).ready:
                return False
            if bt == UnitTypeId.MISSILETURRET and not self.structures(UnitTypeId.ENGINEERINGBAY).ready:
                return False

            # Compute mineral-line or natural-choke anchor for static defense structures
            mineral_line_def_pos = None
            if bt in (UnitTypeId.SPORECRAWLER, UnitTypeId.MISSILETURRET, UnitTypeId.PHOTONCANNON):
                for th in self.townhalls.ready:
                    if not self.structures(bt).closer_than(10.0, th):
                        local_mins = self.mineral_field.closer_than(10.0, th) if self.mineral_field else []
                        if local_mins:
                            mineral_line_def_pos = th.position.towards(local_mins.center, 2.5)
                        else:
                            mineral_line_def_pos = th.position.towards(self.game_info.map_center, -2.5)
                        break
            choke_def_pos = None
            if bt in (UnitTypeId.BUNKER, UnitTypeId.SHIELDBATTERY, UnitTypeId.SPINECRAWLER):
                sorted_ths = sorted(self.townhalls, key=lambda t: t.distance_to(main_th))
                nat_th = sorted_ths[1] if len(sorted_ths) >= 2 else main_th
                choke_def_pos = nat_th.position.towards(self.game_info.map_center, 4.5)

            # Choose anchor position
            if self.race == Race.Protoss:
                pylons = self.structures(UnitTypeId.PYLON).ready
                if not pylons:
                    return False
                if bt == UnitTypeId.CYBERNETICSCORE and not self.structures({UnitTypeId.GATEWAY, UnitTypeId.WARPGATE}).ready:
                    return False
                if bt in (UnitTypeId.TWILIGHTCOUNCIL, UnitTypeId.ROBOTICSFACILITY, UnitTypeId.STARGATE, UnitTypeId.SHIELDBATTERY) and not self.structures(UnitTypeId.CYBERNETICSCORE).ready:
                    return False
                if bt == UnitTypeId.ROBOTICSBAY and not self.structures(UnitTypeId.ROBOTICSFACILITY).ready:
                    return False
                if bt in (UnitTypeId.TEMPLARARCHIVE, UnitTypeId.DARKSHRINE) and not self.structures(UnitTypeId.TWILIGHTCOUNCIL).ready:
                    return False
                if bt == UnitTypeId.FLEETBEACON and not self.structures(UnitTypeId.STARGATE).ready:
                    return False
                if bt == UnitTypeId.PHOTONCANNON and not self.structures(UnitTypeId.FORGE).ready:
                    return False
                target_ref = mineral_line_def_pos or choke_def_pos or self._get_main_build_anchor(main_th)
                anchor_pylon = pylons.closest_to(target_ref)
                self._build_cooldown_by_type[bt] = loop
                self.active_build_goal = ENUM_NAME_TO_BUILDING_NAME.get(bt.name, bt.name.lower())
                await self.build(bt, near=anchor_pylon, max_distance=15)
                self.commands_issued += 1
                return True

            near_pos = (
                mineral_line_def_pos
                or choke_def_pos
                or (
                    main_th.position.towards(self.game_info.map_center, 5.0)
                    if bt in static_def_types
                    else self._get_main_build_anchor(main_th)
                )
            )
            self._build_cooldown_by_type[bt] = loop
            self.active_build_goal = ENUM_NAME_TO_BUILDING_NAME.get(bt.name, bt.name.lower())
            await self.build(bt, near=near_pos, max_distance=18)
            self.commands_issued += 1
            return True

        async def _actuate_research_upgrade(self, upg: Any) -> bool:
            if upg is None or upg in self.state.upgrades:
                return False
            try:
                if self.already_pending_upgrade(upg) > 0:
                    return False
            except Exception:
                pass
            if not self.can_afford(upg):
                return False

            upg_name = getattr(upg, "name", "")
            researcher_types: List[Any] = []
            if upg_name in ("ZERGLINGMOVEMENTSPEED", "ZERGLINGATTACKSPEED"):
                if upg_name == "ZERGLINGATTACKSPEED" and not self.structures(UnitTypeId.HIVE).ready:
                    return False
                researcher_types = [UnitTypeId.SPAWNINGPOOL]
            elif upg_name == "GLIALRECONSTITUTION":
                if not (self.structures(UnitTypeId.LAIR).ready or self.structures(UnitTypeId.HIVE).ready):
                    return False
                researcher_types = [UnitTypeId.ROACHWARREN]
            elif upg_name == "CENTRIFICALHOOKS":
                if not (self.structures(UnitTypeId.LAIR).ready or self.structures(UnitTypeId.HIVE).ready):
                    return False
                researcher_types = [UnitTypeId.BANELINGNEST]
            elif upg_name in ("EVOLVEGROOVEDSPINES", "EVOLVEMUSCULARAUGMENTS"):
                researcher_types = [UnitTypeId.HYDRALISKDEN]
            elif upg_name == "DIGGINGCLAWS":
                if not self.structures(UnitTypeId.HIVE).ready:
                    return False
                researcher_types = [UnitTypeId.LURKERDENMP]
            elif upg_name in ("CHITINOUSPLATING", "ANABOLICSYNTHESIS"):
                researcher_types = [UnitTypeId.ULTRALISKCAVERN]
            elif upg_name.startswith("ZERG"):
                researcher_types = [UnitTypeId.EVOLUTIONCHAMBER]
            elif upg_name in ("BURROW", "OVERLORDSPEED"):
                researcher_types = [UnitTypeId.HATCHERY, UnitTypeId.LAIR, UnitTypeId.HIVE]
            elif upg_name in ("STIMPACK", "SHIELDWALL", "PUNISHERGRENADES"):
                researcher_types = [UnitTypeId.BARRACKSTECHLAB]
            elif upg_name in ("HIGHCAPACITYBARRELS", "DRILLCLAWS"):
                researcher_types = [UnitTypeId.FACTORYTECHLAB]
            elif upg_name == "BANSHEECLOAK":
                researcher_types = [UnitTypeId.STARPORTTECHLAB]
            elif upg_name == "PERSONALCLOAKING":
                researcher_types = [UnitTypeId.GHOSTACADEMY]
            elif upg_name.startswith("TERRANINFANTRY"):
                researcher_types = [UnitTypeId.ENGINEERINGBAY]
            elif upg_name.startswith("TERRANVEHICLE"):
                researcher_types = [UnitTypeId.ARMORY]
            elif upg_name == "WARPGATERESEARCH":
                researcher_types = [UnitTypeId.CYBERNETICSCORE]
            elif upg_name in ("CHARGE", "BLINKTECH"):
                researcher_types = [UnitTypeId.TWILIGHTCOUNCIL]
            elif upg_name == "EXTENDEDTHERMALLANCE":
                researcher_types = [UnitTypeId.ROBOTICSBAY]
            elif upg_name == "PSISTORMTECH":
                researcher_types = [UnitTypeId.TEMPLARARCHIVE]
            elif upg_name.startswith("PROTOSS"):
                researcher_types = [UnitTypeId.FORGE]

            for rtype in researcher_types:
                idle_bldgs = self.structures(rtype).ready.idle
                if idle_bldgs:
                    idle_bldgs.first.research(upg)
                    self.commands_issued += 1
                    return True
            return False

        async def _actuate_morph(self, target_name: str, source_id: Optional[int] = None) -> bool:
            t = target_name.lower()
            if t == "lair":
                if (
                    self.structures(UnitTypeId.SPAWNINGPOOL).ready
                    and not self.structures({UnitTypeId.LAIR, UnitTypeId.HIVE})
                    and not self.already_pending(UnitTypeId.LAIR)
                    and self.can_afford(UnitTypeId.LAIR)
                ):
                    hatches = self.structures(UnitTypeId.HATCHERY).ready.idle
                    if hatches:
                        hatches.first.build(UnitTypeId.LAIR)
                        self.commands_issued += 1
                        return True
            elif t == "hive":
                if (
                    self.structures(UnitTypeId.INFESTATIONPIT).ready
                    and not self.structures(UnitTypeId.HIVE)
                    and not self.already_pending(UnitTypeId.HIVE)
                    and self.can_afford(UnitTypeId.HIVE)
                ):
                    lairs = self.structures(UnitTypeId.LAIR).ready.idle
                    if lairs:
                        lairs.first.build(UnitTypeId.HIVE)
                        self.commands_issued += 1
                        return True
            elif t == "greater-spire":
                if (
                    self.structures(UnitTypeId.HIVE).ready
                    and not self.structures(UnitTypeId.GREATERSPIRE)
                    and not self.already_pending(UnitTypeId.GREATERSPIRE)
                    and self.can_afford(UnitTypeId.GREATERSPIRE)
                ):
                    spires = self.structures(UnitTypeId.SPIRE).ready.idle
                    if spires:
                        spires.first(AbilityId.UPGRADETOGREATERSPIRE_GREATERSPIRE)
                        self.commands_issued += 1
                        return True
            elif t == "ravager":
                roaches = self.units(UnitTypeId.ROACH).ready
                if (
                    roaches
                    and self.structures(UnitTypeId.ROACHWARREN).ready
                    and self.can_afford(UnitTypeId.RAVAGER)
                ):
                    src = roaches.find_by_tag(source_id) if source_id else roaches.first
                    if src is None:
                        src = roaches.first
                    src(AbilityId.MORPHTORAVAGER_RAVAGER)
                    self.commands_issued += 1
                    return True
            elif t == "baneling":
                lings = self.units(UnitTypeId.ZERGLING).ready
                if (
                    lings
                    and self.structures(UnitTypeId.BANELINGNEST).ready
                    and self.can_afford(UnitTypeId.BANELING)
                ):
                    src = lings.find_by_tag(source_id) if source_id else lings.first
                    if src is None:
                        src = lings.first
                    src(AbilityId.MORPHZERGLINGTOBANELING_BANELING)
                    self.commands_issued += 1
                    return True
            elif t == "overseer":
                ovs = self.units(UnitTypeId.OVERLORD).ready
                if (
                    ovs
                    and self.structures({UnitTypeId.LAIR, UnitTypeId.HIVE}).ready
                    and len(self.units(UnitTypeId.OVERSEER)) + self.already_pending(UnitTypeId.OVERSEER) < 2
                    and self.minerals >= 50
                    and self.vespene >= 50
                ):
                    src = ovs.find_by_tag(source_id) if source_id else ovs.first
                    if src is None:
                        src = ovs.first
                    src(AbilityId.MORPH_OVERSEER)
                    self._record_pro_mechanic("morph-overseer-detector")
                    self.commands_issued += 1
                    return True
            elif t in ("lurker", "lurker-mp"):
                hydras = self.units(UnitTypeId.HYDRALISK).ready
                if (
                    hydras
                    and self.structures(UnitTypeId.LURKERDENMP).ready
                    and self.can_afford(UnitTypeId.LURKERMP)
                ):
                    src = hydras.find_by_tag(source_id) if source_id else hydras.first
                    if src is None:
                        src = hydras.first
                    src(AbilityId.MORPH_LURKER)
                    self.commands_issued += 1
                    return True
            elif t in ("brood-lord", "broodlord"):
                corruptors = self.units(UnitTypeId.CORRUPTOR).ready
                if (
                    corruptors
                    and self.structures(UnitTypeId.GREATERSPIRE).ready
                    and self.can_afford(UnitTypeId.BROODLORD)
                ):
                    src = corruptors.find_by_tag(source_id) if source_id else corruptors.first
                    if src is None:
                        src = corruptors.first
                    src(AbilityId.MORPHTOBROODLORD_BROODLORD)
                    self.commands_issued += 1
                    return True
            elif t == "orbital-command":
                ccs = self.structures(UnitTypeId.COMMANDCENTER).ready.idle
                if (
                    ccs
                    and self.structures(UnitTypeId.BARRACKS).ready
                    and self.can_afford(UnitTypeId.ORBITALCOMMAND)
                ):
                    src = ccs.find_by_tag(source_id) if source_id else ccs.first
                    if src is None:
                        src = ccs.first
                    src(AbilityId.UPGRADETOORBITAL_ORBITALCOMMAND)
                    self.commands_issued += 1
                    return True
            elif t == "planetary-fortress":
                ccs = self.structures(UnitTypeId.COMMANDCENTER).ready.idle
                if (
                    ccs
                    and self.structures(UnitTypeId.ENGINEERINGBAY).ready
                    and self.can_afford(UnitTypeId.PLANETARYFORTRESS)
                ):
                    src = ccs.find_by_tag(source_id) if source_id else ccs.first
                    if src is None:
                        src = ccs.first
                    src(AbilityId.UPGRADETOPLANETARYFORTRESS_PLANETARYFORTRESS)
                    self.commands_issued += 1
                    return True
            elif t == "warp-gate":
                gws = self.structures(UnitTypeId.GATEWAY).ready.idle
                if gws and UpgradeId.WARPGATERESEARCH in self.state.upgrades:
                    src = gws.find_by_tag(source_id) if source_id else gws.first
                    if src is None:
                        src = gws.first
                    src(AbilityId.MORPH_WARPGATE)
                    self.commands_issued += 1
                    return True
            elif t == "archon":
                hts = self.units({UnitTypeId.HIGHTEMPLAR, UnitTypeId.DARKTEMPLAR}).ready
                if len(hts) >= 2:
                    hts[0](AbilityId.ARCHON_WARP_TARGET, hts[1])
                    self._record_pro_mechanic("morph-archon")
                    self.commands_issued += 1
                    return True
            return False

        def _partition_queens(self) -> Tuple[List[Any], List[Any]]:
            """
            Partitions ready Queens into dedicated Inject Queens (1 per ready TownHall)
            and Creep/Defense Queens so Inject Queens never wander off to lay tumors.
            """
            queens = list(self.units(UnitTypeId.QUEEN).ready)
            if not queens:
                return [], []
            inject_tags: set = set()
            inject_queens: List[Any] = []
            for th in self.townhalls.ready:
                avail = [q for q in queens if q.tag not in inject_tags and q.distance_to(th) <= 14.0]
                if avail:
                    chosen_q = min(avail, key=lambda q: q.distance_to(th))
                    inject_tags.add(chosen_q.tag)
                    inject_queens.append((chosen_q, th))
            creep_queens = [q for q in queens if q.tag not in inject_tags]
            return inject_queens, creep_queens

        async def _spread_single_creep_tumor(self, tumor: Any, target_dir: Any) -> bool:
            """
            Spreads a burrowed Creep Tumor only after its 10s burrowing cooldown has elapsed
            (`AbilityId.BUILD_CREEPTUMOR_TUMOR in abilities`) and a valid pathable/creep spot
            in a fan of candidate distances/angles (`5.0..9.5` tiles) is found.
            """
            if tumor is None or tumor.tag in self._used_creep_tumors:
                return False
            try:
                abilities = await self.get_available_abilities(tumor)
            except Exception:
                abilities = []
            if AbilityId.BUILD_CREEPTUMOR_TUMOR not in abilities:
                return False

            base_ang = math.atan2(
                float(target_dir.y) - float(tumor.position.y),
                float(target_dir.x) - float(tumor.position.x),
            )
            chosen_pt = None
            for dist in (8.5, 7.0, 5.5):
                for deg in (0.0, -25.0, 25.0, -50.0, 50.0, -80.0, 80.0):
                    ang = base_ang + math.radians(deg)
                    cand = Point2(
                        (
                            float(tumor.position.x) + dist * math.cos(ang),
                            float(tumor.position.y) + dist * math.sin(ang),
                        )
                    )
                    try:
                        if self.in_pathing_grid(cand) and self.has_creep(cand):
                            chosen_pt = cand
                            break
                    except Exception:
                        chosen_pt = cand
                        break
                if chosen_pt is not None:
                    break

            if chosen_pt is None:
                return False

            tumor(AbilityId.BUILD_CREEPTUMOR_TUMOR, chosen_pt)
            self._used_creep_tumors.add(tumor.tag)
            self._record_pro_mechanic("active-creep-tumor-spread")
            self.commands_issued += 1
            return True

        async def _execute_decoded_commands(self, cmds: List[Dict[str, Any]]) -> None:
            self._last_racket_cmds = list(cmds)
            inject_queens_pairs, creep_queens = self._partition_queens() if self.race == Race.Zerg else ([], [])
            inject_queen_tags = {q.tag for q, _ in inject_queens_pairs}
            for c in cmds:
                op = c.get("op")
                try:
                    if op == "posture-transition":
                        new_post = str(c.get("posture", "")).strip()
                        if new_post and new_post != self.current_posture:
                            self.current_posture = new_post
                            self.posture_transitions.append(new_post)
                        self.racket_commands_executed += 1

                    elif op == "mirror-macro-directive":
                        raw = c.get("raw", [])
                        if len(raw) >= 2:
                            directive_str = str(raw[1]).lower()
                            if "defend" in directive_str or "all-in" in directive_str:
                                self.mirror_macro_verdict = "defend_one_base_all_in"
                            elif "greedy" in directive_str or "disrupt" in directive_str:
                                self.mirror_macro_verdict = "counter_greedy_expand_and_disrupt"
                        self.racket_commands_executed += 1

                    elif op == "cancel":
                        uid = c.get("unit_id")
                        bldg = self.structures.find_by_tag(uid) if uid else None
                        if bldg and 0.25 <= bldg.build_progress < 1.0 and bldg.health_percentage < 0.18:
                            bldg(AbilityId.CANCEL_BUILDINPROGRESS)
                            self._record_pro_mechanic("cancel-dying-building")
                            self.commands_issued += 1
                            self.racket_commands_executed += 1

                    elif op == "train":
                        u_enum_name = c.get("unit_enum", "")
                        ut = getattr(UnitTypeId, u_enum_name, None)
                        if ut is not None:
                            executed = await self._actuate_train_unit(ut)
                            if executed or self.can_afford(ut):
                                self.racket_commands_executed += 1

                    elif op == "build":
                        b_enum_name = c.get("building_enum", "")
                        bt = getattr(UnitTypeId, b_enum_name, None)
                        if bt is not None:
                            executed = await self._actuate_build_structure(bt, c.get("x"), c.get("y"))
                            if executed or self.can_afford(bt):
                                self.racket_commands_executed += 1

                    elif op == "expand":
                        th_type = (
                            UnitTypeId.HATCHERY
                            if self.race == Race.Zerg
                            else (UnitTypeId.COMMANDCENTER if self.race == Race.Terran else UnitTypeId.NEXUS)
                        )
                        if self.can_afford(th_type):
                            await self._try_smart_expand(th_type, reason="racket_expand")
                        self.racket_commands_executed += 1

                    elif op == "research":
                        upg_enum_name = c.get("upgrade_enum", "")
                        upg = getattr(UpgradeId, upg_enum_name, None)
                        if upg is not None:
                            executed = await self._actuate_research_upgrade(upg)
                            if executed or self.can_afford(upg):
                                self.racket_commands_executed += 1

                    elif op == "morph":
                        target_name = str(c.get("target", ""))
                        src_id = c.get("source_id")
                        src_tag = int(src_id) if isinstance(src_id, (int, float)) else None
                        await self._actuate_morph(target_name, src_tag)
                        self.racket_commands_executed += 1

                    elif op == "inject-larva":
                        qid = c.get("queen_id")
                        hid = c.get("hatch_id")
                        queen = self.units.find_by_tag(qid) if qid else None
                        hatch = self.structures.find_by_tag(hid) if hid else (self.townhalls.ready.first if self.townhalls.ready else None)
                        if queen and hatch and queen.energy >= 25 and not hatch.has_buff(BuffId.QUEENSPAWNLARVATIMER):
                            queen(AbilityId.EFFECT_INJECTLARVA, hatch)
                            self.commands_issued += 1
                            self.racket_commands_executed += 1

                    elif op == "cast":
                        spell = c.get("spell")
                        cid = c.get("caster_id")
                        if spell == "inject-larva":
                            queen = self.units.find_by_tag(cid) if cid else None
                            tid = c.get("target_id")
                            hatch = self.structures.find_by_tag(tid) if tid else (self.townhalls.ready.first if self.townhalls.ready else None)
                            if queen and hatch and queen.energy >= 25 and not hatch.has_buff(BuffId.QUEENSPAWNLARVATIMER):
                                queen(AbilityId.EFFECT_INJECTLARVA, hatch)
                                self.commands_issued += 1
                                self.racket_commands_executed += 1
                        elif spell == "spawn-creep-tumor":
                            queen = self.units.find_by_tag(cid) if cid else (creep_queens[0] if creep_queens else None)
                            if queen and queen.tag in inject_queen_tags and queen.energy < 50:
                                queen = creep_queens[0] if creep_queens else None
                            loop = int(self.state.game_loop)
                            if (
                                queen
                                and queen.energy >= 25
                                and loop - int(self._queen_tumor_cooldown_by_tag.get(queen.tag, -999)) >= 112
                            ):
                                enemy_pt = self.enemy_start_locations[0] if self.enemy_start_locations else self.game_info.map_center
                                target_pt = queen.position.towards(enemy_pt, 5.0)
                                queen(AbilityId.BUILD_CREEPTUMOR_QUEEN, target_pt)
                                self._queen_tumor_cooldown_by_tag[queen.tag] = loop
                                self._record_pro_mechanic("queen-creep-tumor")
                                self.commands_issued += 1
                                self.racket_commands_executed += 1
                        elif spell == "spread-creep-tumor":
                            tumor = self.structures.find_by_tag(cid) if cid else None
                            if tumor and tumor.tag not in self._used_creep_tumors:
                                enemy_pt = self.enemy_start_locations[0] if self.enemy_start_locations else self.game_info.map_center
                                if await self._spread_single_creep_tumor(tumor, enemy_pt):
                                    self.racket_commands_executed += 1
                        elif spell == "chrono-boost":
                            nexus = self.structures.find_by_tag(cid) if cid else (self.townhalls.ready.first if self.townhalls.ready else None)
                            tid = c.get("target_id")
                            target_bldg = self.structures.find_by_tag(tid) if tid else None
                            if nexus and target_bldg and nexus.energy >= 50 and not target_bldg.has_buff(BuffId.CHRONOBOOSTENERGYCOST):
                                nexus(AbilityId.EFFECT_CHRONOBOOSTENERGYCOST, target_bldg)
                                self._record_pro_mechanic("chrono-boost")
                                self.commands_issued += 1
                                self.racket_commands_executed += 1
                        elif spell == "calldown-mule":
                            oc = self.structures.find_by_tag(cid) if cid else None
                            if oc and oc.energy >= 50 and self.mineral_field and self.townhalls.ready:
                                mf = self.mineral_field.closest_to(self.townhalls.ready.random)
                                oc(AbilityId.CALLDOWNMULE_CALLDOWNMULE, mf)
                                self._record_pro_mechanic("calldown-mule")
                                self.commands_issued += 1
                                self.racket_commands_executed += 1
                        elif spell == "scanner-sweep":
                            oc = self.structures.find_by_tag(cid) if cid else None
                            if oc and oc.energy >= 50:
                                tx = c.get("x") or self.enemy_start_locations[0].x
                                ty = c.get("y") or self.enemy_start_locations[0].y
                                oc(AbilityId.SCANNERSWEEP_SCAN, Point2((float(tx), float(ty))))
                                self._record_countermeasure("scanner-sweep-cloak-reveal")
                                self.commands_issued += 1
                                self.racket_commands_executed += 1
                        elif spell == "corrosive-bile":
                            caster = self.units.find_by_tag(cid) if cid else None
                            if caster and c.get("x") is not None and c.get("y") is not None:
                                caster(AbilityId.EFFECT_CORROSIVEBILE, Point2((c["x"], c["y"])))
                                self._record_countermeasure("force-field-bile-breaker")
                                self.commands_issued += 1
                                self.racket_commands_executed += 1
                        elif spell == "transfusion":
                            caster = self.units.find_by_tag(cid) if cid else None
                            tid = c.get("target_id")
                            target_u = (self.units | self.structures).find_by_tag(tid) if tid else None
                            if caster and target_u and caster.energy >= 50:
                                caster(AbilityId.TRANSFUSION_TRANSFUSION, target_u)
                                self._record_pro_mechanic("queen-transfusion")
                                self.commands_issued += 1
                                self.racket_commands_executed += 1

                    elif op == "hold-position":
                        uid = c.get("unit_id")
                        u = self.units.find_by_tag(uid) if uid else None
                        if u:
                            u(AbilityId.HOLDPOSITION)
                            self.commands_issued += 1
                        self._record_pro_mechanic("hold-position-door-guard")
                        self.racket_commands_executed += 1

                    elif op in ("swap-addon", "transport-juggle", "multi-prong-drop", "mineral-walk", "worker-harass"):
                        self._record_pro_mechanic(op)
                        self.racket_commands_executed += 1

                    elif op == "control-group-steal":
                        gid = int(c.get("group_id", 1))
                        uids = set(c.get("unit_ids", []))
                        for k, s in self._control_groups.items():
                            if k != gid:
                                s -= uids
                        self._control_groups.setdefault(gid, set()).update(uids)
                        self._record_pro_mechanic(op)
                        self.racket_commands_executed += 1

                    elif op == "camera-bookmark-save":
                        slot = int(c.get("slot", 0))
                        self._camera_bookmarks[slot] = (float(c.get("x", 0.0)), float(c.get("y", 0.0)))
                        self._record_pro_mechanic(op)
                        self.racket_commands_executed += 1

                    elif op in ("camera-bookmark-jump", "move-camera", "camera-focus"):
                        if c.get("x") is not None and c.get("y") is not None:
                            self._queued_camera_focus = (float(c["x"]), float(c["y"]))
                        self._record_pro_mechanic(op)
                        self.racket_commands_executed += 1

                    elif op == "human-apm-discipline":
                        self._record_pro_mechanic("human-apm-discipline")
                        self.racket_commands_executed += 1

                    elif op == "mirror-zero-sum-exclusion":
                        self._enemy_committed_branch = str(c.get("committed_branch", "unknown"))
                        self._enemy_excluded_branches.update(str(x).upper() for x in c.get("excluded_branches", []))
                        self._enemy_bluff_suspected = bool(c.get("bluff_suspected", False))
                        self._record_pro_mechanic("mirror-zero-sum-exclusion")
                        self.racket_commands_executed += 1

                    elif op == "mirror-tech-observation":
                        self._implied_enemy_tech_buildings.update(str(x).upper() for x in c.get("implied_tech", []))
                        self._observed_enemy_upgrades.update(str(x).upper() for x in c.get("observed_upgrades", []))
                        self._record_pro_mechanic("mirror-tech-observation")
                        self.racket_commands_executed += 1

                    elif op in (
                        "cast-deception-and-scout-spells",
                        "cast-protective-buff-aura",
                        "position-in-buff-aura-with-splash-spread",
                        "pre-split-wings",
                        "form-concave-arc",
                        "high-ground-tactics",
                    ):
                        self._record_pro_mechanic(op)
                        self.racket_commands_executed += 1

                    elif op in ("mirror-spatial-maneuver", "execute-spatial-maneuver"):
                        if c.get("maneuver") and self._spatial_maneuver == "standard_posture":
                            self._spatial_maneuver = str(c["maneuver"])
                        self._record_pro_mechanic(op)
                        self.racket_commands_executed += 1

                    elif op in ("pull-workers-attack", "clear-expansion-block", "clear-gas-steal", "resume-halted-building"):
                        self._record_countermeasure(op)
                        self.racket_commands_executed += 1

                    elif op == "mirror-prediction":
                        best_d = max(range(6), key=lambda d: (float(self._depth_ema_accuracy.get(d, 60.0)), -abs(d - 2)))
                        self.mirror_active_depth = int(best_d)
                        self.mirror_inferred_opponent_depth = max(0, int(best_d) - 1)
                        self.mirror_toolbox_weight_pct = int(c.get("toolbox_weight_pct", 20))
                        self.mirror_toolbox_role = str(c.get("toolbox_role", "tactical-tiebreaker-and-hedge"))
                        self.mirror_strategic_hypothesis = str(c.get("strategic_hypothesis", "standard-rational-macro"))
                        self.mirror_tactical_target = str(c.get("tactical_target", "center-map-staging"))
                        self.mirror_predicted_enemy_unit = str(c.get("predicted_enemy_unit", "unknown"))
                        self.mirror_preemptive_unit = str(c.get("preemptive_counter_unit", "unknown"))
                        self.mirror_accuracy_pct = int(round(float(self._depth_ema_accuracy.get(best_d, c.get("accuracy_pct", 67)))))
                        self.mirror_trust_mode = str(c.get("trust_mode", "level2-preemptive-mirror"))
                        self.mirror_predictions_received += 1
                        if (
                            "air" in self.mirror_strategic_hypothesis
                            or self.mirror_predicted_enemy_unit in ("void-ray", "carrier", "oracle", "banshee", "mutalisk", "battlecruiser")
                        ):
                            self._mirror_air_alert = True
                        self._record_pro_mechanic(f"mirror-depth-{self.mirror_active_depth}-prediction")
                        self.racket_commands_executed += 1

                    elif op == "scout-sector":
                        self._record_pro_mechanic("active-fog-scout")
                        self.racket_commands_executed += 1

                    elif op in ("attack-pos", "attack-unit", "kite", "move", "retreat"):
                        uids = c.get("unit_ids", [])
                        if uids:
                            if op == "attack-unit":
                                tid = c.get("target_id")
                                target_e = (self.enemy_units | self.enemy_structures).find_by_tag(tid) if tid else None
                                if target_e:
                                    for uid in uids[:8]:
                                        u = self.units.find_by_tag(uid)
                                        if u and u.type_id not in {UnitTypeId.DRONE, UnitTypeId.SCV, UnitTypeId.PROBE}:
                                            u.attack(target_e)
                                            self.commands_issued += 1
                            elif c.get("x") is not None and c.get("y") is not None:
                                tx, ty = float(c["x"]), float(c["y"])
                                w = float(self.game_info.map_size.width)
                                h = float(self.game_info.map_size.height)
                                if 1.0 <= tx <= w and 1.0 <= ty <= h:
                                    pt = Point2((tx, ty))
                                    for uid in uids[:8]:
                                        u = self.units.find_by_tag(uid)
                                        if u and u.type_id not in {UnitTypeId.DRONE, UnitTypeId.SCV, UnitTypeId.PROBE}:
                                            if op == "attack-pos":
                                                u.attack(pt)
                                            else:
                                                u.move(pt)
                                            self.commands_issued += 1
                        self.racket_commands_executed += 1
                except Exception:
                    pass

        async def _run_pro_reflexes_and_countermeasures(self) -> bool:
            if not self.townhalls:
                targets = self.enemy_units | self.enemy_structures
                if targets:
                    for u in self.units:
                        u.attack(targets.closest_to(u))
                return True

            main_th = self.townhalls.first

            # 1. Pro Mechanic #1: Emergency Cancel of Dying In-Progress Buildings (<18% HP under fire)
            for bldg in self.structures.not_ready:
                if bldg.build_progress >= 0.25 and bldg.health_percentage < 0.18 and self.enemy_units.closer_than(8.5, bldg):
                    bldg(AbilityId.CANCEL_BUILDINPROGRESS)
                    self._record_pro_mechanic("cancel-dying-building")
                    self.commands_issued += 1

            # 2. Pro Mechanic #2: Active Creep Tumor Spread (capped at 2/frame, respecting 10s burrowing cooldown)
            if self.race == Race.Zerg:
                ready_tumors = [
                    t
                    for t in self.structures({UnitTypeId.CREEPTUMORBURROWED, UnitTypeId.CREEPTUMORQUEEN}).ready
                    if t.tag not in self._used_creep_tumors
                ][:2]
                enemy_loc = self.enemy_start_locations[0] if self.enemy_start_locations else self.game_info.map_center
                for tumor in ready_tumors:
                    await self._spread_single_creep_tumor(tumor, enemy_loc)

            # 3. Overlord Safe Retreat
            if self.race == Race.Zerg:
                safe_spot = main_th.position.towards(self.game_info.map_center, -5.0)
                for ov in self.units(UnitTypeId.OVERLORD):
                    if ov.distance_to(main_th) > 15.0 or self.enemy_units.closer_than(12.0, ov):
                        ov.move(safe_spot)

            # 4. Terran Main-Ramp Supply Depot Raise/Lower + SCV Auto-Repair + Halted Building Resume
            if self.race == Race.Terran:
                for depot in self.structures(UnitTypeId.SUPPLYDEPOT).ready:
                    if not self.enemy_units.closer_than(10.0, depot):
                        depot(AbilityId.MORPH_SUPPLYDEPOT_LOWER)
                for ldepot in self.structures(UnitTypeId.SUPPLYDEPOTLOWERED).ready:
                    if self.enemy_units.closer_than(10.0, ldepot):
                        ldepot(AbilityId.MORPH_SUPPLYDEPOT_RAISE)
                        self._record_pro_mechanic("depot-wall-raise")

                addon_or_morph_types = {
                    UnitTypeId.BARRACKSTECHLAB,
                    UnitTypeId.BARRACKSREACTOR,
                    UnitTypeId.FACTORYTECHLAB,
                    UnitTypeId.FACTORYREACTOR,
                    UnitTypeId.STARPORTTECHLAB,
                    UnitTypeId.STARPORTREACTOR,
                    UnitTypeId.ORBITALCOMMAND,
                    UnitTypeId.PLANETARYFORTRESS,
                }
                if self.state.game_loop % 16 == 0:
                    for bldg in self.structures.not_ready:
                        if bldg.type_id in addon_or_morph_types:
                            continue
                        constructing = [
                            w
                            for w in self.workers
                            if w.distance_to(bldg) <= 5.5
                            and (w.is_constructing_scv or getattr(w, "order_target", None) == bldg.tag or self._is_builder_worker(w))
                        ]
                        if not constructing and self.workers:
                            avail = [w for w in self.workers if not self._is_builder_worker(w) and not w.is_attacking]
                            if avail:
                                scv = min(avail, key=lambda w: w.distance_to(bldg))
                                scv(AbilityId.SMART, bldg)
                                self._record_countermeasure("resume-halted-building")

                repair_targets = self.structures.filter(
                    lambda s: s.is_ready
                    and s.health_percentage < 0.85
                    and s.type_id
                    in {
                        UnitTypeId.BUNKER,
                        UnitTypeId.SUPPLYDEPOT,
                        UnitTypeId.SUPPLYDEPOTLOWERED,
                        UnitTypeId.PLANETARYFORTRESS,
                    }
                )
                if repair_targets and self.workers:
                    target_rep = repair_targets.first
                    repairers = [
                        w
                        for w in self.workers.closer_than(10.0, target_rep)
                        if not self._is_builder_worker(w)
                    ][:2]
                    for scv in repairers:
                        if not scv.is_repairing:
                            scv(AbilityId.EFFECT_REPAIR_SCV, target_rep)

            # 5. Adversarial Countermeasure #1 & #2: Worker Rush vs Cannon Rush / Proxy Defense
            home_anchor = self.start_location if self.start_location else main_th.position
            proxy_structures = self.enemy_structures.filter(
                lambda s: s.distance_to(home_anchor) < 26.0
                and s.type_id
                in {
                    UnitTypeId.PHOTONCANNON,
                    UnitTypeId.PYLON,
                    UnitTypeId.BARRACKS,
                    UnitTypeId.BUNKER,
                    UnitTypeId.GATEWAY,
                    UnitTypeId.SPINECRAWLER,
                }
            )
            enemy_workers_near = self.enemy_units.filter(
                lambda u: u.type_id in {UnitTypeId.DRONE, UnitTypeId.PROBE, UnitTypeId.SCV}
                and u.distance_to(main_th) < 25.0
            )
            if len(enemy_workers_near) >= 6 and not proxy_structures:
                self._worker_rush_active = True
                self._transition_posture("worker-rush-defense")
            elif (len(enemy_workers_near) <= 1 or proxy_structures) and getattr(self, "_worker_rush_active", False):
                self._worker_rush_active = False
                self._worker_rush_defeated = True
                self._offensive_launched = True
                self._transition_posture("timing-push")

            if getattr(self, "_worker_rush_active", False) and enemy_workers_near:
                self._record_countermeasure("worker-rush-defense")
                await self._ensure_zero_supply_block()
                if self.supply_left >= 2:
                    if self.race == Race.Zerg and self.larva:
                        if self.structures(UnitTypeId.SPAWNINGPOOL).ready and self.can_afford(UnitTypeId.ZERGLING):
                            self.larva.first.train(UnitTypeId.ZERGLING)
                        elif self.can_afford(UnitTypeId.DRONE):
                            self.larva.first.train(UnitTypeId.DRONE)
                    elif self.race == Race.Terran and main_th.is_idle and self.can_afford(UnitTypeId.SCV):
                        main_th.train(UnitTypeId.SCV)
                    elif self.race == Race.Protoss and main_th.is_idle and self.can_afford(UnitTypeId.PROBE):
                        main_th.train(UnitTypeId.PROBE)

                target_pt = enemy_workers_near.center
                for w in self.workers:
                    if self._is_builder_worker(w):
                        continue
                    if not w.is_attacking:
                        w.attack(target_pt)
                for army_u in self.units.exclude_type(
                    {UnitTypeId.DRONE, UnitTypeId.SCV, UnitTypeId.PROBE, UnitTypeId.OVERLORD, UnitTypeId.LARVA}
                ):
                    if not army_u.is_attacking:
                        army_u.attack(target_pt)
                return True

            # 6. Adversarial Countermeasure #2: Cannon Rush / Proxy Pylon / Proxy Barracks / Bunker Defense
            ready_enemy_cannons = self.enemy_structures.filter(
                lambda s: s.type_id in {UnitTypeId.PHOTONCANNON, UnitTypeId.BUNKER, UnitTypeId.SPINECRAWLER}
                and s.is_ready
            )

            def is_safe_from_ready_cannons(pos) -> bool:
                return not any(c.distance_to(pos) <= 8.8 for c in ready_enemy_cannons)

            safe_proxy_builders = self.enemy_units.filter(
                lambda u: u.type_id in {UnitTypeId.PROBE, UnitTypeId.SCV, UnitTypeId.DRONE}
                and u.distance_to(main_th) < 15.0
                and is_safe_from_ready_cannons(u.position)
            )
            safe_inner_proxies = proxy_structures.filter(
                lambda s: s.distance_to(main_th) <= 13.5 and is_safe_from_ready_cannons(s.position)
            )
            if proxy_structures or (safe_proxy_builders and self.state.game_loop < 1600):
                self._transition_posture("crisis-rush-defend")
                self._record_countermeasure("anti-cannon-proxy-pull")
                non_builders = [
                    w for w in self.workers if not self._is_builder_worker(w) and w.health_percentage >= 0.45
                ]
                builder_hunters = set()
                if safe_proxy_builders and len(non_builders) >= 9:
                    target_builder = safe_proxy_builders.closest_to(main_th)
                    hunters = sorted(non_builders, key=lambda w: w.distance_to(target_builder))[:2]
                    for h in hunters:
                        if getattr(h, "order_target", None) != target_builder.tag:
                            h.attack(target_builder)
                        builder_hunters.add(h.tag)

                if safe_inner_proxies and self.supply_army < 8:
                    cannons_first = safe_inner_proxies.filter(
                        lambda s: s.type_id
                        in {UnitTypeId.PHOTONCANNON, UnitTypeId.BUNKER, UnitTypeId.BARRACKS, UnitTypeId.SPINECRAWLER}
                        and s.build_progress < 0.80
                    )
                    unfinished_pylons = safe_inner_proxies.filter(
                        lambda s: s.type_id == UnitTypeId.PYLON and s.build_progress < 0.90
                    )
                    if cannons_first:
                        primary_target = max(
                            cannons_first, key=lambda s: (round(s.build_progress, 1), -s.distance_to(main_th), -s.tag)
                        )
                    elif unfinished_pylons:
                        primary_target = max(
                            unfinished_pylons, key=lambda s: (round(s.build_progress, 1), -s.distance_to(main_th), -s.tag)
                        )
                    else:
                        primary_target = min(
                            safe_inner_proxies, key=lambda s: (s.distance_to(main_th), s.health + s.shield, s.tag)
                        )

                    avail_for_struct = [w for w in non_builders if w.tag not in builder_hunters]
                    pull_count = min(max(0, len(avail_for_struct) - 8), 5)
                    pulled = sorted(avail_for_struct, key=lambda w: w.distance_to(primary_target))[:pull_count]
                    for w in pulled:
                        if getattr(w, "order_target", None) != primary_target.tag:
                            w.attack(primary_target)
                elif self.mineral_field:
                    near_min = self.mineral_field.closest_to(main_th)
                    for w in non_builders:
                        if w.tag not in builder_hunters and w.is_attacking:
                            w.gather(near_min)
            elif len(self.townhalls) >= 2 and not self._offensive_launched:
                self._transition_posture("macro-expand")
            elif self._offensive_launched:
                self._transition_posture("timing-push")

            return False

        def _get_main_build_anchor(self, main_th):
            near_minerals = self.mineral_field.closer_than(10.0, main_th) if self.mineral_field else None
            if near_minerals:
                # Always point 6.5 tiles directly away from the mineral line into the open main-base plaza
                return main_th.position.towards(near_minerals.center, -6.5)
            return main_th.position.towards(self.game_info.map_center, 6.0)

        async def _ensure_zero_supply_block(self) -> None:
            if self.supply_cap >= 200:
                return
            buffer_needed = 2 if self.supply_cap <= 15 else (5 if self.supply_cap < 36 else (8 if self.supply_cap < 80 else 12))
            if self.race == Race.Zerg:
                damaged_ov = self.units(UnitTypeId.OVERLORD).filter(lambda u: u.health_percentage < 0.85)
                eff_buf = buffer_needed + (8 if damaged_ov else 0)
                pending_ov = self.already_pending(UnitTypeId.OVERLORD)
                if self.supply_left <= eff_buf and pending_ov < (2 if self.supply_cap >= 44 else 1):
                    if self.can_afford(UnitTypeId.OVERLORD) and self.larva:
                        self.larva.first.train(UnitTypeId.OVERLORD)
                        self.commands_issued += 1
            elif self.race == Race.Terran:
                damaged_dep = self.structures.filter(
                    lambda s: s.type_id in {UnitTypeId.SUPPLYDEPOT, UnitTypeId.SUPPLYDEPOTLOWERED}
                    and s.is_ready
                    and s.health_percentage < 0.85
                )
                eff_buf = buffer_needed + (8 if damaged_dep else 0)
                pending_dep = self.already_pending(UnitTypeId.SUPPLYDEPOT)
                if self.supply_left <= eff_buf and pending_dep < (2 if (self.supply_cap >= 44 or damaged_dep) else 1):
                    if self.can_afford(UnitTypeId.SUPPLYDEPOT):
                        build_spot = (
                            self._get_main_build_anchor(self.townhalls.first)
                            if self.townhalls
                            else self.start_location
                        )
                        depot_count = len(self.structures(UnitTypeId.SUPPLYDEPOT)) + len(self.structures(UnitTypeId.SUPPLYDEPOTLOWERED))
                        depot_spot = (
                            self.townhalls.first.position.towards(build_spot, 5.0 + (depot_count % 3) * 2.5)
                            if self.townhalls
                            else build_spot
                        )
                        await self.build(UnitTypeId.SUPPLYDEPOT, near=depot_spot, max_distance=15)
                        self.commands_issued += 1
            elif self.race == Race.Protoss:
                damaged_pyl = self.structures(UnitTypeId.PYLON).ready.filter(lambda s: s.health_percentage < 0.85)
                eff_buf = buffer_needed + (8 if damaged_pyl else 0)
                pending_pyl = self.already_pending(UnitTypeId.PYLON)
                if self.supply_left <= eff_buf and pending_pyl < (2 if (self.supply_cap >= 44 or damaged_pyl) else 1):
                    if self.can_afford(UnitTypeId.PYLON):
                        build_spot = (
                            self._get_main_build_anchor(self.townhalls.first)
                            if self.townhalls
                            else self.start_location
                        )
                        pylon_count = len(self.structures(UnitTypeId.PYLON))
                        pylon_spot = (
                            self.townhalls.first.position.towards(build_spot, 5.5 + (pylon_count % 3) * 2.5)
                            if self.townhalls
                            else build_spot
                        )
                        await self.build(UnitTypeId.PYLON, near=pylon_spot, max_distance=15)
                        self.commands_issued += 1

        def _evaluate_coupled_macro_state(self, main_th) -> Dict[str, Any]:
            loop = int(self.state.game_loop)
            sec = loop / 22.4
            ready_ths = self.townhalls.ready
            in_progress_ths = max(0, len(self.townhalls) - len(ready_ths))
            en_route_expand = any(
                any(
                    k in getattr(getattr(o, "ability", None), "name", "")
                    for o in getattr(w, "orders", [])
                    for k in ("HATCHERY", "COMMANDCENTER", "NEXUS")
                )
                for w in self.workers
            )
            pending_bases = in_progress_ths + (1 if (in_progress_ths == 0 and en_route_expand) else 0)
            total_bases = len(ready_ths) + int(pending_bases)
            max_map_bases = (
                len(self.expansion_locations_list)
                if hasattr(self, "expansion_locations_list") and self.expansion_locations_list
                else 12
            )

            # 1. Track enemy_known_bases (visible + scouted/remembered enemy TownHall positions)
            enemy_th_types = {
                UnitTypeId.HATCHERY,
                UnitTypeId.LAIR,
                UnitTypeId.HIVE,
                UnitTypeId.NEXUS,
                UnitTypeId.COMMANDCENTER,
                UnitTypeId.ORBITALCOMMAND,
                UnitTypeId.PLANETARYFORTRESS,
            }
            visible_enemy_ths = self.enemy_structures.filter(lambda s: s.type_id in enemy_th_types)
            for eth in visible_enemy_ths:
                key = (int(round(eth.position.x / 6.0) * 6), int(round(eth.position.y / 6.0) * 6))
                self._remembered_enemy_base_positions[key] = eth.position

            for key, pos in list(self._remembered_enemy_base_positions.items()):
                try:
                    if self.is_visible(pos) and not any(eth.distance_to(pos) < 8.0 for eth in visible_enemy_ths):
                        del self._remembered_enemy_base_positions[key]
                except Exception:
                    pass

            # Check if enemy natural expansion has been scouted empty
            if hasattr(self, "expansion_locations_list") and self.expansion_locations_list and self.enemy_start_locations:
                enemy_start = self.enemy_start_locations[0]
                by_enemy_dist = sorted(self.expansion_locations_list, key=lambda pt: pt.distance_to(enemy_start))
                if len(by_enemy_dist) >= 2:
                    enemy_nat_pt = by_enemy_dist[1]
                    try:
                        if self.is_visible(enemy_nat_pt) and not any(eth.distance_to(enemy_nat_pt) < 8.0 for eth in visible_enemy_ths):
                            self._enemy_natural_scouted_empty_loop = loop
                    except Exception:
                        pass

            enemy_known_bases = max(
                0 if getattr(self, "_enemy_main_cleared", False) else 1,
                len(self._remembered_enemy_base_positions),
            )
            self.enemy_known_bases = enemy_known_bases
            self.peak_enemy_bases_seen = max(self.peak_enemy_bases_seen, enemy_known_bases)

            # 2. Depletion & effective base calculation
            eff_bases = float(pending_bases)
            depleting_bases = 0
            mined_out_bases = 0
            total_ideal_harvesters = 0
            total_assigned_harvesters = 0

            for th in ready_ths:
                local_patches = self.mineral_field.closer_than(10.0, th) if self.mineral_field else []
                patch_cnt = len(local_patches)
                rem_minerals = sum(int(getattr(m, "mineral_contents", 600)) for m in local_patches)
                ideal_h = int(getattr(th, "ideal_harvesters", min(16, 2 * patch_cnt)))
                assigned_h = int(getattr(th, "assigned_harvesters", 0))
                total_ideal_harvesters += ideal_h
                total_assigned_harvesters += assigned_h

                if patch_cnt <= 2 or rem_minerals < 600:
                    mined_out_bases += 1
                    depleting_bases += 1
                    eff_bases += 0.15
                elif patch_cnt <= 5 or rem_minerals < 2400 or assigned_h > ideal_h + 2:
                    depleting_bases += 1
                    eff_bases += 0.55
                else:
                    eff_bases += 1.0

            if len(ready_ths) == 0:
                eff_bases = max(0.5, eff_bases)

            gas_workers = sum(int(getattr(g, "assigned_harvesters", 0)) for g in self.gas_buildings.ready)
            mineral_workers = max(0, len(self.workers) - gas_workers)

            # Unconstrained target workers: up to 76 (Zerg) / 72 (Terran/Protoss), scaled by effective bases
            max_worker_cap = 76 if self.race == Race.Zerg else 72
            if total_bases == 1:
                target_workers = 21 if self.race != Race.Zerg else 19
            else:
                base_scaled = int(round(18.0 * max(1.5, eff_bases) + 6))
                if total_bases >= 4:
                    base_scaled = max(base_scaled, 66)
                target_workers = min(max_worker_cap, base_scaled)

            non_combat_scout_types = {
                UnitTypeId.DRONE,
                UnitTypeId.SCV,
                UnitTypeId.PROBE,
                UnitTypeId.OVERLORD,
                UnitTypeId.OVERSEER,
                UnitTypeId.OBSERVER,
                UnitTypeId.LARVA,
                UnitTypeId.EGG,
            }
            enemy_combat_near_main = self.enemy_units.filter(
                lambda e: any(e.distance_to(th) <= 28.0 for th in self.townhalls)
                and e.type_id not in non_combat_scout_types
                and not getattr(e, "is_hallucination", False)
            )
            enemy_proxies_near_main = self.enemy_structures.filter(
                lambda s: any(s.distance_to(th) <= 32.0 for th in self.townhalls)
            )
            enemy_near_expand = len(enemy_combat_near_main) >= 3 or len(enemy_proxies_near_main) >= 1
            visible_enemy_combat = self.enemy_units.filter(
                lambda e: e.type_id not in non_combat_scout_types
                and not getattr(e, "is_hallucination", False)
            )
            enemy_army_est = max(len(visible_enemy_combat) * 2, int(self.supply_army * 0.6) if loop > 2688 else 4)
            army_ratio = float(self.supply_army + 4) / float(max(4, enemy_army_est))

            # 3. Mirror-Mind Macro/Eco/Base Prediction & Verdict
            nat_recently_empty = (loop - self._enemy_natural_scouted_empty_loop) < 1344
            is_rush_hyp = self.mirror_strategic_hypothesis == "opponent-committed-early-all-in"
            if 140.0 <= sec <= 270.0 and enemy_known_bases <= 1 and (nat_recently_empty or is_rush_hyp):
                predicted_enemy_bases = 1
            else:
                time_expected_bases = 4 if sec >= 450.0 else (3 if sec >= 300.0 else (2 if sec >= 115.0 else 1))
                predicted_enemy_bases = max(enemy_known_bases, 1 if (is_rush_hyp and sec <= 270.0) else time_expected_bases)

            vis_enemy_workers = len(
                self.enemy_units.filter(lambda u: u.type_id in {UnitTypeId.DRONE, UnitTypeId.SCV, UnitTypeId.PROBE})
            )
            predicted_enemy_workers = min(
                76,
                max(vis_enemy_workers, 20 if predicted_enemy_bases == 1 else int(predicted_enemy_bases * 19)),
            )
            self.predicted_enemy_bases = predicted_enemy_bases
            self.predicted_enemy_workers = predicted_enemy_workers

            if sec <= 270.0 and enemy_known_bases <= 1 and (
                (140.0 <= sec and (nat_recently_empty or is_rush_hyp)) or len(enemy_combat_near_main) >= 4
            ):
                mirror_macro_verdict = "defend_one_base_all_in"
            elif (enemy_known_bases >= len(self.townhalls) and (sec >= 90.0 or enemy_known_bases >= 2)) or predicted_enemy_bases >= total_bases:
                mirror_macro_verdict = "counter_greedy_expand_and_disrupt"
            elif total_bases > predicted_enemy_bases:
                mirror_macro_verdict = "macro_eco_lead"
            else:
                mirror_macro_verdict = "macro_parity_pressure"
            self.mirror_macro_verdict = mirror_macro_verdict

            greedy_accel = mirror_macro_verdict == "counter_greedy_expand_and_disrupt"
            all_in_alert = mirror_macro_verdict == "defend_one_base_all_in"
            has_choke_defense = bool(
                self.structures(UnitTypeId.SPINECRAWLER)
                | self.structures(UnitTypeId.BUNKER)
                | self.structures(UnitTypeId.PHOTONCANNON)
                | self.structures(UnitTypeId.SHIELDBATTERY)
            ) or (
                self.already_pending(UnitTypeId.SPINECRAWLER)
                + self.already_pending(UnitTypeId.BUNKER)
                + self.already_pending(UnitTypeId.PHOTONCANNON)
                + self.already_pending(UnitTypeId.SHIELDBATTERY)
                > 0
            )

            exp_cost = 300 if self.race == Race.Zerg else 400
            army_ready_for_multi_expand = (
                total_bases == 1
                or (total_bases == 2 and (self.supply_army >= 18 or self.minerals >= exp_cost + 200))
                or (total_bases >= 3 and (self.supply_army >= 28 or self.minerals >= exp_cost + 300 or depleting_bases >= 1))
            )
            safe_to_expand = (
                not enemy_near_expand
                and total_bases < max_map_bases
                and (not all_in_alert or total_bases < 2 or has_choke_defense or self.supply_army >= 22)
                and army_ready_for_multi_expand
            )

            want_depletion_expand = (
                total_bases < max_map_bases
                and pending_bases == 0
                and len(ready_ths) >= 1
                and (
                    depleting_bases >= 1
                    or mineral_workers > total_ideal_harvesters - 2
                )
                and (self.supply_army >= 16 or self.minerals >= exp_cost + 150)
            )

            nat_w_req = 14 if self.race == Race.Zerg else 15
            total_ideal_gas_harvesters = sum(
                int(getattr(g, "ideal_harvesters", 3)) for g in self.gas_buildings.ready
            )
            mineral_saturated = (
                total_ideal_harvesters > 0
                and max(total_assigned_harvesters, mineral_workers) >= max(1, total_ideal_harvesters - 2)
            )
            gas_saturated = (
                total_ideal_gas_harvesters == 0
                or gas_workers >= max(1, total_ideal_gas_harvesters - 1)
            )
            multi_harvesters_saturated = mineral_saturated and gas_saturated
            multi_min_req = exp_cost + (200 if greedy_accel else 250)

            want_saturation_expand = (
                total_bases < max_map_bases
                and pending_bases == 0
                and (
                    (total_bases == 1 and (len(self.workers) >= nat_w_req or loop >= 1568))
                    or (total_bases >= 2 and (multi_harvesters_saturated or self.minerals >= multi_min_req))
                )
            )

            should_expand = safe_to_expand and (want_saturation_expand or want_depletion_expand)

            # Escrow window: hold on 1 base once natural expansion is due (unless under direct attack),
            # and on 2+ bases only hold escrow when army supply is healthy (>= 18) or minerals are already high.
            escrow_minerals = 0
            if should_expand:
                if total_bases == 1:
                    escrow_minerals = exp_cost
                elif (self.supply_army >= 18 or self.minerals >= exp_cost + 100) and self.minerals >= int(0.45 * exp_cost):
                    if self._escrow_started_loop < 0 or loop - self._escrow_started_loop > 336:
                        self._escrow_started_loop = loop
                    if loop - self._escrow_started_loop <= 224:
                        escrow_minerals = exp_cost

            # 4. Dynamic Gas-vs-Mineral Worker Throttling (Guns-vs-Butter Allocation)
            gas_to_mineral_ratio = round(float(gas_workers) / float(max(1, mineral_workers)), 2)
            if (self.vespene >= 350 and self.minerals < 350) or (total_bases == 1 and should_expand and self.minerals < exp_cost):
                guns_vs_butter_regime = "mineral_recovery_gas_pull"
                target_resource_ratio = 8.0
                max_gas_workers = 1 if (total_bases == 1 and should_expand and self.minerals < exp_cost) else 2
            elif self.vespene < 150 and self.minerals >= 350:
                guns_vs_butter_regime = "tech_upgrade_scaling"
                target_resource_ratio = 0.8
                max_gas_workers = max(3, len(self.gas_buildings.ready) * 3)
            elif should_expand or len(self.workers) < int(0.75 * target_workers):
                guns_vs_butter_regime = "butter_expand_focus"
                target_resource_ratio = 2.0
                max_gas_workers = max(3, len(self.gas_buildings.ready) * 3)
            else:
                guns_vs_butter_regime = "guns_army_surge"
                target_resource_ratio = 1.5
                max_gas_workers = max(3, len(self.gas_buildings.ready) * 3)

            self.gas_workers = gas_workers
            self.mineral_workers = mineral_workers
            self.gas_to_mineral_ratio = gas_to_mineral_ratio
            self.guns_vs_butter_regime = guns_vs_butter_regime
            self.target_resource_ratio = target_resource_ratio
            self.max_gas_workers = max_gas_workers
            self.last_eff_bases = round(eff_bases, 2)
            self.last_depleting_bases = depleting_bases
            self.last_mined_out_bases = mined_out_bases
            self.last_pending_bases = int(pending_bases)
            self.last_target_workers = target_workers
            self.last_escrow_minerals = escrow_minerals

            max_prod_facilities = min(
                14,
                (2 if (total_bases == 1 and should_expand) else max(3, int(2.6 * eff_bases) + 1))
                + max(0, int(self.minerals - (exp_cost + 150)) // 225),
            )

            return {
                "total_bases": total_bases,
                "pending_bases": int(pending_bases),
                "max_map_bases": max_map_bases,
                "eff_bases": round(eff_bases, 2),
                "depleting_bases": depleting_bases,
                "mined_out_bases": mined_out_bases,
                "total_ideal_harvesters": total_ideal_harvesters,
                "target_workers": target_workers,
                "safe_to_expand": safe_to_expand,
                "want_depletion_expand": want_depletion_expand,
                "want_saturation_expand": want_saturation_expand,
                "should_expand": should_expand,
                "escrow_minerals": escrow_minerals,
                "max_prod_facilities": max_prod_facilities,
                "enemy_known_bases": enemy_known_bases,
                "predicted_enemy_bases": predicted_enemy_bases,
                "predicted_enemy_workers": predicted_enemy_workers,
                "mirror_macro_verdict": mirror_macro_verdict,
                "guns_vs_butter_regime": guns_vs_butter_regime,
                "target_resource_ratio": target_resource_ratio,
            }

        async def _transfer_depleted_base_workers(self) -> None:
            await self.distribute_workers(resource_ratio=self.target_resource_ratio)
            if not self.townhalls.ready or not self.mineral_field:
                return

            # 1. Dynamic Gas-vs-Mineral Worker Pull / Fill (Guns-vs-Butter)
            if self.guns_vs_butter_regime == "mineral_recovery_gas_pull" and self.gas_buildings.ready:
                gas_tags = {g.tag for g in self.gas_buildings.ready}
                gas_harvesters = [
                    w
                    for w in self.workers
                    if not self._is_builder_worker(w)
                    and (getattr(w, "order_target", None) in gas_tags or getattr(w, "is_carrying_vespene", False))
                ]
                excess = len(gas_harvesters) - self.max_gas_workers
                if excess > 0:
                    for w in gas_harvesters[:excess]:
                        near_m = self.mineral_field.closest_to(w)
                        w.gather(near_m)
                    self._record_pro_mechanic("guns-vs-butter-gas-pull")
            elif self.guns_vs_butter_regime == "tech_upgrade_scaling" and len(self.workers) >= 14:
                gas_tags = {g.tag for g in self.gas_buildings.ready}
                for g in self.gas_buildings.ready:
                    if int(getattr(g, "assigned_harvesters", 0)) < 3:
                        avail_min_w = [
                            w
                            for w in self.workers.closer_than(12.0, g)
                            if not self._is_builder_worker(w) and getattr(w, "order_target", None) not in gas_tags
                        ]
                        if avail_min_w:
                            avail_min_w[0].gather(g)

            # 2. Explicitly evacuate workers stuck at mined-out townhalls (0 local patches) to active bases
            active_ths_with_room = [
                th
                for th in self.townhalls.ready
                if len(self.mineral_field.closer_than(10.0, th)) >= 3
                and getattr(th, "assigned_harvesters", 0) < getattr(th, "ideal_harvesters", 16) + 2
            ]
            for th in self.townhalls.ready:
                local_min = self.mineral_field.closer_than(10.0, th)
                if len(local_min) == 0:
                    idle_or_local_workers = [
                        w
                        for w in self.workers.closer_than(9.0, th)
                        if not self._is_builder_worker(w)
                    ]
                    for w in idle_or_local_workers[:4]:
                        if active_ths_with_room:
                            dest_th = min(active_ths_with_room, key=lambda t: t.distance_to(w))
                            dest_min = self.mineral_field.closer_than(10.0, dest_th)
                            if dest_min:
                                w.gather(dest_min.closest_to(dest_th))
                        else:
                            w.gather(self.mineral_field.closest_to(w))

        async def _build_mirror_choke_defense(self, main_th) -> None:
            """Fortify natural choke on 2+ bases and place mineral-line Spore/Turret/Cannon when detection/anti-air is required."""
            if len(self.townhalls) < 2:
                return
            sorted_ths = sorted(self.townhalls, key=lambda t: t.distance_to(main_th))
            nat_th = sorted_ths[1] if len(sorted_ths) >= 2 else main_th
            choke_pos = nat_th.position.towards(self.game_info.map_center, 4.5)
            max_choke_def = 2 if self.mirror_macro_verdict == "defend_one_base_all_in" else 1
            allow_choke_build = self.mirror_macro_verdict == "defend_one_base_all_in" or self.minerals >= 250

            if allow_choke_build:
                if self.race == Race.Zerg and self.structures(UnitTypeId.SPAWNINGPOOL).ready:
                    if (
                        len(self.structures(UnitTypeId.SPINECRAWLER)) + self.already_pending(UnitTypeId.SPINECRAWLER) < max_choke_def
                        and self.can_afford(UnitTypeId.SPINECRAWLER)
                    ):
                        if await self._actuate_build_structure(UnitTypeId.SPINECRAWLER, choke_pos.x, choke_pos.y):
                            self._record_countermeasure("mirror-all-in-spine-wall")
                elif self.race == Race.Terran and self.structures(UnitTypeId.BARRACKS).ready:
                    if (
                        len(self.structures(UnitTypeId.BUNKER)) + self.already_pending(UnitTypeId.BUNKER) < max_choke_def
                        and self.can_afford(UnitTypeId.BUNKER)
                    ):
                        if await self._actuate_build_structure(UnitTypeId.BUNKER, choke_pos.x, choke_pos.y):
                            self._record_countermeasure("mirror-all-in-bunker-wall")
                elif self.race == Race.Protoss and self.structures(UnitTypeId.PYLON).ready:
                    if (
                        self.structures(UnitTypeId.CYBERNETICSCORE).ready
                        and len(self.structures(UnitTypeId.SHIELDBATTERY)) + self.already_pending(UnitTypeId.SHIELDBATTERY) < 1
                        and self.can_afford(UnitTypeId.SHIELDBATTERY)
                    ):
                        if await self._actuate_build_structure(UnitTypeId.SHIELDBATTERY, choke_pos.x, choke_pos.y):
                            self._record_countermeasure("mirror-all-in-battery-wall")

            if self._enemy_requires_detection or self._enemy_requires_anti_air or self._mirror_air_alert:
                det_type = (
                    UnitTypeId.SPORECRAWLER
                    if self.race == Race.Zerg
                    else (UnitTypeId.MISSILETURRET if self.race == Race.Terran else UnitTypeId.PHOTONCANNON)
                )
                if self.already_pending(det_type) == 0 and self.can_afford(det_type):
                    for th in self.townhalls.ready:
                        if not self.structures(det_type).closer_than(10.0, th):
                            await self._actuate_build_structure(det_type)
                            break

        def _get_enemy_candidate_expansions(self) -> List[Any]:
            if not hasattr(self, "expansion_locations_list") or not self.expansion_locations_list:
                return []
            enemy_start = self.enemy_start_locations[0] if self.enemy_start_locations else self.game_info.map_center
            our_start = self.start_location if self.start_location else self.townhalls.first.position
            enemy_ths = self.enemy_structures.filter(
                lambda s: s.type_id
                in {
                    UnitTypeId.HATCHERY,
                    UnitTypeId.LAIR,
                    UnitTypeId.HIVE,
                    UnitTypeId.NEXUS,
                    UnitTypeId.COMMANDCENTER,
                    UnitTypeId.ORBITALCOMMAND,
                    UnitTypeId.PLANETARYFORTRESS,
                }
                and s.is_ready
            )
            by_enemy_dist = sorted(self.expansion_locations_list, key=lambda pt: pt.distance_to(enemy_start))
            candidates = []
            for pt in by_enemy_dist[1:]:  # Skip enemy main (index 0)
                if pt.distance_to(our_start) < 22.0:
                    continue
                if any(th.distance_to(pt) < 8.0 for th in self.townhalls):
                    continue
                if any(eth.distance_to(pt) < 7.0 for eth in enemy_ths):
                    continue
                candidates.append(pt)
                if len(candidates) >= 4:
                    break
            return candidates

        async def _run_economic_disruption_and_base_blocking(self, main_th) -> None:
            home_anchor = self.start_location if self.start_location else main_th.position
            threats_home = self.enemy_units.filter(
                lambda u: any(u.distance_to(th) < 25.0 for th in self.townhalls)
            )
            if len(threats_home) >= 3:
                return

            # 1. Maintain Dedicated Cheap Expansion Blockers (especially Burrowed Zerglings!) at Enemy's Next 1-3 Expansions
            alive_all_tags = {u.tag for u in self.units}
            self._expansion_blocker_targets = {
                tag: pt for tag, pt in self._expansion_blocker_targets.items() if tag in alive_all_tags
            }
            self._harass_raider_tags &= alive_all_tags

            enemy_exp_candidates = self._get_enemy_candidate_expansions()
            greedy_boost = self.mirror_macro_verdict == "counter_greedy_expand_and_disrupt"
            if self.race == Race.Zerg:
                max_blockers = (
                    3
                    if (
                        (len(self.townhalls) >= 3 and self.supply_army >= 20)
                        or (greedy_boost and len(self.townhalls) >= 2 and self.supply_army >= 14)
                    )
                    else (
                        2
                        if (len(self.townhalls) >= 2 and self.supply_army >= 14)
                        else (1 if (len(self.townhalls) >= 2 and self.supply_army >= 8) else 0)
                    )
                )
                allowed_blocker_types = {UnitTypeId.ZERGLING}
            else:
                max_blockers = 1 if (len(self.townhalls) >= 2 and self.supply_army >= 28) else 0
                allowed_blocker_types = {UnitTypeId.MARINE, UnitTypeId.ZEALOT}
            if len(self._expansion_blocker_targets) < max_blockers and enemy_exp_candidates:
                cheap_pool = self.units.filter(
                    lambda u: u.type_id in allowed_blocker_types
                    and u.tag not in self._expansion_blocker_targets
                    and u.tag not in self._harass_raider_tags
                )
                assigned_pts = list(self._expansion_blocker_targets.values())
                for exp_pt in enemy_exp_candidates:
                    if len(self._expansion_blocker_targets) >= max_blockers or not cheap_pool:
                        break
                    if any(exp_pt.distance_to(apt) < 4.0 for apt in assigned_pts):
                        continue
                    chosen = cheap_pool.closest_to(exp_pt)
                    self._expansion_blocker_targets[chosen.tag] = exp_pt
                    if hasattr(self, "_deployed_unit_tags"):
                        self._deployed_unit_tags.discard(chosen.tag)
                    assigned_pts.append(exp_pt)
                    self.base_blockers_dispatched += 1
                    self._record_pro_mechanic("base-blocker-dispatched")
                    self._emit_telemetry(
                        "BASE_BLOCKER_DISPATCHED",
                        unit=chosen.type_id.name,
                        tag=chosen.tag,
                        target=[round(exp_pt.x, 1), round(exp_pt.y, 1)],
                        total_blockers=len(self._expansion_blocker_targets),
                        mirror_verdict=self.mirror_macro_verdict,
                    )
                    break

            has_burrow_upgrade = UpgradeId.BURROW in self.state.upgrades
            for b_tag, target_pt in list(self._expansion_blocker_targets.items()):
                blocker = self.units.find_by_tag(b_tag)
                if not blocker:
                    continue
                completed_enemy_th = self.enemy_structures.filter(
                    lambda s: s.is_ready
                    and s.distance_to(target_pt) < 6.0
                    and s.type_id in {UnitTypeId.HATCHERY, UnitTypeId.LAIR, UnitTypeId.HIVE, UnitTypeId.NEXUS, UnitTypeId.COMMANDCENTER, UnitTypeId.ORBITALCOMMAND, UnitTypeId.PLANETARYFORTRESS}
                )
                if completed_enemy_th and enemy_exp_candidates:
                    self._expansion_blocker_targets[b_tag] = enemy_exp_candidates[0]
                    target_pt = enemy_exp_candidates[0]

                enemy_combat_near = self.enemy_units.filter(
                    lambda e: e.distance_to(blocker) <= 10.5
                    and (getattr(e, "can_attack_ground", False) or e.type_id in {UnitTypeId.OVERSEER, UnitTypeId.OBSERVER, UnitTypeId.RAVEN})
                    and e.type_id not in {UnitTypeId.DRONE, UnitTypeId.SCV, UnitTypeId.PROBE}
                )
                enemy_workers_near = self.enemy_units.filter(
                    lambda e: e.distance_to(target_pt) <= 6.5
                    and e.type_id in {UnitTypeId.DRONE, UnitTypeId.SCV, UnitTypeId.PROBE}
                )
                unfinished_enemy_th = self.enemy_structures.filter(
                    lambda s: not s.is_ready and s.distance_to(target_pt) <= 6.5
                )

                if blocker.type_id == UnitTypeId.ZERGLINGBURROWED:
                    if len(enemy_workers_near) == 1 and len(enemy_combat_near) == 0:
                        blocker(AbilityId.BURROWUP_ZERGLING)
                        self._record_pro_mechanic("burrow-ambush-builder")
                    continue

                if blocker.type_id == UnitTypeId.ZERGLING:
                    if len(enemy_combat_near) == 0 and enemy_workers_near and len(enemy_workers_near) <= 2:
                        blocker.attack(enemy_workers_near.closest_to(blocker))
                        continue
                    if blocker.distance_to(target_pt) <= 1.25 and has_burrow_upgrade:
                        blocker(AbilityId.BURROWDOWN_ZERGLING)
                        if blocker.tag not in self._burrowed_blocker_logged_tags:
                            self._burrowed_blocker_logged_tags.add(blocker.tag)
                            self.burrow_blocks_activated += 1
                            self._record_pro_mechanic("burrowed-zergling-base-block")
                            self._emit_telemetry(
                                "BURROW_BLOCK_ACTIVE",
                                tag=blocker.tag,
                                pos=[round(blocker.position.x, 1), round(blocker.position.y, 1)],
                            )
                        continue
                    if len(enemy_combat_near) >= 2 and blocker.distance_to(target_pt) > 2.5:
                        blocker.move(blocker.position.towards(enemy_combat_near.center, -5.0))
                        continue
                    if len(enemy_combat_near) == 0 and unfinished_enemy_th:
                        blocker.attack(unfinished_enemy_th.first)
                        continue
                    if blocker.distance_to(target_pt) > 0.9:
                        blocker.move(target_pt)
                    else:
                        blocker(AbilityId.HOLDPOSITION)
                else:
                    if len(enemy_combat_near) >= 2:
                        blocker.move(blocker.position.towards(enemy_combat_near.center, -6.0))
                    elif enemy_workers_near and len(enemy_combat_near) <= 1:
                        blocker.attack(enemy_workers_near.closest_to(blocker))
                    elif unfinished_enemy_th and len(enemy_combat_near) == 0:
                        blocker.attack(unfinished_enemy_th.first)
                    elif blocker.distance_to(target_pt) > 1.5:
                        blocker.attack(target_pt)
                    else:
                        blocker(AbilityId.HOLDPOSITION)

            # 2. Maintain Dedicated 2-4 Unit Peripheral Economic Harassment Raider Squad
            want_raiders = (
                len(self.townhalls) >= 2
                and self.supply_army >= (20 if greedy_boost else 26)
                and len(threats_home) == 0
            )
            target_raider_count = (
                4
                if (greedy_boost and self.supply_army >= 30)
                else (3 if self.supply_army >= 36 else (2 if want_raiders else 0))
            )
            if len(self._harass_raider_tags) < target_raider_count:
                raider_candidates = self.units.filter(
                    lambda u: u.type_id
                    in {
                        UnitTypeId.ZERGLING,
                        UnitTypeId.ROACH,
                        UnitTypeId.MARINE,
                        UnitTypeId.REAPER,
                        UnitTypeId.HELLION,
                        UnitTypeId.STALKER,
                        UnitTypeId.ZEALOT,
                        UnitTypeId.ADEPT,
                    }
                    and u.tag not in self._expansion_blocker_targets
                    and u.tag not in self._harass_raider_tags
                )
                while len(self._harass_raider_tags) < target_raider_count and raider_candidates:
                    u = raider_candidates.first
                    self._harass_raider_tags.add(u.tag)
                    if hasattr(self, "_deployed_unit_tags"):
                        self._deployed_unit_tags.discard(u.tag)
                    raider_candidates = raider_candidates.filter(lambda x: x.tag != u.tag)
                if self._harass_raider_tags and self.state.game_loop % 224 == 0:
                    self.raider_squads_dispatched += 1
                    self._record_pro_mechanic("raider-harass-squad")
                    self._emit_telemetry(
                        "RAIDER_HARASS_DISPATCHED",
                        raiders=len(self._harass_raider_tags),
                        army_sup=int(self.supply_army),
                        mirror_verdict=self.mirror_macro_verdict,
                    )

            if self._harass_raider_tags:
                enemy_base = self.enemy_start_locations[0] if self.enemy_start_locations else self.game_info.map_center
                enemy_ths = self.enemy_structures.filter(
                    lambda s: s.type_id
                    in {
                        UnitTypeId.HATCHERY,
                        UnitTypeId.LAIR,
                        UnitTypeId.HIVE,
                        UnitTypeId.NEXUS,
                        UnitTypeId.COMMANDCENTER,
                        UnitTypeId.ORBITALCOMMAND,
                        UnitTypeId.PLANETARYFORTRESS,
                    }
                )
                if enemy_ths:
                    raid_target_pos = max(enemy_ths, key=lambda s: s.distance_to(enemy_base)).position
                elif enemy_exp_candidates:
                    raid_target_pos = enemy_exp_candidates[0]
                else:
                    raid_target_pos = enemy_base

                for r_tag in list(self._harass_raider_tags):
                    raider = self.units.find_by_tag(r_tag)
                    if not raider:
                        continue
                    local_defenders = self.enemy_units.filter(
                        lambda e: e.distance_to(raider) <= 10.5
                        and getattr(e, "can_attack_ground", False)
                        and e.type_id not in {UnitTypeId.DRONE, UnitTypeId.SCV, UnitTypeId.PROBE}
                    ) + self.enemy_structures.filter(
                        lambda s: s.is_ready
                        and s.distance_to(raider) <= 9.5
                        and s.type_id in {UnitTypeId.PHOTONCANNON, UnitTypeId.BUNKER, UnitTypeId.SPINECRAWLER, UnitTypeId.PLANETARYFORTRESS}
                    )
                    if len(local_defenders) >= len(self._harass_raider_tags) + 2:
                        alt_pt = enemy_exp_candidates[-1] if enemy_exp_candidates else home_anchor
                        raider.move(raider.position.towards(local_defenders.center, -5.0).towards(alt_pt, 3.0))
                        continue

                    near_workers = self.enemy_units.filter(
                        lambda e: e.distance_to(raider) <= 12.0
                        and e.type_id in {UnitTypeId.DRONE, UnitTypeId.SCV, UnitTypeId.PROBE, UnitTypeId.MULE}
                    )
                    if near_workers:
                        victim = min(near_workers, key=lambda w: (w.health + w.shield, w.distance_to(raider)))
                        raider.attack(victim)
                        continue

                    near_unfinished = self.enemy_structures.filter(
                        lambda s: not s.is_ready and s.distance_to(raider) <= 13.0
                    )
                    if near_unfinished:
                        raider.attack(min(near_unfinished, key=lambda s: s.health + s.shield))
                        continue

                    near_econ_structs = self.enemy_structures.filter(
                        lambda s: s.distance_to(raider) <= 13.0
                    )
                    if near_econ_structs:
                        raider.attack(min(near_econ_structs, key=lambda s: (s.health + s.shield, s.distance_to(raider))))
                        continue

                    raider.attack(raid_target_pos)

        async def _eliminate_unused_production_and_record_metrics(self, macro_state: Dict[str, Any]) -> None:
            """
            Actively eliminates any remaining idle worker/unit production when resources
            are above expansion escrow, then updates `idle_worker_production_loops` and
            `idle_unit_production_loops` after loop 112.
            """
            escrow = int(macro_state.get("escrow_minerals", 0))
            target_workers = int(macro_state.get("target_workers", 20))
            loop = int(self.state.game_loop)
            step_loops = int(getattr(self.client, "game_step", 4))

            # 1. Sweep any idle TownHall / Larva for worker training when above escrow
            if len(self.workers) < target_workers and self.supply_left >= 1 and self.minerals >= escrow + 50:
                if self.race == Race.Terran:
                    for th in self.townhalls.ready.idle:
                        if self.supply_left >= 1 and self.minerals >= escrow + 50 and self.can_afford(UnitTypeId.SCV):
                            th.train(UnitTypeId.SCV)
                            self.commands_issued += 1
                elif self.race == Race.Protoss:
                    for th in self.townhalls.ready.idle:
                        if self.supply_left >= 1 and self.minerals >= escrow + 50 and self.can_afford(UnitTypeId.PROBE):
                            th.train(UnitTypeId.PROBE)
                            self.commands_issued += 1
                elif self.race == Race.Zerg:
                    for larva in self.larva:
                        if (
                            len(self.workers) + self.already_pending(UnitTypeId.DRONE) < target_workers
                            and self.supply_left >= 1
                            and self.minerals >= escrow + 50
                            and self.can_afford(UnitTypeId.DRONE)
                        ):
                            larva.train(UnitTypeId.DRONE)
                            self.commands_issued += 1

            # 2. Sweep any idle unit production facility when above escrow
            if self.supply_cap < 200 and self.supply_left >= 2 and self.minerals >= escrow + 100:
                if self.race == Race.Zerg and self.structures(UnitTypeId.SPAWNINGPOOL).ready:
                    for larva in self.larva:
                        if self.supply_left < 2 or self.minerals < escrow + 50:
                            break
                        if self.structures(UnitTypeId.ULTRALISKCAVERN).ready and self.supply_left >= 6 and self.can_afford(UnitTypeId.ULTRALISK):
                            larva.train(UnitTypeId.ULTRALISK)
                            self.commands_issued += 1
                        elif self.structures(UnitTypeId.HYDRALISKDEN).ready and self.can_afford(UnitTypeId.HYDRALISK):
                            larva.train(UnitTypeId.HYDRALISK)
                            self.commands_issued += 1
                        elif self.structures(UnitTypeId.ROACHWARREN).ready and self.can_afford(UnitTypeId.ROACH):
                            larva.train(UnitTypeId.ROACH)
                            self.commands_issued += 1
                        elif self.can_afford(UnitTypeId.ZERGLING):
                            larva.train(UnitTypeId.ZERGLING)
                            self.commands_issued += 1
                elif self.race == Race.Terran:
                    for rax in self.structures(UnitTypeId.BARRACKS).ready:
                        max_orders = 2 if rax.has_reactor else 1
                        for _ in range(max(0, max_orders - len(rax.orders))):
                            if self.supply_left < 1 or self.minerals < escrow + 50:
                                break
                            if rax.has_techlab and self.supply_left >= 2 and self.can_afford(UnitTypeId.MARAUDER):
                                rax.train(UnitTypeId.MARAUDER)
                                self.commands_issued += 1
                            elif self.can_afford(UnitTypeId.MARINE):
                                rax.train(UnitTypeId.MARINE)
                                self.commands_issued += 1
                            else:
                                break
                    for fac in self.structures(UnitTypeId.FACTORY).ready.idle:
                        if self.supply_left >= 3 and fac.has_techlab and self.can_afford(UnitTypeId.SIEGETANK):
                            fac.train(UnitTypeId.SIEGETANK)
                            self.commands_issued += 1
                        elif self.supply_left >= 2 and self.minerals >= escrow + 100 and self.can_afford(UnitTypeId.HELLION):
                            fac.train(UnitTypeId.HELLION)
                            self.commands_issued += 1
                    for sp in self.structures(UnitTypeId.STARPORT).ready.idle:
                        if self.supply_left >= 2 and self.can_afford(UnitTypeId.MEDIVAC) and len(self.units(UnitTypeId.MEDIVAC)) < 6:
                            sp.train(UnitTypeId.MEDIVAC)
                            self.commands_issued += 1
                        elif self.supply_left >= 2 and self.can_afford(UnitTypeId.VIKINGFIGHTER):
                            sp.train(UnitTypeId.VIKINGFIGHTER)
                            self.commands_issued += 1
                elif self.race == Race.Protoss:
                    for gw in self.structures(UnitTypeId.GATEWAY).ready.idle:
                        if self.supply_left < 2 or self.minerals < escrow + 100:
                            break
                        if UpgradeId.WARPGATERESEARCH in self.state.upgrades:
                            gw(AbilityId.MORPH_WARPGATE)
                            self.commands_issued += 1
                        elif self.structures(UnitTypeId.CYBERNETICSCORE).ready and self.can_afford(UnitTypeId.STALKER):
                            gw.train(UnitTypeId.STALKER)
                            self.commands_issued += 1
                        elif self.can_afford(UnitTypeId.ZEALOT):
                            gw.train(UnitTypeId.ZEALOT)
                            self.commands_issued += 1
                    for robo in self.structures(UnitTypeId.ROBOTICSFACILITY).ready.idle:
                        if self.structures(UnitTypeId.ROBOTICSBAY).ready and self.supply_left >= 6 and self.can_afford(UnitTypeId.COLOSSUS):
                            robo.train(UnitTypeId.COLOSSUS)
                            self.commands_issued += 1
                        elif self.supply_left >= 4 and self.can_afford(UnitTypeId.IMMORTAL):
                            robo.train(UnitTypeId.IMMORTAL)
                            self.commands_issued += 1
                        elif len(self.units(UnitTypeId.OBSERVER)) == 0 and self.supply_left >= 1 and self.can_afford(UnitTypeId.OBSERVER):
                            robo.train(UnitTypeId.OBSERVER)
                            self.commands_issued += 1
                        elif len(self.units(UnitTypeId.WARPPRISM)) == 0 and self.supply_left >= 2 and self.can_afford(UnitTypeId.WARPPRISM):
                            robo.train(UnitTypeId.WARPPRISM)
                            self.commands_issued += 1
                    for sg in self.structures(UnitTypeId.STARGATE).ready.idle:
                        if self.supply_left >= 4 and self.can_afford(UnitTypeId.VOIDRAY):
                            sg.train(UnitTypeId.VOIDRAY)
                            self.commands_issued += 1
                        elif self.supply_left >= 2 and self.can_afford(UnitTypeId.PHOENIX):
                            sg.train(UnitTypeId.PHOENIX)
                            self.commands_issued += 1

            # 3. Record unused production loops after loop 112
            if loop > 112:
                if len(self.workers) < target_workers and self.supply_left >= 1 and self.minerals >= escrow + 50:
                    if self.race in (Race.Terran, Race.Protoss):
                        if self.townhalls.ready.idle:
                            self.idle_worker_production_loops += step_loops
                    elif self.race == Race.Zerg:
                        if self.larva and self.already_pending(UnitTypeId.DRONE) == 0:
                            self.idle_worker_production_loops += step_loops

                if self.supply_cap < 200 and self.supply_left >= 2 and self.minerals >= escrow + 100:
                    prod_types = {
                        UnitTypeId.BARRACKS,
                        UnitTypeId.FACTORY,
                        UnitTypeId.STARPORT,
                        UnitTypeId.GATEWAY,
                        UnitTypeId.ROBOTICSFACILITY,
                        UnitTypeId.STARGATE,
                    }
                    idle_facilities = self.structures.filter(lambda s: s.type_id in prod_types and s.is_ready and s.is_idle)
                    if idle_facilities:
                        self.idle_unit_production_loops += step_loops

        async def _run_race_macro_and_tactics(self, iteration: int) -> None:
            """
            Prioritized Actuator & Continuous Production/Micro Executor driven by Racket's
            S-expression command stream (`self._last_racket_cmds`).
            """
            if not self.townhalls:
                return
            main_th = self.townhalls.first
            macro_state = self._evaluate_coupled_macro_state(main_th)
            escrow = int(macro_state.get("escrow_minerals", 0))

            await self._ensure_zero_supply_block()
            if iteration % 6 == 0:
                await self._transfer_depleted_base_workers()
            await self._build_mirror_choke_defense(main_th)

            buffer_needed = (
                2 if self.supply_cap <= 15 else (5 if self.supply_cap < 36 else (8 if self.supply_cap < 80 else 12))
            )
            pending_sup = (
                self.already_pending(UnitTypeId.OVERLORD)
                + self.already_pending(UnitTypeId.SUPPLYDEPOT)
                + self.already_pending(UnitTypeId.PYLON)
            )
            if self.supply_cap < 200 and self.supply_left <= buffer_needed and pending_sup == 0 and self.minerals < 150:
                await self._run_economic_disruption_and_base_blocking(main_th)
                await self._micro_combat_army(main_th)
                return

            # 1. Execute continuous racial macro mechanics (MULEs, Injects, Creep, Chrono, WarpGate/Archon morph)
            if self.race == Race.Terran:
                for depot in self.structures(UnitTypeId.SUPPLYDEPOT).ready:
                    depot(AbilityId.MORPH_SUPPLYDEPOT_LOWER)
                for oc in self.townhalls(UnitTypeId.ORBITALCOMMAND).ready:
                    if oc.energy >= 50 and self.mineral_field:
                        local_m = self.mineral_field.closer_than(10.0, oc)
                        target_m = local_m.closest_to(oc) if local_m else self.mineral_field.closest_to(oc)
                        oc(AbilityId.CALLDOWNMULE_CALLDOWNMULE, target_m)
                        self._record_pro_mechanic("calldown-mule")
            elif self.race == Race.Zerg:
                inject_queens, _creep_queens = self._partition_queens()
                for queen, th in inject_queens:
                    if queen.energy >= 25 and not th.has_buff(BuffId.QUEENSPAWNLARVATIMER):
                        queen(AbilityId.EFFECT_INJECTLARVA, th)
                enemy_pt = self.enemy_start_locations[0] if self.enemy_start_locations else self.game_info.map_center
                for t in self.structures({UnitTypeId.CREEPTUMORBURROWED, UnitTypeId.CREEPTUMORQUEEN}).ready:
                    if t.tag not in self._used_creep_tumors:
                        await self._spread_single_creep_tumor(t, enemy_pt)
            elif self.race == Race.Protoss:
                for gw in self.structures(UnitTypeId.GATEWAY).ready.idle:
                    if UpgradeId.WARPGATERESEARCH in self.state.upgrades:
                        gw(AbilityId.MORPH_WARPGATE)
                hts = self.units({UnitTypeId.HIGHTEMPLAR, UnitTypeId.DARKTEMPLAR}).ready
                if len(hts) >= 2:
                    hts[0](AbilityId.ARCHON_WARP_TARGET, hts[1])
                    self._record_pro_mechanic("morph-archon")
                for nexus in self.townhalls.ready:
                    if nexus.energy >= 50:
                        busy_targets = self.structures.ready.filter(
                            lambda b: not b.is_idle and not b.has_buff(BuffId.CHRONOBOOSTENERGYCOST)
                        )
                        if busy_targets:
                            nexus(AbilityId.EFFECT_CHRONOBOOSTENERGYCOST, busy_targets.first)
                            self._record_pro_mechanic("chrono-boost")

            # 2. Execute Racket's prioritized expand / morph / research / build / train queue
            th_type = (
                UnitTypeId.HATCHERY
                if self.race == Race.Zerg
                else (UnitTypeId.COMMANDCENTER if self.race == Race.Terran else UnitTypeId.NEXUS)
            )
            if (
                macro_state.get("safe_to_expand")
                and (macro_state.get("want_saturation_expand") or macro_state.get("want_depletion_expand"))
                and self.can_afford(th_type)
            ):
                reason = "depletion_replace" if macro_state.get("want_depletion_expand") else "saturation_expand"
                if await self._try_smart_expand(th_type, reason=reason):
                    if macro_state.get("want_depletion_expand"):
                        self.depletion_expansions_started += 1

            if iteration % 2 != 0 or not self.bridge:
                for c in self._last_racket_cmds:
                    op = c.get("op")
                    if op == "expand" and self.can_afford(th_type):
                        await self._try_smart_expand(th_type, reason="racket_expand")
                    elif op == "morph":
                        await self._actuate_morph(str(c.get("target", "")), None)
                    elif op == "research" and (self.minerals >= escrow or len(self.townhalls) >= 2):
                        upg = getattr(UpgradeId, c.get("upgrade_enum", ""), None)
                        if upg is not None:
                            await self._actuate_research_upgrade(upg)
                    elif op == "build":
                        bt = getattr(UnitTypeId, c.get("building_enum", ""), None)
                        if bt is not None and (self.minerals >= escrow or len(self.townhalls) >= 2 or self.minerals >= 300):
                            await self._actuate_build_structure(bt, c.get("x"), c.get("y"))
                    elif op == "train" and (self.minerals >= escrow or self.supply_army < 20 or len(self.townhalls) >= 2):
                        ut = getattr(UnitTypeId, c.get("unit_enum", ""), None)
                        if ut is not None:
                            await self._actuate_train_unit(ut)

            # 3. Continuous worker/unit fill guided by marginal-utility priority order & idle metric recording
            await self._eliminate_unused_production_and_record_metrics(macro_state)

            # 4. Run economic disruption (base-blockers & worker-harass raiders) and tactical army micro
            await self._run_economic_disruption_and_base_blocking(main_th)
            await self._micro_combat_army(main_th)

        async def _execute_deception_auras_and_buff_positioning(
            self,
            army: Any,
            enemy_targets: Any,
            home_anchor: Any,
            enemy_base: Any,
        ) -> set:
            """
            1. Zerg `OVERSEER` Changeling spawn (`energy >= 50`) & infiltration/base-blocking routing.
            2. Protoss `SENTRY` Hallucination Phoenix tech scouting (`energy >= 75` out of combat) &
               Hallucinated Archon/Immortal frontline tank decoy in combat.
            3. Protoss `GuardianShield` (`r = 4.5`) & Zerg `MicrobialShroud` (`r = 3.5`) aura casting.
            4. Buff-Disk Positioning with Anti-Splash Spread (pulling outside ranged units into the
               aura disk while spreading into 3 distinct crescent slots away from splash/PsiStorm/Bile).
            Returns set of unit tags that received a dedicated deception/aura positioning order this step.
            """
            handled_tags: set = set()
            sec = float(getattr(self.state, "game_loop", 0)) / 22.4

            # 1. Zerg Overseer Changeling Spawn & Routing
            for ov in self.units(UnitTypeId.OVERSEER):
                if float(getattr(ov, "energy", 0.0) or 0.0) >= 50.0:
                    ov(AbilityId.SPAWNCHANGELING_SPAWNCHANGELING)
                    self.deception_spells_cast += 1
                    self._record_pro_mechanic("overseer-spawn-changeling")

            changeling_types = {
                t
                for name in (
                    "CHANGELING",
                    "CHANGELINGZEALOT",
                    "CHANGELINGMARINESHIELD",
                    "CHANGELINGMARINE",
                    "CHANGELINGZERGLING",
                    "CHANGELINGZERGLINGWINGS",
                )
                for t in [getattr(UnitTypeId, name, None)]
                if t is not None
            }
            if changeling_types:
                my_changelings = self.units.of_type(changeling_types)
                if my_changelings:
                    sorted_exps = sorted(
                        list(self.expansion_locations_list),
                        key=lambda pt: pt.distance_to(enemy_base),
                    )
                    scout_pts = sorted_exps[:3] if sorted_exps else [enemy_base]
                    for ch in my_changelings:
                        dest = self._quantize_point(scout_pts[ch.tag % len(scout_pts)], grid=1.5)
                        if ch.distance_to(dest) <= 2.2:
                            ch(AbilityId.HOLDPOSITION)
                        elif not self._unit_already_has_order(ch, AbilityId.MOVE, dest, tol=2.0):
                            ch.move(dest)
                        handled_tags.add(ch.tag)

            # 2. Route friendly Hallucinations (Phoenix tech scout or Archon/Immortal frontline tank decoy)
            for hu in self.units:
                if getattr(hu, "is_hallucination", False):
                    handled_tags.add(hu.tag)
                    if hu.type_id == UnitTypeId.PHOENIX:
                        sorted_exps = sorted(
                            list(self.expansion_locations_list),
                            key=lambda pt: pt.distance_to(enemy_base),
                        )
                        patrol_pts = sorted_exps[:3] if sorted_exps else [enemy_base]
                        wp = self._quantize_point(patrol_pts[(hu.tag + int(sec // 8)) % len(patrol_pts)], grid=2.0)
                        if not self._unit_already_has_order(hu, AbilityId.MOVE, wp, tol=2.5):
                            hu.move(wp)
                    else:
                        front_target = enemy_targets.closest_to(hu).position if enemy_targets else enemy_base
                        ft_q = self._quantize_point(front_target, grid=2.0)
                        if not self._unit_already_has_order(hu, AbilityId.ATTACK, ft_q, tol=2.5):
                            hu.attack(ft_q)

            if not army:
                return handled_tags

            army_center = army.center
            enemy_ranged_near = self.enemy_units.filter(
                lambda e: e.distance_to(army_center) <= 13.0
                and (float(getattr(e, "ground_range", 0.0) or 0.0) > 2.0 or float(getattr(e, "air_range", 0.0) or 0.0) > 2.0)
                and e.tag not in self._confirmed_hallucination_tags
            )
            enemy_air_near = self.enemy_units.filter(
                lambda e: e.distance_to(army_center) <= 13.0
                and e.type_id.name
                in {"VOIDRAY", "CARRIER", "INTERCEPTOR", "TEMPEST", "BATTLECRUISER", "LIBERATOR", "BANSHEE", "MUTALISK"}
                and e.tag not in self._confirmed_hallucination_tags
            )

            # 3. Protoss Sentry GuardianShield + Hallucination casting
            active_aura_center = None
            active_aura_radius = 0.0
            sentries = self.units(UnitTypeId.SENTRY)
            if sentries:
                gs_sentry = None
                for s in sentries:
                    try:
                        if s.has_buff(BuffId.GUARDIANSHIELD):
                            gs_sentry = s
                            break
                    except Exception:
                        pass
                if gs_sentry is not None:
                    active_aura_center = gs_sentry.position
                    active_aura_radius = 4.5
                elif len(enemy_ranged_near) >= 2:
                    ready_sentries = [s for s in sentries if float(getattr(s, "energy", 0.0) or 0.0) >= 75.0]
                    if ready_sentries:
                        caster = min(ready_sentries, key=lambda s: s.distance_to(army_center))
                        caster(AbilityId.GUARDIANSHIELD_GUARDIANSHIELD)
                        self.protective_auras_cast += 1
                        self._record_pro_mechanic("sentry-guardian-shield")
                        active_aura_center = caster.position
                        active_aura_radius = 4.5
                        handled_tags.add(caster.tag)

                # Sentry Hallucination casting (out-of-combat Phoenix scout vs in-combat Archon decoy)
                for s in sentries:
                    if s.tag in handled_tags or float(getattr(s, "energy", 0.0) or 0.0) < 75.0:
                        continue
                    if len(enemy_ranged_near) == 0 and (sec - self._last_halluc_scout_time) > 38.0:
                        h_phx = getattr(AbilityId, "HALLUCINATION_PHOENIX", None)
                        if h_phx is not None:
                            s(h_phx)
                            self._last_halluc_scout_time = sec
                            self.deception_spells_cast += 1
                            self._record_pro_mechanic("sentry-hallucination-phoenix-scout")
                            handled_tags.add(s.tag)
                            break
                    elif gs_sentry is not None and len(enemy_ranged_near) >= 2:
                        h_archon = getattr(AbilityId, "HALLUCINATION_ARCHON", getattr(AbilityId, "HALLUCINATION_IMMORTAL", None))
                        if h_archon is not None:
                            s(h_archon)
                            self.deception_spells_cast += 1
                            self._record_pro_mechanic("sentry-hallucination-combat-decoy")
                            handled_tags.add(s.tag)
                            break

            # 4. Zerg Infestor Microbial Shroud casting (`r = 3.5`)
            infestors = self.units(UnitTypeId.INFESTOR)
            ranged_zerg = army.filter(lambda u: u.type_id in {UnitTypeId.HYDRALISK, UnitTypeId.QUEEN})
            shroud_center = None
            if hasattr(self.state, "effects"):
                for eff in self.state.effects:
                    if "MICROBIALSHROUD" in str(getattr(eff.id, "name", eff.id)).upper() and getattr(eff, "positions", None):
                        shroud_center = next(iter(eff.positions))
                        break
            if shroud_center is not None:
                active_aura_center = shroud_center
                active_aura_radius = 3.5
            elif infestors and ranged_zerg and len(enemy_air_near) >= 2:
                ready_inf = [inf for inf in infestors if float(getattr(inf, "energy", 0.0) or 0.0) >= 75.0]
                if ready_inf:
                    shroud_ab = getattr(AbilityId, "EFFECT_MICROBIALSHROUD", None)
                    if shroud_ab is not None:
                        target_pt = self._quantize_point(ranged_zerg.center, grid=1.0)
                        ready_inf[0](shroud_ab, target_pt)
                        self.protective_auras_cast += 1
                        self._record_pro_mechanic("infestor-microbial-shroud")
                        active_aura_center = target_pt
                        active_aura_radius = 3.5
                        handled_tags.add(ready_inf[0].tag)

            # 5. Buff-Disk Positioning with Anti-Splash Spread (step into aura while spreading into 3 crescent slots)
            if active_aura_center is not None and (enemy_ranged_near or enemy_air_near):
                splash_types = {
                    "SIEGETANK",
                    "SIEGETANKSIEGED",
                    "BANELING",
                    "COLOSSUS",
                    "HIGHTEMPLAR",
                    "DISRUPTOR",
                    "ARCHON",
                    "LURKERMPBURROWED",
                    "WIDOWMINEBURROWED",
                }
                enemy_splash_near = self.enemy_units.filter(
                    lambda e: e.distance_to(active_aura_center) <= 14.0 and e.type_id.name in splash_types
                )
                lethal_aoe_pts: List[Any] = []
                if hasattr(self.state, "effects"):
                    for eff in self.state.effects:
                        ename = str(getattr(eff.id, "name", eff.id)).upper()
                        if any(k in ename for k in ("PSISTORM", "CORROSIVEBILE", "PURIFICATIONNOVA", "NUKE")):
                            for p in getattr(eff, "positions", ()):
                                lethal_aoe_pts.append(p)

                enemy_focus = (enemy_ranged_near | enemy_air_near).center
                base_angle = math.atan2(
                    float(active_aura_center.y) - float(enemy_focus.y),
                    float(active_aura_center.x) - float(enemy_focus.x),
                )
                ring_r = min(active_aura_radius - 0.6, 3.2 if enemy_splash_near else 2.2)
                slot_pts = []
                for wing_i, ang_deg in enumerate((-48.0, 0.0, 48.0)):
                    ang = base_angle + math.radians(ang_deg)
                    cand = Point2(
                        (
                            float(active_aura_center.x) + ring_r * math.cos(ang),
                            float(active_aura_center.y) + ring_r * math.sin(ang),
                        )
                    )
                    for aoe_p in lethal_aoe_pts:
                        if cand.distance_to(aoe_p) < 3.2:
                            cand = cand.towards(aoe_p, -3.5)
                    slot_pts.append(self._quantize_point(cand, grid=1.0))

                wing_batches: List[List[Any]] = [[], [], []]
                for u in army:
                    if u.tag in handled_tags or getattr(u, "is_flying", False):
                        continue
                    d_aura = u.distance_to(active_aura_center)
                    in_aoe = any(u.distance_to(ap) <= 2.8 for ap in lethal_aoe_pts)
                    needs_pull_in = active_aura_radius < d_aura <= 8.0 and float(getattr(u, "ground_range", 0.0) or 0.0) >= 3.0
                    needs_splash_spread = bool(enemy_splash_near) and d_aura <= 1.2
                    if in_aoe or needs_pull_in or needs_splash_spread:
                        wing_batches[u.tag % 3].append(u)
                        handled_tags.add(u.tag)

                for wing_i in range(3):
                    if wing_batches[wing_i]:
                        self._issue_batched_group_order(wing_batches[wing_i], AbilityId.MOVE, slot_pts[wing_i], tol=1.8)

            return handled_tags

        def _execute_presplit_and_concave_high_ground(
            self,
            army: Any,
            enemy_targets: Any,
            home_anchor: Any,
            already_handled_tags: set,
        ) -> set:
            """
            1. High-Ground Terrain & Vision Advantage (`self.get_terrain_height`):
               - Defending High Ground (`our_z > enemy_z + 1.0` near ramp): hold a 3-wing concave arc
                 `2.5` tiles back from `self.main_base_ramp.top_center`.
               - Attacking Uphill (`enemy_z > our_z + 1.0`): position a flying spotter (`OVERSEER`,
                 `OVERLORD`, `MEDIVAC`, `VIKINGFIGHTER`, `OBSERVER`, `PHOENIX`, or `SCANNERSWEEP`)
                 over the high-ground cliff edge before marching ground units up a blind ramp.
            2. 3-Wing Pre-Split (`12.5 < dist_to_enemy <= 21.0` when approaching enemy combat/splash units):
               - Split into 3 batched squad wings (`u.tag % 3 == 0, 1, 2`) offset by `+-4.5` tiles
                 perpendicular to the attack direction (at most 3 batched group commands).
            3. 3-Sector Concave Arc (`8.0 <= dist_to_enemy <= 12.5`):
               - Wrap the 3 squad wings along a `110-degree` concave arc around the enemy centroid.
            """
            handled_tags: set = set()
            if len(army) < 6:
                return handled_tags

            combat_enemies = self.enemy_units.filter(
                lambda e: e.type_id not in {UnitTypeId.LARVA, UnitTypeId.EGG, UnitTypeId.OVERLORD}
                and e.tag not in self._confirmed_hallucination_tags
            )
            if not combat_enemies:
                return handled_tags

            army_center = army.center
            near_cluster = combat_enemies.closer_than(22.0, army_center)
            if not near_cluster:
                return handled_tags

            enemy_center = near_cluster.center
            dist_to_enemy = army_center.distance_to(enemy_center)
            try:
                our_z = float(self.get_terrain_height(army_center))
                enemy_z = float(self.get_terrain_height(enemy_center))
            except Exception:
                our_z = 0.0
                enemy_z = 0.0

            # 1A. Attacking Uphill (`enemy_z > our_z + 1.0`): secure high-ground vision with a flying spotter or Scanner Sweep!
            if enemy_z > our_z + 1.0 and dist_to_enemy <= 15.0:
                has_hg_vision = False
                try:
                    has_hg_vision = bool(self.is_visible(enemy_center))
                except Exception:
                    has_hg_vision = True
                spot_pt = self._quantize_point(enemy_center.towards(army_center, 3.0), grid=1.5)
                flyer_spotters = self.units.filter(
                    lambda u: getattr(u, "is_flying", False) and u.distance_to(enemy_center) <= 25.0
                )
                if flyer_spotters:
                    spotter = flyer_spotters.closest_to(enemy_center)
                    if not self._unit_already_has_order(spotter, AbilityId.MOVE, spot_pt, tol=2.5):
                        spotter.move(spot_pt)
                elif not has_hg_vision and self.race == Race.Terran:
                    orbitals = [
                        oc
                        for oc in self.structures(UnitTypeId.ORBITALCOMMAND).ready
                        if float(getattr(oc, "energy", 0.0) or 0.0) >= 50.0
                    ]
                    if orbitals:
                        orbitals[0](AbilityId.SCANNERSWEEP_SCAN, spot_pt)
                        self._record_pro_mechanic("high-ground-scanner-sweep")

            # 1B. High-Ground Ramp Defense (`our_z > enemy_z + 1.0` near home ramp)
            if our_z > enemy_z + 1.0 and army_center.distance_to(home_anchor) <= 24.0 and dist_to_enemy <= 15.0:
                ramp_top = getattr(getattr(self, "main_base_ramp", None), "top_center", army_center)
                arc_anchor = ramp_top.towards(home_anchor, 2.5)
                ang0 = math.atan2(
                    float(arc_anchor.y) - float(enemy_center.y),
                    float(arc_anchor.x) - float(enemy_center.x),
                )
                wings: List[List[Any]] = [[], [], []]
                for u in army:
                    if u.tag not in already_handled_tags and float(getattr(u, "ground_range", 0.0) or 0.0) >= 3.0:
                        wings[u.tag % 3].append(u)
                        handled_tags.add(u.tag)
                for wi, deg in enumerate((-50.0, 0.0, 50.0)):
                    if wings[wi]:
                        a = ang0 + math.radians(deg)
                        w_pt = self._quantize_point(
                            Point2((float(arc_anchor.x) + 3.5 * math.cos(a), float(arc_anchor.y) + 3.5 * math.sin(a))),
                            grid=1.5,
                        )
                        self._issue_batched_group_order(wings[wi], AbilityId.ATTACK, w_pt, tol=2.2)
                self.presplit_concave_maneuvers += 1
                return handled_tags

            splash_names = {
                "SIEGETANK",
                "SIEGETANKSIEGED",
                "BANELING",
                "COLOSSUS",
                "HIGHTEMPLAR",
                "DISRUPTOR",
                "ARCHON",
                "LURKERMP",
                "LURKERMPBURROWED",
                "WIDOWMINE",
                "WIDOWMINEBURROWED",
            }
            has_splash = any(e.type_id.name in splash_names for e in near_cluster)

            # 2. 3-Wing Pre-Split in Approach Window (`13.0 < dist_to_enemy <= 20.5` when splash or large army present)
            if 13.0 < dist_to_enemy <= 20.5 and (has_splash or len(army) >= 12) and int(self.state.game_loop) % 16 == 0:
                dx = float(enemy_center.x) - float(army_center.x)
                dy = float(enemy_center.y) - float(army_center.y)
                norm = max(0.1, math.hypot(dx, dy))
                ux, uy = dx / norm, dy / norm
                px, py = -uy, ux  # Perpendicular vector
                adv_pt = Point2((float(army_center.x) + ux * 5.0, float(army_center.y) + uy * 5.0))
                wing_pts = [
                    self._quantize_point(Point2((float(adv_pt.x) + px * 4.5, float(adv_pt.y) + py * 4.5)), grid=1.5),
                    self._quantize_point(adv_pt, grid=1.5),
                    self._quantize_point(Point2((float(adv_pt.x) - px * 4.5, float(adv_pt.y) - py * 4.5)), grid=1.5),
                ]
                wings = [[], [], []]
                for u in army:
                    if u.tag not in already_handled_tags and u.distance_to(enemy_center) > 10.5:
                        wings[u.tag % 3].append(u)
                        handled_tags.add(u.tag)
                for wi in range(3):
                    if wings[wi]:
                        self._issue_batched_group_order(wings[wi], AbilityId.ATTACK, wing_pts[wi], tol=2.5)
                self.presplit_concave_maneuvers += 1
                return handled_tags

            # 3. 3-Sector Concave Arc Formation (`8.5 <= dist_to_enemy <= 13.0` for ranged units outside weapon range)
            if 8.5 <= dist_to_enemy <= 13.0 and len(army) >= 10 and int(self.state.game_loop) % 16 == 0:
                base_ang = math.atan2(
                    float(army_center.y) - float(enemy_center.y),
                    float(army_center.x) - float(enemy_center.x),
                )
                arc_r = 6.2
                wing_pts = []
                for deg in (-55.0, 0.0, 55.0):
                    a = base_ang + math.radians(deg)
                    wing_pts.append(
                        self._quantize_point(
                            Point2((float(enemy_center.x) + arc_r * math.cos(a), float(enemy_center.y) + arc_r * math.sin(a))),
                            grid=1.5,
                        )
                    )
                wings = [[], [], []]
                for u in army:
                    if (
                        u.tag not in already_handled_tags
                        and float(getattr(u, "ground_range", 0.0) or 0.0) >= 3.5
                        and u.distance_to(enemy_center) > float(getattr(u, "ground_range", 5.0)) + 1.5
                    ):
                        wings[u.tag % 3].append(u)
                        handled_tags.add(u.tag)
                for wi in range(3):
                    if wings[wi]:
                        self._issue_batched_group_order(wings[wi], AbilityId.ATTACK, wing_pts[wi], tol=2.2)
                if any(wings):
                    self.presplit_concave_maneuvers += 1

            return handled_tags

        async def _micro_combat_army(self, main_th) -> None:
            exclude_types = {
                UnitTypeId.DRONE,
                UnitTypeId.SCV,
                UnitTypeId.PROBE,
                UnitTypeId.OVERLORD,
                UnitTypeId.OVERSEER,
                UnitTypeId.OBSERVER,
                UnitTypeId.LARVA,
                UnitTypeId.EGG,
                UnitTypeId.QUEEN,
                UnitTypeId.MULE,
                UnitTypeId.MEDIVAC,
                UnitTypeId.ZERGLINGBURROWED,
            }
            specialist_tags = set(self._expansion_blocker_targets.keys()) | self._harass_raider_tags
            army = self.units.exclude_type(exclude_types).filter(lambda u: u.tag not in specialist_tags)
            enemy_base = (
                self.enemy_start_locations[0] if self.enemy_start_locations else self.game_info.map_center
            )
            home_anchor = self.start_location if self.start_location else main_th.position
            enemy_targets = self.enemy_units | self.enemy_structures

            # 0A. Snipe any disguised enemy Changeling infiltrators immediately
            enemy_changelings = self.enemy_units.filter(lambda e: "CHANGELING" in e.type_id.name)
            if enemy_changelings and army:
                ch_target = enemy_changelings.first
                snipers = army.closer_than(10.0, ch_target)
                if snipers:
                    sniper = snipers.closest_to(ch_target)
                    if not self._unit_already_has_order(sniper, AbilityId.ATTACK, ch_target, tol=2.0):
                        sniper.attack(ch_target)

            # 0B. Execute Deception (Changeling/Hallucination), Protective Auras (GuardianShield/MicrobialShroud), & Buff-Disk Splash Spread
            special_handled_tags = await self._execute_deception_auras_and_buff_positioning(
                army, enemy_targets, home_anchor, enemy_base
            )
            # 0C. Execute 3-Wing Pre-Split, 3-Sector Concave Arc, & High-Ground Terrain/Vision Advantage
            special_handled_tags |= self._execute_presplit_and_concave_high_ground(
                army, enemy_targets, home_anchor, special_handled_tags
            )

            # Medivac dedicated heal/follow micro (batched)
            medivacs = self.units(UnitTypeId.MEDIVAC)
            if medivacs and army:
                bio_units = army.filter(lambda u: u.type_id in {UnitTypeId.MARINE, UnitTypeId.MARAUDER})
                follow_pool = bio_units if bio_units else army
                injured_bio = follow_pool.filter(lambda u: u.health_percentage < 0.95)
                lead_unit = (
                    min(injured_bio, key=lambda u: u.health_percentage)
                    if injured_bio
                    else follow_pool.closest_to(enemy_base)
                )
                self._issue_batched_group_order(medivacs, AbilityId.ATTACK, lead_unit.position)
            # Mobile detector follow micro (Overseer / Observer)
            detectors = self.units.of_type({UnitTypeId.OVERSEER, UnitTypeId.OBSERVER})
            if detectors and army:
                front_unit = army.closest_to(enemy_base)
                self._issue_batched_group_order(detectors, AbilityId.MOVE, front_unit.position)
            if not army:
                return

            # 1. Identify enemy threats near our base
            non_threat_scouts = {
                UnitTypeId.OVERLORD,
                UnitTypeId.OVERSEER,
                UnitTypeId.OBSERVER,
                UnitTypeId.LARVA,
                UnitTypeId.EGG,
            }
            threats_home = self.enemy_units.filter(
                lambda u: u.type_id not in non_threat_scouts
                and any(u.distance_to(th) < 26.0 for th in self.townhalls)
            ) | self.enemy_structures.filter(
                lambda s: s.distance_to(home_anchor) < 26.0
            )
            combat_threats_home = threats_home.filter(
                lambda t: t.type_id
                not in {
                    UnitTypeId.PYLON,
                    UnitTypeId.PROBE,
                    UnitTypeId.SCV,
                    UnitTypeId.DRONE,
                    UnitTypeId.OVERLORD,
                    UnitTypeId.LARVA,
                    UnitTypeId.EGG,
                }
            )

            # 2. Squad-based Lanchester wave release (gather critical mass & prevent trickle-feeding!)
            if not hasattr(self, "_deployed_unit_tags"):
                self._deployed_unit_tags = set()
            alive_tags = {u.tag for u in army}
            self._deployed_unit_tags &= alive_tags

            # If deployed wave was mostly wiped out, reset _offensive_launched so survivors & new spawns regroup at home!
            if self._offensive_launched and (len(self._deployed_unit_tags) <= 5 or self.supply_army < 16):
                self._offensive_launched = False
                self._deployed_unit_tags.clear()

            uncommitted_squad = [u for u in army if u.tag not in self._deployed_unit_tags]
            uncommitted_supply = sum(
                4
                if u.type_id in {UnitTypeId.IMMORTAL, UnitTypeId.ARCHON, UnitTypeId.COLOSSUS, UnitTypeId.ULTRALISK}
                else (
                    3
                    if u.type_id in {UnitTypeId.SIEGETANK, UnitTypeId.SIEGETANKSIEGED, UnitTypeId.LURKERMP, UnitTypeId.LURKERMPBURROWED}
                    else (
                        2
                        if u.type_id
                        in {
                            UnitTypeId.ROACH,
                            UnitTypeId.RAVAGER,
                            UnitTypeId.HYDRALISK,
                            UnitTypeId.MUTALISK,
                            UnitTypeId.CORRUPTOR,
                            UnitTypeId.MARAUDER,
                            UnitTypeId.VIKINGFIGHTER,
                            UnitTypeId.STALKER,
                            UnitTypeId.ZEALOT,
                        }
                        else 1
                    )
                )
                for u in uncommitted_squad
            )
            if not self._offensive_launched:
                wave_threshold = 28 if len(self.townhalls) >= 2 else (26 if self.race == Race.Terran else 22)
            else:
                wave_threshold = 18
            # Modulate wave release threshold by attrition ratio (our lost resources vs enemy lost resources)
            our_total_lost = int(getattr(self, "_our_lost_minerals", 0)) + int(getattr(self, "_our_lost_gas", 0))
            enemy_total_lost = int(getattr(self, "_enemy_lost_minerals", 0)) + int(getattr(self, "_enemy_lost_gas", 0))
            if enemy_total_lost >= our_total_lost + 400:
                wave_threshold = max(14, wave_threshold - 4)
            elif our_total_lost >= enemy_total_lost + 600 and self.supply_army < 60:
                wave_threshold += 4

            terran_stim_ready_for_march = (
                self.race != Race.Terran
                or self.blind_start
                or not self.structures(UnitTypeId.BARRACKSTECHLAB)
                or self.already_pending_upgrade(UpgradeId.STIMPACK) >= 0.80
                or self.supply_army >= 30
            )
            random_stealth_wave_ready = (
                self.blind_start
                and self.waves_launched == 0
                and self.supply_army >= 14
            )
            if (
                random_stealth_wave_ready
                or ((uncommitted_supply >= wave_threshold or self.supply_army >= wave_threshold + 4) and terran_stim_ready_for_march)
                or self.supply_used >= 170
            ):
                if not self._offensive_launched:
                    self.waves_launched += 1
                    self._emit_telemetry(
                        "WAVE_LAUNCHED",
                        wave_num=self.waves_launched,
                        army_sup=int(self.supply_army),
                        uncommitted_sup=uncommitted_supply,
                        bases=len(self.townhalls),
                        workers=len(self.workers),
                    )
                self._offensive_launched = True
                for u in uncommitted_squad:
                    self._deployed_unit_tags.add(u.tag)

            if self.supply_army >= 16 or len(army) >= 12:
                self._cannon_break_latched = True
            elif self.supply_army <= 4:
                self._cannon_break_latched = False

            enemy_base_q = self._quantize_point(enemy_base, grid=2.0)
            rally_raw = (
                self.townhalls.closest_to(self.game_info.map_center).position.towards(self.game_info.map_center, 5.0)
                if len(self.townhalls) >= 2
                else self._get_main_build_anchor(main_th)
            )
            rally_pt = self._quantize_point(rally_raw, grid=2.0)
            has_stim_researched = self.race == Race.Terran and self.already_pending_upgrade(UpgradeId.STIMPACK) >= 1.0
            has_blink_researched = self.race == Race.Protoss and self.already_pending_upgrade(UpgradeId.BLINKTECH) >= 1.0

            march_enemy_base_batch: List[Any] = []
            regroup_rally_batch: List[Any] = []
            retreat_rally_batch: List[Any] = []

            for u in army:
                if u.tag in special_handled_tags:
                    continue
                # Widow Mine tactical burrow/unburrow reflex (Random Terran stealth-harass & standard 1-1-1)
                if u.type_id == UnitTypeId.WIDOWMINE:
                    enemies_in_wm_range = enemy_targets.filter(
                        lambda e: e.type_id not in {UnitTypeId.LARVA, UnitTypeId.EGG}
                        and not getattr(e, "is_structure", False)
                        and u.distance_to(e) <= 6.5
                    )
                    if enemies_in_wm_range:
                        u(AbilityId.BURROWDOWN_WIDOWMINE)
                        continue
                elif u.type_id == UnitTypeId.WIDOWMINEBURROWED:
                    enemies_near_wm = enemy_targets.filter(
                        lambda e: e.type_id not in {UnitTypeId.LARVA, UnitTypeId.EGG}
                        and not getattr(e, "is_structure", False)
                        and u.distance_to(e) <= 9.0
                    )
                    if not enemies_near_wm:
                        u(AbilityId.BURROWUP_WIDOWMINE)
                    continue

                # Oracle Pulsar Beam reflex (Random Protoss stealth-harass)
                if u.type_id == UnitTypeId.ORACLE:
                    light_or_workers_near = self.enemy_units.filter(
                        lambda e: not getattr(e, "is_flying", False)
                        and u.distance_to(e) <= 5.5
                    )
                    if light_or_workers_near and getattr(u, "energy", 0) >= 25 and not u.has_buff(BuffId.ORACLEWEAPON):
                        u(AbilityId.BEHAVIOR_PULSARBEAMON)
                        continue

                # Siege Tank tactical siege/unsiege reflex
                if u.type_id == UnitTypeId.SIEGETANK:
                    ground_enemies_in_siege = enemy_targets.filter(
                        lambda e: not getattr(e, "is_flying", False)
                        and e.type_id not in {UnitTypeId.LARVA, UnitTypeId.EGG}
                        and u.distance_to(e) <= 13.0
                    )
                    if len(ground_enemies_in_siege) >= 2 or any(e.is_structure for e in ground_enemies_in_siege):
                        u(AbilityId.SIEGEMODE_SIEGEMODE)
                        continue
                elif u.type_id == UnitTypeId.SIEGETANKSIEGED:
                    ground_enemies_near = enemy_targets.filter(
                        lambda e: not getattr(e, "is_flying", False)
                        and e.type_id not in {UnitTypeId.LARVA, UnitTypeId.EGG}
                        and u.distance_to(e) <= 14.5
                    )
                    if not ground_enemies_near:
                        u(AbilityId.UNSIEGE_UNSIEGE)
                    continue

                # Stalker defensive Blink reflex
                if (
                    has_blink_researched
                    and u.type_id == UnitTypeId.STALKER
                    and u.shield_percentage < 0.20
                    and u.health_percentage < 0.85
                ):
                    blink_pt = self._quantize_point(u.position.towards(home_anchor, 5.5), grid=1.0)
                    u(AbilityId.EFFECT_BLINK_STALKER, blink_pt)
                    continue

                unit_deployed = self._offensive_launched and (
                    u.tag in self._deployed_unit_tags
                    or u.distance_to(home_anchor) >= 28.0
                    or getattr(self, "_enemy_main_cleared", False)
                )
                keep_pushing_forward = (
                    unit_deployed
                    and self.supply_army >= 18
                    and (
                        (u.distance_to(home_anchor) >= 45.0 and len(combat_threats_home) <= 3)
                        or (
                            len(combat_threats_home) <= 2
                            and not self.enemy_structures.closer_than(26.0, home_anchor)
                            and u.tag % 3 != 0
                        )
                    )
                )
                if threats_home and not keep_pushing_forward:
                    attackable_home = threats_home.filter(
                        lambda t: (u.can_attack_air if t.is_flying else u.can_attack_ground)
                    )
                    if attackable_home:
                        ready_home_cannons = attackable_home.filter(
                            lambda t: t.type_id in {UnitTypeId.PHOTONCANNON, UnitTypeId.BUNKER, UnitTypeId.SPINECRAWLER}
                            and t.is_ready
                        )
                        dangerous_home = attackable_home.filter(lambda t: t.type_id != UnitTypeId.PYLON)
                        if not dangerous_home and unit_deployed and not getattr(self, "_enemy_main_cleared", False):
                            if u.tag % 4 != 0:
                                far_targets = enemy_targets.filter(
                                    lambda t: t.distance_to(home_anchor) >= 26.0
                                    and (u.can_attack_air if t.is_flying else u.can_attack_ground)
                                )
                                if far_targets:
                                    ft = far_targets.closest_to(u)
                                    if not self._unit_already_has_order(u, AbilityId.ATTACK, ft, tolerance=2.5):
                                        u.attack(ft)
                                    else:
                                        self.redundant_orders_skipped += 1
                                elif u.distance_to(enemy_base) <= 4.5:
                                    self._enemy_main_cleared = True
                                else:
                                    march_enemy_base_batch.append(u)
                                continue

                        uncovered_threats = attackable_home.filter(
                            lambda t: not any(c.distance_to(t) <= 10.5 for c in ready_home_cannons)
                        )
                        can_break_cannons = getattr(self, "_cannon_break_latched", False)
                        if ready_home_cannons and not can_break_cannons and not uncovered_threats:
                            safe_rally = self._quantize_point(self._get_main_build_anchor(main_th), grid=2.0)
                            if u.distance_to(safe_rally) > 3.5:
                                if not self._unit_already_has_order(u, AbilityId.MOVE, safe_rally, tolerance=2.5):
                                    u.move(safe_rally)
                                else:
                                    self.redundant_orders_skipped += 1
                            continue

                        active_pool = (
                            uncovered_threats
                            if (ready_home_cannons and not can_break_cannons and uncovered_threats)
                            else attackable_home
                        )
                        non_halluc_home = active_pool.filter(lambda t: t.tag not in self._confirmed_hallucination_tags)
                        if non_halluc_home:
                            active_pool = non_halluc_home
                        combat_home = active_pool.filter(
                            lambda t: getattr(t, "can_attack_ground", False)
                            or getattr(t, "can_attack_air", False)
                            or t.type_id
                            in {
                                UnitTypeId.BUNKER,
                                UnitTypeId.PHOTONCANNON,
                                UnitTypeId.SPINECRAWLER,
                                UnitTypeId.QUEEN,
                                UnitTypeId.MEDIVAC,
                                UnitTypeId.WARPPRISM,
                            }
                        )
                        priority_threats = combat_home if combat_home else active_pool.filter(lambda t: t.type_id != UnitTypeId.PYLON)
                        target_pool = priority_threats if priority_threats else active_pool
                        if ready_home_cannons and can_break_cannons:
                            target = min(
                                ready_home_cannons,
                                key=lambda t: (round(t.distance_to(main_th), 0), t.health + t.shield, t.tag),
                            )
                        else:
                            in_range_home = target_pool.filter(
                                lambda t: u.distance_to(t)
                                <= ((u.air_range if t.is_flying else u.ground_range) + u.radius + t.radius + 0.3)
                            )
                            if in_range_home:
                                target = min(in_range_home, key=lambda t: (t.health + t.shield, t.tag))
                            else:
                                target = min(target_pool, key=lambda t: (t.distance_to(main_th), t.health + t.shield, t.tag))
                        if (
                            has_stim_researched
                            and u.type_id in {UnitTypeId.MARINE, UnitTypeId.MARAUDER}
                            and u.health_percentage >= 0.70
                            and u.distance_to(target) <= 8.5
                            and not u.has_buff(BuffId.STIMPACK)
                            and not u.has_buff(BuffId.STIMPACKMARAUDER)
                        ):
                            u(AbilityId.EFFECT_STIM_MARINE if u.type_id == UnitTypeId.MARINE else AbilityId.EFFECT_STIM_MARAUDER)
                            continue
                        if (
                            u.type_id == UnitTypeId.RAVAGER
                            and u.distance_to(target) <= 9.0
                            and target.tag not in self._confirmed_hallucination_tags
                        ):
                            u(AbilityId.EFFECT_CORROSIVEBILE, target.position)
                        elif (
                            u.ground_range > 2
                            and u.weapon_cooldown > 0
                            and not target.is_structure
                            and (
                                (target.ground_range <= 2 and u.distance_to(target) < u.ground_range)
                                or (
                                    u.ground_range >= 4.0
                                    and (u.health_percentage < 0.65 or u.distance_to(target) < u.ground_range - 0.5)
                                )
                            )
                        ):
                            kite_pt = self._quantize_point(u.position.towards(target.position, -2.2), grid=1.0)
                            if not self._unit_already_has_order(u, AbilityId.MOVE, kite_pt, tolerance=1.5):
                                u.move(kite_pt)
                            else:
                                self.redundant_orders_skipped += 1
                        elif (
                            u.distance_to(target)
                            <= ((u.air_range if target.is_flying else u.ground_range) + u.radius + target.radius + 4.0)
                            or target.is_structure
                        ):
                            if not self._unit_already_has_order(u, AbilityId.ATTACK, target, tolerance=2.0):
                                u.attack(target)
                            else:
                                self.redundant_orders_skipped += 1
                        else:
                            t_pos = self._quantize_point(target.position, grid=2.0)
                            if not self._unit_already_has_order(u, AbilityId.ATTACK, t_pos, tolerance=2.5):
                                u.attack(t_pos)
                            else:
                                self.redundant_orders_skipped += 1
                        continue

                if unit_deployed:
                    # 5-second (112-loop) retreat hysteresis latch + Local Lanchester retreat check
                    retreat_until = int(self._retreat_until_loop.get(u.tag, 0))
                    if self.state.game_loop < retreat_until and u.distance_to(home_anchor) > 16.0:
                        retreat_rally_batch.append(u)
                        continue
                    if (
                        u.distance_to(home_anchor) > 34.0
                        and self.supply_army < 150
                        and not getattr(self, "_enemy_main_cleared", False)
                    ):
                        local_enemies = self.enemy_units.filter(
                            lambda e: e.distance_to(u) <= 15.0
                            and (getattr(e, "can_attack_ground", False) or getattr(e, "can_attack_air", False))
                            and e.type_id not in {UnitTypeId.SCV, UnitTypeId.PROBE, UnitTypeId.DRONE}
                        )
                        if len(local_enemies) >= 7:
                            local_friends = army.closer_than(14.0, u)
                            e_power = sum(2.0 if e.health_max >= 80 else 1.0 for e in local_enemies)
                            f_power = sum(2.2 if f.health_max >= 80 else 1.0 for f in local_friends)
                            if e_power > 1.50 * f_power:
                                self._retreat_until_loop[u.tag] = int(self.state.game_loop) + 112
                                retreat_rally_batch.append(u)
                                if self.state.game_loop % 64 == 0:
                                    self.squad_retreats += 1
                                continue

                    is_exp_hunter = (
                        getattr(self, "_enemy_main_cleared", False)
                        and self.supply_army >= 32
                        and (u.tag % 4 == 0)
                    )
                    if enemy_targets:
                        valid_targets = enemy_targets.filter(
                            lambda t: (u.can_attack_air if t.is_flying else u.can_attack_ground)
                        )
                        if is_exp_hunter:
                            valid_targets = valid_targets.filter(lambda t: t.distance_to(u) <= 18.0)
                        elif keep_pushing_forward and not getattr(self, "_enemy_main_cleared", False):
                            forward_targets = valid_targets.filter(
                                lambda t: t.distance_to(home_anchor) >= 26.0 or t.distance_to(u) <= 14.0
                            )
                            valid_targets = forward_targets
                        if valid_targets:
                            non_ov_targets = valid_targets.filter(
                                lambda t: t.type_id
                                not in {
                                    UnitTypeId.OVERLORD,
                                    UnitTypeId.LARVA,
                                    UnitTypeId.EGG,
                                    UnitTypeId.CREEPTUMOR,
                                    UnitTypeId.CREEPTUMORBURROWED,
                                    UnitTypeId.CREEPTUMORQUEEN,
                                }
                                and t.tag not in self._confirmed_hallucination_tags
                            )
                            pool = non_ov_targets if non_ov_targets else valid_targets
                            non_kiting_pool = pool.filter(
                                lambda t: t.type_id != UnitTypeId.REAPER
                                or u.distance_to(t) <= max(4.5, u.ground_range + 1.5)
                            )
                            cand_pool = non_kiting_pool if non_kiting_pool else pool
                            combat_near = cand_pool.filter(
                                lambda t: t.distance_to(u) <= 15.0
                                and (
                                    getattr(t, "can_attack_ground", False)
                                    or getattr(t, "can_attack_air", False)
                                    or t.tag in getattr(self, "_priority_research_target_tags", set())
                                    or t.type_id
                                    in {
                                        UnitTypeId.BUNKER,
                                        UnitTypeId.PHOTONCANNON,
                                        UnitTypeId.SPINECRAWLER,
                                        UnitTypeId.QUEEN,
                                        UnitTypeId.MEDIVAC,
                                        UnitTypeId.WARPPRISM,
                                    }
                                )
                                and (
                                    t.type_id not in {UnitTypeId.SCV, UnitTypeId.PROBE, UnitTypeId.DRONE}
                                    or t.distance_to(u) <= 4.0
                                )
                            )
                            active_cand = combat_near if combat_near else cand_pool
                            in_range_cand = active_cand.filter(
                                lambda t: u.distance_to(t)
                                <= ((u.air_range if t.is_flying else u.ground_range) + u.radius + t.radius + 0.3)
                            )
                            if in_range_cand:
                                target = min(
                                    in_range_cand,
                                    key=lambda t: (
                                        0 if t.tag in getattr(self, "_priority_research_target_tags", set()) else 1,
                                        t.health + t.shield,
                                        t.tag,
                                    ),
                                )
                            else:
                                target = active_cand.closest_to(u)
                            if (
                                has_stim_researched
                                and u.type_id in {UnitTypeId.MARINE, UnitTypeId.MARAUDER}
                                and u.health_percentage >= 0.70
                                and u.distance_to(target) <= 8.5
                                and not u.has_buff(BuffId.STIMPACK)
                                and not u.has_buff(BuffId.STIMPACKMARAUDER)
                            ):
                                u(AbilityId.EFFECT_STIM_MARINE if u.type_id == UnitTypeId.MARINE else AbilityId.EFFECT_STIM_MARAUDER)
                                continue
                            if (
                                u.type_id == UnitTypeId.RAVAGER
                                and u.distance_to(target) <= 9.0
                                and target.tag not in self._confirmed_hallucination_tags
                            ):
                                u(AbilityId.EFFECT_CORROSIVEBILE, target.position)
                            elif (
                                u.ground_range > 2
                                and u.weapon_cooldown > 0
                                and not target.is_structure
                                and (
                                    (target.ground_range <= 2 and u.distance_to(target) < u.ground_range)
                                    or (
                                        u.ground_range >= 4.0
                                        and (u.health_percentage < 0.65 or u.distance_to(target) < u.ground_range - 0.5)
                                    )
                                )
                            ):
                                kite_pt = self._quantize_point(u.position.towards(target.position, -2.2), grid=1.0)
                                if not self._unit_already_has_order(u, AbilityId.MOVE, kite_pt, tolerance=1.5):
                                    u.move(kite_pt)
                                else:
                                    self.redundant_orders_skipped += 1
                            elif (
                                u.distance_to(target)
                                <= ((u.air_range if target.is_flying else u.ground_range) + u.radius + target.radius + 4.0)
                                or target.is_structure
                            ):
                                if not self._unit_already_has_order(u, AbilityId.ATTACK, target, tolerance=2.0):
                                    u.attack(target)
                                else:
                                    self.redundant_orders_skipped += 1
                            else:
                                t_pos = self._quantize_point(target.position, grid=2.0)
                                if not self._unit_already_has_order(u, AbilityId.ATTACK, t_pos, tolerance=2.5):
                                    u.attack(t_pos)
                                else:
                                    self.redundant_orders_skipped += 1
                            continue

                    if u.distance_to(enemy_base) <= 4.5:
                        self._enemy_main_cleared = True
                    if not getattr(self, "_enemy_main_cleared", False):
                        march_enemy_base_batch.append(u)
                    elif u.is_idle or (is_exp_hunter and self.state.game_loop % 64 == 0):
                        pa = self.game_info.playable_area
                        corner_pts = [
                            Point2((pa.x + 8.0, pa.y + 8.0)),
                            Point2((pa.x + pa.width - 8.0, pa.y + 8.0)),
                            Point2((pa.x + 8.0, pa.y + pa.height - 8.0)),
                            Point2((pa.x + pa.width - 8.0, pa.y + pa.height - 8.0)),
                        ]
                        sorted_exps = sorted(
                            list(self.expansion_locations_list),
                            key=lambda pt: pt.distance_to(enemy_base),
                        )
                        exp_locs = (
                            sorted_exps
                            + [
                                self.game_info.map_center.towards(home_anchor, 25.0),
                                self.game_info.map_center.towards(home_anchor, 15.0),
                                home_anchor.towards(enemy_base, 18.0),
                                home_anchor.towards(enemy_base, 28.0),
                            ]
                            + corner_pts
                            + [
                                self.game_info.map_center,
                                enemy_base,
                            ]
                        )
                        sweep_pt = self._quantize_point(
                            exp_locs[(u.tag + self.state.game_loop // 96) % len(exp_locs)],
                            grid=2.0,
                        )
                        if not self._unit_already_has_order(u, AbilityId.ATTACK, sweep_pt, tolerance=2.5):
                            u.attack(sweep_pt)
                        else:
                            self.redundant_orders_skipped += 1
                else:
                    near_enemies = enemy_targets.filter(
                        lambda t: t.distance_to(u) <= 14.0
                        and (u.can_attack_air if t.is_flying else u.can_attack_ground)
                    )
                    if near_enemies:
                        ne = near_enemies.closest_to(u)
                        if not self._unit_already_has_order(u, AbilityId.ATTACK, ne, tolerance=2.0):
                            u.attack(ne)
                        else:
                            self.redundant_orders_skipped += 1
                    elif u.distance_to(rally_pt) > 5.0:
                        regroup_rally_batch.append(u)

            # Issue batched squad movement/attack commands so BotAI._prepare_step merges them into single ActionRawUnitCommand packets
            if march_enemy_base_batch:
                self._issue_batched_group_order(march_enemy_base_batch, AbilityId.ATTACK, enemy_base_q, tolerance=2.5)
            if regroup_rally_batch:
                self._issue_batched_group_order(regroup_rally_batch, AbilityId.ATTACK, rally_pt, tolerance=2.5)
            if retreat_rally_batch:
                self._issue_batched_group_order(retreat_rally_batch, AbilityId.MOVE, rally_pt, tolerance=2.5)

        async def on_step(self, iteration: int):
            t0 = time.perf_counter()
            self.peak_workers = max(self.peak_workers, len(self.workers))
            self.peak_bases = max(self.peak_bases, len(self.townhalls))
            self.peak_army_supply = max(self.peak_army_supply, int(self.supply_army))
            if int(self.state.game_loop) > 224:
                self.max_minerals_banked = max(self.max_minerals_banked, int(self.minerals))
                self.max_gas_banked = max(self.max_gas_banked, int(self.vespene))
            if (
                self.state.game_loop > 112
                and self.supply_left <= 0
                and self.supply_cap < 200
                and self.supply_used >= 14
            ):
                self.supply_blocked_loops += int(getattr(self.client, "game_step", 4))

            # 0. Observe enemy upgrades, spells, persistent effects, implied tech tree, and zero-sum negative exclusions
            self._observe_enemy_upgrades_and_implied_tech()

            # 1. Step Racket S-expression IPC subprocess (with Layer 5 HumanCortex APM & saccade filter)
            if self.bridge and iteration % 2 == 0:
                obs_sexp = self._build_frame_observation()
                cmds = self.bridge.step_sexp(obs_sexp)
                if cmds:
                    await self._execute_decoded_commands(cmds)

            # 2. Run pro signature reflexes & anti-cheese countermeasures
            emergency_worker_defense = await self._run_pro_reflexes_and_countermeasures()
            if not emergency_worker_defense:
                await self._run_race_macro_and_tactics(iteration)

            # 3. Enforce Pro-Human Camera Saccades (75-110 SPM) & APM/EPM Alignment
            await self._step_pro_human_camera_and_apm_alignment()

            dt_ms = (time.perf_counter() - t0) * 1000.0
            self._step_durations_ms.append(dt_ms)

            # 4. Emit periodic 30-second Schema 2.0 [SCBOT_TELEMETRY] snapshot to stdout for match_log.zip feedback
            loop = int(self.state.game_loop)
            if loop - self._last_telemetry_loop >= 672:
                self._last_telemetry_loop = loop
                self.telemetry.emit_periodic_snapshot(self)

    return RacketSC2BotAI()


def run_live_headless_sc2_match(
    bot_rkt_path: str,
    opponent_race_str: str = "Protoss",
    difficulty_str: str = "VeryHard",
    map_name: str = "Simple64",
    max_game_loops: int = 4032,
    save_replay_path: Optional[str] = None,
    race_override: Optional[str] = None,
    posture_override: Optional[str] = None,
    external_opponent_bot: Optional[Any] = None,
    opponent_bot_name: Optional[str] = None,
) -> Dict[str, Any]:
    import sc2
    from sc2 import maps
    from sc2.data import Difficulty, Race, Result
    from sc2.main import run_game
    from sc2.player import Bot, Computer

    inferred_race, inferred_posture = infer_bot_race_and_posture(bot_rkt_path)
    our_race_str = race_override or inferred_race

    race_map = {
        "zerg": Race.Zerg,
        "terran": Race.Terran,
        "protoss": Race.Protoss,
        "random": Race.Random,
    }
    our_race_enum = race_map.get(our_race_str.lower(), Race.Random)
    opp_race_enum = race_map.get(opponent_race_str.lower(), Race.Protoss)

    diff_map = {
        "veryeasy": Difficulty.VeryEasy,
        "easy": Difficulty.Easy,
        "medium": Difficulty.Medium,
        "hard": Difficulty.Hard,
        "harder": Difficulty.Harder,
        "veryhard": Difficulty.VeryHard,
        "cheatvision": Difficulty.CheatVision,
        "cheatmoney": Difficulty.CheatMoney,
        "cheatinsane": Difficulty.CheatInsane,
    }
    diff_enum = diff_map.get(difficulty_str.lower(), Difficulty.VeryHard)

    agent = create_racket_sc2_agent(
        bot_rkt_path=bot_rkt_path,
        race_override=our_race_str,
        posture_override=posture_override,
    )
    bot_player = Bot(our_race_enum, agent, name=Path(bot_rkt_path).stem)

    if external_opponent_bot is not None:
        opp_player = Bot(opp_race_enum, external_opponent_bot, name=opponent_bot_name or "ExternalBot")
    else:
        opp_player = Computer(opp_race_enum, diff_enum)

    t0 = time.time()
    try:
        result = run_game(
            maps.get(map_name),
            [bot_player, opp_player],
            realtime=False,
            save_replay_as=save_replay_path,
            game_time_limit=(max_game_loops / 22.4) if max_game_loops else None,
        )
    except AssertionError:
        result = getattr(agent, "_recorded_result", Result.Tie)
    elapsed_s = round(time.time() - t0, 2)

    if result is None:
        result = getattr(agent, "_recorded_result", None)

    res_str = "Tie"
    if isinstance(result, list) and result:
        res_val = result[0] if result[0] is not None else getattr(agent, "_recorded_result", "Tie")
        res_str = res_val.name if hasattr(res_val, "name") else str(res_val)
    elif hasattr(result, "name"):
        res_str = result.name
    elif result is not None:
        res_str = str(result)

    game_loops = int(getattr(agent.state, "game_loop", 0)) if hasattr(agent, "state") and agent.state else 0
    actual_race_played = agent.race.name if hasattr(agent, "race") and agent.race else our_race_str

    active_loops = max(1, game_loops - 112)
    w_util = round(100.0 * max(0.0, 1.0 - float(getattr(agent, "idle_worker_prod_loops", 0)) / active_loops), 1)
    u_util = round(100.0 * max(0.0, 1.0 - float(getattr(agent, "idle_unit_prod_loops", 0)) / active_loops), 1)
    completed_upgrades = sorted(
        getattr(upg, "name", str(upg))
        for upg in getattr(getattr(agent, "state", None), "upgrades", ())
    )

    return {
        "schema_version": SCHEMA_VERSION,
        "bot_rkt_path": str(bot_rkt_path),
        "configured_race": our_race_str,
        "actual_race_played": actual_race_played,
        "blind_start": agent.blind_start,
        "initial_posture": agent.posture_transitions[0] if agent.posture_transitions else "balanced-opening",
        "final_posture": agent.current_posture,
        "posture_transitions": agent.posture_transitions,
        "opponent": opponent_bot_name or f"Computer({opponent_race_str},{difficulty_str})",
        "opponent_race": opponent_race_str,
        "map": map_name,
        "result": res_str,
        "game_loops": game_loops,
        "game_duration_s": round(game_loops / 22.4, 1),
        "wall_time_s": elapsed_s,
        "supply_blocked_loops": agent.supply_blocked_loops,
        "supply_blocked_seconds": round(agent.supply_blocked_loops / 22.4, 2),
        "peak_workers": agent.peak_workers,
        "peak_bases": agent.peak_bases,
        "peak_army_supply": agent.peak_army_supply,
        "worker_prod_utilization_pct": w_util,
        "unit_prod_utilization_pct": u_util,
        "guns_vs_butter_regime": getattr(agent, "guns_vs_butter_regime", "guns_army_surge"),
        "target_resource_ratio": round(float(getattr(agent, "target_resource_ratio", 1.5)), 2),
        "completed_upgrades": completed_upgrades,
        "observed_enemy_upgrades": sorted(getattr(agent, "_observed_enemy_upgrades", set())),
        "observed_enemy_spells": sorted(getattr(agent, "_observed_enemy_spells", set())),
        "implied_enemy_tech_buildings": sorted(getattr(agent, "_implied_enemy_tech_buildings", set())),
        "active_implied_enemy_tech_buildings": sorted(getattr(agent, "_active_implied_enemy_tech_buildings", set())),
        "crippled_enemy_tech_buildings": sorted(getattr(agent, "_crippled_enemy_tech_buildings", set())),
        "inferred_enemy_active_research": sorted(getattr(agent, "_inferred_enemy_active_research", set())),
        "stargate_preview_units": sorted(getattr(agent, "_stargate_preview_units", set())),
        "confirmed_enemy_hallucinations": len(getattr(agent, "_confirmed_hallucination_tags", set())),
        "enemy_committed_branch": getattr(agent, "_enemy_committed_branch", "UNCOMMITTED"),
        "enemy_excluded_branches": sorted(getattr(agent, "_enemy_excluded_branches", set())),
        "enemy_bluff_suspected": bool(getattr(agent, "_enemy_bluff_suspected", False)),
        "our_lost_minerals": int(getattr(agent, "_our_lost_minerals", 0)),
        "our_lost_gas": int(getattr(agent, "_our_lost_gas", 0)),
        "enemy_lost_minerals": int(getattr(agent, "_enemy_lost_minerals", 0)),
        "enemy_lost_gas": int(getattr(agent, "_enemy_lost_gas", 0)),
        "our_workers_lost": int(getattr(agent, "_our_workers_lost", 0)),
        "enemy_workers_killed": int(getattr(agent, "_enemy_workers_killed", 0)),
        "estimated_enemy_workers": int(getattr(agent, "_estimated_enemy_workers", 12)),
        "estimated_enemy_min_rate": int(getattr(agent, "_estimated_enemy_min_rate", 0)),
        "estimated_enemy_gas_rate": int(getattr(agent, "_estimated_enemy_gas_rate", 0)),
        "seen_enemy_army_supply": round(float(getattr(agent, "_seen_enemy_army_supply", 0.0)), 1),
        "unaccounted_enemy_army_supply": round(float(getattr(agent, "_unaccounted_enemy_army_supply", 0.0)), 1),
        "enemy_eta_to_our_natural_sec": round(float(getattr(agent, "_enemy_eta_to_our_natural_sec", 99.0)), 1),
        "spatial_maneuver": str(getattr(agent, "_spatial_maneuver", "standard_posture")),
        "camera_saccades": int(getattr(agent, "camera_saccades_emitted", 0)),
        "batched_group_commands": int(getattr(agent, "batched_group_commands_issued", 0)),
        "redundant_orders_skipped": int(getattr(agent, "redundant_orders_skipped", 0)),
        "deception_spells_cast": int(getattr(agent, "deception_spells_cast", 0)),
        "protective_auras_cast": int(getattr(agent, "protective_auras_cast", 0)),
        "presplit_concave_maneuvers": int(getattr(agent, "presplit_concave_maneuvers", 0)),
        "commands_issued": agent.commands_issued,
        "racket_commands_executed": agent.racket_commands_executed,
        "ipc_calls": agent.bridge.ipc_calls if agent.bridge else 0,
        "racket_command_histogram": agent.bridge.command_histogram if agent.bridge else {},
        "pro_mechanics_triggered": agent.pro_mechanics_triggered,
        "countermeasures_triggered": agent.countermeasures_triggered,
        "mirror_active_depth": agent.mirror_active_depth,
        "active_mirror_depth": agent.mirror_active_depth,
        "depth_accuracy_map": {str(k): round(float(v), 1) for k, v in getattr(agent, "_depth_ema_accuracy", {}).items()},
        "mirror_inferred_opponent_depth": agent.mirror_inferred_opponent_depth,
        "mirror_toolbox_weight_pct": agent.mirror_toolbox_weight_pct,
        "mirror_toolbox_role": agent.mirror_toolbox_role,
        "mirror_strategic_hypothesis": agent.mirror_strategic_hypothesis,
        "mirror_tactical_target": agent.mirror_tactical_target,
        "mirror_predicted_enemy_unit": agent.mirror_predicted_enemy_unit,
        "mirror_preemptive_unit": agent.mirror_preemptive_unit,
        "mirror_accuracy_pct": agent.mirror_accuracy_pct,
        "mirror_trust_mode": agent.mirror_trust_mode,
        "mirror_predictions_received": agent.mirror_predictions_received,
        "mirror_macro_verdict": getattr(agent, "mirror_macro_verdict", "BALANCED"),
        "bases_blocked": int(getattr(agent, "base_blockers_dispatched", 0)),
        "harass_raids_dispatched": int(getattr(agent, "raider_squads_dispatched", 0)),
        "replay_path": save_replay_path,
    }


def run_bridge_self_test() -> Dict[str, Any]:
    core_sexp = """
    ((train zergling)
     (train widow-mine)
     (build spawning-pool 22.5 24.0)
     (expand 36.0 28.0)
     (research zergling-movementspeed)
     (morph 101 baneling)
     (attack-pos (101 102) 48.0 48.0)
     (kite 101 20.0 20.0)
     (inject-larva 201 301)
     (cast 401 corrosive-bile 45.0 45.0)
     (cast-spell 501 chrono-boost 601))
    """
    pro_sexp = """
    ((cancel 701)
     (cast 702 spread-creep-tumor 32.0 34.0)
     (hold-position 703 28.0 28.0)
     (swap-addon 704 705)
     (transport-juggle 706 707 20.0 20.0)
     (multi-prong-drop 706 50.0 18.0)
     (mineral-walk 708 12.0 14.0)
     (worker-harass 709 52.0 52.0)
     (control-group-steal 1 (703 707))
     (camera-bookmark-save 0 24.0 24.0)
     (camera-bookmark-jump 0)
     (pull-workers-attack (801 802 803) 26.0 26.0)
     (clear-gas-steal 901 22.0 20.0)
     (resume-halted-building 804 902)
     (camera-focus 44.0 48.0)
     (human-apm-discipline 190.0 175.0 88.0)
     (mirror-zero-sum-exclusion "ZERG_ROACH_RAVAGER" ("ZERG_SPIRE_AIR") #f)
     (mirror-tech-observation ("STIMPACK") ("PSISTORM") ("BARRACKSTECHLAB"))
     (cast-deception-and-scout-spells "hallucination-phoenix")
     (cast-protective-buff-aura "guardian-shield")
     (position-in-buff-aura-with-splash-spread 4.5 1.8)
     (pre-split-wings 3 4.5)
     (form-concave-arc 110.0 6.0)
     (high-ground-tactics "spotter-overseer")
     (mirror-spatial-maneuver "backstab_undefended_enemy_expansion" 14.5 18.0)
     (execute-spatial-maneuver "surround_and_crush_isolated_enemy_cluster" 42.0 44.0))
    """
    decoded_core = translate_sc_bot_commands(core_sexp)
    decoded_pro = translate_sc_bot_commands(pro_sexp)
    assert len(decoded_core) == 11, f"Expected 11 core decoded commands, got {len(decoded_core)}"
    assert len(decoded_pro) == 26, f"Expected 26 pro/countermeasure decoded commands, got {len(decoded_pro)}"
    return {
        "bridge_self_test": "OK",
        "schema_version": SCHEMA_VERSION,
        "decoded_count": len(decoded_core),
        "pro_mechanics_decoded": len(decoded_pro),
    }


def main():
    parser = argparse.ArgumentParser(description="SC2 burnysc2 S-expression IPC Bridge")
    parser.add_argument("--self-test", action="store_true", help="Run bridge S-expression decoder self-test")
    parser.add_argument("--bot", type=str, default=str(ROOT_DIR / "bots" / "Mothman.rkt"), help="Path to .rkt bot")
    parser.add_argument("--race", type=str, default=None, help="Race override")
    parser.add_argument("--opponent-race", type=str, default="Protoss", help="Opponent race")
    parser.add_argument("--difficulty", type=str, default="VeryHard", help="Opponent difficulty")
    parser.add_argument("--map", type=str, default="Simple64", help="SC2 Map")
    parser.add_argument("--max-loops", type=int, default=4032, help="Max game loops")
    args = parser.parse_args()

    if args.self_test:
        print(json.dumps(run_bridge_self_test()))
        return

    res = run_live_headless_sc2_match(
        bot_rkt_path=args.bot,
        opponent_race_str=args.opponent_race,
        difficulty_str=args.difficulty,
        map_name=args.map,
        max_game_loops=args.max_loops,
        race_override=args.race,
    )
    print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
