#!/usr/bin/env python3
"""
Fast (<15s) repeatable replay + log forensic diff CLI between two SC2 local arena runs.

Usage:
  python3 tools/forensics-diff.py <new_run_dir> <base_run_dir>
      [--race P|T|Z] [--matchup PvP,PvT]
      [--new-score <json>] [--base-score <json>]
      [--new-pro-deep <json>] [--base-pro-deep <json>]
      [--top-flips 12] [--workers 8]
      [--out-md <path>] [--out-json <path>]
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import glob
import importlib.util
import json
import math
import os
import re
import sys
import time
import types
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PYLIBS_DIR = Path("/home/sjaconette/sc2-local-arena/pylibs")
DEFAULT_BRAIN_SCRATCH = Path(
    "/home/sjaconette/.gemini/antigravity/brain/d28d22f4-2d13-41e2-9b7b-32757f58523b/scratch"
)

RACE_SHORT = {
    "P": "Protoss",
    "T": "Terran",
    "Z": "Zerg",
    "PROTOSS": "Protoss",
    "TERRAN": "Terran",
    "ZERG": "Zerg",
}
RACE_CHAR = {"Protoss": "P", "Terran": "T", "Zerg": "Z"}

NON_COMBAT_UNITS = frozenset(
    {
        "Probe",
        "SCV",
        "Drone",
        "Overlord",
        "Overseer",
        "OverseerSiegeMode",
        "OverlordCocoon",
        "TransportOverlordCocoon",
        "Larva",
        "Egg",
        "MULE",
        "Interceptor",
        "Observer",
        "ObserverSiegeMode",
        "Changeling",
        "ChangelingZergling",
        "ChangelingZerglingWings",
        "ChangelingZealot",
        "ChangelingMarine",
        "ChangelingMarineShield",
        "Cocoon",
        "Broodling",
        "BroodlingEscort",
        "LocustMP",
        "LocustMPFlying",
        "LocustMPPrecursor",
        "CreepTumor",
        "CreepTumorBurrowed",
        "CreepTumorQueen",
        "InvisibleTargetDummy",
        "AdeptPhaseShift",
        "DisruptorPhased",
        "KD8Charge",
        "ForceField",
        "BeaconArmy",
        "BeaconDefend",
        "BeaconAttack",
        "BeaconHarass",
        "BeaconIdle",
        "BeaconAuto",
        "BeaconDetect",
        "BeaconScout",
        "BeaconClaim",
        "BeaconExpand",
        "BeaconRally",
        "BeaconCustom1",
        "BeaconCustom2",
        "BeaconCustom3",
        "BeaconCustom4",
        "MineralField",
        "MineralField750",
        "VespeneGeyser",
        "RichMineralField",
        "RichMineralField750",
    }
)

BUILDING_SUBSTRINGS = (
    "Nexus",
    "Pylon",
    "Gateway",
    "WarpGate",
    "Cybernetics",
    "Robotics",
    "Stargate",
    "Twilight",
    "Forge",
    "Photon",
    "ShieldBattery",
    "Assimilator",
    "TemplarArchive",
    "DarkShrine",
    "FleetBeacon",
    "CommandCenter",
    "Orbital",
    "Planetary",
    "SupplyDepot",
    "Barracks",
    "Factory",
    "Starport",
    "Bunker",
    "MissileTurret",
    "SensorTower",
    "EngineeringBay",
    "Armory",
    "FusionCore",
    "GhostAcademy",
    "Refinery",
    "Reactor",
    "TechLab",
    "Hatchery",
    "Lair",
    "Hive",
    "SpawningPool",
    "RoachWarren",
    "BanelingNest",
    "HydraliskDen",
    "LurkerDen",
    "Spire",
    "InfestationPit",
    "UltraliskCavern",
    "EvolutionChamber",
    "SpineCrawler",
    "SporeCrawler",
    "Extractor",
    "Nydus",
    "CreepTumor",
)

TOWNHALL_UNITS = frozenset(
    {
        "Nexus",
        "CommandCenter",
        "CommandCenterFlying",
        "OrbitalCommand",
        "OrbitalCommandFlying",
        "PlanetaryFortress",
        "Hatchery",
        "Lair",
        "Hive",
    }
)

# Verified SC2 5.0.14 s2protocol m_abilLink:m_abilCmdIndex ability mappings
ABIL_MOVE = "42:0"
ABIL_ATTACK = "45:0"
ABIL_WARP_PRISM_PHASING = "233:0"
ABIL_WARP_PRISM_TRANSPORT = "234:0"
ABIL_CREEP_TUMOR_QUEEN = "260:0"
ABIL_CREEP_TUMOR_SPREAD = "265:0"
ABIL_ENERGY_RECHARGE = "730:0"
ABIL_FORCE_FIELD = "232:0"
ABIL_SUPPLY_DROP = "113:0"
ABIL_SCAN = "139:0"
ABIL_MEDIVAC_BOOST = "404:0"
ABIL_BILE = "281:0"
ABIL_INJECT = "111:0"
ABIL_TRANSFUSE = "245:0"
ABIL_LURKER_BURROW = "303:0"
ABIL_RALLY_WORKERS = frozenset({"104:0", "105:0", "106:1"})

KEY_UNITS_TRACKED = ("Immortal", "SiegeTank", "WarpPrism", "Colossus", "Lurker")


def ensure_s2protocol_imports(pylibs_dir: str | Path) -> tuple[Any, Any]:
    """Import mpyq and s2protocol.versions cleanly on Python 3.12+ (with imp shim)."""
    pylibs_str = str(pylibs_dir)
    if pylibs_str and pylibs_str not in sys.path:
        sys.path.insert(0, pylibs_str)

    if "imp" not in sys.modules:
        imp_mod = types.ModuleType("imp")

        def _load_source(name: str, path: str) -> Any:
            spec = importlib.util.spec_from_file_location(name, path)
            if spec is None or spec.loader is None:
                raise ImportError(f"Cannot load source {name} from {path}")
            mod = importlib.util.module_from_spec(spec)
            sys.modules[name] = mod
            spec.loader.exec_module(mod)
            return mod

        def _find_module(name: str, path: list[str] | None = None) -> tuple[Any, str, tuple[str, str, int]]:
            for directory in path or sys.path:
                cand = os.path.join(directory, f"{name}.py")
                if os.path.isfile(cand):
                    return (open(cand, "r", encoding="utf-8"), cand, (".py", "r", 1))
            raise ImportError(f"No module named {name}")

        def _load_module(name: str, file_obj: Any, pathname: str, _description: Any) -> Any:
            if file_obj is not None:
                try:
                    file_obj.close()
                except Exception:
                    pass
            return _load_source(name, pathname)

        imp_mod.load_source = _load_source  # type: ignore[attr-defined]
        imp_mod.find_module = _find_module  # type: ignore[attr-defined]
        imp_mod.load_module = _load_module  # type: ignore[attr-defined]
        sys.modules["imp"] = imp_mod

    import mpyq  # type: ignore[import-not-found]
    from s2protocol import versions  # type: ignore[import-not-found]

    return mpyq, versions


def _decode_str(val: Any) -> str:
    if isinstance(val, bytes):
        return val.decode("utf-8", errors="replace")
    return str(val)


def is_combat_unit_name(ut: str) -> bool:
    if ut in NON_COMBAT_UNITS:
        return False
    for sub in BUILDING_SUBSTRINGS:
        if sub in ut:
            return False
    return True


def _normalize_race(val: str | None) -> str:
    if not val:
        return ""
    up = str(val).strip().upper()
    if up in RACE_SHORT:
        return RACE_SHORT[up]
    if up[:1] in RACE_SHORT:
        return RACE_SHORT[up[:1]]
    return str(val).strip()


def _normalize_result(val: Any) -> str:
    if val is None:
        return "unknown"
    s = str(val).strip().lower()
    if s in ("win", "victory", "w", "1", "bot1"):
        return "win"
    if s in ("loss", "defeat", "lose", "l", "2", "bot2"):
        return "loss"
    if s in ("tie", "draw", "t", "0"):
        return "tie"
    return s


def _infer_label_from_run_dir(run_dir: Path) -> str:
    name = run_dir.name
    # Strip YYYYMMDD_HHMMSS_ prefix if present
    m = re.match(r"^\d{8}_\d{6}_(.+)$", name)
    return m.group(1) if m else name


def _auto_find_score_json(run_dir: Path, explicit: str | None) -> Path | None:
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    label = _infer_label_from_run_dir(run_dir)
    cands = [
        run_dir / "score.json",
        run_dir / f"{label}_score.json",
        DEFAULT_BRAIN_SCRATCH / f"{label}_score.json",
        REPO_ROOT / "scratch" / f"{label}_score.json",
    ]
    for c in cands:
        if c.is_file():
            return c
    return None


def _auto_find_pro_deep_json(run_dir: Path, explicit: str | None) -> Path | None:
    if explicit:
        p = Path(explicit)
        return p if p.is_file() else None
    label = _infer_label_from_run_dir(run_dir)
    cands = [
        run_dir / "pro_deep.json",
        DEFAULT_BRAIN_SCRATCH / "loop" / label / "pro_deep.json",
        REPO_ROOT / "scratch" / "loop" / label / "pro_deep.json",
    ]
    for c in cands:
        if c.is_file():
            return c
    return None


def _extract_match_num_from_path(path_str: str) -> int | None:
    base = os.path.basename(path_str or "")
    m = re.match(r"^(\d+)_", base)
    return int(m.group(1)) if m else None


def _load_score_index(score_path: Path | None) -> dict[int, dict[str, Any]]:
    """Index score-replay-batch.rkt JSON matches by 1-based match index."""
    if not score_path or not score_path.is_file():
        return {}
    data = json.loads(score_path.read_text(encoding="utf-8"))
    out: dict[int, dict[str, Any]] = {}
    for idx, m in enumerate(data.get("matches", []), 1):
        mid = _extract_match_num_from_path(str(m.get("file", ""))) or int(m.get("id") or idx)
        out[mid] = m
    return out


def _find_bot1_log(run_dir: Path, mid: int, bot1_name: str, replay_path: str) -> Path | None:
    logs_dir = run_dir / "logs"
    if not logs_dir.is_dir():
        return None
    stem = Path(replay_path).stem if replay_path else ""
    if stem:
        exact = logs_dir / f"{stem}_{bot1_name}.log"
        if exact.is_file():
            return exact
    cands = sorted(logs_dir.glob(f"{mid:03d}_*_{bot1_name}.log"))
    if cands:
        return cands[0]
    # Fallback: any non-controller, non-base log matching bot1 prefix
    for cand in sorted(logs_dir.glob(f"{mid:03d}_*.log")):
        bn = cand.name
        if "controller" in bn.lower():
            continue
        if bn.endswith(f"_{bot1_name}.log"):
            return cand
    return None


def load_run_matches(run_dir: Path, score_path: Path | None) -> list[dict[str, Any]]:
    """Merge results.json and optional score.json into normalized per-match records."""
    res_path = run_dir / "results.json"
    score_by_id = _load_score_index(score_path)
    records: list[dict[str, Any]] = []

    if res_path.is_file():
        rj = json.loads(res_path.read_text(encoding="utf-8"))
        raw_matches = rj.get("matches", [])
        for idx, m in enumerate(raw_matches, 1):
            mid = int(m.get("match_id") or m.get("index") or m.get("id") or idx)
            sc = score_by_id.get(mid, {})
            bot1 = str(m.get("bot1_name") or m.get("bot1") or sc.get("our_bot") or "Mothman")
            bot2 = str(m.get("bot2_name") or m.get("bot2") or sc.get("opp_bot") or "Opponent")
            r1 = _normalize_race(m.get("bot1_race") or sc.get("our_race"))
            r2 = _normalize_race(m.get("bot2_race") or sc.get("opp_race"))
            mu = str(sc.get("matchup") or (f"{RACE_CHAR.get(r1, '?')}v{RACE_CHAR.get(r2, '?')}" if r1 and r2 else ""))
            res = _normalize_result(sc.get("result") or m.get("bot1_result") or m.get("result"))
            rp = str(m.get("replay_path") or "")
            if rp and not os.path.isabs(rp):
                rp = str(run_dir / rp)
            if (not rp or not os.path.isfile(rp)) and (run_dir / "replays").is_dir():
                cands = sorted((run_dir / "replays").glob(f"{mid:03d}_*.SC2Replay"))
                rp = str(cands[0]) if cands else rp
            log_p = _find_bot1_log(run_dir, mid, bot1, rp)
            anoms = sorted(k for k, v in (sc.get("anomalies") or {}).items() if v)
            is_selfplay = bool(sc.get("is_selfplay")) or (
                str(m.get("cohort", "")).lower() == "self"
                or (bot1.split("-")[0] == bot2.split("-")[0] and bot2 != "Opponent")
            )
            records.append(
                {
                    "match_id": mid,
                    "bot1": bot1,
                    "bot2": bot2,
                    "our_race": r1,
                    "opp_race": r2,
                    "matchup": mu,
                    "result": res,
                    "is_selfplay": is_selfplay,
                    "map_name": str(m.get("map_name") or sc.get("map_name") or ""),
                    "replay_path": rp,
                    "log_path": str(log_p) if log_p else "",
                    "trade_ratio": sc.get("trade_ratio"),
                    "min_collected_ratio": sc.get("min_collected_ratio"),
                    "gas_collected_ratio": sc.get("gas_collected_ratio"),
                    "our_w4": sc.get("our_w4"),
                    "opp_w4": sc.get("opp_w4"),
                    "our_w6": sc.get("our_w6"),
                    "opp_w6": sc.get("opp_w6"),
                    "our_peak_army": sc.get("our_peak_army"),
                    "opp_peak_army": sc.get("opp_peak_army"),
                    "duration_sec": sc.get("duration_sec") or m.get("game_time_sec"),
                    "wall_sec": sc.get("wall_sec") or m.get("wall_sec") or m.get("elapsed_sec"),
                    "timed_out": bool(sc.get("wall_timeout_tie") or m.get("timed_out") or m.get("wall_timeout")),
                    "anomalies": anoms,
                }
            )
    elif score_by_id:
        for mid, sc in sorted(score_by_id.items()):
            bot1 = str(sc.get("our_bot") or "Mothman")
            bot2 = str(sc.get("opp_bot") or "Opponent")
            r1 = _normalize_race(sc.get("our_race"))
            r2 = _normalize_race(sc.get("opp_race"))
            mu = str(sc.get("matchup") or f"{RACE_CHAR.get(r1, '?')}v{RACE_CHAR.get(r2, '?')}")
            rp_rel = str(sc.get("file") or "")
            rp = str(run_dir / "replays" / os.path.basename(rp_rel)) if rp_rel else ""
            log_p = _find_bot1_log(run_dir, mid, bot1, rp)
            anoms = sorted(k for k, v in (sc.get("anomalies") or {}).items() if v)
            records.append(
                {
                    "match_id": mid,
                    "bot1": bot1,
                    "bot2": bot2,
                    "our_race": r1,
                    "opp_race": r2,
                    "matchup": mu,
                    "result": _normalize_result(sc.get("result")),
                    "is_selfplay": bool(sc.get("is_selfplay")),
                    "map_name": str(sc.get("map_name") or ""),
                    "replay_path": rp,
                    "log_path": str(log_p) if log_p else "",
                    "trade_ratio": sc.get("trade_ratio"),
                    "min_collected_ratio": sc.get("min_collected_ratio"),
                    "gas_collected_ratio": sc.get("gas_collected_ratio"),
                    "our_w4": sc.get("our_w4"),
                    "opp_w4": sc.get("opp_w4"),
                    "our_w6": sc.get("our_w6"),
                    "opp_w6": sc.get("opp_w6"),
                    "our_peak_army": sc.get("our_peak_army"),
                    "opp_peak_army": sc.get("opp_peak_army"),
                    "duration_sec": sc.get("duration_sec"),
                    "wall_sec": sc.get("wall_sec"),
                    "timed_out": bool(sc.get("wall_timeout_tie")),
                    "anomalies": anoms,
                }
            )
    return records


def pair_run_matches(
    new_matches: list[dict[str, Any]],
    base_matches: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Pair matches across runs by (bot1, bot2, occurrence_idx), handling random opponent race rolls."""
    new_groups: dict[tuple[str, str], list[dict[str, Any]]] = collections.defaultdict(list)
    base_groups: dict[tuple[str, str], list[dict[str, Any]]] = collections.defaultdict(list)
    for m in sorted(new_matches, key=lambda x: x["match_id"]):
        new_groups[(m["bot1"], m["bot2"])].append(m)
    for m in sorted(base_matches, key=lambda x: x["match_id"]):
        base_groups[(m["bot1"], m["bot2"])].append(m)

    pairs: list[dict[str, Any]] = []
    for key in sorted(set(new_groups.keys()) | set(base_groups.keys())):
        nl = new_groups.get(key, [])
        bl = base_groups.get(key, [])
        # When multiple games exist for the same (bot1, bot2), align by match_id if possible first
        used_b: set[int] = set()
        for nm in nl:
            chosen_bi: int | None = None
            for bi, bm in enumerate(bl):
                if bi in used_b:
                    continue
                if bm["match_id"] == nm["match_id"]:
                    chosen_bi = bi
                    break
            if chosen_bi is None:
                for bi, bm in enumerate(bl):
                    if bi not in used_b:
                        chosen_bi = bi
                        break
            bm = bl[chosen_bi] if chosen_bi is not None else None
            if chosen_bi is not None:
                used_b.add(chosen_bi)
            race_roll_changed = bool(
                bm and nm.get("opp_race") and bm.get("opp_race") and nm["opp_race"] != bm["opp_race"]
            )
            pairs.append(
                {
                    "bot1": key[0],
                    "bot2": key[1],
                    "new": nm,
                    "base": bm,
                    "race_roll_changed": race_roll_changed,
                }
            )
        for bi, bm in enumerate(bl):
            if bi not in used_b:
                pairs.append(
                    {
                        "bot1": key[0],
                        "bot2": key[1],
                        "new": None,
                        "base": bm,
                        "race_roll_changed": False,
                    }
                )
    pairs.sort(key=lambda p: (p["new"]["match_id"] if p["new"] else 999999, p["bot1"], p["bot2"]))
    return pairs


def parse_bot1_log_summary(log_path: str) -> dict[str, Any]:
    """Extract top saving_for=, bo=, arch=, and longest escrow streak from bot1.log."""
    empty = {
        "pri_lines": 0,
        "state_lines": 0,
        "top_saving_for": [],
        "top_bo": [],
        "top_arch": [],
        "longest_saving_streak": None,
    }
    if not log_path or not os.path.isfile(log_path):
        return empty
    saving_cnt: collections.Counter[str] = collections.Counter()
    bo_cnt: collections.Counter[str] = collections.Counter()
    arch_cnt: collections.Counter[str] = collections.Counter()
    pri_lines = 0
    state_lines = 0
    best_streak: tuple[int, str, float, float] | None = None
    cur_item: str | None = None
    cur_start_s = 0.0
    cur_end_s = 0.0
    cur_len = 0

    re_frame = re.compile(r"\bf=(\d+)")
    re_saving = re.compile(r"\bsaving_for=([^\s(]+)")
    re_bo = re.compile(r"\bbo=([^\s]+)")
    re_arch = re.compile(r"\barch=([^\s]+)")

    with open(log_path, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            if "[SCBOT_PRIORITY]" in line:
                pri_lines += 1
                m_sf = re_saving.search(line)
                sf_item = m_sf.group(1) if m_sf else "none"
                if sf_item != "none":
                    saving_cnt[sf_item] += 1
                m_bo = re_bo.search(line)
                if m_bo and m_bo.group(1) != "none":
                    bo_cnt[m_bo.group(1)] += 1
                m_f = re_frame.search(line)
                sec = int(m_f.group(1)) / 22.4 if m_f else 0.0
                if sf_item != "none" and sf_item == cur_item:
                    cur_len += 1
                    cur_end_s = sec
                else:
                    if cur_item and cur_len > 0:
                        if best_streak is None or cur_len > best_streak[0]:
                            best_streak = (cur_len, cur_item, cur_start_s, cur_end_s)
                    if sf_item != "none":
                        cur_item = sf_item
                        cur_start_s = sec
                        cur_end_s = sec
                        cur_len = 1
                    else:
                        cur_item = None
                        cur_len = 0
            elif "[SCBOT_STATE]" in line:
                state_lines += 1
                m_ar = re_arch.search(line)
                if m_ar:
                    arch_cnt[m_ar.group(1)] += 1

    if cur_item and cur_len > 0:
        if best_streak is None or cur_len > best_streak[0]:
            best_streak = (cur_len, cur_item, cur_start_s, cur_end_s)

    return {
        "pri_lines": pri_lines,
        "state_lines": state_lines,
        "top_saving_for": saving_cnt.most_common(5),
        "top_bo": bo_cnt.most_common(5),
        "top_arch": arch_cnt.most_common(3),
        "longest_saving_streak": (
            {
                "ticks": best_streak[0],
                "item": best_streak[1],
                "start_sec": round(best_streak[2], 1),
                "end_sec": round(best_streak[3], 1),
            }
            if best_streak
            else None
        ),
    }


def extract_replay_forensics_worker(task: tuple[str, str, str]) -> dict[str, Any]:
    """ProcessPool worker: extract s2protocol commands/features + bot1.log summary for one match."""
    replay_path, log_path, pylibs_dir = task
    log_summary = parse_bot1_log_summary(log_path)
    out: dict[str, Any] = {
        "replay_path": replay_path,
        "ok": False,
        "error": None,
        "duration_sec": 0.0,
        "cmds": {
            "move_total": 0,
            "move_home": 0,
            "move_fwd": 0,
            "move_squad": 0,
            "move_squad_home": 0,
            "atk_total": 0,
            "atk_home": 0,
            "atk_fwd": 0,
            "atk_squad": 0,
            "atk_squad_home": 0,
        },
        "warp_prism": {
            "born": 0,
            "moves": 0,
            "phasing_cmds": 0,
            "phasing_changes": 0,
            "transport_cmds": 0,
            "fwd_warp_zealots": 0,
            "fwd_warp_all": 0,
        },
        "creep": {
            "tumor_queen_cmds": 0,
            "tumor_spread_cmds": 0,
            "tumor_queen_born": 0,
            "tumor_spread_born": 0,
            "hatch_init": 0,
            "hatch_canceled": 0,
        },
        "key_units_p1": {k: 0 for k in KEY_UNITS_TRACKED},
        "key_units_p2": {k: 0 for k in KEY_UNITS_TRACKED},
        "p1_combat_dead": 0,
        "p2_combat_dead": 0,
        "p1_top_units": [],
        "p2_top_units": [],
        "log": log_summary,
    }
    if not replay_path or not os.path.isfile(replay_path):
        out["error"] = "missing_replay"
        return out

    try:
        mpyq, versions = ensure_s2protocol_imports(pylibs_dir)
        arch = mpyq.MPQArchive(replay_path)
        header = versions.latest().decode_replay_header(arch.header["user_data_header"]["content"])
        proto = versions.build(header["m_dataBuildNum"])
        tevs = proto.decode_replay_tracker_events(arch.read_file("replay.tracker.events"))
        gevs = proto.decode_replay_game_events(arch.read_file("replay.game.events"))

        units: dict[int, list[Any]] = {}  # uid -> [pid, ut, born_t]
        main_xy: tuple[float, float] | None = None
        prism_uids: set[int] = set()
        hatch_init_uids: set[int] = set()
        hatch_done_uids: set[int] = set()
        p1_units: collections.Counter[str] = collections.Counter()
        p2_units: collections.Counter[str] = collections.Counter()
        max_loop = 0

        for e in tevs:
            gl = int(e.get("_gameloop", 0))
            if gl > max_loop:
                max_loop = gl
            et = e["_event"]
            if et == "NNet.Replay.Tracker.SUnitBornEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                pid = int(e["m_controlPlayerId"])
                ut = _decode_str(e["m_unitTypeName"])
                units[uid] = [pid, ut, gl / 22.4]
                if pid == 1 and ut in TOWNHALL_UNITS and main_xy is None:
                    main_xy = (float(e["m_x"]), float(e["m_y"]))
                if pid == 1:
                    if ut == "WarpPrism":
                        prism_uids.add(uid)
                        out["warp_prism"]["born"] += 1
                        out["key_units_p1"]["WarpPrism"] += 1
                    elif ut == "Immortal":
                        out["key_units_p1"]["Immortal"] += 1
                    elif ut in ("SiegeTank", "SiegeTankSieged"):
                        out["key_units_p1"]["SiegeTank"] += 1
                    elif ut == "Colossus":
                        out["key_units_p1"]["Colossus"] += 1
                    elif ut in ("LurkerMP", "LurkerMPEgg"):
                        out["key_units_p1"]["Lurker"] += 1
                    elif ut == "CreepTumorQueen":
                        out["creep"]["tumor_queen_born"] += 1
                    elif ut == "CreepTumor":
                        out["creep"]["tumor_spread_born"] += 1
                    if is_combat_unit_name(ut):
                        p1_units[ut] += 1
                elif pid == 2:
                    if ut == "WarpPrism":
                        out["key_units_p2"]["WarpPrism"] += 1
                    elif ut == "Immortal":
                        out["key_units_p2"]["Immortal"] += 1
                    elif ut in ("SiegeTank", "SiegeTankSieged"):
                        out["key_units_p2"]["SiegeTank"] += 1
                    elif ut == "Colossus":
                        out["key_units_p2"]["Colossus"] += 1
                    elif ut in ("LurkerMP", "LurkerMPEgg"):
                        out["key_units_p2"]["Lurker"] += 1
                    if is_combat_unit_name(ut):
                        p2_units[ut] += 1
            elif et == "NNet.Replay.Tracker.SUnitInitEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                pid = int(e["m_controlPlayerId"])
                ut = _decode_str(e["m_unitTypeName"])
                units[uid] = [pid, ut, gl / 22.4]
                if pid == 1:
                    if ut == "Hatchery":
                        hatch_init_uids.add(uid)
                        out["creep"]["hatch_init"] += 1
                    elif ut == "CreepTumorQueen":
                        out["creep"]["tumor_queen_born"] += 1
                    elif ut == "CreepTumor":
                        out["creep"]["tumor_spread_born"] += 1
                    elif ut in ("Zealot", "Stalker", "Sentry", "Adept", "HighTemplar", "DarkTemplar"):
                        if is_combat_unit_name(ut):
                            p1_units[ut] += 1
                        if main_xy is not None:
                            dh = math.hypot(float(e["m_x"]) - main_xy[0], float(e["m_y"]) - main_xy[1])
                            if dh > 30.0:
                                out["warp_prism"]["fwd_warp_all"] += 1
                                if ut == "Zealot":
                                    out["warp_prism"]["fwd_warp_zealots"] += 1
                elif pid == 2 and is_combat_unit_name(ut):
                    p2_units[ut] += 1
            elif et == "NNet.Replay.Tracker.SUnitDoneEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                if uid in hatch_init_uids:
                    hatch_done_uids.add(uid)
            elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                ut = _decode_str(e["m_unitTypeName"])
                prev = units.get(uid)
                if prev is not None:
                    pid, prev_ut, _ = prev
                    if pid == 1 and ut == "WarpPrismPhasing":
                        prism_uids.add(uid)
                        out["warp_prism"]["phasing_changes"] += 1
                    if ut == "LurkerMP" and prev_ut == "LurkerMPEgg":
                        pass  # already counted at egg
                    elif ut == "LurkerMPEgg" and prev_ut != "LurkerMPEgg":
                        if pid == 1:
                            out["key_units_p1"]["Lurker"] += 1
                        elif pid == 2:
                            out["key_units_p2"]["Lurker"] += 1
                    prev[1] = ut
            elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                if uid in hatch_init_uids and uid not in hatch_done_uids:
                    kpid = e.get("m_killerPlayerId")
                    if kpid in (None, 1):
                        out["creep"]["hatch_canceled"] += 1
                info = units.get(uid)
                if info is not None and is_combat_unit_name(info[1]):
                    if info[0] == 1:
                        out["p1_combat_dead"] += 1
                    elif info[0] == 2:
                        out["p2_combat_dead"] += 1

        sel_tags: list[int] = []
        for e in gevs:
            uid_info = e.get("_userid")
            if not uid_info or uid_info.get("m_userId") != 0:
                continue
            et = e["_event"]
            if et == "NNet.Game.SSelectionDeltaEvent":
                sel_tags = list(e.get("m_delta", {}).get("m_addUnitTags", []))
            elif et == "NNet.Game.SCmdEvent":
                ab = e.get("m_abil")
                if not ab:
                    continue
                key = f"{ab['m_abilLink']}:{ab['m_abilCmdIndex']}"
                if key == ABIL_CREEP_TUMOR_QUEEN:
                    out["creep"]["tumor_queen_cmds"] += 1
                elif key == ABIL_CREEP_TUMOR_SPREAD:
                    out["creep"]["tumor_spread_cmds"] += 1
                elif key == ABIL_WARP_PRISM_PHASING:
                    out["warp_prism"]["phasing_cmds"] += 1
                elif key == ABIL_WARP_PRISM_TRANSPORT:
                    out["warp_prism"]["transport_cmds"] += 1

                if prism_uids and sel_tags and any(t in prism_uids for t in sel_tags):
                    if key == ABIL_MOVE:
                        out["warp_prism"]["moves"] += 1

                if key in (ABIL_MOVE, ABIL_ATTACK):
                    pt = e.get("m_data", {}).get("TargetPoint")
                    dh = (
                        math.hypot(pt["x"] / 4096.0 - main_xy[0], pt["y"] / 4096.0 - main_xy[1])
                        if (pt and main_xy is not None)
                        else 999.0
                    )
                    is_home = dh <= 28.0
                    is_squad = len(sel_tags) >= 2
                    if key == ABIL_MOVE:
                        out["cmds"]["move_total"] += 1
                        if is_home:
                            out["cmds"]["move_home"] += 1
                        else:
                            out["cmds"]["move_fwd"] += 1
                        if is_squad:
                            out["cmds"]["move_squad"] += 1
                            if is_home:
                                out["cmds"]["move_squad_home"] += 1
                    else:
                        out["cmds"]["atk_total"] += 1
                        if is_home:
                            out["cmds"]["atk_home"] += 1
                        else:
                            out["cmds"]["atk_fwd"] += 1
                        if is_squad:
                            out["cmds"]["atk_squad"] += 1
                            if is_home:
                                out["cmds"]["atk_squad_home"] += 1

        out["duration_sec"] = round(max_loop / 22.4, 1)
        out["p1_top_units"] = p1_units.most_common(5)
        out["p2_top_units"] = p2_units.most_common(5)
        out["ok"] = True
    except Exception as exc:
        out["error"] = f"{type(exc).__name__}: {exc}"
    return out


def _summarize_group(matches: list[dict[str, Any]]) -> dict[str, Any]:
    w = sum(1 for m in matches if m["result"] == "win")
    l = sum(1 for m in matches if m["result"] == "loss")
    t = sum(1 for m in matches if m["result"] == "tie")
    n = len(matches)
    trs = [float(m["trade_ratio"]) for m in matches if isinstance(m.get("trade_ratio"), (int, float))]
    mins = [float(m["min_collected_ratio"]) for m in matches if isinstance(m.get("min_collected_ratio"), (int, float))]
    gases = [float(m["gas_collected_ratio"]) for m in matches if isinstance(m.get("gas_collected_ratio"), (int, float))]
    pkas = [float(m["our_peak_army"]) for m in matches if isinstance(m.get("our_peak_army"), (int, float))]
    return {
        "n": n,
        "w": w,
        "l": l,
        "t": t,
        "wr_pct": round(100.0 * w / n, 1) if n else 0.0,
        "nl_pct": round(100.0 * (w + t) / n, 1) if n else 0.0,
        "avg_tr": round(sum(trs) / len(trs), 2) if trs else None,
        "avg_min": round(sum(mins) / len(mins), 2) if mins else None,
        "avg_gas": round(sum(gases) / len(gases), 2) if gases else None,
        "avg_pka": round(sum(pkas) / len(pkas), 0) if pkas else None,
    }


def _extract_pro_deep_slice(pd_json: dict[str, Any] | None, group_key: str, by_race: bool) -> dict[str, Any]:
    """Pull ReinfLinked, Trickle, Diseng, Ann, Concave wrap/sep/inv/inR from pro_deep.json."""
    if not pd_json:
        return {}
    if by_race:
        src = (pd_json.get("by_race") or {}).get(group_key, {}).get("mothman", {})
    else:
        src = (pd_json.get("by_matchup") or {}).get(group_key, {}).get("mothman", {})
    ag = src.get("army_group_positioning") or {}
    cm = src.get("combat_positioning") or {}
    if not ag and not cm:
        return {}
    return {
        "reinf_pct": ag.get("reinforce_linked_pct"),
        "trickle_pct": ag.get("solo_trickle_death_pct"),
        "diseng_pct": ag.get("disengage_and_regroup_pct"),
        "ann_pct": ag.get("fight_to_annihilation_pct"),
        "wrap": cm.get("concave_wrap_score"),
        "sep": cm.get("front_to_rear_separation_t"),
        "inv_pct": cm.get("role_inversion_pct"),
        "in_range_pct": cm.get("in_range_pct"),
    }


def _fmt_num(v: Any, suffix: str = "", digits: int = 1) -> str:
    if v is None:
        return "-"
    if isinstance(v, (int, float)):
        return f"{v:.{digits}f}{suffix}"
    return str(v)


def _fmt_delta(new_v: Any, base_v: Any, suffix: str = "", digits: int = 1) -> str:
    if new_v is None and base_v is None:
        return "-"
    if base_v is None:
        return _fmt_num(new_v, suffix, digits)
    if new_v is None:
        return f"{_fmt_num(base_v, suffix, digits)} -> -"
    return f"{base_v:.{digits}f} -> {new_v:.{digits}f}{suffix}"


def _filter_matches(
    matches: list[dict[str, Any]],
    races: set[str],
    matchups: set[str],
    include_selfplay: bool,
) -> list[dict[str, Any]]:
    out = []
    for m in matches:
        if not include_selfplay and m.get("is_selfplay"):
            continue
        if races and m.get("our_race") not in races:
            continue
        if matchups and m.get("matchup") not in matchups:
            continue
        out.append(m)
    return out


def render_markdown(report: dict[str, Any]) -> str:
    lines: list[str] = []
    meta = report["meta"]
    lines.append(f"# Forensics Diff: `{meta['new_label']}` vs `{meta['base_label']}`")
    lines.append("")
    filt = []
    if meta.get("races"):
        filt.append(f"race={','.join(meta['races'])}")
    if meta.get("matchups"):
        filt.append(f"matchup={','.join(meta['matchups'])}")
    filt_str = " | ".join(filt) if filt else "all races/matchups"
    roll_changes = sum(1 for p in report["flips_w_to_l"] + report["flips_l_to_w"] + report["flips_other"] if p.get("race_roll_changed"))
    all_roll_changes = meta.get("race_roll_changes", roll_changes)
    lines.append(
        f"- **Scope:** {filt_str} | **Matched pairs:** {meta['paired_count']} "
        f"(race rolls changed: {all_roll_changes}) | "
        f"**Flips:** `W->L: {len(report['flips_w_to_l'])}`, `L->W: {len(report['flips_l_to_w'])}`, "
        f"`other: {len(report['flips_other'])}` | **Elapsed:** `{meta['elapsed_sec']:.2f}s`"
    )
    ov_n = report["overall"]["new"]
    ov_b = report["overall"]["base"]
    lines.append(
        f"- **Overall:** `{ov_b['w']}-{ov_b['l']}-{ov_b['t']}` ({ov_b['wr_pct']}% WR / {ov_b['nl_pct']}% NL, "
        f"Tr {_fmt_num(ov_b['avg_tr'], 'x', 2)}) -> **`{ov_n['w']}-{ov_n['l']}-{ov_n['t']}` "
        f"({ov_n['wr_pct']}% WR / {ov_n['nl_pct']}% NL, Tr {_fmt_num(ov_n['avg_tr'], 'x', 2)})** "
        f"(`dW={ov_n['w'] - ov_b['w']:+d}`)"
    )
    lines.append("")

    # Per-race delta table
    lines.append("## Per-Race & Per-Matchup Delta Table")
    lines.append("")
    lines.append(
        "| Group | Base W-L-T | New W-L-T | dW | Avg Tr (B->N) | Reinf% (B->N) | Trickle% (B->N) | Diseng% (B->N) | Wrap / Sep / Inv% / InR% (N) |"
    )
    lines.append("|---|---|---|---:|---|---|---|---|---|")
    for section_key in ("by_race", "by_matchup"):
        for grp_name, entry in sorted(report[section_key].items()):
            b = entry["base"]
            n = entry["new"]
            pb = entry.get("pro_deep_base") or {}
            pn = entry.get("pro_deep_new") or {}
            cm_str = (
                f"{_fmt_num(pn.get('wrap'), 't', 2)} / {_fmt_num(pn.get('sep'), 't', 1)} / "
                f"{_fmt_num(pn.get('inv_pct'), '%', 1)} / {_fmt_num(pn.get('in_range_pct'), '%', 1)}"
                if pn
                else "-"
            )
            lines.append(
                f"| `{grp_name}` | `{b['w']}-{b['l']}-{b['t']}` | `{n['w']}-{n['l']}-{n['t']}` | "
                f"`{n['w'] - b['w']:+d}` | {_fmt_delta(n['avg_tr'], b['avg_tr'], 'x', 2)} | "
                f"{_fmt_delta(pn.get('reinf_pct'), pb.get('reinf_pct'), '%')} | "
                f"{_fmt_delta(pn.get('trickle_pct'), pb.get('trickle_pct'), '%')} | "
                f"{_fmt_delta(pn.get('diseng_pct'), pb.get('diseng_pct'), '%')} | {cm_str} |"
            )
    lines.append("")

    def _emit_flip_table(title: str, rows: list[dict[str, Any]]) -> None:
        lines.append(f"## {title} ({len(rows)})")
        lines.append("")
        if not rows:
            lines.append("_None._")
            lines.append("")
            return
        lines.append(
            "| # | MU | Opponent | Base | New | MinCol | Gas | W4 | W6 | PkA | Wall | Anomalies (New) |"
        )
        lines.append("|---:|---|---|---|---|---:|---:|---|---|---:|---:|---|")
        for r in rows:
            nm = r["new"]
            bm = r["base"]
            roll_tag = " [roll!]" if r.get("race_roll_changed") else ""
            b_str = f"{bm['result'][0].upper()} {_fmt_num(bm.get('trade_ratio'), 'x', 2)}" if bm else "-"
            n_str = f"{nm['result'][0].upper()} {_fmt_num(nm.get('trade_ratio'), 'x', 2)}" if nm else "-"
            w4 = f"{nm.get('our_w4')}/{nm.get('opp_w4')}" if nm and nm.get("our_w4") is not None else "-"
            w6 = f"{nm.get('our_w6')}/{nm.get('opp_w6')}" if nm and nm.get("our_w6") is not None else "-"
            wall = f"{nm['wall_sec']:.0f}s{'(T)' if nm.get('timed_out') else ''}" if nm and nm.get("wall_sec") else "-"
            anoms = ", ".join(nm.get("anomalies") or []) if nm else ""
            lines.append(
                f"| #{nm['match_id'] if nm else '-'} | {nm['matchup'] if nm else '-'}{roll_tag} | "
                f"{r['bot2']} | {b_str} | {n_str} | {_fmt_num(nm.get('min_collected_ratio') if nm else None, 'x', 2)} | "
                f"{_fmt_num(nm.get('gas_collected_ratio') if nm else None, 'x', 2)} | {w4} | {w6} | "
                f"{_fmt_num(nm.get('our_peak_army') if nm else None, '', 0)} | {wall} | {anoms or '-'} |"
            )
        lines.append("")

    _emit_flip_table("W -> L Regressions", report["flips_w_to_l"])
    _emit_flip_table("L -> W Improvements", report["flips_l_to_w"])
    if report["flips_other"]:
        _emit_flip_table("Other Outcome Changes (Ties)", report["flips_other"])

    # Deep s2protocol + log audit for top W->L flips
    deep = report.get("deep_w_to_l_flips") or []
    lines.append(f"## Deep Replay + Log Forensics (Top {len(deep)} W -> L Flips)")
    lines.append("")
    if not deep:
        lines.append("_No W -> L flips to audit._")
        lines.append("")
    for item in deep:
        nm = item["new_match"]
        nf = item["new_forensics"]
        bf = item.get("base_forensics")
        lines.append(
            f"### #{nm['match_id']} {nm['matchup']} vs `{item['bot2']}` "
            f"(`{item['base_res']}` {_fmt_num(item['base_tr'], 'x', 2)} -> `{nm['result']}` {_fmt_num(nm.get('trade_ratio'), 'x', 2)})"
        )
        for tag, f in (("NEW", nf), ("BASE", bf)):
            if not f:
                continue
            c = f["cmds"]
            wp = f["warp_prism"]
            cr = f["creep"]
            ku = f["key_units_p1"]
            lg = f["log"]
            ku_str = " ".join(f"{k}={ku[k]}" for k in KEY_UNITS_TRACKED if ku.get(k, 0) > 0) or "none"
            sf_str = ", ".join(f"{k}:{v}" for k, v in lg["top_saving_for"][:4]) or "none"
            bo_str = ", ".join(f"{k}:{v}" for k, v in lg["top_bo"][:4]) or "none"
            streak = lg.get("longest_saving_streak")
            st_str = (
                f" | max_streak={streak['item']}({streak['ticks']}t, {streak['start_sec']:.0f}-{streak['end_sec']:.0f}s)"
                if streak
                else ""
            )
            lines.append(
                f"- **{tag}** (`{f['duration_sec']:.0f}s`, dead P1/P2=`{f['p1_combat_dead']}/{f['p2_combat_dead']}`): "
                f"`42:0 MOVE={c['move_total']}(h:{c['move_home']},fwd:{c['move_fwd']},sqH:{c['move_squad_home']})` "
                f"`45:0 ATK={c['atk_total']}(h:{c['atk_home']},fwd:{c['atk_fwd']},sqH:{c['atk_squad_home']})` | "
                f"KeyUnits: `{ku_str}` | Prism: born={wp['born']} mv={wp['moves']} ph={wp['phasing_changes']}/{wp['phasing_cmds']} fwdZ={wp['fwd_warp_zealots']} | "
                f"Creep: q={cr['tumor_queen_cmds']} sp={cr['tumor_spread_cmds']} hatch={cr['hatch_init']}(cancel:{cr['hatch_canceled']})"
            )
            lines.append(
                f"  - Log (`PRI={lg['pri_lines']}`): `saving_for=[{sf_str}]` | `bo=[{bo_str}]`{st_str}"
            )
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def run_forensics_diff(
    new_run_dir: Path,
    base_run_dir: Path,
    *,
    races: set[str] | None = None,
    matchups: set[str] | None = None,
    new_score_path: Path | None = None,
    base_score_path: Path | None = None,
    new_pro_deep_path: Path | None = None,
    base_pro_deep_path: Path | None = None,
    include_selfplay: bool = False,
    top_flips: int = 12,
    workers: int = 8,
    pylibs_dir: Path = DEFAULT_PYLIBS_DIR,
) -> dict[str, Any]:
    t0 = time.monotonic()
    races = races or set()
    matchups = matchups or set()

    new_score = _auto_find_score_json(new_run_dir, str(new_score_path) if new_score_path else None)
    base_score = _auto_find_score_json(base_run_dir, str(base_score_path) if base_score_path else None)
    new_pd_path = _auto_find_pro_deep_json(new_run_dir, str(new_pro_deep_path) if new_pro_deep_path else None)
    base_pd_path = _auto_find_pro_deep_json(base_run_dir, str(base_pro_deep_path) if base_pro_deep_path else None)

    new_pd = json.loads(new_pd_path.read_text(encoding="utf-8")) if new_pd_path else None
    base_pd = json.loads(base_pd_path.read_text(encoding="utf-8")) if base_pd_path else None

    new_all = load_run_matches(new_run_dir, new_score)
    base_all = load_run_matches(base_run_dir, base_score)

    # Auto-include selfplay if ALL matches in the run are selfplay (e.g. H2H_12!)
    effective_include_sp = include_selfplay or (bool(new_all) and all(m["is_selfplay"] for m in new_all))
    new_f = _filter_matches(new_all, races, matchups, effective_include_sp)
    base_f = _filter_matches(base_all, races, matchups, effective_include_sp)
    pairs = pair_run_matches(new_f, base_f)

    flips_w_to_l: list[dict[str, Any]] = []
    flips_l_to_w: list[dict[str, Any]] = []
    flips_other: list[dict[str, Any]] = []

    for p in pairs:
        nm = p["new"]
        bm = p["base"]
        if not nm or not bm:
            continue
        br = bm["result"]
        nr = nm["result"]
        if br == nr:
            continue
        if br == "win" and nr == "loss":
            flips_w_to_l.append(p)
        elif br == "loss" and nr == "win":
            flips_l_to_w.append(p)
        else:
            flips_other.append(p)

    # Sort W->L flips worst trade_ratio first
    flips_w_to_l.sort(
        key=lambda p: (
            p["new"].get("trade_ratio") if isinstance(p["new"].get("trade_ratio"), (int, float)) else 999.0,
            p["new"]["match_id"],
        )
    )

    # Per-race and per-matchup summaries
    by_race: dict[str, Any] = {}
    all_races_seen = sorted({m["our_race"] for m in new_f + base_f if m.get("our_race")})
    for r in all_races_seen:
        by_race[r] = {
            "base": _summarize_group([m for m in base_f if m["our_race"] == r]),
            "new": _summarize_group([m for m in new_f if m["our_race"] == r]),
            "pro_deep_base": _extract_pro_deep_slice(base_pd, r, by_race=True),
            "pro_deep_new": _extract_pro_deep_slice(new_pd, r, by_race=True),
        }

    by_matchup: dict[str, Any] = {}
    all_mus_seen = sorted({m["matchup"] for m in new_f + base_f if m.get("matchup")})
    for mu in all_mus_seen:
        by_matchup[mu] = {
            "base": _summarize_group([m for m in base_f if m["matchup"] == mu]),
            "new": _summarize_group([m for m in new_f if m["matchup"] == mu]),
            "pro_deep_base": _extract_pro_deep_slice(base_pd, mu, by_race=False),
            "pro_deep_new": _extract_pro_deep_slice(new_pd, mu, by_race=False),
        }

    # Parallel s2protocol + bot1.log deep extraction on top W->L flips
    selected_flips = flips_w_to_l[: max(0, top_flips)]
    # Also include W->T regressions if we have room and zero W->L or want context
    tasks: list[tuple[str, str, str]] = []
    task_map: list[tuple[int, str]] = []
    for idx, p in enumerate(selected_flips):
        nm = p["new"]
        bm = p["base"]
        tasks.append((nm.get("replay_path", ""), nm.get("log_path", ""), str(pylibs_dir)))
        task_map.append((idx, "new"))
        if bm and bm.get("replay_path"):
            tasks.append((bm.get("replay_path", ""), bm.get("log_path", ""), str(pylibs_dir)))
            task_map.append((idx, "base"))

    deep_results: dict[tuple[int, str], dict[str, Any]] = {}
    if tasks:
        max_w = max(1, min(workers, len(tasks)))
        with concurrent.futures.ProcessPoolExecutor(max_workers=max_w) as pool:
            for tm, res in zip(task_map, pool.map(extract_replay_forensics_worker, tasks)):
                deep_results[tm] = res

    deep_w_to_l_flips: list[dict[str, Any]] = []
    for idx, p in enumerate(selected_flips):
        nm = p["new"]
        bm = p["base"]
        deep_w_to_l_flips.append(
            {
                "bot1": p["bot1"],
                "bot2": p["bot2"],
                "race_roll_changed": p["race_roll_changed"],
                "base_res": bm["result"] if bm else None,
                "base_tr": bm.get("trade_ratio") if bm else None,
                "new_match": nm,
                "new_forensics": deep_results.get((idx, "new")),
                "base_forensics": deep_results.get((idx, "base")),
            }
        )

    elapsed = time.monotonic() - t0
    return {
        "meta": {
            "new_run_dir": str(new_run_dir),
            "base_run_dir": str(base_run_dir),
            "new_label": _infer_label_from_run_dir(new_run_dir),
            "base_label": _infer_label_from_run_dir(base_run_dir),
            "new_score_json": str(new_score) if new_score else None,
            "base_score_json": str(base_score) if base_score else None,
            "new_pro_deep_json": str(new_pd_path) if new_pd_path else None,
            "base_pro_deep_json": str(base_pd_path) if base_pd_path else None,
            "races": sorted(races),
            "matchups": sorted(matchups),
            "include_selfplay": effective_include_sp,
            "paired_count": sum(1 for p in pairs if p["new"] and p["base"]),
            "race_roll_changes": sum(1 for p in pairs if p.get("race_roll_changed")),
            "elapsed_sec": round(elapsed, 3),
        },
        "overall": {
            "base": _summarize_group(base_f),
            "new": _summarize_group(new_f),
        },
        "by_race": by_race,
        "by_matchup": by_matchup,
        "flips_w_to_l": flips_w_to_l,
        "flips_l_to_w": flips_l_to_w,
        "flips_other": flips_other,
        "deep_w_to_l_flips": deep_w_to_l_flips,
    }


def build_arg_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="Fast parallel replay & log forensic diff CLI between two SC2 local arena runs."
    )
    ap.add_argument("new_run_dir", help="Path to new SC2 local arena run directory")
    ap.add_argument("base_run_dir", help="Path to baseline SC2 local arena run directory")
    ap.add_argument("--race", default=None, help="Filter by our race: P|T|Z (comma-separated allowed)")
    ap.add_argument("--matchup", default=None, help="Filter by matchup(s), e.g. PvP,PvT")
    ap.add_argument("--new-score", default=None, help="Optional explicit score JSON for new run")
    ap.add_argument("--base-score", default=None, help="Optional explicit score JSON for base run")
    ap.add_argument("--new-pro-deep", default=None, help="Optional explicit pro_deep.json for new run")
    ap.add_argument("--base-pro-deep", default=None, help="Optional explicit pro_deep.json for base run")
    ap.add_argument("--include-selfplay", action="store_true", help="Include self-play matches in mixed runs")
    ap.add_argument("--top-flips", type=int, default=12, help="Max W->L flips to deep-decode (default: 12)")
    ap.add_argument("--workers", type=int, default=8, help="Parallel worker processes (default: 8)")
    ap.add_argument("--pylibs-dir", default=str(DEFAULT_PYLIBS_DIR), help="Directory containing mpyq & s2protocol")
    ap.add_argument("--out-md", default=None, help="Optional output Markdown report path")
    ap.add_argument("--out-json", default=None, help="Optional output JSON report path")
    ap.add_argument("--quiet", action="store_true", help="Do not print Markdown report to stdout")
    return ap


def main(argv: list[str] | None = None) -> int:
    ap = build_arg_parser()
    args = ap.parse_args(argv)

    races: set[str] = set()
    if args.race:
        for tok in args.race.split(","):
            nr = _normalize_race(tok)
            if nr:
                races.add(nr)
    matchups: set[str] = set()
    if args.matchup:
        for tok in args.matchup.split(","):
            s = tok.strip()
            if s:
                matchups.add(s)

    report = run_forensics_diff(
        Path(args.new_run_dir),
        Path(args.base_run_dir),
        races=races,
        matchups=matchups,
        new_score_path=Path(args.new_score) if args.new_score else None,
        base_score_path=Path(args.base_score) if args.base_score else None,
        new_pro_deep_path=Path(args.new_pro_deep) if args.new_pro_deep else None,
        base_pro_deep_path=Path(args.base_pro_deep) if args.base_pro_deep else None,
        include_selfplay=args.include_selfplay,
        top_flips=args.top_flips,
        workers=args.workers,
        pylibs_dir=Path(args.pylibs_dir),
    )
    md = render_markdown(report)

    if args.out_md:
        out_md = Path(args.out_md)
        out_md.parent.mkdir(parents=True, exist_ok=True)
        out_md.write_text(md, encoding="utf-8")
    if args.out_json:
        out_json = Path(args.out_json)
        out_json.parent.mkdir(parents=True, exist_ok=True)
        out_json.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if not args.quiet:
        print(md)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
