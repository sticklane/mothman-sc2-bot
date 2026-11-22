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

SCHEMA_VERSION = 1
CACHE_SCHEMA_VERSION = 1

GAME_LOOPS_PER_SEC = 22.4
GAME_LOOPS_PER_MIN = 60.0 * GAME_LOOPS_PER_SEC  # 1344.0
LOTV_MIN_BASE_BUILD = 38215

RACES = ("Protoss", "Terran", "Zerg")
SEGMENTS = ("all", "Protoss", "Terran", "Zerg")
COHORTS = ("mothman", "opponents", "pros")

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


def _decode_game_events_metrics(
    proto: Any,
    ge_bytes: bytes,
    uid_to_pid: dict[int, int],
    target_pids: tuple[int, ...],
    buckets_sec: list[int],
    bucket_sec: int,
    dur_sec: float,
) -> tuple[bool, dict[int, dict[str, Any]]]:
    """
    Decode replay.game.events into APM, EPM, and SPM per-bucket curves and
    full-game rates for each player in `target_pids`.
    Returns `(ok, per_pid_dict)`. If s2protocol raises (e.g., newer patch
    schema mismatch), returns `(False, {})` so partial corruptions never bias
    APM/EPM/SPM metrics.
    """
    n_buckets = len(buckets_sec)
    bucket_loops = int(round(bucket_sec * GAME_LOOPS_PER_SEC))
    max_bucket_idx = n_buckets - 1

    apm_b: dict[int, list[int]] = {p: [0] * n_buckets for p in target_pids}
    epm_b: dict[int, list[int]] = {p: [0] * n_buckets for p in target_pids}
    spm_b: dict[int, list[int]] = {p: [0] * n_buckets for p in target_pids}
    apm_tot: dict[int, int] = {p: 0 for p in target_pids}
    epm_tot: dict[int, int] = {p: 0 for p in target_pids}
    spm_tot: dict[int, int] = {p: 0 for p in target_pids}

    # Per-player EPM & SPM rolling state
    cur_sel: dict[int, list[int]] = {p: [] for p in target_pids}
    last_cmd_gl: dict[int, dict[tuple[Any, ...], int]] = {p: {} for p in target_pids}
    last_sel_sig: dict[int, Any] = {p: None for p in target_pids}
    last_sel_gl: dict[int, int] = {p: -9999 for p in target_pids}
    last_cam: dict[int, tuple[int, float, float] | None] = {p: None for p in target_pids}

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
                        prev_sel = cur_sel[pid]
                        new_sel = _apply_selection_delta(prev_sel, delta)
                        cur_sel[pid] = new_sel
                        # Genuine human/bot selection switch (exclude Raw-API same-loop prefix)
                        cg_id = ev.get("m_controlGroupId")
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
                        if ev.get("m_controlGroupUpdate") in (0, 1, 4, 5):
                            epm_tot[pid] += 1
                            if in_curve:
                                epm_b[pid][bi] += 1

                    else:
                        # SCmdEvent / SCmdUpdateTargetPointEvent / SCmdUpdateTargetUnitEvent
                        sel_now = cur_sel[pid]
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
        for idx, pl in enumerate(pls, 1):
            rn = rdb._norm_race(pl.get("m_race"))
            if rn not in RACES:
                return results
            if mode == "pro" and pl.get("m_control") == 3:
                return results
            race_by_pid[idx] = rn
            name_by_pid[idx] = rdb._decode_str(pl.get("m_name", b""))

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

        # Single linear tracker pass: SPlayerSetupEvent, SPlayerStatsEvent, structures, morphs, upgrades
        uid_to_pid: dict[int, int] = {}
        stats_series: dict[int, list[tuple[float, float, float, float, float]]] = {1: [], 2: []}
        bldg_inits: dict[int, dict[str, list[tuple[float, int]]]] = {1: defaultdict(list), 2: defaultdict(list)}
        th_inits: dict[int, list[tuple[float, int]]] = {1: [], 2: []}
        morphs: dict[int, dict[str, list[float]]] = {1: defaultdict(list), 2: defaultdict(list)}
        upgrades: dict[int, dict[str, float]] = {1: {}, 2: {}}

        tag_owner: dict[int, int] = {}
        init_tags: set[int] = set()
        done_tags: set[int] = set()
        self_canceled_tags: set[int] = set()

        for ev in proto.decode_replay_tracker_events(trk_bytes):
            et = ev.get("_event", "")
            gl = int(ev.get("_gameloop", 0))
            sec = gl / GAME_LOOPS_PER_SEC

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
                stats_series[pid].append((sec, am, ag, cm, cg))

            elif et == "NNet.Replay.Tracker.SUnitInitEvent":
                pid = int(ev.get("m_controlPlayerId") or 0)
                if pid not in (1, 2):
                    continue
                ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                tag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                tag_owner[tag] = pid
                if ut in TRACKED_STRUCTURES:
                    init_tags.add(tag)
                    if ut in TOWN_HALLS and sec > 5.0:
                        th_inits[pid].append((sec, tag))
                    elif sec > 2.0:
                        bldg_inits[pid][ut].append((sec, tag))

            elif et == "NNet.Replay.Tracker.SUnitDoneEvent":
                tag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                if tag in init_tags:
                    done_tags.add(tag)

            elif et == "NNet.Replay.Tracker.SUnitBornEvent":
                pid = int(ev.get("m_controlPlayerId") or 0)
                if pid not in (1, 2):
                    continue
                ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                tag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                tag_owner[tag] = pid
                if ut in TRACKED_STRUCTURES:
                    if ut in TOWN_HALLS and sec > 5.0:
                        th_inits[pid].append((sec, tag))
                    elif sec > 2.0:
                        bldg_inits[pid][ut].append((sec, tag))

            elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
                tag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                if tag in init_tags and tag not in done_tags:
                    owner = tag_owner.get(tag)
                    k_pid = ev.get("m_killerPlayerId")
                    if k_pid is None or k_pid == owner:
                        self_canceled_tags.add(tag)

            elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
                tag = (int(ev.get("m_unitTagIndex", 0)) << 18) | int(ev.get("m_unitTagRecycle", 0))
                pid = tag_owner.get(tag)
                if pid in (1, 2):
                    ut = rdb._decode_str(ev.get("m_unitTypeName", b""))
                    if ut in TRACKED_MORPHS:
                        morphs[pid][ut].append(sec)

            elif et == "NNet.Replay.Tracker.SUpgradeEvent":
                pid = int(ev.get("m_playerId") or 0)
                if pid in (1, 2):
                    uname = rdb._decode_str(ev.get("m_upgradeTypeName", b""))
                    if uname in TRACKED_UPGRADES and uname not in upgrades[pid]:
                        upgrades[pid][uname] = sec

        # Fallback uid -> pid mapping only if SPlayerSetupEvent was absent
        if not uid_to_pid:
            uid_to_pid = {0: 1, 1: 2}

        # Decode replay.game.events for APM / EPM / SPM
        ge_bytes = arch.read_file("replay.game.events")
        ge_ok = False
        ge_by_pid: dict[int, dict[str, Any]] = {}
        if ge_bytes:
            ge_ok, ge_by_pid = _decode_game_events_metrics(
                proto, ge_bytes, uid_to_pid, (1, 2), buckets_sec, bucket_sec, dur_sec
            )
            # In Pro mode, if game events decoded cleanly for only 1 player, the other was AFK -> drop replay
            if mode == "pro" and ge_ok and len(ge_by_pid) < 2:
                return results

        half_win = max(15.0, bucket_sec * 0.5)
        for pid in (1, 2):
            race = race_by_pid[pid]
            ss = stats_series[pid]
            snap_curves = _sample_stats_at_buckets(ss, buckets_sec, dur_sec, half_win)

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

            ge_p = ge_by_pid.get(pid) if ge_ok else None
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
                "duration_sec": round(dur_sec, 1),
                "base_build": bb,
                "replay": rname,
                "game_events_ok": bool(ge_p is not None),
                "curves": curves_rec,
                "summary": summary_rec,
                "timings": timings_rec,
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

    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "meta": meta,
        "buckets_sec": buckets_sec,
        "buckets_label": [_fmt_sec(float(t)) for t in buckets_sec],
        "segments": list(SEGMENTS),
        "curves": curves_out,
        "summary": summary_out,
        "timings": timings_out,
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
