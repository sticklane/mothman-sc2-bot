#!/usr/bin/env python3
"""
Full Replay Corpus Upgrades, Terran Add-On Swapping & Expansion/Depletion Evaluator
(`tools/evaluate-full-corpus-upgrades-and-addon-swaps.py`).

Scans all `.SC2Replay` archives across the workspace corpus (`1,888` unique archives,
`1,649` valid 2-player replays) using `multiprocessing.Pool(16)` to extract:
  1. Pro vs. Bot Upgrade Paths & Timings (`median_sec`, `p25_sec`, `p75_sec`, `count`)
     across all Zerg, Terran, and Protoss combat/tech upgrades, plus simultaneous
     `+1/+1`, `+2/+2`, `+3/+3` pair rates and upgrade-advantage win rates.
  2. Terran Building Lift-Off & Add-On Swapping (`Barracks` <-> `Factory` <-> `Starport`
     swapping onto `TechLab` / `Reactor` add-ons via `SUnitTypeChangeEvent` `*Flying`,
     spatial `(bx + 2.5, by - 0.5)` add-on attachment, and `SCmdEvent` Lift/Land).
  3. Expansion Timings & Resource-Depletion / Gas-Float Ledger across races (`2nd`, `3rd`,
     `4th`, `5th` TownHall timings, pre-depletion expansion lead times, and gas-float rates).
"""

import glob
import hashlib
import json
import math
import multiprocessing as mp
import os
import statistics
from collections import Counter, defaultdict

import mpyq
from s2protocol import versions

TOWNHALL_RAW = {
    "Nexus",
    "CommandCenter",
    "OrbitalCommand",
    "PlanetaryFortress",
    "Hatchery",
    "Lair",
    "Hive",
}
TERRAN_PROD_LANDED = {"Barracks", "Factory", "Starport"}
TERRAN_PROD_FLYING = {"BarracksFlying", "FactoryFlying", "StarportFlying"}
TERRAN_ADDON_TYPES = {
    "TechLab",
    "Reactor",
    "BarracksTechLab",
    "BarracksReactor",
    "FactoryTechLab",
    "FactoryReactor",
    "StarportTechLab",
    "StarportReactor",
}

CANONICAL_UPGRADES_BY_RACE = {
    "Zerg": [
        "zerglingmovementspeed",
        "zerglingattackspeed",
        "GlialReconstitution",
        "TunnelingClaws",
        "CentrifugalHooks",
        "EvolveGroovedSpines",
        "EvolveMuscularAugments",
        "Burrow",
        "overlordspeed",
        "ChitinousPlating",
        "AnabolicSynthesis",
        "DiggingClaws",
        "LurkerRange",
        "NeuralParasite",
        "InfestorEnergyUpgrade",
        "ZergMeleeWeaponsLevel1",
        "ZergMeleeWeaponsLevel2",
        "ZergMeleeWeaponsLevel3",
        "ZergMissileWeaponsLevel1",
        "ZergMissileWeaponsLevel2",
        "ZergMissileWeaponsLevel3",
        "ZergGroundArmorsLevel1",
        "ZergGroundArmorsLevel2",
        "ZergGroundArmorsLevel3",
        "ZergFlyerWeaponsLevel1",
        "ZergFlyerWeaponsLevel2",
        "ZergFlyerWeaponsLevel3",
        "ZergFlyerArmorsLevel1",
        "ZergFlyerArmorsLevel2",
        "ZergFlyerArmorsLevel3",
    ],
    "Terran": [
        "Stimpack",
        "ShieldWall",
        "PunisherGrenades",
        "TerranInfantryWeaponsLevel1",
        "TerranInfantryWeaponsLevel2",
        "TerranInfantryWeaponsLevel3",
        "TerranInfantryArmorsLevel1",
        "TerranInfantryArmorsLevel2",
        "TerranInfantryArmorsLevel3",
        "TerranVehicleWeaponsLevel1",
        "TerranVehicleWeaponsLevel2",
        "TerranVehicleWeaponsLevel3",
        "TerranShipWeaponsLevel1",
        "TerranShipWeaponsLevel2",
        "TerranShipWeaponsLevel3",
        "TerranVehicleAndShipArmorsLevel1",
        "TerranVehicleAndShipArmorsLevel2",
        "TerranVehicleAndShipArmorsLevel3",
        "DrillClaws",
        "BansheeCloak",
        "HyperflightRotors",
        "PersonalCloaking",
        "InterferenceMatrix",
        "CycloneLockOnDamageUpgrade",
        "SmartServos",
        "HiSecAutoTracking",
        "TerranBuildingArmor",
    ],
    "Protoss": [
        "WarpGateResearch",
        "Charge",
        "BlinkTech",
        "AdeptPiercingAttack",
        "ExtendedThermalLance",
        "PsiStormTech",
        "DarkTemplarBlinkUpgrade",
        "ObserverGraviticBooster",
        "GraviticDrive",
        "AnionPulseCrystals",
        "ProtossGroundWeaponsLevel1",
        "ProtossGroundWeaponsLevel2",
        "ProtossGroundWeaponsLevel3",
        "ProtossGroundArmorsLevel1",
        "ProtossGroundArmorsLevel2",
        "ProtossGroundArmorsLevel3",
        "ProtossShieldsLevel1",
        "ProtossShieldsLevel2",
        "ProtossShieldsLevel3",
        "ProtossAirWeaponsLevel1",
        "ProtossAirWeaponsLevel2",
        "ProtossAirWeaponsLevel3",
        "ProtossAirArmorsLevel1",
        "ProtossAirArmorsLevel2",
        "ProtossAirArmorsLevel3",
    ],
}

WEAPON_ARMOR_UPGRADES = {
    "ZergMeleeWeaponsLevel1",
    "ZergMeleeWeaponsLevel2",
    "ZergMeleeWeaponsLevel3",
    "ZergMissileWeaponsLevel1",
    "ZergMissileWeaponsLevel2",
    "ZergMissileWeaponsLevel3",
    "ZergGroundArmorsLevel1",
    "ZergGroundArmorsLevel2",
    "ZergGroundArmorsLevel3",
    "ZergFlyerWeaponsLevel1",
    "ZergFlyerWeaponsLevel2",
    "ZergFlyerWeaponsLevel3",
    "ZergFlyerArmorsLevel1",
    "ZergFlyerArmorsLevel2",
    "ZergFlyerArmorsLevel3",
    "TerranInfantryWeaponsLevel1",
    "TerranInfantryWeaponsLevel2",
    "TerranInfantryWeaponsLevel3",
    "TerranInfantryArmorsLevel1",
    "TerranInfantryArmorsLevel2",
    "TerranInfantryArmorsLevel3",
    "TerranVehicleWeaponsLevel1",
    "TerranVehicleWeaponsLevel2",
    "TerranVehicleWeaponsLevel3",
    "TerranShipWeaponsLevel1",
    "TerranShipWeaponsLevel2",
    "TerranShipWeaponsLevel3",
    "TerranVehicleAndShipArmorsLevel1",
    "TerranVehicleAndShipArmorsLevel2",
    "TerranVehicleAndShipArmorsLevel3",
    "ProtossGroundWeaponsLevel1",
    "ProtossGroundWeaponsLevel2",
    "ProtossGroundWeaponsLevel3",
    "ProtossGroundArmorsLevel1",
    "ProtossGroundArmorsLevel2",
    "ProtossGroundArmorsLevel3",
    "ProtossShieldsLevel1",
    "ProtossShieldsLevel2",
    "ProtossShieldsLevel3",
    "ProtossAirWeaponsLevel1",
    "ProtossAirWeaponsLevel2",
    "ProtossAirWeaponsLevel3",
    "ProtossAirArmorsLevel1",
    "ProtossAirArmorsLevel2",
    "ProtossAirArmorsLevel3",
}


def collect_all_replays():
    patterns = [
        ("pro_tournament", "external_bots/python-sc2/test/replays/*.SC2Replay"),
        ("pro_corpus", "replays/pro_corpus/**/*.SC2Replay"),
        ("pro_corpus", "replays/pro_corpus/*.SC2Replay"),
        ("aiarena_ladder", "replays/aiarena_matches/*.SC2Replay"),
        ("aiarena_ladder", "replays/aiarena_matches/**/*.SC2Replay"),
        ("aiarena_ladder", "data/aiarena_latest/**/*.SC2Replay"),
        ("aiarena_ladder", "replays/aiarena_corpus/**/*.SC2Replay"),
        ("aiarena_ladder", "replays/aiarena_corpus/*.SC2Replay"),
        ("local_real_matches", "replays/local_real_matches/**/*.SC2Replay"),
        ("local_real_matches", "replays/*.SC2Replay"),
        ("external_gauntlet", "replays/external_gauntlet/*.SC2Replay"),
        ("external_gauntlet", "replays/external_bots_gauntlet/*.SC2Replay"),
    ]
    seen_hashes = set()
    items = []
    raw_file_count = 0
    for cohort, pat in patterns:
        for p in sorted(glob.glob(pat, recursive=True)):
            try:
                sz = os.path.getsize(p)
                if sz < 1000:
                    continue
                raw_file_count += 1
                with open(p, "rb") as fh:
                    h = hashlib.md5(fh.read()).hexdigest()
                key = (sz, h)
                if key not in seen_hashes:
                    seen_hashes.add(key)
                    items.append((cohort, p))
            except Exception:
                continue
    return items, raw_file_count


def decode_str(val):
    if isinstance(val, bytes):
        return val.decode("utf-8", errors="ignore")
    return str(val or "")


def normalize_race(raw_r):
    r = decode_str(raw_r)
    if "테란" in r or "人类" in r or "Terran" in r:
        return "Terran"
    if "저그" in r or "异虫" in r or "Zerg" in r:
        return "Zerg"
    if "프로토스" in r or "星灵" in r or "Protoss" in r:
        return "Protoss"
    return "Terran"


def base_prod_kind(utype):
    if "Barracks" in utype:
        return "Barracks"
    if "Factory" in utype:
        return "Factory"
    if "Starport" in utype:
        return "Starport"
    return None


def scan_single_replay(item):
    cohort, path = item
    res = {
        "cohort": cohort,
        "path": path,
        "valid": False,
        "p1_race": "Unknown",
        "p2_race": "Unknown",
        "winner": 0,
        "upgrades": [],  # list of (race, upg_name, sec)
        "double_plus1_parallel_events": 0,
        "plus2_transitions": 0,
        "plus3_transitions": 0,
        "upg_lead_wins": 0,
        "upg_lead_total": 0,
        "terran_perspectives": 0,
        "addons_built": {},
        "liftoff_events": {"Barracks": 0, "Factory": 0, "Starport": 0},
        "addon_swap_events": 0,
        "swap_pairs": {
            "Barracks->Factory": 0,
            "Barracks->Starport": 0,
            "Factory->Starport": 0,
            "Starport->Factory": 0,
            "Factory->Barracks": 0,
            "Starport->Barracks": 0,
            "SameKind": 0,
        },
        "first_swap_sec": None,
        "expansion_timings": [],  # list of (race, base_index_2_to_5, sec)
        "pre_depletion_expansions": 0,
        "depletion_events": 0,
        "gas_float_events": 0,
    }
    try:
        archive = mpyq.MPQArchive(path)
        header = versions.latest().decode_replay_header(
            archive.header["user_data_header"]["content"]
        )
        protocol = versions.build(header["m_version"]["m_baseBuild"])
        details = protocol.decode_replay_details(archive.read_file("replay.details"))
        tracker = list(
            protocol.decode_replay_tracker_events(
                archive.read_file("replay.tracker.events")
            )
        )
    except Exception:
        return res

    if not details or len(details.get("m_playerList", [])) < 2:
        return res

    res["valid"] = True
    races = {}
    winner = 0
    for idx, p in enumerate(details["m_playerList"][:2]):
        pid = idx + 1
        races[pid] = normalize_race(p.get("m_race"))
        if p.get("m_result") == 1:
            winner = pid
    res["p1_race"] = races.get(1, "Terran")
    res["p2_race"] = races.get(2, "Terran")
    res["winner"] = winner
    res["terran_perspectives"] = sum(1 for r in races.values() if r == "Terran")

    p_upgrades = {1: [], 2: []}
    p_weap_arm = {1: [], 2: []}
    p_townhalls = {1: [], 2: []}
    prod_units = {}  # tag -> {p, kind, x, y, flying, born}
    addons = {}  # tag -> {p, utype, x, y, builder_kind, attached_tag}
    p_collection = {1: 0, 2: 0}

    for ev in tracker:
        gl = ev.get("_gameloop", 0)
        sec = round(gl / 22.4, 2)
        etype = ev.get("_event")

        if etype == "NNet.Replay.Tracker.SUpgradeEvent":
            p = ev.get("m_playerId", 0)
            upg = decode_str(ev.get("m_upgradeTypeName"))
            if p in (1, 2) and upg and not upg.startswith("Spray"):
                r = races.get(p, "Terran")
                res["upgrades"].append((r, upg, sec))
                p_upgrades[p].append((upg, sec))
                if upg in WEAPON_ARMOR_UPGRADES:
                    p_weap_arm[p].append((upg, sec))
                    if upg.endswith("Level2"):
                        res["plus2_transitions"] += 1
                    elif upg.endswith("Level3"):
                        res["plus3_transitions"] += 1

        elif etype in (
            "NNet.Replay.Tracker.SUnitInitEvent",
            "NNet.Replay.Tracker.SUnitBornEvent",
        ):
            tag = ev.get("m_unitTagIndex", 0)
            p = ev.get("m_controlPlayerId", 0)
            utype = decode_str(ev.get("m_unitTypeName"))
            x = float(ev.get("m_x", 0))
            y = float(ev.get("m_y", 0))
            if p not in (1, 2):
                continue

            if utype in TOWNHALL_RAW and gl > 10:
                if etype == "NNet.Replay.Tracker.SUnitInitEvent" or (
                    etype == "NNet.Replay.Tracker.SUnitBornEvent"
                    and utype in ("Hatchery", "Nexus", "CommandCenter")
                    and not any(
                        math.hypot(x - ox, y - oy) < 4.0
                        for (ox, oy, _) in p_townhalls[p]
                    )
                ):
                    p_townhalls[p].append((x, y, sec))
                    b_idx = len(p_townhalls[p]) + 1  # 2nd base = 2, 3rd = 3, etc.
                    if 2 <= b_idx <= 5:
                        res["expansion_timings"].append((races[p], b_idx, sec))
                    # Check if an older base has mined >= 7000 minerals (~pre-depletion)
                    if b_idx >= 3 and p_collection[p] >= (b_idx - 2) * 6500:
                        res["pre_depletion_expansions"] += 1

            elif utype in TERRAN_PROD_LANDED or utype in TERRAN_PROD_FLYING:
                kind = base_prod_kind(utype)
                prod_units[tag] = {
                    "p": p,
                    "kind": kind,
                    "x": x,
                    "y": y,
                    "flying": utype in TERRAN_PROD_FLYING,
                    "lifted_once": utype in TERRAN_PROD_FLYING,
                }

            elif utype in TERRAN_ADDON_TYPES:
                res["addons_built"][utype] = res["addons_built"].get(utype, 0) + 1
                # Find attached parent facility at (bx + 2.5, by - 0.5) ~ distance <= 4.0
                builder_kind = base_prod_kind(utype)
                builder_tag = None
                for ftag, finfo in prod_units.items():
                    if finfo["p"] == p and math.hypot(x - finfo["x"], y - finfo["y"]) <= 4.2:
                        builder_kind = finfo["kind"]
                        builder_tag = ftag
                        break
                addons[tag] = {
                    "p": p,
                    "utype": utype,
                    "x": x,
                    "y": y,
                    "builder_kind": builder_kind or "Barracks",
                    "builder_tag": builder_tag,
                    "swapped": False,
                }

        elif etype == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
            tag = ev.get("m_unitTagIndex", 0)
            utype = decode_str(ev.get("m_unitTypeName"))
            if tag in prod_units:
                finfo = prod_units[tag]
                p = finfo["p"]
                if utype in TERRAN_PROD_FLYING:
                    finfo["flying"] = True
                    finfo["lifted_once"] = True
                    k = finfo["kind"]
                    if k in res["liftoff_events"]:
                        res["liftoff_events"][k] += 1
                elif utype in TERRAN_PROD_LANDED:
                    was_flying = finfo["flying"]
                    finfo["flying"] = False
                    if was_flying:
                        # Check if landed next to an existing add-on (or swapped add-ons)
                        for atag, ainfo in addons.items():
                            if ainfo["p"] == p and (
                                ainfo["builder_tag"] != tag
                                or ainfo["builder_kind"] != finfo["kind"]
                            ):
                                if (
                                    math.hypot(
                                        finfo["x"] - ainfo["x"],
                                        finfo["y"] - ainfo["y"],
                                    )
                                    <= 6.5
                                    or ainfo["builder_kind"] != finfo["kind"]
                                ):
                                    res["addon_swap_events"] += 1
                                    pair_key = f"{ainfo['builder_kind']}->{finfo['kind']}"
                                    if pair_key not in res["swap_pairs"]:
                                        pair_key = "SameKind"
                                    res["swap_pairs"][pair_key] = (
                                        res["swap_pairs"].get(pair_key, 0) + 1
                                    )
                                    ainfo["builder_tag"] = tag
                                    ainfo["builder_kind"] = finfo["kind"]
                                    if res["first_swap_sec"] is None:
                                        res["first_swap_sec"] = sec
                                    break
            else:
                # Check if an add-on changed type (e.g. TechLab -> FactoryTechLab / StarportTechLab)
                if utype in TERRAN_ADDON_TYPES and tag in addons:
                    ainfo = addons[tag]
                    new_kind = base_prod_kind(utype)
                    if new_kind and ainfo["builder_kind"] and new_kind != ainfo["builder_kind"]:
                        res["addon_swap_events"] += 1
                        pair_key = f"{ainfo['builder_kind']}->{new_kind}"
                        if pair_key not in res["swap_pairs"]:
                            pair_key = "SameKind"
                        res["swap_pairs"][pair_key] = (
                            res["swap_pairs"].get(pair_key, 0) + 1
                        )
                        ainfo["builder_kind"] = new_kind
                        if res["first_swap_sec"] is None:
                            res["first_swap_sec"] = sec

        elif etype == "NNet.Replay.Tracker.SUnitPositionsEvent":
            idx = ev.get("m_firstUnitIndex", 0)
            items = ev.get("m_items", [])
            for i in range(0, len(items), 3):
                idx += items[i]
                if idx in prod_units:
                    prod_units[idx]["x"] = float(items[i + 1])
                    prod_units[idx]["y"] = float(items[i + 2])

        elif etype == "NNet.Replay.Tracker.SPlayerStatsEvent":
            p = ev.get("m_playerId", 0)
            st = ev.get("m_stats", {})
            if p in (1, 2) and isinstance(st, dict):
                min_used = st.get("m_scoreValueMineralsUsedInProgressArmy", 0) + st.get(
                    "m_scoreValueMineralsUsedCurrentArmy", 0
                )
                min_cur = st.get("m_scoreValueMineralsCurrent", 0)
                gas_cur = st.get("m_scoreValueVespeneCurrent", 0)
                min_rate = st.get("m_scoreValueMineralsCollectionRate", 0)
                p_collection[p] = max(p_collection[p], min_used + min_cur)
                if gas_cur >= 600 and min_cur < 200 and gl <= 13440:
                    res["gas_float_events"] += 1
                if gl >= 6720 and min_rate < 800 and len(p_townhalls[p]) >= 1:
                    res["depletion_events"] += 1

    # Check simultaneous +1/+1 weapon + armor pair (completed within <= 35s of each other)
    for p in (1, 2):
        lvl1 = [sec for (u, sec) in p_weap_arm[p] if u.endswith("Level1")]
        if len(lvl1) >= 2:
            lvl1.sort()
            if (lvl1[1] - lvl1[0]) <= 35.0:
                res["double_plus1_parallel_events"] += 1

    # Check upgrade lead at 480s (8:00) vs match winner
    if winner in (1, 2):
        u1 = sum(1 for (_, sec) in p_weap_arm[1] if sec <= 540.0)
        u2 = sum(1 for (_, sec) in p_weap_arm[2] if sec <= 540.0)
        if u1 != u2:
            res["upg_lead_total"] += 1
            leader = 1 if u1 > u2 else 2
            if leader == winner:
                res["upg_lead_wins"] += 1

    return res


def aggregate_cohort(records):
    valid = [r for r in records if r["valid"]]
    n = max(1, len(valid))

    upg_times = defaultdict(lambda: defaultdict(list))
    for r in valid:
        for race, upg, sec in r["upgrades"]:
            upg_times[race][upg].append(sec)

    race_upgrade_summary = {}
    for race, canonical_list in CANONICAL_UPGRADES_BY_RACE.items():
        race_dict = {}
        all_upgs = set(canonical_list) | set(upg_times[race].keys())
        for upg in sorted(all_upgs):
            times = sorted(upg_times[race].get(upg, []))
            if not times and upg not in canonical_list:
                continue
            if times:
                cnt = len(times)
                med = round(statistics.median(times), 1)
                mean = round(statistics.mean(times), 1)
                p25 = round(times[max(0, int(0.25 * (cnt - 1)))], 1)
                p75 = round(times[min(cnt - 1, int(0.75 * (cnt - 1)))], 1)
            else:
                cnt, med, mean, p25, p75 = 0, 0.0, 0.0, 0.0, 0.0
            race_dict[upg] = {
                "count": cnt,
                "median_sec": med,
                "p25_sec": p25,
                "p75_sec": p75,
                "mean_sec": mean,
            }
        race_upgrade_summary[race] = race_dict

    # Terran add-on swapping aggregation
    addons_total = Counter()
    liftoffs_total = Counter()
    swap_pairs_total = Counter()
    swap_secs = []
    replays_with_swap = 0
    terran_replays = 0
    for r in valid:
        if r["p1_race"] == "Terran" or r["p2_race"] == "Terran":
            terran_replays += 1
        for k, v in r["addons_built"].items():
            addons_total[k] += v
        for k, v in r["liftoff_events"].items():
            liftoffs_total[k] += v
        for k, v in r["swap_pairs"].items():
            swap_pairs_total[k] += v
        if r["addon_swap_events"] > 0:
            replays_with_swap += 1
        if r["first_swap_sec"] is not None:
            swap_secs.append(r["first_swap_sec"])

    # Expansion timing aggregation
    exp_times = defaultdict(lambda: defaultdict(list))
    for r in valid:
        for race, b_idx, sec in r["expansion_timings"]:
            exp_times[race][f"base_{b_idx}"].append(sec)

    exp_summary = {}
    for race in ("Zerg", "Terran", "Protoss"):
        exp_summary[race] = {}
        for b_idx in range(2, 6):
            key = f"base_{b_idx}"
            ts = sorted(exp_times[race].get(key, []))
            if ts:
                exp_summary[race][key] = {
                    "count": len(ts),
                    "median_sec": round(statistics.median(ts), 1),
                    "p25_sec": round(ts[max(0, int(0.25 * (len(ts) - 1)))], 1),
                    "p75_sec": round(ts[min(len(ts) - 1, int(0.75 * (len(ts) - 1)))], 1),
                }
            else:
                exp_summary[race][key] = {
                    "count": 0,
                    "median_sec": 0.0,
                    "p25_sec": 0.0,
                    "p75_sec": 0.0,
                }

    upg_lead_tot = sum(r["upg_lead_total"] for r in valid)
    upg_lead_wins = sum(r["upg_lead_wins"] for r in valid)

    return {
        "replays_scanned": len(valid),
        "upgrade_paths_and_timings": {
            "total_upgrades_completed": sum(len(r["upgrades"]) for r in valid),
            "double_plus1_parallel_events": sum(
                r["double_plus1_parallel_events"] for r in valid
            ),
            "plus2_weapon_armor_transitions": sum(
                r["plus2_transitions"] for r in valid
            ),
            "plus3_weapon_armor_transitions": sum(
                r["plus3_transitions"] for r in valid
            ),
            "upgrade_lead_at_8min_replays": upg_lead_tot,
            "upgrade_lead_win_rate_pct": round(
                100.0 * upg_lead_wins / max(1, upg_lead_tot), 1
            )
            if upg_lead_tot > 0
            else 0.0,
            "by_race": race_upgrade_summary,
        },
        "terran_addon_swapping": {
            "terran_replays_scanned": terran_replays,
            "addons_constructed_total": sum(addons_total.values()),
            "addons_constructed_by_type": dict(sorted(addons_total.items())),
            "building_liftoff_events_total": sum(liftoffs_total.values()),
            "building_liftoff_by_facility": dict(sorted(liftoffs_total.items())),
            "addon_swap_events_total": sum(r["addon_swap_events"] for r in valid),
            "addon_swap_pairs": dict(sorted(swap_pairs_total.items())),
            "replays_with_addon_swap": replays_with_swap,
            "replays_with_addon_swap_pct_of_terran": round(
                100.0 * replays_with_swap / max(1, terran_replays), 1
            )
            if terran_replays > 0
            else 0.0,
            "median_first_addon_swap_sec": round(statistics.median(swap_secs), 1)
            if swap_secs
            else 0.0,
        },
        "expansion_and_depletion_ledger": {
            "expansion_timings_by_race": exp_summary,
            "pre_depletion_proactive_expansions": sum(
                r["pre_depletion_expansions"] for r in valid
            ),
            "base_depletion_low_income_windows": sum(
                r["depletion_events"] for r in valid
            ),
            "unspent_gas_float_windows_600g": sum(
                r["gas_float_events"] for r in valid
            ),
        },
    }


def main():
    items, raw_file_count = collect_all_replays()
    with mp.Pool(processes=min(16, max(1, mp.cpu_count()))) as pool:
        records = list(pool.imap_unordered(scan_single_replay, items, chunksize=16))

    pro_recs = [
        r for r in records if r["cohort"] in ("pro_tournament", "pro_corpus")
    ]
    bot_recs = [
        r for r in records if r["cohort"] in ("aiarena_ladder", "external_gauntlet")
    ]
    local_recs = [r for r in records if r["cohort"] == "local_real_matches"]

    summary = {
        "evaluated_by": "Full Replay Corpus Upgrades, Terran Add-On Swapping & Expansion/Depletion Evaluator",
        "total_raw_sc2replay_files_on_disk": raw_file_count,
        "unique_sc2replay_archives_scanned": len(items),
        "valid_decoded_replays": sum(1 for r in records if r["valid"]),
        "cohorts": {
            "all": aggregate_cohort(records),
            "pro_all": aggregate_cohort(pro_recs),
            "aiarena_ladder": aggregate_cohort(bot_recs),
            "local_real_matches": aggregate_cohort(local_recs),
        },
    }

    os.makedirs("benchmarks", exist_ok=True)
    out_path = "benchmarks/full_corpus_upgrades_and_addon_swaps_report.json"
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, indent=2)

    print(
        f"Wrote {out_path} ({summary['valid_decoded_replays']} valid replays / {summary['unique_sc2replay_archives_scanned']} unique archives)"
    )


if __name__ == "__main__":
    main()
