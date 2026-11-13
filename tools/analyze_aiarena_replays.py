#!/usr/bin/env python3
"""
Closed-Loop AI Arena Forensic Replay & Match-Log Harvester (`analyze_aiarena_replays.py`).

1. Downloads `.SC2Replay` files and `match_log.zip` (`stdout.log` + `stderr.log`)
   for all Mothman bots (`1457`, `1458`, `1459`, `1460`) from the AI Arena API.
2. Parses `s2protocol` tracker events (expansions, upgrades, worker counts,
   resource collection rates, unspent banks, army values, unit deaths by minute).
3. Parses internal `[SCBOT_TELEMETRY]` JSON events and `Tag:` lines from `stdout.log`.
4. Produces per-match root-cause diagnostics and writes `replays/aiarena_matches/forensic_summary.json`.
"""
import argparse
import glob
import json
import os
import urllib.request
import zipfile
from collections import Counter
from typing import Any, Dict, List

import mpyq
from s2protocol import versions

DEFAULT_TOKEN = os.environ.get("AIARENA_API_TOKEN", "")
BOT_IDS = {
    1457: "Mothman-R",
    1458: "Mothman-Z",
    1459: "Mothman-T",
    1460: "Mothman-P",
    1461: "Mothman-X",
}
TH_NAMES = {
    "CommandCenter",
    "OrbitalCommand",
    "PlanetaryFortress",
    "Nexus",
    "Hatchery",
    "Lair",
    "Hive",
}
NON_COMBAT_DEATHS = {
    "Larva",
    "Egg",
    "MULE",
    "CreepTumor",
    "CreepTumorBurrowed",
    "CreepTumorQueen",
}


def api_get_json(url: str, token: str) -> Dict[str, Any]:
    headers = {"Authorization": f"Token {token}", "User-Agent": "sc-bot-forensics/2.0"}
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode("utf-8"))


def download_url(url: str, dest: str, token: str) -> None:
    headers = (
        {"Authorization": f"Token {token}", "User-Agent": "sc-bot-forensics/2.0"}
        if "aiarena.net" in url
        else {"User-Agent": "sc-bot-forensics/2.0"}
    )
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        with open(dest, "wb") as f:
            f.write(r.read())


def fetch_latest_matches(out_dir: str, token: str, limit: int = 20) -> List[int]:
    os.makedirs(out_dir, exist_ok=True)
    downloaded_matches: List[int] = []
    for bot_id, bot_name in BOT_IDS.items():
        mp = api_get_json(
            f"https://aiarena.net/api/match-participations/?bot={bot_id}&ordering=-id&limit={limit}",
            token,
        )
        for p in mp.get("results", []):
            mid = p["match"]
            mlog_url = p.get("match_log")
            if mlog_url:
                log_dest = os.path.join(out_dir, f"{mid}_match_log.zip")
                if not os.path.exists(log_dest):
                    try:
                        download_url(mlog_url, log_dest, token)
                    except Exception as e:
                        print(f"[WARN] Could not download match_log for {mid}: {e}")
            res = api_get_json(f"https://aiarena.net/api/results/?match={mid}", token)
            if res.get("results"):
                r0 = res["results"][0]
                rep_url = r0.get("replay_file")
                if rep_url:
                    rep_dest = os.path.join(out_dir, f"{mid}_{bot_name}_vs_Opponent.SC2Replay")
                    # Avoid duplicate download if any replay with same match id exists
                    existing = glob.glob(os.path.join(out_dir, f"{mid}_*.SC2Replay"))
                    if not existing:
                        try:
                            download_url(rep_url, rep_dest, token)
                        except Exception as e:
                            print(f"[WARN] Could not download replay for {mid}: {e}")
            downloaded_matches.append(mid)
    return sorted(set(downloaded_matches))


def parse_match_log_zip(zip_path: str) -> Dict[str, Any]:
    info: Dict[str, Any] = {
        "tags": [],
        "telemetry_events": [],
        "stderr_lines": [],
        "stdout_lines": [],
    }
    if not os.path.exists(zip_path):
        return info
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            if "stdout.log" in zf.namelist():
                stdout_txt = zf.read("stdout.log").decode("utf-8", errors="replace")
                for line in stdout_txt.splitlines():
                    info["stdout_lines"].append(line)
                    if line.startswith("Tag:"):
                        info["tags"].append(line.split("Tag:", 1)[1].strip())
                    elif line.startswith("[SCBOT_TELEMETRY]"):
                        raw_json = line.split("[SCBOT_TELEMETRY]", 1)[1].strip()
                        try:
                            info["telemetry_events"].append(json.loads(raw_json))
                        except Exception:
                            pass
            if "stderr.log" in zf.namelist():
                stderr_txt = zf.read("stderr.log").decode("utf-8", errors="replace")
                info["stderr_lines"] = [l for l in stderr_txt.splitlines() if l.strip()]
    except Exception as e:
        info["stderr_lines"].append(f"zip_parse_error: {e}")
    return info


def analyze_replay(rep_path: str) -> Dict[str, Any]:
    archive = mpyq.MPQArchive(rep_path)
    header = versions.latest().decode_replay_header(archive.header["user_data_header"]["content"])
    base_build = header["m_version"]["m_baseBuild"]
    try:
        protocol = versions.build(base_build)
    except Exception:
        protocol = versions.latest()
    details = protocol.decode_replay_details(archive.read_file("replay.details"))
    tracker = list(protocol.decode_replay_tracker_events(archive.read_file("replay.tracker.events")))

    p1_name = details["m_playerList"][0]["m_name"].decode()
    p2_name = details["m_playerList"][1]["m_name"].decode()
    p1_race = details["m_playerList"][0]["m_race"].decode()
    p2_race = details["m_playerList"][1]["m_race"].decode()
    map_name = details["m_title"].decode()

    our_pid = 1 if "Mothman" in p1_name else (2 if "Mothman" in p2_name else 1)
    opp_pid = 2 if our_pid == 1 else 1

    born = {1: Counter(), 2: Counter()}
    upgrades = {1: [], 2: []}
    townhall_timings = {1: [], 2: []}
    stats_by_min = {1: {}, 2: {}}
    supply_blocked_steps = {1: 0, 2: 0}
    total_stat_events = {1: 0, 2: 0}
    unit_owner: Dict[int, int] = {}
    unit_type: Dict[int, str] = {}
    deaths_by_min = {1: Counter(), 2: Counter()}

    for ev in tracker:
        et = ev["_event"]
        loop = ev["_gameloop"]
        sec = loop / 22.4
        if et in ("NNet.Replay.Tracker.SUnitBornEvent", "NNet.Replay.Tracker.SUnitInitEvent"):
            tag = (ev["m_unitTagIndex"] << 18) | ev["m_unitTagRecycle"]
            p = ev["m_controlPlayerId"]
            u = ev["m_unitTypeName"].decode()
            unit_owner[tag] = p
            unit_type[tag] = u
            if p in (1, 2):
                born[p][u] += 1
                if u in TH_NAMES and loop > 0:
                    prefix = "init:" if et.endswith("SUnitInitEvent") else ""
                    townhall_timings[p].append((round(sec, 1), f"{prefix}{u}"))
        elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
            tag = (ev["m_unitTagIndex"] << 18) | ev["m_unitTagRecycle"]
            p = unit_owner.get(tag)
            u = unit_type.get(tag, "?")
            if p in (1, 2) and u not in NON_COMBAT_DEATHS:
                m = int(sec // 60)
                deaths_by_min[p][(m, u)] += 1
        elif et == "NNet.Replay.Tracker.SUpgradeEvent":
            p = ev["m_playerId"]
            upg = ev["m_upgradeTypeName"].decode()
            if p in (1, 2) and not upg.startswith("Spray"):
                upgrades[p].append((round(sec, 1), upg))
        elif et == "NNet.Replay.Tracker.SPlayerStatsEvent":
            p = ev["m_playerId"]
            if p in (1, 2):
                st = ev["m_stats"]
                food_used = st["m_scoreValueFoodUsed"] // 4096
                food_made = st["m_scoreValueFoodMade"] // 4096
                total_stat_events[p] += 1
                if food_used >= food_made and food_made < 200 and loop > 224:
                    supply_blocked_steps[p] += 1
                minute = int(sec // 60)
                stats_by_min[p][minute] = {
                    "sec": round(sec, 1),
                    "min_cur": st["m_scoreValueMineralsCurrent"],
                    "gas_cur": st["m_scoreValueVespeneCurrent"],
                    "min_rate": st["m_scoreValueMineralsCollectionRate"],
                    "gas_rate": st["m_scoreValueVespeneCollectionRate"],
                    "workers": st["m_scoreValueWorkersActiveCount"],
                    "food_used": food_used,
                    "food_made": food_made,
                    "army_min": st["m_scoreValueMineralsUsedCurrentArmy"],
                    "army_gas": st["m_scoreValueVespeneUsedCurrentArmy"],
                    "lost_min": st["m_scoreValueMineralsLostArmy"] + st["m_scoreValueMineralsLostEconomy"],
                    "lost_gas": st["m_scoreValueVespeneLostArmy"] + st["m_scoreValueVespeneLostEconomy"],
                }

    base_name = os.path.basename(rep_path)
    match_id_str = base_name.split("_", 1)[0]
    log_zip_path = os.path.join(os.path.dirname(rep_path), f"{match_id_str}_match_log.zip")
    log_info = parse_match_log_zip(log_zip_path)

    # Automatic root-cause diagnosis from replay ground truth
    our_stats = stats_by_min[our_pid]
    opp_stats = stats_by_min[opp_pid]
    max_our_workers = max((s["workers"] for s in our_stats.values()), default=0)
    max_opp_workers = max((s["workers"] for s in opp_stats.values()), default=0)
    max_our_gas = max((s["gas_cur"] for s in our_stats.values()), default=0)
    our_expansions = len(townhall_timings[our_pid])
    opp_expansions = len(townhall_timings[opp_pid])
    first_our_expand_sec = townhall_timings[our_pid][0][0] if townhall_timings[our_pid] else None

    findings: List[str] = []
    if our_expansions == 0:
        findings.append("CRITICAL_ZERO_EXPANSIONS: Never built a 2nd TownHall; starved on 1 base (~21 workers).")
    elif first_our_expand_sec and first_our_expand_sec > 180.0:
        findings.append(f"DELAYED_NATURAL_EXPANSION: First expansion started at {first_our_expand_sec}s (>180s).")
    if opp_expansions >= our_expansions + 3:
        findings.append(f"MACRO_BASE_DEFICIT: {our_expansions + 1} bases vs opponent {opp_expansions + 1} bases.")
    if max_opp_workers >= max_our_workers + 25:
        findings.append(f"WORKER_DEFICIT: Peak {max_our_workers} workers vs opponent {max_opp_workers} workers.")
    if max_our_gas >= 400:
        findings.append(f"UNSPENT_GAS_FLOAT: Floated up to {max_our_gas} Vespene without sufficient gas tech/upgrades.")
    if not upgrades[our_pid]:
        findings.append("ZERO_UPGRADES_COMPLETED: Completed 0 combat/tech upgrades during match.")

    # Extract Schema 2.0 structured telemetry summary if present in match_log.zip
    schema2_summary: Dict[str, Any] = {}
    for ev in log_info["telemetry_events"]:
        if ev.get("event") in ("PERIODIC_SNAPSHOT", "MATCH_END_SUMMARY"):
            schema2_summary.update(
                {
                    k: ev[k]
                    for k in (
                        "schema_version",
                        "guns_vs_butter_regime",
                        "target_resource_ratio",
                        "worker_prod_utilization_pct",
                        "unit_prod_utilization_pct",
                        "observed_enemy_upgrades",
                        "observed_enemy_spells",
                        "implied_enemy_tech_buildings",
                        "active_implied_enemy_tech_buildings",
                        "crippled_enemy_tech_buildings",
                        "inferred_enemy_active_research",
                        "stargate_preview_units",
                        "confirmed_enemy_hallucinations",
                        "enemy_committed_branch",
                        "enemy_excluded_branches",
                        "enemy_bluff_suspected",
                        "our_lost_minerals",
                        "our_lost_gas",
                        "enemy_lost_minerals",
                        "enemy_lost_gas",
                        "estimated_enemy_workers",
                        "estimated_apm",
                        "estimated_epm",
                        "estimated_spm",
                        "deception_spells_cast",
                        "protective_auras_cast",
                        "presplit_concave_maneuvers",
                        "bottlenecks",
                    )
                    if k in ev
                }
            )

    print("=" * 98)
    print(
        f"MATCH {match_id_str} | Map: {map_name} | "
        f"P{our_pid} ({p1_name if our_pid == 1 else p2_name} - {p1_race if our_pid == 1 else p2_race}) vs "
        f"P{opp_pid} ({p2_name if our_pid == 1 else p1_name} - {p2_race if our_pid == 1 else p1_race})"
    )
    print(f"  Match Log Tags: {log_info['tags']} | Telemetry Events: {len(log_info['telemetry_events'])} | Stderr Lines: {len(log_info['stderr_lines'])}")
    print(f"  Our TownHalls after 0s: {townhall_timings[our_pid]} | Opponent: {townhall_timings[opp_pid]}")
    print(f"  Our Upgrades: {upgrades[our_pid]} | Opponent: {upgrades[opp_pid]}")
    if schema2_summary:
        print(f"  Schema 2.0 Telemetry Summary: {schema2_summary}")
    print(f"  Forensic Root-Cause Findings:")
    for f_str in findings:
        print(f"    - {f_str}")
    print("  Minute-by-Minute Telemetry (Our Bot vs Opponent):")
    for m in sorted(set(our_stats.keys()) | set(opp_stats.keys())):
        s1 = our_stats.get(m, {})
        s2 = opp_stats.get(m, {})
        d1 = {u: c for (mm, u), c in deaths_by_min[our_pid].items() if mm == m}
        print(
            f"    Min {m:2d} | Us: W={s1.get('workers',0):2d} Sup={s1.get('food_used',0):3d}/{s1.get('food_made',0):3d} "
            f"Bank={s1.get('min_cur',0):4d}M/{s1.get('gas_cur',0):4d} Rate={s1.get('min_rate',0):4d}M "
            f"Army={s1.get('army_min',0)+s1.get('army_gas',0):5d} Lost={s1.get('lost_min',0)+s1.get('lost_gas',0):5d} "
            f"|| Opp: W={s2.get('workers',0):3d} Sup={s2.get('food_used',0):3d}/{s2.get('food_made',0):3d} "
            f"Rate={s2.get('min_rate',0):4d}M Army={s2.get('army_min',0)+s2.get('army_gas',0):5d} | OurDeaths={d1}"
        )

    return {
        "match_id": match_id_str,
        "map": map_name,
        "our_race": p1_race if our_pid == 1 else p2_race,
        "opp_race": p2_race if our_pid == 1 else p1_race,
        "our_expansions": townhall_timings[our_pid],
        "opp_expansions": townhall_timings[opp_pid],
        "our_upgrades": upgrades[our_pid],
        "opp_upgrades": upgrades[opp_pid],
        "max_our_workers": max_our_workers,
        "max_opp_workers": max_opp_workers,
        "max_our_gas": max_our_gas,
        "supply_blocked_snapshots": supply_blocked_steps[our_pid],
        "tags": log_info["tags"],
        "telemetry_events": log_info["telemetry_events"],
        "schema2_summary": schema2_summary,
        "findings": findings,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Forensic AI Arena Replay & Match-Log Analyzer")
    parser.add_argument("--fetch", action="store_true", help="Download latest replays and match_log.zip files from AI Arena API")
    parser.add_argument("--dir", default="replays/aiarena_matches", help="Directory containing downloaded replays and match logs")
    args = parser.parse_args()

    if args.fetch:
        fetch_latest_matches(args.dir, DEFAULT_TOKEN)

    reports = []
    for rp in sorted(glob.glob(os.path.join(args.dir, "*.SC2Replay"))):
        reports.append(analyze_replay(rp))

    out_json = os.path.join(args.dir, "forensic_summary.json")
    os.makedirs(args.dir, exist_ok=True)
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(reports, f, indent=2)
    print(f"\n[OK] Wrote {len(reports)} forensic match reports to {out_json}")


if __name__ == "__main__":
    main()
