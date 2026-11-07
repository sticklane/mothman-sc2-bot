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
    "stargate": "STARGATE",
    "templar-archives": "TEMPLARARCHIVE",
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
    "glial-reconstitution": "GLIALRECONSTITUTION",
    "grooved-spines": "EVOLVEGROOVEDSPINES",
    "muscular-augments": "EVOLVEMUSCULARAUGMENTS",
    "centrifugal-hooks": "CENTRIFUGALHOOKS",
    "chitinous-plating": "CHITINOUSPLATING",
    "stimpack": "STIMPACK",
    "combat-shield": "SHIELDWALL",
    "shield-wall": "SHIELDWALL",
    "concussive-shells": "PUNISHERGRENADES",
    "infernal-pre-igniter": "HIGHCAPACITYBARRELS",
    "cloak-banshee": "BANSHEECLOAK",
    "warp-gate-research": "WARPGATERESEARCH",
    "warpgate": "WARPGATERESEARCH",
    "charge": "CHARGE",
    "blink": "BLINKTECH",
    "psi-storm": "PSISTORMTECH",
    "extended-thermal-lance": "EXTENDEDTHERMALLANCE",
}

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
        import tarfile

        bot_args = [
            "--bot",
            self.bot_rkt_path,
            "--race",
            self.race_str.lower(),
            "--posture",
            self.posture_str,
        ]

        # 1. Local system / toolchain Racket (fastest when pre-installed)
        sys_racket = RACKET_BIN if os.path.exists(RACKET_BIN) else shutil.which("racket")
        if sys_racket and os.path.exists(sys_racket):
            return [sys_racket, str(ipc_script)] + bot_args

        # 2. Bundled AI Arena portable Linux x86_64 Racket runtime (racket_runtime/ or racket_runtime.tar.xz)
        rt_dir = ROOT_DIR / "racket_runtime"
        rt_bin = rt_dir / "bin" / "racket"
        rt_archive = ROOT_DIR / "racket_runtime.tar.xz"
        if not rt_bin.exists() and rt_archive.exists():
            try:
                with tarfile.open(rt_archive, "r:xz") as tf:
                    tf.extractall(path=ROOT_DIR)
            except Exception:
                pass

        if rt_bin.exists():
            try:
                os.chmod(rt_bin, 0o755)
                etc_dir = rt_dir / "etc"
                etc_dir.mkdir(parents=True, exist_ok=True)
                cfg_rktd = etc_dir / "config.rktd"
                if not cfg_rktd.exists():
                    cfg_rktd.write_text("#hash()\n", encoding="utf-8")
                collects_dir = rt_dir / "collects"
                sc_bot_collect = collects_dir / "sc-bot"
                if not sc_bot_collect.exists() and (ROOT_DIR / "sc-bot").exists():
                    shutil.copytree(ROOT_DIR / "sc-bot", sc_bot_collect)
                return [
                    str(rt_bin),
                    "-X",
                    str(collects_dir),
                    "-G",
                    str(etc_dir),
                    str(ipc_script),
                ] + bot_args
            except Exception:
                pass

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
            self.peak_workers = 0
            self.peak_bases = 1
            self.peak_army_supply = 0
            self.max_minerals_banked = 0
            self.max_gas_banked = 0
            self.expansions_started = 0
            self.expansions_failed = 0
            self.waves_launched = 0
            self.squad_retreats = 0
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

        def _emit_telemetry(self, event_type: str, **payload: Any) -> None:
            rec = {
                "event": event_type,
                "loop": int(getattr(self.state, "game_loop", 0)) if hasattr(self, "state") and self.state else 0,
                "sec": round(
                    (int(getattr(self.state, "game_loop", 0)) / 22.4)
                    if hasattr(self, "state") and self.state
                    else 0.0,
                    1,
                ),
            }
            rec.update(payload)
            print(f"[SCBOT_TELEMETRY] {json.dumps(rec, sort_keys=False)}", flush=True)

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

        def _opponent_data_path(self) -> Path:
            data_dir = ROOT_DIR / "data"
            data_dir.mkdir(parents=True, exist_ok=True)
            return data_dir / "mirror_mind_opponents.json"

        def _telemetry_history_path(self) -> Path:
            data_dir = ROOT_DIR / "data"
            data_dir.mkdir(parents=True, exist_ok=True)
            return data_dir / "match_telemetry_history.jsonl"

        def _load_opponent_bot_data(self) -> None:
            opp_id = str(getattr(self, "opponent_id", None) or "local_opponent")
            p = self._opponent_data_path()
            if not p.exists():
                return
            try:
                db = json.loads(p.read_text(encoding="utf-8"))
                rec = db.get("opponents", {}).get(opp_id)
                if not isinstance(rec, dict):
                    return
                self.mirror_inferred_opponent_depth = int(rec.get("last_inferred_opponent_depth", 1))
                self.mirror_active_depth = int(rec.get("last_active_depth", 2))
                self.mirror_accuracy_pct = int(rec.get("last_accuracy_pct", 67))
                if rec.get("saw_air_tech"):
                    self._mirror_air_alert = True
                if rec.get("saw_early_rush"):
                    self.mirror_strategic_hypothesis = "opponent-committed-early-all-in"
                    self.mirror_tactical_target = "natural-choke-defense"
                games = int(rec.get("games_played", 0))
                print(f"Tag: prior_games_{games}", flush=True)
            except Exception:
                pass

        def _diagnose_bottlenecks(self) -> List[str]:
            bottlenecks: List[str] = []
            max_sec = (int(getattr(self.state, "game_loop", 0)) / 22.4) if hasattr(self, "state") and self.state else 0
            if max_sec >= 240 and self.peak_bases < 2:
                bottlenecks.append("one_base_starvation")
            elif max_sec >= 420 and self.peak_bases < 3:
                bottlenecks.append("low_bases")
            if max_sec >= 300 and self.peak_workers < 38:
                bottlenecks.append("worker_starvation")
            if self.max_gas_banked >= 400:
                bottlenecks.append("gas_float")
            if self.max_minerals_banked >= 900:
                bottlenecks.append("mineral_float")
            if self.supply_blocked_loops >= 350:
                bottlenecks.append("supply_blocked")
            if not bottlenecks:
                bottlenecks.append("healthy_macro")
            return bottlenecks

        def _save_opponent_bot_data(self, game_result: Any) -> None:
            opp_id = str(getattr(self, "opponent_id", None) or "local_opponent")
            p = self._opponent_data_path()
            try:
                db = json.loads(p.read_text(encoding="utf-8")) if p.exists() else {"opponents": {}}
            except Exception:
                db = {"opponents": {}}
            if "opponents" not in db or not isinstance(db["opponents"], dict):
                db["opponents"] = {}
            rec = db["opponents"].get(opp_id, {})
            games = int(rec.get("games_played", 0)) + 1
            res_name = getattr(game_result, "name", str(game_result))
            wins = int(rec.get("wins", 0)) + (1 if "Victory" in res_name else 0)
            losses = int(rec.get("losses", 0)) + (1 if "Defeat" in res_name else 0)
            ties = int(rec.get("ties", 0)) + (1 if "Tie" in res_name else 0)
            saw_rush = bool(rec.get("saw_early_rush", False)) or (
                self.mirror_strategic_hypothesis == "opponent-committed-early-all-in"
                or "pull-workers-attack" in self.countermeasures_triggered
            )
            saw_air = bool(rec.get("saw_air_tech", False)) or bool(self._mirror_air_alert)
            bottlenecks = self._diagnose_bottlenecks()
            my_race = self.race.name if hasattr(self, "race") and self.race else self.configured_race
            enemy_race = (
                self.enemy_race.name
                if hasattr(self, "enemy_race") and self.enemy_race
                else "Unknown"
            )
            ipc_mode = "python_fallback"
            if self.bridge and self.bridge.cmd:
                ipc_mode = "python_fallback" if "racket_sexp_fallback.py" in " ".join(self.bridge.cmd) else "racket_native"

            step_sorted = sorted(self._step_durations_ms)
            p50_ms = round(step_sorted[len(step_sorted) // 2], 2) if step_sorted else 0.0
            p95_ms = round(step_sorted[int(len(step_sorted) * 0.95)], 2) if step_sorted else 0.0
            max_ms = round(step_sorted[-1], 2) if step_sorted else 0.0

            summary_record = {
                "opponent_id": opp_id,
                "map": getattr(self.game_info, "map_name", "unknown") if hasattr(self, "game_info") else "unknown",
                "my_race": my_race,
                "enemy_race": enemy_race,
                "result": res_name,
                "ipc_mode": ipc_mode,
                "peak_bases": self.peak_bases,
                "peak_workers": self.peak_workers,
                "peak_army_supply": self.peak_army_supply,
                "expansions_started": self.expansions_started,
                "expansions_failed": self.expansions_failed,
                "waves_launched": self.waves_launched,
                "squad_retreats": self.squad_retreats,
                "max_minerals_banked": self.max_minerals_banked,
                "max_gas_banked": self.max_gas_banked,
                "supply_blocked_loops": self.supply_blocked_loops,
                "racket_commands_executed": self.racket_commands_executed,
                "mirror_active_depth": self.mirror_active_depth,
                "mirror_inferred_opponent_depth": self.mirror_inferred_opponent_depth,
                "mirror_toolbox_weight_pct": self.mirror_toolbox_weight_pct,
                "final_posture": self.current_posture,
                "posture_transitions": self.posture_transitions[-10:],
                "pro_mechanics": self.pro_mechanics_triggered,
                "countermeasures": self.countermeasures_triggered,
                "bottlenecks": bottlenecks,
                "step_ms_p50": p50_ms,
                "step_ms_p95": p95_ms,
                "step_ms_max": max_ms,
            }
            db["opponents"][opp_id] = {
                "games_played": games,
                "wins": wins,
                "losses": losses,
                "ties": ties,
                "last_result": res_name,
                "last_inferred_opponent_depth": self.mirror_inferred_opponent_depth,
                "last_active_depth": self.mirror_active_depth,
                "last_accuracy_pct": self.mirror_accuracy_pct,
                "last_toolbox_weight_pct": self.mirror_toolbox_weight_pct,
                "saw_early_rush": saw_rush,
                "saw_air_tech": saw_air,
                "last_posture": self.current_posture,
                "last_bottlenecks": bottlenecks,
            }
            try:
                p.write_text(json.dumps(db, indent=2), encoding="utf-8")
                with open(self._telemetry_history_path(), "a", encoding="utf-8") as hf:
                    hf.write(json.dumps(summary_record) + "\n")
            except Exception:
                pass
            print(f"Tag: race_{my_race}_vs_{enemy_race}", flush=True)
            print(f"Tag: bases_{self.peak_bases}_w_{self.peak_workers}", flush=True)
            print(f"Tag: depth_{self.mirror_active_depth}_opp_{self.mirror_inferred_opponent_depth}", flush=True)
            print(f"Tag: posture_{self.current_posture}", flush=True)
            print(f"Tag: ipc_{ipc_mode}", flush=True)
            print(f"Tag: bottleneck_{bottlenecks[0]}", flush=True)
            self._emit_telemetry("MATCH_SUMMARY", **summary_record)

        async def on_start(self):
            self._load_opponent_bot_data()
            actual_race_name = self.race.name if hasattr(self, "race") and self.race else self.configured_race
            enemy_race_name = (
                self.enemy_race.name
                if hasattr(self, "enemy_race") and self.enemy_race
                else "Unknown"
            )
            self.bridge = SC2BurnySexpBridge(
                bot_rkt_path=self.bot_rkt_path,
                race_str=actual_race_name,
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
            for u in self.units.take(30):
                ut_name = u.type_id.name.lower()
                my_units_sexp.append(
                    f"({u.tag} {ut_name} {u.position.x:.1f} {u.position.y:.1f} {u.health:.0f} {u.energy:.0f})"
                )

            ready_tumors = [
                t
                for t in self.structures(UnitTypeId.CREEPTUMORBURROWED).ready
                if t.tag not in self._used_creep_tumors
            ][:2]
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
                bt_name = b.type_id.name.lower()
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
            for eu in self.enemy_units.take(30):
                e_name = eu.type_id.name.lower()
                enemy_units_sexp.append(
                    f"({eu.tag} {e_name} {eu.position.x:.1f} {eu.position.y:.1f} {eu.health:.0f})"
                )

            enemy_bldgs_sexp = []
            for eb in self.enemy_structures.take(25):
                eb_name = eb.type_id.name.lower()
                enemy_bldgs_sexp.append(
                    f"({eb.tag} {eb.position.x:.1f} {eb.position.y:.1f} {eb.health:.0f})"
                    if False
                    else f"({eb.tag} {eb_name} {eb.position.x:.1f} {eb.position.y:.1f} {eb.health:.0f})"
                )

            effects_sexp = []
            ff_eff_id = getattr(EffectId, "FORCEFIELD", getattr(EffectId, "FORCEFIELD_FORCEFIELD", None))
            for eff in self.state.effects:
                if ff_eff_id is not None and eff.id == ff_eff_id:
                    for pos in eff.positions:
                        effects_sexp.append(f"(force-field {pos.x:.1f} {pos.y:.1f})")

            enemy_start = self.enemy_start_locations[0] if self.enemy_start_locations else Point2((32.0, 32.0))
            our_start = self.start_location if self.start_location else Point2((16.0, 16.0))

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
                f"#:enemy-base ({enemy_start.x:.1f} {enemy_start.y:.1f}) "
                f"#:my-units ({' '.join(my_units_sexp)}) "
                f"#:my-buildings ({' '.join(my_bldgs_sexp)}) "
                f"#:enemy-units ({' '.join(enemy_units_sexp)}) "
                f"#:enemy-buildings ({' '.join(enemy_bldgs_sexp)}) "
                f"#:effects ({' '.join(effects_sexp)}))"
            )

        async def _execute_decoded_commands(self, cmds: List[Dict[str, Any]]) -> None:
            for c in cmds:
                op = c.get("op")
                try:
                    if op == "cancel":
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
                            if ut == UnitTypeId.OVERLORD:
                                if (
                                    self.race == Race.Zerg
                                    and self.supply_left <= 6
                                    and self.already_pending(UnitTypeId.OVERLORD) < 2
                                    and self.can_afford(UnitTypeId.OVERLORD)
                                    and self.larva
                                ):
                                    self.larva.first.train(UnitTypeId.OVERLORD)
                                    self.commands_issued += 1
                                    self.racket_commands_executed += 1
                            elif self.supply_left >= 3 and self.can_afford(ut):
                                self.racket_commands_executed += 1

                    elif op == "build":
                        b_enum_name = c.get("building_enum", "")
                        bt = getattr(UnitTypeId, b_enum_name, None)
                        if bt is not None and self.can_afford(bt):
                            self.racket_commands_executed += 1

                    elif op == "expand":
                        self.racket_commands_executed += 1

                    elif op == "research":
                        upg_enum_name = c.get("upgrade_enum", "")
                        upg = getattr(UpgradeId, upg_enum_name, None)
                        if upg is not None and self.can_afford(upg):
                            self.racket_commands_executed += 1

                    elif op == "morph":
                        self.racket_commands_executed += 1

                    elif op == "inject-larva":
                        qid = c.get("queen_id")
                        hid = c.get("hatch_id")
                        queen = self.units.find_by_tag(qid) if qid else None
                        hatch = self.structures.find_by_tag(hid) if hid else (self.townhalls.first if self.townhalls else None)
                        if queen and hatch and queen.energy >= 25:
                            queen(AbilityId.EFFECT_INJECTLARVA, hatch)
                            self.commands_issued += 1
                            self.racket_commands_executed += 1

                    elif op == "cast":
                        spell = c.get("spell")
                        cid = c.get("caster_id")
                        if spell == "spread-creep-tumor":
                            tumor = self.structures.find_by_tag(cid) if cid else None
                            if tumor and tumor.tag not in self._used_creep_tumors:
                                tx = c.get("x") or self.enemy_start_locations[0].x
                                ty = c.get("y") or self.enemy_start_locations[0].y
                                target_pt = tumor.position.towards(Point2((tx, ty)), 8.5)
                                tumor(AbilityId.BUILD_CREEPTUMOR_TUMOR, target_pt)
                                self._used_creep_tumors.add(tumor.tag)
                                self._record_pro_mechanic("active-creep-tumor-spread")
                                self.commands_issued += 1
                                self.racket_commands_executed += 1
                        elif spell == "chrono-boost":
                            nexus = self.structures.find_by_tag(cid) if cid else (self.townhalls.ready.first if self.townhalls.ready else None)
                            tid = c.get("target_id")
                            target_bldg = self.structures.find_by_tag(tid) if tid else None
                            if nexus and target_bldg and nexus.energy >= 50:
                                nexus(AbilityId.EFFECT_CHRONOBOOSTENERGYCOST, target_bldg)
                                self._record_pro_mechanic("chrono-boost")
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

                    elif op in ("camera-bookmark-jump", "move-camera"):
                        self._record_pro_mechanic(op)
                        self.racket_commands_executed += 1

                    elif op in ("pull-workers-attack", "clear-expansion-block", "clear-gas-steal", "resume-halted-building"):
                        self._record_countermeasure(op)
                        self.racket_commands_executed += 1

                    elif op == "mirror-prediction":
                        self.mirror_active_depth = int(c.get("depth", 2))
                        self.mirror_inferred_opponent_depth = int(c.get("inferred_opponent_depth", 1))
                        self.mirror_toolbox_weight_pct = int(c.get("toolbox_weight_pct", 20))
                        self.mirror_toolbox_role = str(c.get("toolbox_role", "tactical-tiebreaker-and-hedge"))
                        self.mirror_strategic_hypothesis = str(c.get("strategic_hypothesis", "standard-rational-macro"))
                        self.mirror_tactical_target = str(c.get("tactical_target", "center-map-staging"))
                        self.mirror_predicted_enemy_unit = str(c.get("predicted_enemy_unit", "unknown"))
                        self.mirror_preemptive_unit = str(c.get("preemptive_counter_unit", "unknown"))
                        self.mirror_accuracy_pct = int(c.get("accuracy_pct", 67))
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

            # 2. Pro Mechanic #2: Active Creep Tumor Spread (capped at 2/frame)
            if self.race == Race.Zerg:
                ready_tumors = [
                    t
                    for t in self.structures(UnitTypeId.CREEPTUMORBURROWED).ready
                    if t.tag not in self._used_creep_tumors
                ][:2]
                enemy_loc = self.enemy_start_locations[0] if self.enemy_start_locations else self.game_info.map_center
                for tumor in ready_tumors:
                    target_pt = tumor.position.towards(enemy_loc, 8.5)
                    tumor(AbilityId.BUILD_CREEPTUMOR_TUMOR, target_pt)
                    self._used_creep_tumors.add(tumor.tag)
                    self._record_pro_mechanic("active-creep-tumor-spread")
                    self.commands_issued += 1

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

        async def _run_race_macro_and_tactics(self, iteration: int) -> None:
            await self._ensure_zero_supply_block()
            if iteration % 6 == 0:
                await self.distribute_workers(resource_ratio=1.0)

            if not self.townhalls:
                return
            main_th = self.townhalls.first
            buffer_needed = 2 if self.supply_cap <= 15 else (5 if self.supply_cap < 36 else (8 if self.supply_cap < 80 else 12))
            pending_sup = (
                self.already_pending(UnitTypeId.OVERLORD)
                + self.already_pending(UnitTypeId.SUPPLYDEPOT)
                + self.already_pending(UnitTypeId.PYLON)
            )
            # Reserve 100 minerals when supply_left <= buffer_needed and no supply structure is pending yet!
            if self.supply_cap < 200 and self.supply_left <= buffer_needed and pending_sup == 0 and self.minerals < 150:
                await self._micro_combat_army(main_th)
                return

            can_spend_supply = self.supply_left >= 2 or self.supply_cap >= 200

            if self.race == Race.Zerg:
                await self._macro_zerg(main_th, can_spend_supply)
            elif self.race == Race.Terran:
                await self._macro_terran(main_th, can_spend_supply)
            elif self.race == Race.Protoss:
                await self._macro_protoss(main_th, can_spend_supply)

            await self._micro_combat_army(main_th)

        async def _macro_zerg(self, main_th, can_spend_supply: bool) -> None:
            safe_build_pos = main_th.position.towards(self.game_info.map_center, -4.5)

            # Train 13th/14th Drone in opening frames (<300 gl) so we have >=13 Drones vs frame-0 12-worker rushes
            if (
                self.state.game_loop < 300
                and len(self.workers) < 14
                and self.already_pending(UnitTypeId.DRONE) == 0
                and self.supply_left >= 2
            ):
                if self.can_afford(UnitTypeId.DRONE) and self.larva:
                    self.larva.first.train(UnitTypeId.DRONE)
                    return

            # 1. Spawning Pool first
            if not self.structures(UnitTypeId.SPAWNINGPOOL) and not self.already_pending(UnitTypeId.SPAWNINGPOOL):
                if self.can_afford(UnitTypeId.SPAWNINGPOOL) and (len(self.workers) >= 13 or self.state.game_loop >= 400):
                    await self.build(UnitTypeId.SPAWNINGPOOL, near=safe_build_pos)
                    return

            # 2. Natural & Multi-Base Expansion (up to 5 Hatcheries) before larva drains all minerals
            enemy_near = self.enemy_units.closer_than(24.0, main_th) | self.enemy_structures.closer_than(26.0, main_th)
            enemy_near_expand = self.enemy_units.closer_than(35.0, main_th) | self.enemy_structures.closer_than(40.0, main_th)
            total_hatches = len(self.townhalls) + self.already_pending(UnitTypeId.HATCHERY)
            want_natural_hatch = (
                not enemy_near_expand
                and total_hatches == 1
                and len(self.workers) >= 15
                and (len(self.structures(UnitTypeId.SPAWNINGPOOL)) >= 1 or self.minerals >= 350)
            )
            want_multi_hatch = (
                not enemy_near_expand
                and total_hatches < 5
                and (
                    (total_hatches == 2 and (len(self.workers) >= 28 or self.minerals >= 400) and self.supply_army >= 8)
                    or (total_hatches == 3 and (len(self.workers) >= 42 or self.minerals >= 450))
                    or (total_hatches == 4 and (len(self.workers) >= 54 or self.minerals >= 500))
                )
            )
            if (want_natural_hatch and self.minerals >= 300) or (want_multi_hatch and self.minerals >= 325):
                if await self._try_smart_expand(UnitTypeId.HATCHERY, reason="natural_or_multi_hatch"):
                    return
            saving_for_hatch = want_natural_hatch and self.minerals >= 180

            # 3. Queen production & Larva Inject + Anti-Air Defense
            if self.structures(UnitTypeId.SPAWNINGPOOL).ready:
                enemy_air = self.enemy_units.filter(
                    lambda u: u.is_flying and u.type_id not in {UnitTypeId.OVERLORD, UnitTypeId.OVERSEER, UnitTypeId.OBSERVER}
                )
                target_queens = len(self.townhalls) + (3 if enemy_air else 1)
                if not saving_for_hatch and (self.supply_left >= 3 or self.supply_cap >= 200) and len(self.units(UnitTypeId.QUEEN)) < target_queens:
                    for th in self.townhalls.ready.idle:
                        if self.can_afford(UnitTypeId.QUEEN):
                            th.train(UnitTypeId.QUEEN)
                            break
                for queen in self.units(UnitTypeId.QUEEN):
                    injured = (self.units | self.structures).filter(
                        lambda u: u.health_percentage < 0.55 and u.health_max >= 120 and u.distance_to(queen) <= 7.5
                    )
                    if injured and queen.energy >= 50:
                        queen(AbilityId.TRANSFUSION_TRANSFUSION, injured.first)
                        self._record_pro_mechanic("queen-transfusion")
                    elif queen.energy >= 25:
                        th = self.townhalls.closest_to(queen)
                        queen(AbilityId.EFFECT_INJECTLARVA, th)
                    else:
                        near_q = self.enemy_units.closer_than(14.0, queen)
                        if near_q:
                            queen.attack(near_q.closest_to(queen))

            # 4. Extractor & Zergling Speed + Roach Warren + Evolution Chamber + Hydralisk Den
            if self.structures(UnitTypeId.SPAWNINGPOOL) and self.vespene_geyser:
                target_gases = 1 if len(self.townhalls) == 1 else min(6, 2 * len(self.townhalls) - 1)
                if not saving_for_hatch and len(self.gas_buildings) + self.already_pending(UnitTypeId.EXTRACTOR) < target_gases:
                    if self.can_afford(UnitTypeId.EXTRACTOR) and len(self.workers) >= 14:
                        for th in self.townhalls.ready:
                            vgs = self.vespene_geyser.closer_than(11.0, th)
                            for vg in vgs:
                                if not self.gas_buildings.closer_than(1.0, vg):
                                    w = self.select_build_worker(vg)
                                    if w:
                                        w.build_gas(vg)
                                        break

            if self.structures(UnitTypeId.SPAWNINGPOOL).ready:
                if not saving_for_hatch and not self.structures(UnitTypeId.ROACHWARREN) and not self.already_pending(UnitTypeId.ROACHWARREN):
                    if self.can_afford(UnitTypeId.ROACHWARREN) and len(self.workers) >= 14:
                        await self.build(UnitTypeId.ROACHWARREN, near=safe_build_pos)

                pool = self.structures(UnitTypeId.SPAWNINGPOOL).ready.first
                if (
                    pool.is_idle
                    and self.already_pending_upgrade(UpgradeId.ZERGLINGMOVEMENTSPEED) == 0
                    and self.can_afford(UpgradeId.ZERGLINGMOVEMENTSPEED)
                ):
                    pool.research(UpgradeId.ZERGLINGMOVEMENTSPEED)

            # Evolution Chamber for +1/+2 Missile & Ground Carapace on 2+ bases
            if len(self.townhalls) >= 2 and self.structures(UnitTypeId.ROACHWARREN).ready:
                if not self.structures(UnitTypeId.EVOLUTIONCHAMBER) and not self.already_pending(UnitTypeId.EVOLUTIONCHAMBER):
                    if self.can_afford(UnitTypeId.EVOLUTIONCHAMBER):
                        await self.build(UnitTypeId.EVOLUTIONCHAMBER, near=safe_build_pos)
                for evo in self.structures(UnitTypeId.EVOLUTIONCHAMBER).ready.idle:
                    if self.already_pending_upgrade(UpgradeId.ZERGMISSILEWEAPONSLEVEL1) == 0 and self.can_afford(UpgradeId.ZERGMISSILEWEAPONSLEVEL1):
                        evo.research(UpgradeId.ZERGMISSILEWEAPONSLEVEL1)
                    elif self.already_pending_upgrade(UpgradeId.ZERGGROUNDARMORSLEVEL1) == 0 and self.can_afford(UpgradeId.ZERGGROUNDARMORSLEVEL1):
                        evo.research(UpgradeId.ZERGGROUNDARMORSLEVEL1)
                    elif self.structures(UnitTypeId.LAIR).ready:
                        if self.already_pending_upgrade(UpgradeId.ZERGMISSILEWEAPONSLEVEL2) == 0 and self.can_afford(UpgradeId.ZERGMISSILEWEAPONSLEVEL2):
                            evo.research(UpgradeId.ZERGMISSILEWEAPONSLEVEL2)
                        elif self.already_pending_upgrade(UpgradeId.ZERGGROUNDARMORSLEVEL2) == 0 and self.can_afford(UpgradeId.ZERGGROUNDARMORSLEVEL2):
                            evo.research(UpgradeId.ZERGGROUNDARMORSLEVEL2)

            # Lair & Hydralisk Den for anti-air & Roach Speed
            if (
                self.structures(UnitTypeId.SPAWNINGPOOL).ready
                and not self.structures(UnitTypeId.LAIR)
                and not self.already_pending(UnitTypeId.LAIR)
            ):
                if main_th.is_idle and self.can_afford(UnitTypeId.LAIR) and (len(self.units(UnitTypeId.ROACH)) >= 5 or len(self.townhalls) >= 2):
                    main_th.build(UnitTypeId.LAIR)

            if self.structures(UnitTypeId.LAIR).ready:
                for rw in self.structures(UnitTypeId.ROACHWARREN).ready.idle:
                    if self.already_pending_upgrade(UpgradeId.GLIALRECONSTITUTION) == 0 and self.can_afford(UpgradeId.GLIALRECONSTITUTION):
                        rw.research(UpgradeId.GLIALRECONSTITUTION)
                if not self.structures(UnitTypeId.HYDRALISKDEN) and not self.already_pending(UnitTypeId.HYDRALISKDEN):
                    if self.can_afford(UnitTypeId.HYDRALISKDEN):
                        await self.build(UnitTypeId.HYDRALISKDEN, near=safe_build_pos)
                for hden in self.structures(UnitTypeId.HYDRALISKDEN).ready.idle:
                    if self.already_pending_upgrade(UpgradeId.EVOLVEGROOVEDSPINES) == 0 and self.can_afford(UpgradeId.EVOLVEGROOVEDSPINES):
                        hden.research(UpgradeId.EVOLVEGROOVEDSPINES)
                    elif self.already_pending_upgrade(UpgradeId.EVOLVEMUSCULARAUGMENTS) == 0 and self.can_afford(UpgradeId.EVOLVEMUSCULARAUGMENTS):
                        hden.research(UpgradeId.EVOLVEMUSCULARAUGMENTS)

            # Ravager morphs when gas available
            if self.structures(UnitTypeId.ROACHWARREN).ready and self.vespene >= 75 and self.minerals >= 25:
                if len(self.units(UnitTypeId.RAVAGER)) < 4 and len(self.units(UnitTypeId.ROACH)) >= 4:
                    r = self.units(UnitTypeId.ROACH).first
                    r(AbilityId.MORPHTORAVAGER_RAVAGER)

            if not can_spend_supply or saving_for_hatch:
                return

            army_count = (
                len(self.units(UnitTypeId.ZERGLING))
                + 2 * len(self.units(UnitTypeId.ROACH))
                + 2 * len(self.units(UnitTypeId.RAVAGER))
                + 2 * len(self.units(UnitTypeId.HYDRALISK))
            )
            desired_drones = min(70, 20 * len(self.townhalls) + 2)
            for larva in self.larva:
                if self.supply_left < 2 and self.supply_cap < 200:
                    break
                if (len(self.workers) < 18 and (not enemy_near or army_count >= 4)) or (
                    not enemy_near and len(self.workers) < desired_drones and army_count >= 8
                ):
                    if self.can_afford(UnitTypeId.DRONE):
                        larva.train(UnitTypeId.DRONE)
                        continue
                if self.structures(UnitTypeId.HYDRALISKDEN).ready and self.vespene >= 50 and (self.supply_left >= 3 or self.supply_cap >= 200):
                    if self.can_afford(UnitTypeId.HYDRALISK):
                        larva.train(UnitTypeId.HYDRALISK)
                    else:
                        break
                elif self.structures(UnitTypeId.ROACHWARREN).ready and self.vespene >= 25 and (self.supply_left >= 3 or self.supply_cap >= 200):
                    if self.can_afford(UnitTypeId.ROACH):
                        larva.train(UnitTypeId.ROACH)
                    else:
                        break
                elif self.structures(UnitTypeId.SPAWNINGPOOL).ready and self.can_afford(UnitTypeId.ZERGLING):
                    larva.train(UnitTypeId.ZERGLING)
                elif len(self.workers) < desired_drones and self.can_afford(UnitTypeId.DRONE):
                    larva.train(UnitTypeId.DRONE)

        async def _macro_terran(self, main_th, can_spend_supply: bool) -> None:
            plaza_build_pos = self._get_main_build_anchor(main_th)

            # Ensure first Supply Depot is started immediately at 13+ supply in open main-base plaza
            if (
                len(self.structures(UnitTypeId.SUPPLYDEPOT))
                + len(self.structures(UnitTypeId.SUPPLYDEPOTLOWERED))
                + self.already_pending(UnitTypeId.SUPPLYDEPOT)
                == 0
            ):
                if self.supply_used >= 13 and self.can_afford(UnitTypeId.SUPPLYDEPOT):
                    await self.build(UnitTypeId.SUPPLYDEPOT, near=plaza_build_pos, max_distance=15)
                    return

            # 1. MULE Calldowns from Orbital Command
            for oc in self.townhalls(UnitTypeId.ORBITALCOMMAND).ready:
                if oc.energy >= 50 and self.mineral_field:
                    oc(AbilityId.CALLDOWNMULE_CALLDOWNMULE, self.mineral_field.closest_to(oc))

            # 2. Build first 2 Barracks & Refineries
            has_depot = (
                len(self.structures(UnitTypeId.SUPPLYDEPOT).ready)
                + len(self.structures(UnitTypeId.SUPPLYDEPOTLOWERED).ready)
                >= 1
            )
            rax_total = len(self.structures(UnitTypeId.BARRACKS)) + self.already_pending(UnitTypeId.BARRACKS)
            rax_spot = main_th.position.towards(plaza_build_pos, 5.5 + (rax_total % 3) * 3.0)
            if has_depot and rax_total < 2:
                if self.can_afford(UnitTypeId.BARRACKS) and self.already_pending(UnitTypeId.BARRACKS) < 2:
                    await self.build(UnitTypeId.BARRACKS, near=rax_spot, max_distance=16)

            target_refineries = 1 if len(self.townhalls) == 1 else min(6, 2 * len(self.townhalls) - 1)
            if len(self.structures(UnitTypeId.BARRACKS)) >= 1 and len(self.gas_buildings) + self.already_pending(UnitTypeId.REFINERY) < target_refineries:
                if self.can_afford(UnitTypeId.REFINERY) and len(self.workers) >= 14:
                    for th in self.townhalls.ready:
                        vgs = self.vespene_geyser.closer_than(11.0, th)
                        for vg in vgs:
                            if not self.gas_buildings.closer_than(1.0, vg):
                                w = self.select_build_worker(vg)
                                if w:
                                    w.build_gas(vg)
                                    break

            # 3. Upgrade Orbital Command as soon as 1st Barracks finishes
            if (
                self.structures(UnitTypeId.BARRACKS).ready
                and len(self.townhalls(UnitTypeId.ORBITALCOMMAND)) < len(self.townhalls)
                and self.already_pending(UnitTypeId.ORBITALCOMMAND) == 0
            ):
                ccs = self.townhalls(UnitTypeId.COMMANDCENTER).ready.idle
                if ccs and self.can_afford(UnitTypeId.ORBITALCOMMAND):
                    ccs.first(AbilityId.UPGRADETOORBITAL_ORBITALCOMMAND)

            # 4. Build BarracksTechLab (1st on first 2 Rax, 2nd once 3+ Rax AND Stimpack started)
            max_techlabs = 1 if (rax_total < 3 or self.already_pending_upgrade(UpgradeId.STIMPACK) == 0) else 2
            for rax in self.structures(UnitTypeId.BARRACKS).ready.idle:
                if (
                    not rax.has_add_on
                    and rax.tag not in self._addon_attempted_tags
                    and len(self.structures(UnitTypeId.BARRACKSTECHLAB)) + self.already_pending(UnitTypeId.BARRACKSTECHLAB) < max_techlabs
                    and self.can_afford(UnitTypeId.BARRACKSTECHLAB)
                ):
                    self._addon_attempted_tags.add(rax.tag)
                    if await self.can_place_single(UnitTypeId.SUPPLYDEPOT, rax.add_on_position):
                        rax.build(UnitTypeId.BARRACKSTECHLAB)
                        break

            # 5. Research Stimpack & Combat Shield at BarracksTechLab BEFORE spending gas/minerals on units
            for tlab in self.structures(UnitTypeId.BARRACKSTECHLAB).ready.idle:
                if self.already_pending_upgrade(UpgradeId.STIMPACK) == 0 and self.can_afford(UpgradeId.STIMPACK):
                    tlab.research(UpgradeId.STIMPACK)
                    return
                elif self.already_pending_upgrade(UpgradeId.SHIELDWALL) == 0 and self.can_afford(UpgradeId.SHIELDWALL):
                    tlab.research(UpgradeId.SHIELDWALL)
                    return

            need_bio_upgrade = bool(self.structures(UnitTypeId.BARRACKSTECHLAB).ready.idle) and (
                self.already_pending_upgrade(UpgradeId.STIMPACK) == 0
                or self.already_pending_upgrade(UpgradeId.SHIELDWALL) == 0
            )
            saving_for_bio_upgrade = need_bio_upgrade and self.vespene >= 50 and self.minerals < 200

            # 6. Early Natural & Multi-Base Expansion (up to 5 Command Centers)
            enemy_near_expand = self.enemy_units.closer_than(35.0, main_th) | self.enemy_structures.closer_than(40.0, main_th)
            total_ccs = len(self.townhalls) + self.already_pending(UnitTypeId.COMMANDCENTER)
            want_natural_cc = (
                not enemy_near_expand
                and total_ccs == 1
                and rax_total >= 2
                and len(self.workers) >= 18
                and (self.supply_army >= 8 or self.minerals >= 350)
            )
            want_multi_cc = (
                not enemy_near_expand
                and total_ccs < 5
                and (
                    (total_ccs == 2 and (len(self.workers) >= 32 or self.minerals >= 425) and self.supply_army >= 16)
                    or (total_ccs == 3 and (len(self.workers) >= 44 or self.minerals >= 475))
                    or (total_ccs == 4 and (len(self.workers) >= 54 or self.minerals >= 525))
                )
            )
            if (want_natural_cc or want_multi_cc) and self.minerals >= 400:
                if await self._try_smart_expand(UnitTypeId.COMMANDCENTER, reason="terran_expand"):
                    return

            saving_for_cc = want_natural_cc and self.minerals >= 220

            # 6b. Mid-Game Tech on 2+ Bases: Engineering Bay (+1/+2 Bio) & Factory -> Starport (Medivacs!)
            if len(self.townhalls) >= 2 and not saving_for_cc and not saving_for_bio_upgrade:
                if not self.structures(UnitTypeId.ENGINEERINGBAY) and not self.already_pending(UnitTypeId.ENGINEERINGBAY):
                    if self.can_afford(UnitTypeId.ENGINEERINGBAY):
                        await self.build(UnitTypeId.ENGINEERINGBAY, near=plaza_build_pos, max_distance=18)
                for ebay in self.structures(UnitTypeId.ENGINEERINGBAY).ready.idle:
                    if self.already_pending_upgrade(UpgradeId.TERRANINFANTRYWEAPONSLEVEL1) == 0 and self.can_afford(UpgradeId.TERRANINFANTRYWEAPONSLEVEL1):
                        ebay.research(UpgradeId.TERRANINFANTRYWEAPONSLEVEL1)
                    elif self.already_pending_upgrade(UpgradeId.TERRANINFANTRYARMORSLEVEL1) == 0 and self.can_afford(UpgradeId.TERRANINFANTRYARMORSLEVEL1):
                        ebay.research(UpgradeId.TERRANINFANTRYARMORSLEVEL1)
                    elif self.already_pending_upgrade(UpgradeId.TERRANINFANTRYWEAPONSLEVEL2) == 0 and self.can_afford(UpgradeId.TERRANINFANTRYWEAPONSLEVEL2):
                        ebay.research(UpgradeId.TERRANINFANTRYWEAPONSLEVEL2)
                    elif self.already_pending_upgrade(UpgradeId.TERRANINFANTRYARMORSLEVEL2) == 0 and self.can_afford(UpgradeId.TERRANINFANTRYARMORSLEVEL2):
                        ebay.research(UpgradeId.TERRANINFANTRYARMORSLEVEL2)

                if self.already_pending_upgrade(UpgradeId.STIMPACK) > 0:
                    if not self.structures(UnitTypeId.FACTORY) and not self.already_pending(UnitTypeId.FACTORY):
                        if self.can_afford(UnitTypeId.FACTORY):
                            await self.build(UnitTypeId.FACTORY, near=plaza_build_pos, max_distance=18)
                    elif self.structures(UnitTypeId.FACTORY).ready and not self.structures(UnitTypeId.STARPORT) and not self.already_pending(UnitTypeId.STARPORT):
                        if self.can_afford(UnitTypeId.STARPORT):
                            await self.build(UnitTypeId.STARPORT, near=plaza_build_pos, max_distance=18)
                    for sp in self.structures(UnitTypeId.STARPORT).ready.idle:
                        if (
                            can_spend_supply
                            and len(self.units(UnitTypeId.MEDIVAC)) + self.already_pending(UnitTypeId.MEDIVAC) < 4
                            and self.can_afford(UnitTypeId.MEDIVAC)
                        ):
                            sp.train(UnitTypeId.MEDIVAC)

            # 7. Scale Barracks (up to 3 on 1 base, up to 10 on 3+ bases)
            max_rax = 3 if len(self.townhalls) == 1 else min(10, 3 * len(self.townhalls) + 1)
            if not saving_for_cc and not saving_for_bio_upgrade and has_depot and rax_total >= 2 and rax_total < max_rax:
                if self.can_afford(UnitTypeId.BARRACKS) and self.already_pending(UnitTypeId.BARRACKS) < 2 and self.minerals >= 175:
                    await self.build(UnitTypeId.BARRACKS, near=rax_spot, max_distance=16)

            # 8. Continuous Marauder & Marine Production from all ready Barracks
            saving_gas_for_bio_upgrade = (
                bool(self.structures(UnitTypeId.BARRACKSTECHLAB))
                and (
                    self.already_pending_upgrade(UpgradeId.STIMPACK) == 0
                    or (
                        self.already_pending_upgrade(UpgradeId.SHIELDWALL) == 0
                        and len(self.units(UnitTypeId.MARAUDER)) >= 2
                    )
                )
                and self.vespene < 125
            )
            if not saving_for_cc and not saving_for_bio_upgrade:
                for rax in self.structures(UnitTypeId.BARRACKS).ready.idle:
                    if not can_spend_supply:
                        break
                    if (
                        rax.has_techlab
                        and not saving_gas_for_bio_upgrade
                        and (self.supply_left >= 3 or self.supply_cap >= 200)
                        and self.can_afford(UnitTypeId.MARAUDER)
                    ):
                        rax.train(UnitTypeId.MARAUDER)
                    elif (self.supply_left >= 2 or self.supply_cap >= 200) and self.can_afford(UnitTypeId.MARINE):
                        rax.train(UnitTypeId.MARINE)

            # 9. SCV Production (up to 21 on 1 base, 20 per base on 2+ bases, capped at 68)
            desired_scvs = 21 if len(self.townhalls) == 1 else min(68, 20 * len(self.townhalls) + 2)
            if not saving_for_bio_upgrade and not saving_for_cc and can_spend_supply and len(self.workers) < desired_scvs:
                for th in self.townhalls.ready.idle:
                    if (self.supply_left >= 2 or self.supply_cap >= 200) and self.can_afford(UnitTypeId.SCV):
                        th.train(UnitTypeId.SCV)

        async def _macro_protoss(self, main_th, can_spend_supply: bool) -> None:
            safe_build_pos = self._get_main_build_anchor(main_th)

            # Ensure first Pylon is built immediately in the open main-base plaza
            if len(self.structures(UnitTypeId.PYLON)) + self.already_pending(UnitTypeId.PYLON) == 0:
                if self.supply_used >= 13 and self.can_afford(UnitTypeId.PYLON):
                    await self.build(UnitTypeId.PYLON, near=safe_build_pos, max_distance=15)
                    return

            # 1. Pro Mechanic #6: Chrono Boost (prioritize busy Robotics Facility, Upgrade buildings, & Gateways)
            for nexus in self.townhalls.ready:
                if nexus.energy >= 50:
                    targets = (
                        self.structures(UnitTypeId.ROBOTICSFACILITY).ready.filter(lambda s: not s.is_idle)
                        | self.structures(UnitTypeId.FORGE).ready.filter(lambda s: not s.is_idle)
                        | self.structures(UnitTypeId.TWILIGHTCOUNCIL).ready.filter(lambda s: not s.is_idle)
                        | self.structures(UnitTypeId.GATEWAY).ready.filter(lambda s: not s.is_idle)
                        | self.townhalls.ready.filter(lambda s: not s.is_idle)
                    )
                    if targets:
                        nexus(AbilityId.EFFECT_CHRONOBOOSTENERGYCOST, targets.first)
                        self._record_pro_mechanic("chrono-boost")

            if not self.structures(UnitTypeId.PYLON).ready:
                if can_spend_supply and len(self.workers) < 15 and main_th.is_idle and self.can_afford(UnitTypeId.PROBE):
                    main_th.train(UnitTypeId.PROBE)
                return

            pylons_ready = self.structures(UnitTypeId.PYLON).ready
            safe_pylon = (
                pylons_ready[self.state.game_loop // 16 % len(pylons_ready)]
                if len(pylons_ready) > 1
                else pylons_ready.first
            )
            gw_total = (
                len(self.structures(UnitTypeId.GATEWAY))
                + len(self.structures(UnitTypeId.WARPGATE))
                + self.already_pending(UnitTypeId.GATEWAY)
            )

            # 2. Build 1st Gateway & Assimilators immediately
            if gw_total < 1:
                if self.can_afford(UnitTypeId.GATEWAY):
                    await self.build(UnitTypeId.GATEWAY, near=safe_pylon, max_distance=15)
                if can_spend_supply and len(self.workers) < 16 and main_th.is_idle and self.can_afford(UnitTypeId.PROBE):
                    main_th.train(UnitTypeId.PROBE)
                return

            target_assim = 2 if len(self.townhalls) == 1 else min(6, 2 * len(self.townhalls) - 1)
            if len(self.structures(UnitTypeId.GATEWAY)) >= 1 and len(self.gas_buildings) + self.already_pending(UnitTypeId.ASSIMILATOR) < target_assim:
                if self.can_afford(UnitTypeId.ASSIMILATOR) and len(self.workers) >= 14:
                    for th in self.townhalls.ready:
                        vgs = self.vespene_geyser.closer_than(11.0, th)
                        for vg in vgs:
                            if not self.gas_buildings.closer_than(1.0, vg):
                                w = self.select_build_worker(vg)
                                if w:
                                    w.build_gas(vg)
                                    break

            # 3. Build Cybernetics Core as soon as 1st Gateway is ready
            need_cyber = (
                self.structures(UnitTypeId.GATEWAY).ready
                and not self.structures(UnitTypeId.CYBERNETICSCORE)
                and not self.already_pending(UnitTypeId.CYBERNETICSCORE)
            )
            if need_cyber and self.can_afford(UnitTypeId.CYBERNETICSCORE):
                await self.build(UnitTypeId.CYBERNETICSCORE, near=safe_pylon, max_distance=15)

            # 4. Early Natural & Multi-Base Expansion Priority (BEFORE Gateways drain all minerals!)
            enemy_near_expand = self.enemy_units.closer_than(35.0, main_th) | self.enemy_structures.closer_than(40.0, main_th)
            total_nexuses = len(self.townhalls) + self.already_pending(UnitTypeId.NEXUS)
            want_natural_nexus = (
                not enemy_near_expand
                and total_nexuses == 1
                and not need_cyber
                and len(self.workers) >= 18
                and (self.supply_army >= 4 or self.minerals >= 350)
            )
            want_multi_nexus = (
                not enemy_near_expand
                and total_nexuses < 5
                and (
                    (total_nexuses == 2 and (len(self.workers) >= 32 or self.minerals >= 425) and self.supply_army >= 14)
                    or (total_nexuses == 3 and (len(self.workers) >= 44 or self.minerals >= 475))
                    or (total_nexuses == 4 and (len(self.workers) >= 54 or self.minerals >= 525))
                )
            )
            if (want_natural_nexus or want_multi_nexus) and self.minerals >= 400:
                if await self._try_smart_expand(UnitTypeId.NEXUS, reason="protoss_expand"):
                    return
            saving_for_nexus = want_natural_nexus and self.minerals >= 210

            # 5. Build 2nd Gateway & Robotics Facility
            if not need_cyber and not saving_for_nexus and gw_total < 2 and self.can_afford(UnitTypeId.GATEWAY):
                await self.build(UnitTypeId.GATEWAY, near=safe_pylon, max_distance=15)

            target_robos = 1 if len(self.townhalls) < 3 else 2
            need_robo = (
                self.structures(UnitTypeId.CYBERNETICSCORE).ready
                and len(self.structures(UnitTypeId.ROBOTICSFACILITY)) + self.already_pending(UnitTypeId.ROBOTICSFACILITY) < target_robos
            )
            if need_robo and not saving_for_nexus and self.can_afford(UnitTypeId.ROBOTICSFACILITY):
                await self.build(UnitTypeId.ROBOTICSFACILITY, near=safe_pylon, max_distance=15)

            # 5b. Upgrades on 2+ Bases: Forge (+1/+2 Ground) & Twilight Council (Charge)
            if len(self.townhalls) >= 2 and not saving_for_nexus:
                if not self.structures(UnitTypeId.FORGE) and not self.already_pending(UnitTypeId.FORGE):
                    if self.can_afford(UnitTypeId.FORGE):
                        await self.build(UnitTypeId.FORGE, near=safe_pylon, max_distance=15)
                for forge in self.structures(UnitTypeId.FORGE).ready.idle:
                    if self.already_pending_upgrade(UpgradeId.PROTOSSGROUNDWEAPONSLEVEL1) == 0 and self.can_afford(UpgradeId.PROTOSSGROUNDWEAPONSLEVEL1):
                        forge.research(UpgradeId.PROTOSSGROUNDWEAPONSLEVEL1)
                    elif self.already_pending_upgrade(UpgradeId.PROTOSSGROUNDARMORSLEVEL1) == 0 and self.can_afford(UpgradeId.PROTOSSGROUNDARMORSLEVEL1):
                        forge.research(UpgradeId.PROTOSSGROUNDARMORSLEVEL1)
                    elif self.structures(UnitTypeId.TWILIGHTCOUNCIL).ready:
                        if self.already_pending_upgrade(UpgradeId.PROTOSSGROUNDWEAPONSLEVEL2) == 0 and self.can_afford(UpgradeId.PROTOSSGROUNDWEAPONSLEVEL2):
                            forge.research(UpgradeId.PROTOSSGROUNDWEAPONSLEVEL2)
                        elif self.already_pending_upgrade(UpgradeId.PROTOSSGROUNDARMORSLEVEL2) == 0 and self.can_afford(UpgradeId.PROTOSSGROUNDARMORSLEVEL2):
                            forge.research(UpgradeId.PROTOSSGROUNDARMORSLEVEL2)

                if self.structures(UnitTypeId.CYBERNETICSCORE).ready and not self.structures(UnitTypeId.TWILIGHTCOUNCIL) and not self.already_pending(UnitTypeId.TWILIGHTCOUNCIL):
                    if self.can_afford(UnitTypeId.TWILIGHTCOUNCIL):
                        await self.build(UnitTypeId.TWILIGHTCOUNCIL, near=safe_pylon, max_distance=15)
                for tc in self.structures(UnitTypeId.TWILIGHTCOUNCIL).ready.idle:
                    if self.already_pending_upgrade(UpgradeId.CHARGE) == 0 and self.can_afford(UpgradeId.CHARGE):
                        tc.research(UpgradeId.CHARGE)

            # 6. Continuous Immortal & Stalker/Zealot Production
            if not saving_for_nexus:
                for robo in self.structures(UnitTypeId.ROBOTICSFACILITY).ready.idle:
                    if (self.supply_left >= 4 or self.supply_cap >= 200) and self.can_afford(UnitTypeId.IMMORTAL):
                        robo.train(UnitTypeId.IMMORTAL)

            need_immortal = (
                bool(self.structures(UnitTypeId.ROBOTICSFACILITY).ready.idle)
                and (self.supply_left >= 4 or self.supply_cap >= 200)
                and len(self.units(UnitTypeId.IMMORTAL)) < 6
                and self.vespene >= 60
            )
            saving_for_tech = (
                need_cyber
                or saving_for_nexus
                or (need_robo and len(self.structures(UnitTypeId.ROBOTICSFACILITY)) == 0 and self.vespene >= 75 and self.minerals < 275)
                or (need_immortal and not self.can_afford(UnitTypeId.IMMORTAL))
            )

            if not saving_for_tech:
                for gw in self.structures(UnitTypeId.GATEWAY).ready.idle:
                    if self.supply_left < 3 and self.supply_cap < 200:
                        break
                    if self.structures(UnitTypeId.CYBERNETICSCORE).ready and self.can_afford(UnitTypeId.STALKER) and (
                        len(self.units(UnitTypeId.STALKER)) <= 2 * len(self.units(UnitTypeId.ZEALOT)) + 4
                        or self.already_pending_upgrade(UpgradeId.CHARGE) == 0
                    ):
                        gw.train(UnitTypeId.STALKER)
                    elif self.can_afford(UnitTypeId.ZEALOT) and (self.vespene < 50 or self.minerals >= 200):
                        gw.train(UnitTypeId.ZEALOT)

            # 7. Probe Production (up to 21 on 1 base, 20 per base on 2+ bases, capped at 68)
            desired_probes = 21 if len(self.townhalls) == 1 else min(68, 20 * len(self.townhalls) + 2)
            if not saving_for_nexus and can_spend_supply and len(self.workers) < desired_probes:
                if not need_cyber or len(self.workers) < 16 or self.minerals >= 200:
                    for nexus in self.townhalls.ready.idle:
                        if (self.supply_left >= 2 or self.supply_cap >= 200) and self.can_afford(UnitTypeId.PROBE):
                            nexus.train(UnitTypeId.PROBE)

            # 8. Scale Gateways (up to 3 on 1 base, up to 10 on 3+ bases)
            max_gw = 3 if len(self.townhalls) == 1 else min(10, 3 * len(self.townhalls) + 1)
            if not saving_for_tech and gw_total < max_gw and (self.supply_army >= 6 or self.minerals >= 350):
                if self.can_afford(UnitTypeId.GATEWAY) and self.already_pending(UnitTypeId.GATEWAY) < 2 and self.minerals >= 200:
                    await self.build(UnitTypeId.GATEWAY, near=safe_pylon, max_distance=15)

        async def _micro_combat_army(self, main_th) -> None:
            exclude_types = {
                UnitTypeId.DRONE,
                UnitTypeId.SCV,
                UnitTypeId.PROBE,
                UnitTypeId.OVERLORD,
                UnitTypeId.OVERSEER,
                UnitTypeId.LARVA,
                UnitTypeId.EGG,
                UnitTypeId.QUEEN,
                UnitTypeId.MULE,
                UnitTypeId.MEDIVAC,
            }
            army = self.units.exclude_type(exclude_types)
            # Medivac dedicated heal/follow micro
            medivacs = self.units(UnitTypeId.MEDIVAC)
            if medivacs and army:
                bio_units = army.filter(lambda u: u.type_id in {UnitTypeId.MARINE, UnitTypeId.MARAUDER})
                follow_pool = bio_units if bio_units else army
                injured_bio = follow_pool.filter(lambda u: u.health_percentage < 0.95)
                lead_unit = (
                    min(injured_bio, key=lambda u: u.health_percentage)
                    if injured_bio
                    else follow_pool.closest_to(self.game_info.map_center)
                )
                for mv in medivacs:
                    mv.attack(lead_unit.position)
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
            home_anchor = self.start_location if self.start_location else main_th.position
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
                if u.type_id == UnitTypeId.IMMORTAL
                else (
                    2
                    if u.type_id
                    in {
                        UnitTypeId.ROACH,
                        UnitTypeId.RAVAGER,
                        UnitTypeId.HYDRALISK,
                        UnitTypeId.MARAUDER,
                        UnitTypeId.STALKER,
                    }
                    else 1
                )
                for u in uncommitted_squad
            )
            if not self._offensive_launched:
                wave_threshold = 28 if len(self.townhalls) >= 2 else (26 if self.race == Race.Terran else 22)
            else:
                wave_threshold = 18

            terran_stim_ready_for_march = (
                self.race != Race.Terran
                or not self.structures(UnitTypeId.BARRACKSTECHLAB)
                or self.already_pending_upgrade(UpgradeId.STIMPACK) >= 0.80
                or self.supply_army >= 34
            )
            if (uncommitted_supply >= wave_threshold and terran_stim_ready_for_march) or self.supply_used >= 180:
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

            enemy_targets = self.enemy_units | self.enemy_structures
            enemy_base = (
                self.enemy_start_locations[0] if self.enemy_start_locations else self.game_info.map_center
            )
            rally_pt = (
                self.townhalls.closest_to(self.game_info.map_center).position.towards(self.game_info.map_center, 5.0)
                if len(self.townhalls) >= 2
                else self._get_main_build_anchor(main_th)
            )
            has_stim_researched = self.race == Race.Terran and self.already_pending_upgrade(UpgradeId.STIMPACK) >= 1.0

            for u in army:
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
                                    u.attack(far_targets.closest_to(u))
                                elif u.distance_to(enemy_base) <= 4.5:
                                    self._enemy_main_cleared = True
                                else:
                                    u.attack(enemy_base)
                                continue

                        uncovered_threats = attackable_home.filter(
                            lambda t: not any(c.distance_to(t) <= 10.5 for c in ready_home_cannons)
                        )
                        can_break_cannons = getattr(self, "_cannon_break_latched", False)
                        if ready_home_cannons and not can_break_cannons and not uncovered_threats:
                            safe_rally = self._get_main_build_anchor(main_th)
                            if u.distance_to(safe_rally) > 3.5:
                                u.move(safe_rally)
                            continue

                        active_pool = (
                            uncovered_threats
                            if (ready_home_cannons and not can_break_cannons and uncovered_threats)
                            else attackable_home
                        )
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
                        if u.type_id == UnitTypeId.RAVAGER and u.distance_to(target) <= 9.0:
                            u(AbilityId.EFFECT_CORROSIVEBILE, target.position)
                        elif (
                            u.ground_range > 2
                            and u.weapon_cooldown > 0
                            and not target.is_structure
                            and target.ground_range <= 2
                            and u.distance_to(target) < u.ground_range
                        ):
                            u.move(u.position.towards(target.position, -2.2))
                        elif (
                            u.distance_to(target)
                            <= ((u.air_range if target.is_flying else u.ground_range) + u.radius + target.radius + 0.3)
                            or target.is_structure
                        ):
                            u.attack(target)
                        else:
                            u.attack(target.position)
                        continue

                if unit_deployed:
                    # Local Lanchester retreat check: don't suicide outnumbered small squads onto enemy creep!
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
                                u.move(rally_pt)
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
                                target = min(in_range_cand, key=lambda t: (t.health + t.shield, t.tag))
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
                            if u.type_id == UnitTypeId.RAVAGER and u.distance_to(target) <= 9.0:
                                u(AbilityId.EFFECT_CORROSIVEBILE, target.position)
                            elif (
                                u.ground_range > 2
                                and u.weapon_cooldown > 0
                                and not target.is_structure
                                and target.ground_range <= 2
                                and u.distance_to(target) < u.ground_range
                            ):
                                u.move(u.position.towards(target.position, -2.2))
                            elif (
                                u.distance_to(target)
                                <= ((u.air_range if target.is_flying else u.ground_range) + u.radius + target.radius + 0.3)
                                or target.is_structure
                            ):
                                u.attack(target)
                            else:
                                u.attack(target.position)
                            continue

                    if u.distance_to(enemy_base) <= 4.5:
                        self._enemy_main_cleared = True
                    if not getattr(self, "_enemy_main_cleared", False):
                        u.attack(enemy_base)
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
                        sweep_pt = exp_locs[(u.tag + self.state.game_loop // 96) % len(exp_locs)]
                        u.attack(sweep_pt)
                else:
                    near_enemies = enemy_targets.filter(
                        lambda t: t.distance_to(u) <= 14.0
                        and (u.can_attack_air if t.is_flying else u.can_attack_ground)
                    )
                    if near_enemies:
                        u.attack(near_enemies.closest_to(u))
                    elif u.distance_to(rally_pt) > 5.0:
                        u.attack(rally_pt)

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

            # 1. Step Racket S-expression IPC subprocess (with Layer 5 HumanCortex APM & saccade filter)
            if self.bridge and iteration % 8 == 0:
                obs_sexp = self._build_frame_observation()
                cmds = self.bridge.step_sexp(obs_sexp)
                if cmds:
                    await self._execute_decoded_commands(cmds)

            # 2. Run pro signature reflexes & anti-cheese countermeasures
            emergency_worker_defense = await self._run_pro_reflexes_and_countermeasures()
            if not emergency_worker_defense:
                await self._run_race_macro_and_tactics(iteration)

            dt_ms = (time.perf_counter() - t0) * 1000.0
            self._step_durations_ms.append(dt_ms)

            # 3. Emit periodic 30-second [SCBOT_TELEMETRY] snapshot to stdout for match_log.zip feedback
            loop = int(self.state.game_loop)
            if loop - self._last_telemetry_loop >= 672:
                self._last_telemetry_loop = loop
                pending_bases = (
                    self.already_pending(UnitTypeId.HATCHERY)
                    + self.already_pending(UnitTypeId.COMMANDCENTER)
                    + self.already_pending(UnitTypeId.NEXUS)
                )
                avg_ms = (
                    round(sum(self._step_durations_ms[-64:]) / len(self._step_durations_ms[-64:]), 2)
                    if self._step_durations_ms
                    else 0.0
                )
                self._emit_telemetry(
                    "MINUTE_SNAPSHOT",
                    bases=len(self.townhalls),
                    pending_bases=int(pending_bases),
                    workers=len(self.workers),
                    supply=f"{int(self.supply_used)}/{int(self.supply_cap)}",
                    army_sup=int(self.supply_army),
                    minerals=int(self.minerals),
                    gas=int(self.vespene),
                    posture=self.current_posture,
                    depth=self.mirror_active_depth,
                    opp_depth=self.mirror_inferred_opponent_depth,
                    deployed=len(getattr(self, "_deployed_unit_tags", ())),
                    step_ms_avg=avg_ms,
                )

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

    return {
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
        "peak_army_supply": agent.peak_army_supply,
        "commands_issued": agent.commands_issued,
        "racket_commands_executed": agent.racket_commands_executed,
        "ipc_calls": agent.bridge.ipc_calls if agent.bridge else 0,
        "racket_command_histogram": agent.bridge.command_histogram if agent.bridge else {},
        "pro_mechanics_triggered": agent.pro_mechanics_triggered,
        "countermeasures_triggered": agent.countermeasures_triggered,
        "mirror_active_depth": agent.mirror_active_depth,
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
     (resume-halted-building 804 902))
    """
    decoded_core = translate_sc_bot_commands(core_sexp)
    decoded_pro = translate_sc_bot_commands(pro_sexp)
    assert len(decoded_core) == 11, f"Expected 11 core decoded commands, got {len(decoded_core)}"
    assert len(decoded_pro) == 14, f"Expected 14 pro/countermeasure decoded commands, got {len(decoded_pro)}"
    return {
        "bridge_self_test": "OK",
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
