#!/usr/bin/env python3
"""
Zero-Dependency Blizzard MPQ + S2Protocol VersionedDecoder Pro-Replay Checkpoint Unpacker
(`tools/extract_pro_starvation_checkpoints.py`).

Unpacks `.SC2Replay` archives across `replays/pro_corpus/` using pure Python standard
library (`struct`, `zlib`, `bz2`, `multiprocessing`) into a compact S-expression dataset
`data/pro_starvation_checkpoints.sexp` for the pure Racket `#lang sc-bot` Pro-Replay
Starvation & Deadlock Verifier (`lib/pro-replay-starvation-audit.rkt`).
"""

import bz2
import glob
import hashlib
import multiprocessing as mp
import os
import re
import struct
import sys
import zlib


def _build_storm_crypt_table():
    seed = 0x00100001
    crypt = [0] * 1280
    for i in range(256):
        idx = i
        for _ in range(5):
            seed = (seed * 125 + 3) % 0x2AAAAB
            t1 = (seed & 0xFFFF) << 16
            seed = (seed * 125 + 3) % 0x2AAAAB
            t2 = seed & 0xFFFF
            crypt[idx] = t1 | t2
            idx += 256
    return crypt


STORM_CRYPT = _build_storm_crypt_table()


def mpq_hash(s: str, hash_type: int) -> int:
    seed1 = 0x7FED7FED
    seed2 = 0xEEEEEEEE
    for ch in s.upper().encode("ascii"):
        val = STORM_CRYPT[(hash_type << 8) + ch]
        seed1 = (val ^ ((seed1 + seed2) & 0xFFFFFFFF)) & 0xFFFFFFFF
        seed2 = (ch + seed1 + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF
    return seed1


def mpq_decrypt(data: bytes, key: int) -> bytes:
    seed1 = key & 0xFFFFFFFF
    seed2 = 0xEEEEEEEE
    n = len(data) & ~3
    out = bytearray(n)
    for i in range(0, n, 4):
        seed2 = (seed2 + STORM_CRYPT[0x400 + (seed1 & 0xFF)]) & 0xFFFFFFFF
        val = struct.unpack_from("<I", data, i)[0]
        val = (val ^ ((seed1 + seed2) & 0xFFFFFFFF)) & 0xFFFFFFFF
        seed1 = ((((~seed1) & 0xFFFFFFFF) << 0x15) + 0x11111111) & 0xFFFFFFFF | (seed1 >> 0x0B)
        seed2 = (val + seed2 + (seed2 << 5) + 3) & 0xFFFFFFFF
        struct.pack_into("<I", out, i, val)
    return bytes(out)


def _decompress_mpq_sector(raw: bytes, expected_size: int) -> bytes:
    if len(raw) >= expected_size:
        return raw
    ctype = raw[0]
    payload = raw[1:]
    if ctype == 0x02:
        return zlib.decompress(payload)
    if ctype == 0x10:
        return bz2.decompress(payload)
    return raw


def read_mpq_files(path: str, filenames=("replay.details", "replay.tracker.events")):
    with open(path, "rb") as f:
        blob = f.read()
    if len(blob) < 64:
        return None
    if blob[:4] == b"MPQ\x1b":
        _, _, mpq_offset, ud_hdr_sz = struct.unpack_from("<4sIII", blob, 0)
        user_data = blob[16 : 16 + ud_hdr_sz]
    elif blob[:4] == b"MPQ\x1a":
        mpq_offset = 0
        user_data = b""
    else:
        return None

    if blob[mpq_offset : mpq_offset + 4] != b"MPQ\x1a":
        return None
    (
        _,
        _hdr_sz,
        _arch_sz,
        _fmt_ver,
        sector_shift,
        ht_off,
        bt_off,
        ht_entries,
        bt_entries,
    ) = struct.unpack_from("<4sIIHHIIII", blob, mpq_offset)

    sector_size = 512 << sector_shift
    ht_raw = mpq_decrypt(
        blob[mpq_offset + ht_off : mpq_offset + ht_off + ht_entries * 16],
        mpq_hash("(hash table)", 3),
    )
    bt_raw = mpq_decrypt(
        blob[mpq_offset + bt_off : mpq_offset + bt_off + bt_entries * 16],
        mpq_hash("(block table)", 3),
    )

    hash_map = {}
    for i in range(ht_entries):
        ha, hb, _loc, _plat, blk_idx = struct.unpack_from("<IIHHI", ht_raw, i * 16)
        if blk_idx < bt_entries:
            hash_map[(ha, hb)] = blk_idx

    out = {"_user_data": user_data}
    for fname in filenames:
        ha = mpq_hash(fname, 1)
        hb = mpq_hash(fname, 2)
        blk_idx = hash_map.get((ha, hb))
        if blk_idx is None:
            continue
        f_off, arch_sz, full_sz, flags = struct.unpack_from("<IIII", bt_raw, blk_idx * 16)
        if not (flags & 0x80000000):  # MPQ_FILE_EXISTS
            continue
        abs_off = mpq_offset + f_off
        raw_file = blob[abs_off : abs_off + arch_sz]
        compressed = bool(flags & 0x00000200)
        single_unit = bool(flags & 0x01000000)
        if full_sz == 0:
            out[fname] = b""
        elif single_unit:
            out[fname] = _decompress_mpq_sector(raw_file, full_sz) if compressed else raw_file
        elif compressed:
            n_sectors = (full_sz + sector_size - 1) // sector_size
            offsets = struct.unpack_from(f"<{n_sectors + 1}I", raw_file, 0)
            parts = []
            rem = full_sz
            for s_idx in range(n_sectors):
                s_bytes = raw_file[offsets[s_idx] : offsets[s_idx + 1]]
                want = min(sector_size, rem)
                parts.append(_decompress_mpq_sector(s_bytes, want))
                rem -= want
            out[fname] = b"".join(parts)
        else:
            out[fname] = raw_file[:full_sz]
    return out


def read_vint(buf: bytes, pos: int):
    b = buf[pos]
    pos += 1
    neg = b & 1
    res = (b >> 1) & 0x3F
    bits = 6
    while b & 0x80:
        b = buf[pos]
        pos += 1
        res |= (b & 0x7F) << bits
        bits += 7
    return (-res if neg else res), pos


def decode_versioned(buf: bytes, pos: int = 0):
    tag = buf[pos]
    pos += 1
    if tag == 0:  # array
        n, pos = read_vint(buf, pos)
        arr = []
        for _ in range(n):
            v, pos = decode_versioned(buf, pos)
            arr.append(v)
        return arr, pos
    if tag == 1:  # bitarray
        nbits, pos = read_vint(buf, pos)
        nbytes = (nbits + 7) // 8
        return buf[pos : pos + nbytes], pos + nbytes
    if tag == 2:  # blob
        n, pos = read_vint(buf, pos)
        return buf[pos : pos + n], pos + n
    if tag == 3:  # choice
        flag, pos = read_vint(buf, pos)
        v, pos = decode_versioned(buf, pos)
        return (flag, v), pos
    if tag == 4:  # optional
        has = buf[pos]
        pos += 1
        if has:
            return decode_versioned(buf, pos)
        return None, pos
    if tag == 5:  # struct
        nf, pos = read_vint(buf, pos)
        d = {}
        for _ in range(nf):
            ftag, pos = read_vint(buf, pos)
            v, pos = decode_versioned(buf, pos)
            d[ftag] = v
        return d, pos
    if tag == 6:  # u8
        return buf[pos], pos + 1
    if tag == 7:  # u32
        return struct.unpack_from(">I", buf, pos)[0], pos + 4
    if tag == 8:  # u64
        return struct.unpack_from(">Q", buf, pos)[0], pos + 8
    if tag == 9:  # vint
        return read_vint(buf, pos)
    raise ValueError(f"Unknown versioned tag {tag} at {pos - 1}")


def decode_tracker_stream(buf: bytes):
    pos = 0
    gl = 0
    n = len(buf)
    events = []
    while pos < n:
        # In replay.tracker.events, each record is:
        #   03 <delta_gl_choice_or_vint> <event_id> <struct>
        # Let's handle both direct vint and tagged struct delta_gameloop!
        v0, pos = decode_versioned(buf, pos)
        if isinstance(v0, dict):
            # Some versions wrap delta_gl in {0: delta}
            d_gl = v0.get(0, 0)
            if isinstance(d_gl, tuple):
                d_gl = d_gl[1]
        elif isinstance(v0, tuple):
            d_gl = v0[1]
        else:
            d_gl = int(v0)
        gl += d_gl
        ev_id, pos = decode_versioned(buf, pos)
        if isinstance(ev_id, tuple):
            ev_id = ev_id[1]
        payload, pos = decode_versioned(buf, pos)
        events.append((gl, ev_id, payload))
    return events


CAMEL_TO_KEBAB = {
    "Zergling": "zergling", "Baneling": "baneling", "BanelingCocoon": "baneling",
    "Drone": "drone", "Queen": "queen", "Roach": "roach", "Ravager": "ravager",
    "RavagerCocoon": "ravager", "Hydralisk": "hydralisk", "LurkerMP": "lurker",
    "Lurker": "lurker", "LurkerMPCocoon": "lurker", "Mutalisk": "mutalisk",
    "Corruptor": "corruptor", "Ultralisk": "ultralisk", "BroodLord": "brood-lord",
    "BroodLordCocoon": "brood-lord", "Infestor": "infestor", "Viper": "viper",
    "Overlord": "overlord", "Overseer": "overseer", "OverseerCocoon": "overseer",
    "Hatchery": "hatchery", "Lair": "lair", "Hive": "hive",
    "SpawningPool": "spawning-pool", "Extractor": "extractor", "RoachWarren": "roach-warren",
    "BanelingNest": "baneling-nest", "HydraliskDen": "hydralisk-den", "LurkerDenMP": "lurker-den",
    "Spire": "spire", "GreaterSpire": "greater-spire", "InfestationPit": "infestation-pit",
    "UltraliskCavern": "ultralisk-cavern", "EvolutionChamber": "evolution-chamber",
    "SpineCrawler": "spine-crawler", "SpineCrawlerUprooted": "spine-crawler",
    "SporeCrawler": "spore-crawler", "SporeCrawlerUprooted": "spore-crawler",
    "SCV": "scv", "Marine": "marine", "Marauder": "marauder", "Reaper": "reaper",
    "Ghost": "ghost", "Hellion": "hellion", "HellionTank": "hellbat",
    "WidowMine": "widow-mine", "WidowMineBurrowed": "widow-mine", "Cyclone": "cyclone",
    "SiegeTank": "siege-tank", "SiegeTankSieged": "siege-tank", "Thor": "thor",
    "ThorAP": "thor", "VikingFighter": "viking", "VikingAssault": "viking",
    "Medivac": "medivac", "Liberator": "liberator", "LiberatorAG": "liberator",
    "Banshee": "banshee", "Raven": "raven", "Battlecruiser": "battlecruiser",
    "CommandCenter": "command-center", "CommandCenterFlying": "command-center",
    "OrbitalCommand": "orbital-command", "OrbitalCommandFlying": "orbital-command",
    "PlanetaryFortress": "planetary-fortress", "SupplyDepot": "supply-depot",
    "SupplyDepotLowered": "supply-depot", "Refinery": "refinery",
    "Barracks": "barracks", "BarracksFlying": "barracks",
    "BarracksTechLab": "barracks-techlab", "BarracksReactor": "barracks-reactor",
    "Factory": "factory", "FactoryFlying": "factory",
    "FactoryTechLab": "factory-techlab", "FactoryReactor": "factory-reactor",
    "Starport": "starport", "StarportFlying": "starport",
    "StarportTechLab": "starport-techlab", "StarportReactor": "starport-reactor",
    "EngineeringBay": "engineering-bay", "Armory": "armory", "FusionCore": "fusion-core",
    "GhostAcademy": "ghost-academy", "Bunker": "bunker", "MissileTurret": "missile-turret",
    "SensorTower": "sensor-tower",
    "Probe": "probe", "Zealot": "zealot", "Stalker": "stalker", "Sentry": "sentry",
    "Adept": "adept", "HighTemplar": "high-templar", "DarkTemplar": "dark-templar",
    "Archon": "archon", "Observer": "observer", "ObserverSiegeMode": "observer",
    "WarpPrism": "warp-prism", "WarpPrismPhasing": "warp-prism",
    "Immortal": "immortal", "Colossus": "colossus", "Disruptor": "disruptor",
    "Phoenix": "phoenix", "VoidRay": "void-ray", "Oracle": "oracle",
    "Tempest": "tempest", "Carrier": "carrier", "Mothership": "mothership",
    "Nexus": "nexus", "Pylon": "pylon", "Assimilator": "assimilator",
    "Gateway": "gateway", "WarpGate": "warpgate", "Forge": "forge",
    "CyberneticsCore": "cybernetics-core", "PhotonCannon": "photon-cannon",
    "ShieldBattery": "shield-battery", "TwilightCouncil": "twilight-council",
    "Stargate": "stargate", "RoboticsFacility": "robotics-facility",
    "RoboticsBay": "robotics-bay", "FleetBeacon": "fleet-beacon",
    "TemplarArchive": "templar-archive", "DarkShrine": "dark-shrine",
}

UPGRADE_TO_KEBAB = {
    "zerglingmovementspeed": "metabolic-boost",
    "zerglingattackspeed": "zergling-attackspeed",
    "glialreconstitution": "glial-reconstitution",
    "tunnelingclaws": "tunneling-claws",
    "centrificalhooks": "centrifical-hooks",
    "evolvemuscularaugments": "grooved-spines",
    "evolvegroovedspines": "grooved-spines",
    "burrow": "burrow",
    "overlordspeed": "pneumatized-carapace",
    "chitinousplating": "chitinous-plating",
    "anabolicsynthesis": "anabolic-synthesis",
    "zergmeleeweaponslevel1": "zerg-melee-weapons-1",
    "zergmissileweaponslevel1": "zerg-missile-weapons-1",
    "zerggroundarmorslevel1": "zerg-ground-armor-1",
    "stimpack": "stimpack",
    "shieldwall": "combat-shield",
    "punishergrenades": "concussive-shells",
    "terraninfantryweaponslevel1": "terran-infantry-weapons-1",
    "terraninfantryarmorslevel1": "terran-infantry-armor-1",
    "terranvehicleweaponslevel1": "terran-vehicle-weapons-1",
    "terranshipweaponslevel1": "terran-ship-weapons-1",
    "drillclaws": "drilling-claws",
    "cyclonehiprotect": "mag-field-accelerator",
    "personalcloaking": "personal-cloaking",
    "warpgateresearch": "warp-gate-research",
    "charge": "charge",
    "blinktech": "blink",
    "adeptpiercingattack": "resonating-glaives",
    "extendedthermallance": "extended-thermal-lance",
    "psistormtech": "psi-storm",
    "protossgroundweaponslevel1": "protoss-ground-weapons-1",
    "protossgroundarmorslevel1": "protoss-ground-armor-1",
    "protossairweaponslevel1": "protoss-air-weapons-1",
}

BLDG_SYMS = {
    "hatchery", "lair", "hive", "spawning-pool", "extractor", "roach-warren",
    "baneling-nest", "hydralisk-den", "lurker-den", "spire", "greater-spire",
    "infestation-pit", "ultralisk-cavern", "evolution-chamber", "spine-crawler",
    "spore-crawler",
    "command-center", "orbital-command", "planetary-fortress", "supply-depot",
    "refinery", "barracks", "barracks-techlab", "barracks-reactor",
    "factory", "factory-techlab", "factory-reactor", "starport",
    "starport-techlab", "starport-reactor", "engineering-bay", "armory",
    "fusion-core", "ghost-academy", "bunker", "missile-turret", "sensor-tower",
    "nexus", "pylon", "assimilator", "gateway", "warpgate", "forge",
    "cybernetics-core", "photon-cannon", "shield-battery", "twilight-council",
    "stargate", "robotics-facility", "robotics-bay", "fleet-beacon",
    "templar-archive", "dark-shrine",
}

IGNORE_RAW_SUBSTR = (
    "MineralField", "VespeneGeyser", "SpacePlatformGeyser", "RichMineralField",
    "PurifierMineralField", "LabMineralField", "BattleStationMineralField",
    "Unbuildable", "Destructible", "XelNagaTower", "Beacon", "Larva", "Egg",
    "Broodling", "KD8Charge", "AdeptPhaseShift", "Interceptor", "MULE",
    "CreepTumor", "ParasiticBombDummy", "OracleStasisTrap", "AutoTurret",
    "LocustMP", "Changeling",
)

TOWNHALL_SYMS = {
    "hatchery", "lair", "hive",
    "command-center", "orbital-command", "planetary-fortress",
    "nexus",
}

SUPPLY_PROVIDER_SYMS = {"overlord", "supply-depot", "pylon"}
WORKER_SYMS = {"drone", "scv", "probe"}
AI_NAME_PATTERNS = ("A.I.", "Computer", "Local Player", "NULL")


def normalize_race(raw_bytes) -> str:
    r = raw_bytes.decode("utf-8", errors="ignore") if isinstance(raw_bytes, bytes) else str(raw_bytes)
    if "테란" in r or "人类" in r or "Terran" in r:
        return "Terran"
    if "저그" in r or "异虫" in r or "Zerg" in r:
        return "Zerg"
    if "프로토스" in r or "星灵" in r or "Protoss" in r:
        return "Protoss"
    return "Unknown"


def to_sym(raw_utype: str):
    for bad in IGNORE_RAW_SUBSTR:
        if bad in raw_utype:
            return None
    if raw_utype in CAMEL_TO_KEBAB:
        return CAMEL_TO_KEBAB[raw_utype]
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", raw_utype).lower()
    s = re.sub(r"[^a-z0-9\-]", "", s)
    return s if s else None


def to_upg_sym(raw_upg: str):
    key = re.sub(r"[^a-z0-9]", "", raw_upg.lower())
    return UPGRADE_TO_KEBAB.get(key)


def parse_single_pro_replay(path: str):
    try:
        mpq = read_mpq_files(path)
        if not mpq or "replay.details" not in mpq or "replay.tracker.events" not in mpq:
            return []
        details, _ = decode_versioned(mpq["replay.details"], 0)
        plist = details.get(0, [])
        if not isinstance(plist, list) or len(plist) < 2:
            return []
        events = decode_tracker_stream(mpq["replay.tracker.events"])
    except Exception:
        return []

    # Map slot_id -> tracker player_id via SPlayerSetupEvent (ev_id == 9)
    slot_to_pid = {}
    for gl, ev_id, payload in events:
        if gl > 0:
            break
        if ev_id == 9 and isinstance(payload, dict):
            pid = payload.get(0, 0)
            ptype = payload.get(1, 0)  # 1 = human, 2 = computer
            slot = payload.get(3)
            if ptype in (1, 2) and slot is not None and slot < len(plist):
                slot_to_pid[slot] = pid

    # Detect race & Frame-0 worker count directly from Frame-0 SUnitBornEvent (handles Cyrillic/localized m_race!)
    f0_workers = {}
    f0_race = {}
    for gl, ev_id, payload in events:
        if gl > 0:
            break
        if ev_id == 1 and isinstance(payload, dict):
            ut_raw = payload.get(2, b"")
            ut = ut_raw.decode("utf-8", errors="ignore") if isinstance(ut_raw, bytes) else str(ut_raw)
            cp = payload.get(3, 0)
            if cp > 0:
                if ut in ("Drone", "Hatchery"):
                    f0_race[cp] = "Zerg"
                elif ut in ("SCV", "CommandCenter"):
                    f0_race[cp] = "Terran"
                elif ut in ("Probe", "Nexus"):
                    f0_race[cp] = "Protoss"
                if ut in ("Drone", "SCV", "Probe"):
                    f0_workers[cp] = f0_workers.get(cp, 0) + 1

    players = {}
    for slot_idx, p in enumerate(plist):
        if len(players) >= 2:
            break
        pid = slot_to_pid.get(slot_idx, slot_idx + 1)
        raw_name = p.get(0, b"")
        name = raw_name.decode("utf-8", errors="ignore") if isinstance(raw_name, bytes) else str(raw_name)
        name = re.sub(r"<[^>]+>", "", name).replace("&lt;", "<").replace("&gt;", ">").replace("<sp/>", " ")
        name = re.sub(r"<[^>]+>", "", name).strip()
        if not name:
            name = f"Player{slot_idx + 1}"
        race = normalize_race(p.get(2, b""))
        if race == "Unknown":
            race = f0_race.get(pid, "Unknown")
        if race == "Unknown":
            continue
        players[pid] = {"name": name, "race": race}

    if len(players) != 2:
        return []
    pids = sorted(players.keys())
    p1_id, p2_id = pids[0], pids[1]
    opp_of = {p1_id: p2_id, p2_id: p1_id}
    if f0_workers.get(p1_id, 0) < 6 or f0_workers.get(p2_id, 0) < 6:
        return []

    # Pre-collect future 15s (336 gameloops) actions initiated by each player:
    # ev_id 6 = SUnitInitEvent, 1 = SUnitBornEvent, 4 = SUnitTypeChangeEvent, 5 = SUpgradeEvent
    init_tags = set()
    tag_owner = {}
    future_actions = {p1_id: [], p2_id: []}
    morph_events = []

    for gl, ev_id, payload in events:
        if not isinstance(payload, dict):
            continue
        if ev_id in (1, 6):
            tag = (payload.get(0, 0) << 18) | payload.get(1, 0)
            cp = payload.get(3, 0)
            if cp in future_actions:
                tag_owner[tag] = cp
            if gl == 0:
                continue
            ut_raw = payload.get(2, b"")
            ut = ut_raw.decode("utf-8", errors="ignore") if isinstance(ut_raw, bytes) else str(ut_raw)
            sym = to_sym(ut)
            if ev_id == 6:  # SUnitInitEvent (structure build started at exact gl!)
                init_tags.add(tag)
                if cp in future_actions and sym:
                    future_actions[cp].append((gl, sym))
            elif ev_id == 1 and tag not in init_tags:  # SUnitBornEvent (unit trained)
                if cp in future_actions and sym and sym not in BLDG_SYMS:
                    start_gl = max(1, gl - 270)
                    future_actions[cp].append((start_gl, sym))
        elif ev_id == 4 and gl > 0:  # SUnitTypeChangeEvent
            ut_raw = payload.get(2, b"")
            ut = ut_raw.decode("utf-8", errors="ignore") if isinstance(ut_raw, bytes) else str(ut_raw)
            if ut in (
                "Lair", "Hive", "OrbitalCommand", "PlanetaryFortress", "GreaterSpire",
                "BanelingCocoon", "RavagerCocoon", "LurkerMPCocoon", "BroodLordCocoon", "OverseerCocoon",
            ):
                tag = (payload.get(0, 0) << 18) | payload.get(1, 0)
                morph_events.append((gl, tag, to_sym(ut)))
        elif ev_id == 5 and gl > 0:  # SUpgradeEvent
            cp = payload.get(0, 0)
            upg_raw = payload.get(1, b"")
            upg = upg_raw.decode("utf-8", errors="ignore") if isinstance(upg_raw, bytes) else str(upg_raw)
            usym = to_upg_sym(upg)
            if cp in future_actions and usym:
                future_actions[cp].append((max(1, gl - 900), usym))

    for gl, tag, sym in morph_events:
        cp = tag_owner.get(tag)
        if cp in future_actions and sym:
            start_gl = gl if "Cocoon" not in str(sym) else gl
            future_actions[cp].append((max(1, start_gl - 320), sym))

    for cp in future_actions:
        future_actions[cp].sort(key=lambda x: x[0])

    # Replay simulation across checkpoints
    checkpoints = [1008, 1344, 2016, 2688, 3360, 4032, 4704, 5376, 6720, 8064, 9408]
    cp_idx = 0
    units = {}
    alive = {p1_id: set(), p2_id: set()}
    researched = {p1_id: [], p2_id: []}
    stats = {p1_id: {}, p2_id: {}}
    records = []
    short_id = os.path.basename(path)

    for gl, ev_id, payload in events:
        while cp_idx < len(checkpoints) and gl >= checkpoints[cp_idx]:
            cp_gl = checkpoints[cp_idx]
            for idx_p, p in enumerate((p1_id, p2_id), start=1):
                opp = opp_of[p]
                our_u = [units[t] for t in alive[p] if t in units]
                opp_u = [units[t] for t in alive[opp] if t in units]
                if not our_u or not opp_u:
                    continue
                st = stats[p]
                if not st:
                    continue
                minerals = int(st.get(0, 0))
                gas = int(st.get(1, 0))
                sup_used = int(round(st.get(29, 0) / 4096.0))
                sup_made = min(200, int(round(st.get(30, 0) / 4096.0)))

                ready_b = {}
                total_b = {}
                uc = {}
                pending_sup = 0
                workers = 0
                bases = 0
                for u in our_u:
                    s = u["sym"]
                    if not s:
                        continue
                    if s in BLDG_SYMS:
                        total_b[s] = total_b.get(s, 0) + 1
                        if u["ready"]:
                            ready_b[s] = ready_b.get(s, 0) + 1
                            if s in TOWNHALL_SYMS:
                                bases += 1
                        else:
                            if s in ("supply-depot", "pylon"):
                                pending_sup += 8
                            elif s == "hatchery":
                                pending_sup += 6
                            elif s in ("command-center", "nexus"):
                                pending_sup += 15
                    else:
                        uc[s] = uc.get(s, 0) + 1
                        if s in WORKER_SYMS:
                            workers += 1

                if bases == 0 or workers == 0:
                    continue
                if sup_made == 0:
                    sup_made = min(
                        200,
                        bases * (6 if players[p]["race"] == "Zerg" else 15)
                        + uc.get("overlord", 0) * 8
                        + ready_b.get("supply-depot", 0) * 8
                        + ready_b.get("pylon", 0) * 8,
                    )
                if sup_used == 0:
                    sup_used = workers

                our_bx = [u["x"] for u in our_u if u["sym"] in TOWNHALL_SYMS] or [32.0]
                our_by = [u["y"] for u in our_u if u["sym"] in TOWNHALL_SYMS] or [32.0]
                threat_sup = 0
                for eu in opp_u:
                    es = eu["sym"]
                    if es and es not in BLDG_SYMS and es not in WORKER_SYMS and es not in ("overlord", "overseer", "observer"):
                        if any((eu["x"] - bx) ** 2 + (eu["y"] - by) ** 2 <= 38.0 ** 2 for bx, by in zip(our_bx, our_by)):
                            threat_sup += 2

                fut15 = []
                seen_f = set()
                for f_gl, f_sym in future_actions[p]:
                    if cp_gl <= f_gl <= cp_gl + 336:
                        if f_sym not in seen_f:
                            seen_f.add(f_sym)
                            fut15.append(f_sym)
                if not fut15:
                    continue

                rb_sexp = " ".join(f"({k} {v})" for k, v in sorted(ready_b.items()))
                tb_sexp = " ".join(f"({k} {v})" for k, v in sorted(total_b.items()))
                uc_sexp = " ".join(f"({k} {v})" for k, v in sorted(uc.items()))
                upg_sexp = " ".join(researched[p])
                f15_sexp = " ".join(fut15)

                records.append(
                    f'(pro-cp "{short_id}" {idx_p} {players[p]["race"]} {players[opp]["race"]} '
                    f"{cp_gl} {minerals} {gas} {sup_used} {sup_made} {pending_sup} {workers} {bases} {threat_sup} "
                    f"({rb_sexp}) ({tb_sexp}) ({uc_sexp}) ({upg_sexp}) ({f15_sexp}))"
                )
            cp_idx += 1

        if not isinstance(payload, dict):
            continue
        if ev_id == 1:  # SUnitBornEvent
            cp = payload.get(3, 0)
            if cp in alive:
                tag = (payload.get(0, 0) << 18) | payload.get(1, 0)
                ut_raw = payload.get(2, b"")
                ut = ut_raw.decode("utf-8", errors="ignore") if isinstance(ut_raw, bytes) else str(ut_raw)
                units[tag] = {"sym": to_sym(ut), "x": float(payload.get(5, 0)), "y": float(payload.get(6, 0)), "ready": True, "p": cp}
                alive[cp].add(tag)
        elif ev_id == 6:  # SUnitInitEvent
            cp = payload.get(3, 0)
            if cp in alive:
                tag = (payload.get(0, 0) << 18) | payload.get(1, 0)
                ut_raw = payload.get(2, b"")
                ut = ut_raw.decode("utf-8", errors="ignore") if isinstance(ut_raw, bytes) else str(ut_raw)
                units[tag] = {"sym": to_sym(ut), "x": float(payload.get(5, 0)), "y": float(payload.get(6, 0)), "ready": False, "p": cp}
                alive[cp].add(tag)
        elif ev_id == 7:  # SUnitDoneEvent
            tag = (payload.get(0, 0) << 18) | payload.get(1, 0)
            if tag in units:
                units[tag]["ready"] = True
        elif ev_id == 4:  # SUnitTypeChangeEvent
            tag = (payload.get(0, 0) << 18) | payload.get(1, 0)
            if tag in units:
                ut_raw = payload.get(2, b"")
                ut = ut_raw.decode("utf-8", errors="ignore") if isinstance(ut_raw, bytes) else str(ut_raw)
                ns = to_sym(ut)
                if ns:
                    units[tag]["sym"] = ns
                    units[tag]["ready"] = True
        elif ev_id == 2:  # SUnitDiedEvent
            tag = (payload.get(0, 0) << 18) | payload.get(1, 0)
            if tag in units:
                alive[units[tag]["p"]].discard(tag)
        elif ev_id == 5:  # SUpgradeEvent
            cp = payload.get(0, 0)
            upg_raw = payload.get(1, b"")
            upg = upg_raw.decode("utf-8", errors="ignore") if isinstance(upg_raw, bytes) else str(upg_raw)
            usym = to_upg_sym(upg)
            if cp in researched and usym and usym not in researched[cp]:
                researched[cp].append(usym)
        elif ev_id == 0:  # SPlayerStatsEvent
            cp = payload.get(0, 0)
            if cp in stats and isinstance(payload.get(1), dict):
                stats[cp] = payload[1]

    return records


def collect_unique_pro_replays():
    patterns = [
        "external_bots/python-sc2/test/replays/*.SC2Replay",
        "replays/pro_corpus/**/*.SC2Replay",
        "replays/pro_corpus/*.SC2Replay",
        "replays/*.SC2Replay",
    ]
    seen = set()
    paths = []
    for pat in patterns:
        for p in sorted(glob.glob(pat, recursive=True)):
            try:
                sz = os.path.getsize(p)
                if sz < 1000:
                    continue
                with open(p, "rb") as fh:
                    h = hashlib.md5(fh.read(65536)).hexdigest()
                if (sz, h) not in seen:
                    seen.add((sz, h))
                    paths.append(p)
            except Exception:
                continue
    return paths


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--single":
        recs = parse_single_pro_replay(sys.argv[2])
        print(f"Single replay records: {len(recs)}")
        for r in recs[:5]:
            print(" ", r)
        return

    paths = collect_unique_pro_replays()
    out_path = "data/pro_starvation_checkpoints.sexp"
    all_recs = []
    valid_replays = 0
    with mp.Pool(processes=min(16, max(1, mp.cpu_count()))) as pool:
        for recs in pool.imap(parse_single_pro_replay, paths, chunksize=16):
            if recs:
                valid_replays += 1
                all_recs.extend(recs)

    os.makedirs("data", exist_ok=True)
    with open(out_path, "w") as out_f:
        out_f.write(
            f";; Auto-unpacked from {valid_replays} unique pro .SC2Replay trajectories ({len(all_recs)} checkpoints)\n"
        )
        for r in all_recs:
            out_f.write(r + "\n")
    print(f"Unpacked {len(all_recs)} pro checkpoints from {valid_replays} valid LotV 1v1 pro replays (out of {len(paths)} unique archives) -> {out_path}")


if __name__ == "__main__":
    main()
