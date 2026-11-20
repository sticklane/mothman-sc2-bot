#!/usr/bin/env python3
"""
tools/iteration-loop/render-replay-clips.py

Post-match real-3D SC2_x64 critical-moment batch renderer.
Uses fast `s2protocol` (`protocol75689`, ~45ms/replay) to locate the exact
decisive clash window & coordinates for the Top N diverse matches from a
`score-replay-batch.rkt` JSON, then renders real 3D animated WebPs (800x600 @ 16fps)
and 960x720 Peak-Clash PNGs in parallel on host AMD Radeon via `sc2_3d_renderer.py`.

Usage:
  python3 tools/iteration-loop/render-replay-clips.py \
      --score-json /path/to/iter18_wave18_score.json \
      --replays-dir /path/to/replays \
      --maps-dir /home/sjaconette/sc2-local-arena/maps \
      --out-dir /path/to/visuals/replays \
      --max-clips 6 --jobs 4 --step 2 --fps 16 --frames 72

Ad-hoc single replay mode:
  python3 tools/iteration-loop/render-replay-clips.py \
      --replay /path/to/match.SC2Replay \
      --maps-dir /home/sjaconette/sc2-local-arena/maps \
      --out-dir /path/to/out [--start-loop 8400]
"""

from __future__ import annotations

import argparse
import concurrent.futures
import importlib.util
import json
import os
import re
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_PYLIBS_DIR = Path("/home/sjaconette/sc2-local-arena/pylibs")
DEFAULT_MAPS_DIR = Path("/home/sjaconette/sc2-local-arena/maps")

if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))
if str(DEFAULT_PYLIBS_DIR) not in sys.path and DEFAULT_PYLIBS_DIR.is_dir():
    sys.path.append(str(DEFAULT_PYLIBS_DIR))

from sc2_3d_renderer import fmt_clock, render_replay_clip_sync  # noqa: E402

CORE_12_OPPONENTS = frozenset({
    "12PoolBot", "Chance", "Creepy_strategies", "RustyNikolaj", "SmoothBrain",
    "Thssprtssbt", "mini-puck", "monsterbot", "oberon", "puck",
    "sludgement2-revived", "titania",
})

# Approximate unit values for s2protocol clash-window scoring (by SC2 internal unit name)
UNIT_NAME_VALUE: dict[str, float] = {
    "Marine": 50, "Reaper": 100, "Marauder": 125, "Ghost": 275,
    "Hellion": 100, "HellionTank": 100, "WidowMine": 100, "WidowMineBurrowed": 100,
    "SiegeTank": 275, "SiegeTankSieged": 275, "Cyclone": 250, "Thor": 500, "ThorAP": 500,
    "VikingFighter": 225, "VikingAssault": 225, "Medivac": 200, "Liberator": 300,
    "LiberatorAG": 300, "Banshee": 250, "Raven": 300, "Battlecruiser": 700, "SCV": 50,
    "Zealot": 100, "Stalker": 175, "Sentry": 150, "Adept": 125, "HighTemplar": 200,
    "DarkTemplar": 250, "Archon": 350, "Immortal": 375, "Colossus": 500, "Disruptor": 300,
    "Observer": 100, "WarpPrism": 250, "WarpPrismPhasing": 250, "Phoenix": 250,
    "Oracle": 300, "VoidRay": 400, "Carrier": 600, "Tempest": 425, "Mothership": 800, "Probe": 50,
    "Zergling": 25, "Baneling": 75, "Roach": 100, "Ravager": 200, "Hydralisk": 150,
    "LurkerMP": 300, "LurkerMPBurrowed": 300, "Infestor": 250, "SwarmHostMP": 175,
    "Ultralisk": 500, "Queen": 150, "Mutalisk": 200, "Corruptor": 250, "Viper": 300,
    "BroodLord": 550, "Overlord": 100, "Overseer": 200, "Drone": 50,
    # Key structures (lower weight than combat units so pure mop-up loses to real army fights)
    "Nexus": 250, "CommandCenter": 250, "OrbitalCommand": 300, "PlanetaryFortress": 350,
    "Hatchery": 200, "Lair": 250, "Hive": 300, "Bunker": 100, "PhotonCannon": 125,
    "SpineCrawler": 100, "SporeCrawler": 75, "ShieldBattery": 100, "MissileTurret": 100,
}

NON_COMBAT_UNIT_NAMES = frozenset({
    "Larva", "Egg", "BanelingCocoon", "RavagerCocoon", "LurkerMPEgg", "BroodLordCocoon",
    "Broodling", "BroodlingEscort", "Interceptor", "LocustMP", "LocustMPFlying",
    "CreepTumor", "CreepTumorBurrowed", "CreepTumorQueen", "MULE", "Changeling",
    "ChangelingZealot", "ChangelingMarineShield", "ChangelingMarine", "ChangelingZergling",
    "AdeptPhaseShift", "DisruptorPhased", "AutoTurret", "KD8Charge", "ForceField",
})

_PROTO75689 = None


def _load_protocol75689():
    global _PROTO75689
    if _PROTO75689 is not None:
        return _PROTO75689
    proto_path = DEFAULT_PYLIBS_DIR / "s2protocol" / "versions" / "protocol75689.py"
    spec = importlib.util.spec_from_file_location("protocol75689", str(proto_path))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _PROTO75689 = mod
    return mod


def _slug(text: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]+", "_", text).strip("_")[:48]


def _clean_unit_name(raw: Any) -> str:
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="ignore")
    return str(raw or "")


def locate_critical_window(
    replay_path: Path,
    focus_mode: str = "peak_clash",
    window_loops: int = 160,
    lead_in_loops: int = 36,
    our_player_id: int = 1,
) -> dict[str, Any]:
    """
    Fast (~45ms) s2protocol tracker-event scanner locating the exact highest-signal
    battle window `(start_loop, peak_loop, focus_x, focus_y)` + destroyed unit breakdown.
    """
    import mpyq

    proto = _load_protocol75689()
    arc = mpyq.MPQArchive(str(replay_path))
    header = proto.decode_replay_header(arc.header["user_data_header"]["content"])
    total_loops = int(header.get("m_elapsedGameLoops") or 0)
    trk_bytes = arc.read_file("replay.tracker.events")

    unit_map: dict[tuple[int, int], tuple[str, int]] = {}  # (idx, recycle) -> (name, owner)
    deaths: list[tuple[int, int, str, float, float, float, int]] = []
    # tuple: (loop, owner, unit_name, val, x, y, killer_pid)

    for ev in proto.decode_replay_tracker_events(trk_bytes):
        et = ev.get("_event")
        if et in ("NNet.Replay.Tracker.SUnitBornEvent", "NNet.Replay.Tracker.SUnitInitEvent"):
            key = (int(ev["m_unitTagIndex"]), int(ev["m_unitTagRecycle"]))
            uname = _clean_unit_name(ev.get("m_unitTypeName"))
            owner = int(ev.get("m_controlPlayerId") or 0)
            unit_map[key] = (uname, owner)
        elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
            key = (int(ev["m_unitTagIndex"]), int(ev["m_unitTagRecycle"]))
            if key in unit_map:
                unit_map[key] = (_clean_unit_name(ev.get("m_unitTypeName")), unit_map[key][1])
        elif et == "NNet.Replay.Tracker.SUnitOwnerChangeEvent":
            key = (int(ev["m_unitTagIndex"]), int(ev["m_unitTagRecycle"]))
            if key in unit_map:
                unit_map[key] = (unit_map[key][0], int(ev.get("m_controlPlayerId") or unit_map[key][1]))
        elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
            key = (int(ev["m_unitTagIndex"]), int(ev["m_unitTagRecycle"]))
            uname, owner = unit_map.get(key, ("", 0))
            killer = int(ev.get("m_killerPlayerId") or 0)
            gl = int(ev.get("_gameloop") or 0)
            if owner not in (1, 2) or killer not in (1, 2) or killer == owner:
                continue
            if uname in NON_COMBAT_UNIT_NAMES:
                continue
            val = float(UNIT_NAME_VALUE.get(uname, 40.0))
            deaths.append((gl, owner, uname, val, float(ev.get("m_x") or 88.0), float(ev.get("m_y") or 88.0), killer))

    # Filter deaths by focus_mode time horizon if requested
    cand_deaths = deaths
    if focus_mode == "early_rush":
        early = [d for d in deaths if d[0] <= 6720]  # <= 5:00
        if early:
            cand_deaths = early

    if not cand_deaths:
        mid = max(64, min(total_loops - 180, total_loops // 2))
        return {
            "start_loop": mid,
            "peak_loop": mid + 60,
            "focus_x": None,
            "focus_y": None,
            "clash_value": 0.0,
            "p1_lost_window": 0.0,
            "p2_lost_window": 0.0,
            "p1_lost_units": [],
            "p2_lost_units": [],
            "total_loops": total_loops,
        }

    best_score = -1.0
    best_span = (0, 0)
    n = len(cand_deaths)
    j = 0
    for i in range(n):
        t_start = cand_deaths[i][0]
        if j < i:
            j = i
        while j < n and cand_deaths[j][0] - t_start <= window_loops:
            j += 1
        seg = cand_deaths[i:j]
        p1_l = sum(d[3] for d in seg if d[1] == our_player_id)
        p2_l = sum(d[3] for d in seg if d[1] != our_player_id)
        tot = p1_l + p2_l
        both_bonus = 1.35 if (p1_l >= 100.0 and p2_l >= 100.0) else 1.0
        # Slight penalty for very final mop-up right before surrender if an earlier real battle exists
        late_damp = 0.82 if (total_loops > 2000 and t_start > total_loops - 260 and p2_l < 100.0 and p1_l < 100.0) else 1.0
        if focus_mode == "anomaly_loss":
            score = (p1_l * 1.65 + p2_l * 0.55) * both_bonus * late_damp
        elif focus_mode == "early_rush":
            score = tot * (1.25 if t_start <= 4800 else 0.9) * both_bonus
        else:
            score = tot * both_bonus * late_damp
        if score > best_score:
            best_score = score
            best_span = (i, j)

    seg = cand_deaths[best_span[0]:best_span[1]]
    w_start = seg[0][0]
    w_end = seg[-1][0]
    sw = sum(d[3] for d in seg)
    # Weight camera focus toward the densest spatial kill-value cluster (radius=20t)
    # so simultaneous kills across two distant map locations never average onto empty terrain.
    best_cluster = seg
    best_cluster_val = -1.0
    for anchor in seg:
        ax, ay = anchor[4], anchor[5]
        cluster = [d for d in seg if (d[4] - ax) ** 2 + (d[5] - ay) ** 2 <= 400.0]
        cval = sum(d[3] for d in cluster)
        if cval > best_cluster_val:
            best_cluster_val = cval
            best_cluster = cluster
    cw = sum(d[3] for d in best_cluster)
    fx = sum(d[4] * d[3] for d in best_cluster) / max(1.0, cw)
    fy = sum(d[5] * d[3] for d in best_cluster) / max(1.0, cw)
    p1_l = sum(d[3] for d in seg if d[1] == our_player_id)
    p2_l = sum(d[3] for d in seg if d[1] != our_player_id)
    p1_cnt = Counter(d[2] for d in seg if d[1] == our_player_id)
    p2_cnt = Counter(d[2] for d in seg if d[1] != our_player_id)

    # Start slightly before the first deaths so viewer sees army approach + engagement
    clip_start = max(32, w_start - lead_in_loops)
    if total_loops > window_loops + 64:
        clip_start = min(clip_start, total_loops - window_loops - 32)
    peak_loop = int(round(0.5 * (w_start + w_end)))

    return {
        "start_loop": int(clip_start),
        "peak_loop": int(peak_loop),
        "focus_x": round(fx, 1),
        "focus_y": round(fy, 1),
        "clash_value": round(sw, 1),
        "p1_lost_window": round(p1_l, 1),
        "p2_lost_window": round(p2_l, 1),
        "p1_lost_units": p1_cnt.most_common(4),
        "p2_lost_units": p2_cnt.most_common(4),
        "total_loops": total_loops,
    }


def _fmt_units_list(pairs: list[tuple[str, int]]) -> str:
    if not pairs:
        return "none"
    return ", ".join(f"{cnt}x {name}" for name, cnt in pairs)


def select_critical_clips(
    matches: list[dict[str, Any]],
    replays_dir: Path,
    max_clips: int = 6,
) -> list[dict[str, Any]]:
    """Auto-select up to `max_clips` diverse, high-signal critical moments from score JSON."""
    valid = []
    for m in matches:
        fname = m.get("file") or ""
        rp = replays_dir / fname
        if not fname or not rp.exists():
            continue
        if m.get("opp_early_crash"):
            continue
        valid.append((m, rp))

    selected: list[dict[str, Any]] = []
    used_ids: set[str] = set()
    used_races: Counter[str] = Counter()

    def _add(m: dict[str, Any], rp: Path, category: str, focus_mode: str, accent: tuple[int, int, int], why: str, watch: str) -> None:
        mid = str(m.get("id") or rp.stem)
        used_ids.add(mid)
        used_races[str(m.get("our_race") or "")] += 1
        selected.append({
            "match": m,
            "replay_path": rp,
            "category": category,
            "focus_mode": focus_mode,
            "accent_rgb": accent,
            "why_selected": why,
            "what_to_watch": watch,
        })

    def _pick(pool, key_fn):
        cands = [(m, rp) for m, rp in pool if str(m.get("id") or rp.stem) not in used_ids]
        if not cands:
            return None
        # Slight preference for under-represented Mothman races (P/T/Z diversity!)
        return max(
            cands,
            key=lambda pair: (key_fn(pair[0]) * (1.12 if used_races[str(pair[0].get("our_race") or "")] == 0 else 1.0)),
        )

    # 1. Showcase Core Win (big macro battle win vs core_12)
    core_wins = [
        (m, rp) for m, rp in valid
        if m.get("result") == "win"
        and (m.get("opp_bot") in CORE_12_OPPONENTS)
        and (m.get("duration_sec") or 0) >= 240
    ]
    pick = _pick(
        core_wins,
        lambda m: (m.get("killed_val") or 0) * min(3.5, max(0.5, m.get("trade_ratio") or 1.0)) + (m.get("our_peak_army") or 0) * 1.2,
    )
    if pick:
        m, rp = pick
        _add(
            m, rp, "SHOWCASE CORE WIN", "peak_clash", (34, 197, 94),
            f"Flagship core_12 victory ({m.get('our_bot')} vs {m.get('opp_bot')}, Trade {m.get('trade_ratio')}x, Peak Army {m.get('our_peak_army')}).",
            "Watch Mothman's army positioning, focus-fire discipline, and decisive mid/late-game macro conversion.",
        )

    # 2. Held-Out Unseen Win (generalization proof; falls back to 2nd diverse Core Win)
    unseen_wins = [
        (m, rp) for m, rp in valid
        if m.get("result") == "win"
        and (m.get("opp_bot") not in CORE_12_OPPONENTS)
        and (m.get("duration_sec") or 0) >= 200
    ]
    pick = _pick(
        unseen_wins,
        lambda m: (m.get("our_peak_army") or 0) + (m.get("killed_val") or 0) * 1.3,
    )
    if pick:
        m, rp = pick
        _add(
            m, rp, "HELD-OUT UNSEEN WIN", "peak_clash", (56, 189, 248),
            f"Zero-overfitting held-out unseen_6 win ({m.get('our_bot')} vs {m.get('opp_bot')}, Trade {m.get('trade_ratio')}x, Peak Army {m.get('our_peak_army')}).",
            "Watch Mothman adapt cleanly to an unseen ladder opponent with strong mid/late army execution.",
        )
    else:
        pick = _pick(core_wins, lambda m: (m.get("our_peak_army") or 0) + (m.get("killed_val") or 0))
        if pick:
            m, rp = pick
            _add(
                m, rp, "CORE MACRO WIN", "peak_clash", (56, 189, 248),
                f"Second race-diverse core_12 win ({m.get('our_bot')} vs {m.get('opp_bot')}, Trade {m.get('trade_ratio')}x).",
                "Watch Mothman's unit composition, engagement geometry, and production follow-through.",
            )

    # 3. Worst Siege0DPS / Cloak / Freeze Anomaly Loss
    siege_losses = [
        (m, rp) for m, rp in valid
        if m.get("result") == "loss"
        and (
            m.get("siege_range_zero_dps_loss")
            or (m.get("anomalies") or {}).get("siege_range_zero_dps_loss")
            or m.get("cloaked_unit_damage_loss")
            or m.get("prod_idle_bank_freeze")
        )
    ]
    pick = _pick(
        siege_losses,
        lambda m: (m.get("lost_val") or 0) + (m.get("our_peak_army") or 0) * 0.8 + (2500 if m.get("siege_range_zero_dps_loss") else 0),
    )
    if pick:
        m, rp = pick
        tag = "SIEGE0DPS LOSS" if m.get("siege_range_zero_dps_loss") else "ANOMALY LOSS"
        _add(
            m, rp, tag, "anomaly_loss", (239, 68, 68),
            f"Highest-priority combat anomaly loss ({m.get('our_bot')} vs {m.get('opp_bot')}, Trade {m.get('trade_ratio')}x, Lost {m.get('lost_val')}).",
            "Diagnose whether Mothman hesitates/kites inside enemy siege or splash range instead of closing, flanking, or cleanly disengaging.",
        )

    # 4. Worst OBRet / Territory Retreat Loss
    obret_losses = [
        (m, rp) for m, rp in valid
        if m.get("result") == "loss"
        and ((m.get("own_base_retreat_frames") or 0) >= 440 or (m.get("own_territory_retreat_frames") or 0) >= 440)
    ]
    pick = _pick(
        obret_losses,
        lambda m: (m.get("own_base_retreat_frames") or 0) * 1.5 + (m.get("own_territory_retreat_frames") or 0) + (m.get("lost_val") or 0) * 0.25,
    )
    if pick:
        m, rp = pick
        _add(
            m, rp, "HOME-DEFENSE RETREAT LOSS", "anomaly_loss", (249, 115, 22),
            f"Worst own-base/territory retreat loss ({m.get('our_bot')} vs {m.get('opp_bot')}, OBRet={m.get('own_base_retreat_frames')}f, Trade {m.get('trade_ratio')}x).",
            "Inspect why units retreat inside our own main/natural rather than standing & focus-firing with defenders' advantage.",
        )

    # 5. Early Rush Defense (< 5:30 action or early_rush_idle_bank_3m)
    early_rushes = [
        (m, rp) for m, rp in valid
        if (
            m.get("early_rush_idle_bank_3m")
            or (m.get("anomalies") or {}).get("early_rush_idle_bank_3m")
            or ((m.get("duration_sec") or 9999) <= 340 and ((m.get("killed_val") or 0) + (m.get("lost_val") or 0)) >= 400)
        )
    ]
    pick = _pick(
        early_rushes,
        lambda m: (3000 if m.get("early_rush_idle_bank_3m") else 0) + (m.get("lost_val") or 0) + (m.get("killed_val") or 0),
    )
    if pick:
        m, rp = pick
        _add(
            m, rp, "EARLY RUSH DEFENSE", "early_rush", (168, 85, 247),
            f"Critical early-game rush test ({m.get('our_bot')} vs {m.get('opp_bot')}, {m.get('result').upper()} in {int(m.get('duration_sec') or 0)}s).",
            "Watch worker pull timing, choke/mineral-line positioning, and whether early minerals convert into combat units & production.",
        )

    # 6. Highest-Intensity Late / T3 Clash (fill remaining slots up to max_clips)
    while len(selected) < max_clips:
        pick = _pick(
            valid,
            lambda m: (m.get("our_peak_army") or 0) + (m.get("opp_peak_army") or 0) + (2000 if m.get("t3_first_sec") else 0) + (m.get("killed_val") or 0) * 0.5,
        )
        if not pick:
            break
        m, rp = pick
        lbl = "T3 LATE-GAME CLASH" if m.get("t3_first_sec") else "HIGH-INTENSITY CLASH"
        _add(
            m, rp, lbl, "peak_clash", (234, 179, 8),
            f"Massive late-game army clash ({m.get('our_bot')} vs {m.get('opp_bot')}, Peak Armies {m.get('our_peak_army')}/{m.get('opp_peak_army')}, {m.get('result').upper()}).",
            "Watch late-game tech composition, spellcaster usage, and multi-angle army control.",
        )

    return selected[:max_clips]


def _render_job_entry(job: dict[str, Any]) -> dict[str, Any]:
    loc = locate_critical_window(
        Path(job["replay_path"]),
        focus_mode=job["focus_mode"],
        window_loops=max(120, job["frames"] * job["step"]),
    )
    start_loop = job["override_start_loop"] if job.get("override_start_loop") is not None else loc["start_loop"]
    focus_hint = (loc["focus_x"], loc["focus_y"]) if (loc["focus_x"] is not None and loc["focus_y"] is not None) else None

    res = render_replay_clip_sync(
        replay_path=job["replay_path"],
        out_webp=job["out_webp"],
        out_png=job["out_png"],
        start_loop=start_loop,
        num_frames=job["frames"],
        step=job["step"],
        fps=job["fps"],
        webp_size=(job["webp_width"], job["webp_height"]),
        maps_dir=job["maps_dir"],
        title=job["pill_title"],
        subtitle_metric=job["pill_metric"],
        focus_hint=focus_hint,
        accent_rgb=tuple(job["accent_rgb"]),
    )

    m = job.get("match") or {}
    clash_summary = (
        f"During {res['clock_window']} around ({loc['focus_x']}, {loc['focus_y']}), "
        f"Mothman lost ~{int(loc['p1_lost_window']):,} res ({_fmt_units_list(loc['p1_lost_units'])}) "
        f"while destroying ~{int(loc['p2_lost_window']):,} enemy res ({_fmt_units_list(loc['p2_lost_units'])})."
    )
    return {
        **res,
        "clip_slug": job["clip_slug"],
        "match_id": str(m.get("id") or ""),
        "our_bot": m.get("our_bot") or "",
        "opp_bot": m.get("opp_bot") or "",
        "our_race": m.get("our_race") or "",
        "opp_race": m.get("opp_race") or "",
        "matchup": m.get("matchup") or "",
        "result": m.get("result") or "",
        "duration_sec": m.get("duration_sec"),
        "trade_ratio": m.get("trade_ratio"),
        "killed_val": m.get("killed_val"),
        "lost_val": m.get("lost_val"),
        "our_peak_army": m.get("our_peak_army"),
        "opp_peak_army": m.get("opp_peak_army"),
        "map_symmetry_kind": m.get("map_symmetry_kind"),
        "category": job["category"],
        "why_selected": job["why_selected"],
        "what_to_watch": job["what_to_watch"],
        "context": f"{job['why_selected']} {clash_summary}",
        "clash_window_stats": {
            "focus_x": loc["focus_x"],
            "focus_y": loc["focus_y"],
            "clash_value": loc["clash_value"],
            "p1_lost_window": loc["p1_lost_window"],
            "p2_lost_window": loc["p2_lost_window"],
            "p1_lost_units": loc["p1_lost_units"],
            "p2_lost_units": loc["p2_lost_units"],
        },
        "anomalies": [k for k, v in (m.get("anomalies") or {}).items() if v],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Render Top-N real-3D SC2_x64 replay critical moments to animated WebP + Peak PNG.")
    ap.add_argument("--score-json", default=None, help="Score JSON from score-replay-batch.rkt")
    ap.add_argument("--replays-dir", default=None, help="Directory with .SC2Replay files")
    ap.add_argument("--replay", default=None, help="Ad-hoc single .SC2Replay file")
    ap.add_argument("--start-loop", type=int, default=None, help="Optional explicit start_loop for ad-hoc single replay")
    ap.add_argument("--title", default=None, help="Optional title for ad-hoc single replay")
    ap.add_argument("--maps-dir", default=str(DEFAULT_MAPS_DIR), help="Directory with .SC2Map files")
    ap.add_argument("--out-dir", required=True, help="Output directory for .webp, .png, and manifest.json")
    ap.add_argument("--max-clips", type=int, default=6)
    ap.add_argument("--jobs", type=int, default=4, help="Parallel host SC2_x64 3D renderer workers")
    ap.add_argument("--step", type=int, default=2, help="Game loops per rendered frame")
    ap.add_argument("--fps", type=int, default=16, help="Output animated WebP FPS")
    ap.add_argument("--frames", type=int, default=72, help="Frames per clip (72 @ step=2 = 144 loops / 4.5s @ 16fps)")
    ap.add_argument("--webp-width", type=int, default=800)
    ap.add_argument("--webp-height", type=int, default=600)
    args = ap.parse_args()

    t0 = time.monotonic()
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    maps_dir = Path(args.maps_dir)

    jobs: list[dict[str, Any]] = []
    if args.replay:
        rp = Path(args.replay)
        slug = _slug(rp.stem)
        jobs.append({
            "clip_slug": slug,
            "replay_path": str(rp),
            "maps_dir": str(maps_dir),
            "out_webp": str(out_dir / f"{slug}.webp"),
            "out_png": str(out_dir / f"{slug}.png"),
            "frames": args.frames,
            "step": args.step,
            "fps": args.fps,
            "webp_width": args.webp_width,
            "webp_height": args.webp_height,
            "focus_mode": "peak_clash",
            "override_start_loop": args.start_loop,
            "pill_title": args.title or rp.stem[:34],
            "pill_metric": "",
            "accent_rgb": (56, 189, 248),
            "category": "AD-HOC CLIP",
            "why_selected": f"Ad-hoc replay clip for {rp.name}.",
            "what_to_watch": "Real 3D SC2_x64 playback of the target engagement window.",
            "match": {},
        })
    else:
        if not args.score_json or not args.replays_dir:
            ap.error("Provide either --replay OR both --score-json and --replays-dir")
        data = json.loads(Path(args.score_json).read_text(encoding="utf-8"))
        picks = select_critical_clips(data.get("matches") or [], Path(args.replays_dir), max_clips=args.max_clips)
        for idx, p in enumerate(picks, start=1):
            m = p["match"]
            rp = p["replay_path"]
            mid = str(m.get("id") or idx)
            slug = _slug(f"clip{idx:02d}_m{mid}_{m.get('our_bot', 'M')}_vs_{m.get('opp_bot', 'Opp')}_{p['category'].split()[0].lower()}")
            tr = m.get("trade_ratio")
            res_u = str(m.get("result") or "").upper()
            pill_metric = f"{res_u} {float(tr):.2f}x" if tr is not None else res_u
            jobs.append({
                "clip_slug": slug,
                "replay_path": str(rp),
                "maps_dir": str(maps_dir),
                "out_webp": str(out_dir / f"{slug}.webp"),
                "out_png": str(out_dir / f"{slug}.png"),
                "frames": args.frames,
                "step": args.step,
                "fps": args.fps,
                "webp_width": args.webp_width,
                "webp_height": args.webp_height,
                "focus_mode": p["focus_mode"],
                "override_start_loop": None,
                "pill_title": f"#{mid} {m.get('our_bot')} vs {m.get('opp_bot')}",
                "pill_metric": pill_metric,
                "accent_rgb": p["accent_rgb"],
                "category": p["category"],
                "why_selected": p["why_selected"],
                "what_to_watch": p["what_to_watch"],
                "match": m,
            })

    results: list[dict[str, Any]] = []
    max_w = max(1, min(args.jobs, len(jobs)))
    if max_w == 1:
        for j in jobs:
            results.append(_render_job_entry(j))
    else:
        with concurrent.futures.ProcessPoolExecutor(max_workers=max_w) as ex:
            futs = [ex.submit(_render_job_entry, j) for j in jobs]
            for f in futs:
                results.append(f.result())

    manifest = {
        "kind": "replay_3d_visuals",
        "score_json": os.path.abspath(args.score_json) if args.score_json else None,
        "replays_dir": os.path.abspath(args.replays_dir) if args.replays_dir else None,
        "render_size": [960, 720],
        "webp_size": [args.webp_width, args.webp_height],
        "fps": args.fps,
        "step": args.step,
        "clips_count": len(results),
        "total_webp_bytes": sum(r.get("webp_bytes", 0) for r in results),
        "total_png_bytes": sum(r.get("png_bytes", 0) for r in results),
        "wall_sec": round(time.monotonic() - t0, 2),
        "clips": results,
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
