#!/usr/bin/env python3
"""
Modular interactive report sections, real SQLite/Pro-baseline analytics, and
iOS-Safari-compatible same-origin MP4 staging for the Mothman GitHub Pages site.

Imported by tools/publish-gh-pages.py.
"""

from __future__ import annotations

import concurrent.futures
import html
import json
import math
import os
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


MATCHUPS_ORDER = ("PvP", "PvT", "PvZ", "TvP", "TvT", "TvZ", "ZvP", "ZvT", "ZvZ")

MATCHUP_NOTES: Dict[str, Dict[str, str]] = {
    "PvP": {
        "working": "Blink Stalker mirror control (4.0× in drills), mid-game Immortal/Colossus fights, and head-to-head mirror wins over prior builds.",
        "gaps": "Nearly half of games delay the second Nexus past 3:00 when scouts, early Twilight tech, or enemy units block the natural, and Stargates still overbuild Phoenixes against Stalkers and Tempests.",
    },
    "PvT": {
        "working": "Strongest Protoss ladder matchup (6–2, 1.18× trade), backed by Disruptor shots against infantry (2.57× vs. Hubert) and Dark Templar raids that snipe Missile Turrets first.",
        "gaps": "Stalker and Phoenix spending sometimes drains gas needed for Robotics Bay and the first two Colossi, leaving Gateway armies pinned by Siege Tanks.",
    },
    "PvZ": {
        "working": "Colossus, Immortal, and Disruptor mid-game pushes (2.67× vs. PolyMorph) and early Oracle or Adept harassment.",
        "gaps": "Early 12-Pool Zergling rushes (improved by canceling unfinished expansions) and defending high-supply Roach/Ravager pushes.",
    },
    "TvP": {
        "working": "Marine/Marauder/Tank/Viking mid-game pushes (3.5–4.0× vs. puck and Creepy_strategies), Widow Mine drops, and 1.6% live supply-blocked time.",
        "gaps": "Pulling too much of the main army home against small Adept or Oracle raids, and late natural expansions when harassed early or cannon-rushed.",
    },
    "TvT": {
        "working": "81.8% live ladder win rate (9–1–1, 1.04× trade, including an 18-Tank zero-loss win over Slowpoke at 5.41×) and 1.7% local supply-blocked time.",
        "gaps": "Early enemy Reapers delaying our first Marines and Bunkers, and building extra Medivacs ahead of the first four Siege Tanks.",
    },
    "TvZ": {
        "working": "77.8% on the live ladder (7–1–1, 2.31× trade, including wins over titania and Carcara), backed by Widow Mine drops and Blue-Flame Hellion raids.",
        "gaps": "Scaling smoothly onto third-base Barracks after fixing the bug where dead Zerg buildings triggered false anti-air panics.",
    },
    "ZvP": {
        "working": "Fast 3.5-base economy, Queen/Drone mineral-line defense, and late-game Lurker/Ravager pushes when Zerg reaches Hive tech.",
        "gaps": "Weakest ladder matchup (3–8–1, 0.26× trade): third Hatcheries landed nearly three minutes later than pros (5:41 vs. 2:43), Hydralisks and Ravagers repeatedly burrowed mid-fight, and an outdated command ID prevented any Banelings from morphing (all targeted in Loop 49).",
    },
    "ZvT": {
        "working": "Five-base Roach/Hydra/Lurker/Brood Lord late games (2.61× live vs. oberon with 32 Lurkers), Reaper defense at 97% mining uptime, and Mutalisk spread against Thors.",
        "gaps": "Zero Banelings morphed across 1,070 games due to an outdated SC2 ability ID (fixed in Loop 49), late third Hatcheries (5:07 vs. 2:59 pro median), and extra Corruptors starving Hive tech against Terran Bio-Tank.",
    },
    "ZvZ": {
        "working": "9–0 on the recent live ladder (2.78× trade, including 10.63× vs. Carcara) with 3.8-base scaling and fast Zergling-to-Roach transitions.",
        "gaps": "Saving 300 minerals for a new Hatchery when supply is tight (2 or less free) or when an enemy Roach/Zergling push is already crossing the map.",
    },
}

CATEGORY_META: Dict[str, Tuple[str, str]] = {
    "detection-snipe": ("Sniping Detectors", "Kill Turrets, Cannons, Spores, Observers, Ravens, or Overseers first so cloaked and burrowed units can fight unrevealed."),
    "stalker-blink": ("Stalker Blink", "Blink wounded Stalkers to the back of the fight and blink forward together onto Siege Tanks, Colossi, or Liberators."),
    "runby-offense": ("Mineral-Line Raids", "Harass enemy workers with Widow Mine drops, Hellions, Adepts, Oracles, Banshees, Mutalisks, Zerglings, and Baneling drops."),
    "runby-defense": ("Defending Worker Harass", "Pull targeted workers away from Widow Mines, split against Hellions, and return to mining once the raid is cleared."),
    "stasis-ward": ("Oracle Stasis Traps", "Place Stasis Wards in mineral lines and chokes, or trigger enemy traps with a single cheap unit instead of the whole army."),
    "yamato-jump": ("Battlecruiser Yamato & Jump", "Focus Yamato Cannon on heavy targets and Tactical Jump damaged Battlecruisers home before they die."),
    "transport-nydus": ("Dropships & Nydus Worms", "Load and unload Medivacs, Warp Prisms, Baneling overlords, and Nydus Worms under fire."),
    "burrow-micro": ("Burrow & Ambush", "Heal burrowed Roaches, detonate Baneling traps, cast from burrowed Infestors, and leapfrog Lurkers and Widow Mines."),
    "spellcasters": ("Spellcasters", "Cast High Templar Storm/Feedback, Ghost EMP/Snipe, Raven Matrix/Missile, Viper Abduct/Cloud, and Infestor Fungal/Neural."),
    "kiting-concave": ("Kiting & Firing Arcs", "Stutter-step ranged units away from melee units and spread armies into wide arcs instead of clumping."),
    "flank-surround": ("Flanking Siege Lines", "Collapse on sieged Tanks from two angles at once instead of marching single-file down a choke."),
    "high-ground-ramp": ("Ramp & High-Ground Fights", "Hold top-of-ramp chokes and secure high-ground vision before pushing uphill."),
    "air-superiority": ("Air-to-Air Fights", "Spread Mutalisks (\"magic-box\") over Thors, lift ground threats with Phoenixes, and focus fire in Viking/Corruptor fights."),
    "early-rush-defense": ("Holding Early Rushes", "Survive 12-Pool Zerglings, early Reapers, and proxy builds without losing the mineral line."),
    "capital-endgame": ("Late-Game Fleets", "Fight across cliffs and open air with Carriers, Tempests, Brood Lords, Thors, and Vipers."),
    "regression": ("Past Ladder Losses", "Exact fights pulled from real ladder defeats, including 15-Probe worker rushes, cloaked Banshees, and early Zergling floods."),
}


# ---------------------------------------------------------------------------
# 1. iOS-Safari-Compatible Same-Origin MP4 Staging
# ---------------------------------------------------------------------------

def _transcode_one_ios_mp4(src: Path, cache_dst: Path) -> Tuple[Path, Optional[Path], bool, str]:
    """Transcode MP4 to H.264 Main Profile Level 3.1 yuv420p +faststart + lightweight JPG poster."""
    cache_dst.parent.mkdir(parents=True, exist_ok=True)
    poster_dst = cache_dst.with_suffix(".jpg")
    mp4_ready = (
        cache_dst.is_file()
        and cache_dst.stat().st_size > 4096
        and cache_dst.stat().st_mtime >= src.stat().st_mtime
    )
    if not mp4_ready:
        tmp_dst = cache_dst.with_suffix(".tmp.mp4")
        cmd = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(src),
            "-an",
            "-c:v",
            "libx264",
            "-profile:v",
            "main",
            "-level:v",
            "3.1",
            "-pix_fmt",
            "yuv420p",
            "-preset",
            "veryfast",
            "-crf",
            "28",
            "-vf",
            "scale=640:480:flags=lanczos",
            "-movflags",
            "+faststart",
            str(tmp_dst),
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0 or not tmp_dst.is_file() or tmp_dst.stat().st_size < 1024:
            if tmp_dst.exists():
                tmp_dst.unlink(missing_ok=True)
            return cache_dst, None, False, (proc.stderr or "ffmpeg failed")[:160]
        os.replace(tmp_dst, cache_dst)

    # Also build a compact ~35 KB same-origin JPG poster from sibling PNG (or MP4 frame)
    poster_src = src.with_suffix(".png")
    if not poster_src.is_file():
        poster_src = cache_dst
    poster_ready = (
        poster_dst.is_file()
        and poster_dst.stat().st_size > 1024
        and poster_dst.stat().st_mtime >= poster_src.stat().st_mtime
    )
    if not poster_ready:
        tmp_jpg = poster_dst.with_suffix(".tmp.jpg")
        pcmd = [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(poster_src),
            "-frames:v",
            "1",
            "-vf",
            "scale=640:480:flags=lanczos",
            "-q:v",
            "5",
            str(tmp_jpg),
        ]
        pproc = subprocess.run(pcmd, capture_output=True, text=True)
        if pproc.returncode == 0 and tmp_jpg.is_file() and tmp_jpg.stat().st_size > 512:
            os.replace(tmp_jpg, poster_dst)
        elif tmp_jpg.exists():
            tmp_jpg.unlink(missing_ok=True)

    return cache_dst, (poster_dst if poster_dst.is_file() else None), True, ("cached" if mp4_ready else "encoded")


def stage_ios_playable_mp4s(
    *,
    brain_dir: Path,
    out_dir: Path,
    priority_entries: List[Tuple[str, Path, str]],
    max_total_mb: float = 220.0,
    max_workers: int = 4,
) -> Tuple[Dict[str, str], Dict[str, str]]:
    """
    Stage iOS-Safari-native H.264 Main L3.1 MP4s and compact JPG posters directly
    into out_dir/media/ so GitHub Pages serves them same-origin with
    Content-Type: video/mp4, Accept-Ranges: bytes, and Content-Type: image/jpeg
    (avoiding GitHub Releases application/octet-stream + Content-Disposition: attachment).

    priority_entries: list of (key_url_or_id, local_mp4_path, safe_filename)
    in descending priority order.
    Returns (mp4_url_map, poster_url_map):
      - mp4_url_map:    key_url_or_id -> "./media/<safe_filename>"
      - poster_url_map: key_url_or_id -> "./media/<stem>.jpg"
    """
    cache_dir = brain_dir / "scratch" / "site_ios_mp4_cache"
    cache_dir.mkdir(parents=True, exist_ok=True)
    media_out = out_dir / "media"
    media_out.mkdir(parents=True, exist_ok=True)

    # Deduplicate by safe_filename preserving priority order
    unique_jobs: List[Tuple[str, Path, str]] = []
    seen_names: Dict[str, str] = {}
    key_to_name: Dict[str, str] = {}
    for key, src_p, safe_name in priority_entries:
        if not src_p.is_file():
            continue
        clean_name = re.sub(r"[^A-Za-z0-9._-]+", "_", safe_name)
        if not clean_name.lower().endswith(".mp4"):
            clean_name += ".mp4"
        key_to_name[key] = clean_name
        if clean_name not in seen_names:
            seen_names[clean_name] = str(src_p)
            unique_jobs.append((key, src_p, clean_name))

    if not unique_jobs:
        return {}, {}

    # Transcode in priority batches and stop once the gh-pages media budget is full
    # (avoids wasting CPU encoding hundreds of archived older-loop MP4s beyond the cap)
    budget_bytes = int(max_total_mb * 1024 * 1024)
    used_bytes = 0
    staged_names: set[str] = set()
    staged_posters: Dict[str, str] = {}
    batch_size = max(8, max_workers * 3)
    processed_jobs = 0
    skipped_for_budget = 0

    for start in range(0, len(unique_jobs), batch_size):
        if (used_bytes >= budget_bytes or skipped_for_budget >= 10) and len(staged_names) >= 24:
            break
        batch = unique_jobs[start : start + batch_size]
        encoded_batch: Dict[str, Tuple[Path, Optional[Path]]] = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
            futs = {
                pool.submit(_transcode_one_ios_mp4, src_p, cache_dir / cname): cname
                for _, src_p, cname in batch
            }
            for fut in concurrent.futures.as_completed(futs):
                cname = futs[fut]
                try:
                    dst, pdst, ok, _ = fut.result()
                    if ok and dst.is_file():
                        encoded_batch[cname] = (dst, pdst)
                except Exception:
                    continue
        processed_jobs += len(batch)
        for _, _, cname in batch:
            pair = encoded_batch.get(cname)
            if not pair:
                continue
            cdst, pdst = pair
            if not cdst.is_file():
                continue
            sz = cdst.stat().st_size + (pdst.stat().st_size if pdst and pdst.is_file() else 0)
            if used_bytes + sz > budget_bytes and len(staged_names) >= 24:
                skipped_for_budget += 1
                continue
            shutil.copy2(cdst, media_out / cname)
            used_bytes += cdst.stat().st_size
            staged_names.add(cname)
            if pdst and pdst.is_file():
                pname = Path(cname).with_suffix(".jpg").name
                shutil.copy2(pdst, media_out / pname)
                used_bytes += pdst.stat().st_size
                staged_posters[cname] = f"./media/{pname}"

    mp4_url_map: Dict[str, str] = {}
    poster_url_map: Dict[str, str] = {}
    for key, cname in key_to_name.items():
        if cname in staged_names:
            mp4_url_map[key] = f"./media/{cname}"
        if cname in staged_posters:
            poster_url_map[key] = staged_posters[cname]
    print(
        f"  [iOS MP4] Staged {len(staged_names)} same-origin H.264 Main L3.1 MP4s "
        f"+ {len(staged_posters)} JPG posters ({used_bytes / (1024 * 1024):.1f} MB / {max_total_mb:.0f} MB cap, "
        f"processed {processed_jobs}/{len(unique_jobs)} candidates)"
    )
    return mp4_url_map, poster_url_map


# ---------------------------------------------------------------------------
# 2. Rich Live Telemetry Loader (SQLite + Pro Baselines + Arena 3.0 + Ledger)
# ---------------------------------------------------------------------------

def _median_or_none(vals: List[float]) -> Optional[float]:
    clean = [float(v) for v in vals if v is not None and v > 0]
    if not clean:
        return None
    return round(statistics.median(clean), 1)


def _fmt_mmss(sec: Optional[float]) -> str:
    if sec is None or sec <= 0:
        return "—"
    m, s = divmod(int(round(sec)), 60)
    return f"{m}:{s:02d}"


def load_rich_report_telemetry(
    *,
    sqlite_path: Path,
    repo_dir: Path,
    brain_dir: Path,
) -> Dict[str, Any]:
    """Load real matchup evaluations, minute curves, gas timings, APM, Arena 3.0 & flywheel stats."""
    out: Dict[str, Any] = {
        "matchups": {},
        "worker_curves": {"Protoss": [], "Terran": [], "Zerg": []},
        "army_curves": {"Protoss": [], "Terran": [], "Zerg": []},
        "pro_worker_curves": {"Protoss": {}, "Terran": {}, "Zerg": {}},
        "pro_matchups": {},
        "apm_by_race": {"Protoss": (222.8, 493.0), "Terran": (206.3, 481.0), "Zerg": (255.0, 718.0)},
        "live_perf": {"avg_step_ms": 3.51, "wire_rejects": 0, "total_replays": 3265, "prod_replays": 477},
        "arena3": {
            "total": 216, "fast_core": 69, "categories": [],
            "dummy_rec": "32–33–4", "dummy_trade": 1.04, "sp_rec": "29–35–5", "sp_trade": 0.78, "loop_num": 48,
            "peak_loop_num": 47, "peak_dummy_rec": "34–25–7", "peak_dummy_trade": 1.17,
        },
        "flywheel": {
            "transcript_steps": 68378,
            "recent_loops": 11,
            "hold_loops": 7,
            "h2h_caught_holds": 6,
            "saved_min_per_hold": 31,
            "total_wasted_min": 186,
            "ownership_pauses": 7,
            "perf_false_fails": 19,
        },
    }

    # A. Load Pro Baselines
    pb_path = repo_dir / "tools/iteration-loop/pro_baselines.json"
    if pb_path.is_file():
        try:
            pb = json.loads(pb_path.read_text(encoding="utf-8"))
            out["pro_matchups"] = pb.get("by_matchup", {})
            for rname in ("Protoss", "Terran", "Zerg"):
                br = pb.get("by_race", {}).get(rname, {})
                out["pro_worker_curves"][rname] = {
                    2: float(br.get("w2m", 20.0)),
                    4: float(br.get("w4m", 33.0)),
                    6: float(br.get("w6m", 46.0)),
                    8: float(br.get("w8m", 58.0)),
                    10: float(br.get("w10m", 66.0)),
                }
        except Exception:
            pass

    # B. Load Tactics Arena 3.0 Catalog + Latest Duel/Self-Play Results
    scen_path = repo_dir / "tools/arena-scenarios.json"
    cat_catalog: Dict[str, Dict[str, Any]] = {}
    if scen_path.is_file():
        try:
            sdata = json.loads(scen_path.read_text(encoding="utf-8"))
            scens = sdata.get("scenarios", [])
            out["arena3"]["total"] = len(scens)
            out["arena3"]["fast_core"] = sum(1 for s in scens if s.get("fast_core"))
            for s in scens:
                cat = str(s.get("category") or "other")
                ent = cat_catalog.setdefault(
                    cat, {"id": cat, "total": 0, "core": 0, "examples": [], "scoring_modes": set()}
                )
                ent["total"] += 1
                if s.get("fast_core"):
                    ent["core"] += 1
                ent["scoring_modes"].add(str(s.get("scoring_mode") or "combat"))
                if len(ent["examples"]) < 4:
                    desc = str(s.get("description") or s.get("id") or "")
                    desc = re.sub(r"^(?:Real SC2|Pro-DB|Match-forensics|Replay Regression|Econ-Harass)[^:]*:\s*", "", desc)
                    if len(desc) > 108:
                        desc = desc[:105].rsplit(" ", 1)[0].rstrip(" ,;:-(") + "…"
                    ent["examples"].append(desc)
        except Exception:
            pass

    # Find latest iter* arena JSONs AND track best recent dummy run honestly (loops >= 43 = 66-69 core suite)
    loop_scratch = brain_dir / "scratch" / "loop"
    latest_d_json: Optional[Path] = None
    latest_sp_json: Optional[Path] = None
    latest_loop_num = 0
    best_loop_num = 0
    best_dummy_trade = -1.0
    best_dummy_rec = ""
    if loop_scratch.is_dir():
        for p in loop_scratch.glob("tactics_sc2_duel_iter*.json"):
            m = re.search(r"iter(\d+)\.json$", p.name)
            if not m:
                continue
            lnum = int(m.group(1))
            sp_cand = loop_scratch / f"tactics_sc2_selfplay_iter{lnum}.json"
            if sp_cand.is_file() and lnum > latest_loop_num:
                latest_loop_num = lnum
                latest_d_json = p
                latest_sp_json = sp_cand
            if lnum >= 43:
                try:
                    ds_c = json.loads(p.read_text(encoding="utf-8")).get("summary", {})
                    tr_c = float(ds_c.get("agg_trade_ratio", ds_c.get("trade_ratio", ds_c.get("agg_trade", 0.0))) or 0.0)
                    if tr_c > best_dummy_trade:
                        best_dummy_trade = tr_c
                        best_loop_num = lnum
                        dw_c = int(ds_c.get("mothman_wins", ds_c.get("wins", 0)) or 0)
                        dl_c = int(ds_c.get("p2_wins", ds_c.get("losses", 0)) or 0)
                        dd_c = int(ds_c.get("draws", 0) or 0)
                        best_dummy_rec = f"{dw_c}–{dl_c}–{dd_c}"
                except Exception:
                    pass
    if best_loop_num:
        out["arena3"]["peak_loop_num"] = best_loop_num
        out["arena3"]["peak_dummy_rec"] = best_dummy_rec
        out["arena3"]["peak_dummy_trade"] = best_dummy_trade

    d_by_cat: Dict[str, Dict[str, Any]] = {}
    sp_by_cat: Dict[str, Dict[str, Any]] = {}
    if latest_d_json and latest_sp_json:
        try:
            dj = json.loads(latest_d_json.read_text(encoding="utf-8"))
            sj = json.loads(latest_sp_json.read_text(encoding="utf-8"))
            out["arena3"]["loop_num"] = latest_loop_num
            ds = dj.get("summary", {})
            ss = sj.get("summary", {})
            if ds:
                dw_t = int(ds.get("mothman_wins", ds.get("wins", 0)) or 0)
                dl_t = int(ds.get("p2_wins", ds.get("losses", 0)) or 0)
                dd_t = int(ds.get("draws", 0) or 0)
                out["arena3"]["dummy_rec"] = f"{dw_t}–{dl_t}–{dd_t}"
                out["arena3"]["dummy_trade"] = float(
                    ds.get("agg_trade_ratio", ds.get("trade_ratio", ds.get("agg_trade", 0.0))) or 0.0
                )
            if ss:
                sw_t = int(ss.get("mothman_wins", ss.get("wins", 0)) or 0)
                sl_t = int(ss.get("p2_wins", ss.get("losses", 0)) or 0)
                sd_t = int(ss.get("draws", 0) or 0)
                out["arena3"]["sp_rec"] = f"{sw_t}–{sl_t}–{sd_t}"
                out["arena3"]["sp_trade"] = float(
                    ss.get("agg_trade_ratio", ss.get("trade_ratio", ss.get("agg_trade", 0.0))) or 0.0
                )
            d_by_cat = dj.get("by_category", {}) or ds.get("by_category", {}) or {}
            sp_by_cat = sj.get("by_category", {}) or ss.get("by_category", {}) or {}
            # Compute fallback per-category rollups from scenario list if needed
            if not d_by_cat:
                for sc in dj.get("scenarios", dj.get("results", [])):
                    c = str(sc.get("category") or "other")
                    b = d_by_cat.setdefault(c, {"wins": 0, "losses": 0, "draws": 0, "k": 0.0, "l": 0.0})
                    r = str(sc.get("winner") or sc.get("outcome") or "").lower()
                    if r in ("mothman", "win", "p1", "pass", "econ_pass", "runby_pass"):
                        b["wins"] += 1
                    elif r in ("draw", "tie"):
                        b["draws"] += 1
                    else:
                        b["losses"] += 1
                    b["k"] += float(sc.get("enemy_lost_value", sc.get("killed_val", 0)) or 0)
                    b["l"] += float(sc.get("our_lost_value", sc.get("lost_val", 0)) or 0)
            if not sp_by_cat:
                for sc in sj.get("scenarios", sj.get("results", [])):
                    c = str(sc.get("category") or "other")
                    b = sp_by_cat.setdefault(c, {"wins": 0, "losses": 0, "draws": 0, "k": 0.0, "l": 0.0})
                    r = str(sc.get("winner") or sc.get("outcome") or "").lower()
                    if r in ("mothman", "win", "p1", "pass", "econ_pass", "runby_pass"):
                        b["wins"] += 1
                    elif r in ("draw", "tie"):
                        b["draws"] += 1
                    else:
                        b["losses"] += 1
                    b["k"] += float(sc.get("enemy_lost_value", sc.get("killed_val", 0)) or 0)
                    b["l"] += float(sc.get("our_lost_value", sc.get("lost_val", 0)) or 0)
        except Exception:
            pass

    ordered_cats: List[Dict[str, Any]] = []
    for cid, (clabel, cdesc) in CATEGORY_META.items():
        if cid not in cat_catalog:
            continue
        ci = cat_catalog[cid]
        dc = d_by_cat.get(cid, {})
        sc = sp_by_cat.get(cid, {})

        def _cat_stat(x: Dict[str, Any]) -> Tuple[int, int, int, float]:
            w = int(x.get("mothman_wins", x.get("wins", x.get("passes", 0))) or 0)
            l = int(x.get("p2_wins", x.get("losses", x.get("fails", 0))) or 0)
            dr = int(x.get("draws", 0) or 0)
            tr = x.get("agg_trade_ratio", x.get("trade_ratio", x.get("agg_trade")))
            if tr is None:
                kv = float(x.get("k", x.get("enemy_lost_val", 0)) or 0)
                lv = float(x.get("l", x.get("our_lost_val", 0)) or 0)
                tr = round(kv / max(1.0, lv), 2) if (kv or lv) else 0.0
            return w, l, dr, float(tr or 0.0)

        dw, dl, dd, dtr = _cat_stat(dc)
        sw, sl, sd, str_v = _cat_stat(sc)
        ordered_cats.append(
            {
                "id": cid,
                "label": clabel,
                "desc": cdesc,
                "total": ci["total"],
                "core": ci["core"],
                "examples": ci["examples"],
                "d_w": dw,
                "d_l": dl,
                "d_d": dd,
                "d_tr": dtr,
                "sp_w": sw,
                "sp_l": sl,
                "sp_d": sd,
                "sp_tr": str_v,
            }
        )
    out["arena3"]["categories"] = ordered_cats

    # C. Load Live SQLite Matchup Metrics, Minute Curves, Build Timings, Anomalies & APM
    if not sqlite_path.is_file():
        return out

    try:
        con = sqlite3.connect(f"file:{sqlite_path}?mode=ro", uri=True)
        cur = con.cursor()
        out["live_perf"]["total_replays"] = int(cur.execute("SELECT COUNT(*) FROM matches").fetchone()[0])
        out["live_perf"]["prod_replays"] = int(
            cur.execute("SELECT COUNT(*) FROM matches WHERE source_type='prod_aiarena'").fetchone()[0]
        )
        lp_row = cur.execute(
            """
            SELECT ROUND(AVG(avg_step_ms), 2), SUM(COALESCE(action_rejects, 0))
            FROM matches
            WHERE source_type='prod_aiarena' AND bot_build_version IN ('qpqqolmk_3b21fe7a', 'womqlpsp_6917245e')
              AND avg_step_ms IS NOT NULL AND avg_step_ms > 0 AND avg_step_ms < 50
            """
        ).fetchone()
        if lp_row and lp_row[0]:
            out["live_perf"]["avg_step_ms"] = float(lp_row[0])
            out["live_perf"]["wire_rejects"] = int(lp_row[1] or 0)

        # APM per race from match_cmd_summary
        for rname, avg_apm, max_apm in cur.execute(
            """
            SELECT m.our_race, ROUND(AVG(c.apm), 1), ROUND(MAX(c.apm), 1)
            FROM match_cmd_summary c JOIN matches m ON m.replay_id = c.replay_id
            WHERE c.user_id = m.our_player_id AND m.run_id LIKE '%iter4%'
            GROUP BY m.our_race
            """
        ).fetchall():
            if rname in out["apm_by_race"] and avg_apm:
                out["apm_by_race"][rname] = (float(avg_apm), float(max_apm or avg_apm))

        recent_local_where = """
            m.source_type='local_arena' AND COALESCE(m.is_selfplay,0)=0
            AND m.run_id NOT LIKE '%h2h%' AND m.run_id NOT LIKE '%smoke%' AND m.run_id NOT LIKE '%gauntlet%'
            AND (m.run_id LIKE '%iter42%' OR m.run_id LIKE '%iter43%' OR m.run_id LIKE '%iter44%'
                 OR m.run_id LIKE '%iter45%' OR m.run_id LIKE '%iter46%' OR m.run_id LIKE '%iter47%'
                 OR m.run_id LIKE '%iter48%')
        """

        # Per-matchup Local stats (All 26 external opponents)
        local_mu: Dict[str, Dict[str, Any]] = {}
        for r in cur.execute(
            f"""
            SELECT m.matchup, COUNT(*),
                   SUM(CASE WHEN LOWER(m.result)='win' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN LOWER(m.result)='loss' THEN 1 ELSE 0 END),
                   ROUND(SUM(m.killed_val)*1.0/NULLIF(SUM(m.lost_val),0), 2),
                   ROUND(AVG(m.sup_blk_pct), 1),
                   ROUND(AVG(m.w4m), 1),
                   ROUND(AVG(m.w6m), 1),
                   ROUND(AVG(m.peak_workers), 1),
                   ROUND(AVG(m.peak_army_val), 0),
                   ROUND(AVG(m.opp_peak_army_val), 0),
                   ROUND(AVG(m.peak_bases), 1),
                   ROUND(AVG(m.duration_sec)/60.0, 1)
            FROM matches m
            WHERE {recent_local_where}
              AND m.matchup IN ('PvP','PvT','PvZ','TvP','TvT','TvZ','ZvP','ZvT','ZvZ')
            GROUP BY m.matchup
            """
        ).fetchall():
            mu = r[0]
            n_m = int(r[1])
            w_m = int(r[2] or 0)
            l_m = int(r[3] or 0)
            t_m = max(0, n_m - w_m - l_m)
            local_mu[mu] = {
                "n": n_m,
                "w": w_m,
                "l": l_m,
                "t": t_m,
                "wr": round(100.0 * w_m / n_m, 1) if n_m else 0.0,
                "nl": round(100.0 * (w_m + t_m) / n_m, 1) if n_m else 0.0,
                "tr": float(r[4] or 0.0),
                "sb": float(r[5] or 0.0),
                "w4m": float(r[6] or 0.0),
                "w6m": float(r[7] or 0.0),
                "pkw": float(r[8] or 0.0),
                "pka": int(r[9] or 0),
                "opka": int(r[10] or 0),
                "bases": float(r[11] or 0.0),
                "dur_m": float(r[12] or 0.0),
            }

        # Per-matchup Local CORE14 stats (Benchmark core cohort, L42-L48)
        core_mu: Dict[str, Dict[str, Any]] = {}
        for r in cur.execute(
            f"""
            SELECT m.matchup, COUNT(*),
                   SUM(CASE WHEN LOWER(m.result)='win' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN LOWER(m.result)='loss' THEN 1 ELSE 0 END),
                   ROUND(SUM(m.killed_val)*1.0/NULLIF(SUM(m.lost_val),0), 2)
            FROM matches m
            WHERE {recent_local_where}
              AND m.opp_cohort='core_12'
              AND m.matchup IN ('PvP','PvT','PvZ','TvP','TvT','TvZ','ZvP','ZvT','ZvZ')
            GROUP BY m.matchup
            """
        ).fetchall():
            n_m = int(r[1])
            w_m = int(r[2] or 0)
            l_m = int(r[3] or 0)
            t_m = max(0, n_m - w_m - l_m)
            core_mu[r[0]] = {
                "n": n_m,
                "w": w_m,
                "l": l_m,
                "t": t_m,
                "wr": round(100.0 * w_m / n_m, 1) if n_m else 0.0,
                "nl": round(100.0 * (w_m + t_m) / n_m, 1) if n_m else 0.0,
                "tr": float(r[4] or 0.0),
            }

        # Per-matchup Prod stats (recent live builds: L37/L40/L42/L45/L48)
        prod_mu: Dict[str, Dict[str, Any]] = {}
        for r in cur.execute(
            """
            SELECT matchup, COUNT(*),
                   SUM(CASE WHEN LOWER(result)='win' THEN 1 ELSE 0 END),
                   SUM(CASE WHEN LOWER(result)='loss' THEN 1 ELSE 0 END),
                   ROUND(SUM(killed_val)*1.0/NULLIF(SUM(lost_val),0), 2),
                   ROUND(AVG(sup_blk_pct), 1)
            FROM matches
            WHERE source_type='prod_aiarena' AND COALESCE(is_selfplay,0)=0
              AND bot_build_version IN ('ltxmxpzu_e45b61eb','mwskxoml_ffb8aaf1','womqlpsp_6917245e','qpqqolmk_3b21fe7a','oyzplryr_dc3a33b6')
              AND matchup IN ('PvP','PvT','PvZ','TvP','TvT','TvZ','ZvP','ZvT','ZvZ')
            GROUP BY matchup
            """
        ).fetchall():
            n_m = int(r[1])
            w_m = int(r[2] or 0)
            l_m = int(r[3] or 0)
            t_m = max(0, n_m - w_m - l_m)
            prod_mu[r[0]] = {
                "n": n_m,
                "w": w_m,
                "l": l_m,
                "t": t_m,
                "wr": round(100.0 * w_m / n_m, 1) if n_m else 0.0,
                "tr": float(r[4] or 0.0),
                "sb": float(r[5] or 0.0),
            }

        # Per-matchup anomalies (iter42..47, player_side='p1')
        anom_mu: Dict[str, Dict[str, int]] = {m: {} for m in MATCHUPS_ORDER}
        for mu, aname, cnt in cur.execute(
            f"""
            SELECT m.matchup, a.anomaly_name, COUNT(*)
            FROM match_anomalies a JOIN matches m ON m.replay_id = a.replay_id
            WHERE a.player_side='p1' AND {recent_local_where}
              AND m.matchup IN ('PvP','PvT','PvZ','TvP','TvT','TvZ','ZvP','ZvT','ZvZ')
            GROUP BY m.matchup, a.anomaly_name
            """
        ).fetchall():
            anom_mu[mu][aname] = int(cnt)

        # Gas #1, Gas #2, and Natural Expansion median init timings per matchup
        gas_lists: Dict[str, Tuple[List[float], List[float]]] = {m: ([], []) for m in MATCHUPS_ORDER}
        nat_lists: Dict[str, List[float]] = {m: [] for m in MATCHUPS_ORDER}

        # Gas events ordered by replay_id, sec
        by_rep_gas: Dict[Tuple[str, str], List[float]] = {}
        for mu, rid, sec in cur.execute(
            f"""
            SELECT m.matchup, be.replay_id, be.sec
            FROM match_build_events be JOIN matches m ON m.replay_id = be.replay_id
            WHERE be.player_id = m.our_player_id AND be.event_type='init'
              AND be.unit_type IN ('Assimilator','AssimilatorRich','Refinery','RefineryRich','Extractor','ExtractorRich')
              AND {recent_local_where}
              AND m.matchup IN ('PvP','PvT','PvZ','TvP','TvT','TvZ','ZvP','ZvT','ZvZ')
            ORDER BY be.replay_id, be.sec ASC
            """
        ).fetchall():
            arr = by_rep_gas.setdefault((mu, str(rid)), [])
            if len(arr) < 2 and sec is not None and sec > 5:
                arr.append(float(sec))
        for (mu, _), secs in by_rep_gas.items():
            if len(secs) >= 1:
                gas_lists[mu][0].append(secs[0])
            if len(secs) >= 2:
                gas_lists[mu][1].append(secs[1])

        # Natural expansion (first townhall init after sec > 20)
        seen_nat_rep: set[str] = set()
        for mu, rid, sec in cur.execute(
            f"""
            SELECT m.matchup, be.replay_id, MIN(be.sec)
            FROM match_build_events be JOIN matches m ON m.replay_id = be.replay_id
            WHERE be.player_id = m.our_player_id AND be.event_type='init'
              AND be.unit_type IN ('Nexus','CommandCenter','Hatchery')
              AND be.sec > 20
              AND {recent_local_where}
              AND m.matchup IN ('PvP','PvT','PvZ','TvP','TvT','TvZ','ZvP','ZvT','ZvZ')
            GROUP BY m.matchup, be.replay_id
            """
        ).fetchall():
            rid_s = str(rid)
            if rid_s not in seen_nat_rep and sec is not None and sec < 420:
                seen_nat_rep.add(rid_s)
                nat_lists[mu].append(float(sec))

        # Minute 2..5 supply progression + Minute-4 supply distribution histogram + Natural timing histogram + Opening build order (first 4 min)
        sup_bins = [("<25", 0, 24.99), ("25–32", 25, 32.99), ("33–40", 33, 40.99), ("41–48", 41, 48.99), ("49+", 49, 999)]
        nat_bins = [("<1:15", 0, 74.99), ("1:15–1:45", 75, 104.99), ("1:45–2:15", 105, 134.99), ("2:15–3:00", 135, 179.99), ("3:00+ / 1B", 180, 99999)]
        sup_vals_by_mu: Dict[str, Dict[int, List[float]]] = {m: {2: [], 3: [], 4: [], 5: []} for m in MATCHUPS_ORDER}
        for mu, minute, food in cur.execute(
            f"""
            SELECT m.matchup, ms.minute, ms.food_used
            FROM match_minute_stats ms JOIN matches m ON m.replay_id = ms.replay_id
            WHERE ms.player_id = m.our_player_id AND ms.minute BETWEEN 2 AND 5
              AND {recent_local_where}
              AND m.matchup IN ('PvP','PvT','PvZ','TvP','TvT','TvZ','ZvP','ZvT','ZvZ')
            """
        ).fetchall():
            if food is not None and float(food) > 0:
                sup_vals_by_mu[mu][int(minute)].append(float(food))

        # Earliest init sec per building type per replay (first 4 min) for build-order style & timeline
        key_open_buildings = (
            "Pylon", "Gateway", "Assimilator", "AssimilatorRich", "CyberneticsCore", "Nexus",
            "RoboticsFacility", "TwilightCouncil", "Stargate", "ShieldBattery", "Forge",
            "SupplyDepot", "Barracks", "Refinery", "RefineryRich", "OrbitalCommand",
            "CommandCenter", "Factory", "Starport", "Bunker",
            "Hatchery", "SpawningPool", "Extractor", "ExtractorRich", "RoachWarren",
            "BanelingNest", "SpineCrawler", "EvolutionChamber", "Lair",
        )
        bld_label_map = {
            "Pylon": "Pylon", "Gateway": "Gateway", "Assimilator": "Gas #1", "AssimilatorRich": "Gas #1",
            "CyberneticsCore": "CyberCore", "Nexus": "Nat Nexus", "RoboticsFacility": "Robotics",
            "TwilightCouncil": "Twilight", "Stargate": "Stargate", "ShieldBattery": "Battery", "Forge": "Forge",
            "SupplyDepot": "Depot", "Barracks": "Barracks", "Refinery": "Gas #1", "RefineryRich": "Gas #1",
            "OrbitalCommand": "Orbital", "CommandCenter": "Nat CC", "Factory": "Factory",
            "Starport": "Starport", "Bunker": "Bunker",
            "Hatchery": "Nat Hatch", "SpawningPool": "Pool", "Extractor": "Gas #1", "ExtractorRich": "Gas #1",
            "RoachWarren": "Roach Warren", "BanelingNest": "Bane Nest", "SpineCrawler": "Spine",
            "EvolutionChamber": "Evo", "Lair": "Lair",
        }
        placeholders_b = ",".join("?" for _ in key_open_buildings)
        rep_open_blds: Dict[str, Dict[str, Dict[str, float]]] = {m: {} for m in MATCHUPS_ORDER}
        for mu, rid, utype, sec in cur.execute(
            f"""
            SELECT m.matchup, be.replay_id, be.unit_type, MIN(be.sec)
            FROM match_build_events be JOIN matches m ON m.replay_id = be.replay_id
            WHERE be.player_id = m.our_player_id AND be.event_type='init'
              AND be.sec BETWEEN 5 AND 245
              AND be.unit_type IN ({placeholders_b})
              AND {recent_local_where}
              AND m.matchup IN ('PvP','PvT','PvZ','TvP','TvT','TvZ','ZvP','ZvT','ZvZ')
            GROUP BY m.matchup, be.replay_id, be.unit_type
            """,
            key_open_buildings,
        ).fetchall():
            # Skip starting townhall (sec <= 20)
            if utype in ("Nexus", "CommandCenter", "Hatchery") and (sec is None or float(sec) <= 20.0):
                continue
            lbl = bld_label_map.get(utype, utype)
            rmap = rep_open_blds[mu].setdefault(str(rid), {})
            val = float(sec)
            if lbl not in rmap or val < rmap[lbl]:
                rmap[lbl] = val

        # Load rendered 3D base & ramp-wall layout manifest + Pro vs Mothman geometric blueprint metrics if present
        base_manifest_by_mu: Dict[str, Dict[str, Any]] = {}
        bm_path = brain_dir / "scratch" / "base_layouts" / "base_layouts_manifest.json"
        if bm_path.is_file():
            try:
                for ent in json.loads(bm_path.read_text(encoding="utf-8")):
                    if ent.get("matchup"):
                        base_manifest_by_mu[str(ent["matchup"])] = ent
            except Exception:
                pass
        pro_bp_path = brain_dir / "scratch" / "base_layouts" / "pro_vs_mothman_base_metrics.json"
        if pro_bp_path.is_file():
            try:
                out["pro_base_metrics"] = json.loads(pro_bp_path.read_text(encoding="utf-8"))
            except Exception:
                out["pro_base_metrics"] = {}
        else:
            out["pro_base_metrics"] = {}

        for mu in MATCHUPS_ORDER:
            loc = local_mu.get(mu, {"n": 0, "w": 0, "l": 0, "t": 0, "wr": 0.0, "nl": 0.0, "tr": 0.0, "sb": 0.0, "w4m": 0.0, "w6m": 0.0, "pkw": 0.0, "pka": 0, "opka": 0, "bases": 0.0, "dur_m": 0.0})
            cor = core_mu.get(mu, {"n": 0, "w": 0, "l": 0, "t": 0, "wr": 0.0, "nl": 0.0, "tr": 0.0})
            prd = prod_mu.get(mu, {"n": 0, "w": 0, "l": 0, "t": 0, "wr": 0.0, "tr": 0.0, "sb": 0.0})
            an = anom_mu.get(mu, {})
            pm = out["pro_matchups"].get(mu, {})
            n_games = max(1, loc["n"])

            # Supply histogram at Minute 4 + median supply curve 2m..5m
            m4_vals = sup_vals_by_mu[mu][4]
            sup_hist = [
                {"label": lbl, "count": sum(1 for v in m4_vals if lo <= v <= hi)}
                for lbl, lo, hi in sup_bins
            ]
            sup_curve = {
                str(mi): (_median_or_none(sup_vals_by_mu[mu][mi]) or 0.0)
                for mi in (2, 3, 4, 5)
            }

            # Natural timing histogram (games without an early expand count in '3:00+ / 1B')
            n_vals = nat_lists[mu]
            no_nat_cnt = max(0, loc["n"] - len(n_vals))
            nat_hist = []
            for idx_b, (lbl, lo, hi) in enumerate(nat_bins):
                cnt = sum(1 for v in n_vals if lo <= v <= hi)
                if idx_b == len(nat_bins) - 1:
                    cnt += no_nat_cnt
                nat_hist.append({"label": lbl, "count": cnt})

            # Opening build order steps (first 4 min) & opening style percentages
            rmaps = rep_open_blds[mu]
            n_open = max(1, len(rmaps))
            by_bld: Dict[str, List[float]] = {}
            for rdict in rmaps.values():
                for blbl, bsec in rdict.items():
                    by_bld.setdefault(blbl, []).append(bsec)

            # Interpolate approximate supply at a given timestamp from 2m..5m median curve
            def _approx_sup(sec_val: float) -> int:
                m2 = sup_curve["2"] or 23.0
                m3 = sup_curve["3"] or 31.0
                m4 = sup_curve["4"] or 39.0
                if sec_val <= 120.0:
                    return int(round(12.0 + (m2 - 12.0) * max(0.0, sec_val) / 120.0))
                if sec_val <= 180.0:
                    return int(round(m2 + (m3 - m2) * (sec_val - 120.0) / 60.0))
                return int(round(m3 + (m4 - m3) * min(60.0, sec_val - 180.0) / 60.0))

            open_steps = []
            for blbl, secs in by_bld.items():
                pct = round(100.0 * len(secs) / n_open)
                if pct >= 35:
                    med_s = statistics.median(secs)
                    open_steps.append(
                        {
                            "name": blbl,
                            "sec": round(med_s, 1),
                            "time": _fmt_mmss(med_s),
                            "sup": _approx_sup(med_s),
                            "pct": pct,
                        }
                    )
            open_steps.sort(key=lambda x: x["sec"])
            open_steps = open_steps[:7]

            # Classify opening style distribution cleanly per race
            styles: List[str] = []
            race_code = mu[0]
            if race_code == "Z":
                hf = sum(1 for rd in rmaps.values() if rd.get("Nat Hatch", 999) < rd.get("Pool", 999))
                pf = len(rmaps) - hf
                styles.append(f"Hatch-First {round(100*hf/n_open)}%")
                styles.append(f"Pool-First {round(100*pf/n_open)}%")
                rw = sum(1 for rd in rmaps.values() if "Roach Warren" in rd)
                bn = sum(1 for rd in rmaps.values() if "Bane Nest" in rd)
                if rw >= bn:
                    styles.append(f"Roach Warren {round(100*rw/n_open)}%")
                if bn >= 0.25 * n_open:
                    styles.append(f"Baneling Nest {round(100*bn/n_open)}%")
            elif race_code == "T":
                fe = sum(1 for rd in rmaps.values() if rd.get("Nat CC", 999) <= 145)
                styles.append(f"Fast Expand (≤2:25) {round(100*fe/n_open)}%")
                styles.append(f"1-Base Tech / Press {round(100*(len(rmaps)-fe)/n_open)}%")
                fac = sum(1 for rd in rmaps.values() if "Factory" in rd)
                styles.append(f"1-1-1 Factory {round(100*fac/n_open)}%")
            else:
                if mu == "PvP":
                    fe = sum(1 for rd in rmaps.values() if rd.get("Nat Nexus", 999) <= 210)
                    styles.append(f"2-Gate Expand (≤3:30) {round(100*fe/n_open)}%")
                    styles.append(f"Delayed / 1-Base (>3:30) {round(100*(len(rmaps)-fe)/n_open)}%")
                else:
                    fe = sum(1 for rd in rmaps.values() if rd.get("Nat Nexus", 999) <= 130)
                    styles.append(f"Gate Fast-Expand {round(100*fe/n_open)}%")
                    styles.append(f"Delayed / 1-Base {round(100*(len(rmaps)-fe)/n_open)}%")
                rb = sum(1 for rd in rmaps.values() if "Robotics" in rd)
                tw = sum(1 for rd in rmaps.values() if "Twilight" in rd)
                if rb >= 0.25 * n_open:
                    styles.append(f"Robo Tech {round(100*rb/n_open)}%")
                if tw >= 0.20 * n_open:
                    styles.append(f"Twilight {round(100*tw/n_open)}%")

            bm_info = base_manifest_by_mu.get(mu, {})
            base_img = f"./media/base_layout_{mu}.jpg" if bm_info else ""
            base_cap = (
                f"In-game 3D capture from {bm_info.get('bot', 'Mothman')} vs. {bm_info.get('opp', 'opponent')} "
                f"on {bm_info.get('map', '')} ({bm_info.get('corner', '')} spawn, 4:10 game time): "
                f"main base and ramp wall on the left, second base and choke wall on the right."
                if bm_info
                else ""
            )

            out["matchups"][mu] = {
                "matchup": mu,
                "race": {"P": "Protoss", "T": "Terran", "Z": "Zerg"}[mu[0]],
                "local": loc,
                "core": cor,
                "prod": prd,
                "anomalies": an,
                "gas1_sec": _median_or_none(gas_lists[mu][0]),
                "gas2_sec": _median_or_none(gas_lists[mu][1]),
                "nat_sec": _median_or_none(nat_lists[mu]),
                "pro_gas1_sec": pm.get("gas1_sec"),
                "pro_gas2_sec": pm.get("gas2_sec"),
                "pro_nat_sec": pm.get("nat_sec"),
                "pro_w4m": pm.get("w4m"),
                "pro_w6m": pm.get("w6m"),
                "supply_hist": sup_hist,
                "supply_curve": sup_curve,
                "nat_hist": nat_hist,
                "opening_steps": open_steps,
                "opening_styles": styles,
                "base_img": base_img,
                "base_cap": base_cap,
                "working": MATCHUP_NOTES[mu]["working"],
                "gaps": MATCHUP_NOTES[mu]["gaps"],
            }

        # Minute-by-minute worker & army curves per race (1..10m workers, 1..12m army)
        for rname in ("Protoss", "Terran", "Zerg"):
            wpts = []
            apts = []
            for minute, wk, our_a, opp_a in cur.execute(
                f"""
                SELECT ms.minute,
                       ROUND(AVG(CASE WHEN ms.player_id = m.our_player_id THEN ms.workers_active END), 1),
                       ROUND(AVG(CASE WHEN ms.player_id = m.our_player_id THEN ms.army_value_total END), 0),
                       ROUND(AVG(CASE WHEN ms.player_id != m.our_player_id THEN ms.army_value_total END), 0)
                FROM match_minute_stats ms JOIN matches m ON m.replay_id = ms.replay_id
                WHERE m.our_race = ? AND {recent_local_where} AND ms.minute BETWEEN 1 AND 12
                GROUP BY ms.minute ORDER BY ms.minute ASC
                """,
                (rname,),
            ).fetchall():
                mi = int(minute)
                if mi <= 10 and wk is not None:
                    wpts.append({"m": mi, "w": float(wk)})
                if our_a is not None and opp_a is not None:
                    apts.append({"m": mi, "our": float(our_a), "opp": float(opp_a)})
            out["worker_curves"][rname] = wpts
            out["army_curves"][rname] = apts

        con.close()
    except Exception as exc:
        print(f"  [note] Rich telemetry fallback ({exc})", file=sys.stderr)

    return out


# ---------------------------------------------------------------------------
# 3. Clean Editorial SVG Charts (Anthropic Warm Palette)
# ---------------------------------------------------------------------------

def render_worker_curves_svg(
    worker_curves: Dict[str, List[Dict[str, float]]],
    pro_curves: Dict[str, Dict[int, float]],
    race: str,
) -> str:
    pts = worker_curves.get(race, [])
    pro = pro_curves.get(race, {})
    w, h = 560, 265
    pl, pr, pt, pb = 42, 24, 34, 38
    cw, ch = w - pl - pr, h - pt - pb
    max_w = 75.0

    def x_m(m: float) -> float:
        return pl + ((m - 1.0) / 9.0) * cw

    def y_w(val: float) -> float:
        return pt + ch - (max(0.0, min(max_w, val)) / max_w) * ch

    parts = [
        f'<svg viewBox="0 0 {w} {h}" class="chart-svg" role="img" '
        f'aria-label="{race} active workers over minutes 1 to 10 compared with Pro baseline">'
    ]
    for yv in (0, 20, 40, 60):
        yy = y_w(yv)
        parts.append(f'<line x1="{pl}" y1="{yy:.1f}" x2="{w-pr}" y2="{yy:.1f}" stroke="#E3E0D6" stroke-width="1" />')
        parts.append(f'<text x="{pl-8}" y="{yy+3.5:.1f}" text-anchor="end" fill="#7A7870" font-size="10.5">{yv}</text>')
    for mv in (1, 2, 4, 6, 8, 10):
        xx = x_m(mv)
        parts.append(f'<text x="{xx:.1f}" y="{h-pb+16}" text-anchor="middle" fill="#5E5D59" font-size="10.5">{mv}m</text>')

    # Pro dashed curve
    pro_items = sorted(pro.items())
    if pro_items:
        p_str = " ".join(f"{x_m(m):.1f},{y_w(v):.1f}" for m, v in pro_items)
        parts.append(
            f'<polyline fill="none" stroke="#4A6B82" stroke-width="2" stroke-dasharray="5,3" '
            f'stroke-linejoin="round" points="{p_str}" />'
        )
        for m, v in pro_items:
            parts.append(
                f'<circle cx="{x_m(m):.1f}" cy="{y_w(v):.1f}" r="3.1" fill="#4A6B82" stroke="#F4F2EA" stroke-width="1">'
                f"<title>Pro {race} at {m}m: {v:.0f} workers</title></circle>"
            )
        lm, lv = pro_items[-1]
        parts.append(
            f'<text x="{x_m(lm)-6:.1f}" y="{y_w(lv)-8:.1f}" text-anchor="end" fill="#4A6B82" font-size="10.5" font-weight="600">'
            f"Pro {lv:.0f}</text>"
        )

    # Mothman solid curve
    if pts:
        m_str = " ".join(f"{x_m(p['m']):.1f},{y_w(p['w']):.1f}" for p in pts)
        parts.append(
            f'<polyline fill="none" stroke="#C4633E" stroke-width="2.5" stroke-linejoin="round" points="{m_str}" />'
        )
        for p in pts:
            parts.append(
                f'<circle cx="{x_m(p["m"]):.1f}" cy="{y_w(p["w"]):.1f}" r="3.4" fill="#C4633E" stroke="#F4F2EA" stroke-width="1">'
                f"<title>Mothman {race} at {p['m']}m: {p['w']:.1f} workers</title></circle>"
            )
        lp = pts[-1]
        parts.append(
            f'<text x="{x_m(lp["m"]):.1f}" y="{min(h-pb-4, y_w(lp["w"])+18):.1f}" text-anchor="end" fill="#A34E2E" font-size="10.5" font-weight="600">'
            f"Mothman {lp['w']:.0f}</text>"
        )

    parts.append(
        f'<line x1="{pl}" y1="13" x2="{pl+18}" y2="13" stroke="#C4633E" stroke-width="2.5" />'
        f'<text x="{pl+23}" y="16.5" fill="#141413" font-size="11" font-weight="500">Mothman ({race})</text>'
        f'<line x1="{pl+148}" y1="13" x2="{pl+166}" y2="13" stroke="#4A6B82" stroke-width="2" stroke-dasharray="4,2" />'
        f'<text x="{pl+171}" y="16.5" fill="#141413" font-size="11" font-weight="500">Pro SC2 median</text>'
    )
    parts.append("</svg>")
    return "".join(parts)


def render_army_curves_svg(
    army_curves: Dict[str, List[Dict[str, float]]],
    race: str,
) -> str:
    pts = army_curves.get(race, [])
    w, h = 560, 265
    pl, pr, pt, pb = 48, 24, 34, 38
    cw, ch = w - pl - pr, h - pt - pb
    peak = max([3500.0] + [max(p["our"], p["opp"]) for p in pts])
    step = 1000 if peak <= 5000.0 else (2000 if peak <= 12000.0 else 5000)
    max_a = float(math.ceil(peak / step) * step)

    def x_m(m: float) -> float:
        return pl + ((m - 1.0) / 11.0) * cw

    def y_a(val: float) -> float:
        return pt + ch - (max(0.0, min(max_a, val)) / max_a) * ch

    parts = [
        f'<svg viewBox="0 0 {w} {h}" class="chart-svg" role="img" '
        f'aria-label="{race} army value over minutes 1 to 12 compared with opponents">'
    ]
    for yv in range(0, int(max_a) + 1, step):
        yy = y_a(yv)
        lbl = f"{yv//1000}k" if yv else "0"
        parts.append(f'<line x1="{pl}" y1="{yy:.1f}" x2="{w-pr}" y2="{yy:.1f}" stroke="#E3E0D6" stroke-width="1" />')
        parts.append(f'<text x="{pl-8}" y="{yy+3.5:.1f}" text-anchor="end" fill="#7A7870" font-size="10.5">{lbl}</text>')
    for mv in (2, 4, 6, 8, 10, 12):
        parts.append(f'<text x="{x_m(mv):.1f}" y="{h-pb+16}" text-anchor="middle" fill="#5E5D59" font-size="10.5">{mv}m</text>')

    if pts:
        opp_s = " ".join(f"{x_m(p['m']):.1f},{y_a(p['opp']):.1f}" for p in pts)
        our_s = " ".join(f"{x_m(p['m']):.1f},{y_a(p['our']):.1f}" for p in pts)
        parts.append(f'<polyline fill="none" stroke="#9C988E" stroke-width="2" stroke-dasharray="4,3" points="{opp_s}" />')
        parts.append(f'<polyline fill="none" stroke="#C4633E" stroke-width="2.5" stroke-linejoin="round" points="{our_s}" />')
        for p in pts:
            parts.append(
                f'<circle cx="{x_m(p["m"]):.1f}" cy="{y_a(p["our"]):.1f}" r="3.2" fill="#C4633E">'
                f"<title>{race} at {p['m']}m: Mothman {p['our']:,.0f} vs Opp {p['opp']:,.0f}</title></circle>"
            )
        lp = pts[-1]
        parts.append(
            f'<text x="{x_m(lp["m"])-4:.1f}" y="{y_a(lp["our"])+14:.1f}" text-anchor="end" fill="#A34E2E" font-size="10.5" font-weight="600">'
            f"{lp['our']/1000:.1f}k</text>"
        )
        parts.append(
            f'<text x="{x_m(lp["m"])-4:.1f}" y="{max(pt+10, y_a(lp["opp"])-8):.1f}" text-anchor="end" fill="#5E5D59" font-size="10.5" font-weight="600">'
            f"Opp {lp['opp']/1000:.1f}k</text>"
        )

    parts.append(
        f'<line x1="{pl}" y1="13" x2="{pl+18}" y2="13" stroke="#C4633E" stroke-width="2.5" />'
        f'<text x="{pl+23}" y="16.5" fill="#141413" font-size="11" font-weight="500">Mothman ({race})</text>'
        f'<line x1="{pl+148}" y1="13" x2="{pl+166}" y2="13" stroke="#9C988E" stroke-width="2" stroke-dasharray="4,2" />'
        f'<text x="{pl+171}" y="16.5" fill="#141413" font-size="11" font-weight="500">Opponent average</text>'
    )
    parts.append("</svg>")
    return "".join(parts)


def render_supply_block_svg(matchups: Dict[str, Dict[str, Any]]) -> str:
    w, h = 560, 250
    pl, pr, pt, pb = 52, 46, 28, 30
    cw = w - pl - pr
    max_sb = 8.0

    def x_s(v: float) -> float:
        return pl + (max(0.0, min(max_sb, v)) / max_sb) * cw

    parts = [f'<svg viewBox="0 0 {w} {h}" class="chart-svg" role="img" aria-label="Supply-blocked percentage by matchup">']
    for pct in (0, 2, 4, 6, 8):
        xx = x_s(pct)
        parts.append(f'<line x1="{xx:.1f}" y1="{pt}" x2="{xx:.1f}" y2="{h-pb}" stroke="#E3E0D6" stroke-width="1" />')
        parts.append(f'<text x="{xx:.1f}" y="{h-pb+15}" text-anchor="middle" fill="#7A7870" font-size="10">{pct}%</text>')
    # 4% steady target line
    x4 = x_s(4.0)
    parts.append(
        f'<line x1="{x4:.1f}" y1="{pt-4}" x2="{x4:.1f}" y2="{h-pb}" stroke="#4A6B82" stroke-width="1.2" stroke-dasharray="3,3" />'
        f'<text x="{x4+4:.1f}" y="{pt-7}" fill="#4A6B82" font-size="9.5" font-weight="600">4% steady target</text>'
    )
    row_h = (h - pt - pb) / len(MATCHUPS_ORDER)
    for idx, mu in enumerate(MATCHUPS_ORDER):
        sb = float(matchups.get(mu, {}).get("local", {}).get("sb", 0.0))
        yy = pt + idx * row_h + 3
        bw = max(2.0, x_s(sb) - pl)
        fill = "#2F6B48" if sb <= 2.5 else ("#4A6B82" if sb <= 4.2 else "#C4633E")
        parts.append(f'<text x="{pl-8}" y="{yy+11:.1f}" text-anchor="end" fill="#141413" font-size="11" font-weight="600">{mu}</text>')
        parts.append(f'<rect x="{pl}" y="{yy:.1f}" width="{bw:.1f}" height="12" rx="2.5" fill="{fill}"><title>{mu}: {sb:.1f}% supply-blocked</title></rect>')
        parts.append(f'<text x="{pl+bw+6:.1f}" y="{yy+10.5:.1f}" fill="#4A4945" font-size="10.5">{sb:.1f}%</text>')
    parts.append("</svg>")
    return "".join(parts)


# ---------------------------------------------------------------------------
# 4. Interactive Section Builders (Zero Walls of Text!)
# ---------------------------------------------------------------------------

def render_video_element(
    *,
    src: str,
    poster: str,
    title: str,
    download_url: Optional[str] = None,
    playable_mp4: bool = True,
) -> str:
    """Render an iOS-Safari-safe video player (when same-origin MP4) or crisp poster+download card."""
    esc_title = html.escape(title)
    esc_src = html.escape(src, quote=True)
    esc_poster = html.escape(poster, quote=True) if poster else ""
    esc_dl = html.escape(download_url or src, quote=True)
    if playable_mp4:
        p_attr = f' poster="{esc_poster}"' if esc_poster else ""
        return (
            f'<div class="clip-video-wrap">'
            f'<video class="clip-video" controls playsinline webkit-playsinline preload="metadata"{p_attr}>'
            f'<source src="{esc_src}" type="video/mp4" />'
            f"</video>"
            f"</div>"
            f'<div class="video-bar">'
            f'<button type="button" class="text-btn video-theater-btn" '
            f'data-video-src="{esc_src}" data-video-poster="{esc_poster}" data-video-title="{esc_title}">Expand</button>'
            f'<a class="text-btn" href="{esc_dl}" target="_blank" rel="noopener noreferrer">Download MP4</a>'
            f"</div>"
        )
    # Archived external MP4 fallback (never renders a broken iOS AVPlayer box!)
    if esc_poster:
        return (
            f'<img class="clip-img" loading="lazy" decoding="async" src="{esc_poster}" alt="{esc_title}" '
            f'data-lightbox-src="{esc_poster}" data-lightbox-alt="{esc_title}" />'
            f'<div class="video-bar">'
            f'<a class="text-btn" href="{esc_dl}" target="_blank" rel="noopener noreferrer">Download MP4</a>'
            f'<a class="text-btn" href="{esc_poster}" target="_blank" rel="noopener noreferrer">Still frame</a>'
            f"</div>"
        )
    return (
        f'<div class="video-bar">'
        f'<a class="text-btn" href="{esc_dl}" target="_blank" rel="noopener noreferrer">Download MP4</a>'
        f"</div>"
    )


def render_loop_diagram_section(rich: Dict[str, Any]) -> str:
    lp = rich["live_perf"]
    a3 = rich["arena3"]
    peak_note = (
        f" · Loop {a3['peak_loop_num']} peak: {a3['peak_dummy_rec']} ({a3['peak_dummy_trade']:.2f}×)"
        if a3.get("peak_loop_num") and a3["peak_loop_num"] != a3["loop_num"]
        else ""
    )
    nodes = [
        {
            "id": "live",
            "title": "1. Live & Practice Games",
            "badge": "Step 1 · Replays",
            "what": (
                "Four Mothman bots play continuously on AI Arena and across local practice batches. "
                "Every replay is parsed into minute-by-minute worker counts, army values, expansion timings, and fault flags."
            ),
            "why": (
                "Win rate bounces around over ten-game samples. Recording economy curves and fault flags "
                "catches silent bugs, such as production stalling mid-game, even in matches Mothman wins."
            ),
            "metric": f"{lp['prod_replays']} public AI Arena matches · 0 crashes on Live Build 45",
        },
        {
            "id": "forensics",
            "title": "2. Review Why Games Were Lost",
            "badge": "Step 2 · Diagnosis",
            "what": (
                "We inspect the worst live and local losses along their match timelines to separate bad luck "
                "from repeatable bot mistakes, such as expanding late, building the wrong counter unit, or chasing kiting workers."
            ),
            "why": (
                "Starting from specific replays keeps us from guessing. Replay logs showed that dead Zerg buildings "
                "spawned Broodlings that tricked Terran into building 13 Vikings against a ground army."
            ),
            "metric": "Every code change targets a general bug seen in replays, never a hardcoded opponent name",
        },
        {
            "id": "code",
            "title": "3. Code Fixes",
            "badge": "Step 3 · Implementation",
            "what": (
                "Separate coding passes update three non-overlapping parts of the codebase: economy and enemy-tech rules, "
                "squad control in fights, and building placement plus command filtering."
            ),
            "why": (
                "Keeping economy scoring, unit control, and map geometry in separate files prevents merge conflicts "
                "and keeps spending logic untangled from low-level movement code."
            ),
            "metric": "Economy & scouting · Squad control · Building placement & command filter",
        },
        {
            "id": "verify",
            "title": "4. Fast Unit Tests",
            "badge": "Step 4 · 2 min",
            "what": (
                "Before launching StarCraft II, the build compiles and runs fast unit tests covering build-order math, "
                "unit control edge cases, command encoding, and whether spending rules ever deadlock on pro replay states."
            ),
            "why": (
                "Catching a broken limit or crash in two minutes of CPU tests avoids wasting half an hour "
                "running full StarCraft II games on a broken build."
            ),
            "metric": "Runs in 2 minutes on CPU · Blocks invalid game commands and spending deadlocks",
        },
        {
            "id": "arena",
            "title": "5. Combat Drills",
            "badge": "Step 5 · 25 sec per drill",
            "what": (
                f"The bot plays {a3['fast_core']} short combat and harassment scenarios inside the StarCraft II engine, "
                "testing detector sniping, Stalker Blink, Widow Mine drops, worker-rush defense, and spellcasters "
                "against a scripted AI and against itself."
            ),
            "why": (
                "Full ladder games take ten minutes to reach one fight. Twenty-second scenarios let us test "
                "a combat change and watch the video clip right away."
            ),
            "metric": (
                f"Loop {a3['loop_num']} core drills: {a3['dummy_rec']} ({a3['dummy_trade']:.2f}× trade) vs. scripted AI"
                f"{peak_note}"
            ),
        },
        {
            "id": "bench",
            "title": "6. Head-to-Head Gate & 84-Game Benchmark",
            "badge": "Step 6 · Release Gate",
            "what": (
                "Every candidate first plays a 6-game head-to-head set (about 2 minutes) against the build currently live on AI Arena. "
                "Only builds that beat or clear the live bot run the 30-minute, 84-game benchmark against 14 regular practice bots, "
                "12 held-out bots, and self-play."
            ),
            "why": (
                "That 2-minute head-to-head match caught all 8 regressed builds before they reached the ladder, "
                "and running it first spares 30 minutes of simulation whenever a candidate regresses."
            ),
            "metric": "8 bad builds held back before shipping · 12 held-out bots check for overfitting",
        },
        {
            "id": "ship",
            "title": "7. Package & Deploy to AI Arena",
            "badge": "Step 7 · Release",
            "what": (
                "Builds that beat the live bot and hold up across the 84-game benchmark compile into four standalone Linux bot packages, "
                "run a 4-game smoke check in StarCraft II, and upload to AI Arena."
            ),
            "why": (
                "A new version only replaces the ladder bot after beating it directly and clearing the full practice pool without crashes."
            ),
            "metric": "7 live releases shipped · Mothman-P at 1310 rating",
        },
        {
            "id": "flywheel",
            "title": "Reviewing Build & Test Logs",
            "badge": "Process Check",
            "what": (
                "After each pass, a script summarizes how long coding, testing, and benchmarking took "
                "and flags subsystems that were edited repeatedly across back-to-back runs."
            ),
            "why": (
                "Checking Loops 34–47 showed we had been running the 30-minute benchmark before the 2-minute head-to-head check "
                "that caught every bad build, wasting over three hours of simulation time."
            ),
            "metric": "Swapped the 2-minute head-to-head check ahead of the 30-minute benchmark in Loop 48",
        },
    ]
    nodes_json = json.dumps(nodes, ensure_ascii=False).replace("</", "<\\/")

    loop_svg = f"""
<svg viewBox="0 0 760 445" class="diagram-svg" id="loop-svg" role="img" aria-label="Seven-step testing and release cycle diagram">
  <defs>
    <marker id="arr-outer" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse">
      <path d="M 0 1.5 L 8.5 5 L 0 8.5 z" fill="#8C877A" />
    </marker>
    <marker id="arr-fw" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse">
      <path d="M 0 1.5 L 8.5 5 L 0 8.5 z" fill="#C4633E" />
    </marker>
  </defs>

  <!-- Subtle outer track guide -->
  <ellipse cx="380" cy="224" rx="286" ry="172" fill="none" stroke="#E5E1D6" stroke-width="1.5" stroke-dasharray="4,4" />

  <!-- Clockwise outer arrows -->
  <path d="M 465 56 Q 528 62 558 84" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-outer)" />
  <path d="M 656 146 Q 674 176 666 206" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-outer)" />
  <path d="M 636 274 Q 618 308 586 330" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-outer)" />
  <path d="M 480 378 L 456 382" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-outer)" />
  <path d="M 304 382 L 278 378" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-outer)" />
  <path d="M 152 332 Q 116 286 112 228" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-outer)" />
  <path d="M 156 144 Q 204 82 282 60" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-outer)" />

  <!-- Process check dashed arrows -->
  <path d="M 380 348 L 380 288" fill="none" stroke="#C4633E" stroke-width="2" stroke-dasharray="5,3" marker-end="url(#arr-fw)" />
  <text x="388" y="324" fill="#A34E2E" font-size="10.5" font-weight="600">Run timings</text>
  <path d="M 462 184 Q 504 162 532 146" fill="none" stroke="#C4633E" stroke-width="2" stroke-dasharray="5,3" marker-end="url(#arr-fw)" />
  <path d="M 298 258 Q 252 292 224 326" fill="none" stroke="#C4633E" stroke-width="2" stroke-dasharray="5,3" marker-end="url(#arr-fw)" />
  <text x="200" y="286" fill="#A34E2E" font-size="10.5" font-weight="600">Gate order</text>

  <!-- Node 0: Top Center (Live Games) -->
  <g class="svg-node is-active" data-loop-idx="0" tabindex="0" role="button" aria-label="1. Live and Practice Games">
    <rect x="288" y="20" width="184" height="62" rx="10" class="node-bg" />
    <text x="380" y="44" text-anchor="middle" class="node-title">1. Live &amp; Practice Games</text>
    <text x="380" y="63" text-anchor="middle" class="node-sub">AI Arena + local matches</text>
  </g>

  <!-- Node 1: Top Right (Review Losses) -->
  <g class="svg-node" data-loop-idx="1" tabindex="0" role="button" aria-label="2. Review Losses">
    <rect x="536" y="84" width="182" height="62" rx="10" class="node-bg" />
    <text x="627" y="108" text-anchor="middle" class="node-title">2. Review Losses</text>
    <text x="627" y="127" text-anchor="middle" class="node-sub">Find repeatable bugs</text>
  </g>

  <!-- Node 2: Mid Right (Code Fixes) -->
  <g class="svg-node" data-loop-idx="2" tabindex="0" role="button" aria-label="3. Code Fixes">
    <rect x="562" y="210" width="182" height="62" rx="10" class="node-bg" />
    <text x="653" y="234" text-anchor="middle" class="node-title">3. Code Fixes</text>
    <text x="653" y="253" text-anchor="middle" class="node-sub">Economy · Combat · Walls</text>
  </g>

  <!-- Node 3: Bottom Right (Fast Unit Tests) -->
  <g class="svg-node" data-loop-idx="3" tabindex="0" role="button" aria-label="4. Fast Unit Tests">
    <rect x="484" y="336" width="182" height="62" rx="10" class="node-bg" />
    <text x="575" y="360" text-anchor="middle" class="node-title">4. Fast Unit Tests</text>
    <text x="575" y="379" text-anchor="middle" class="node-sub">Compile &amp; logic checks (2m)</text>
  </g>

  <!-- Node 4: Bottom Center (Combat Drills) -->
  <g class="svg-node" data-loop-idx="4" tabindex="0" role="button" aria-label="5. Combat Drills">
    <rect x="298" y="354" width="164" height="62" rx="10" class="node-bg" />
    <text x="380" y="378" text-anchor="middle" class="node-title">5. Combat Drills</text>
    <text x="380" y="397" text-anchor="middle" class="node-sub">{a3['fast_core']} fast SC2 scenarios</text>
  </g>

  <!-- Node 5: Bottom Left (Beat Live Bot -> 84 Games) -->
  <g class="svg-node" data-loop-idx="5" tabindex="0" role="button" aria-label="6. Beat Live Bot then 84 Games">
    <rect x="76" y="336" width="204" height="62" rx="10" class="node-bg" />
    <text x="178" y="360" text-anchor="middle" class="node-title">6. Beat Live Bot → 84 Games</text>
    <text x="178" y="379" text-anchor="middle" class="node-sub">2m gate before 30m bench</text>
  </g>

  <!-- Node 6: Top Left (Deploy to Ladder) -->
  <g class="svg-node" data-loop-idx="6" tabindex="0" role="button" aria-label="7. Deploy to Ladder">
    <rect x="34" y="150" width="176" height="68" rx="10" class="node-bg" />
    <text x="122" y="177" text-anchor="middle" class="node-title">7. Deploy to Ladder</text>
    <text x="122" y="196" text-anchor="middle" class="node-sub">4 bots → AI Arena</text>
  </g>

  <!-- Node 7: CENTER HUB (Process Check) -->
  <g class="svg-node node-flywheel" data-loop-idx="7" tabindex="0" role="button" aria-label="Review build and test logs">
    <rect x="260" y="176" width="240" height="106" rx="14" class="node-bg-fw" />
    <text x="380" y="201" text-anchor="middle" class="node-kicker-fw">PROCESS CHECK</text>
    <text x="380" y="223" text-anchor="middle" class="node-title">Review Build &amp; Test Logs</text>
    <text x="380" y="243" text-anchor="middle" class="node-sub">Tracks slow steps &amp; repeat edits</text>
    <text x="380" y="261" text-anchor="middle" class="node-sub">Moved 2m gate ahead of 30m bench</text>
  </g>
</svg>
"""

    first = nodes[0]
    return f"""
<section class="section-rule wide-col" id="loop-section">
  <div class="section-head">
    <p class="section-num">Section 1</p>
    <h2 class="section-kicker">How We Test and Ship Changes</h2>
    <p class="section-intro">
      Every update goes through the same seven-step check before reaching the live ladder.
      After each pass, a script also checks our build and test logs to see where time was wasted
      or which rules kept getting edited back and forth.
    </p>
  </div>
  <div class="interactive-panel">
    <div class="diagram-stage">{loop_svg}</div>
    <div class="detail-drawer" id="loop-detail">
      <div class="detail-top-row">
        <div class="detail-title" id="loop-detail-title">{html.escape(first["title"])}</div>
        <span class="detail-badge" id="loop-detail-badge">{html.escape(first["badge"])}</span>
      </div>
      <div class="explain-grid">
        <div>
          <div class="mini-kicker">What happens here</div>
          <p class="detail-body" id="loop-detail-what">{html.escape(first["what"])}</p>
        </div>
        <div>
          <div class="mini-kicker">Why it matters</div>
          <p class="detail-body" id="loop-detail-why">{html.escape(first["why"])}</p>
        </div>
      </div>
      <div class="detail-metric" id="loop-detail-metric">{html.escape(first["metric"])}</div>
    </div>
  </div>
  <script>window.__LOOP_STAGES__ = {nodes_json};</script>
</section>
"""


def render_architecture_section(rich: Dict[str, Any]) -> str:
    lp = rich["live_perf"]
    a3 = rich["arena3"]

    pieces = {
        "sc2": {
            "title": "StarCraft II Engine (22.4 Steps / Sec)",
            "badge": "Game State",
            "what": "Every 45 milliseconds, StarCraft II sends everything visible on the map: our units, resources, building progress, and enemy units outside the fog of war.",
            "connects": "Feeds the six state readers and executes the filtered command batch returned at the end of the step.",
            "perf": f"{lp['avg_step_ms']:.2f} ms average bot step time (200 ms tournament limit) · 0 crashes on Build 45",
        },
        "econ": {
            "title": "Economy & Supply",
            "badge": "State Reader → Spending Queue",
            "what": "Tracks minerals, gas, active workers per base, free supply, and resources already promised to workers walking to build sites.",
            "connects": "Tells the spending queue what Mothman can afford right now, when supply is tight, and when a gas geyser has idle slots.",
            "perf": "Re-assigns empty gas geysers within 8 seconds · Terran supply-blocked 1.8% of match time",
        },
        "scout": {
            "title": "Scouting & Memory",
            "badge": "State Reader → Tech Inference & Combat",
            "what": "Remembers enemy units and buildings after they duck back into the fog of war, along with how long each base location has gone unscouted.",
            "connects": "Feeds sightings into enemy tech inference and tells combat squads where hidden bases or siege lines sit.",
            "perf": "Tracks fog-of-war tile visibility so raiders clear hidden corners instead of stalling",
        },
        "mirror": {
            "title": "Enemy Tech & Rush Inference",
            "badge": "Inference → Spending & Combat",
            "what": "Infers hidden tech and rushes from partial clues: an early Starport with a Tech Lab warns of cloaked Banshees, and 12 enemy workers crossing the map flags an all-in worker rush.",
            "connects": "Sends counter requests (such as rushing detection or canceling a greedy expansion) to both the spending queue and squad control.",
            "perf": "Ignores hallucinations and dead-building Broodlings that previously caused false air panics",
        },
        "prodb": {
            "title": "Pro Timing Targets",
            "badge": "Benchmarks → Spending Queue",
            "what": "Compares Mothman's worker count, base count, and gas timings against Grandmaster medians for the current matchup.",
            "connects": "Raises the priority of workers or expansions whenever economy growth falls behind normal ladder pace.",
            "perf": "Benchmarked per matchup from Grandmaster replays",
        },
        "fap": {
            "title": "Fight Simulator",
            "badge": "Simulation → Spending & Combat",
            "what": "Runs a fast local check on nearby friendly and enemy squads, accounting for unit types, splash damage, high ground, and siege range.",
            "connects": "Tells squads whether to press an attack, kite back, or retreat, and tells the spending queue when to stop droning and build army.",
            "perf": "Stops outnumbered Stalkers from blinking onto sieged Tank lines",
        },
        "map": {
            "title": "Map & Base Layout",
            "badge": "Geometry → Spending & Combat",
            "what": "Computes ramps, chokes, expansion pads, and mineral pockets from actual walking distances rather than compass directions, so layouts behave identically from north or south spawns.",
            "connects": "Gives safe wall and building spots to the build queue and flank or retreat paths to combat squads.",
            "perf": "Closed our 16-point north-spawn deficit on Ley Lines (53.3% North vs. 53.8% South live)",
        },
        "prio": {
            "title": "Build & Spending Queue (What to Build)",
            "badge": "Decision → Command Filter",
            "what": "Every tick, workers, supply buildings, expansions, tech, upgrades, and army units compete on one priority list. When an expensive item like a second Nexus (400 minerals) or Robotics Bay is almost affordable, it sets cash aside (\"escrow\") so cheaper units do not drain the bank first.",
            "connects": "Turns all six state readers into ranked build and train orders, then hands them to the command filter.",
            "perf": "Matches build-queue and executor facility caps so late-game production does not stall",
        },
        "micro": {
            "title": "Squad & Worker Control (How to Fight)",
            "badge": "Decision → Command Filter",
            "what": "Controls squads and workers in fights: sniping enemy detectors before cloaked units engage, blinking hurt Stalkers back, dropping Widow Mines into mineral lines, casting spells, and pulling workers against early rushes.",
            "connects": "Uses scouting memory, enemy tech clues, fight simulations, and map geometry to issue unit orders to the command filter.",
            "perf": f"Tested across {a3['total']} isolated combat, drop, spellcaster, and rush-defense scenarios",
        },
        "apm": {
            "title": "Command Priority Filter",
            "badge": "Output → StarCraft II",
            "what": "Both the build queue and combat control try to move units every tick. The filter sorts orders into four priority levels (1. Survival & Spells, 2. Combat, 3. Building & Training, 4. Routine Mining), drops duplicate clicks, and blocks lower-priority rules from overwriting urgent commands on the same unit.",
            "connects": "Merges orders from both decision modules into one conflict-free batch per game step.",
            "perf": f"{lp['wire_rejects']} rejected game commands · {lp['avg_step_ms']:.2f} ms average step time",
        },
    }

    walkthroughs = {
        "explore": {
            "label": "Inspect Parts",
            "active": ["prio"],
            "title": "Click any block on the diagram to see what it does",
            "steps": [],
        },
        "macro": {
            "label": "Example: Taking a 2nd Base",
            "active": ["sc2", "econ", "prodb", "map", "prio", "apm"],
            "title": "How Mothman saves 400 minerals for a second Nexus at 1:30 without Stalkers spending the cash",
            "steps": [
                "1. Economy & Supply sees 350 minerals and 20 Probes; Pro Timing Targets show Grandmasters take a second base around 1:33.",
                "2. Build & Spending Queue ranks the second Nexus ahead of training another Stalker and holds 350 minerals aside so Gateways pause for four seconds.",
                "3. Map & Base Layout picks the natural expansion pad using walking distance (identical from north or south spawns).",
                "4. Command Priority Filter sends the Build Nexus order at Priority 3 and locks that builder Probe so routine mining (Priority 4) cannot pull it back to minerals.",
            ],
        },
        "rush": {
            "label": "Example: 15-Probe Rush",
            "active": ["sc2", "scout", "mirror", "fap", "prio", "micro", "apm"],
            "title": "How the bot responds when 15 enemy Probes rush the main base at 1:00",
            "steps": [
                "1. Scouting & Memory counts 12+ enemy workers crossing the map, and Fight Simulator flags immediate danger at home.",
                "2. Enemy Tech Inference flags an all-in worker rush, turning off expansions, extra Supply Depots, and gas mining.",
                "3. Build & Spending Queue cancels unfinished expansions or gas buildings for a 75% refund and rushes out the first Zealot, Marine, or Spine Crawler and Zerglings.",
                "4. Squad & Worker Control pulls workers to fight while keeping 3 to 4 workers mining so income never hits zero, and Command Priority Filter locks those defenders at Priority 1.",
            ],
        },
        "cloak": {
            "label": "Example: Cloaked Banshee",
            "active": ["sc2", "scout", "mirror", "prio", "micro", "apm"],
            "title": "How the bot handles cloaked Banshees before they wipe a mineral line",
            "steps": [
                "1. Scouting & Memory spots a Starport with a Tech Lab (or workers taking invisible damage).",
                "2. Enemy Tech Inference flags a cloaked threat while ignoring false alarms like Sentry hallucinations.",
                "3. Build & Spending Queue bumps detection (Observer, Spore Crawler, or Missile Turret) ahead of normal army production.",
                "4. Squad & Worker Control pulls workers away from the Banshee until detection arrives, then focus-fires the revealed Banshee at Priority 2.",
            ],
        },
    }

    pieces_json = json.dumps(pieces, ensure_ascii=False).replace("</", "<\\/")
    walks_json = json.dumps(walkthroughs, ensure_ascii=False).replace("</", "<\\/")

    arch_svg = """
<svg viewBox="0 0 760 568" class="diagram-svg" id="arch-svg" role="img" aria-label="How the bot plays each frame: six game-state readers feeding build queue and squad control into a command priority filter">
  <defs>
    <marker id="arr-arch" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M 0 1.5 L 8.5 5 L 0 8.5 z" fill="#8C877A" />
    </marker>
    <marker id="arr-ret" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse">
      <path d="M 0 1.5 L 8.5 5 L 0 8.5 z" fill="#4A6B82" />
    </marker>
  </defs>

  <!-- Right-side feedback loop arrow: Command Priority Filter -> StarCraft II -->
  <path d="M 684 504 L 730 504 L 730 42 L 690 42" fill="none" stroke="#4A6B82" stroke-width="2.2" marker-end="url(#arr-ret)" />
  <text x="742" y="276" text-anchor="middle" fill="#4A6B82" font-size="11" font-weight="600" transform="rotate(-90 742 276)">Filtered commands sent 22×/sec</text>

  <!-- TOP BAND: StarCraft II Game State -->
  <g class="svg-node arch-svg-node" data-arch-id="sc2" tabindex="0" role="button" aria-label="StarCraft II Game State">
    <rect x="30" y="14" width="654" height="56" rx="10" class="node-bg-dark" />
    <text x="357" y="37" text-anchor="middle" fill="#FAF9F5" font-size="14" font-weight="600">StarCraft II Game State (every 45 ms)</text>
    <text x="357" y="55" text-anchor="middle" fill="#D4D0C5" font-size="11.5">Visible units, resources, supply, and terrain</text>
  </g>

  <!-- Fan-out arrows from SC2 to Readers -->
  <line x1="133" y1="70" x2="133" y2="106" stroke="#8C877A" stroke-width="1.8" marker-end="url(#arr-arch)" />
  <line x1="357" y1="70" x2="357" y2="106" stroke="#8C877A" stroke-width="1.8" marker-end="url(#arr-arch)" />
  <line x1="581" y1="70" x2="581" y2="106" stroke="#8C877A" stroke-width="1.8" marker-end="url(#arr-arch)" />

  <!-- Subtle grouping box around the 6 Game-State Readers -->
  <rect x="20" y="92" width="674" height="176" rx="12" fill="#F4F2EA" stroke="#E0DCD0" stroke-width="1.2" />
  <text x="34" y="108" fill="#7A7870" font-size="10.5" font-weight="600" letter-spacing="0.06em">SIX PARALLEL GAME-STATE READERS</text>

  <!-- Row 1 of Readers -->
  <g class="svg-node arch-svg-node" data-arch-id="econ" tabindex="0" role="button" aria-label="Economy and Supply reader">
    <rect x="32" y="116" width="204" height="64" rx="8" class="node-bg" />
    <text x="134" y="140" text-anchor="middle" class="node-title">Economy &amp; Supply</text>
    <text x="134" y="159" text-anchor="middle" class="node-sub">Minerals, gas, workers, free supply</text>
  </g>
  <g class="svg-node arch-svg-node" data-arch-id="scout" tabindex="0" role="button" aria-label="Scouting and Memory reader">
    <rect x="255" y="116" width="204" height="64" rx="8" class="node-bg" />
    <text x="357" y="140" text-anchor="middle" class="node-title">Scouting &amp; Memory</text>
    <text x="357" y="159" text-anchor="middle" class="node-sub">Seen enemies &amp; last-known positions</text>
  </g>
  <g class="svg-node arch-svg-node" data-arch-id="mirror" tabindex="0" role="button" aria-label="Enemy Tech Inference">
    <rect x="478" y="116" width="204" height="64" rx="8" class="node-bg-accent" />
    <text x="580" y="140" text-anchor="middle" class="node-title">Enemy Tech Inference</text>
    <text x="580" y="159" text-anchor="middle" class="node-sub">Guesses hidden tech &amp; early rushes</text>
  </g>
  <!-- Horizontal arrow: Scouting -> Enemy Tech Inference -->
  <line x1="459" y1="148" x2="476" y2="148" stroke="#C4633E" stroke-width="1.8" marker-end="url(#arr-fw)" />

  <!-- Row 2 of Readers -->
  <g class="svg-node arch-svg-node" data-arch-id="prodb" tabindex="0" role="button" aria-label="Pro Timing Targets">
    <rect x="32" y="192" width="204" height="64" rx="8" class="node-bg" />
    <text x="134" y="216" text-anchor="middle" class="node-title">Pro Timing Targets</text>
    <text x="134" y="235" text-anchor="middle" class="node-sub">Grandmaster worker, base &amp; gas curves</text>
  </g>
  <g class="svg-node arch-svg-node" data-arch-id="fap" tabindex="0" role="button" aria-label="Fight Simulator">
    <rect x="255" y="192" width="204" height="64" rx="8" class="node-bg" />
    <text x="357" y="216" text-anchor="middle" class="node-title">Fight Simulator</text>
    <text x="357" y="235" text-anchor="middle" class="node-sub">Estimates whether nearby units win</text>
  </g>
  <g class="svg-node arch-svg-node" data-arch-id="map" tabindex="0" role="button" aria-label="Map and Base Layout">
    <rect x="478" y="192" width="204" height="64" rx="8" class="node-bg" />
    <text x="580" y="216" text-anchor="middle" class="node-title">Map &amp; Base Layout</text>
    <text x="580" y="235" text-anchor="middle" class="node-sub">Ramps, chokes &amp; safe building spots</text>
  </g>

  <!-- Converging arrows from Readers into Decision Modules -->
  <path d="M 160 268 L 160 314" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <path d="M 320 268 L 265 314" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <path d="M 394 268 L 450 314" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <path d="M 554 268 L 554 314" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <text x="150" y="297" text-anchor="end" fill="#7A7870" font-size="10.5">Spending &amp; counter signals</text>
  <text x="566" y="297" fill="#7A7870" font-size="10.5">Threat &amp; target map</text>

  <!-- ROW 3: Two Parallel Decision Modules -->
  <g class="svg-node arch-svg-node is-active" data-arch-id="prio" tabindex="0" role="button" aria-label="Build and Spending Queue">
    <rect x="30" y="318" width="318" height="94" rx="10" class="node-bg" />
    <text x="189" y="340" text-anchor="middle" class="node-kicker-fw">ECONOMY · WHAT TO BUILD</text>
    <text x="189" y="361" text-anchor="middle" class="node-title">Build &amp; Spending Queue</text>
    <text x="189" y="381" text-anchor="middle" class="node-sub">Scores workers, bases, tech &amp; units each tick;</text>
    <text x="189" y="397" text-anchor="middle" class="node-sub">holds cash aside ("escrow") for big purchases</text>
  </g>

  <g class="svg-node arch-svg-node" data-arch-id="micro" tabindex="0" role="button" aria-label="Squad and Worker Control">
    <rect x="366" y="318" width="318" height="94" rx="10" class="node-bg" />
    <text x="525" y="340" text-anchor="middle" class="node-kicker-fw">COMBAT · HOW TO FIGHT</text>
    <text x="525" y="361" text-anchor="middle" class="node-title">Squad &amp; Worker Control</text>
    <text x="525" y="381" text-anchor="middle" class="node-sub">Kiting, Blink, spells, drops, detector sniping,</text>
    <text x="525" y="397" text-anchor="middle" class="node-sub">and pulling workers against rushes</text>
  </g>

  <!-- Converging arrows into Command Priority Filter -->
  <line x1="189" y1="412" x2="189" y2="454" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <line x1="525" y1="412" x2="525" y2="454" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <text x="200" y="439" fill="#7A7870" font-size="10.5">Build &amp; train orders</text>
  <text x="536" y="439" fill="#7A7870" font-size="10.5">Combat &amp; spell orders</text>

  <!-- ROW 4: Command Priority Filter -->
  <g class="svg-node arch-svg-node" data-arch-id="apm" tabindex="0" role="button" aria-label="Command Priority Filter">
    <rect x="30" y="458" width="654" height="94" rx="10" class="node-bg" />
    <text x="357" y="481" text-anchor="middle" class="node-title">Command Priority Filter</text>
    <text x="357" y="499" text-anchor="middle" class="node-sub">Drops duplicate clicks so routine mining never overwrites urgent combat or survival orders</text>
    <!-- Visual 1..4 priority levels -->
    <rect x="50" y="512" width="144" height="28" rx="5" fill="#FCECE6" stroke="#C4633E" stroke-width="1" />
    <text x="122" y="530" text-anchor="middle" fill="#A34E2E" font-size="10.5" font-weight="600">1 · Survival &amp; Spells</text>

    <rect x="206" y="512" width="144" height="28" rx="5" fill="#EEF3F6" stroke="#4A6B82" stroke-width="1" />
    <text x="278" y="530" text-anchor="middle" fill="#355166" font-size="10.5" font-weight="600">2 · Combat Control</text>

    <rect x="362" y="512" width="144" height="28" rx="5" fill="#F4F2EA" stroke="#B5B0A3" stroke-width="1" />
    <text x="434" y="530" text-anchor="middle" fill="#4A4945" font-size="10.5" font-weight="600">3 · Building &amp; Training</text>

    <rect x="518" y="512" width="144" height="28" rx="5" fill="#FAF9F5" stroke="#D5D1C5" stroke-width="1" />
    <text x="590" y="530" text-anchor="middle" fill="#7A7870" font-size="10.5" font-weight="600">4 · Routine Mining</text>
  </g>
</svg>
"""

    init_p = pieces["prio"]
    return f"""
<section class="section-rule wide-col" id="architecture-section">
  <div class="section-head">
    <p class="section-num">Section 2</p>
    <h2 class="section-kicker">How the Bot Plays Each Frame</h2>
    <p class="section-intro">
      Every 45 milliseconds, StarCraft II sends the current map state. Six independent readers digest economy,
      scouting, enemy tech clues, pro timing targets, local fight odds, and map geometry, then feed two modules:
      one scores <strong>what to build</strong>, and the other controls <strong>how units fight</strong>.
      At the bottom, a <strong>command filter</strong> drops duplicate clicks and stops routine mining orders
      from overwriting urgent combat actions.
    </p>
  </div>

  <div class="interactive-panel">
    <div class="walk-bar" role="tablist" aria-label="Frame decision examples">
      <button type="button" class="cat-pill is-active" data-walk-id="explore">Inspect Parts</button>
      <button type="button" class="cat-pill" data-walk-id="macro">Example: Taking a 2nd Base</button>
      <button type="button" class="cat-pill" data-walk-id="rush">Example: 15-Probe Rush</button>
      <button type="button" class="cat-pill" data-walk-id="cloak">Example: Cloaked Banshee</button>
    </div>

    <div class="diagram-stage">{arch_svg}</div>

    <div class="detail-drawer" id="arch-detail">
      <div class="detail-top-row">
        <div class="detail-title" id="arch-detail-title">{html.escape(init_p["title"])}</div>
        <span class="detail-badge" id="arch-detail-badge">{html.escape(init_p["badge"])}</span>
      </div>
      <div id="arch-piece-view">
        <div class="explain-grid">
          <div>
            <div class="mini-kicker">What it does</div>
            <p class="detail-body" id="arch-detail-what">{html.escape(init_p["what"])}</p>
          </div>
          <div>
            <div class="mini-kicker">How it connects</div>
            <p class="detail-body" id="arch-detail-connects">{html.escape(init_p["connects"])}</p>
          </div>
        </div>
        <div class="detail-metric" id="arch-detail-perf">{html.escape(init_p["perf"])}</div>
      </div>
      <ol class="walk-steps" id="arch-walk-steps" style="display:none;"></ol>
    </div>
  </div>

  <details style="margin-top:1.1rem;">
    <summary>Economy stalls targeted next (Loop 49)</summary>
    <p class="prose-tight" style="margin-top:0.65rem;">
      Across Loops 42–48 and our last two ladder builds, most macro losses still trace to seven recurring economy stalls.
      Instead of adding more one-off matchup patches, Loop 49 adds four general fallback checks to unstick blocked builds,
      rebalance mineral and gas workers, build supply ahead of production spikes, and resume halted structures.
    </p>
    <div class="table-wrap" style="margin-bottom:0.5rem;">
      <table>
        <thead>
          <tr>
            <th>Economy Stall</th>
            <th style="text-align:right">Matches</th>
            <th style="text-align:right">Loss Rate</th>
            <th>Loop 49 Fallback</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><strong>Supply-blocked on the minute</strong> (&lt;195 supply)</td><td style="text-align:right">168 (32.4%)</td><td style="text-align:right">81.1%</td><td>Queue supply based on active production rate</td></tr>
          <tr><td><strong>Worker count stalls early</strong> (&le;24 at 5m or &le;36 at 8m)</td><td style="text-align:right">123 (23.7%)</td><td style="text-align:right">87.8%</td><td>Enforce worker floors &amp; transfer off mined-out bases</td></tr>
          <tr><td><strong>Stuck saving cash for an unplaceable building</strong></td><td style="text-align:right">95 (18.3%)</td><td style="text-align:right">50.5%</td><td>Retry builder, widen placement search, then release cash</td></tr>
          <tr><td><strong>Too much gas with no minerals</strong> (or 0 gas workers at 5m+)</td><td style="text-align:right">72 / 63</td><td style="text-align:right">66.7% / 42.7%</td><td>Move workers from gas to minerals at 450G / &lt;200M</td></tr>
          <tr><td><strong>Zero mineral income for a full cycle</strong> (&ge;5 workers, 2m+)</td><td style="text-align:right">49 (9.4%)</td><td style="text-align:right">63.9%</td><td>Force workers back to open mineral patches or expand</td></tr>
          <tr><td><strong>Terran opening stalls before Factory/Starport finish</strong></td><td style="text-align:right">32 (6.2%)</td><td style="text-align:right">90.6%</td><td>Send replacement SCV to finish halted Terran buildings</td></tr>
          <tr><td><strong>Unspent cash during early rushes or blocked build spots</strong></td><td style="text-align:right">15 / 10</td><td style="text-align:right">100.0%</td><td>Widen build-spot search &amp; spend idle minerals on units</td></tr>
        </tbody>
      </table>
    </div>
  </details>
  <script>
    window.__ARCH_PIECES__ = {pieces_json};
    window.__ARCH_WALKS__ = {walks_json};
  </script>
</section>
"""


def render_tactics_explorer_section(
    rich: Dict[str, Any],
    clips_by_cat: Optional[Dict[str, List[Dict[str, Any]]]] = None,
) -> str:
    a3 = rich["arena3"]
    cats = a3["categories"]
    clips_lookup = clips_by_cat or {}

    enriched_cats: List[Dict[str, Any]] = []
    for c in cats:
        entry = dict(c)
        entry["clips"] = clips_lookup.get(c["id"], [])[:4]
        enriched_cats.append(entry)

    cats_json = json.dumps(enriched_cats, ensure_ascii=False).replace("</", "<\\/")

    pills = []
    for idx, c in enumerate(enriched_cats):
        cls = "cat-pill is-active" if idx == 0 else "cat-pill"
        pills.append(
            f'<button type="button" class="{cls}" data-cat-idx="{idx}">'
            f'{html.escape(c["label"])} <span class="pill-n">{c["total"]}</span>'
            f"</button>"
        )

    first = enriched_cats[0] if enriched_cats else {
        "label": "Detection Sniping",
        "desc": "",
        "total": 20,
        "core": 8,
        "d_w": 3,
        "d_l": 4,
        "d_d": 1,
        "d_tr": 0.81,
        "sp_w": 3,
        "sp_l": 5,
        "sp_d": 0,
        "sp_tr": 0.48,
        "examples": [],
        "clips": [],
    }

    def _initial_clip_cards(clips: List[Dict[str, Any]]) -> str:
        cards = []
        for cl in clips:
            res_cls = "t-win" if cl.get("outcome") == "win" else ("t-loss" if cl.get("outcome") == "loss" else "t-muted")
            vhtml = render_video_element(
                src=cl["src"],
                poster=cl.get("poster", ""),
                title=cl["title"],
                download_url=cl.get("download_url") or cl["src"],
                playable_mp4=bool(cl.get("playable_mp4", True)),
            )
            cards.append(
                f'<article class="clip-card">'
                f'<div class="gallery-meta-row">'
                f'<span>{html.escape(cl.get("meta", ""))}</span>'
                f'<span class="{res_cls}">{html.escape(cl.get("result_label", ""))}</span>'
                f"</div>"
                f'<h4>{html.escape(cl["title"])}</h4>'
                f'<figure class="clip-figure">{vhtml}<figcaption>{html.escape(cl.get("caption", ""))}</figcaption></figure>'
                f"</article>"
            )
        return "".join(cards)

    peak_clause = ""
    if a3.get("peak_loop_num") and a3["peak_loop_num"] != a3["loop_num"] and a3.get("peak_dummy_trade", 0) > a3["dummy_trade"]:
        peak_clause = (
            f" (down slightly from Loop {a3['peak_loop_num']}'s {html.escape(a3['peak_dummy_rec'])} "
            f"at {a3['peak_dummy_trade']:.2f}× trade after upgrading raid drills to active mining bases)"
        )

    return f"""
<section class="section-rule wide-col" id="tactics-section">
  <div class="section-head">
    <p class="section-num">Section 3</p>
    <h2 class="section-kicker">Combat and Harassment Drills</h2>
    <p class="section-intro">
      Short, isolated fights and worker-defense scenarios run inside StarCraft II so we can test unit control
      without waiting ten minutes for a full match. On the {a3['fast_core']}-scenario fast check in Loop {a3['loop_num']},
      Mothman went <strong>{html.escape(a3['dummy_rec'])} ({a3['dummy_trade']:.2f}× trade)</strong> against the
      scripted attack-move AI and <strong>{html.escape(a3['sp_rec'])} ({a3['sp_trade']:.2f}× trade)</strong>
      against a copy of itself{peak_clause}.
    </p>
  </div>

  <div class="interactive-panel">
    <div class="cat-pills" role="tablist" aria-label="Combat drill categories">
      {"".join(pills)}
    </div>
    <div class="detail-drawer" id="cat-detail">
      <div class="detail-top-row">
        <div class="detail-title" id="cat-detail-title">{html.escape(first["label"])}</div>
        <span class="detail-badge" id="cat-detail-counts">{first["total"]} scenarios ({first["core"]} run every build)</span>
      </div>
      <p class="detail-body" id="cat-detail-desc">{html.escape(first["desc"])}</p>
      <div class="metric-strip metric-strip-2" id="cat-detail-metrics">
        <div class="m-chip"><span class="m-lbl">vs. Scripted AI</span><strong>{first["d_w"]}–{first["d_l"]}{f"–{first['d_d']}" if first["d_d"] else ""} ({first["d_tr"]:.2f}×)</strong></div>
        <div class="m-chip"><span class="m-lbl">vs. Mothman Copy</span><strong>{first["sp_w"]}–{first["sp_l"]}{f"–{first['sp_d']}" if first["sp_d"] else ""} ({first["sp_tr"]:.2f}×)</strong></div>
      </div>
      <div class="mini-kicker" style="margin-top:0.85rem;">Recorded Clips</div>
      <div class="featured-grid" id="cat-detail-clips" style="margin-top:0.5rem;">
        {_initial_clip_cards(first.get("clips", []))}
      </div>
    </div>
  </div>
  <script>window.__ARENA_CATS__ = {cats_json};</script>
</section>
"""


def _render_hist_svg(bins: List[Dict[str, Any]], color: str, aria_label: str) -> str:
    w, h = 340, 146
    pl, pr, pt, pb = 14, 14, 20, 30
    cw = w - pl - pr
    ch = h - pt - pb
    n = max(1, len(bins))
    max_c = max(1, max((int(b.get("count", 0)) for b in bins), default=1))
    gap = 8.0
    bw = max(14.0, (cw - gap * (n - 1)) / n)
    parts = [f'<svg viewBox="0 0 {w} {h}" class="chart-svg" role="img" aria-label="{html.escape(aria_label)}">']
    parts.append(f'<line x1="{pl}" y1="{h-pb}" x2="{w-pr}" y2="{h-pb}" stroke="#D8D4C8" stroke-width="1" />')
    for idx, b in enumerate(bins):
        cnt = int(b.get("count", 0))
        bh = (cnt / max_c) * ch if cnt > 0 else 0.0
        xx = pl + idx * (bw + gap)
        yy = h - pb - bh
        if bh > 0:
            parts.append(
                f'<rect x="{xx:.1f}" y="{yy:.1f}" width="{bw:.1f}" height="{max(2.0, bh):.1f}" rx="3" fill="{color}">'
                f'<title>{html.escape(str(b["label"]))}: {cnt} games</title></rect>'
            )
            parts.append(
                f'<text x="{xx + bw/2:.1f}" y="{max(12.0, yy - 4):.1f}" text-anchor="middle" '
                f'fill="#141413" font-size="10.5" font-weight="600">{cnt}</text>'
            )
        else:
            parts.append(
                f'<text x="{xx + bw/2:.1f}" y="{h - pb - 4:.1f}" text-anchor="middle" '
                f'fill="#A09C91" font-size="9.5">0</text>'
            )
        parts.append(
            f'<text x="{xx + bw/2:.1f}" y="{h - pb + 16:.1f}" text-anchor="middle" '
            f'fill="#5E5D59" font-size="9.5">{html.escape(str(b["label"]))}</text>'
        )
    parts.append("</svg>")
    return "".join(parts)


def _render_matchup_wr_svg(mu_list: List[Dict[str, Any]]) -> str:
    """Grouped bar chart of per-matchup win rate (%) exposing spread behind the overall average."""
    w, h = 720, 260
    pl, pr, pt, pb = 42, 18, 44, 42
    cw = w - pl - pr
    ch = h - pt - pb
    n = max(1, len(mu_list))
    slot_w = cw / n
    bw = min(20.0, slot_w * 0.30)
    gap = 4.0

    def _y(pct: float) -> float:
        return pt + ch * (1.0 - max(0.0, min(100.0, pct)) / 100.0)

    parts = [
        f'<svg viewBox="0 0 {w} {h}" class="chart-svg" role="img" aria-label="Win rate by matchup across Live AI Arena, Core14, and Local 26-bot roster">',
        # Legend at top
        f'<rect x="{pl}" y="8" width="11" height="11" rx="2" fill="#C4633E" />'
        f'<text x="{pl+16}" y="17.5" fill="#141413" font-size="11" font-weight="600">Live AI Arena (Builds 37–48)</text>'
        f'<rect x="{pl+204}" y="8" width="11" height="11" rx="2" fill="#4A6B82" />'
        f'<text x="{pl+220}" y="17.5" fill="#141413" font-size="11" font-weight="600">14 Core Bots (L42–48)</text>'
        f'<rect x="{pl+376}" y="8" width="11" height="11" rx="2" fill="#C5C0B4" />'
        f'<text x="{pl+392}" y="17.5" fill="#5E5D59" font-size="11">All 26 Local Bots</text>',
    ]
    # Horizontal gridlines (0, 25, 50, 75, 100)
    for gv in (0, 25, 50, 75, 100):
        yy = _y(gv)
        dash = ' stroke-dasharray="4 3"' if gv == 50 else ""
        col = "#9E9A8E" if gv == 50 else "#E7E3D8"
        parts.append(f'<line x1="{pl}" y1="{yy:.1f}" x2="{w-pr}" y2="{yy:.1f}" stroke="{col}" stroke-width="{1.2 if gv==50 else 1}"{dash} />')
        parts.append(f'<text x="{pl-6}" y="{yy+3.5:.1f}" text-anchor="end" fill="#7A7870" font-size="10">{gv}%</text>')

    # Group separators between Protoss / Terran / Zerg
    for sep_idx in (3, 6):
        sx = pl + sep_idx * slot_w
        parts.append(f'<line x1="{sx:.1f}" y1="{pt}" x2="{sx:.1f}" y2="{h-pb}" stroke="#E3DFD3" stroke-width="1" stroke-dasharray="2 3" />')

    for idx, m in enumerate(mu_list):
        cx = pl + (idx + 0.5) * slot_w
        prd = m.get("prod") or {}
        cor = m.get("core") or {}
        loc = m.get("local") or {}
        p_wr = float(prd.get("wr") or 0.0)
        c_wr = float(cor.get("wr") or 0.0)
        l_wr = float(loc.get("wr") or 0.0)
        bars = [
            (cx - bw * 1.5 - gap, p_wr, "#C4633E", f"{m['matchup']} Live AI Arena: {p_wr:.1f}% ({prd.get('w',0)}W-{prd.get('l',0)}L)"),
            (cx - bw * 0.5,       c_wr, "#4A6B82", f"{m['matchup']} Core-14: {c_wr:.1f}% ({cor.get('w',0)}W-{cor.get('l',0)}L)"),
            (cx + bw * 0.5 + gap, l_wr, "#C5C0B4", f"{m['matchup']} All 26 Local: {l_wr:.1f}% ({loc.get('w',0)}W-{loc.get('l',0)}L)"),
        ]
        for bx, val, fill, tip in bars:
            by = _y(val)
            bh = max(1.5, (h - pb) - by) if val > 0 else 0.0
            if bh > 0:
                parts.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bw:.1f}" height="{bh:.1f}" rx="2.5" fill="{fill}"><title>{html.escape(tip)}</title></rect>')
        # Label live WR% cleanly above terracotta bar so discrepancies jump out immediately
        py_lbl = _y(p_wr) - 5
        parts.append(
            f'<text x="{cx - bw - gap:.1f}" y="{py_lbl:.1f}" text-anchor="middle" fill="#A34E2E" font-size="9.5" font-weight="700">{p_wr:.0f}%</text>'
        )
        # Matchup label & n below axis
        parts.append(f'<text x="{cx:.1f}" y="{h-pb+16}" text-anchor="middle" fill="#141413" font-size="11.5" font-weight="600">{m["matchup"]}</text>')
        parts.append(f'<text x="{cx:.1f}" y="{h-pb+29}" text-anchor="middle" fill="#7A7870" font-size="9.2">{prd.get("w",0)}–{prd.get("l",0)} live</text>')

    parts.append("</svg>")
    return "".join(parts)


def render_matchup_evaluation_section(rich: Dict[str, Any]) -> str:
    mus = rich["matchups"]
    mu_list = [mus[m] for m in MATCHUPS_ORDER if m in mus]
    mu_json = json.dumps(mu_list, ensure_ascii=False).replace("</", "<\\/")

    # Interactive 9-matchup pills (top overview shows Live WR% right on each pill!)
    mu_pills = []
    base_pills = []
    for idx, m in enumerate(mu_list):
        cls = "cat-pill is-active" if idx == 0 else "cat-pill"
        p_wr = (m.get("prod") or {}).get("wr", 0.0)
        mu_pills.append(
            f'<button type="button" class="{cls}" data-mu-idx="{idx}">{m["matchup"]} · {p_wr:.0f}%</button>'
        )
        base_pills.append(
            f'<button type="button" class="{cls}" data-base-idx="{idx}">{m["matchup"]}</button>'
        )

    # Complete 9-matchup Win-Rate & Discrepancy summary table
    wr_svg = _render_matchup_wr_svg(mu_list)
    wr_rows = []
    for m in mu_list:
        prd = m.get("prod") or {}
        cor = m.get("core") or {}
        loc = m.get("local") or {}
        p_rec = f"{prd.get('w',0)}–{prd.get('l',0)}" + (f"–{prd['t']}" if prd.get("t") else "")
        c_rec = f"{cor.get('w',0)}–{cor.get('l',0)}" + (f"–{cor['t']}" if cor.get("t") else "")
        l_rec = f"{loc.get('w',0)}–{loc.get('l',0)}" + (f"–{loc['t']}" if loc.get("t") else "")
        p_wr = float(prd.get("wr") or 0.0)
        wr_cls = ' style="color:#1F6E43;font-weight:700;"' if p_wr >= 60.0 else (' style="color:#B43C2E;font-weight:700;"' if p_wr <= 40.0 else ' style="font-weight:600;"')
        wr_rows.append(
            f"<tr>"
            f"<td><strong>{m['matchup']}</strong></td>"
            f'<td style="text-align:right"><span{wr_cls}>{p_wr:.1f}%</span> <span class="t-muted">({p_rec})</span></td>'
            f'<td style="text-align:right">{float(prd.get("tr") or 0.0):.2f}×</td>'
            f'<td style="text-align:right"><strong>{float(cor.get("wr") or 0.0):.1f}%</strong> <span class="t-muted">({c_rec})</span></td>'
            f'<td style="text-align:right">{float(loc.get("wr") or 0.0):.1f}% <span class="t-muted">({l_rec})</span></td>'
            f'<td style="text-align:right">{float(loc.get("nl") or 0.0):.1f}%</td>'
            f'<td style="text-align:right">{float(loc.get("tr") or 0.0):.2f}×</td>'
            f"</tr>"
        )

    def _render_open_steps(steps: List[Dict[str, Any]]) -> str:
        if not steps:
            return '<span class="t-muted">Insufficient early build events.</span>'
        chips = []
        for s in steps:
            chips.append(
                f'<div class="bo-step">'
                f'<span class="bo-time">{html.escape(s["time"])} · {s["sup"]} sup</span>'
                f'<strong>{html.escape(s["name"])}</strong>'
                f'<span class="bo-pct">{s["pct"]}% of games</span>'
                f"</div>"
            )
        return "".join(chips)

    def _render_styles(styles: List[str]) -> str:
        return "".join(f'<span class="style-chip">{html.escape(st)}</span>' for st in styles)

    first = mu_list[0] if mu_list else None
    first_html = ""
    if first:
        loc = first["local"]
        cor = first.get("core") or {}
        prd = first["prod"]
        prd_s = f"{prd.get('wr',0):.1f}% · {prd['w']}–{prd['l']}" + (f"–{prd['t']}" if prd["t"] else "") + f" ({prd['tr']:.2f}× trade)" if prd["n"] else "—"
        cor_s = f"{cor.get('wr',0):.1f}% · {cor.get('w',0)}–{cor.get('l',0)}" + (f"–{cor['t']}" if cor.get("t") else "") + f" ({cor.get('tr',0):.2f}× trade)" if cor.get("n") else "—"
        loc_s = f"{loc.get('wr',0):.1f}% · {loc['w']}–{loc['l']}" + (f"–{loc['t']}" if loc["t"] else "") + f" ({loc['tr']:.2f}× trade)" if loc["n"] else "—"
        sc = first.get("supply_curve", {})
        sc_txt = f"2m: {sc.get('2', 0):.0f} · 3m: {sc.get('3', 0):.0f} · 4m: {sc.get('4', 0):.0f} · 5m: {sc.get('5', 0):.0f} median supply"
        sup_svg = _render_hist_svg(first.get("supply_hist", []), "#C4633E", f"{first['matchup']} minute 4 supply histogram")
        nat_svg = _render_hist_svg(first.get("nat_hist", []), "#4A6B82", f"{first['matchup']} natural expansion timing histogram")
        first_html = f"""
      <div class="detail-top-row">
        <div class="detail-title" id="mu-detail-title">{first['matchup']} ({first['race']})</div>
        <span class="detail-file" id="mu-detail-meta">Avg duration {loc['dur_m']:.1f}m · {loc['bases']:.1f} peak bases</span>
      </div>
      <div class="metric-strip" id="mu-detail-metrics">
        <div class="m-chip"><span class="m-lbl">Live Ladder</span><strong>{prd_s}</strong></div>
        <div class="m-chip"><span class="m-lbl">14 Core Bots (L42–48)</span><strong>{cor_s}</strong></div>
        <div class="m-chip"><span class="m-lbl">All 26 Local (L42–48)</span><strong>{loc_s}</strong></div>
        <div class="m-chip"><span class="m-lbl">Time Supply-Blocked</span><strong>{loc['sb']:.1f}%</strong></div>
        <div class="m-chip"><span class="m-lbl">Workers (4m / 6m / Peak)</span><strong>{loc['w4m']:.0f} / {loc['w6m']:.0f} / {loc['pkw']:.0f}</strong></div>
        <div class="m-chip"><span class="m-lbl">Peak Army Value (Us / Opp)</span><strong>{loc['pka']:,} / {loc['opka']:,}</strong></div>
      </div>

      <div class="bo-box">
        <div class="bo-header">
          <div class="mini-kicker" style="margin:0;">First 4 Minutes · Opening Build Order &amp; Style</div>
          <div class="style-chips" id="mu-open-styles">{_render_styles(first.get("opening_styles", []))}</div>
        </div>
        <div class="bo-strip" id="mu-open-steps">{_render_open_steps(first.get("opening_steps", []))}</div>
      </div>

      <div class="hist-pair">
        <div class="hist-card">
          <div class="mini-kicker">Supply Count Histogram (Minute 4)</div>
          <div id="mu-sup-hist">{sup_svg}</div>
          <div class="hist-foot" id="mu-sup-curve">{html.escape(sc_txt)}</div>
        </div>
        <div class="hist-card">
          <div class="mini-kicker">Natural Expansion Timing Histogram</div>
          <div id="mu-nat-hist">{nat_svg}</div>
          <div class="hist-foot" id="mu-nat-foot">Median: {_fmt_mmss(first['nat_sec'])} · Pro median: {_fmt_mmss(first['pro_nat_sec'])}</div>
        </div>
      </div>

      <div class="mu-two-col" style="margin-top:0.85rem;">
        <div>
          <div class="mini-kicker">What is working</div>
          <p class="detail-body" id="mu-detail-working">{html.escape(first['working'])}</p>
        </div>
        <div>
          <div class="mini-kicker">Where it breaks</div>
          <p class="detail-body" id="mu-detail-gaps">{html.escape(first['gaps'])}</p>
        </div>
      </div>
"""

    # Build 9-row fault tables (collapsed inside one developer <details>)
    layout_rows = []
    gas_rows = []
    mm_rows = []
    pvp_nat_delay_cnt = 0
    pvp_total_n = 0
    tvt_zero_tank_cnt = 0
    tvt_total_n = 0
    total_cloak_losses = 0
    for m in mu_list:
        mu = m["matchup"]
        loc = m["local"]
        an = m["anomalies"]
        n = max(1, loc["n"])
        prod_st = an.get("prod_placement_stall", 0)
        one_b = an.get("one_base_lockout", 0)
        if mu == "PvP":
            pvp_nat_delay_cnt = an.get("pvp_nat_delay", 0)
            pvp_total_n = loc["n"]
        layout_rows.append(
            f"<tr>"
            f"<td><strong>{mu}</strong></td>"
            f'<td style="text-align:right">{loc["bases"]:.1f}</td>'
            f'<td style="text-align:right">{_fmt_mmss(m["nat_sec"])} <span class="t-muted">(Pro {_fmt_mmss(m["pro_nat_sec"])})</span></td>'
            f'<td style="text-align:right">{prod_st}</td>'
            f'<td style="text-align:right">{one_b}</td>'
            f"</tr>"
        )
        gas_rich = an.get("gas_rich_min_starved", 0)
        gas_zero = an.get("gas_zero_harvest_freeze", 0)
        gas_rows.append(
            f"<tr>"
            f"<td><strong>{mu}</strong></td>"
            f'<td style="text-align:right">{_fmt_mmss(m["gas1_sec"])} <span class="t-muted">(Pro {_fmt_mmss(m["pro_gas1_sec"])})</span></td>'
            f'<td style="text-align:right">{_fmt_mmss(m["gas2_sec"])} <span class="t-muted">(Pro {_fmt_mmss(m["pro_gas2_sec"])})</span></td>'
            f'<td style="text-align:right">{gas_rich} / {n}</td>'
            f'<td style="text-align:right">{gas_zero}</td>'
            f"</tr>"
        )
        cloak_l = an.get("cloaked_unit_damage_loss", 0)
        total_cloak_losses += cloak_l
        aa_s = an.get("air_aa_starvation", 0)
        escr = an.get("escrow_lockouts", 0)
        if mu == "TvT":
            tvt_zero_tank_cnt = an.get("tvt_zero_tank", 0)
            tvt_total_n = loc["n"]
        mm_rows.append(
            f"<tr>"
            f"<td><strong>{mu}</strong></td>"
            f'<td style="text-align:right">{cloak_l}</td>'
            f'<td style="text-align:right">{aa_s}</td>'
            f'<td style="text-align:right">{escr}</td>'
            f"</tr>"
        )

    # Build 9-row Grandmaster Pro vs. Mothman Geometric Base Layout table (4:10)
    pro_bp_metrics = rich.get("pro_base_metrics") or {}
    pro_bp_rows = []
    for m in mu_list:
        mu = m["matchup"]
        pm_d = (pro_bp_metrics.get(mu) or {}).get("PRO") or {}
        mm_d = (pro_bp_metrics.get(mu) or {}).get("MOTHMAN") or {}
        if not pm_d and not mm_d:
            continue
        def _f_opt(v: Any, suffix: str = "") -> str:
            if v is None:
                return "—"
            return f"{float(v):.1f}{suffix}"
        def _f_pct(v: Any) -> str:
            if v is None:
                return "—"
            return f"{float(v):.0f}%"
        p_snn = _f_opt(pm_d.get("sup_nn"))
        m_snn = _f_opt(mm_d.get("sup_nn"))
        p_cl = _f_pct(pm_d.get("sup_clump_pct")) if pm_d.get("sup_nn") is not None else "—"
        m_cl = _f_pct(mm_d.get("sup_clump_pct")) if mm_d.get("sup_nn") is not None else "—"
        p_mw = _f_pct(pm_d.get("main_wall_pct"))
        m_mw = _f_pct(mm_d.get("main_wall_pct"))
        p_nw = _f_pct(pm_d.get("nat_wall_pct"))
        m_nw = _f_pct(mm_d.get("nat_wall_pct"))
        p_ns = _f_pct(pm_d.get("nat_sup_pct")) if pm_d.get("sup_nn") is not None else "—"
        m_ns = _f_pct(mm_d.get("nat_sup_pct")) if mm_d.get("sup_nn") is not None else "—"
        p_nd = _f_opt(pm_d.get("nat_def"))
        m_nd = _f_opt(mm_d.get("nat_def"))
        pro_bp_rows.append(
            f"<tr>"
            f"<td><strong>{mu}</strong> <span class=\"t-muted\">({pm_d.get('n',0)}/{mm_d.get('n',0)})</span></td>"
            f'<td style="text-align:right">{p_snn} / {m_snn}</td>'
            f'<td style="text-align:right">{p_cl} / {m_cl}</td>'
            f'<td style="text-align:right">{p_mw} / {m_mw}</td>'
            f'<td style="text-align:right">{p_nw} / {m_nw}</td>'
            f'<td style="text-align:right">{p_ns} / {m_ns}</td>'
            f'<td style="text-align:right">{p_nd} / {m_nd}</td>'
            f"</tr>"
        )

    pro_bp_block = ""
    if pro_bp_rows:
        pro_bp_block = f"""
    <div style="margin-top:1.65rem;">
      <h4 style="margin:0 0 0.45rem;font-family:var(--serif);font-size:1.15rem;font-weight:600;color:var(--ink);">
        Building Placement vs. Grandmaster Pros (4:10)
      </h4>
      <p class="prose-tight">
        Top-down building maps at 4:10 comparing Grandmaster games (herO, Stats, Maru, HeroMarine, Serral) on the left
        with Mothman on the right, rotated so the main base sits at the origin and the second base points right.
      </p>
      <div class="interactive-panel" style="margin-bottom:1.15rem;">
        <div class="race-toggle" role="tablist" aria-label="Select Pro vs Mothman blueprint race" style="margin-bottom:0.85rem;">
          <button type="button" class="cat-pill is-active" data-pro-bp-race="Protoss">Protoss</button>
          <button type="button" class="cat-pill" data-pro-bp-race="Terran">Terran</button>
          <button type="button" class="cat-pill" data-pro-bp-race="Zerg">Zerg</button>
        </div>
        <div class="pro-bp-slot" data-pro-bp-panel="Protoss">
          <figure class="clip-figure" style="margin:0;">
            <img class="clip-img base-layout-photo" src="./media/pro_vs_mothman_protoss.png"
                 alt="Protoss base layouts at 4:10 comparing Grandmaster pros and Mothman"
                 data-lightbox-src="./media/pro_vs_mothman_protoss.png"
                 data-lightbox-alt="Protoss base layouts at 4:10 comparing Grandmaster pros and Mothman" />
            <figcaption>Pros spread Pylons 14.5 to 19.5 tiles apart for vision and place Pylons and Shield Batteries at their second base in 73–100% of games. Mothman clumps 39–75% of its Pylons inside the main base, leaves PvP second bases unpowered (17% Natural Pylon), and occasionally puts its fragile Robotics Facility in the PvZ front wall.</figcaption>
          </figure>
        </div>
        <div class="pro-bp-slot" data-pro-bp-panel="Terran" style="display:none;">
          <figure class="clip-figure" style="margin:0;">
            <img class="clip-img base-layout-photo" src="./media/pro_vs_mothman_terran.png"
                 alt="Terran base layouts at 4:10 comparing Grandmaster pros and Mothman"
                 data-lightbox-src="./media/pro_vs_mothman_terran.png"
                 data-lightbox-alt="Terran base layouts at 4:10 comparing Grandmaster pros and Mothman" />
            <figcaption>Mothman's Depot-Barracks-Depot main ramp wall forms in 98–100% of games, matching Maru and HeroMarine. At the second base, though, Mothman walls with Supply Depots in only 28–41% of games (vs. 60–100% for pros), building 1.1–1.4 early Bunkers instead and stringing production buildings out vertically rather than in a tight add-on swap block.</figcaption>
          </figure>
        </div>
        <div class="pro-bp-slot" data-pro-bp-panel="Zerg" style="display:none;">
          <figure class="clip-figure" style="margin:0;">
            <img class="clip-img base-layout-photo" src="./media/pro_vs_mothman_zerg.png"
                 alt="Zerg base layouts at 4:10 comparing Grandmaster pros and Mothman"
                 data-lightbox-src="./media/pro_vs_mothman_zerg.png"
                 data-lightbox-alt="Zerg base layouts at 4:10 comparing Grandmaster pros and Mothman" />
            <figcaption>Serral tucks his Spawning Pool behind the Main Hatchery and puts Spore Crawlers inside each mineral line; Mothman places tech buildings and Spine Crawlers right in front of the Main Hatchery, blocking unit traffic. In ZvZ, pros wall their natural choke with Evolution Chambers and a Roach Warren in 48% of games vs. Mothman's 21%.</figcaption>
          </figure>
        </div>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Matchup <span class="t-muted">(Pro / Us)</span></th>
              <th style="text-align:right">Spacing</th>
              <th style="text-align:right">Clumped (&lt;5)</th>
              <th style="text-align:right">Main Wall</th>
              <th style="text-align:right">2nd Wall</th>
              <th style="text-align:right">2nd Power</th>
              <th style="text-align:right">2nd Defense</th>
            </tr>
          </thead>
          <tbody>{"".join(pro_bp_rows)}</tbody>
        </table>
      </div>
      <p class="table-note" style="margin-top:0.45rem;">All columns show Grandmaster Pro / Mothman at 4:10 (Main base at origin, second base along +X; spacing in tiles, walls and power in % of games, static defense in avg structures). Across our broader 398-game pro timing check, Mothman's third expansion also lands 109–178 seconds later than pro medians across all three races, Protoss exposes fragile tech in 68% of PvZ walls (vs. 31% for pros), and Terran production sits in a tight addon cluster in 50–58% of games (vs. 79–100% for pros).</p>
    </div>
"""

    # Pre-rendered per-race SVGs (toggled cleanly by race buttons!)
    wk_svgs = {
        r: render_worker_curves_svg(rich["worker_curves"], rich["pro_worker_curves"], r)
        for r in ("Protoss", "Terran", "Zerg")
    }
    ar_svgs = {
        r: render_army_curves_svg(rich["army_curves"], r)
        for r in ("Protoss", "Terran", "Zerg")
    }
    sb_svg = render_supply_block_svg(mus)

    return f"""
<section class="section-rule wide-col" id="matchups-section">
  <div class="section-head">
    <p class="section-num">Section 4</p>
    <h2 class="section-kicker">Results by Matchup</h2>
    <p class="section-intro">
      Overall averages hide a <strong>75-percentage-point spread across the nine matchups</strong>.
      On the live ladder, Mothman wins reliably in <strong>ZvZ (9–0, 100%)</strong>, <strong>TvT (9–1–1, 82%)</strong>,
      <strong>TvZ (7–1–1, 78%)</strong>, and <strong>PvT (6–2, 75%)</strong>, while all three losing matchups are
      against Protoss (<strong>ZvP 25%</strong>, <strong>TvP 33%</strong>, <strong>PvP 40%</strong>).
    </p>
    <p class="section-intro" style="margin-top:0.65rem;">
      Two patterns explain both the anti-Protoss slump and why Zerg trails our other bots by more than 50 rating points.
      Against Protoss, mid-game Gateway/Immortal/Colossus pushes and late-game Tempest fleets punish Mothman whenever
      counter-tech (Terran Vikings, Zerg Lurkers and Vipers, or PvP second bases) comes out late. For Zerg specifically,
      checking 1,070 clean replays uncovered three concrete bugs now targeted in Loop 49: Mothman built Baneling Nests in
      82% of longer games yet morphed <strong>zero Banelings</strong> because it sent an outdated command ID (80 instead of 4121);
      a defensive Burrow rule kept locking Hydralisks and Ravagers underground mid-fight; and third Hatcheries landed two to
      three minutes behind pro timings (5:41 vs. 2:43 in ZvP; 5:07 vs. 2:59 in ZvT), leaving Zerg outnumbered two-to-one in
      army value by Minute 10.
    </p>
  </div>

  <figure class="figure-block" style="margin-bottom:1.15rem;">
    <div class="figure-label">Figure 2 · Win Rate by Matchup</div>
    <div class="figure-title">Win rate (%) by matchup across live ladder and local sparring pools</div>
    {wr_svg}
    <figcaption class="figure-caption">
      Live AI Arena win rates (terracotta, Builds 37–48) alongside our 14 regular local sparring bots (slate, Loops 42–48)
      and all 26 local bots including 12 held-out opponents (gray). Local win rates run lower than ladder win rates because
      the 12 held-out bots include specialist cheese and stronger benchmark bots we do not tune against directly.
    </figcaption>
  </figure>

  <p class="table-note" style="margin:0 0 0.5rem;">
    Live records cover Builds 37–48 on AI Arena; local records cover Loops 42–48, where matches hitting the 30-minute limit count as ties (Win + Tie %).
  </p>
  <div class="table-wrap" style="margin-bottom:1.5rem;">
    <table>
      <thead>
        <tr>
          <th>Matchup</th>
          <th style="text-align:right">Live Ladder</th>
          <th style="text-align:right">Live Trade</th>
          <th style="text-align:right">14 Core Bots</th>
          <th style="text-align:right">All 26 Local</th>
          <th style="text-align:right">Win + Tie %</th>
          <th style="text-align:right">Local Trade</th>
        </tr>
      </thead>
      <tbody>{"".join(wr_rows)}</tbody>
    </table>
  </div>

  <div class="interactive-panel">
    <div class="cat-pills" role="tablist" aria-label="Select matchup">
      {"".join(mu_pills)}
    </div>
    <div class="detail-drawer" id="mu-detail">
      {first_html}
    </div>
  </div>

  <div class="eval-subsection">
    <h3>4.1 Base Layouts and Walls (at 4:10)</h3>
    <p class="prose-tight">
      In-game 3D captures of Mothman's main base, ramp wall, and second-base choke at 4:10 across all nine matchups,
      compared below against Grandmaster pro layouts.
    </p>
    <div class="interactive-panel" style="margin-bottom:1.15rem;">
      <div class="cat-pills" role="tablist" aria-label="Select base layout matchup" style="margin-bottom:0.8rem;">
        {"".join(base_pills)}
      </div>
      <figure class="clip-figure" style="margin:0;">
        <img id="base-layout-img" class="clip-img base-layout-photo"
             src="{html.escape(first.get('base_img', '') if first else '', quote=True)}"
             alt="{html.escape((first['matchup'] + ' main base and natural wall') if first else 'Base layout', quote=True)}"
             data-lightbox-src="{html.escape(first.get('base_img', '') if first else '', quote=True)}"
             data-lightbox-alt="{html.escape(first.get('base_cap', '') if first else '', quote=True)}" />
        <figcaption id="base-layout-cap">{html.escape(first.get('base_cap', '') if first else '')}</figcaption>
      </figure>
    </div>
    {pro_bp_block}
  </div>

  <div class="eval-subsection">
    <h3>4.2 Time Spent Supply-Blocked</h3>
    <p class="prose-tight">
      Terran spends just 1.7%–2.1% of match time supply-blocked across all three matchups, while Protoss and Zerg sit
      between 3.8% and 5.9% when early pressure kills Pylons or Overlords.
    </p>
    <figure class="figure-block">
      <div class="figure-label">Figure 3</div>
      <div class="figure-title">Average time supply-blocked by matchup (Loops 42–48, lower is better)</div>
      {sb_svg}
      <figcaption class="figure-caption">
        Percentage of match time unable to train units due to hitting supply cap (Pylon, Depot, or Overlord).
      </figcaption>
    </figure>
  </div>

  <div class="eval-subsection">
    <h3>4.3 Worker Count and Army Value Over Time</h3>
    <p class="prose-tight">
      Average active workers over the first 10 minutes (compared with Grandmaster medians) and total army resource value
      over the first 12 minutes (compared with local practice opponents). Notice how all three races fall behind opponent
      army value after Minute 8, steepest of all on Zerg (2.0k vs. 5.9k at Minute 12).
    </p>
    <div class="race-toggle" role="tablist" aria-label="Select race curves">
      <button type="button" class="cat-pill is-active" data-race-curve="Protoss">Protoss</button>
      <button type="button" class="cat-pill" data-race-curve="Terran">Terran</button>
      <button type="button" class="cat-pill" data-race-curve="Zerg">Zerg</button>
    </div>
    <div class="charts-pair">
      <figure class="figure-block" style="margin:0;">
        <div class="figure-label">Figure 4A · Workers</div>
        <div class="figure-title">Active workers (minutes 1–10) vs. Pro median</div>
        <div class="race-svg-slot" data-curve-kind="wk" data-race="Protoss">{wk_svgs["Protoss"]}</div>
        <div class="race-svg-slot" data-curve-kind="wk" data-race="Terran" style="display:none;">{wk_svgs["Terran"]}</div>
        <div class="race-svg-slot" data-curve-kind="wk" data-race="Zerg" style="display:none;">{wk_svgs["Zerg"]}</div>
      </figure>
      <figure class="figure-block" style="margin:0;">
        <div class="figure-label">Figure 4B · Army Value</div>
        <div class="figure-title">Total army value (minutes 1–12) vs. Opponents</div>
        <div class="race-svg-slot" data-curve-kind="ar" data-race="Protoss">{ar_svgs["Protoss"]}</div>
        <div class="race-svg-slot" data-curve-kind="ar" data-race="Terran" style="display:none;">{ar_svgs["Terran"]}</div>
        <div class="race-svg-slot" data-curve-kind="ar" data-race="Zerg" style="display:none;">{ar_svgs["Zerg"]}</div>
      </figure>
    </div>
  </div>

  <details style="margin-top:1.5rem;">
    <summary>Detailed expansion, gas, and tech-response fault counts by matchup (Loops 42–48)</summary>

    <div class="eval-subsection" style="margin-top:0.85rem;">
      <h4 style="margin:0 0 0.45rem;font-family:var(--serif);font-size:1.05rem;">Expansions &amp; Placement Stalls</h4>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Matchup</th>
              <th style="text-align:right">Peak Bases</th>
              <th style="text-align:right">Median 2nd Base (vs. Pro)</th>
              <th style="text-align:right">Placement Stalls</th>
              <th style="text-align:right">Stuck on 1 Base</th>
            </tr>
          </thead>
          <tbody>{"".join(layout_rows)}</tbody>
        </table>
      </div>
      <p class="table-note" style="margin-top:0.35rem;">PvP delayed second Nexus (&gt;3:00): {pvp_nat_delay_cnt} of {pvp_total_n} games.</p>
    </div>

    <div class="eval-subsection" style="margin-top:1.15rem;">
      <h4 style="margin:0 0 0.45rem;font-family:var(--serif);font-size:1.05rem;">Gas Timings &amp; Imbalances</h4>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Matchup</th>
              <th style="text-align:right">Gas #1 Median (vs. Pro)</th>
              <th style="text-align:right">Gas #2 Median (vs. Pro)</th>
              <th style="text-align:right">High Gas / Low Minerals</th>
              <th style="text-align:right">Empty Gas Geyser</th>
            </tr>
          </thead>
          <tbody>{"".join(gas_rows)}</tbody>
        </table>
      </div>
      <p class="table-note" style="margin-top:0.35rem;">Re-assigning idle gas geysers within 8 seconds eliminated empty-gas freezes in Loops 45, 47, and 48.</p>
    </div>

    <div class="eval-subsection" style="margin-top:1.15rem;">
      <h4 style="margin:0 0 0.45rem;font-family:var(--serif);font-size:1.05rem;">Detection, Anti-Air &amp; Spending Faults</h4>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Matchup</th>
              <th style="text-align:right">Cloak Wipeouts</th>
              <th style="text-align:right">Missing Anti-Air</th>
              <th style="text-align:right">Stuck Saving Cash</th>
            </tr>
          </thead>
          <tbody>{"".join(mm_rows)}</tbody>
        </table>
      </div>
      <p class="table-note" style="margin-top:0.35rem;">Cumulative fault counts across Loops 42–48 ({total_cloak_losses} cloak wipeouts total across earlier runs, dropping to 0 across all 84 games in Loop 47). TvT zero-Tank games: {tvt_zero_tank_cnt} of {tvt_total_n} games (down from 4 in Loop 45 to 1 in Loops 46–48).</p>
    </div>
  </details>
  <script>window.__MATCHUP_DATA__ = {mu_json};</script>
</section>
"""


def render_issues_fixed_section(chart_sym_svg: str, sym: Dict[str, Any], rich: Dict[str, Any]) -> str:
    fw = rich["flywheel"]
    return f"""
<section class="section-rule wide-col" id="issues-section">
  <div class="section-head">
    <p class="section-num">Section 5</p>
    <h2 class="section-kicker">Notable Bugs Found and Fixed</h2>
    <p class="section-intro">
      Five bugs we caught in replays and combat drills, what caused them in the code, and what changed after fixing them.
    </p>
  </div>

  <div class="case-grid">
    <article class="case-card case-wide">
      <div class="case-tag">Geometry &amp; Placement · Fixed in Loop 37</div>
      <h3>5.1 Losing More Often from Top-Half Spawns</h3>
      <div class="case-split">
        <div>
          <p><strong>Symptom:</strong> Bots won 16 percentage points less often when spawning north-east on Ley Lines (21.7% vs. 37.8%) and trailed by nearly 5 points across all northern spawns.</p>
          <p><strong>Root cause:</strong> Building placement and early scout offsets assumed the enemy sat roughly up and to the right, causing top-half spawns to wall off their own second base.</p>
          <p><strong>Fix &amp; result:</strong> Replaced compass-direction offsets with actual ground walking distances. Across {sym["post_n"]} local matches since Loop 37, north and south win rates leveled out ({sym["all_after_n"]:.1f}% vs. {sym["all_after_s"]:.1f}%), and Build 42 split 53.3% North vs. 53.8% South on the live ladder.</p>
        </div>
        <figure class="figure-block" style="margin:0;">
          <div class="figure-title" style="font-size:0.98rem;">North vs. South win rate before and after fix</div>
          {chart_sym_svg}
        </figure>
      </div>
    </article>

    <article class="case-card">
      <div class="case-tag">Enemy Tech Inference · Fixed in Loop 43</div>
      <h3>5.2 Dead Zerg Buildings Triggering Anti-Air Panic</h3>
      <p><strong>Symptom:</strong> Against pure ground Zerg (Roaches and Hydralisks), Terran suddenly built 4 Starports and 13 Vikings mid-game.</p>
      <p><strong>Root cause:</strong> Destroying any Zerg building spawns short-lived Broodlings. Our tech-prerequisite table mapped Broodlings to Brood Lords and a Greater Spire, tricking Terran into panicking against non-existent air units.</p>
      <p><strong>Fix &amp; result:</strong> Ignored Broodlings and Sentry hallucinations in tech inference. Unnecessary Viking builds dropped to zero and lifted Terran above a 1.0× overall trade ratio (1.02× locally, 1.64× live).</p>
    </article>

    <article class="case-card">
      <div class="case-tag">Unit Control · Fixed in Loops 43–46</div>
      <h3>5.3 Dark Templars Attacking Before Clearing Detectors</h3>
      <p><strong>Symptom:</strong> In drill p15, Dark Templars blinked straight onto a Terran Planetary Fortress while both Missile Turrets were still standing, dying to splash damage. Even when they killed the turrets, surviving Dark Templars merged into visible Archons or got recalled home by their own Nexus.</p>
      <p><strong>Fix &amp; result:</strong> Dark Templars now split into two groups to destroy nearby detectors first, stay cloaked instead of merging into Archons or taking Mass Recall when no enemy detection remains, and sweep unexplored fog tiles. Drill p15 flipped from a 0.33× loss to a 1.58× win with 14 of 27 Dark Templars surviving.</p>
    </article>

    <article class="case-card">
      <div class="case-tag">Spending &amp; Production · Fixed in Loop 48</div>
      <h3>5.4 Conflicting Barracks Limits Freezing Terran Production</h3>
      <p><strong>Symptom:</strong> In Terran mirrors and three benchmark games, Terran stopped building units for several seconds at a time while sitting on unspent minerals.</p>
      <p><strong>Root cause:</strong> The spending queue scheduled a 5th or 7th Barracks on three bases, while the build executor enforced an older cap of two Barracks per Command Center and quietly dropped the order every frame.</p>
      <p><strong>Fix &amp; result:</strong> Matched the executor's facility cap (up to 8) to the spending queue and added a unit test verifying that both modules agree on every building limit.</p>
    </article>

    <article class="case-card">
      <div class="case-tag">Testing Workflow · Shipped in Loop 48</div>
      <h3>5.5 Running a 2-Minute Check Before the 30-Minute Benchmark</h3>
      <p><strong>Symptom:</strong> Six of seven held builds lost their 2-minute head-to-head match against the live bot, yet our test script ran the 31-minute, 84-game benchmark first, wasting {fw['total_wasted_min']} minutes of simulation.</p>
      <p><strong>Fix &amp; result:</strong> Moved the 2-minute head-to-head gate and 25-second targeted combat drills ahead of the full 84-game benchmark, and added a warning whenever the same rule gets tweaked repeatedly across consecutive runs.</p>
    </article>
  </div>
</section>
"""


INTERACTIVE_SECTIONS_CSS = """
/* Structured Section Headers */
.section-head { max-width: 720px; margin-bottom: 1.35rem; }
.section-num {
  font-size: 0.74rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--accent);
  margin: 0 0 0.25rem;
}
.section-intro { font-size: 0.98rem; color: var(--ink-2); margin: 0; line-height: 1.58; }
.prose-tight { max-width: 700px; font-size: 0.95rem; margin: 0 0 0.9rem; line-height: 1.58; }

/* Quick Section Jump Bar */
.jump-bar {
  display: flex;
  flex-wrap: wrap;
  gap: 0.45rem 0.95rem;
  margin-top: 0.95rem;
  font-size: 0.88rem;
}
.jump-bar a { color: var(--ink-2); text-decoration: none; border-bottom: 1px solid var(--border); padding-bottom: 1px; }
.jump-bar a:hover { color: var(--accent); border-bottom-color: var(--accent); }

/* Interactive Panels & Detail Drawers */
.interactive-panel {
  background: var(--surface);
  border-radius: 10px;
  padding: 1.25rem;
  margin-bottom: 1.4rem;
}
/* Interactive SVG Diagrams & Walkthroughs */
.diagram-stage {
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 0.75rem 0.65rem;
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
}
.diagram-svg {
  width: 100%;
  height: auto;
  display: block;
  font-family: var(--sans);
}
.svg-node { cursor: pointer; outline: none; transition: opacity 0.18s ease; }
.svg-node .node-bg {
  fill: #FAF9F5;
  stroke: #D6D2C6;
  stroke-width: 1.5;
  transition: stroke 0.15s, fill 0.15s, stroke-width 0.15s;
}
.svg-node .node-bg-accent {
  fill: #FDF4F0;
  stroke: #DFB5A5;
  stroke-width: 1.5;
  transition: stroke 0.15s, fill 0.15s, stroke-width 0.15s;
}
.svg-node .node-bg-fw {
  fill: #FDF4F0;
  stroke: #C4633E;
  stroke-width: 1.8;
  stroke-dasharray: 5,3;
  transition: stroke 0.15s, fill 0.15s;
}
.svg-node .node-bg-dark {
  fill: #262522;
  stroke: #262522;
  stroke-width: 1.5;
  transition: stroke 0.15s, stroke-width 0.15s;
}
.svg-node:hover .node-bg,
.svg-node:hover .node-bg-accent,
.svg-node:hover .node-bg-fw { stroke: #C4633E; }
.svg-node.is-active .node-bg,
.svg-node.is-active .node-bg-accent,
.svg-node.is-active .node-bg-fw {
  fill: #FFFFFF;
  stroke: #C4633E;
  stroke-width: 2.6;
}
.svg-node.is-active .node-bg-dark {
  stroke: #C4633E;
  stroke-width: 2.8;
}
.svg-node.is-dim { opacity: 0.34; }
.node-title { fill: #141413; font-size: 13px; font-weight: 600; }
.node-sub { fill: #5E5D59; font-size: 11px; }
.node-kicker-fw { fill: #C4633E; font-size: 10px; font-weight: 700; letter-spacing: 0.06em; }

.walk-bar {
  display: flex;
  flex-wrap: wrap;
  gap: 0.42rem;
  margin-bottom: 0.8rem;
}
.walk-steps {
  margin: 0.45rem 0 0;
  padding-left: 1.25rem;
  font-size: 0.92rem;
  color: var(--ink-2);
  line-height: 1.56;
}
.walk-steps li { margin: 0.45rem 0; }
.detail-badge {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--accent);
  background: #FDF4F0;
  border: 1px solid #EBD1C6;
  border-radius: 999px;
  padding: 0.15rem 0.6rem;
  white-space: nowrap;
}
.explain-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.85rem 1.35rem;
  margin-bottom: 0.5rem;
}

.detail-drawer {
  margin-top: 0.95rem;
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 1rem 1.15rem;
}
.detail-top-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 0.75rem;
  flex-wrap: wrap;
  margin-bottom: 0.45rem;
}
.detail-title { font-family: var(--serif); font-size: 1.08rem; font-weight: 600; color: var(--ink); }
.detail-file { font-family: var(--mono); font-size: 0.76rem; color: var(--muted); }
.detail-body { font-size: 0.92rem; color: var(--ink-2); margin: 0 0 0.65rem; line-height: 1.56; }
.detail-metric {
  font-size: 0.84rem;
  font-weight: 500;
  color: var(--ink);
  background: var(--surface);
  padding: 0.45rem 0.7rem;
  border-radius: 6px;
  border-left: 3px solid var(--accent);
}
.compact-list { margin: 0.35rem 0 0.75rem; padding-left: 1.2rem; font-size: 0.89rem; color: var(--ink-2); }
.compact-list li { margin: 0.25rem 0; line-height: 1.48; }

.subsys-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1rem;
  margin-top: 1.15rem;
}
.subsys-card {
  background: var(--surface);
  border-radius: 8px;
  padding: 1rem 1.1rem;
}
.subsys-card h3 { margin: 0 0 0.4rem; font-size: 1.02rem; }
.subsys-card p { font-size: 0.89rem; margin: 0 0 0.65rem; line-height: 1.52; }
.mini-stat {
  font-size: 0.82rem;
  color: var(--ink-2);
  border-top: 1px solid var(--border);
  padding-top: 0.5rem;
}

/* Interactive Category & Matchup Pills */
.cat-pills, .race-toggle {
  display: flex;
  flex-wrap: wrap;
  gap: 0.42rem;
}
.race-toggle { margin-bottom: 0.85rem; }
.cat-pill {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 0.36rem 0.68rem;
  font-family: var(--sans);
  font-size: 0.83rem;
  font-weight: 500;
  color: var(--ink-2);
  cursor: pointer;
}
.cat-pill:hover { border-color: var(--accent); color: var(--ink); }
.cat-pill.is-active {
  background: var(--accent);
  border-color: var(--accent);
  color: #FFFFFF;
}
.cat-pill .pill-n { font-size: 0.76rem; opacity: 0.75; margin-left: 0.2rem; }

.metric-strip {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 0.55rem;
  margin: 0.55rem 0 0.85rem;
}
.metric-strip-2 {
  grid-template-columns: repeat(2, minmax(0, 1fr));
}
.m-chip {
  background: var(--surface);
  border-radius: 6px;
  padding: 0.5rem 0.65rem;
  display: flex;
  flex-direction: column;
  gap: 0.12rem;
}
.m-lbl { font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); }
.m-chip strong { font-size: 0.9rem; color: var(--ink); font-variant-numeric: tabular-nums; }
.mu-two-col {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.85rem 1.25rem;
}
.mini-kicker {
  font-size: 0.76rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--muted);
  margin-bottom: 0.25rem;
}

.eval-subsection { margin-top: 2rem; }
.eval-subsection h3 { margin: 0 0 0.45rem; font-size: 1.12rem; }
.charts-pair {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1.15rem;
}

/* Opening Build Order & Histograms + Base Layout Photos */
.bo-box {
  background: var(--surface);
  border-radius: 8px;
  padding: 0.75rem 0.85rem;
  margin: 0.75rem 0;
}
.bo-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.45rem 0.75rem;
  margin-bottom: 0.55rem;
}
.style-chips { display: flex; flex-wrap: wrap; gap: 0.35rem; }
.style-chip {
  font-size: 0.76rem;
  font-weight: 600;
  color: var(--ink);
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 999px;
  padding: 0.14rem 0.55rem;
}
.bo-strip {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(112px, 1fr));
  gap: 0.45rem;
}
.bo-step {
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 0.42rem 0.52rem;
  display: flex;
  flex-direction: column;
  gap: 0.08rem;
}
.bo-time { font-family: var(--mono); font-size: 0.7rem; color: var(--accent); font-weight: 600; }
.bo-step strong { font-size: 0.84rem; color: var(--ink); line-height: 1.25; }
.bo-pct { font-size: 0.71rem; color: var(--muted); }
.hist-pair {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.85rem;
  margin-top: 0.65rem;
}
.hist-card {
  background: var(--surface);
  border-radius: 8px;
  padding: 0.75rem 0.85rem 0.6rem;
}
.hist-foot {
  font-size: 0.78rem;
  color: var(--muted);
  margin-top: 0.25rem;
  font-variant-numeric: tabular-nums;
}
.base-layout-photo {
  border-radius: 8px;
  border: 1px solid var(--border);
  width: 100%;
  height: auto;
  display: block;
}

/* Case Study Cards */
.case-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1.15rem;
}
.case-card {
  background: var(--surface);
  border-radius: 10px;
  padding: 1.1rem 1.2rem;
}
.case-wide { grid-column: 1 / -1; }
.case-tag {
  font-size: 0.72rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--accent);
  margin-bottom: 0.25rem;
}
.case-card h3 { margin: 0 0 0.5rem; font-size: 1.06rem; }
.case-card p { font-size: 0.9rem; margin: 0 0 0.55rem; line-height: 1.54; }
.case-card p:last-child { margin-bottom: 0; }
.case-split {
  display: grid;
  grid-template-columns: minmax(0, 1fr) minmax(0, 1.08fr);
  gap: 1.2rem;
  align-items: start;
}

@media (max-width: 900px) {
  .subsys-grid, .charts-pair, .case-grid, .case-split, .mu-two-col, .explain-grid, .hist-pair { grid-template-columns: minmax(0, 1fr); }
}
@media (max-width: 699px) {
  .interactive-panel { padding: 0.9rem 0.75rem; }
  .detail-drawer { padding: 0.85rem; }
  .diagram-stage { padding: 0.5rem 0.35rem; }
  .metric-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
"""


INTERACTIVE_SECTIONS_JS = """
<script>
(function() {
  function esc(s) {
    return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }
  function fmtMmss(sec) {
    if (!sec || sec <= 0) return '—';
    const r = Math.round(sec);
    const m = Math.floor(r / 60);
    const s = r % 60;
    return m + ':' + (s < 10 ? '0' : '') + s;
  }

  // 1. Self-Improvement Dual-Loop SVG nodes
  const loopStages = window.__LOOP_STAGES__ || [];
  const loopNodes = document.querySelectorAll('[data-loop-idx]');
  function selectLoopNode(idx) {
    const st = loopStages[idx];
    if (!st) return;
    loopNodes.forEach(function(n) {
      n.classList.toggle('is-active', parseInt(n.getAttribute('data-loop-idx'), 10) === idx);
    });
    document.getElementById('loop-detail-title').textContent = st.title || '';
    document.getElementById('loop-detail-badge').textContent = st.badge || '';
    document.getElementById('loop-detail-what').textContent = st.what || '';
    document.getElementById('loop-detail-why').textContent = st.why || '';
    document.getElementById('loop-detail-metric').textContent = st.metric || '';
  }
  loopNodes.forEach(function(node) {
    node.addEventListener('click', function() { selectLoopNode(parseInt(node.getAttribute('data-loop-idx'), 10)); });
    node.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); selectLoopNode(parseInt(node.getAttribute('data-loop-idx'), 10)); }
    });
  });

  // 2. Architecture SVG pieces + Live Walkthroughs
  const archPieces = window.__ARCH_PIECES__ || {};
  const archWalks = window.__ARCH_WALKS__ || {};
  const archNodes = document.querySelectorAll('.arch-svg-node');
  const walkBtns = document.querySelectorAll('[data-walk-id]');
  const pieceView = document.getElementById('arch-piece-view');
  const walkStepsEl = document.getElementById('arch-walk-steps');

  function selectArchPiece(id) {
    const p = archPieces[id];
    if (!p) return;
    walkBtns.forEach(function(b) { b.classList.toggle('is-active', b.getAttribute('data-walk-id') === 'explore'); });
    archNodes.forEach(function(n) {
      const match = n.getAttribute('data-arch-id') === id;
      n.classList.toggle('is-active', match);
      n.classList.remove('is-dim');
    });
    document.getElementById('arch-detail-title').textContent = p.title || '';
    document.getElementById('arch-detail-badge').textContent = p.badge || '';
    document.getElementById('arch-detail-what').textContent = p.what || '';
    document.getElementById('arch-detail-connects').textContent = p.connects || '';
    document.getElementById('arch-detail-perf').textContent = p.perf || '';
    if (pieceView) pieceView.style.display = '';
    if (walkStepsEl) walkStepsEl.style.display = 'none';
  }

  function selectArchWalk(wid) {
    const w = archWalks[wid];
    if (!w) return;
    walkBtns.forEach(function(b) { b.classList.toggle('is-active', b.getAttribute('data-walk-id') === wid); });
    if (wid === 'explore') {
      selectArchPiece('prio');
      return;
    }
    const activeSet = new Set(w.active || []);
    archNodes.forEach(function(n) {
      const nid = n.getAttribute('data-arch-id');
      const isOn = activeSet.has(nid);
      n.classList.toggle('is-active', isOn);
      n.classList.toggle('is-dim', !isOn);
    });
    document.getElementById('arch-detail-title').textContent = w.title || '';
    document.getElementById('arch-detail-badge').textContent = 'Live Decision Trace';
    if (pieceView) pieceView.style.display = 'none';
    if (walkStepsEl) {
      walkStepsEl.innerHTML = (w.steps || []).map(function(st) { return '<li>' + esc(st) + '</li>'; }).join('');
      walkStepsEl.style.display = '';
    }
  }

  archNodes.forEach(function(node) {
    const nid = node.getAttribute('data-arch-id');
    node.addEventListener('click', function() { selectArchPiece(nid); });
    node.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); selectArchPiece(nid); }
    });
  });
  walkBtns.forEach(function(btn) {
    btn.addEventListener('click', function() { selectArchWalk(btn.getAttribute('data-walk-id')); });
  });

  // 3. Combat Drills Category Explorer WITH Per-Category Playable Video Clips
  const arenaCats = window.__ARENA_CATS__ || [];
  const catBtns = document.querySelectorAll('[data-cat-idx]');
  function renderArenaClipCard(cl) {
    const resCls = cl.outcome === 'win' ? 't-win' : (cl.outcome === 'loss' ? 't-loss' : 't-muted');
    const dlUrl = cl.download_url || cl.src;
    const pAttr = cl.poster ? ' poster="' + esc(cl.poster) + '"' : '';
    const vHtml =
      '<div class="clip-video-wrap">' +
        '<video class="clip-video" controls playsinline webkit-playsinline preload="metadata"' + pAttr + '>' +
          '<source src="' + esc(cl.src) + '" type="video/mp4" />' +
        '</video>' +
      '</div>' +
      '<div class="video-bar">' +
        '<button type="button" class="text-btn video-theater-btn" data-video-src="' + esc(cl.src) + '" data-video-poster="' + esc(cl.poster || '') + '" data-video-title="' + esc(cl.title) + '">Expand</button>' +
        '<a class="text-btn" href="' + esc(dlUrl) + '" target="_blank" rel="noopener noreferrer">Download MP4</a>' +
      '</div>';
    return (
      '<article class="clip-card">' +
        '<div class="gallery-meta-row">' +
          '<span>' + esc(cl.meta || '') + '</span>' +
          '<span class="' + resCls + '">' + esc(cl.result_label || '') + '</span>' +
        '</div>' +
        '<h4>' + esc(cl.title) + '</h4>' +
        '<figure class="clip-figure">' + vHtml + '<figcaption>' + esc(cl.caption || '') + '</figcaption></figure>' +
      '</article>'
    );
  }
  catBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      const idx = parseInt(btn.getAttribute('data-cat-idx'), 10);
      const c = arenaCats[idx];
      if (!c) return;
      catBtns.forEach(function(b) { b.classList.toggle('is-active', b === btn); });
      document.getElementById('cat-detail-title').textContent = c.label;
      document.getElementById('cat-detail-counts').textContent = c.total + ' scenarios (' + c.core + ' run every build)';
      document.getElementById('cat-detail-desc').textContent = c.desc;
      const dRec = c.d_w + '–' + c.d_l + (c.d_d ? '–' + c.d_d : '') + ' (' + Number(c.d_tr).toFixed(2) + '×)';
      const sRec = c.sp_w + '–' + c.sp_l + (c.sp_d ? '–' + c.sp_d : '') + ' (' + Number(c.sp_tr).toFixed(2) + '×)';
      document.getElementById('cat-detail-metrics').innerHTML =
        '<div class="m-chip"><span class="m-lbl">vs. Scripted AI</span><strong>' + esc(dRec) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">vs. Mothman Copy</span><strong>' + esc(sRec) + '</strong></div>';
      const clipsEl = document.getElementById('cat-detail-clips');
      if (clipsEl) {
        const cls = c.clips || [];
        clipsEl.innerHTML = cls.length
          ? cls.map(renderArenaClipCard).join('')
          : '<p class="t-muted">No video clips staged for this category yet.</p>';
      }
    });
  });

  // 4. Matchup Selector + Opening Build Order + Histograms + Base Layout Photo Sync
  const muData = window.__MATCHUP_DATA__ || [];
  const muBtns = document.querySelectorAll('[data-mu-idx]');
  const baseBtns = document.querySelectorAll('[data-base-idx]');

  function buildHistSvgJs(bins, color, aria) {
    const w = 340, h = 146, pl = 14, pr = 14, pt = 20, pb = 30;
    const cw = w - pl - pr, ch = h - pt - pb;
    const n = Math.max(1, (bins || []).length);
    let maxC = 1;
    (bins || []).forEach(function(b) { if ((b.count || 0) > maxC) maxC = b.count; });
    const gap = 8, bw = Math.max(14, (cw - gap * (n - 1)) / n);
    let out = '<svg viewBox="0 0 ' + w + ' ' + h + '" class="chart-svg" role="img" aria-label="' + esc(aria) + '">';
    out += '<line x1="' + pl + '" y1="' + (h - pb) + '" x2="' + (w - pr) + '" y2="' + (h - pb) + '" stroke="#D8D4C8" stroke-width="1" />';
    (bins || []).forEach(function(b, idx) {
      const cnt = b.count || 0;
      const bh = cnt > 0 ? (cnt / maxC) * ch : 0;
      const xx = pl + idx * (bw + gap);
      const yy = h - pb - bh;
      if (bh > 0) {
        out += '<rect x="' + xx.toFixed(1) + '" y="' + yy.toFixed(1) + '" width="' + bw.toFixed(1) + '" height="' + Math.max(2, bh).toFixed(1) + '" rx="3" fill="' + color + '"><title>' + esc(b.label) + ': ' + cnt + ' games</title></rect>';
        out += '<text x="' + (xx + bw / 2).toFixed(1) + '" y="' + Math.max(12, yy - 4).toFixed(1) + '" text-anchor="middle" fill="#141413" font-size="10.5" font-weight="600">' + cnt + '</text>';
      } else {
        out += '<text x="' + (xx + bw / 2).toFixed(1) + '" y="' + (h - pb - 4).toFixed(1) + '" text-anchor="middle" fill="#A09C91" font-size="9.5">0</text>';
      }
      out += '<text x="' + (xx + bw / 2).toFixed(1) + '" y="' + (h - pb + 16).toFixed(1) + '" text-anchor="middle" fill="#5E5D59" font-size="9.5">' + esc(b.label) + '</text>';
    });
    return out + '</svg>';
  }

  function updateBasePhoto(idx) {
    const m = muData[idx];
    if (!m) return;
    baseBtns.forEach(function(b) { b.classList.toggle('is-active', parseInt(b.getAttribute('data-base-idx'), 10) === idx); });
    const imgEl = document.getElementById('base-layout-img');
    const capEl = document.getElementById('base-layout-cap');
    if (imgEl && m.base_img) {
      imgEl.src = m.base_img;
      imgEl.alt = m.matchup + ' main base and natural wall';
      imgEl.setAttribute('data-lightbox-src', m.base_img);
      imgEl.setAttribute('data-lightbox-alt', m.base_cap || m.matchup);
    }
    if (capEl) capEl.textContent = m.base_cap || '';
  }

  muBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      const idx = parseInt(btn.getAttribute('data-mu-idx'), 10);
      const m = muData[idx];
      if (!m) return;
      muBtns.forEach(function(b) { b.classList.toggle('is-active', b === btn); });
      const loc = m.local || {};
      const cor = m.core || {};
      const prd = m.prod || {};
      const prdS = prd.n ? (Number(prd.wr || 0).toFixed(1) + '% · ' + prd.w + '–' + prd.l + (prd.t ? '–' + prd.t : '') + ' (' + Number(prd.tr).toFixed(2) + '× trade)') : '—';
      const corS = cor.n ? (Number(cor.wr || 0).toFixed(1) + '% · ' + cor.w + '–' + cor.l + (cor.t ? '–' + cor.t : '') + ' (' + Number(cor.tr).toFixed(2) + '× trade)') : '—';
      const locS = loc.n ? (Number(loc.wr || 0).toFixed(1) + '% · ' + loc.w + '–' + loc.l + (loc.t ? '–' + loc.t : '') + ' (' + Number(loc.tr).toFixed(2) + '× trade)') : '—';
      document.getElementById('mu-detail-title').textContent = m.matchup + ' (' + m.race + ')';
      document.getElementById('mu-detail-meta').textContent = 'Avg duration ' + Number(loc.dur_m || 0).toFixed(1) + 'm · ' + Number(loc.bases || 0).toFixed(1) + ' peak bases';
      document.getElementById('mu-detail-metrics').innerHTML =
        '<div class="m-chip"><span class="m-lbl">Live Ladder</span><strong>' + esc(prdS) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">14 Core Bots (L42–48)</span><strong>' + esc(corS) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">All 26 Local (L42–48)</span><strong>' + esc(locS) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">Time Supply-Blocked</span><strong>' + Number(loc.sb || 0).toFixed(1) + '%</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">Workers (4m / 6m / Peak)</span><strong>' + Math.round(loc.w4m || 0) + ' / ' + Math.round(loc.w6m || 0) + ' / ' + Math.round(loc.pkw || 0) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">Peak Army Value (Us / Opp)</span><strong>' + Number(loc.pka || 0).toLocaleString() + ' / ' + Number(loc.opka || 0).toLocaleString() + '</strong></div>';
      const stEl = document.getElementById('mu-open-styles');
      if (stEl) {
        stEl.innerHTML = (m.opening_styles || []).map(function(s) { return '<span class="style-chip">' + esc(s) + '</span>'; }).join('');
      }
      const boEl = document.getElementById('mu-open-steps');
      if (boEl) {
        boEl.innerHTML = (m.opening_steps || []).map(function(s) {
          return '<div class="bo-step"><span class="bo-time">' + esc(s.time) + ' · ' + s.sup + ' sup</span><strong>' + esc(s.name) + '</strong><span class="bo-pct">' + s.pct + '% of games</span></div>';
        }).join('');
      }
      const shEl = document.getElementById('mu-sup-hist');
      if (shEl) shEl.innerHTML = buildHistSvgJs(m.supply_hist || [], '#C4633E', m.matchup + ' minute 4 supply histogram');
      const sc = m.supply_curve || {};
      const scEl = document.getElementById('mu-sup-curve');
      if (scEl) scEl.textContent = '2m: ' + Math.round(sc['2'] || 0) + ' · 3m: ' + Math.round(sc['3'] || 0) + ' · 4m: ' + Math.round(sc['4'] || 0) + ' · 5m: ' + Math.round(sc['5'] || 0) + ' median supply';
      const nhEl = document.getElementById('mu-nat-hist');
      if (nhEl) nhEl.innerHTML = buildHistSvgJs(m.nat_hist || [], '#4A6B82', m.matchup + ' natural expansion timing histogram');
      const nfEl = document.getElementById('mu-nat-foot');
      if (nfEl) nfEl.textContent = 'Median: ' + fmtMmss(m.nat_sec) + ' · Pro median: ' + fmtMmss(m.pro_nat_sec);
      document.getElementById('mu-detail-working').textContent = m.working || '';
      document.getElementById('mu-detail-gaps').textContent = m.gaps || '';
      updateBasePhoto(idx);
    });
  });
  baseBtns.forEach(function(btn) {
    btn.addEventListener('click', function() { updateBasePhoto(parseInt(btn.getAttribute('data-base-idx'), 10)); });
  });

  // 5. Worker / Army Curve Race Toggle + Pro Blueprint Race Toggle
  const rcBtns = document.querySelectorAll('[data-race-curve]');
  const slots = document.querySelectorAll('.race-svg-slot');
  rcBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      const r = btn.getAttribute('data-race-curve');
      rcBtns.forEach(function(b) { b.classList.toggle('is-active', b === btn); });
      slots.forEach(function(s) {
        s.style.display = s.getAttribute('data-race') === r ? '' : 'none';
      });
    });
  });

  const bpBtns = document.querySelectorAll('[data-pro-bp-race]');
  const bpPanels = document.querySelectorAll('[data-pro-bp-panel]');
  bpBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      const r = btn.getAttribute('data-pro-bp-race');
      bpBtns.forEach(function(b) { b.classList.toggle('is-active', b === btn); });
      bpPanels.forEach(function(p) {
        p.style.display = p.getAttribute('data-pro-bp-panel') === r ? '' : 'none';
      });
    });
  });
})();
</script>
"""
