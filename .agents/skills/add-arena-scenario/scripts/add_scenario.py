#!/usr/bin/env python3
"""
Human-friendly helper CLI to list, validate, add, extract from SC2 replays, or remove
tactics arena scenarios in `tools/arena-scenarios.json` (Tactics Arena 2.0).

Examples:
  # List all scenarios with combat value balance, terrain, source & upgrades
  python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --list

  # List all supported SC2 unit names and upgrade keys
  python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --list-units

  # Preview a new terrain + upgrade scenario (dry-run)
  python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py \\
    --race Zerg --enemy-race Protoss --slug roach-burrow-ramp \\
    --terrain high-ground-ramp --high-ground-side p1 \\
    --p1 "roach:10,ravager:2" --p2 "stalker:6,immortal:2" \\
    --p1-upgrades "Burrow,TunnelingClaws,GlialReconstitution" --p2-upgrades "Blink" \\
    --source custom --patterns "roach-burrow-heal,high-ground-ramp" \\
    --opponent self --dry-run

  # Extract a peak-clash scenario directly from a real .SC2Replay file!
  python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py \\
    --from-replay /path/to/match.SC2Replay --slug match-peak-clash --dry-run
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_CATALOG = REPO_ROOT / "tools" / "arena-scenarios.json"
DEFAULT_PYLIBS = Path("/home/sjaconette/sc2-local-arena/pylibs")

VALID_TERRAINS = (
    "open",
    "high-ground-ramp",
    "flank-surround",
    "cliff-air-chasm",
    "mineral-line-harass",
)
VALID_SOURCES = ("core", "match-forensics", "pro-db", "pattern-coverage", "replay-extract", "custom")

VALID_UPGRADES = {
    "Burrow", "TunnelingClaws", "GlialReconstitution", "MetabolicBoost", "AdrenalGlands",
    "CentrifugalHooks", "LurkerRange", "AdaptiveTalons", "GroovedSpines", "MuscularAugments",
    "ChitinousPlating", "NeuralParasite",
    "Blink", "Charge", "ResonatingGlaives", "ThermalLance", "PsiStorm",
    "ShadowStride", "ProtossGroundWeapons1", "ProtossGroundWeapons2", "ProtossGroundWeapons3",
    "Stim", "CombatShield", "ConcussiveShells", "DrillingClaws", "SmartServos",
    "InfernalPreigniter", "BansheeCloak", "PersonalCloaking", "AdvancedBallistics", "Cloak",
}

# Canonical Blizzard 4.10 SC2 UnitTypeIds, (id, value, role_offset_from_front)
UNITS: dict[str, tuple[int, float, float]] = {
    # Protoss
    "zealot": (73, 100.0, 0.0),
    "adept": (311, 137.5, 0.8),
    "stalker": (74, 200.0, 1.2),
    "sentry": (77, 200.0, 1.6),
    "immortal": (83, 425.0, 0.5),
    "archon": (141, 550.0, 0.0),
    "dark-templar": (76, 312.5, 0.0),
    "high-templar": (75, 275.0, 2.2),
    "colossus": (4, 600.0, 2.4),
    "disruptor": (694, 375.0, 2.4),
    "phoenix": (78, 300.0, 1.5),
    "oracle": (495, 375.0, 2.0),
    "void-ray": (80, 475.0, 1.5),
    "tempest": (496, 512.5, 3.0),
    "carrier": (79, 725.0, 3.0),
    "observer": (82, 137.5, 2.2),
    "warp-prism": (81, 250.0, 2.5),
    "probe": (84, 50.0, 0.5),
    # Terran
    "hellbat": (484, 100.0, 0.0),
    "hellion": (53, 100.0, 0.5),
    "marauder": (51, 137.5, 0.3),
    "marine": (48, 50.0, 1.0),
    "reaper": (49, 125.0, 0.4),
    "cyclone": (692, 300.0, 0.9),
    "thor": (52, 600.0, 0.6),
    "ghost": (50, 337.5, 2.0),
    "siege-tank": (33, 337.5, 2.2),
    "siege-tank-sieged": (32, 337.5, 2.8),
    "widow-mine": (498, 112.5, 0.7),
    "widow-mine-burrowed": (500, 112.5, 0.7),
    "medivac": (54, 250.0, 2.4),
    "viking-fighter": (35, 262.5, 1.6),
    "viking-assault": (34, 262.5, 1.0),
    "banshee": (55, 300.0, 2.0),
    "raven": (56, 400.0, 2.4),
    "liberator": (689, 375.0, 2.2),
    "liberator-ag": (734, 375.0, 2.2),
    "battlecruiser": (57, 850.0, 2.8),
    "scv": (45, 50.0, 0.5),
    "planetary-fortress": (130, 775.0, 2.0),
    "missile-turret": (23, 100.0, 1.5),
    # Zerg
    "zergling": (105, 25.0, 0.0),
    "zergling-burrowed": (119, 25.0, 0.0),
    "baneling": (9, 87.5, 0.4),
    "baneling-burrowed": (115, 87.5, 0.4),
    "ultralisk": (109, 575.0, 0.2),
    "ultralisk-burrowed": (131, 575.0, 0.2),
    "roach": (110, 112.5, 0.4),
    "roach-burrowed": (118, 112.5, 0.4),
    "ravager": (688, 250.0, 1.3),
    "ravager-burrowed": (690, 250.0, 1.3),
    "hydralisk": (107, 175.0, 1.4),
    "hydralisk-burrowed": (117, 175.0, 1.4),
    "queen": (126, 150.0, 1.8),
    "queen-burrowed": (125, 150.0, 1.8),
    "lurker-mp": (502, 375.0, 1.6),
    "lurker-mp-burrowed": (503, 375.0, 1.6),
    "infestor": (111, 325.0, 2.2),
    "infestor-burrowed": (127, 325.0, 2.2),
    "swarm-host": (494, 212.5, 2.4),
    "swarm-host-burrowed": (493, 212.5, 2.4),
    "mutalisk": (108, 250.0, 1.5),
    "corruptor": (112, 300.0, 1.5),
    "viper": (499, 400.0, 2.4),
    "brood-lord": (114, 675.0, 3.0),
    "overseer": (129, 225.0, 2.2),
    "drone": (104, 50.0, 0.5),
    "drone-burrowed": (116, 50.0, 0.5),
}

ALIASES: dict[str, str] = {
    "ling": "zergling", "lings": "zergling", "zerglings": "zergling",
    "bane": "baneling", "banes": "baneling", "banelings": "baneling",
    "hydra": "hydralisk", "hydras": "hydralisk", "hydralisks": "hydralisk",
    "muta": "mutalisk", "mutas": "mutalisk",
    "ultra": "ultralisk", "ultras": "ultralisk",
    "lurker": "lurker-mp", "lurkers": "lurker-mp", "lurkermp": "lurker-mp",
    "burrowed-lurker": "lurker-mp-burrowed", "lurkermpburrowed": "lurker-mp-burrowed",
    "broodlord": "brood-lord", "broodlords": "brood-lord", "bl": "brood-lord",
    "roaches": "roach", "roachburrowed": "roach-burrowed", "burrowed-roach": "roach-burrowed",
    "ravagers": "ravager", "queens": "queen", "infestors": "infestor",
    "vipers": "viper", "corruptors": "corruptor", "swarmhostmp": "swarm-host",
    "marines": "marine", "marauders": "marauder", "medivacs": "medivac",
    "reapers": "reaper", "hellions": "hellion", "hellbats": "hellbat", "helliontank": "hellbat",
    "cyclones": "cyclone", "ghosts": "ghost", "ravens": "raven", "thors": "thor", "thorap": "thor",
    "banshees": "banshee", "liberators": "liberator", "liberatorag": "liberator-ag",
    "tank": "siege-tank", "tanks": "siege-tank", "siegetank": "siege-tank",
    "sieged-tank": "siege-tank-sieged", "sieged-tanks": "siege-tank-sieged", "siegetanksieged": "siege-tank-sieged",
    "viking": "viking-fighter", "vikings": "viking-fighter", "vikingfighter": "viking-fighter", "vikingassault": "viking-assault",
    "bc": "battlecruiser", "battlecruisers": "battlecruiser",
    "mine": "widow-mine", "mines": "widow-mine", "widowmine": "widow-mine", "widowmineburrowed": "widow-mine-burrowed",
    "pf": "planetary-fortress", "planetary": "planetary-fortress", "planetaryfortress": "planetary-fortress",
    "turret": "missile-turret", "turrets": "missile-turret", "missileturret": "missile-turret",
    "zealots": "zealot", "stalkers": "stalker", "adepts": "adept", "sentries": "sentry",
    "immortals": "immortal", "archons": "archon", "colossi": "colossus", "colossuses": "colossus",
    "ht": "high-templar", "hts": "high-templar", "hightemplar": "high-templar",
    "dt": "dark-templar", "dts": "dark-templar", "darktemplar": "dark-templar",
    "disruptors": "disruptor", "oracles": "oracle", "phoenixes": "phoenix",
    "voidray": "void-ray", "voidrays": "void-ray", "void-rays": "void-ray",
    "tempests": "tempest", "carriers": "carrier", "warpprism": "warp-prism", "warpprismphasing": "warp-prism",
}

RACE_PREFIX = {"Protoss": "p", "Terran": "t", "Zerg": "z"}
RACE_ORDER = {"Protoss": 0, "Terran": 1, "Zerg": 2}
UNIT_TO_RACE: dict[str, str] = {}
for _k, (_uid, _, _) in UNITS.items():
    if _k in ("zealot", "adept", "stalker", "sentry", "immortal", "archon", "dark-templar", "high-templar", "colossus", "disruptor", "phoenix", "oracle", "void-ray", "tempest", "carrier", "observer", "warp-prism", "probe"):
        UNIT_TO_RACE[_k] = "Protoss"
    elif _k in ("hellbat", "hellion", "marauder", "marine", "reaper", "cyclone", "thor", "ghost", "siege-tank", "siege-tank-sieged", "widow-mine", "widow-mine-burrowed", "medivac", "viking-fighter", "viking-assault", "banshee", "raven", "liberator", "liberator-ag", "battlecruiser", "scv", "planetary-fortress", "missile-turret"):
        UNIT_TO_RACE[_k] = "Terran"
    else:
        UNIT_TO_RACE[_k] = "Zerg"


def normalize_unit(raw: str) -> str:
    key = raw.strip().lower().replace("_", "-").replace(" ", "-")
    key = ALIASES.get(key, key)
    if key not in UNITS:
        key_compact = re.sub(r"[^a-z0-9]", "", raw.strip().lower())
        key = ALIASES.get(key_compact, key)
    if key not in UNITS:
        raise ValueError(f"Unknown unit '{raw}'. Run --list-units to see supported keys.")
    return key


def parse_csv_list(raw: str) -> list[str]:
    return [x.strip() for x in (raw or "").split(",") if x.strip()]


def parse_army_spec(spec: str, side: int, separation: float) -> list[list[Any]]:
    half_sep = max(3.0, separation / 2.0)
    groups: list[list[Any]] = []
    for token in [t.strip() for t in spec.split(",") if t.strip()]:
        explicit_xy = None
        if "@" in token:
            head, coords = token.split("@", 1)
            parts = coords.split(",")
            if len(parts) != 2:
                raise ValueError(f"Bad @dx,dy offset in '{token}'")
            explicit_xy = (float(parts[0]), float(parts[1]))
            token = head
        if ":" in token:
            uname_raw, cnt_raw = token.split(":", 1)
            cnt = int(cnt_raw)
        else:
            uname_raw, cnt = token, 1
        if cnt <= 0:
            raise ValueError(f"Unit count must be > 0 in '{token}'")
        uname = normalize_unit(uname_raw)
        if explicit_xy is not None:
            dx, dy = explicit_xy
        else:
            role_off = UNITS[uname][2]
            dx = round(side * (half_sep - 0.5 + role_off), 2)
            dy = 0.0
        groups.append([uname, cnt, dx, dy])
    if not groups:
        raise ValueError("Army spec cannot be empty.")
    return groups


def extract_peak_clash_from_replay(
    replay_path: Path,
    our_player_id: int = 1,
    window_loops: int = 224,
    max_units_per_side: int = 28,
) -> dict[str, Any]:
    """
    Scan a real .SC2Replay via s2protocol (protocol75689) to locate the highest-value
    combat clash and synthesize a ready-to-run Tactics Arena 2.0 scenario spec!
    """
    if str(DEFAULT_PYLIBS) not in sys.path and DEFAULT_PYLIBS.is_dir():
        sys.path.append(str(DEFAULT_PYLIBS))
    import mpyq  # type: ignore[import-not-found]

    proto_path = DEFAULT_PYLIBS / "s2protocol" / "versions" / "protocol75689.py"
    if not proto_path.is_file():
        raise FileNotFoundError(f"s2protocol protocol75689 not found at {proto_path}")
    spec = importlib.util.spec_from_file_location("protocol75689", str(proto_path))
    assert spec and spec.loader
    proto = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(proto)

    arc = mpyq.MPQArchive(str(replay_path))
    details = proto.decode_replay_details(arc.read_file("replay.details"))
    players = details.get("m_playerList") or []
    races_by_pid: dict[int, str] = {}
    names_by_pid: dict[int, str] = {}
    for idx, pl in enumerate(players, start=1):
        r_raw = pl.get("m_race", b"")
        r_str = r_raw.decode("utf-8", errors="ignore") if isinstance(r_raw, bytes) else str(r_raw)
        n_raw = pl.get("m_name", b"")
        n_str = n_raw.decode("utf-8", errors="ignore") if isinstance(n_raw, bytes) else str(n_raw)
        races_by_pid[idx] = r_str
        names_by_pid[idx] = n_str

    trk_bytes = arc.read_file("replay.tracker.events")
    # Track alive combat units over time and locate the peak-value combat death window
    units_born: dict[tuple[int, int], tuple[str, int, int]] = {}  # (idx, rec) -> (canon_name, owner, born_loop)
    unit_died: dict[tuple[int, int], int] = {}
    deaths: list[tuple[int, int, str, float]] = []

    for ev in proto.decode_replay_tracker_events(trk_bytes):
        et = ev.get("_event")
        loop = int(ev.get("_gameloop", 0))
        if et in ("NNet.Replay.Tracker.SUnitBornEvent", "NNet.Replay.Tracker.SUnitDoneEvent", "NNet.Replay.Tracker.SUnitTypeChangeEvent"):
            key = (int(ev.get("m_unitTagIndex", -1)), int(ev.get("m_unitTagRecycle", -1)))
            raw_t = ev.get("m_unitTypeName", b"")
            t_str = raw_t.decode("utf-8", errors="ignore") if isinstance(raw_t, bytes) else str(raw_t)
            owner = int(ev.get("m_controlPlayerId") or ev.get("m_upkeepPlayerId") or (units_born.get(key, ("", 0, 0))[1]))
            try:
                canon = normalize_unit(t_str)
            except ValueError:
                continue
            units_born[key] = (canon, owner, units_born[key][2] if key in units_born else loop)
        elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
            key = (int(ev.get("m_unitTagIndex", -1)), int(ev.get("m_unitTagRecycle", -1)))
            if key in units_born:
                canon, owner, _bl = units_born[key]
                unit_died[key] = loop
                if owner in (1, 2) and canon not in ("probe", "scv", "drone", "drone-burrowed"):
                    deaths.append((loop, owner, canon, UNITS[canon][1]))

    if not deaths:
        raise ValueError(f"No combat unit deaths found in replay {replay_path}")

    # Sliding window to locate peak combined combat death value
    deaths.sort(key=lambda x: x[0])
    best_score = -1.0
    best_start = deaths[0][0]
    j = 0
    cur_val = 0.0
    p1_val = 0.0
    p2_val = 0.0
    for i in range(len(deaths)):
        lp, own, _c, val = deaths[i]
        cur_val += val
        if own == our_player_id:
            p1_val += val
        else:
            p2_val += val
        while deaths[j][0] < lp - window_loops:
            _, own_j, _, val_j = deaths[j]
            cur_val -= val_j
            if own_j == our_player_id:
                p1_val -= val_j
            else:
                p2_val -= val_j
            j += 1
        # Reward mutual clashes where both sides fight
        score = cur_val + 0.35 * min(p1_val, p2_val)
        if score > best_score:
            best_score = score
            best_start = max(16, deaths[j][0] - 24)

    # Snapshot all alive combat units on both sides at best_start
    p1_counts: Counter[str] = Counter()
    p2_counts: Counter[str] = Counter()
    for key, (canon, owner, born_loop) in units_born.items():
        if owner not in (1, 2):
            continue
        if canon in ("probe", "scv", "drone", "drone-burrowed"):
            continue
        died_loop = unit_died.get(key, 10**9)
        if born_loop <= best_start < died_loop:
            if owner == our_player_id:
                p1_counts[canon] += 1
            else:
                p2_counts[canon] += 1

    # Cap extreme unit counts proportionally so arena skirmishes stay crisp
    def _cap_counts(cnts: Counter[str]) -> list[tuple[str, int]]:
        tot = sum(cnts.values())
        if tot == 0:
            return []
        scale = min(1.0, max_units_per_side / float(tot))
        out = []
        for u, c in cnts.most_common(6):
            nc = max(1, int(round(c * scale)))
            out.append((u, nc))
        return out

    p1_list = _cap_counts(p1_counts)
    p2_list = _cap_counts(p2_counts)
    if not p1_list or not p2_list:
        raise ValueError(f"Peak clash at loop {best_start} in {replay_path} had empty combat army on one side.")

    our_race = races_by_pid.get(our_player_id) or UNIT_TO_RACE[p1_list[0][0]]
    enemy_pid = 2 if our_player_id == 1 else 1
    enemy_race = races_by_pid.get(enemy_pid) or UNIT_TO_RACE[p2_list[0][0]]
    clock_sec = best_start / 22.4
    clock_str = f"{int(clock_sec // 60):02d}:{int(clock_sec % 60):02d}"
    return {
        "our_race": our_race,
        "enemy_race": enemy_race,
        "p1_spec": ",".join(f"{u}:{c}" for u, c in p1_list),
        "p2_spec": ",".join(f"{u}:{c}" for u, c in p2_list),
        "clock": clock_str,
        "loop": best_start,
        "p1_name": names_by_pid.get(our_player_id, "P1"),
        "p2_name": names_by_pid.get(enemy_pid, "P2"),
        "clash_val": round(best_score, 1),
    }


def army_value(units: list[list[Any]]) -> float:
    return sum(UNITS[u[0]][1] * int(u[1]) for u in units)


def army_summary(units: list[list[Any]]) -> str:
    agg: dict[str, int] = {}
    for u in units:
        agg[u[0]] = agg.get(u[0], 0) + int(u[1])
    return " + ".join(f"{cnt} {name}" for name, cnt in agg.items())


def load_catalog(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise FileNotFoundError(f"Scenario catalog not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, dict) and "scenarios" in data:
        return list(data["scenarios"])
    if isinstance(data, list):
        return data
    raise ValueError(f"Unexpected JSON structure in {path}")


def save_catalog(path: Path, scenarios: list[dict[str, Any]]) -> None:
    scenarios_sorted = sorted(
        scenarios,
        key=lambda s: (RACE_ORDER.get(s.get("our_race", ""), 9), s.get("id", "")),
    )
    payload = {
        "schema_version": 2,
        "notes": "Real-SC2_x64 micro skirmish scenarios loaded by tools/sc2-tactics-arena.py. Add or edit via .agents/skills/add-arena-scenario/scripts/add_scenario.py.",
        "scenarios": scenarios_sorted,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def next_id(scenarios: list[dict[str, Any]], race: str, slug: str) -> str:
    pfx = RACE_PREFIX[race]
    pat = re.compile(rf"^sc2-real-{pfx}(\d+)-")
    max_n = 0
    for s in scenarios:
        m = pat.match(s.get("id", ""))
        if m:
            max_n = max(max_n, int(m.group(1)))
    clean_slug = re.sub(r"[^a-z0-9]+", "-", slug.strip().lower()).strip("-")
    if not clean_slug:
        clean_slug = "custom-duel"
    return f"sc2-real-{pfx}{max_n + 1:02d}-{clean_slug}"


def validate_catalog(scenarios: list[dict[str, Any]]) -> list[str]:
    errs: list[str] = []
    seen: set[str] = set()
    for i, s in enumerate(scenarios):
        sid = s.get("id", "")
        if not sid:
            errs.append(f"Scenario #{i} missing 'id'")
        elif sid in seen:
            errs.append(f"Duplicate scenario id: {sid}")
        seen.add(sid)
        for field in ("our_race", "enemy_race"):
            if s.get(field) not in RACE_PREFIX:
                errs.append(f"{sid}: invalid {field}={s.get(field)!r}")
        terrain = s.get("terrain", "open")
        if terrain not in VALID_TERRAINS:
            errs.append(f"{sid}: invalid terrain={terrain!r}")
        for ukey in ("upgrades", "p1_upgrades", "p2_upgrades"):
            for u in s.get(ukey) or []:
                if u not in VALID_UPGRADES:
                    errs.append(f"{sid}: unknown upgrade {u!r} in {ukey}")
        for side_key in ("p1_units", "p2_units"):
            ulist = s.get(side_key)
            if not isinstance(ulist, list) or not ulist:
                errs.append(f"{sid}: {side_key} must be a non-empty list")
                continue
            for item in ulist:
                if not isinstance(item, list) or len(item) != 4:
                    errs.append(f"{sid}: bad {side_key} entry {item!r}")
                else:
                    uname, cnt, dx, dy = item
                    if uname not in UNITS:
                        errs.append(f"{sid}: unknown unit {uname!r} in {side_key}")
                    if not isinstance(cnt, int) or cnt <= 0:
                        errs.append(f"{sid}: invalid count {cnt!r} in {side_key}")
    return errs


def main() -> int:
    ap = argparse.ArgumentParser(description="Manage Mothman real-SC2 tactics arena 2.0 scenarios")
    ap.add_argument("--catalog", default=str(DEFAULT_CATALOG))
    ap.add_argument("--list", action="store_true", help="List all scenarios with balance, terrain, source & upgrades")
    ap.add_argument("--list-units", action="store_true", help="List all supported SC2 unit names and upgrade keys")
    ap.add_argument("--validate", action="store_true", help="Validate the scenario catalog")
    ap.add_argument("--remove", default="", help="Remove scenario with exact id")
    ap.add_argument("--from-replay", default="", help="Extract peak-clash scenario automatically from a .SC2Replay file")
    ap.add_argument("--our-player-id", type=int, default=1, help="Player ID in replay for --from-replay (default 1)")
    ap.add_argument("--race", choices=["Protoss", "Terran", "Zerg"], help="Mothman's race (P1)")
    ap.add_argument("--enemy-race", choices=["Protoss", "Terran", "Zerg"], help="Opponent's race (P2)")
    ap.add_argument("--id", default="", help="Explicit scenario id (auto-generated from --slug if omitted)")
    ap.add_argument("--slug", default="", help="Short kebab-case slug (e.g. blink-vs-tanks)")
    ap.add_argument("--p1", default="", help="Mothman army spec, e.g. 'zealot:4,stalker:4'")
    ap.add_argument("--p2", default="", help="Opponent army spec, e.g. 'marine:12,marauder:3'")
    ap.add_argument("--terrain", choices=list(VALID_TERRAINS), default="open", help="Real SC2 terrain spawn mode")
    ap.add_argument("--high-ground-side", choices=["p1", "p2"], default="p1", help="Which side holds high ground on high-ground-ramp")
    ap.add_argument("--source", choices=list(VALID_SOURCES), default="custom", help="Scenario provenance tag")
    ap.add_argument("--patterns", default="", help="Comma-separated tactical pattern tags")
    ap.add_argument("--upgrades", default="", help="Comma-separated shared upgrades (auto-routed by race)")
    ap.add_argument("--p1-upgrades", default="", help="Comma-separated P1 upgrades (e.g. 'Burrow,TunnelingClaws')")
    ap.add_argument("--p2-upgrades", default="", help="Comma-separated P2 upgrades (e.g. 'Blink,Charge')")
    ap.add_argument("--p1-pre-cloaked", action="store_true", help="Cloak P1 Banshees/Ghosts at fight start")
    ap.add_argument("--p2-pre-cloaked", action="store_true", help="Cloak P2 Banshees/Ghosts at fight start")
    ap.add_argument("--opponent", choices=["dummy", "self"], default="dummy", help="Opponent mode for printed preview command")
    ap.add_argument("--separation", type=float, default=9.0, help="Front-line separation in tiles (default 9.0)")
    ap.add_argument("--max-loops", type=int, default=336, help="Max combat loops (~22.4 loops/sec, default 336)")
    ap.add_argument("--description", default="", help="Human-readable description for reports & 3D clip context")
    ap.add_argument("--dry-run", action="store_true", help="Preview scenario without modifying catalog")
    args = ap.parse_args()

    if args.list_units:
        print(f"{'Unit Key':22s} {'SC2 ID':>6s} {'Value':>7s} {'Layer':>6s}")
        print("-" * 46)
        for k in sorted(UNITS):
            uid, val, layer = UNITS[k]
            print(f"{k:22s} {uid:6d} {val:7.1f} {layer:6.1f}")
        print("\nSupported Terrains:", ", ".join(VALID_TERRAINS))
        print("Supported Upgrades:", ", ".join(sorted(VALID_UPGRADES)))
        return 0

    cat_path = Path(args.catalog)
    scenarios = load_catalog(cat_path)

    if args.validate:
        errs = validate_catalog(scenarios)
        if errs:
            for e in errs:
                print(f"ERROR: {e}", file=sys.stderr)
            return 1
        print(f"OK: {len(scenarios)} scenarios validated cleanly in {cat_path}")
        return 0

    if args.list:
        print(f"{'ID':54s} {'MU':4s} {'Terrain':19s} {'Source':16s} {'P1/P2':>11s}")
        print("-" * 110)
        for s in scenarios:
            v1 = army_value(s["p1_units"])
            v2 = army_value(s["p2_units"])
            mu = f"{s['our_race'][0]}v{s['enemy_race'][0]}"
            terr = s.get("terrain", "open")
            src = s.get("source", "core")
            print(f"{s['id']:54s} {mu:4s} {terr:19s} {src:16s} {v1:5.0f}/{v2:5.0f}")
        print(f"\nTotal: {len(scenarios)} scenarios ({cat_path})")
        return 0

    if args.remove:
        before = len(scenarios)
        scenarios = [s for s in scenarios if s.get("id") != args.remove]
        if len(scenarios) == before:
            print(f"Scenario not found: {args.remove}", file=sys.stderr)
            return 1
        if not args.dry_run:
            save_catalog(cat_path, scenarios)
        print(f"Removed {args.remove} ({len(scenarios)} remaining)")
        return 0

    if args.from_replay:
        rep_p = Path(args.from_replay).resolve()
        if not rep_p.is_file():
            ap.error(f"Replay file not found: {rep_p}")
        ext = extract_peak_clash_from_replay(rep_p, our_player_id=args.our_player_id)
        if not args.race:
            args.race = ext["our_race"]
        if not args.enemy_race:
            args.enemy_race = ext["enemy_race"]
        if not args.p1:
            args.p1 = ext["p1_spec"]
        if not args.p2:
            args.p2 = ext["p2_spec"]
        if not args.slug:
            args.slug = re.sub(r"[^a-z0-9]+", "-", rep_p.stem.lower()).strip("-")[:36]
        if args.source == "custom":
            args.source = "replay-extract"
        if not args.description:
            args.description = (
                f"Extracted from {rep_p.name} @ {ext['clock']} (clash~{ext['clash_val']:.0f}): "
                f"{ext['p1_name']} ({ext['p1_spec']}) vs {ext['p2_name']} ({ext['p2_spec']})"
            )

    if not (args.race and args.enemy_race and args.p1 and args.p2):
        ap.error("Provide --race, --enemy-race, --p1, and --p2 (or --from-replay, --list, --list-units, --validate).")

    p1_units = parse_army_spec(args.p1, side=-1, separation=args.separation)
    p2_units = parse_army_spec(args.p2, side=+1, separation=args.separation)
    sid = args.id.strip() or next_id(scenarios, args.race, args.slug or f"{p1_units[0][0]}-vs-{p2_units[0][0]}")
    if any(s.get("id") == sid for s in scenarios):
        print(f"ERROR: Scenario id already exists: {sid}", file=sys.stderr)
        return 1

    desc = args.description.strip() or f"Real SC2: {army_summary(p1_units)} vs {army_summary(p2_units)}"
    entry: dict[str, Any] = {
        "id": sid,
        "our_race": args.race,
        "enemy_race": args.enemy_race,
        "source": args.source,
        "terrain": args.terrain,
        "description": desc,
        "p1_units": p1_units,
        "p2_units": p2_units,
        "max_loops": int(args.max_loops),
    }
    if args.terrain == "high-ground-ramp":
        entry["high_ground_side"] = args.high_ground_side
    pats = parse_csv_list(args.patterns)
    if pats:
        entry["patterns"] = pats
    upgs = parse_csv_list(args.upgrades)
    p1_upgs = parse_csv_list(args.p1_upgrades)
    p2_upgs = parse_csv_list(args.p2_upgrades)
    if upgs:
        entry["upgrades"] = upgs
    if p1_upgs:
        entry["p1_upgrades"] = p1_upgs
    if p2_upgs:
        entry["p2_upgrades"] = p2_upgs
    if args.p1_pre_cloaked:
        entry["p1_pre_cloaked"] = True
    if args.p2_pre_cloaked:
        entry["p2_pre_cloaked"] = True

    v1 = army_value(p1_units)
    v2 = army_value(p2_units)
    print(json.dumps(entry, indent=2))
    print(f"\nBalance: P1 ({args.race}) = {v1:.1f} vs P2 ({args.enemy_race}) = {v2:.1f}  (P1/P2 = {v1/max(1.0,v2):.2f}x)")

    if args.dry_run:
        print("[dry-run] Catalog not modified.")
    else:
        scenarios.append(entry)
        errs = validate_catalog(scenarios)
        if errs:
            for e in errs:
                print(f"VALIDATION ERROR: {e}", file=sys.stderr)
            return 1
        save_catalog(cat_path, scenarios)
        print(f"Added '{sid}' to {cat_path} ({len(scenarios)} total scenarios).")

    opp_flag = f" --opponent {args.opponent}" if args.opponent != "dummy" else ""
    print("\nQuick 3D preview command (~10-15s):")
    print(
        f"  python3 tools/sc2-tactics-arena.py --mode duel{opp_flag} --race {args.race} "
        f"--scenario {sid} --render-dir /tmp/arena_preview_{sid} "
        f"--out /tmp/arena_preview_{sid}/result.json"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
