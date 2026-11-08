#!/usr/bin/env python3
"""
Pro & Ladder LotV Replay Build-Order, Expansion, Gas, Upgrade, Macro-Mechanic &
Worker-to-Army Curve Extractor (`tools/extract_pro_build_orders.py`).

Uses `mpyq` and `s2protocol` to parse all Legacy of the Void (12-worker start)
1v1 `.SC2Replay` archives across:
  - `replays/pro_corpus/`
  - `data/aiarena_latest/`
  - `replays/aiarena_matches/`

For every player perspective across all 9 matchups (`ZvZ`, `ZvT`, `ZvP`, `TvZ`,
`TvT`, `TvP`, `PvZ`, `PvT`, `PvP`) plus Random opening variants (`RvX` / `XvR`),
extracts for the first 7 minutes (`0s..420s`, gameloops `0..9408`):
  1. Exact supply-indexed & time-indexed build order: every structure built or
     morphed, with exact supply used and active worker count at initiation.
  2. TownHall expansion timings (2nd, 3rd, 4th base) and active worker count at
     each expansion.
  3. Gas geyser timings (1st, 2nd, 3rd, 4th gas) and active worker count at each
     geyser.
  4. Upgrade research start & completion timings and supply/worker count at start.
  5. Race-specific macro-mechanic timings:
     - Zerg: Queen start/born timings, Inject Larva casts, Creep Tumor timings,
       Lair/Hive morph timings.
     - Terran: Orbital Command / Planetary Fortress morph start/completion timings,
       MULE calldown timings, TechLab/Reactor add-on timings.
     - Protoss: Chrono Boost cast timings and target structures, WarpGate morphs.
  6. Unit production sequence (workers vs combat units at each supply threshold).
  7. Empirical worker-to-army supply curves at `1:00, 2:00, 3:00, 4:00, 5:00,
     6:00, 7:00` (`60s..420s`) for winning players in each matchup.

Synthesizes the mined pro build orders and curves into the tracked S-expression
database `data/pro_build_orders.sexp`.
"""

import argparse
import glob
import hashlib
import json
import math
import multiprocessing as mp
import os
import re
import statistics
from collections import Counter, defaultdict
from typing import Any, Dict, List, Optional, Tuple

import mpyq
from s2protocol import versions

FASTER_FPS = 22.4
MAX_EXTRACT_SEC = 420.0
MAX_EXTRACT_GL = int(round(MAX_EXTRACT_SEC * FASTER_FPS))  # 9408

WORKER_TYPES = {"Drone", "SCV", "Probe"}
TOWNHALL_INIT_TYPES = {"Hatchery", "CommandCenter", "Nexus"}
TOWNHALL_ALL_TYPES = {
    "Hatchery",
    "Lair",
    "Hive",
    "CommandCenter",
    "OrbitalCommand",
    "PlanetaryFortress",
    "Nexus",
}
GAS_TYPES = {"Extractor", "Refinery", "Assimilator"}
SUPPLY_PROVIDER_TYPES = {"Overlord", "SupplyDepot", "Pylon"}

ZERG_CONSUMED_DRONE_BLDGS = {
    "Hatchery",
    "Extractor",
    "SpawningPool",
    "RoachWarren",
    "BanelingNest",
    "EvolutionChamber",
    "HydraliskDen",
    "LurkerDenMP",
    "Spire",
    "InfestationPit",
    "UltraliskCavern",
    "SpineCrawler",
    "SporeCrawler",
    "NydusNetwork",
}

STRUCTURE_TYPES = TOWNHALL_ALL_TYPES | GAS_TYPES | {
    "SupplyDepot",
    "Pylon",
    "SpawningPool",
    "RoachWarren",
    "BanelingNest",
    "HydraliskDen",
    "LurkerDenMP",
    "Spire",
    "GreaterSpire",
    "InfestationPit",
    "UltraliskCavern",
    "EvolutionChamber",
    "SpineCrawler",
    "SporeCrawler",
    "NydusNetwork",
    "NydusCanal",
    "Barracks",
    "BarracksTechLab",
    "BarracksReactor",
    "Factory",
    "FactoryTechLab",
    "FactoryReactor",
    "Starport",
    "StarportTechLab",
    "StarportReactor",
    "EngineeringBay",
    "Armory",
    "FusionCore",
    "GhostAcademy",
    "Bunker",
    "MissileTurret",
    "SensorTower",
    "Gateway",
    "WarpGate",
    "Forge",
    "CyberneticsCore",
    "PhotonCannon",
    "ShieldBattery",
    "TwilightCouncil",
    "Stargate",
    "RoboticsFacility",
    "RoboticsBay",
    "FleetBeacon",
    "TemplarArchive",
    "DarkShrine",
}

MORPH_STRUCTURE_DURATION_SEC = {
    "OrbitalCommand": 25.0,
    "PlanetaryFortress": 36.0,
    "Lair": 57.0,
    "Hive": 71.0,
    "GreaterSpire": 71.0,
    "WarpGate": 7.0,
}

MORPH_UNIT_FROM_COCOON = {
    "BanelingCocoon": ("baneling", 14.0, 0.0),
    "RavagerCocoon": ("ravager", 12.0, 1.0),
    "LurkerMPEgg": ("lurker", 18.0, 1.0),
    "BroodLordCocoon": ("brood-lord", 24.0, 2.0),
    "TransportOverlordCocoon": ("dropperlords", 15.0, 0.0),
    "OverlordCocoon": ("overseer", 12.0, 0.0),
}

UNIT_TRAIN_TIME_SEC = {
    "Drone": 12.0,
    "SCV": 12.0,
    "Probe": 12.0,
    "Overlord": 18.0,
    "Queen": 36.0,
    "Zergling": 17.0,
    "Baneling": 14.0,
    "Roach": 19.0,
    "Ravager": 12.0,
    "Hydralisk": 24.0,
    "LurkerMP": 18.0,
    "Mutalisk": 24.0,
    "Corruptor": 29.0,
    "SwarmHostMP": 29.0,
    "Infestor": 36.0,
    "Viper": 29.0,
    "Ultralisk": 39.0,
    "BroodLord": 24.0,
    "Overseer": 12.0,
    "Marine": 18.0,
    "Marauder": 21.0,
    "Reaper": 32.0,
    "Ghost": 29.0,
    "Hellion": 21.0,
    "HellionTank": 21.0,
    "WidowMine": 21.0,
    "Cyclone": 32.0,
    "SiegeTank": 32.0,
    "Thor": 43.0,
    "VikingFighter": 30.0,
    "Medivac": 30.0,
    "Liberator": 43.0,
    "Raven": 34.0,
    "Banshee": 43.0,
    "Battlecruiser": 64.0,
    "Zealot": 27.0,
    "Stalker": 30.0,
    "Sentry": 23.0,
    "Adept": 30.0,
    "HighTemplar": 39.0,
    "DarkTemplar": 39.0,
    "Archon": 8.6,
    "Observer": 21.0,
    "WarpPrism": 36.0,
    "Immortal": 39.0,
    "Colossus": 54.0,
    "Disruptor": 36.0,
    "Phoenix": 25.0,
    "Oracle": 37.0,
    "VoidRay": 43.0,
    "Tempest": 43.0,
    "Carrier": 64.0,
    "Mothership": 79.0,
}

UNIT_SUPPLY_COST = {
    "Drone": 1.0,
    "SCV": 1.0,
    "Probe": 1.0,
    "Overlord": 0.0,
    "Overseer": 0.0,
    "Queen": 2.0,
    "Zergling": 0.5,
    "Baneling": 0.5,
    "Roach": 2.0,
    "Ravager": 3.0,
    "Hydralisk": 2.0,
    "LurkerMP": 3.0,
    "Mutalisk": 2.0,
    "Corruptor": 2.0,
    "SwarmHostMP": 3.0,
    "Infestor": 2.0,
    "Viper": 3.0,
    "Ultralisk": 6.0,
    "BroodLord": 4.0,
    "Marine": 1.0,
    "Marauder": 2.0,
    "Reaper": 1.0,
    "Ghost": 2.0,
    "Hellion": 2.0,
    "HellionTank": 2.0,
    "WidowMine": 2.0,
    "Cyclone": 3.0,
    "SiegeTank": 3.0,
    "Thor": 6.0,
    "VikingFighter": 2.0,
    "Medivac": 2.0,
    "Liberator": 3.0,
    "Raven": 2.0,
    "Banshee": 3.0,
    "Battlecruiser": 6.0,
    "Zealot": 2.0,
    "Stalker": 2.0,
    "Sentry": 2.0,
    "Adept": 2.0,
    "HighTemplar": 2.0,
    "DarkTemplar": 2.0,
    "Archon": 4.0,
    "Observer": 1.0,
    "WarpPrism": 2.0,
    "Immortal": 4.0,
    "Colossus": 6.0,
    "Disruptor": 4.0,
    "Phoenix": 2.0,
    "Oracle": 3.0,
    "VoidRay": 4.0,
    "Tempest": 5.0,
    "Carrier": 6.0,
    "Mothership": 6.0,
}

IGNORE_UNITS = {
    "Larva",
    "Egg",
    "Broodling",
    "BroodlingEscort",
    "KD8Charge",
    "AdeptPhaseShift",
    "Interceptor",
    "MULE",
    "CreepTumor",
    "CreepTumorBurrowed",
    "CreepTumorQueen",
    "AutoTurret",
    "PointDefenseDrone",
    "LocustMP",
    "LocustMPFlying",
    "Changeling",
    "ChangelingZealot",
    "ChangelingMarine",
    "ChangelingMarineShield",
    "ChangelingZergling",
    "ChangelingZerglingWings",
    "ParasiticBombDummy",
    "RavagerCorrosiveBileMissile",
    "DisruptorPhased",
    "OracleStasisTrap",
    "ForceField",
}

CAMEL_TO_KEBAB = {
    "Zergling": "zergling",
    "Baneling": "baneling",
    "Drone": "drone",
    "Queen": "queen",
    "Roach": "roach",
    "Ravager": "ravager",
    "Hydralisk": "hydralisk",
    "LurkerMP": "lurker",
    "Lurker": "lurker",
    "Mutalisk": "mutalisk",
    "Corruptor": "corruptor",
    "Ultralisk": "ultralisk",
    "BroodLord": "brood-lord",
    "Infestor": "infestor",
    "SwarmHostMP": "swarm-host",
    "Viper": "viper",
    "Overlord": "overlord",
    "Overseer": "overseer",
    "Hatchery": "hatchery",
    "Lair": "lair",
    "Hive": "hive",
    "SpawningPool": "spawning-pool",
    "Extractor": "extractor",
    "RoachWarren": "roach-warren",
    "BanelingNest": "baneling-nest",
    "HydraliskDen": "hydralisk-den",
    "LurkerDenMP": "lurker-den",
    "Spire": "spire",
    "GreaterSpire": "greater-spire",
    "InfestationPit": "infestation-pit",
    "UltraliskCavern": "ultralisk-cavern",
    "EvolutionChamber": "evolution-chamber",
    "SpineCrawler": "spine-crawler",
    "SpineCrawlerUprooted": "spine-crawler",
    "SporeCrawler": "spore-crawler",
    "SporeCrawlerUprooted": "spore-crawler",
    "NydusNetwork": "nydus-network",
    "NydusCanal": "nydus-worm",
    "SCV": "scv",
    "Marine": "marine",
    "Marauder": "marauder",
    "Reaper": "reaper",
    "Ghost": "ghost",
    "Hellion": "hellion",
    "HellionTank": "hellbat",
    "WidowMine": "widow-mine",
    "Cyclone": "cyclone",
    "SiegeTank": "siege-tank",
    "SiegeTankSieged": "siege-tank-sieged",
    "Thor": "thor",
    "ThorAP": "thor",
    "VikingFighter": "viking",
    "VikingAssault": "viking",
    "Medivac": "medivac",
    "Liberator": "liberator",
    "LiberatorAG": "liberator",
    "Banshee": "banshee",
    "Raven": "raven",
    "Battlecruiser": "battlecruiser",
    "CommandCenter": "command-center",
    "OrbitalCommand": "orbital-command",
    "PlanetaryFortress": "planetary-fortress",
    "SupplyDepot": "supply-depot",
    "SupplyDepotLowered": "supply-depot",
    "Refinery": "refinery",
    "Barracks": "barracks",
    "BarracksTechLab": "barracks-techlab",
    "BarracksReactor": "barracks-reactor",
    "Factory": "factory",
    "FactoryTechLab": "factory-techlab",
    "FactoryReactor": "factory-reactor",
    "Starport": "starport",
    "StarportTechLab": "starport-techlab",
    "StarportReactor": "starport-reactor",
    "EngineeringBay": "engineering-bay",
    "Armory": "armory",
    "FusionCore": "fusion-core",
    "GhostAcademy": "ghost-academy",
    "Bunker": "bunker",
    "MissileTurret": "missile-turret",
    "SensorTower": "sensor-tower",
    "Probe": "probe",
    "Zealot": "zealot",
    "Stalker": "stalker",
    "Sentry": "sentry",
    "Adept": "adept",
    "HighTemplar": "high-templar",
    "DarkTemplar": "dark-templar",
    "Archon": "archon",
    "Observer": "observer",
    "WarpPrism": "warp-prism",
    "Immortal": "immortal",
    "Colossus": "colossus",
    "Disruptor": "disruptor",
    "Phoenix": "phoenix",
    "VoidRay": "void-ray",
    "Oracle": "oracle",
    "Tempest": "tempest",
    "Carrier": "carrier",
    "Mothership": "mothership",
    "Nexus": "nexus",
    "Pylon": "pylon",
    "Assimilator": "assimilator",
    "Gateway": "gateway",
    "WarpGate": "warpgate",
    "Forge": "forge",
    "CyberneticsCore": "cybernetics-core",
    "PhotonCannon": "photon-cannon",
    "ShieldBattery": "shield-battery",
    "TwilightCouncil": "twilight-council",
    "Stargate": "stargate",
    "RoboticsFacility": "robotics-facility",
    "RoboticsBay": "robotics-bay",
    "FleetBeacon": "fleet-beacon",
    "TemplarArchive": "templar-archive",
    "DarkShrine": "dark-shrine",
}

UPGRADE_INFO: Dict[str, Tuple[str, float]] = {
    "zerglingmovementspeed": ("zergling-movementspeed", 79.0),
    "zerglingattackspeed": ("adrenal-glands", 93.0),
    "Burrow": ("burrow", 71.0),
    "GlialReconstitution": ("glial-reconstitution", 79.0),
    "TunnelingClaws": ("tunneling-claws", 79.0),
    "CentrificalHooks": ("centrifical-hooks", 79.0),
    "overlordspeed": ("pneumatized-carapace", 43.0),
    "EvolveGroovedSpines": ("grooved-spines", 50.0),
    "EvolveMuscularAugments": ("muscular-augments", 50.0),
    "DiggingClaws": ("adaptive-talons", 57.0),
    "LurkerRange": ("seismic-spines", 57.0),
    "ChitinousPlating": ("chitinous-plating", 79.0),
    "AnabolicSynthesis": ("anabolic-synthesis", 43.0),
    "InfestorEnergyUpgrade": ("pathogen-glands", 57.0),
    "NeuralParasite": ("neural-parasite", 79.0),
    "ZergMeleeWeaponsLevel1": ("zerg-melee-weapons-1", 114.0),
    "ZergMeleeWeaponsLevel2": ("zerg-melee-weapons-2", 136.0),
    "ZergMeleeWeaponsLevel3": ("zerg-melee-weapons-3", 157.0),
    "ZergMissileWeaponsLevel1": ("zerg-missile-weapons-1", 114.0),
    "ZergMissileWeaponsLevel2": ("zerg-missile-weapons-2", 136.0),
    "ZergMissileWeaponsLevel3": ("zerg-missile-weapons-3", 157.0),
    "ZergGroundArmorsLevel1": ("zerg-ground-armor-1", 114.0),
    "ZergGroundArmorsLevel2": ("zerg-ground-armor-2", 136.0),
    "ZergGroundArmorsLevel3": ("zerg-ground-armor-3", 157.0),
    "ZergFlyerWeaponsLevel1": ("zerg-flyer-weapons-1", 114.0),
    "ZergFlyerArmorsLevel1": ("zerg-flyer-armor-1", 114.0),
    "Stimpack": ("stimpack", 100.0),
    "ShieldWall": ("combat-shield", 79.0),
    "PunisherGrenades": ("concussive-shells", 43.0),
    "HighCapacityBarrels": ("infernal-pre-igniter", 79.0),
    "DrillClaws": ("drilling-claws", 79.0),
    "SmartServos": ("smart-servos", 79.0),
    "CycloneLockOnDamageUpgrade": ("mag-field-accelerator", 79.0),
    "HurricaneThrusters": ("hurricane-thrusters", 79.0),
    "BansheeCloak": ("cloaking-field", 79.0),
    "BansheeSpeed": ("hyperflight-rotors", 100.0),
    "RavenCorvidReactor": ("corvid-reactor", 79.0),
    "LiberatorAGRangeUpgrade": ("advanced-ballistics", 79.0),
    "PersonalCloaking": ("personal-cloaking", 86.0),
    "TerranInfantryWeaponsLevel1": ("terran-infantry-weapons-1", 114.0),
    "TerranInfantryWeaponsLevel2": ("terran-infantry-weapons-2", 136.0),
    "TerranInfantryWeaponsLevel3": ("terran-infantry-weapons-3", 157.0),
    "TerranInfantryArmorsLevel1": ("terran-infantry-armor-1", 114.0),
    "TerranInfantryArmorsLevel2": ("terran-infantry-armor-2", 136.0),
    "TerranInfantryArmorsLevel3": ("terran-infantry-armor-3", 157.0),
    "TerranVehicleWeaponsLevel1": ("terran-vehicle-weapons-1", 114.0),
    "TerranVehicleAndShipArmorsLevel1": ("terran-vehicle-and-ship-plating-1", 114.0),
    "TerranShipWeaponsLevel1": ("terran-ship-weapons-1", 114.0),
    "HiSecAutoTracking": ("hi-sec-auto-tracking", 57.0),
    "TerranBuildingArmor": ("neosteel-armor", 100.0),
    "WarpGateResearch": ("warp-gate-research", 100.0),
    "Charge": ("charge", 100.0),
    "BlinkTech": ("blink", 121.0),
    "AdeptPiercingAttack": ("resonating-glaives", 100.0),
    "PsiStormTech": ("psi-storm", 79.0),
    "ExtendedThermalLance": ("extended-thermal-lance", 100.0),
    "GraviticDrive": ("gravitic-drive", 57.0),
    "ObserverGraviticBooster": ("gravitic-boosters", 57.0),
    "PhoenixRangeUpgrade": ("anion-pulse-crystals", 64.0),
    "VoidRaySpeedUpgrade": ("flux-vanes", 57.0),
    "DarkTemplarBlinkUpgrade": ("shadow-stride", 100.0),
    "ProtossGroundWeaponsLevel1": ("protoss-ground-weapons-1", 114.0),
    "ProtossGroundWeaponsLevel2": ("protoss-ground-weapons-2", 136.0),
    "ProtossGroundWeaponsLevel3": ("protoss-ground-weapons-3", 157.0),
    "ProtossGroundArmorsLevel1": ("protoss-ground-armor-1", 114.0),
    "ProtossGroundArmorsLevel2": ("protoss-ground-armor-2", 136.0),
    "ProtossGroundArmorsLevel3": ("protoss-ground-armor-3", 157.0),
    "ProtossShieldsLevel1": ("protoss-shields-1", 114.0),
    "ProtossAirWeaponsLevel1": ("protoss-air-weapons-1", 114.0),
    "ProtossAirArmorsLevel1": ("protoss-air-armor-1", 114.0),
}


def to_sym(utype: str) -> str:
    if utype in CAMEL_TO_KEBAB:
        return CAMEL_TO_KEBAB[utype]
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", utype).lower()
    return re.sub(r"[^a-z0-9\-]", "", s) or "unknown"


def normalize_race(raw_race: Any) -> str:
    s = raw_race.decode("utf-8", errors="ignore") if isinstance(raw_race, bytes) else str(raw_race)
    if any(k in s for k in ("Terran", "테란", "人类", "Терран", "Terraner")):
        return "Terran"
    if any(k in s for k in ("Zerg", "저그", "异虫", "Зерг")):
        return "Zerg"
    if any(k in s for k in ("Protoss", "프로토스", "星灵", "Протосс")):
        return "Protoss"
    return "Unknown"


def race_letter(race: str) -> str:
    return {"Zerg": "Z", "Terran": "T", "Protoss": "P"}.get(race, "?")


def clean_player_name(raw_name: Any) -> str:
    s = raw_name.decode("utf-8", errors="ignore") if isinstance(raw_name, bytes) else str(raw_name)
    s = s.replace("<sp/>", " ").replace("&lt;", "<").replace("&gt;", ">")
    s = s.replace("\\", "").replace('"', "").replace("\n", " ").strip()
    return s


def is_bot_or_ai_player(name: str, cohort_hint: str) -> bool:
    if cohort_hint == "aiarena":
        return True
    lower = name.lower().strip()
    if lower in ("null", "player 1", "player 2", ""):
        return True
    bot_markers = (
        "a.i.",
        "computer",
        "mothman",
        "bot",
        "local player",
        "cheater",
    )
    return any(m in lower for m in bot_markers)


PREMIER_PRO_NAMES = (
    "serral",
    "reynor",
    "solar",
    "shin",
    "rogue",
    "true",
    "maru",
    "gumiho",
    "special",
    "hero",
    "classic",
    "showtime",
    "stats",
    "mana",
    "trigger",
    "onescotch",
)

NON_LOTV_MELEE_MARKERS = (
    "MothershipCore",
    "Kerrigan",
    "VoidCoop",
    "HotS",
    "DuskWing",
    "QueenCoop",
)

CHRONO_TARGET_TYPES = {
    "Nexus",
    "Gateway",
    "WarpGate",
    "CyberneticsCore",
    "TwilightCouncil",
    "RoboticsFacility",
    "RoboticsBay",
    "Stargate",
    "FleetBeacon",
    "Forge",
    "TemplarArchive",
    "DarkShrine",
}


def is_premier_pro(name: str) -> bool:
    lower = name.lower()
    return any(p in lower for p in PREMIER_PRO_NAMES)


def parse_single_replay(item: Tuple[str, str]) -> List[Dict[str, Any]]:
    cohort_hint, rep_path = item
    try:
        archive = mpyq.MPQArchive(rep_path)
        header = versions.latest().decode_replay_header(archive.header["user_data_header"]["content"])
        base_build = header["m_version"]["m_baseBuild"]
        try:
            protocol = versions.build(base_build)
        except Exception:
            protocol = versions.latest()
        details = protocol.decode_replay_details(archive.read_file("replay.details"))
        tracker = list(protocol.decode_replay_tracker_events(archive.read_file("replay.tracker.events")))
    except Exception:
        return []

    plist = details.get("m_playerList", [])
    if len(plist) < 2:
        return []

    # Verify LotV 1v1 (exactly 2 players starting with 12 workers at gameloop 0)
    starting_workers = Counter()
    for ev in tracker:
        if ev["_gameloop"] > 0:
            break
        if ev["_event"] == "NNet.Replay.Tracker.SUnitBornEvent":
            u = ev["m_unitTypeName"].decode("utf-8", errors="ignore")
            if u in WORKER_TYPES:
                starting_workers[ev["m_controlPlayerId"]] += 1

    if starting_workers[1] != 12 or starting_workers[2] != 12 or len(starting_workers) != 2:
        return []

    # Exclude Co-op / Campaign / pre-4.0 HotS/MothershipCore custom games
    for ev in tracker:
        if "m_unitTypeName" in ev:
            u = ev["m_unitTypeName"].decode("utf-8", errors="ignore")
            if any(m in u for m in NON_LOTV_MELEE_MARKERS):
                return []

    # Check if either player queued as Random in replay.initData
    random_slots = {1: False, 2: False}
    try:
        init_raw = archive.read_file("replay.initData")
        if init_raw:
            init_data = protocol.decode_replay_initdata(init_raw)
            slots = init_data.get("m_syncLobbyState", {}).get("m_lobbyState", {}).get("m_slots", [])
            for idx in (0, 1):
                if idx < len(slots):
                    rpref = slots[idx].get("m_racePref", {}).get("m_race")
                    if rpref is None:
                        random_slots[idx + 1] = True
    except Exception:
        pass

    p_meta = {}
    for pid in (1, 2):
        pobj = plist[pid - 1]
        pname = clean_player_name(pobj.get("m_name", f"Player{pid}"))
        prace = normalize_race(pobj.get("m_race", ""))
        if prace == "Unknown":
            return []
        is_rand = random_slots[pid] or ("Mothman-R" in pname) or ("Mothman-X" in pname)
        p_meta[pid] = {
            "name": pname,
            "race": prace,
            "result": pobj.get("m_result", 0),
            "is_random": is_rand,
            "is_pro": not is_bot_or_ai_player(pname, cohort_hint),
        }
    both_human_pro = p_meta[1]["is_pro"] and p_meta[2]["is_pro"]
    p_meta[1]["is_pro"] = both_human_pro
    p_meta[2]["is_pro"] = both_human_pro

    map_name = clean_player_name(details.get("m_title", "UnknownMap"))
    replay_id = os.path.basename(rep_path)

    # First pass over tracker events to collect stats snapshots, unit tags, and final score
    stats_series: Dict[int, List[Tuple[int, Dict[str, Any]]]] = {1: [], 2: []}
    unit_owner: Dict[int, int] = {}
    unit_type: Dict[int, str] = {}
    unit_born_gl: Dict[int, int] = {}

    # Also build exact supply/worker timeline in [0..MAX_EXTRACT_GL]
    # Using SPlayerStatsEvent checkpoints + exact unit/building deltas between checkpoints
    for ev in tracker:
        et = ev["_event"]
        gl = ev["_gameloop"]
        if et == "NNet.Replay.Tracker.SPlayerStatsEvent":
            p = ev.get("m_playerId", 0)
            if p in (1, 2):
                st = ev["m_stats"]
                snap = {
                    "gl": gl,
                    "sec": round(gl / FASTER_FPS, 2),
                    "workers": int(st["m_scoreValueWorkersActiveCount"]),
                    "food_used": int(st["m_scoreValueFoodUsed"] // 4096),
                    "food_made": int(st["m_scoreValueFoodMade"] // 4096),
                    "min_cur": int(st["m_scoreValueMineralsCurrent"]),
                    "gas_cur": int(st["m_scoreValueVespeneCurrent"]),
                    "min_rate": int(st["m_scoreValueMineralsCollectionRate"]),
                    "gas_rate": int(st["m_scoreValueVespeneCollectionRate"]),
                    "army_min": int(st["m_scoreValueMineralsUsedCurrentArmy"]),
                    "army_gas": int(st["m_scoreValueVespeneUsedCurrentArmy"]),
                    "econ_min": int(st["m_scoreValueMineralsUsedCurrentEconomy"]),
                    "tech_min": int(st["m_scoreValueMineralsUsedCurrentTechnology"]),
                }
                stats_series[p].append((gl, snap))
        elif et in ("NNet.Replay.Tracker.SUnitBornEvent", "NNet.Replay.Tracker.SUnitInitEvent"):
            tag = (ev["m_unitTagIndex"] << 18) | ev["m_unitTagRecycle"]
            p = ev.get("m_controlPlayerId", 0)
            u = ev["m_unitTypeName"].decode("utf-8", errors="ignore")
            unit_owner[tag] = p
            unit_type[tag] = u
            unit_born_gl[tag] = gl
        elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
            tag = (ev["m_unitTagIndex"] << 18) | ev["m_unitTagRecycle"]
            u = ev["m_unitTypeName"].decode("utf-8", errors="ignore")
            if u in STRUCTURE_TYPES:
                unit_type[tag] = u

    # Resolve winner if m_result == 0 (undecided/tie in some custom lobbies)
    for pid in (1, 2):
        opp = 3 - pid
        if p_meta[pid]["result"] == 1:
            p_meta[pid]["won"] = True
        elif p_meta[pid]["result"] == 2:
            p_meta[pid]["won"] = False
        else:
            s_us = stats_series[pid][-1][1] if stats_series[pid] else {}
            s_op = stats_series[opp][-1][1] if stats_series[opp] else {}
            val_us = s_us.get("army_min", 0) + s_us.get("army_gas", 0) + s_us.get("econ_min", 0)
            val_op = s_op.get("army_min", 0) + s_op.get("army_gas", 0) + s_op.get("econ_min", 0)
            p_meta[pid]["won"] = val_us >= val_op

    # Construct a fine-grained state estimator for supply & active workers at any gameloop gl in [0..MAX_EXTRACT_GL]
    # We combine exact start-of-training / drone-consumption deltas with SPlayerStatsEvent anchor points.
    supply_deltas: Dict[int, List[Tuple[int, float, int]]] = {1: [], 2: []}  # (gl, d_supply, d_workers)
    for ev in tracker:
        gl = ev["_gameloop"]
        if gl == 0:
            continue
        et = ev["_event"]
        if et == "NNet.Replay.Tracker.SUnitBornEvent":
            p = ev.get("m_controlPlayerId", 0)
            if p not in (1, 2):
                continue
            u = ev["m_unitTypeName"].decode("utf-8", errors="ignore")
            if u in UNIT_TRAIN_TIME_SEC:
                train_gl = int(round(UNIT_TRAIN_TIME_SEC[u] * FASTER_FPS))
                start_gl = max(1, gl - train_gl)
                sup_cost = UNIT_SUPPLY_COST.get(u, 0.0)
                if sup_cost > 0 and start_gl <= MAX_EXTRACT_GL:
                    supply_deltas[p].append((start_gl, sup_cost, 0))
                if u in WORKER_TYPES and gl <= MAX_EXTRACT_GL:
                    supply_deltas[p].append((gl, 0.0, 1))
        elif et == "NNet.Replay.Tracker.SUnitInitEvent":
            p = ev.get("m_controlPlayerId", 0)
            if p not in (1, 2) or gl > MAX_EXTRACT_GL:
                continue
            u = ev["m_unitTypeName"].decode("utf-8", errors="ignore")
            if p_meta[p]["race"] == "Zerg" and u in ZERG_CONSUMED_DRONE_BLDGS:
                # Consumes 1 Drone right after SUnitInitEvent
                supply_deltas[p].append((gl + 1, -1.0, -1))
            elif u not in STRUCTURE_TYPES and u in UNIT_SUPPLY_COST:
                # Protoss WarpGate warp-in starts at SUnitInitEvent
                sup_cost = UNIT_SUPPLY_COST.get(u, 0.0)
                if sup_cost > 0:
                    supply_deltas[p].append((gl, sup_cost, 0))

    for p in (1, 2):
        supply_deltas[p].sort(key=lambda x: x[0])

    def query_supply_and_workers(p: int, target_gl: int) -> Tuple[int, int]:
        # Find the latest SPlayerStatsEvent at or before target_gl
        series = stats_series[p]
        base_gl = 0
        base_sup = 12.0
        base_wrk = 12
        for s_gl, snap in series:
            if s_gl <= target_gl:
                base_gl = s_gl
                base_sup = float(snap["food_used"])
                base_wrk = int(snap["workers"])
            else:
                break
        # Apply deltas in (base_gl, target_gl]
        d_sup = 0.0
        d_wrk = 0
        for ev_gl, ds, dw in supply_deltas[p]:
            if base_gl < ev_gl <= target_gl:
                d_sup += ds
                d_wrk += dw
            elif ev_gl > target_gl:
                break
        est_sup = max(1, int(round(base_sup + d_sup)))
        est_wrk = max(1, base_wrk + d_wrk)
        return est_sup, est_wrk

    # Extract build order events in [0s..420s]
    structures: Dict[int, List[Dict[str, Any]]] = {1: [], 2: []}
    expansions: Dict[int, List[Dict[str, Any]]] = {1: [], 2: []}
    gases: Dict[int, List[Dict[str, Any]]] = {1: [], 2: []}
    upgrades: Dict[int, List[Dict[str, Any]]] = {1: [], 2: []}
    queens: Dict[int, List[Dict[str, Any]]] = {1: [], 2: []}
    orbitals: Dict[int, List[Dict[str, Any]]] = {1: [], 2: []}
    mules: Dict[int, List[float]] = {1: [], 2: []}
    creep_tumors: Dict[int, List[float]] = {1: [], 2: []}
    unit_spawns: Dict[int, List[Dict[str, Any]]] = {1: [], 2: []}

    # Track active/in-progress bases and gases by gameloop for minute curves
    base_init_gls: Dict[int, List[int]] = {1: [0], 2: [0]}
    gas_init_gls: Dict[int, List[int]] = {1: [], 2: []}

    ling_pair_buffer: Dict[int, int] = {1: -999, 2: -999}

    for ev in tracker:
        gl = ev["_gameloop"]
        sec = round(gl / FASTER_FPS, 1)
        et = ev["_event"]

        if et == "NNet.Replay.Tracker.SUnitInitEvent":
            p = ev.get("m_controlPlayerId", 0)
            if p not in (1, 2) or gl == 0:
                continue
            u = ev["m_unitTypeName"].decode("utf-8", errors="ignore")
            sym = to_sym(u)
            if u in TOWNHALL_INIT_TYPES:
                base_init_gls[p].append(gl)
            if u in GAS_TYPES:
                gas_init_gls[p].append(gl)
            if gl > MAX_EXTRACT_GL:
                continue

            if u in ("CreepTumor", "CreepTumorQueen", "CreepTumorBurrowed"):
                if u == "CreepTumorQueen":
                    creep_tumors[p].append(sec)
                continue

            sup, wrk = query_supply_and_workers(p, gl)
            if u in STRUCTURE_TYPES:
                structures[p].append(
                    {
                        "supply": sup,
                        "sec": sec,
                        "workers": wrk,
                        "action": "build",
                        "symbol": sym,
                    }
                )
                if u in TOWNHALL_INIT_TYPES:
                    expansions[p].append(
                        {
                            "base_num": len(expansions[p]) + 2,
                            "sec": sec,
                            "supply": sup,
                            "workers": wrk,
                            "symbol": sym,
                        }
                    )
                elif u in GAS_TYPES:
                    gases[p].append(
                        {
                            "gas_num": len(gases[p]) + 1,
                            "sec": sec,
                            "supply": sup,
                            "workers": wrk,
                            "symbol": sym,
                        }
                    )
            elif u not in IGNORE_UNITS and not u.startswith("Beacon") and u in UNIT_SUPPLY_COST:
                # WarpGate unit warp-in
                unit_spawns[p].append(
                    {
                        "supply": sup,
                        "sec": sec,
                        "workers": wrk,
                        "symbol": sym,
                        "is_worker": False,
                    }
                )

        elif et == "NNet.Replay.Tracker.SUnitBornEvent":
            p = ev.get("m_controlPlayerId", 0)
            if p not in (1, 2) or gl == 0:
                continue
            u = ev["m_unitTypeName"].decode("utf-8", errors="ignore")
            if u == "MULE" and gl <= MAX_EXTRACT_GL:
                mules[p].append(sec)
                continue
            if u in IGNORE_UNITS or u.startswith("Beacon") or u in STRUCTURE_TYPES or u not in UNIT_SUPPLY_COST:
                continue

            train_sec = UNIT_TRAIN_TIME_SEC.get(u, 0.0)
            start_gl = max(1, gl - int(round(train_sec * FASTER_FPS)))
            if start_gl > MAX_EXTRACT_GL:
                continue
            start_sec = round(start_gl / FASTER_FPS, 1)
            sup, wrk = query_supply_and_workers(p, start_gl)
            sym = to_sym(u)

            if u == "Overlord":
                structures[p].append(
                    {
                        "supply": sup,
                        "sec": start_sec,
                        "workers": wrk,
                        "action": "train",
                        "symbol": "overlord",
                    }
                )
                continue

            if u == "Queen":
                queens[p].append(
                    {
                        "queen_num": len(queens[p]) + 1,
                        "start_sec": start_sec,
                        "born_sec": sec,
                        "supply": sup,
                        "workers": wrk,
                    }
                )

            if u == "Zergling":
                # Combine pair of Zerglings hatched on the same gameloop into 1 pair
                if abs(gl - ling_pair_buffer[p]) <= 2:
                    ling_pair_buffer[p] = -999
                    continue
                ling_pair_buffer[p] = gl

            unit_spawns[p].append(
                {
                    "supply": sup,
                    "sec": start_sec,
                    "born_sec": sec,
                    "workers": wrk,
                    "symbol": sym,
                    "is_worker": u in WORKER_TYPES,
                }
            )

        elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
            tag = (ev["m_unitTagIndex"] << 18) | ev["m_unitTagRecycle"]
            p = unit_owner.get(tag, 0)
            if p not in (1, 2):
                continue
            u = ev["m_unitTypeName"].decode("utf-8", errors="ignore")
            if u in MORPH_STRUCTURE_DURATION_SEC:
                dur = MORPH_STRUCTURE_DURATION_SEC[u]
                start_gl = max(1, gl - int(round(dur * FASTER_FPS)))
                if start_gl <= MAX_EXTRACT_GL:
                    start_sec = round(start_gl / FASTER_FPS, 1)
                    sup, wrk = query_supply_and_workers(p, start_gl)
                    sym = to_sym(u)
                    structures[p].append(
                        {
                            "supply": sup,
                            "sec": start_sec,
                            "complete_sec": sec,
                            "workers": wrk,
                            "action": "morph",
                            "symbol": sym,
                        }
                    )
                    if u in ("OrbitalCommand", "PlanetaryFortress"):
                        orbitals[p].append(
                            {
                                "num": len(orbitals[p]) + 1,
                                "symbol": sym,
                                "start_sec": start_sec,
                                "complete_sec": sec,
                                "supply": sup,
                                "workers": wrk,
                            }
                        )
            elif u in MORPH_UNIT_FROM_COCOON and gl <= MAX_EXTRACT_GL:
                sym, _dur, _sup = MORPH_UNIT_FROM_COCOON[u]
                sup, wrk = query_supply_and_workers(p, gl)
                unit_spawns[p].append(
                    {
                        "supply": sup,
                        "sec": sec,
                        "workers": wrk,
                        "symbol": sym,
                        "is_worker": False,
                    }
                )

        elif et == "NNet.Replay.Tracker.SUpgradeEvent":
            p = ev.get("m_playerId", 0)
            if p not in (1, 2) or gl == 0:
                continue
            raw_upg = ev["m_upgradeTypeName"].decode("utf-8", errors="ignore")
            if raw_upg not in UPGRADE_INFO:
                continue
            upg_sym, dur = UPGRADE_INFO[raw_upg]
            start_gl = max(1, gl - int(round(dur * FASTER_FPS)))
            if start_gl <= MAX_EXTRACT_GL:
                start_sec = round(start_gl / FASTER_FPS, 1)
                sup, wrk = query_supply_and_workers(p, start_gl)
                upgrades[p].append(
                    {
                        "symbol": upg_sym,
                        "start_sec": start_sec,
                        "complete_sec": sec,
                        "supply": sup,
                        "workers": wrk,
                    }
                )

    # Parse replay.game.events for Chrono Boost and Queen Inject Larva casts in [0s..420s]
    chronos: Dict[int, List[Dict[str, Any]]] = {1: [], 2: []}
    injects: Dict[int, List[float]] = {1: [], 2: []}
    try:
        game_raw = archive.read_file("replay.game.events")
        if game_raw:
            for gev in protocol.decode_replay_game_events(game_raw):
                gl = gev["_gameloop"]
                if gl > MAX_EXTRACT_GL:
                    break
                if gev["_event"] == "NNet.Game.SCmdEvent" and gev.get("m_abil") is not None:
                    abil_link = gev["m_abil"].get("m_abilLink", 0)
                    if abil_link in (16, 19, 23, 46, 92, 107, 121):
                        continue
                    d = gev.get("m_data")
                    if isinstance(d, dict) and isinstance(d.get("TargetUnit"), dict):
                        ttag = d["TargetUnit"].get("m_tag", 0)
                        p = unit_owner.get(ttag, 0)
                        if p in (1, 2):
                            ut = unit_type.get(ttag, "")
                            sec = round(gl / FASTER_FPS, 1)
                            if p_meta[p]["race"] == "Protoss" and ut in CHRONO_TARGET_TYPES and sec >= 15.0:
                                if not chronos[p] or (sec - chronos[p][-1]["sec"]) >= 2.0 or chronos[p][-1]["target"] != to_sym(ut):
                                    sup, wrk = query_supply_and_workers(p, gl)
                                    chronos[p].append(
                                        {
                                            "num": len(chronos[p]) + 1,
                                            "sec": sec,
                                            "supply": sup,
                                            "workers": wrk,
                                            "target": to_sym(ut),
                                        }
                                    )
                            elif p_meta[p]["race"] == "Zerg" and ut in ("Hatchery", "Lair", "Hive") and sec >= 135.0:
                                if not injects[p] or (sec - injects[p][-1]) >= 2.0:
                                    injects[p].append(sec)
    except Exception:
        pass

    # Sort extracted timelines by timestamp
    for p in (1, 2):
        structures[p].sort(key=lambda x: (x["sec"], x["supply"]))
        unit_spawns[p].sort(key=lambda x: (x["sec"], x["supply"]))
        upgrades[p].sort(key=lambda x: x["start_sec"])

    # Compute minute-by-minute curves at 1:00, 2:00, 3:00, 4:00, 5:00, 6:00, 7:00
    minute_curves: Dict[int, Dict[int, Dict[str, Any]]] = {1: {}, 2: {}}
    for p in (1, 2):
        series = stats_series[p]
        if not series:
            continue
        max_game_gl = series[-1][0]
        for minute in range(1, 8):
            target_gl = int(round(minute * 60.0 * FASTER_FPS))
            if max_game_gl < target_gl - int(30 * FASTER_FPS):
                # Replay ended well before this minute
                continue
            # Closest stats snapshot to target_gl
            best_gl, best_snap = min(series, key=lambda item: abs(item[0] - target_gl))
            if abs(best_gl - target_gl) > int(25 * FASTER_FPS):
                continue
            w = best_snap["workers"]
            fu = best_snap["food_used"]
            fm = best_snap["food_made"]
            army_sup = max(0, fu - w)
            bases_cnt = sum(1 for bgl in base_init_gls[p] if bgl <= target_gl)
            gases_cnt = sum(1 for ggl in gas_init_gls[p] if ggl <= target_gl)
            minute_curves[p][minute] = {
                "minute": minute,
                "sec": minute * 60,
                "workers": w,
                "army_supply": army_sup,
                "food_used": fu,
                "food_made": fm,
                "worker_to_army_ratio": round(w / max(1.0, float(army_sup)), 2),
                "army_supply_share": round(army_sup / max(1.0, float(fu)), 3),
                "bases": bases_cnt,
                "gases": gases_cnt,
                "army_value": best_snap["army_min"] + best_snap["army_gas"],
                "min_rate": best_snap["min_rate"],
                "gas_rate": best_snap["gas_rate"],
            }

    # Summarize unit production sequence by supply threshold bands
    SUPPLY_BANDS = [(12, 20), (20, 30), (30, 44), (44, 66), (66, 100), (100, 200)]
    perspectives: List[Dict[str, Any]] = []
    for pid in (1, 2):
        opp = 3 - pid
        r_us = p_meta[pid]["race"]
        r_op = p_meta[opp]["race"]
        matchup = f"{race_letter(r_us)}v{race_letter(r_op)}"

        band_summary = []
        for lo, hi in SUPPLY_BANDS:
            w_cnt = sum(1 for u in unit_spawns[pid] if lo <= u["supply"] < hi and u["is_worker"])
            c_counter = Counter(
                u["symbol"] for u in unit_spawns[pid] if lo <= u["supply"] < hi and not u["is_worker"]
            )
            if w_cnt > 0 or c_counter:
                band_summary.append(
                    {
                        "band": f"{lo}-{hi}",
                        "workers_trained": w_cnt,
                        "combat_units": dict(c_counter.most_common(6)),
                    }
                )

        # Compact supply-indexed combat + key worker transition sequence
        compact_unit_seq = []
        for u in unit_spawns[pid]:
            if not u["is_worker"]:
                if compact_unit_seq and compact_unit_seq[-1]["symbol"] == u["symbol"] and abs(compact_unit_seq[-1]["supply"] - u["supply"]) <= 2:
                    compact_unit_seq[-1]["count"] += 1
                else:
                    compact_unit_seq.append(
                        {
                            "supply": u["supply"],
                            "sec": u["sec"],
                            "symbol": u["symbol"],
                            "count": 1,
                        }
                    )

        perspectives.append(
            {
                "replay_id": replay_id,
                "map": map_name,
                "cohort": "pro" if p_meta[pid]["is_pro"] else "aiarena",
                "player": p_meta[pid]["name"],
                "opponent": p_meta[opp]["name"],
                "race": r_us,
                "opp_race": r_op,
                "matchup": matchup,
                "is_random": p_meta[pid]["is_random"],
                "opp_is_random": p_meta[opp]["is_random"],
                "won": p_meta[pid]["won"],
                "structures": structures[pid],
                "expansions": expansions[pid],
                "gases": gases[pid],
                "upgrades": upgrades[pid],
                "queens": queens[pid],
                "injects_count_7m": len(injects[pid]),
                "first_inject_sec": injects[pid][0] if injects[pid] else None,
                "creep_tumors_count_7m": len(creep_tumors[pid]),
                "first_tumor_sec": creep_tumors[pid][0] if creep_tumors[pid] else None,
                "orbitals": orbitals[pid],
                "mules_count_7m": len(mules[pid]),
                "first_mule_sec": mules[pid][0] if mules[pid] else None,
                "chronos": chronos[pid],
                "unit_bands": band_summary,
                "combat_unit_sequence": compact_unit_seq[:30],
                "minute_curves": minute_curves[pid],
            }
        )

    return perspectives


def collect_all_replays(base_dir: str) -> List[Tuple[str, str]]:
    search_specs = [
        ("pro_corpus", os.path.join(base_dir, "replays/pro_corpus/**/*.SC2Replay")),
        ("aiarena", os.path.join(base_dir, "data/aiarena_latest/**/*.SC2Replay")),
        ("aiarena", os.path.join(base_dir, "replays/aiarena_matches/**/*.SC2Replay")),
    ]
    seen_hashes = set()
    items: List[Tuple[str, str]] = []
    for cohort, pat in search_specs:
        for p in sorted(glob.glob(pat, recursive=True)):
            try:
                sz = os.path.getsize(p)
                if sz < 1000:
                    continue
                with open(p, "rb") as fh:
                    h = hashlib.sha256(fh.read(16384)).hexdigest()[:16]
                key = (sz, h)
                if key not in seen_hashes:
                    seen_hashes.add(key)
                    items.append((cohort, p))
            except Exception:
                continue
    return items


def med_round(vals: List[float], digits: int = 1) -> float:
    if not vals:
        return 0.0
    m = statistics.median(vals)
    return round(float(m), digits)


def mean_round(vals: List[float], digits: int = 1) -> float:
    if not vals:
        return 0.0
    m = statistics.mean(vals)
    return round(float(m), digits)


def aggregate_matchup(matchup: str, records: List[Dict[str, Any]]) -> Dict[str, Any]:
    # Prefer pro winning perspectives; fall back to all pro or all winners when sample is small
    pro_winners = [r for r in records if r["cohort"] == "pro" and r["won"]]
    all_winners = [r for r in records if r["won"]]
    pro_all = [r for r in records if r["cohort"] == "pro"]

    primary_pool = pro_winners if len(pro_winners) >= 3 else (all_winners if all_winners else records)
    curve_pool = all_winners if len(pro_winners) < 4 and all_winners else primary_pool

    # Choose exemplar pro game: prefer premier tournament pro winner with standard macro opening
    exemplar_candidates = [
        r
        for r in (pro_winners or pro_all or all_winners or records)
        if len(r["structures"]) >= 6 and len(r["expansions"]) >= 1
    ]
    if not exemplar_candidates:
        exemplar_candidates = records
    exp1_secs = [r["expansions"][0]["sec"] for r in primary_pool if r["expansions"]]
    med_exp1 = statistics.median(exp1_secs) if exp1_secs else 60.0
    exemplar = min(
        exemplar_candidates,
        key=lambda r: (
            0 if is_premier_pro(r["player"]) else 45.0,
            abs((r["expansions"][0]["sec"] if r["expansions"] else 120.0) - med_exp1)
            - 0.5 * min(20, len(r["structures"])),
        ),
    )

    # Aggregate expansion timings (Base 2 = Natural, Base 3 = Third, Base 4 = Fourth)
    expansion_summary = []
    prev_sec = 0.0
    for b_idx in range(3):
        b_num = b_idx + 2
        valid_exps = [
            r["expansions"][b_idx]
            for r in primary_pool
            if len(r["expansions"]) > b_idx and r["expansions"][b_idx]["sec"] > prev_sec
        ]
        if valid_exps:
            secs = [e["sec"] for e in valid_exps]
            sups = [e["supply"] for e in valid_exps]
            wrks = [e["workers"] for e in valid_exps]
            med_s = med_round(secs, 1)
            prev_sec = med_s
            expansion_summary.append(
                {
                    "base_num": b_num,
                    "count": len(secs),
                    "median_sec": med_s,
                    "median_supply": int(round(statistics.median(sups))),
                    "median_workers": int(round(statistics.median(wrks))),
                }
            )

    # Aggregate gas timings (Gas 1..4)
    gas_summary = []
    for g_idx in range(4):
        g_num = g_idx + 1
        secs = [r["gases"][g_idx]["sec"] for r in primary_pool if len(r["gases"]) > g_idx]
        sups = [r["gases"][g_idx]["supply"] for r in primary_pool if len(r["gases"]) > g_idx]
        wrks = [r["gases"][g_idx]["workers"] for r in primary_pool if len(r["gases"]) > g_idx]
        if secs:
            gas_summary.append(
                {
                    "gas_num": g_num,
                    "count": len(secs),
                    "median_sec": med_round(secs, 1),
                    "median_supply": int(round(statistics.median(sups))),
                    "median_workers": int(round(statistics.median(wrks))),
                }
            )

    # Aggregate first occurrence of each tech/production structure across primary_pool
    bldg_first_sec: Dict[str, List[float]] = defaultdict(list)
    bldg_first_sup: Dict[str, List[int]] = defaultdict(list)
    bldg_first_wrk: Dict[str, List[int]] = defaultdict(list)
    for r in primary_pool:
        seen_b = set()
        for st in r["structures"]:
            sym = st["symbol"]
            if sym not in seen_b:
                seen_b.add(sym)
                bldg_first_sec[sym].append(st["sec"])
                bldg_first_sup[sym].append(st["supply"])
                bldg_first_wrk[sym].append(st["workers"])

    tech_timings = []
    for sym, secs in bldg_first_sec.items():
        if len(secs) >= max(1, len(primary_pool) // 6):
            tech_timings.append(
                {
                    "symbol": sym,
                    "frequency": round(len(secs) / max(1, len(primary_pool)), 2),
                    "median_sec": med_round(secs, 1),
                    "median_supply": int(round(statistics.median(bldg_first_sup[sym]))),
                    "median_workers": int(round(statistics.median(bldg_first_wrk[sym]))),
                }
            )
    tech_timings.sort(key=lambda x: x["median_sec"])

    # Aggregate upgrades
    upg_start_sec: Dict[str, List[float]] = defaultdict(list)
    upg_comp_sec: Dict[str, List[float]] = defaultdict(list)
    upg_sup: Dict[str, List[int]] = defaultdict(list)
    upg_wrk: Dict[str, List[int]] = defaultdict(list)
    for r in primary_pool:
        seen_u = set()
        for u in r["upgrades"]:
            sym = u["symbol"]
            if sym not in seen_u:
                seen_u.add(sym)
                upg_start_sec[sym].append(u["start_sec"])
                upg_comp_sec[sym].append(u["complete_sec"])
                upg_sup[sym].append(u["supply"])
                upg_wrk[sym].append(u["workers"])

    upgrade_timings = []
    for sym, secs in upg_start_sec.items():
        upgrade_timings.append(
            {
                "symbol": sym,
                "count": len(secs),
                "median_start_sec": med_round(secs, 1),
                "median_complete_sec": med_round(upg_comp_sec[sym], 1),
                "median_supply": int(round(statistics.median(upg_sup[sym]))),
                "median_workers": int(round(statistics.median(upg_wrk[sym]))),
            }
        )
    upgrade_timings.sort(key=lambda x: x["median_start_sec"])

    # Aggregate macro mechanics (Queens / Orbitals / Chronos)
    macro_summary: Dict[str, Any] = {}
    race_char = matchup[0]
    if race_char == "Z":
        for q_idx in range(4):
            q_starts = [r["queens"][q_idx]["start_sec"] for r in primary_pool if len(r["queens"]) > q_idx]
            q_borns = [r["queens"][q_idx]["born_sec"] for r in primary_pool if len(r["queens"]) > q_idx]
            q_sups = [r["queens"][q_idx]["supply"] for r in primary_pool if len(r["queens"]) > q_idx]
            if q_starts:
                macro_summary[f"queen_{q_idx + 1}"] = {
                    "start_sec": med_round(q_starts, 1),
                    "born_sec": med_round(q_borns, 1),
                    "supply": int(round(statistics.median(q_sups))),
                }
        inj_secs = [r["first_inject_sec"] for r in primary_pool if r["first_inject_sec"] is not None]
        tum_secs = [r["first_tumor_sec"] for r in primary_pool if r["first_tumor_sec"] is not None]
        macro_summary["first_inject_sec"] = med_round(inj_secs, 1) if inj_secs else 0.0
        macro_summary["first_creep_tumor_sec"] = med_round(tum_secs, 1) if tum_secs else 0.0
    elif race_char == "T":
        for o_idx in range(3):
            o_starts = [r["orbitals"][o_idx]["start_sec"] for r in primary_pool if len(r["orbitals"]) > o_idx]
            o_comps = [r["orbitals"][o_idx]["complete_sec"] for r in primary_pool if len(r["orbitals"]) > o_idx]
            o_sups = [r["orbitals"][o_idx]["supply"] for r in primary_pool if len(r["orbitals"]) > o_idx]
            if o_starts:
                macro_summary[f"orbital_{o_idx + 1}"] = {
                    "start_sec": med_round(o_starts, 1),
                    "complete_sec": med_round(o_comps, 1),
                    "supply": int(round(statistics.median(o_sups))),
                }
        mule_secs = [r["first_mule_sec"] for r in primary_pool if r["first_mule_sec"] is not None]
        macro_summary["first_mule_sec"] = med_round(mule_secs, 1) if mule_secs else 0.0
    elif race_char == "P":
        for c_idx in range(5):
            c_secs = [r["chronos"][c_idx]["sec"] for r in primary_pool if len(r["chronos"]) > c_idx]
            c_sups = [r["chronos"][c_idx]["supply"] for r in primary_pool if len(r["chronos"]) > c_idx]
            c_tgts = [r["chronos"][c_idx]["target"] for r in primary_pool if len(r["chronos"]) > c_idx]
            if c_secs:
                top_tgt = Counter(c_tgts).most_common(1)[0][0]
                macro_summary[f"chrono_{c_idx + 1}"] = {
                    "sec": med_round(c_secs, 1),
                    "supply": int(round(statistics.median(c_sups))),
                    "target": top_tgt,
                }

    # Aggregate empirical worker-to-army supply curves at 1:00..7:00 for winning players
    curves_by_min = []
    for minute in range(1, 8):
        m_snaps = [r["minute_curves"][minute] for r in curve_pool if minute in r["minute_curves"]]
        if not m_snaps:
            m_snaps = [r["minute_curves"][minute] for r in records if minute in r["minute_curves"]]
        if m_snaps:
            w_vals = [s["workers"] for s in m_snaps]
            a_vals = [s["army_supply"] for s in m_snaps]
            fu_vals = [s["food_used"] for s in m_snaps]
            fm_vals = [s["food_made"] for s in m_snaps]
            b_vals = [s["bases"] for s in m_snaps]
            g_vals = [s["gases"] for s in m_snaps]
            av_vals = [s["army_value"] for s in m_snaps]
            mr_vals = [s["min_rate"] for s in m_snaps]
            gr_vals = [s["gas_rate"] for s in m_snaps]
            med_w = med_round(w_vals, 1)
            med_a = med_round(a_vals, 1)
            Med_fu = med_round(fu_vals, 1)
            curves_by_min.append(
                {
                    "minute": minute,
                    "sec": minute * 60,
                    "time_label": f"{minute}:00",
                    "samples": len(m_snaps),
                    "median_workers": med_w,
                    "mean_workers": mean_round(w_vals, 1),
                    "median_army_supply": med_a,
                    "mean_army_supply": mean_round(a_vals, 1),
                    "median_total_supply": Med_fu,
                    "median_supply_cap": med_round(fm_vals, 1),
                    "worker_to_army_ratio": round(med_w / max(1.0, med_a), 2),
                    "army_supply_pct": round(100.0 * med_a / max(1.0, Med_fu), 1),
                    "median_bases": med_round(b_vals, 1),
                    "median_gases": med_round(g_vals, 1),
                    "median_army_value": int(round(statistics.median(av_vals))),
                    "median_min_rate": int(round(statistics.median(mr_vals))),
                    "median_gas_rate": int(round(statistics.median(gr_vals))),
                }
            )

    # Aggregate unit production by supply threshold bands across primary_pool
    SUPPLY_BANDS = ["12-20", "20-30", "30-44", "44-66", "66-100", "100-200"]
    unit_band_agg = []
    for b_name in SUPPLY_BANDS:
        w_list = []
        c_totals: Counter = Counter()
        for r in primary_pool:
            for b in r["unit_bands"]:
                if b["band"] == b_name:
                    w_list.append(b["workers_trained"])
                    for u_sym, cnt in b["combat_units"].items():
                        c_totals[u_sym] += cnt
        if w_list or c_totals:
            unit_band_agg.append(
                {
                    "band": b_name,
                    "median_workers_trained": int(round(statistics.median(w_list))) if w_list else 0,
                    "top_combat_units": c_totals.most_common(6),
                }
            )

    return {
        "matchup": matchup,
        "total_perspectives": len(records),
        "pro_perspectives": len(pro_all),
        "winning_perspectives": len(all_winners),
        "pro_winning_perspectives": len(pro_winners),
        "exemplar_player": exemplar["player"],
        "exemplar_opponent": exemplar["opponent"],
        "exemplar_map": exemplar["map"],
        "exemplar_replay": exemplar["replay_id"],
        "exemplar_structures": exemplar["structures"][:28],
        "exemplar_upgrades": exemplar["upgrades"],
        "exemplar_combat_sequence": exemplar["combat_unit_sequence"][:20],
        "expansions": expansion_summary,
        "gases": gas_summary,
        "tech_timings": tech_timings,
        "upgrade_timings": upgrade_timings,
        "macro_mechanics": macro_summary,
        "unit_production_bands": unit_band_agg,
        "winning_supply_curves": curves_by_min,
    }


def write_sexp_database(
    out_path: str,
    total_replays: int,
    all_perspectives: List[Dict[str, Any]],
    matchup_summaries: Dict[str, Dict[str, Any]],
    random_summaries: Dict[str, Dict[str, Any]],
) -> None:
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    lines: List[str] = []
    lines.append(";; =============================================================================")
    lines.append(";; Canonical StarCraft II: Legacy of the Void (LotV) Pro Build-Order &")
    lines.append(";; Empirical Worker-to-Army Supply Curve Database (`data/pro_build_orders.sexp`)")
    lines.append(";;")
    lines.append(";; Auto-mined by `tools/extract_pro_build_orders.py` using `mpyq` + `s2protocol`")
    lines.append(f";; from {total_replays} LotV 1v1 replays ({len(all_perspectives)} player perspectives)")
    lines.append(";; across `replays/pro_corpus/`, `data/aiarena_latest/`, and `replays/aiarena_matches/`.")
    lines.append(";; =============================================================================")
    lines.append("")
    lines.append("(pro-build-order-database")
    lines.append(f"  (metadata")
    lines.append(f"    (schema-version 1.0)")
    lines.append(f"    (lotv-1v1-replays {total_replays})")
    lines.append(f"    (total-perspectives {len(all_perspectives)})")
    lines.append(f"    (pro-perspectives {sum(1 for r in all_perspectives if r['cohort'] == 'pro')})")
    lines.append(f"    (winning-perspectives {sum(1 for r in all_perspectives if r['won'])})")
    lines.append(f"    (horizon-seconds 420))")
    lines.append("")
    lines.append("  (matchups")

    for mu in ("ZvZ", "ZvT", "ZvP", "TvZ", "TvT", "TvP", "PvZ", "PvT", "PvP"):
        ms = matchup_summaries.get(mu)
        if not ms:
            continue
        lines.append(f"    (matchup {mu}")
        lines.append(
            f"      (samples (total {ms['total_perspectives']}) (pro {ms['pro_perspectives']}) "
            f"(winners {ms['winning_perspectives']}) (pro-winners {ms['pro_winning_perspectives']}))"
        )
        lines.append(
            f'      (exemplar (player "{ms["exemplar_player"]}") (opponent "{ms["exemplar_opponent"]}") '
            f'(map "{ms["exemplar_map"]}") (replay "{ms["exemplar_replay"]}"))'
        )

        # Expansions
        lines.append("      (expansions")
        for ex in ms["expansions"]:
            lines.append(
                f"        (base {ex['base_num']} (median-sec {ex['median_sec']}) "
                f"(supply {ex['median_supply']}) (workers {ex['median_workers']}) (n {ex['count']}))"
            )
        lines.append("      )")

        # Gases
        lines.append("      (gases")
        for gs in ms["gases"]:
            lines.append(
                f"        (geyser {gs['gas_num']} (median-sec {gs['median_sec']}) "
                f"(supply {gs['median_supply']}) (workers {gs['median_workers']}) (n {gs['count']}))"
            )
        lines.append("      )")

        # Macro Mechanics
        lines.append("      (macro-mechanics")
        for k, v in ms["macro_mechanics"].items():
            if isinstance(v, dict):
                kv_str = " ".join(f"({ sk } { sv })" for sk, sv in v.items())
                lines.append(f"        ({k} {kv_str})")
            else:
                lines.append(f"        ({k} {v})")
        lines.append("      )")

        # Canonical Build Order Steps (first 7 minutes)
        lines.append("      (canonical-build-order")
        for st in ms["exemplar_structures"]:
            lines.append(
                f"        (step (supply {st['supply']}) (sec {st['sec']}) "
                f"(workers {st['workers']}) ({st['action']} {st['symbol']}))"
            )
        lines.append("      )")

        # Tech Building Timings (median across pro winners)
        lines.append("      (median-tech-structure-timings")
        for tt in ms["tech_timings"]:
            lines.append(
                f"        (structure {tt['symbol']} (median-sec {tt['median_sec']}) "
                f"(supply {tt['median_supply']}) (workers {tt['median_workers']}) (freq {tt['frequency']}))"
            )
        lines.append("      )")

        # Upgrade Research Timings
        lines.append("      (upgrade-research-timings")
        for ut in ms["upgrade_timings"]:
            lines.append(
                f"        (upgrade {ut['symbol']} (start-sec {ut['median_start_sec']}) "
                f"(complete-sec {ut['median_complete_sec']}) (supply {ut['median_supply']}) "
                f"(workers {ut['median_workers']}) (n {ut['count']}))"
            )
        lines.append("      )")

        # Unit Production Sequence by Supply Band
        lines.append("      (unit-production-by-supply-band")
        for ub in ms["unit_production_bands"]:
            c_str = " ".join(f"({u} {c})" for u, c in ub["top_combat_units"])
            lines.append(
                f'        (band "{ub["band"]}" (median-workers {ub["median_workers_trained"]}) '
                f"(combat-mix ({c_str})))"
            )
        lines.append("      )")

        # Exemplar Combat Unit Sequence
        lines.append("      (exemplar-combat-unit-sequence")
        for cu in ms["exemplar_combat_sequence"]:
            lines.append(
                f"        (produce (supply {cu['supply']}) (sec {cu['sec']}) "
                f"(unit {cu['symbol']}) (count {cu['count']}))"
            )
        lines.append("      )")

        # Empirical Worker-to-Army Supply Curves (1:00..7:00)
        lines.append("      (winning-worker-to-army-supply-curve")
        for mc in ms["winning_supply_curves"]:
            lines.append(
                f"        (minute {mc['minute']} (sec {mc['sec']}) "
                f"(workers {mc['median_workers']}) (army-supply {mc['median_army_supply']}) "
                f"(total-supply {mc['median_total_supply']}) (supply-cap {mc['median_supply_cap']}) "
                f"(worker-army-ratio {mc['worker_to_army_ratio']}) (army-share-pct {mc['army_supply_pct']}) "
                f"(bases {mc['median_bases']}) (gases {mc['median_gases']}) "
                f"(army-value {mc['median_army_value']}) (min-rate {mc['median_min_rate']}) "
                f"(gas-rate {mc['median_gas_rate']}) (n {mc['samples']}))"
            )
        lines.append("      )")
        lines.append("    )")

    lines.append("  )")
    lines.append("")
    lines.append("  (random-opening-variants")
    for rk, rinfo in random_summaries.items():
        lines.append(f"    (variant {rk}")
        lines.append(f"      (samples {rinfo['samples']})")
        lines.append(f'      (description "{rinfo["description"]}")')
        lines.append(f"      (scout-trigger-supply {rinfo['scout_supply']})")
        lines.append("      (opening-steps")
        for st in rinfo["opening_steps"]:
            lines.append(
                f"        (step (supply {st['supply']}) (sec {st['sec']}) "
                f"(workers {st['workers']}) ({st['action']} {st['symbol']}))"
            )
        lines.append("      )")
        lines.append("    )")
    lines.append("  )")
    lines.append(")")
    lines.append("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def build_random_opening_summaries(
    all_perspectives: List[Dict[str, Any]],
    matchup_summaries: Dict[str, Dict[str, Any]],
) -> Dict[str, Dict[str, Any]]:
    # Both players who rolled Random (RvX) and players facing an unknown Random opponent (XvR)
    rvz = [r for r in all_perspectives if r["is_random"] and r["race"] == "Zerg"]
    rvt = [r for r in all_perspectives if r["is_random"] and r["race"] == "Terran"]
    rvp = [r for r in all_perspectives if r["is_random"] and r["race"] == "Protoss"]
    zvr = [r for r in all_perspectives if r["opp_is_random"] and r["race"] == "Zerg"]
    tvr = [r for r in all_perspectives if r["opp_is_random"] and r["race"] == "Terran"]
    pvr = [r for r in all_perspectives if r["opp_is_random"] and r["race"] == "Protoss"]

    return {
        "RvX-Rolled-Zerg": {
            "samples": len(rvz),
            "description": "Random player rolling Zerg: 13 Overlord -> 16 Hatchery -> 18 Extractor -> 17 Spawning Pool -> 20 Overlord -> 2x Queen + 4 Zerglings (universal safe opening before opponent race adaptation)",
            "scout_supply": 13,
            "opening_steps": matchup_summaries["ZvT"]["exemplar_structures"][:10],
        },
        "RvX-Rolled-Terran": {
            "samples": len(rvt),
            "description": "Random player rolling Terran: 14 Supply Depot (ramp wall) -> 16 Barracks -> 16 Refinery -> 19 Orbital Command + Reaper scout -> 20 Command Center (Natural) -> 21 Factory",
            "scout_supply": 14,
            "opening_steps": matchup_summaries["TvZ"]["exemplar_structures"][:10],
        },
        "RvX-Rolled-Protoss": {
            "samples": len(rvp),
            "description": "Random player rolling Protoss: 14 Pylon (low-ground/ramp wall) -> 16 Gateway (Probe scout) -> 17 Assimilator -> 20 Nexus -> 20 Cybernetics Core -> 21 Assimilator -> 22 Pylon",
            "scout_supply": 16,
            "opening_steps": matchup_summaries["PvT"]["exemplar_structures"][:10],
        },
        "ZvR-Anti-Random-Zerg": {
            "samples": len(zvr),
            "description": "Zerg vs unknown Random opponent: 13 Overlord + 14 Drone scout -> 16 Hatchery -> 18 Extractor -> 17 Spawning Pool (holds 2nd Overlord & Bane Nest/Roach Warren choice until Drone scout identifies T/P/Z at ~1:05)",
            "scout_supply": 14,
            "opening_steps": matchup_summaries["ZvZ"]["exemplar_structures"][:10],
        },
        "TvR-Anti-Random-Terran": {
            "samples": len(tvr),
            "description": "Terran vs unknown Random opponent: 14 Supply Depot at main ramp -> 16 Barracks + 16 SCV scout -> 16 Refinery -> 19 Reaper + Orbital Command -> 20 Command Center on high/low ground after SCV confirms race",
            "scout_supply": 16,
            "opening_steps": matchup_summaries["TvP"]["exemplar_structures"][:10],
        },
        "PvR-Anti-Random-Protoss": {
            "samples": len(pvr),
            "description": "Protoss vs unknown Random opponent: 14 Pylon at natural/ramp wall -> 16 Gateway + immediate 16 Probe scout -> 17 Assimilator -> 20 Cybernetics Core before/after 20 Nexus depending on Zerg/Terran/Protoss identification",
            "scout_supply": 16,
            "opening_steps": matchup_summaries["PvZ"]["exemplar_structures"][:10],
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract canonical LotV pro build orders and supply curves")
    parser.add_argument(
        "--base-dir",
        default="/home/antigravity/sticklane/ws13-okasaki-quantum-data-structures/sc-bot",
        help="Root directory of sc-bot workspace",
    )
    parser.add_argument(
        "--out-sexp",
        default="/home/antigravity/sticklane/ws13-okasaki-quantum-data-structures/sc-bot/data/pro_build_orders.sexp",
        help="Output S-expression path",
    )
    parser.add_argument(
        "--out-json",
        default="/home/antigravity/sticklane/ws13-okasaki-quantum-data-structures/sc-bot/data/pro_build_orders_summary.json",
        help="Output JSON summary path",
    )
    args = parser.parse_args()

    items = collect_all_replays(args.base_dir)
    print(f"[INFO] Scanning {len(items)} unique .SC2Replay archives across pro_corpus, aiarena_latest, aiarena_matches...")

    all_perspectives: List[Dict[str, Any]] = []
    lotv_replays = 0
    with mp.Pool(processes=min(16, max(1, mp.cpu_count()))) as pool:
        for persp_list in pool.imap_unordered(parse_single_replay, items, chunksize=16):
            if persp_list:
                lotv_replays += 1
                all_perspectives.extend(persp_list)

    by_matchup: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for p in all_perspectives:
        by_matchup[p["matchup"]].append(p)

    matchup_summaries: Dict[str, Dict[str, Any]] = {}
    for mu in ("ZvZ", "ZvT", "ZvP", "TvZ", "TvT", "TvP", "PvZ", "PvT", "PvP"):
        recs = by_matchup.get(mu, [])
        if recs:
            matchup_summaries[mu] = aggregate_matchup(mu, recs)

    random_summaries = build_random_opening_summaries(all_perspectives, matchup_summaries)
    write_sexp_database(args.out_sexp, lotv_replays, all_perspectives, matchup_summaries, random_summaries)

    with open(args.out_json, "w", encoding="utf-8") as jf:
        json.dump(
            {
                "lotv_replays": lotv_replays,
                "total_perspectives": len(all_perspectives),
                "matchups": matchup_summaries,
                "random_variants": random_summaries,
            },
            jf,
            indent=2,
        )

    print(
        f"[OK] Extracted {len(all_perspectives)} player perspectives from {lotv_replays} LotV 1v1 replays "
        f"into {args.out_sexp} and {args.out_json}"
    )
    for mu in ("ZvZ", "ZvT", "ZvP", "TvZ", "TvT", "TvP", "PvZ", "PvT", "PvP"):
        ms = matchup_summaries.get(mu)
        if not ms:
            continue
        exp_str = ", ".join(
            f"B{e['base_num']}@{e['median_sec']}s({e['median_supply']}sup/{e['median_workers']}w)"
            for e in ms["expansions"]
        )
        gas_str = ", ".join(
            f"G{g['gas_num']}@{g['median_sec']}s({g['median_supply']}sup/{g['median_workers']}w)"
            for g in ms["gases"]
        )
        c7 = next((c for c in ms["winning_supply_curves"] if c["minute"] == 7), None)
        c7_str = (
            f"7:00 W={c7['median_workers']}/Army={c7['median_army_supply']} (ratio={c7['worker_to_army_ratio']})"
            if c7
            else "n/a"
        )
        print(
            f"  {mu} (n={ms['total_perspectives']}, pro={ms['pro_perspectives']}, win={ms['winning_perspectives']}) "
            f"| Exemplar: {ms['exemplar_player']} vs {ms['exemplar_opponent']} "
            f"| Exp: [{exp_str}] | Gas: [{gas_str}] | {c7_str}"
        )


if __name__ == "__main__":
    main()
