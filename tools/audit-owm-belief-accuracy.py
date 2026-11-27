#!/usr/bin/env python3
"""
Standalone replay-vs-log Opponent World Model (OWM) belief accuracy evaluator.

Extracts exact opponent ground truth over time from SC2Replay files via s2protocol
(bases, gases, workers, mineral/gas collection rates, active army value, production
facilities by type, combat units by type, and completed upgrades) and aligns each
replay against dev bot [SCBOT_OWM] telemetry lines (with automatic [SCBOT_STATE]
eB/eG fallback for pre-Loop-87 runs).

Usage:
  python3 tools/audit-owm-belief-accuracy.py <run_dir> [--out-json <path>]
      [--workers 8] [--buckets 1,2,3,4,5,6,8,10,12,15,18]
  python3 tools/audit-owm-belief-accuracy.py --self-test
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import importlib.util
import json
import os
import re
import sys
import types
from pathlib import Path
from typing import Any

DEFAULT_PYLIBS_DIRS = [
    os.environ.get("SC2_ARENA_PYLIBS", ""),
    "/home/sjaconette/sc2-local-arena/pylibs",
]

DEFAULT_BUCKETS_MIN = [1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18]
FPS = 22.4

TOWNHALL_REPLAY_TYPES = {
    "Nexus",
    "CommandCenter",
    "OrbitalCommand",
    "PlanetaryFortress",
    "CommandCenterFlying",
    "OrbitalCommandFlying",
    "Hatchery",
    "Lair",
    "Hive",
}

GAS_REPLAY_TYPES = {
    "Assimilator",
    "AssimilatorRich",
    "Refinery",
    "RefineryRich",
    "Extractor",
    "ExtractorRich",
}

WORKER_REPLAY_TYPES = {
    "Probe",
    "SCV",
    "Drone",
    "DroneBurrowed",
}

PROD_REPLAY_TO_CANON = {
    "Barracks": "barracks",
    "BarracksFlying": "barracks",
    "Factory": "factory",
    "FactoryFlying": "factory",
    "Starport": "starport",
    "StarportFlying": "starport",
    "Gateway": "gateway",
    "WarpGate": "gateway",
    "RoboticsFacility": "robotics-facility",
    "Stargate": "stargate",
    "Hatchery": "hatchery",
    "Lair": "hatchery",
    "Hive": "hatchery",
}

PROD_BELIEF_ALIASES = {
    "barracks": "barracks",
    "barracks-flying": "barracks",
    "factory": "factory",
    "factory-flying": "factory",
    "starport": "starport",
    "starport-flying": "starport",
    "gateway": "gateway",
    "warp-gate": "gateway",
    "robotics-facility": "robotics-facility",
    "stargate": "stargate",
    "hatchery": "hatchery",
    "lair": "hatchery",
    "hive": "hatchery",
}

COMBAT_UNIT_REPLAY_TO_CANON = {
    # Terran
    "Marine": "marine",
    "Marauder": "marauder",
    "Reaper": "reaper",
    "Ghost": "ghost",
    "GhostAlternate": "ghost",
    "GhostNova": "ghost",
    "Hellion": "hellion",
    "HellionTank": "hellbat",
    "WidowMine": "widow-mine",
    "WidowMineBurrowed": "widow-mine",
    "Cyclone": "cyclone",
    "SiegeTank": "siege-tank",
    "SiegeTankSieged": "siege-tank",
    "Thor": "thor",
    "ThorAP": "thor",
    "VikingFighter": "viking",
    "VikingAssault": "viking",
    "Medivac": "medivac",
    "Liberator": "liberator",
    "LiberatorAG": "liberator",
    "Raven": "raven",
    "Banshee": "banshee",
    "Battlecruiser": "battlecruiser",
    # Protoss
    "Zealot": "zealot",
    "Stalker": "stalker",
    "Sentry": "sentry",
    "Adept": "adept",
    "HighTemplar": "high-templar",
    "DarkTemplar": "dark-templar",
    "Archon": "archon",
    "Immortal": "immortal",
    "Colossus": "colossus",
    "Disruptor": "disruptor",
    "Phoenix": "phoenix",
    "VoidRay": "void-ray",
    "Oracle": "oracle",
    "Tempest": "tempest",
    "Carrier": "carrier",
    "Mothership": "mothership",
    "MothershipCore": "mothership",
    "WarpPrism": "warp-prism",
    "WarpPrismPhasing": "warp-prism",
    "Observer": "observer",
    "ObserverSiegeMode": "observer",
    # Zerg
    "Zergling": "zergling",
    "ZerglingBurrowed": "zergling",
    "Baneling": "baneling",
    "BanelingBurrowed": "baneling",
    "Queen": "queen",
    "QueenBurrowed": "queen",
    "Roach": "roach",
    "RoachBurrowed": "roach",
    "Ravager": "ravager",
    "RavagerBurrowed": "ravager",
    "Hydralisk": "hydralisk",
    "HydraliskBurrowed": "hydralisk",
    "Lurker": "lurker",
    "LurkerMP": "lurker",
    "LurkerBurrowed": "lurker",
    "LurkerMPBurrowed": "lurker",
    "Mutalisk": "mutalisk",
    "Corruptor": "corruptor",
    "Infestor": "infestor",
    "InfestorBurrowed": "infestor",
    "InfestorTerran": "infestor",
    "SwarmHost": "swarm-host",
    "SwarmHostMP": "swarm-host",
    "SwarmHostBurrowed": "swarm-host",
    "SwarmHostBurrowedMP": "swarm-host",
    "Ultralisk": "ultralisk",
    "UltraliskBurrowed": "ultralisk",
    "BroodLord": "brood-lord",
    "Viper": "viper",
    "Overseer": "overseer",
    "OverseerSiegeMode": "overseer",
}

UNIT_BELIEF_ALIASES = {
    "viking-fighter": "viking",
    "viking-assault": "viking",
    "siege-tank-sieged": "siege-tank",
    "widow-mine-burrowed": "widow-mine",
    "liberator-ag": "liberator",
    "hellion-tank": "hellbat",
    "thor-ap": "thor",
    "warp-prism-phasing": "warp-prism",
    "observer-siege-mode": "observer",
    "zergling-burrowed": "zergling",
    "baneling-burrowed": "baneling",
    "queen-burrowed": "queen",
    "roach-burrowed": "roach",
    "ravager-burrowed": "ravager",
    "hydralisk-burrowed": "hydralisk",
    "lurker-mp": "lurker",
    "lurker-burrowed": "lurker",
    "lurker-mp-burrowed": "lurker",
    "infestor-burrowed": "infestor",
    "swarm-host-mp": "swarm-host",
    "swarm-host-burrowed": "swarm-host",
    "swarm-host-burrowed-mp": "swarm-host",
    "ultralisk-burrowed": "ultralisk",
    "overseer-siege-mode": "overseer",
}

# Exact replay SUpgradeEvent -> canonical kebab-case upgrade token
REPLAY_UPGRADE_TO_CANON = {
    # Terran
    "Stimpack": "stimpack",
    "ShieldWall": "combat-shield",
    "PunisherGrenades": "concussive-shells",
    "BansheeCloak": "cloaking-field",
    "BansheeSpeed": "hyperflight-rotors",
    "PersonalCloaking": "personal-cloaking",
    "HighCapacityBarrels": "infernal-pre-igniter",
    "DrillClaws": "drilling-claws",
    "CycloneLockOnDamageUpgrade": "mag-field-accelerator",
    "SmartServos": "smart-servos",
    "MedivacIncreaseSpeedBoost": "rapid-reignition-system",
    "LiberatorAGRangeUpgrade": "advanced-ballistics",
    "BattlecruiserEnableSpecializations": "yamato-cannon",
    "HiSecAutoTracking": "hi-sec-auto-tracking",
    "TerranBuildingArmor": "neosteel-armor",
    "TerranInfantryWeaponsLevel1": "terran-infantry-weapons-1",
    "TerranInfantryWeaponsLevel2": "terran-infantry-weapons-2",
    "TerranInfantryWeaponsLevel3": "terran-infantry-weapons-3",
    "TerranInfantryArmorsLevel1": "terran-infantry-armor-1",
    "TerranInfantryArmorsLevel2": "terran-infantry-armor-2",
    "TerranInfantryArmorsLevel3": "terran-infantry-armor-3",
    "TerranVehicleWeaponsLevel1": "terran-vehicle-weapons-1",
    "TerranVehicleWeaponsLevel2": "terran-vehicle-weapons-2",
    "TerranVehicleWeaponsLevel3": "terran-vehicle-weapons-3",
    "TerranShipWeaponsLevel1": "terran-ship-weapons-1",
    "TerranShipWeaponsLevel2": "terran-ship-weapons-2",
    "TerranShipWeaponsLevel3": "terran-ship-weapons-3",
    "TerranVehicleAndShipArmorsLevel1": "terran-vehicle-and-ship-plating-1",
    "TerranVehicleAndShipArmorsLevel2": "terran-vehicle-and-ship-plating-2",
    "TerranVehicleAndShipArmorsLevel3": "terran-vehicle-and-ship-plating-3",
    # Protoss
    "WarpGateResearch": "warp-gate-research",
    "Charge": "charge",
    "BlinkTech": "blink",
    "AdeptPiercingAttack": "resonating-glaives",
    "PsiStormTech": "psi-storm-tech",
    "ExtendedThermalLance": "extended-thermal-lance",
    "ObserverGraviticBooster": "gravitic-boosters",
    "GraviticDrive": "gravitic-drive",
    "PhoenixRangeUpgrade": "anion-pulse-crystals",
    "VoidRaySpeedUpgrade": "flux-vanes",
    "DarkTemplarBlinkUpgrade": "shadow-stride",
    "ProtossGroundWeaponsLevel1": "protoss-ground-weapons-1",
    "ProtossGroundWeaponsLevel2": "protoss-ground-weapons-2",
    "ProtossGroundWeaponsLevel3": "protoss-ground-weapons-3",
    "ProtossGroundArmorsLevel1": "protoss-ground-armor-1",
    "ProtossGroundArmorsLevel2": "protoss-ground-armor-2",
    "ProtossGroundArmorsLevel3": "protoss-ground-armor-3",
    "ProtossShieldsLevel1": "protoss-shields-1",
    "ProtossShieldsLevel2": "protoss-shields-2",
    "ProtossShieldsLevel3": "protoss-shields-3",
    "ProtossAirWeaponsLevel1": "protoss-air-weapons-1",
    "ProtossAirWeaponsLevel2": "protoss-air-weapons-2",
    "ProtossAirWeaponsLevel3": "protoss-air-weapons-3",
    "ProtossAirArmorsLevel1": "protoss-air-armor-1",
    "ProtossAirArmorsLevel2": "protoss-air-armor-2",
    "ProtossAirArmorsLevel3": "protoss-air-armor-3",
    # Zerg
    "zerglingmovementspeed": "zergling-movementspeed",
    "zerglingattackspeed": "adrenal-glands",
    "Burrow": "burrow",
    "overlordspeed": "pneumatized-carapace",
    "CentrificalHooks": "centrifugal-hooks",
    "GlialReconstitution": "glial-reconstitution",
    "TunnelingClaws": "tunneling-claws",
    "EvolveGroovedSpines": "grooved-spines",
    "EvolveMuscularAugments": "muscular-augments",
    "DiggingClaws": "adaptive-talons",
    "LurkerRange": "seismic-spines",
    "NeuralParasite": "neural-parasite",
    "ChitinousPlating": "chitinous-plating",
    "AnabolicSynthesis": "anabolic-synthesis",
    "ZergMeleeWeaponsLevel1": "zerg-melee-weapons-1",
    "ZergMeleeWeaponsLevel2": "zerg-melee-weapons-2",
    "ZergMeleeWeaponsLevel3": "zerg-melee-weapons-3",
    "ZergMissileWeaponsLevel1": "zerg-missile-weapons-1",
    "ZergMissileWeaponsLevel2": "zerg-missile-weapons-2",
    "ZergMissileWeaponsLevel3": "zerg-missile-weapons-3",
    "ZergGroundArmorsLevel1": "zerg-ground-carapace-1",
    "ZergGroundArmorsLevel2": "zerg-ground-carapace-2",
    "ZergGroundArmorsLevel3": "zerg-ground-carapace-3",
    "ZergFlyerWeaponsLevel1": "zerg-flyer-weapons-1",
    "ZergFlyerWeaponsLevel2": "zerg-flyer-weapons-2",
    "ZergFlyerWeaponsLevel3": "zerg-flyer-weapons-3",
    "ZergFlyerArmorsLevel1": "zerg-flyer-carapace-1",
    "ZergFlyerArmorsLevel2": "zerg-flyer-carapace-2",
    "ZergFlyerArmorsLevel3": "zerg-flyer-carapace-3",
}

UPGRADE_BELIEF_ALIASES = {
    "metabolic-boost": "zergling-movementspeed",
    "zergling-speed": "zergling-movementspeed",
    "roach-speed": "glial-reconstitution",
    "baneling-speed": "centrifugal-hooks",
    "warp-gate": "warp-gate-research",
    "psi-storm": "psi-storm-tech",
    "thermal-lance": "extended-thermal-lance",
    "banshee-cloak": "cloaking-field",
    "lurker-aspect": "adaptive-talons",
    "shield-wall": "combat-shield",
    "punisher-grenades": "concussive-shells",
}

# Composite/inferred upgrade markers produced by MirrorMind/OWM -> matching real canonical upgrades
COMPOSITE_UPGRADE_FAMILIES: dict[str, set[str]] = {
    "stimpack-or-combat-shield": {"stimpack", "combat-shield", "concussive-shells"},
    "blink-or-charge": {"blink", "charge", "resonating-glaives"},
    "infernal-pre-igniter-or-cyclones": {
        "infernal-pre-igniter",
        "drilling-claws",
        "mag-field-accelerator",
        "smart-servos",
    },
    "anion-pulse-crystals-or-flux-vanes": {"anion-pulse-crystals", "flux-vanes"},
    "terran-infantry-weapons-or-armor": {
        "terran-infantry-weapons-1",
        "terran-infantry-weapons-2",
        "terran-infantry-weapons-3",
        "terran-infantry-armor-1",
        "terran-infantry-armor-2",
        "terran-infantry-armor-3",
    },
    "terran-vehicle-and-ship-plating": {
        "terran-vehicle-and-ship-plating-1",
        "terran-vehicle-and-ship-plating-2",
        "terran-vehicle-and-ship-plating-3",
        "terran-vehicle-weapons-1",
        "terran-ship-weapons-1",
    },
    "protoss-ground-weapons-or-shields": {
        "protoss-ground-weapons-1",
        "protoss-ground-weapons-2",
        "protoss-ground-weapons-3",
        "protoss-ground-armor-1",
        "protoss-ground-armor-2",
        "protoss-ground-armor-3",
        "protoss-shields-1",
        "protoss-shields-2",
        "protoss-shields-3",
    },
    "zerg-ground-weapons-or-carapace": {
        "zerg-melee-weapons-1",
        "zerg-melee-weapons-2",
        "zerg-melee-weapons-3",
        "zerg-missile-weapons-1",
        "zerg-missile-weapons-2",
        "zerg-missile-weapons-3",
        "zerg-ground-carapace-1",
        "zerg-ground-carapace-2",
        "zerg-ground-carapace-3",
    },
    "atk-1": {
        "terran-infantry-weapons-1",
        "terran-vehicle-weapons-1",
        "terran-ship-weapons-1",
        "protoss-ground-weapons-1",
        "protoss-air-weapons-1",
        "zerg-melee-weapons-1",
        "zerg-missile-weapons-1",
        "zerg-flyer-weapons-1",
    },
    "atk-2": {
        "terran-infantry-weapons-2",
        "terran-vehicle-weapons-2",
        "terran-ship-weapons-2",
        "protoss-ground-weapons-2",
        "protoss-air-weapons-2",
        "zerg-melee-weapons-2",
        "zerg-missile-weapons-2",
        "zerg-flyer-weapons-2",
    },
    "atk-3": {
        "terran-infantry-weapons-3",
        "terran-vehicle-weapons-3",
        "terran-ship-weapons-3",
        "protoss-ground-weapons-3",
        "protoss-air-weapons-3",
        "zerg-melee-weapons-3",
        "zerg-missile-weapons-3",
        "zerg-flyer-weapons-3",
    },
    "arm-1": {
        "terran-infantry-armor-1",
        "terran-vehicle-and-ship-plating-1",
        "protoss-ground-armor-1",
        "protoss-air-armor-1",
        "zerg-ground-carapace-1",
        "zerg-flyer-carapace-1",
    },
    "arm-2": {
        "terran-infantry-armor-2",
        "terran-vehicle-and-ship-plating-2",
        "protoss-ground-armor-2",
        "protoss-air-armor-2",
        "zerg-ground-carapace-2",
        "zerg-flyer-carapace-2",
    },
    "arm-3": {
        "terran-infantry-armor-3",
        "terran-vehicle-and-ship-plating-3",
        "protoss-ground-armor-3",
        "protoss-air-armor-3",
        "zerg-ground-carapace-3",
        "zerg-flyer-carapace-3",
    },
    "shd-1": {"protoss-shields-1"},
    "shd-2": {"protoss-shields-2"},
    "shd-3": {"protoss-shields-3"},
}
for _lvl in (1, 2, 3):
    COMPOSITE_UPGRADE_FAMILIES[f"enemy-weapons-{_lvl}"] = COMPOSITE_UPGRADE_FAMILIES[f"atk-{_lvl}"]
    COMPOSITE_UPGRADE_FAMILIES[f"enemy-armor-{_lvl}"] = COMPOSITE_UPGRADE_FAMILIES[f"arm-{_lvl}"]
    COMPOSITE_UPGRADE_FAMILIES[f"enemy-shields-{_lvl}"] = COMPOSITE_UPGRADE_FAMILIES[f"shd-{_lvl}"]

OWM_LINE_RE = re.compile(
    r"\[SCBOT_OWM\]\s+"
    r"f=(\d+)\s+"
    r"b=(\d+)/(\d+)\s+"
    r"g=(\d+)/(\d+)\s+"
    r"w=(\d+)/(\d+)\s+"
    r"inc=([0-9.]+)M/([0-9.]+)G\s+"
    r"prod=\(([^)]*)\)\s+"
    r"upg=\(([^)]*)\)\s+"
    r"units=\(([^)]*)\)\s+"
    r"unseen=([-0-9.]+)M/([-0-9.]+)G\s+"
    r"arm=([0-9.]+)"
)

STATE_FALLBACK_RE = re.compile(
    r"\[SCBOT_STATE\].*?\bf=(\d+)\b.*?\beB=(\d+)/(\d+)\s+eG=(\d+)/(\d+)"
)


def _ensure_s2protocol() -> tuple[Any, Any]:
    """Import mpyq and s2protocol.versions, injecting Python 3.12+ imp shim if needed."""
    for pdir in DEFAULT_PYLIBS_DIRS:
        if pdir and os.path.isdir(pdir) and pdir not in sys.path:
            sys.path.insert(0, pdir)
    if "imp" not in sys.modules:
        imp_mod = types.ModuleType("imp")

        def find_module(name: str, paths: list[str] | None = None) -> tuple[Any, str, tuple[str, str, int]]:
            for p in paths or sys.path:
                cand = os.path.join(p, name + ".py")
                if os.path.exists(cand):
                    return (open(cand, "rb"), cand, (".py", "rb", 1))
            raise ImportError(name)

        def load_module(name: str, fp: Any, pathname: str, desc: Any) -> Any:
            if fp:
                fp.close()
            spec = importlib.util.spec_from_file_location(name, pathname)
            if spec is None or spec.loader is None:
                raise ImportError(name)
            mod = importlib.util.module_from_spec(spec)
            sys.modules[name] = mod
            spec.loader.exec_module(mod)
            return mod

        imp_mod.find_module = find_module  # type: ignore[attr-defined]
        imp_mod.load_module = load_module  # type: ignore[attr-defined]
        sys.modules["imp"] = imp_mod

    import mpyq  # type: ignore[import-not-found]
    from s2protocol import versions  # type: ignore[import-not-found]

    return mpyq, versions


def _camel_to_kebab(name: str) -> str:
    s1 = re.sub(r"(.)([A-Z][a-z]+)", r"\1-\2", name)
    s2 = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", s1)
    return s2.replace("_", "-").lower()


def canonicalize_prod(sym: str) -> str:
    k = sym.strip().lower().replace("_", "-")
    return PROD_BELIEF_ALIASES.get(k, k)


def canonicalize_unit(sym: str) -> str:
    k = sym.strip().lower().replace("_", "-")
    return UNIT_BELIEF_ALIASES.get(k, k)


def canonicalize_upgrade_belief(sym: str) -> str:
    k = sym.strip().lower().replace("_", "-")
    return UPGRADE_BELIEF_ALIASES.get(k, k)


def canonicalize_upgrade_replay(raw_name: str) -> str | None:
    if not raw_name or "Spray" in raw_name or "RewardDance" in raw_name or "GameHeart" in raw_name:
        return None
    if raw_name in REPLAY_UPGRADE_TO_CANON:
        return REPLAY_UPGRADE_TO_CANON[raw_name]
    k = _camel_to_kebab(raw_name)
    return UPGRADE_BELIEF_ALIASES.get(k, k)


def parse_kv_csv(raw: str, canonicalizer: Any) -> dict[str, int]:
    out: dict[str, int] = {}
    s = raw.strip()
    if not s:
        return out
    for part in s.split(","):
        part = part.strip()
        if not part or ":" not in part:
            continue
        k, v = part.rsplit(":", 1)
        try:
            cnt = int(float(v.strip()))
        except ValueError:
            continue
        if cnt > 0:
            ck = canonicalizer(k)
            out[ck] = out.get(ck, 0) + cnt
    return out


def parse_upg_csv(raw: str) -> set[str]:
    out: set[str] = set()
    s = raw.strip()
    if not s or s.lower() == "none":
        return out
    for tok in s.split(","):
        tok = tok.strip()
        if tok and tok.lower() != "none":
            out.add(canonicalize_upgrade_belief(tok))
    return out


def parse_owm_line(line: str) -> dict[str, Any] | None:
    m = OWM_LINE_RE.search(line)
    if not m:
        return None
    frame = int(m.group(1))
    return {
        "mode": "owm",
        "frame": frame,
        "sec": frame / FPS,
        "conf_b": int(m.group(2)),
        "est_b": int(m.group(3)),
        "conf_g": int(m.group(4)),
        "est_g": int(m.group(5)),
        "est_w": int(m.group(6)),
        "seen_w": int(m.group(7)),
        "est_min_rate": float(m.group(8)),
        "est_gas_rate": float(m.group(9)),
        "prod": parse_kv_csv(m.group(10), canonicalize_prod),
        "upgrades": parse_upg_csv(m.group(11)),
        "units": parse_kv_csv(m.group(12), canonicalize_unit),
        "unseen_min": float(m.group(13)),
        "unseen_gas": float(m.group(14)),
        "est_army_val": float(m.group(15)),
    }


def parse_state_fallback_line(line: str) -> dict[str, Any] | None:
    m = STATE_FALLBACK_RE.search(line)
    if not m:
        return None
    frame = int(m.group(1))
    return {
        "mode": "state_fallback",
        "frame": frame,
        "sec": frame / FPS,
        "conf_b": int(m.group(2)),
        "est_b": int(m.group(3)),
        "conf_g": int(m.group(4)),
        "est_g": int(m.group(5)),
    }


def parse_log_beliefs(log_path: Path) -> tuple[str, list[dict[str, Any]]]:
    owm_rows: list[dict[str, Any]] = []
    state_rows: list[dict[str, Any]] = []
    with log_path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            if "[SCBOT_OWM]" in line:
                rec = parse_owm_line(line)
                if rec is not None:
                    owm_rows.append(rec)
            elif "[SCBOT_STATE]" in line and "eB=" in line:
                rec = parse_state_fallback_line(line)
                if rec is not None:
                    state_rows.append(rec)
    if owm_rows:
        return "owm", owm_rows
    return "state_fallback", state_rows


def score_upgrades_set(believed: set[str], real: set[str]) -> tuple[int, int, int]:
    """Return (tp_believed, n_believed, n_real) using exact + composite-family matching."""
    if not believed and not real:
        return 0, 0, 0
    matched_real: set[str] = set()
    tp = 0
    for b in sorted(believed):
        if b in real:
            tp += 1
            matched_real.add(b)
        elif b in COMPOSITE_UPGRADE_FAMILIES:
            hits = COMPOSITE_UPGRADE_FAMILIES[b] & real
            if hits:
                tp += 1
                matched_real.update(hits)
    return tp, len(believed), len(real)


def compute_dict_l1_and_signed(
    believed: dict[str, int], real: dict[str, int]
) -> tuple[int, dict[str, int], dict[str, int]]:
    """Return (total_l1, signed_err_by_key, abs_err_by_key)."""
    keys = set(believed.keys()) | set(real.keys())
    total_l1 = 0
    signed: dict[str, int] = {}
    abs_err: dict[str, int] = {}
    for k in keys:
        diff = believed.get(k, 0) - real.get(k, 0)
        if diff != 0:
            signed[k] = diff
            abs_err[k] = abs(diff)
            total_l1 += abs(diff)
    return total_l1, signed, abs_err


def _discover_match_pairs(run_dir: Path) -> list[dict[str, Any]]:
    """Pair each replay in <run_dir>/replays with its dev bot log in <run_dir>/logs."""
    logs_dir = run_dir / "logs"
    replays_dir = run_dir / "replays"
    if not logs_dir.is_dir() or not replays_dir.is_dir():
        raise FileNotFoundError(f"Expected logs/ and replays/ inside {run_dir}")

    replay_by_idx: dict[str, Path] = {}
    for rp in sorted(replays_dir.glob("*.SC2Replay")):
        m = re.match(r"^(\d+)_", rp.name)
        if m:
            replay_by_idx[m.group(1)] = rp

    pairs: list[dict[str, Any]] = []
    for lf in sorted(logs_dir.glob("*.log")):
        bn = lf.name
        if bn.endswith("_controller.log") or "-Base.log" in bn:
            continue
        m = re.match(r"^(\d+)_(Mothman-[PTZXC]+)_vs_(.+)_(Mothman-[PTZXC]+)\.log$", bn)
        if not m:
            continue
        idx, our_bot, _rest, log_bot = m.group(1), m.group(2), m.group(3), m.group(4)
        if our_bot != log_bot:
            continue
        rp = replay_by_idx.get(idx)
        if rp is None:
            continue
        race_letter = our_bot.split("-")[-1][0]
        race = {"P": "Protoss", "T": "Terran", "Z": "Zerg"}.get(race_letter, "Random")
        pairs.append({
            "id": int(idx),
            "our_bot": our_bot,
            "our_race": race,
            "log_path": str(lf),
            "replay_path": str(rp),
        })
    return pairs


def _extract_replay_truth(replay_path: str, our_bot: str) -> dict[str, Any]:
    mpyq, versions = _ensure_s2protocol()
    arch = mpyq.MPQArchive(replay_path)
    hdr = versions.latest().decode_replay_header(arch.header["user_data_header"]["content"])
    proto = versions.build(hdr["m_version"]["m_baseBuild"])
    det = proto.decode_replay_details(arch.read_file("replay.details"))

    players = det["m_playerList"]
    our_pid = None
    for idx, pl in enumerate(players, 1):
        nm = pl["m_name"].decode("utf-8", "ignore")
        if our_bot in nm and "-Base" not in nm:
            our_pid = idx
            break
    if our_pid is None:
        our_pid = 1
    opp_pid = 3 - our_pid
    opp_race = players[opp_pid - 1]["m_race"].decode("utf-8", "ignore")
    our_race = players[our_pid - 1]["m_race"].decode("utf-8", "ignore")

    tevs = list(proto.decode_replay_tracker_events(arch.read_file("replay.tracker.events")))
    units: dict[tuple[int, int], tuple[int, str]] = {}

    th_ev: list[tuple[float, int]] = []
    gas_ev: list[tuple[float, int]] = []
    wrk_ev: list[tuple[float, int]] = []
    prod_ev: list[tuple[float, str, int]] = []
    unit_ev: list[tuple[float, str, int]] = []
    upg_ev: list[tuple[float, str]] = []
    stats_ev: list[tuple[float, float, float, float, int]] = []
    max_sec = 0.0

    for e in tevs:
        t = e["_gameloop"] / FPS
        if t > max_sec:
            max_sec = t
        et = e["_event"]
        if et in ("NNet.Replay.Tracker.SUnitBornEvent", "NNet.Replay.Tracker.SUnitInitEvent"):
            uid = (e["m_unitTagIndex"], e["m_unitTagRecycle"])
            ut = e["m_unitTypeName"].decode("utf-8", "ignore")
            pid = e["m_controlPlayerId"]
            units[uid] = (pid, ut)
            if pid == opp_pid:
                if ut in TOWNHALL_REPLAY_TYPES:
                    th_ev.append((t, 1))
                if ut in GAS_REPLAY_TYPES:
                    gas_ev.append((t, 1))
                if ut in WORKER_REPLAY_TYPES:
                    wrk_ev.append((t, 1))
                if ut in PROD_REPLAY_TO_CANON:
                    prod_ev.append((t, PROD_REPLAY_TO_CANON[ut], 1))
                if ut in COMBAT_UNIT_REPLAY_TO_CANON:
                    unit_ev.append((t, COMBAT_UNIT_REPLAY_TO_CANON[ut], 1))
        elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
            uid = (e["m_unitTagIndex"], e["m_unitTagRecycle"])
            new_ut = e["m_unitTypeName"].decode("utf-8", "ignore")
            if uid in units:
                pid, old_ut = units[uid]
                units[uid] = (pid, new_ut)
                if pid == opp_pid and old_ut != new_ut:
                    old_th, new_th = old_ut in TOWNHALL_REPLAY_TYPES, new_ut in TOWNHALL_REPLAY_TYPES
                    if old_th != new_th:
                        th_ev.append((t, 1 if new_th else -1))
                    old_w, new_w = old_ut in WORKER_REPLAY_TYPES, new_ut in WORKER_REPLAY_TYPES
                    if old_w != new_w:
                        wrk_ev.append((t, 1 if new_w else -1))
                    old_p, new_p = PROD_REPLAY_TO_CANON.get(old_ut), PROD_REPLAY_TO_CANON.get(new_ut)
                    if old_p != new_p:
                        if old_p:
                            prod_ev.append((t, old_p, -1))
                        if new_p:
                            prod_ev.append((t, new_p, 1))
                    old_c, new_c = COMBAT_UNIT_REPLAY_TO_CANON.get(old_ut), COMBAT_UNIT_REPLAY_TO_CANON.get(new_ut)
                    if old_c != new_c:
                        if old_c:
                            unit_ev.append((t, old_c, -1))
                        if new_c:
                            unit_ev.append((t, new_c, 1))
        elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
            uid = (e["m_unitTagIndex"], e["m_unitTagRecycle"])
            if uid in units:
                pid, ut = units.pop(uid)
                if pid == opp_pid:
                    if ut in TOWNHALL_REPLAY_TYPES:
                        th_ev.append((t, -1))
                    if ut in GAS_REPLAY_TYPES:
                        gas_ev.append((t, -1))
                    if ut in WORKER_REPLAY_TYPES:
                        wrk_ev.append((t, -1))
                    if ut in PROD_REPLAY_TO_CANON:
                        prod_ev.append((t, PROD_REPLAY_TO_CANON[ut], -1))
                    if ut in COMBAT_UNIT_REPLAY_TO_CANON:
                        unit_ev.append((t, COMBAT_UNIT_REPLAY_TO_CANON[ut], -1))
        elif et == "NNet.Replay.Tracker.SUpgradeEvent":
            if e["m_playerId"] == opp_pid:
                raw_u = e["m_upgradeTypeName"].decode("utf-8", "ignore")
                cu = canonicalize_upgrade_replay(raw_u)
                if cu:
                    upg_ev.append((t, cu))
        elif et == "NNet.Replay.Tracker.SPlayerStatsEvent":
            if e["m_playerId"] == opp_pid:
                st = e["m_stats"]
                min_rate = float(st.get("m_scoreValueMineralsCollectionRate", 0))
                gas_rate = float(st.get("m_scoreValueVespeneCollectionRate", 0))
                army_val = float(
                    st.get("m_scoreValueMineralsUsedActiveForces", 0)
                    + st.get("m_scoreValueVespeneUsedActiveForces", 0)
                )
                wrk_active = int(st.get("m_scoreValueWorkersActiveCount", -1))
                stats_ev.append((t, min_rate, gas_rate, army_val, wrk_active))

    return {
        "our_race": our_race,
        "opp_race": opp_race,
        "max_sec": max_sec,
        "th_ev": th_ev,
        "gas_ev": gas_ev,
        "wrk_ev": wrk_ev,
        "prod_ev": prod_ev,
        "unit_ev": unit_ev,
        "upg_ev": upg_ev,
        "stats_ev": stats_ev,
    }


def _truth_at_sec(truth: dict[str, Any], sec: float) -> dict[str, Any]:
    real_b = max(0, sum(d for ts, d in truth["th_ev"] if ts <= sec))
    real_g = max(0, sum(d for ts, d in truth["gas_ev"] if ts <= sec))
    real_w = max(0, sum(d for ts, d in truth["wrk_ev"] if ts <= sec))

    prod: dict[str, int] = {}
    for ts, sym, d in truth["prod_ev"]:
        if ts <= sec:
            prod[sym] = prod.get(sym, 0) + d
    prod = {k: v for k, v in prod.items() if v > 0}

    units: dict[str, int] = {}
    for ts, sym, d in truth["unit_ev"]:
        if ts <= sec:
            units[sym] = units.get(sym, 0) + d
    units = {k: v for k, v in units.items() if v > 0}

    upgs = {u for ts, u in truth["upg_ev"] if ts <= sec}

    min_rate, gas_rate, army_val = 0.0, 0.0, 0.0
    stats_ev = truth["stats_ev"]
    if stats_ev:
        best = min(stats_ev, key=lambda x: abs(x[0] - sec))
        min_rate, gas_rate, army_val = best[1], best[2], best[3]
        if best[4] >= 0:
            real_w = best[4]

    return {
        "real_b": real_b,
        "real_g": real_g,
        "real_w": real_w,
        "real_min_rate": min_rate,
        "real_gas_rate": gas_rate,
        "real_army_val": army_val,
        "real_prod": prod,
        "real_units": units,
        "real_upgrades": upgs,
    }


def _evaluate_single_match(args: tuple[dict[str, Any], list[int]]) -> dict[str, Any]:
    pair, buckets_min = args
    mode, samples = parse_log_beliefs(Path(pair["log_path"]))
    truth = _extract_replay_truth(pair["replay_path"], pair["our_bot"])

    bucket_records: dict[int, dict[str, Any]] = {}
    for bm in buckets_min:
        target_s = bm * 60.0
        if target_s > truth["max_sec"] + 5.0:
            continue
        cand = [s for s in samples if abs(s["sec"] - target_s) <= 15.0]
        if not cand:
            continue
        sample = min(cand, key=lambda x: abs(x["sec"] - target_s))
        gt = _truth_at_sec(truth, sample["sec"])
        rec: dict[str, Any] = {
            "bucket_min": bm,
            "sample_sec": round(sample["sec"], 1),
            "mode": sample["mode"],
            "real_b": gt["real_b"],
            "conf_b": sample["conf_b"],
            "est_b": sample["est_b"],
            "real_g": gt["real_g"],
            "conf_g": sample["conf_g"],
            "est_g": sample["est_g"],
        }
        if sample["mode"] == "owm":
            prod_l1, prod_signed, prod_abs = compute_dict_l1_and_signed(sample["prod"], gt["real_prod"])
            unit_l1, unit_signed, unit_abs = compute_dict_l1_and_signed(sample["units"], gt["real_units"])
            upg_tp, upg_bel_n, upg_real_n = score_upgrades_set(sample["upgrades"], gt["real_upgrades"])
            rec.update({
                "real_w": gt["real_w"],
                "est_w": sample["est_w"],
                "seen_w": sample["seen_w"],
                "real_min_rate": gt["real_min_rate"],
                "est_min_rate": sample["est_min_rate"],
                "real_gas_rate": gt["real_gas_rate"],
                "est_gas_rate": sample["est_gas_rate"],
                "real_army_val": gt["real_army_val"],
                "est_army_val": sample["est_army_val"],
                "unseen_min": sample["unseen_min"],
                "unseen_gas": sample["unseen_gas"],
                "prod_l1": prod_l1,
                "prod_signed": prod_signed,
                "prod_abs": prod_abs,
                "unit_l1": unit_l1,
                "unit_signed": unit_signed,
                "unit_abs": unit_abs,
                "upg_tp": upg_tp,
                "upg_bel_n": upg_bel_n,
                "upg_real_n": upg_real_n,
            })
        bucket_records[bm] = rec

    return {
        "id": pair["id"],
        "our_bot": pair["our_bot"],
        "our_race": truth["our_race"] or pair["our_race"],
        "opp_race": truth["opp_race"],
        "mode": mode,
        "sample_count": len(samples),
        "duration_sec": round(truth["max_sec"], 1),
        "buckets": bucket_records,
    }


def _agg_records(records: list[dict[str, Any]]) -> dict[str, Any]:
    n = len(records)
    if n == 0:
        return {"n": 0}
    out: dict[str, Any] = {
        "n": n,
        "real_b": round(sum(r["real_b"] for r in records) / n, 2),
        "conf_b": round(sum(r["conf_b"] for r in records) / n, 2),
        "est_b": round(sum(r["est_b"] for r in records) / n, 2),
        "b_mae": round(sum(abs(r["est_b"] - r["real_b"]) for r in records) / n, 2),
        "b_bias": round(sum(r["est_b"] - r["real_b"] for r in records) / n, 2),
        "real_g": round(sum(r["real_g"] for r in records) / n, 2),
        "conf_g": round(sum(r["conf_g"] for r in records) / n, 2),
        "est_g": round(sum(r["est_g"] for r in records) / n, 2),
        "g_mae": round(sum(abs(r["est_g"] - r["real_g"]) for r in records) / n, 2),
        "g_bias": round(sum(r["est_g"] - r["real_g"] for r in records) / n, 2),
    }
    owm_recs = [r for r in records if r.get("mode") == "owm"]
    m = len(owm_recs)
    out["n_owm"] = m
    if m > 0:
        tp = sum(r["upg_tp"] for r in owm_recs)
        bel_n = sum(r["upg_bel_n"] for r in owm_recs)
        real_n = sum(r["upg_real_n"] for r in owm_recs)
        prec = tp / bel_n if bel_n > 0 else 1.0
        rec = tp / real_n if real_n > 0 else 1.0
        f1 = (2 * prec * rec / (prec + rec)) if (prec + rec) > 0 else 0.0
        out.update({
            "real_w": round(sum(r["real_w"] for r in owm_recs) / m, 1),
            "est_w": round(sum(r["est_w"] for r in owm_recs) / m, 1),
            "seen_w": round(sum(r["seen_w"] for r in owm_recs) / m, 1),
            "w_mae": round(sum(abs(r["est_w"] - r["real_w"]) for r in owm_recs) / m, 1),
            "w_bias": round(sum(r["est_w"] - r["real_w"] for r in owm_recs) / m, 1),
            "real_min_rate": round(sum(r["real_min_rate"] for r in owm_recs) / m, 0),
            "est_min_rate": round(sum(r["est_min_rate"] for r in owm_recs) / m, 0),
            "min_rate_mae": round(sum(abs(r["est_min_rate"] - r["real_min_rate"]) for r in owm_recs) / m, 0),
            "min_rate_bias": round(sum(r["est_min_rate"] - r["real_min_rate"] for r in owm_recs) / m, 0),
            "real_gas_rate": round(sum(r["real_gas_rate"] for r in owm_recs) / m, 0),
            "est_gas_rate": round(sum(r["est_gas_rate"] for r in owm_recs) / m, 0),
            "gas_rate_mae": round(sum(abs(r["est_gas_rate"] - r["real_gas_rate"]) for r in owm_recs) / m, 0),
            "gas_rate_bias": round(sum(r["est_gas_rate"] - r["real_gas_rate"] for r in owm_recs) / m, 0),
            "real_army_val": round(sum(r["real_army_val"] for r in owm_recs) / m, 0),
            "est_army_val": round(sum(r["est_army_val"] for r in owm_recs) / m, 0),
            "army_val_mae": round(sum(abs(r["est_army_val"] - r["real_army_val"]) for r in owm_recs) / m, 0),
            "army_val_bias": round(sum(r["est_army_val"] - r["real_army_val"] for r in owm_recs) / m, 0),
            "prod_l1_mean": round(sum(r["prod_l1"] for r in owm_recs) / m, 2),
            "unit_l1_mean": round(sum(r["unit_l1"] for r in owm_recs) / m, 2),
            "upg_precision": round(prec, 3),
            "upg_recall": round(rec, 3),
            "upg_f1": round(f1, 3),
            "upg_tp": tp,
            "upg_bel_total": bel_n,
            "upg_real_total": real_n,
        })
    return out


def aggregate_run(match_results: list[dict[str, Any]], buckets_min: list[int]) -> dict[str, Any]:
    all_recs: list[dict[str, Any]] = []
    by_bucket: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    by_race: dict[str, list[dict[str, Any]]] = collections.defaultdict(list)
    gas_recall: dict[str, dict[str, list[int]]] = {
        r: {"2m": [0, 0], "3m": [0, 0]} for r in ("Protoss", "Terran", "Zerg")
    }
    prod_signed_sum: dict[str, int] = collections.Counter()
    prod_abs_sum: dict[str, int] = collections.Counter()
    unit_signed_sum: dict[str, int] = collections.Counter()
    unit_abs_sum: dict[str, int] = collections.Counter()
    owm_sample_total = 0

    for mr in match_results:
        race = mr["our_race"]
        for bm, rec in mr["buckets"].items():
            all_recs.append(rec)
            by_bucket[str(bm)].append(rec)
            by_race[race].append(rec)
            if bm in (2, 3) and race in gas_recall and rec["real_g"] >= 1:
                k = f"{bm}m"
                gas_recall[race][k][1] += 1
                if rec["conf_g"] >= 1:
                    gas_recall[race][k][0] += 1
            if rec.get("mode") == "owm":
                owm_sample_total += 1
                for k, v in rec.get("prod_signed", {}).items():
                    prod_signed_sum[k] += v
                for k, v in rec.get("prod_abs", {}).items():
                    prod_abs_sum[k] += v
                for k, v in rec.get("unit_signed", {}).items():
                    unit_signed_sum[k] += v
                for k, v in rec.get("unit_abs", {}).items():
                    unit_abs_sum[k] += v

    def _top_type_errors(abs_ctr: dict[str, int], signed_ctr: dict[str, int], denom: int, limit: int = 8) -> list[dict[str, Any]]:
        if denom <= 0:
            return []
        ranked = sorted(abs_ctr.items(), key=lambda x: (-x[1], x[0]))[:limit]
        return [
            {
                "type": k,
                "mean_abs_err": round(v / denom, 3),
                "mean_bias": round(signed_ctr.get(k, 0) / denom, 3),
                "total_abs_err": v,
            }
            for k, v in ranked
        ]

    owm_match_cnt = sum(1 for m in match_results if m["mode"] == "owm")
    fallback_match_cnt = sum(1 for m in match_results if m["mode"] != "owm")

    return {
        "match_count": len(match_results),
        "owm_matches": owm_match_cnt,
        "fallback_matches": fallback_match_cnt,
        "overall": _agg_records(all_recs),
        "by_bucket": {str(bm): _agg_records(by_bucket[str(bm)]) for bm in buckets_min if by_bucket[str(bm)]},
        "by_race": {r: _agg_records(recs) for r, recs in sorted(by_race.items())},
        "early_gas_recall": {
            r: {
                k: {
                    "hits": v[0],
                    "total": v[1],
                    "pct": round(100.0 * v[0] / v[1], 1) if v[1] > 0 else 0.0,
                }
                for k, v in d.items()
            }
            for r, d in gas_recall.items()
        },
        "top_prod_errors": _top_type_errors(prod_abs_sum, prod_signed_sum, owm_sample_total),
        "top_unit_errors": _top_type_errors(unit_abs_sum, unit_signed_sum, owm_sample_total),
    }


def print_report(summary: dict[str, Any], run_label: str) -> None:
    print(f"=== OWM BELIEF ACCURACY AUDIT: {run_label} ===")
    print(
        f"Matches: {summary['match_count']} "
        f"(full [SCBOT_OWM]: {summary['owm_matches']}, "
        f"[SCBOT_STATE] fallback: {summary['fallback_matches']})"
    )

    has_owm = summary["overall"].get("n_owm", 0) > 0
    print("\n--- Per-Minute Believed vs Reality ---")
    if has_owm:
        print(
            f"{'Min':>4s} {'N':>3s} | {'RealB':>5s} {'EstB':>5s} {'B_MAE':>5s} | "
            f"{'RealG':>5s} {'EstG':>5s} {'G_MAE':>5s} | "
            f"{'RealW':>5s} {'EstW':>5s} {'W_MAE':>5s} | "
            f"{'M/m_MAE':>7s} {'G/m_MAE':>7s} | {'ArmMAE':>6s} | {'PrdL1':>5s} {'UntL1':>5s} | {'UpgF1':>5s}"
        )
        for bm, st in summary["by_bucket"].items():
            if st.get("n_owm", 0) > 0:
                print(
                    f"{int(bm):3d}m {st['n']:3d} | {st['real_b']:5.2f} {st['est_b']:5.2f} {st['b_mae']:5.2f} | "
                    f"{st['real_g']:5.2f} {st['est_g']:5.2f} {st['g_mae']:5.2f} | "
                    f"{st['real_w']:5.1f} {st['est_w']:5.1f} {st['w_mae']:5.1f} | "
                    f"{st['min_rate_mae']:7.0f} {st['gas_rate_mae']:7.0f} | {st['army_val_mae']:6.0f} | "
                    f"{st['prod_l1_mean']:5.2f} {st['unit_l1_mean']:5.2f} | {st['upg_f1']:5.3f}"
                )
            else:
                print(
                    f"{int(bm):3d}m {st['n']:3d} | {st['real_b']:5.2f} {st['est_b']:5.2f} {st['b_mae']:5.2f} | "
                    f"{st['real_g']:5.2f} {st['est_g']:5.2f} {st['g_mae']:5.2f} | (fallback only)"
                )
    else:
        print(f"{'Min':>4s} {'N':>3s} | {'RealB':>5s} {'ConfB':>5s} {'EstB':>5s} {'B_MAE':>5s} | {'RealG':>5s} {'ConfG':>5s} {'EstG':>5s} {'G_MAE':>5s}")
        for bm, st in summary["by_bucket"].items():
            print(
                f"{int(bm):3d}m {st['n']:3d} | {st['real_b']:5.2f} {st['conf_b']:5.2f} {st['est_b']:5.2f} {st['b_mae']:5.2f} | "
                f"{st['real_g']:5.2f} {st['conf_g']:5.2f} {st['est_g']:5.2f} {st['g_mae']:5.2f}"
            )

    ov = summary["overall"]
    print("\n--- Overall & By-Race Summary ---")
    for label, st in [("ALL", ov)] + [(r, s) for r, s in summary["by_race"].items()]:
        if st.get("n", 0) == 0:
            continue
        base_str = (
            f"  {label:8s} (n={st['n']:3d}): "
            f"B_MAE={st['b_mae']:.2f} (bias={st['b_bias']:+.2f}) | "
            f"G_MAE={st['g_mae']:.2f} (bias={st['g_bias']:+.2f})"
        )
        if st.get("n_owm", 0) > 0:
            base_str += (
                f" | W_MAE={st['w_mae']:.1f} ({st['w_bias']:+.1f})"
                f" | MRate_MAE={st['min_rate_mae']:.0f} GRate_MAE={st['gas_rate_mae']:.0f}"
                f" | Arm_MAE={st['army_val_mae']:.0f}"
                f" | PrdL1={st['prod_l1_mean']:.2f} UntL1={st['unit_l1_mean']:.2f}"
                f" | Upg P/R/F1={st['upg_precision']:.2f}/{st['upg_recall']:.2f}/{st['upg_f1']:.2f}"
            )
        print(base_str)

    print("\n--- Early Gas Recall (ConfG >= 1 when RealG >= 1) ---")
    for r, d in summary["early_gas_recall"].items():
        m2, m3 = d["2m"], d["3m"]
        print(
            f"  {r:8s}: @2:00={m2['hits']}/{m2['total']} ({m2['pct']:.1f}%) | "
            f"@3:00={m3['hits']}/{m3['total']} ({m3['pct']:.1f}%)"
        )

    if summary["top_prod_errors"]:
        print("\n--- Top Production Facility Errors (per-sample mean abs err & bias) ---")
        for e in summary["top_prod_errors"][:6]:
            print(f"  {e['type']:20s}: MAE={e['mean_abs_err']:.3f} bias={e['mean_bias']:+.3f}")

    if summary["top_unit_errors"]:
        print("\n--- Top Combat Unit Type Errors (per-sample mean abs err & bias) ---")
        for e in summary["top_unit_errors"][:8]:
            print(f"  {e['type']:20s}: MAE={e['mean_abs_err']:.3f} bias={e['mean_bias']:+.3f}")


def run_self_test() -> int:
    # 1. Synthetic [SCBOT_OWM] line parse test
    sample_owm = (
        "[SCBOT_OWM] f=8064 b=2/3 g=3/4 w=42/18 inc=1850M/420G "
        "prod=(barracks:3,factory:1,starport:1) "
        "upg=(stimpack-or-combat-shield,terran-infantry-weapons-1) "
        "units=(marine:18,marauder:4,siege-tank-sieged:2,medivac:2) "
        "unseen=650M/175G arm=2150"
    )
    parsed = parse_owm_line(sample_owm)
    assert parsed is not None, "Failed to parse [SCBOT_OWM] line"
    assert parsed["frame"] == 8064 and abs(parsed["sec"] - 360.0) < 0.01
    assert parsed["conf_b"] == 2 and parsed["est_b"] == 3
    assert parsed["conf_g"] == 3 and parsed["est_g"] == 4
    assert parsed["est_w"] == 42 and parsed["seen_w"] == 18
    assert parsed["est_min_rate"] == 1850.0 and parsed["est_gas_rate"] == 420.0
    assert parsed["prod"] == {"barracks": 3, "factory": 1, "starport": 1}
    assert parsed["units"] == {"marine": 18, "marauder": 4, "siege-tank": 2, "medivac": 2}
    assert parsed["unseen_min"] == 650.0 and parsed["unseen_gas"] == 175.0
    assert parsed["est_army_val"] == 2150.0

    # 2. Empty and (none) parens parse tests
    empty_owm = (
        "[SCBOT_OWM] f=448 b=1/1 g=0/0 w=16/0 inc=600M/0G "
        "prod=() upg=() units=() unseen=0M/0G arm=0"
    )
    parsed_empty = parse_owm_line(empty_owm)
    assert parsed_empty is not None
    assert parsed_empty["prod"] == {} and parsed_empty["upgrades"] == set() and parsed_empty["units"] == {}
    none_owm = (
        "[SCBOT_OWM] f=448 b=1/1 g=0/0 w=16/0 inc=600M/0G "
        "prod=(none) upg=(none) units=(none) unseen=0M/0G arm=0"
    )
    parsed_none = parse_owm_line(none_owm)
    assert parsed_none is not None
    assert parsed_none["prod"] == {} and parsed_none["upgrades"] == set() and parsed_none["units"] == {}

    # 3. Fallback [SCBOT_STATE] line parse test
    state_line = (
        "[SCBOT_STATE] f=5376 matchup=PvZ posture=DragoonReaverVanguard "
        "bayesian=(bluff=0.01,rush=0.02,hexp=0.36,tsw=0.15,camp=0.03) "
        "eB=2/3 eG=2/4 step_ms=14.2"
    )
    fb = parse_state_fallback_line(state_line)
    assert fb is not None and fb["conf_b"] == 2 and fb["est_b"] == 3 and fb["conf_g"] == 2 and fb["est_g"] == 4

    # 4. Upgrade family matching & unit/prod L1 test
    real_upgs = {canonicalize_upgrade_replay("Stimpack"), canonicalize_upgrade_replay("TerranInfantryWeaponsLevel1")}
    assert None not in real_upgs
    tp, bel_n, real_n = score_upgrades_set(parsed["upgrades"], real_upgs)  # type: ignore[arg-type]
    assert tp == 2 and bel_n == 2 and real_n == 2, f"Unexpected upg score: {(tp, bel_n, real_n)}"
    assert canonicalize_upgrade_replay("SprayTerran") is None

    l1, signed, abs_e = compute_dict_l1_and_signed(
        parsed["units"], {"marine": 20, "marauder": 4, "siege-tank": 3, "medivac": 2}
    )
    assert l1 == 3 and signed == {"marine": -2, "siege-tank": -1} and abs_e == {"marine": 2, "siege-tank": 1}

    # 5. End-to-end aggregation test
    synth_matches = [
        {
            "id": 1,
            "our_bot": "Mothman-P",
            "our_race": "Protoss",
            "opp_race": "Terran",
            "mode": "owm",
            "sample_count": 1,
            "duration_sec": 420.0,
            "buckets": {
                6: {
                    "bucket_min": 6,
                    "sample_sec": 360.0,
                    "mode": "owm",
                    "real_b": 3,
                    "conf_b": 2,
                    "est_b": 3,
                    "real_g": 4,
                    "conf_g": 3,
                    "est_g": 4,
                    "real_w": 45,
                    "est_w": 42,
                    "seen_w": 18,
                    "real_min_rate": 1950.0,
                    "est_min_rate": 1850.0,
                    "real_gas_rate": 450.0,
                    "est_gas_rate": 420.0,
                    "real_army_val": 2300.0,
                    "est_army_val": 2150.0,
                    "unseen_min": 650.0,
                    "unseen_gas": 175.0,
                    "prod_l1": 1,
                    "prod_signed": {"barracks": -1},
                    "prod_abs": {"barracks": 1},
                    "unit_l1": 3,
                    "unit_signed": {"marine": -2, "siege-tank": -1},
                    "unit_abs": {"marine": 2, "siege-tank": 1},
                    "upg_tp": 2,
                    "upg_bel_n": 2,
                    "upg_real_n": 2,
                }
            },
        }
    ]
    agg = aggregate_run(synth_matches, [6])
    assert agg["overall"]["b_mae"] == 0.0 and agg["overall"]["w_mae"] == 3.0
    assert agg["overall"]["upg_f1"] == 1.0 and agg["overall"]["unit_l1_mean"] == 3.0
    assert agg["top_unit_errors"][0]["type"] == "marine"
    print("SELF_TEST PASS (5/5 checks OK)")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Evaluate OWM believed-vs-reality accuracy from SC2 replays and bot logs.")
    ap.add_argument("run_dir", nargs="?", help="Arena run directory containing logs/ and replays/")
    ap.add_argument("--out-json", dest="out_json", help="Optional path to write structured JSON report")
    ap.add_argument("--workers", type=int, default=8, help="Parallel worker processes (default: 8)")
    ap.add_argument(
        "--buckets",
        default=",".join(str(x) for x in DEFAULT_BUCKETS_MIN),
        help="Comma-separated minute checkpoints (default: 1,2,3,4,5,6,8,10,12,15,18)",
    )
    ap.add_argument("--self-test", action="store_true", help="Run built-in parser and metric unit tests")
    args = ap.parse_args(argv)

    if args.self_test:
        return run_self_test()

    if not args.run_dir:
        ap.error("run_dir is required unless --self-test is passed")

    run_dir = Path(args.run_dir).resolve()
    buckets_min = [int(x.strip()) for x in args.buckets.split(",") if x.strip()]
    pairs = _discover_match_pairs(run_dir)
    if not pairs:
        print(f"ERROR: No matching dev bot logs + replays found in {run_dir}", file=sys.stderr)
        return 1

    workers = max(1, min(args.workers, len(pairs)))
    work_items = [(p, buckets_min) for p in pairs]
    if workers == 1:
        results = [_evaluate_single_match(item) for item in work_items]
    else:
        with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as ex:
            results = list(ex.map(_evaluate_single_match, work_items))
    results.sort(key=lambda r: r["id"])

    summary = aggregate_run(results, buckets_min)
    print_report(summary, run_dir.name)

    if args.out_json:
        out_path = Path(args.out_json)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "run_dir": str(run_dir),
            "buckets_min": buckets_min,
            "summary": summary,
            "matches": results,
        }
        out_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"\nWrote JSON report -> {out_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
