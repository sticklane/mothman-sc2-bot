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
        "working": "Blink Stalker mirror micro (b01 4.0×), Immortal/Colossus mid-game, and H2H mirror sweep (3.40×).",
        "gaps": "Early natural Nexus delays (pvp_nat_delay) when scouts or extra tech slip ahead of Nexus #2, plus occasional over-investment in Phoenixes against Stalkers/Tempests.",
    },
    "PvT": {
        "working": "Strongest live Protoss matchup (6–2, 1.18× trade), Disruptor Novas vs. Bio (2.57× vs. Hubert), and Detection-First Blink DT raids (p15 1.58× KO).",
        "gaps": "Protecting Robotics Bay and Colossus #1–2 gas escrow against Stalker/Phoenix demand so Siege Tank lines cannot freeze mid-game pushes.",
    },
    "PvZ": {
        "working": "Colossus/Immortal/Disruptor mid-game (4.38× H2H, 2.67× vs. PolyMorph) and Oracle/Glaive Adept pressure.",
        "gaps": "12-Pool early holds (recently improved with incomplete Nexus cancel + reserved builder Probe) and high-supply Roach/Ravager transitions.",
    },
    "TvP": {
        "working": "Fast Bio + Tank + Viking mid-game (3.5–4.0× vs. puck/Creepy), Widow Mine drops, and 1.6% live supply-block discipline.",
        "gaps": "Avoiding parity army splits on minor Adept/Oracle harass and keeping natural expansion on schedule when probed or cannon-rushed.",
    },
    "TvT": {
        "working": "90% live win rate (9–1, 1.04×, including 5.41× vs. Slowpoke with 18 Tanks and zero lost) and crisp 1.8% supply-block control.",
        "gaps": "Keeping early Reaper openings (1–4 Reapers) from delaying Marines/Bunkers and preserving Tank #1–4 ahead of excess Medivacs.",
    },
    "TvZ": {
        "working": "Dominant live (7–1, 2.31×, 4.85× vs. titania, 5.07× vs. Carcara) and local (6–5, 1.11× in Loop 47), backed by 16/16 Widow Mine & Blue-Flame Hellion drops.",
        "gaps": "Eliminating false capital-air overreactions (fixed via death-Broodling bug) and smooth 3rd-base Barracks scaling.",
    },
    "ZvP": {
        "working": "Burrowed Lurker & Ravager pushes, rapid 3.5+ base economy, and strong Queen/Drone mineral-line holds.",
        "gaps": "Preventing Corruptor overproduction vs. non-air Protoss (<= 12 cap added from live ladder) and defending early 15-Probe worker rushes.",
    },
    "ZvT": {
        "working": "Five-base Roach/Hydra/Lurker/Brood Lord late games (2.61× live vs. oberon with 32 Lurkers), 97% mining uptime vs. early Reapers, and Mutalisk Magic-Box (2/2 KO).",
        "gaps": "Early Banshee Spore+Queen lock (CloakLoss now 0 in Loop 47) and capping Corruptors vs. pure Viking/Mine armies.",
    },
    "ZvZ": {
        "working": "Undefeated on recent live ladder (9–0, 2.78× trade, 10.63× vs. Carcara) with rapid 3.8-base scaling and decisive Ling/Roach transitions.",
        "gaps": "Keeping Hatchery escrow non-blocking whenever supply is tight (<= 2 left) or an early Ling/Roach push arrives.",
    },
}

CATEGORY_META: Dict[str, Tuple[str, str]] = {
    "detection-snipe": ("Detection Sniping", "Clear static (Turret, Cannon, Spore) or mobile (Observer, Raven, Overseer) detectors first so cloaked/burrowed armies sweep safely."),
    "stalker-blink": ("Stalker Blink Micro", "Both shield-cycling Blink-Back under focus fire and coordinated Blink-Forward snipes onto Tanks, Colossi, and Liberators."),
    "runby-offense": ("Runby Offense", "Worker-elimination efficiency across every Mothman raid type: Widow Mine drop, Blue-Flame Hellion, Adept, Oracle, Banshee, Muta, Ling, Baneling drop."),
    "runby-defense": ("Runby Defense", "Symmetric mineral-line defense: pulling targeted workers away from Widow Mines, splitting vs. Hellions, and keeping mining uptime high."),
    "stasis-ward": ("Stasis Ward", "Oracle Stasis Ward placement in mineral pockets/chokes versus single-unit sacrifice defusing and detected sniping."),
    "yamato-jump": ("Yamato & Tactical Jump", "Battlecruiser Yamato focus-fire and low-HP Tactical Jump escapes across air and mech clashes."),
    "transport-nydus": ("Dropships & Nydus", "Medivac pickup-drop juggles, Warp Prism Archon/Immortal drops, Dropperlord Baneling rains, and Nydus Worm unloads."),
    "burrow-micro": ("Burrow & Unburrow", "Roach Tunneling Claws burrow-heal, Baneling landmine traps, burrowed Infestor ambushes, Lurker leapfrogs, and Widow Mine positioning."),
    "spellcasters": ("Spellcasters", "High Templar Storm/Feedback, Ghost EMP/Snipe, Raven Interference Matrix/AAM, Viper Abduct/Blinding Cloud, Infestor Fungal/Neural."),
    "kiting-concave": ("Kiting & Concaves", "Stutter-step Bio, Immortal/Stalker focus-fire, Hydra/Roach arcs, and melee-ranged mixed micro."),
    "flank-surround": ("Flank Surrounds", "Two-prong Ling/Bane and Ravager/Hydra pincer collapses onto sieged Tank lines."),
    "high-ground-ramp": ("High-Ground Ramps", "Ramp vision, tank-line defense, Lurker choke holds, and uphill breaks."),
    "air-superiority": ("Air Superiority", "Mutalisk Magic-Box vs. Thors, Phoenix Graviton lifts, and Viking/Corruptor air focus."),
    "early-rush-defense": ("Early Rush Defense", "12-Pool mineral-line holds, Reaper defense, and early proxy survival."),
    "capital-endgame": ("Capital Endgame", "Cliff-air clashes with Carriers, Tempests, Brood Lords, Thors, and Vipers."),
    "regression": ("Replay Regressions", "Exact skirmishes extracted from real ladder losses (Cloaked Banshees, 15-Probe worker rushes, 24-Ling ramp floods)."),
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
        "arena3": {"total": 213, "fast_core": 66, "categories": [], "dummy_rec": "34W–25L–7D", "dummy_trade": 1.17, "sp_rec": "27W–38L–1D", "sp_trade": 0.83, "loop_num": 47},
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

    # Find latest iter* arena JSONs
    loop_scratch = brain_dir / "scratch" / "loop"
    latest_d_json: Optional[Path] = None
    latest_sp_json: Optional[Path] = None
    latest_loop_num = 0
    if loop_scratch.is_dir():
        for p in loop_scratch.glob("tactics_sc2_duel_iter*.json"):
            m = re.search(r"iter(\d+)\.json$", p.name)
            if m and int(m.group(1)) > latest_loop_num:
                sp_cand = loop_scratch / f"tactics_sc2_selfplay_iter{m.group(1)}.json"
                if sp_cand.is_file():
                    latest_loop_num = int(m.group(1))
                    latest_d_json = p
                    latest_sp_json = sp_cand

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
                out["arena3"]["dummy_rec"] = f"{dw_t}W–{dl_t}L–{dd_t}D"
                out["arena3"]["dummy_trade"] = float(
                    ds.get("agg_trade_ratio", ds.get("trade_ratio", ds.get("agg_trade", 0.0))) or 0.0
                )
            if ss:
                sw_t = int(ss.get("mothman_wins", ss.get("wins", 0)) or 0)
                sl_t = int(ss.get("p2_wins", ss.get("losses", 0)) or 0)
                sd_t = int(ss.get("draws", 0) or 0)
                out["arena3"]["sp_rec"] = f"{sw_t}W–{sl_t}L–{sd_t}D"
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
            AND m.run_id NOT LIKE '%h2h%' AND m.run_id NOT LIKE '%smoke%'
            AND (m.run_id LIKE '%iter42%' OR m.run_id LIKE '%iter43%' OR m.run_id LIKE '%iter44%'
                 OR m.run_id LIKE '%iter45%' OR m.run_id LIKE '%iter46%' OR m.run_id LIKE '%iter47%')
        """

        # Per-matchup Local stats
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
            local_mu[mu] = {
                "n": int(r[1]),
                "w": int(r[2] or 0),
                "l": int(r[3] or 0),
                "t": max(0, int(r[1]) - int(r[2] or 0) - int(r[3] or 0)),
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

        # Per-matchup Prod stats (recent 4 live builds: L37/L40/L42/L45)
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
              AND bot_build_version IN ('ltxmxpzu_e45b61eb','mwskxoml_ffb8aaf1','womqlpsp_6917245e','qpqqolmk_3b21fe7a')
              AND matchup IN ('PvP','PvT','PvZ','TvP','TvT','TvZ','ZvP','ZvT','ZvZ')
            GROUP BY matchup
            """
        ).fetchall():
            prod_mu[r[0]] = {
                "n": int(r[1]),
                "w": int(r[2] or 0),
                "l": int(r[3] or 0),
                "t": max(0, int(r[1]) - int(r[2] or 0) - int(r[3] or 0)),
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
            loc = local_mu.get(mu, {"n": 0, "w": 0, "l": 0, "t": 0, "tr": 0.0, "sb": 0.0, "w4m": 0.0, "w6m": 0.0, "pkw": 0.0, "pka": 0, "opka": 0, "bases": 0.0, "dur_m": 0.0})
            prd = prod_mu.get(mu, {"n": 0, "w": 0, "l": 0, "t": 0, "tr": 0.0, "sb": 0.0})
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
                f"Real 3D SC2 capture from {bm_info.get('bot', 'Mothman')} vs. {bm_info.get('opp', 'opponent')} "
                f"on {bm_info.get('map', '')} ({bm_info.get('corner', '')} spawn, 4:10 game time): "
                f"main base & ramp wall (left) and natural expansion & choke wall (right)."
                if bm_info
                else ""
            )

            out["matchups"][mu] = {
                "matchup": mu,
                "race": {"P": "Protoss", "T": "Terran", "Z": "Zerg"}[mu[0]],
                "local": loc,
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
    max_a = float(((int(peak) // 1000) + 1) * 1000)

    def x_m(m: float) -> float:
        return pl + ((m - 1.0) / 11.0) * cw

    def y_a(val: float) -> float:
        return pt + ch - (max(0.0, min(max_a, val)) / max_a) * ch

    parts = [
        f'<svg viewBox="0 0 {w} {h}" class="chart-svg" role="img" '
        f'aria-label="{race} army value over minutes 1 to 12 compared with opponents">'
    ]
    step = max(1000, int(max_a // 4))
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
    fw = rich["flywheel"]
    lp = rich["live_perf"]
    a3 = rich["arena3"]
    nodes = [
        {
            "id": "live",
            "title": "1. Live & Practice Games",
            "badge": "Outer Loop · Data",
            "what": (
                f"Four Mothman bots play continuously on the public AI Arena ladder ({lp['prod_replays']} live games) "
                f"and across 90-game local practice batches ({lp['total_replays']:,} replays total). "
                "Every replay is parsed automatically into minute-by-minute worker counts, army values, gas timings, and error flags."
            ),
            "why": (
                "Raw win rate bounces around over ten games, so logging every economy curve and anomaly "
                "lets us spot silent regressions—like a build accidentally stalling production—even in games we win."
            ),
            "metric": f"{lp['total_replays']:,} replays analyzed · 100% build-tagged · 0 crashes on Live Build 45",
        },
        {
            "id": "forensics",
            "title": "2. Diagnose Why Games Were Lost",
            "badge": "Outer Loop · Analysis",
            "what": (
                "An analysis agent inspects the worst live and local losses, watching exact timelines to separate "
                "one-off bad luck from repeatable bot bugs (for example: expanding late, building the wrong unit, or chasing kiting workers)."
            ),
            "why": (
                "Instead of guessing what to tweak, every code change starts from replay proof. "
                "That is how we found that dead Zerg buildings spawned Broodlings that tricked Terran into building 13 unnecessary Vikings."
            ),
            "metric": "Every fix traces to a specific replay cause · Zero opponent-specific hacks",
        },
        {
            "id": "code",
            "title": "3. Parallel Engineering Fixes",
            "badge": "Outer Loop · Build",
            "what": (
                "Three specialist coding agents edit separate parts of the bot at the same time: "
                "one updates macro & Mirror Mind, one updates combat micro, and one updates building placement & the APM governor."
            ),
            "why": (
                "Splitting the codebase into non-overlapping tracks cuts coding time to ~12–25 minutes per loop "
                "and keeps macro logic from getting tangled up with low-level unit control."
            ),
            "metric": "3 parallel tracks · Zero file conflicts · Every fix ships with new unit tests",
        },
        {
            "id": "verify",
            "title": "4. Automated Safety Checks",
            "badge": "Outer Loop · ~2.5 min",
            "what": (
                "Before launching StarCraft II, a dedicated verifier compiles the entire bot and runs over 3,400 fast unit tests, "
                "231 isolated micro checks, a state-machine audit, and a pro-replay check confirming the bot never deadlocks on workers or bases."
            ),
            "why": (
                "Catching broken logic in two minutes of CPU tests prevents wasting half an hour running full StarCraft II games on a broken build."
            ),
            "metric": "3,400+ tests passing · 0 pro-replay deadlocks · 0 invalid game commands",
        },
        {
            "id": "arena",
            "title": "5. Tactics Arena 3.0 Drills",
            "badge": "Outer Loop · 213 Drills",
            "what": (
                f"The bot fights {a3['fast_core']} core micro scenarios inside the real StarCraft II engine "
                f"(out of {a3['total']} total across 16 categories)—testing detector sniping, Blink micro, "
                "Widow Mine drops, worker-rush holds, and spellcasters against both a baseline AI and itself."
            ),
            "why": (
                "Full matches take minutes to reach one key fight. Isolated 20-second engine drills let us test "
                "and visually inspect a micro fix in 25 seconds."
            ),
            "metric": f"Loop {a3['loop_num']}: {a3['dummy_rec']} ({a3['dummy_trade']:.2f}× trade) vs. Dummy · {a3['sp_rec']} Self-Play",
        },
        {
            "id": "bench",
            "title": "6. 2-Min Head-to-Head & 84-Game Bench",
            "badge": "Outer Loop · Release Gate",
            "what": (
                "Every candidate first plays a 6-game head-to-head match (~2 minutes) against the build currently live on AI Arena. "
                "Only builds that beat the live bot proceed to the full 84-game benchmark (14 practice bots, 12 unseen test bots, and self-play)."
            ),
            "why": (
                "The 2-minute head-to-head caught all 8 bad builds before they could hurt our live ladder rating—and running it first "
                "saves ~30 minutes of GPU time whenever a build regresses."
            ),
            "metric": "Blocked 8 regressions from shipping · 12 unseen holdout bots guard against overfitting",
        },
        {
            "id": "ship",
            "title": "7. Package & Deploy Live",
            "badge": "Outer Loop · Ship",
            "what": (
                "Builds that beat the live baseline are compiled into 4 standalone Linux bots, smoke-tested in real SC2 games "
                "to verify their build version tag, and pushed live to AI Arena—where their new ladder games immediately start the next cycle."
            ),
            "why": (
                "Each release only goes live after beating the previous live bot head-to-head and proving healthy macro and trade ratios."
            ),
            "metric": "6 live ships deployed · Live Build 45 at 56.5% WR · Mothman-P 1310 Elo",
        },
        {
            "id": "flywheel",
            "title": "Meta-Flywheel: Auditing the Loop Itself",
            "badge": "Inner Loop · Process",
            "what": (
                f"After every loop, a trajectory script reads the execution logs of all 12 agents ({fw['transcript_steps']:,} recorded steps), "
                "measures where time was spent, flags rules that flip-flopped across consecutive loops, and recommends process upgrades."
            ),
            "why": (
                "Auditing Loops 19–47 revealed we were spending 30 minutes on full benchmarks before running the 2-minute head-to-head check "
                "that caught 8/8 bad builds. Flipping the gate order boosts shipping speed by 1.44×."
            ),
            "metric": "29 loops logged · 358 min recoverable savings · 1.44× projected ship throughput",
        },
    ]
    nodes_json = json.dumps(nodes, ensure_ascii=False).replace("</", "<\\/")

    loop_svg = f"""
<svg viewBox="0 0 760 445" class="diagram-svg" id="loop-svg" role="img" aria-label="Self-improvement loop and meta-flywheel diagram">
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

  <!-- Meta-Flywheel dashed feedback arrows -->
  <path d="M 380 348 L 380 288" fill="none" stroke="#C4633E" stroke-width="2" stroke-dasharray="5,3" marker-end="url(#arr-fw)" />
  <text x="388" y="324" fill="#A34E2E" font-size="10.5" font-weight="600">Logs &amp; timings</text>
  <path d="M 462 184 Q 504 162 532 146" fill="none" stroke="#C4633E" stroke-width="2" stroke-dasharray="5,3" marker-end="url(#arr-fw)" />
  <path d="M 298 258 Q 252 292 224 326" fill="none" stroke="#C4633E" stroke-width="2" stroke-dasharray="5,3" marker-end="url(#arr-fw)" />
  <text x="200" y="286" fill="#A34E2E" font-size="10.5" font-weight="600">Faster gates</text>

  <!-- Node 0: Top Center (Live Games) -->
  <g class="svg-node is-active" data-loop-idx="0" tabindex="0" role="button" aria-label="1. Live and Practice Games">
    <rect x="288" y="20" width="184" height="62" rx="10" class="node-bg" />
    <text x="380" y="44" text-anchor="middle" class="node-title">1. Live &amp; Practice Games</text>
    <text x="380" y="63" text-anchor="middle" class="node-sub">{lp['total_replays']:,} replays · AI Arena</text>
  </g>

  <!-- Node 1: Top Right (Diagnose Losses) -->
  <g class="svg-node" data-loop-idx="1" tabindex="0" role="button" aria-label="2. Diagnose Losses">
    <rect x="536" y="84" width="182" height="62" rx="10" class="node-bg" />
    <text x="627" y="108" text-anchor="middle" class="node-title">2. Diagnose Losses</text>
    <text x="627" y="127" text-anchor="middle" class="node-sub">Replay forensics &amp; leaks</text>
  </g>

  <!-- Node 2: Mid Right (Parallel Code Fixes) -->
  <g class="svg-node" data-loop-idx="2" tabindex="0" role="button" aria-label="3. Parallel Code Fixes">
    <rect x="562" y="210" width="182" height="62" rx="10" class="node-bg" />
    <text x="653" y="234" text-anchor="middle" class="node-title">3. Parallel Code Fixes</text>
    <text x="653" y="253" text-anchor="middle" class="node-sub">Macro · Micro · Placement</text>
  </g>

  <!-- Node 3: Bottom Right (Safety Checks) -->
  <g class="svg-node" data-loop-idx="3" tabindex="0" role="button" aria-label="4. Automated Safety Checks">
    <rect x="484" y="336" width="182" height="62" rx="10" class="node-bg" />
    <text x="575" y="360" text-anchor="middle" class="node-title">4. Safety Checks</text>
    <text x="575" y="379" text-anchor="middle" class="node-sub">3,400+ tests · ~2.5 min</text>
  </g>

  <!-- Node 4: Bottom Center (Tactics Arena) -->
  <g class="svg-node" data-loop-idx="4" tabindex="0" role="button" aria-label="5. Tactics Arena 3.0">
    <rect x="298" y="354" width="164" height="62" rx="10" class="node-bg" />
    <text x="380" y="378" text-anchor="middle" class="node-title">5. Tactics Arena</text>
    <text x="380" y="397" text-anchor="middle" class="node-sub">{a3['total']} real SC2 drills</text>
  </g>

  <!-- Node 5: Bottom Left (H2H & Bench) -->
  <g class="svg-node" data-loop-idx="5" tabindex="0" role="button" aria-label="6. 2-Min H2H and 84-Game Bench">
    <rect x="86" y="336" width="188" height="62" rx="10" class="node-bg" />
    <text x="180" y="360" text-anchor="middle" class="node-title">6. 2m H2H → 84 Games</text>
    <text x="180" y="379" text-anchor="middle" class="node-sub">Must beat live bot to ship</text>
  </g>

  <!-- Node 6: Top Left (Ship Live) -->
  <g class="svg-node" data-loop-idx="6" tabindex="0" role="button" aria-label="7. Ship New Build Live">
    <rect x="34" y="150" width="176" height="68" rx="10" class="node-bg" />
    <text x="122" y="177" text-anchor="middle" class="node-title">7. Ship Live Build</text>
    <text x="122" y="196" text-anchor="middle" class="node-sub">4 binaries → AI Arena</text>
  </g>

  <!-- Node 7: CENTER HUB (Meta-Flywheel) -->
  <g class="svg-node node-flywheel" data-loop-idx="7" tabindex="0" role="button" aria-label="Meta-Flywheel auditing the loop itself">
    <rect x="266" y="176" width="228" height="106" rx="14" class="node-bg-fw" />
    <text x="380" y="201" text-anchor="middle" class="node-kicker-fw">INNER META-FLYWHEEL</text>
    <text x="380" y="223" text-anchor="middle" class="node-title">Audits the Loop Itself</text>
    <text x="380" y="243" text-anchor="middle" class="node-sub">Reads all 12 agent transcripts</text>
    <text x="380" y="261" text-anchor="middle" class="node-sub">Cuts wasted GPU time · 1.44× ships</text>
  </g>
</svg>
"""

    first = nodes[0]
    return f"""
<section class="section-rule wide-col" id="loop-section">
  <div class="section-head">
    <p class="section-num">Section 1</p>
    <h2 class="section-kicker">How Mothman Improves Every Loop</h2>
    <p class="section-intro">
      Improvement runs on two linked cycles: the <strong>outer cycle</strong> tests and ships stronger StarCraft II
      bots, while the <strong>inner meta-flywheel</strong> inspects our agents’ own run logs to remove bottlenecks
      and stop repeat mistakes. Tap any node on the diagram to inspect it.
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
    apm = rich["apm_by_race"]
    lp = rich["live_perf"]

    pieces = {
        "sc2": {
            "title": "StarCraft II Game Engine (22.4 Ticks / Sec)",
            "badge": "Game World",
            "what": "Every 45 milliseconds, StarCraft II sends Mothman a snapshot of everything currently visible on the map—our units, our money, enemy units outside the fog of war, and building progress.",
            "connects": "Broadcasts the raw game state in parallel to all six perception streams, then executes the clean commands returned by the APM Governor.",
            "perf": f"Average bot response time: {lp['avg_step_ms']:.2f} ms per step (well under the 200 ms tournament limit), with 0 crashes on Live Build 45.",
        },
        "econ": {
            "title": "Stream 1 · Economy & Supply",
            "badge": "Input Stream → Prioritization",
            "what": "Tracks exact minerals, gas, active workers per base, free supply, and money already promised to workers walking toward a build site.",
            "connects": "Feeds live spending capacity into the Prioritization Engine so it knows whether we can afford an expansion, need a Pylon/Depot/Overlord immediately, or have idle gas geysers.",
            "perf": "Auto-resaturating empty gas geysers within 8 seconds drove zero-gas freezes to 0 in Loops 45 and 47; Terran averages just 1.8% time supply-blocked.",
        },
        "scout": {
            "title": "Stream 2 · Scouting & Enemy Memory",
            "badge": "Input Stream → Mirror Mind & Micro",
            "what": "Remembers every enemy unit and building Mothman has seen—even after they disappear back into the fog of war—and tracks how long ago each spot was scouted.",
            "connects": "Hands raw sightings to Mirror Mind to infer hidden tech, and tells Tactical Micro where hidden enemies or bases are likely sitting.",
            "perf": "Visibility-grid verification fixed dark-fog blind spots so cloaked Dark Templars now hunt down the final hidden Siege Tank cleanly.",
        },
        "mirror": {
            "title": "Stream 3 · Mirror Mind (Opponent Predictor)",
            "badge": "Inference Stream → Prioritization & Micro",
            "what": "Acts like a human player reading their opponent: if it sees early gas and a Starport with Tech Lab, it anticipates cloaked Banshees before they arrive; if it sees 12 enemy workers crossing the map, it flags an emergency rush.",
            "connects": "Outputs concrete counter-signals—like 'need detection now' or 'enemy is all-in, cancel greedy bases'—into both the Prioritization Engine and Tactical Micro.",
            "perf": "Cloak losses dropped to 0 across all 84 matches in Loop 47. Removing dead-building Broodlings eliminated false anti-air panics; Loop 48 adds dedicated kiting worker-rush detection.",
        },
        "prodb": {
            "title": "Stream 4 · Pro Replay Benchmarks",
            "badge": "Input Stream → Prioritization",
            "what": "Holds Grandmaster median curves for worker count, expansion timings, and gas timings in all nine matchups so the bot knows what healthy growth looks like at minute 2, 5, or 8.",
            "connects": "Nudges the Prioritization Engine upward whenever worker production or base count falls behind Grandmaster pace.",
            "perf": "Verified across 5,575 pro-replay checkpoints with 0 worker-starvation, 0 expansion-starvation, and 0 resource-hoarding deadlocks.",
        },
        "fap": {
            "title": "Stream 5 · Battle Simulator (FAP)",
            "badge": "Input Stream → Prioritization & Micro",
            "what": "Runs a fast local fight simulation comparing nearby friendly and enemy armies—accounting for unit types, splash damage, high ground, and siege range.",
            "connects": "Tells Tactical Micro whether to engage, kite back, or retreat, and tells the Prioritization Engine when to pause greed and pump combat units.",
            "perf": "Stopped reckless Stalker blink-ins against Siege Tank lines and lifted Terran to its first >1.00× overall local trade ratio (1.02× in Loop 45; 1.64× live).",
        },
        "map": {
            "title": "Stream 6 · Map & Base Placement",
            "badge": "Input Stream → Prioritization & Micro",
            "what": "Maps every ramp, choke, expansion pad, and mineral pocket using pathing distances rather than compass directions—so every base layout works identically whether spawning north or south.",
            "connects": "Supplies safe building coordinates (including natural and third-base spillover space) to Macro, and safe retreat / flank paths to Tactical Micro.",
            "perf": "Eliminated our 16-point northern-spawn deficit on Ley Lines; North vs. South live win rate gap is now 0.0 percentage points on Live Build 45.",
        },
        "prio": {
            "title": "Prioritization Engine (Macro — What to Build)",
            "badge": "Decision Engine → APM Governor",
            "what": "Instead of following a brittle script, every possible spending choice—workers, supply, expansions, tech, upgrades, and army units—submits a live priority score each tick. When a high-value item like a second Nexus (400 minerals) or Robotics Bay is almost affordable, it sets money aside ('escrow') so cheaper units cannot spend it first.",
            "connects": "Combines all six input streams into ranked build and train orders, then sends them to the APM Governor.",
            "perf": "0/0/0/0 pro-replay starvation audit; Escrow lockouts cut 17→12; Loop 48 aligns Brain & Runtime Barracks/Phoenix limits to remove late-game production stalls.",
        },
        "micro": {
            "title": "Tactical Micro Engine (Combat — How to Fight)",
            "badge": "Decision Engine → APM Governor",
            "what": "Controls individual squads and workers in real time: sniping detectors before engaging with cloaked units, blinking injured Stalkers back, dropping Widow Mines behind mineral lines, casting spells, and pulling workers against rushes.",
            "connects": "Reads Scouting, Mirror Mind, Battle Simulator, and Map Geometry, then sends urgent unit orders to the APM Governor.",
            "perf": "Tactics Arena 3.0 hit a new high of 34W–25L–7D (1.17× trade, 25 KOs) in Loop 47, including a 1.58× permanent-cloak Planetary Fortress win and 16/16 Widow Mine drops.",
        },
        "apm": {
            "title": "APM Governor (Priority Traffic Controller)",
            "badge": "Actuation → StarCraft II",
            "what": "Every tick, both Macro and Micro want to command units. The APM Governor sorts all orders into four strict urgency lanes—P0 Survive & Spells, P1 Combat Micro, P2 Macro Builds, P3 Routine Mining—removes redundant clicks, and guarantees a lower-priority rule never overwrites an urgent command on the same unit.",
            "connects": "Takes orders from both Decision Engines and sends one clean, conflict-free action batch back to StarCraft II.",
            "perf": f"{lp['wire_rejects']} rejected game commands · {lp['avg_step_ms']:.2f} ms avg step · Balanced human-like APM (Protoss {apm['Protoss'][0]:.0f} / Terran {apm['Terran'][0]:.0f} / Zerg {apm['Zerg'][0]:.0f}).",
        },
    }

    walkthroughs = {
        "explore": {
            "label": "Explore Pieces",
            "active": ["prio"],
            "title": "Click any piece on the diagram to see what it does",
            "steps": [],
        },
        "macro": {
            "label": "Walkthrough: Normal Expansion",
            "active": ["sc2", "econ", "prodb", "map", "prio", "apm"],
            "title": "How Mothman saves for a 2nd Nexus at 1:30 without Stalkers stealing the cash",
            "steps": [
                "1. Economy & Supply sees 350 minerals and 20 healthy Probes; Pro Replay Curves show Grandmasters expand around 1:33.",
                "2. Prioritization Engine scores Natural Nexus (920) higher than a Stalker (620) and locks 350 minerals into escrow so Gateways pause for 4 seconds.",
                "3. Map & Placement selects the safe natural expansion pad (working identically from north or south spawns).",
                "4. APM Governor sends the Build Nexus command in lane P2 and locks that builder Probe so routine mining (P3) cannot call it back to minerals.",
            ],
        },
        "rush": {
            "label": "Walkthrough: 15-Probe Worker Rush",
            "active": ["sc2", "scout", "mirror", "fap", "prio", "micro", "apm"],
            "title": "How all pieces coordinate when 15 enemy Probes rush the base at 1:00",
            "steps": [
                "1. Scouting & Memory spots 12+ enemy workers crossing the map; Battle Simulator flags immediate home-base danger.",
                "2. Mirror Mind locks 'Worker Rush' mode—suppressing greedy expansions, extra Depots, and gas buildings.",
                "3. Prioritization Engine cancels unfinished gas/expands for a 75% refund and prioritizes the first Zealot, Marine, or Spine + Zerglings.",
                "4. Tactical Micro pulls defenders against advancing Probes while keeping 3–4 workers safely mining so income never freezes, and the APM Governor promotes those pulls to lane P0 so nothing overrides them.",
            ],
        },
        "cloak": {
            "label": "Walkthrough: Cloaked Banshee",
            "active": ["sc2", "scout", "mirror", "prio", "micro", "apm"],
            "title": "How Mothman stops invisible units before they wipe a mineral line",
            "steps": [
                "1. Scouting spots a Starport with a Tech Lab—or invisible damage hitting our workers.",
                "2. Mirror Mind immediately latches 'Cloaked Threat' (while ignoring false alarms like hallucinations or death Broodlings).",
                "3. Prioritization Engine overrides normal army production to rush detection (Observer, Spore Crawler, or Missile Turret).",
                "4. Tactical Micro pulls workers away from the Banshee until detection arrives, then focus-fires the revealed threat at P1—driving cloak losses to 0 across all 84 matches in Loop 47.",
            ],
        },
    }

    pieces_json = json.dumps(pieces, ensure_ascii=False).replace("</", "<\\/")
    walks_json = json.dumps(walkthroughs, ensure_ascii=False).replace("</", "<\\/")

    arch_svg = """
<svg viewBox="0 0 760 568" class="diagram-svg" id="arch-svg" role="img" aria-label="Mothman real-time decision architecture showing six parallel streams feeding Macro Prioritization and Tactical Micro into the APM Governor">
  <defs>
    <marker id="arr-arch" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M 0 1.5 L 8.5 5 L 0 8.5 z" fill="#8C877A" />
    </marker>
    <marker id="arr-ret" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse">
      <path d="M 0 1.5 L 8.5 5 L 0 8.5 z" fill="#4A6B82" />
    </marker>
  </defs>

  <!-- Right-side feedback loop arrow: APM Governor -> StarCraft II -->
  <path d="M 684 504 L 730 504 L 730 42 L 690 42" fill="none" stroke="#4A6B82" stroke-width="2.2" marker-end="url(#arr-ret)" />
  <text x="742" y="276" text-anchor="middle" fill="#4A6B82" font-size="11" font-weight="600" transform="rotate(-90 742 276)">Clean orders sent 22×/sec → next frame</text>

  <!-- TOP BAND: StarCraft II Game State -->
  <g class="svg-node arch-svg-node" data-arch-id="sc2" tabindex="0" role="button" aria-label="StarCraft II Game State">
    <rect x="30" y="14" width="654" height="56" rx="10" class="node-bg-dark" />
    <text x="357" y="37" text-anchor="middle" fill="#FAF9F5" font-size="14" font-weight="600">StarCraft II Game State (every 45 ms)</text>
    <text x="357" y="55" text-anchor="middle" fill="#D4D0C5" font-size="11.5">Broadcasts visible units, money, supply, and map state to all six streams in parallel</text>
  </g>

  <!-- Fan-out arrows from SC2 to Streams -->
  <line x1="133" y1="70" x2="133" y2="106" stroke="#8C877A" stroke-width="1.8" marker-end="url(#arr-arch)" />
  <line x1="357" y1="70" x2="357" y2="106" stroke="#8C877A" stroke-width="1.8" marker-end="url(#arr-arch)" />
  <line x1="581" y1="70" x2="581" y2="106" stroke="#8C877A" stroke-width="1.8" marker-end="url(#arr-arch)" />

  <!-- Subtle grouping box around the 6 Independent Streams -->
  <rect x="20" y="92" width="674" height="176" rx="12" fill="#F4F2EA" stroke="#E0DCD0" stroke-width="1.2" />
  <text x="34" y="108" fill="#7A7870" font-size="10.5" font-weight="600" letter-spacing="0.06em">SIX INDEPENDENT INPUT STREAMS (RUN IN PARALLEL)</text>

  <!-- Row 1 of Streams -->
  <g class="svg-node arch-svg-node" data-arch-id="econ" tabindex="0" role="button" aria-label="Economy and Supply stream">
    <rect x="32" y="116" width="204" height="64" rx="8" class="node-bg" />
    <text x="134" y="140" text-anchor="middle" class="node-title">Economy &amp; Supply</text>
    <text x="134" y="159" text-anchor="middle" class="node-sub">Cash, income, workers, free supply</text>
  </g>
  <g class="svg-node arch-svg-node" data-arch-id="scout" tabindex="0" role="button" aria-label="Scouting and Memory stream">
    <rect x="255" y="116" width="204" height="64" rx="8" class="node-bg" />
    <text x="357" y="140" text-anchor="middle" class="node-title">Scouting &amp; Memory</text>
    <text x="357" y="159" text-anchor="middle" class="node-sub">Seen enemies &amp; fog-of-war recall</text>
  </g>
  <g class="svg-node arch-svg-node" data-arch-id="mirror" tabindex="0" role="button" aria-label="Mirror Mind opponent predictor">
    <rect x="478" y="116" width="204" height="64" rx="8" class="node-bg-accent" />
    <text x="580" y="140" text-anchor="middle" class="node-title">Mirror Mind</text>
    <text x="580" y="159" text-anchor="middle" class="node-sub">Guesses hidden tech &amp; rush threats</text>
  </g>
  <!-- Horizontal arrow: Scouting -> Mirror Mind -->
  <line x1="459" y1="148" x2="476" y2="148" stroke="#C4633E" stroke-width="1.8" marker-end="url(#arr-fw)" />

  <!-- Row 2 of Streams -->
  <g class="svg-node arch-svg-node" data-arch-id="prodb" tabindex="0" role="button" aria-label="Pro Replay Benchmarks stream">
    <rect x="32" y="192" width="204" height="64" rx="8" class="node-bg" />
    <text x="134" y="216" text-anchor="middle" class="node-title">Pro Replay Curves</text>
    <text x="134" y="235" text-anchor="middle" class="node-sub">GM worker, base &amp; gas targets</text>
  </g>
  <g class="svg-node arch-svg-node" data-arch-id="fap" tabindex="0" role="button" aria-label="Battle Simulator stream">
    <rect x="255" y="192" width="204" height="64" rx="8" class="node-bg" />
    <text x="357" y="216" text-anchor="middle" class="node-title">Battle Simulator (FAP)</text>
    <text x="357" y="235" text-anchor="middle" class="node-sub">Predicts who wins nearby fights</text>
  </g>
  <g class="svg-node arch-svg-node" data-arch-id="map" tabindex="0" role="button" aria-label="Map and Base Placement stream">
    <rect x="478" y="192" width="204" height="64" rx="8" class="node-bg" />
    <text x="580" y="216" text-anchor="middle" class="node-title">Map &amp; Base Geometry</text>
    <text x="580" y="235" text-anchor="middle" class="node-sub">Ramps, paths &amp; safe build spots</text>
  </g>

  <!-- Converging arrows from Streams into Macro & Micro Engines -->
  <path d="M 160 268 L 160 314" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <path d="M 320 268 L 265 314" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <path d="M 394 268 L 450 314" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <path d="M 554 268 L 554 314" fill="none" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <text x="150" y="297" text-anchor="end" fill="#7A7870" font-size="10.5">Spending &amp; counter signals</text>
  <text x="566" y="297" fill="#7A7870" font-size="10.5">Threat &amp; target map</text>

  <!-- ROW 3: Two Parallel Decision Engines -->
  <g class="svg-node arch-svg-node is-active" data-arch-id="prio" tabindex="0" role="button" aria-label="Prioritization Engine for Macro">
    <rect x="30" y="318" width="318" height="94" rx="10" class="node-bg" />
    <text x="189" y="340" text-anchor="middle" class="node-kicker-fw">MACRO · WHAT TO BUILD</text>
    <text x="189" y="361" text-anchor="middle" class="node-title">Prioritization Engine</text>
    <text x="189" y="381" text-anchor="middle" class="node-sub">Scores workers, bases, tech &amp; army every tick;</text>
    <text x="189" y="397" text-anchor="middle" class="node-sub">locks money aside ("escrow") for big purchases</text>
  </g>

  <g class="svg-node arch-svg-node" data-arch-id="micro" tabindex="0" role="button" aria-label="Tactical Micro Engine for Combat">
    <rect x="366" y="318" width="318" height="94" rx="10" class="node-bg" />
    <text x="525" y="340" text-anchor="middle" class="node-kicker-fw">COMBAT · HOW TO FIGHT</text>
    <text x="525" y="361" text-anchor="middle" class="node-title">Tactical Micro Engine</text>
    <text x="525" y="381" text-anchor="middle" class="node-sub">Blink, kiting, spells, drops, detector snipes,</text>
    <text x="525" y="397" text-anchor="middle" class="node-sub">and pulling workers against early rushes</text>
  </g>

  <!-- Converging arrows into APM Governor -->
  <line x1="189" y1="412" x2="189" y2="454" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <line x1="525" y1="412" x2="525" y2="454" stroke="#8C877A" stroke-width="2" marker-end="url(#arr-arch)" />
  <text x="200" y="439" fill="#7A7870" font-size="10.5">Build &amp; train orders</text>
  <text x="536" y="439" fill="#7A7870" font-size="10.5">Combat &amp; spell orders</text>

  <!-- ROW 4: APM Governor (Priority Traffic Controller) -->
  <g class="svg-node arch-svg-node" data-arch-id="apm" tabindex="0" role="button" aria-label="APM Governor priority traffic controller">
    <rect x="30" y="458" width="654" height="94" rx="10" class="node-bg" />
    <text x="357" y="481" text-anchor="middle" class="node-title">APM Governor · Priority Traffic Controller</text>
    <text x="357" y="499" text-anchor="middle" class="node-sub">Removes duplicate clicks and ensures routine orders never overwrite urgent survival actions</text>
    <!-- Visual P0..P3 priority lanes -->
    <rect x="50" y="512" width="144" height="28" rx="5" fill="#FCECE6" stroke="#C4633E" stroke-width="1" />
    <text x="122" y="530" text-anchor="middle" fill="#A34E2E" font-size="10.5" font-weight="600">P0 · Survive &amp; Spells</text>

    <rect x="206" y="512" width="144" height="28" rx="5" fill="#EEF3F6" stroke="#4A6B82" stroke-width="1" />
    <text x="278" y="530" text-anchor="middle" fill="#355166" font-size="10.5" font-weight="600">P1 · Combat Micro</text>

    <rect x="362" y="512" width="144" height="28" rx="5" fill="#F4F2EA" stroke="#B5B0A3" stroke-width="1" />
    <text x="434" y="530" text-anchor="middle" fill="#4A4945" font-size="10.5" font-weight="600">P2 · Macro Builds</text>

    <rect x="518" y="512" width="144" height="28" rx="5" fill="#FAF9F5" stroke="#D5D1C5" stroke-width="1" />
    <text x="590" y="530" text-anchor="middle" fill="#7A7870" font-size="10.5" font-weight="600">P3 · Routine Mining</text>
  </g>
</svg>
"""

    init_p = pieces["prio"]
    return f"""
<section class="section-rule wide-col" id="architecture-section">
  <div class="section-head">
    <p class="section-num">Section 2</p>
    <h2 class="section-kicker">How Mothman Makes a Decision Every Frame</h2>
    <p class="section-intro">
      Instead of a rigid if-then script, six independent perception streams read the game in parallel and feed
      two decision engines—one for economy (<strong>what to build</strong>) and one for combat (<strong>how to fight</strong>)—before
      the <strong>APM Governor</strong> sorts every order by urgency. Tap any walkthrough or diagram block below.
    </p>
  </div>

  <div class="interactive-panel">
    <div class="walk-bar" role="tablist" aria-label="Architecture walkthrough examples">
      <button type="button" class="cat-pill is-active" data-walk-id="explore">Explore Pieces</button>
      <button type="button" class="cat-pill" data-walk-id="macro">Walkthrough: Normal Expansion</button>
      <button type="button" class="cat-pill" data-walk-id="rush">Walkthrough: 15-Probe Rush</button>
      <button type="button" class="cat-pill" data-walk-id="cloak">Walkthrough: Cloaked Banshee</button>
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

  <div class="subsys-grid">
    <article class="subsys-card">
      <h3>2.1 Six Independent Input Streams</h3>
      <p>Economy, Scouting, Mirror Mind, Pro Curves, Battle Simulation, and Map Geometry each read the frame independently—preventing spaghetti logic and keeping north/south spawns completely symmetric.</p>
      <div class="mini-stat">North vs. South live win gap: <strong>0.0pp</strong> on Build 45</div>
    </article>
    <article class="subsys-card">
      <h3>2.2 Mirror Mind (Opponent Prediction)</h3>
      <p>Infers hidden enemy tech and rush timings from partial scouting. Fixing a bug where dead Zerg buildings spawned Broodlings that triggered false anti-air panics immediately lifted Terran trades above 1.0×.</p>
      <div class="mini-stat">Cloak losses: <strong>0</strong> in Loop 47 · Worker-rush defense upgrading in Loop 48</div>
    </article>
    <article class="subsys-card">
      <h3>2.3 Prioritization Engine</h3>
      <p>Every build choice competes on one priority scale, with money locked aside ("escrow") when high-priority bases or tech are nearly affordable so cheaper units cannot drain the bank.</p>
      <div class="mini-stat">Pro-replay deadlocks: <strong>0 / 5,575</strong> · Terran supply-blocked only <strong>1.8%</strong></div>
    </article>
    <article class="subsys-card">
      <h3>2.4 APM Governor</h3>
      <p>Enforces P0–P3 urgency lanes and deduplicates commands so routine mining or rallies can never cancel a spell, transport drop, building resume, or emergency worker pull.</p>
      <div class="mini-stat"><strong>{lp['wire_rejects']}</strong> rejected commands · <strong>{lp['avg_step_ms']:.2f} ms</strong>/step · P {apm['Protoss'][0]:.0f} / T {apm['Terran'][0]:.0f} / Z {apm['Zerg'][0]:.0f} APM</div>
    </article>
  </div>

  <div class="eval-subsection" style="margin-top:1.75rem;">
    <h3>2.5 Generalized Stall Watchdog (519-Match Audit → Loop 49)</h3>
    <p class="prose-tight">
      Mining all <strong>519 recent matches</strong> (Loops 42–48 + Live Ships #5/#6) showed that nearly every macro
      failure we had been patching one-by-one comes from just four root stall patterns. Rather than stacking more
      special-case rules, Loop 49 adds a single <strong>4-Law Stall Watchdog</strong> pass inside the Prioritization Engine.
    </p>
    <div class="table-wrap" style="margin-bottom:1.1rem;">
      <table>
        <thead>
          <tr>
            <th>Empirically Observed Stall (519 Matches)</th>
            <th style="text-align:right">Matches</th>
            <th style="text-align:right">Loss Rate</th>
            <th>Generalized Watchdog Law</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><strong>Supply capped at minute mark</strong> (&lt;195 sup)</td><td style="text-align:right">168 (32.4%)</td><td style="text-align:right"><strong>81.1%</strong></td><td>Law 3 · Pre-emptive supply headroom</td></tr>
          <tr><td><strong>Worker plateau</strong> (&le;36 @8m / &le;24 @5m)</td><td style="text-align:right">123 (23.7%)</td><td style="text-align:right"><strong>87.8%</strong></td><td>Law 2 · Income &amp; saturation conservation</td></tr>
          <tr><td><strong>Escrow lockouts</strong> (stuck saving for unplaceable goal)</td><td style="text-align:right">95 (18.3%)</td><td style="text-align:right">50.5%</td><td>Law 1 · 3-stage intent-to-action escalation</td></tr>
          <tr><td><strong>Gas-rich / mineral-starved</strong> &amp; <strong>zero-gas</strong> (&ge;5m)</td><td style="text-align:right">72 / 63</td><td style="text-align:right"><strong>66.7%</strong> / 42.7%</td><td>Law 2 · Dynamic gas valve &amp; re-saturation</td></tr>
          <tr><td><strong>Zero-mineral-income stall</strong> (&ge;5 workers, &ge;2m)</td><td style="text-align:right">49 (9.4%)</td><td style="text-align:right"><strong>63.9%</strong></td><td>Law 2 · Force mine transfer / urgent expand</td></tr>
          <tr><td><strong>Terran 1-1-1 opening stall</strong></td><td style="text-align:right">32 (6.2%)</td><td style="text-align:right"><strong>90.6%</strong></td><td>Law 1 &amp; 4 · Resume halted SCV / unlock prereq</td></tr>
          <tr><td><strong>Early-rush idle bank (3m)</strong> / <strong>Prod placement stall</strong></td><td style="text-align:right">15 / 10</td><td style="text-align:right"><strong>100.0%</strong></td><td>Law 1 &amp; 3 · Ring expansion + flush idle bank</td></tr>
        </tbody>
      </table>
    </div>
    <div class="subsys-grid">
      <article class="subsys-card">
        <h3>Law 1 · Goal Progress</h3>
        <p>If an affordable top goal fails to advance for 1.4s / 2.9s / 5.0s, escalate uniformly: resume halted builder → expand placement ring → release stuck escrow with cooldown.</p>
      </article>
      <article class="subsys-card">
        <h3>Law 2 · Flow Conservation</h3>
        <p>Every non-fighting worker must produce income: auto-transfer off depleted bases, pull excess gas workers back to minerals when gas &ge; 450 &amp; minerals &lt; 200, and enforce worker floors.</p>
      </article>
      <article class="subsys-card">
        <h3>Law 3 · Capacity &amp; Spend</h3>
        <p>Pre-empt supply caps based on live production burn rate, and flush floating banks (&ge;500M normal / &ge;150M under rush) whenever production or Larvae sit idle.</p>
      </article>
      <article class="subsys-card">
        <h3>Law 4 · Stuck Entities</h3>
        <p>Auto-resume Terran buildings frozen &ge;24 frames, cancel doomed greedy structures under base breach, and force winning armies out of endgame home stalls.</p>
      </article>
    </div>
  </div>
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

    return f"""
<section class="section-rule wide-col" id="tactics-section">
  <div class="section-head">
    <p class="section-num">Section 3</p>
    <h2 class="section-kicker">Tactics Arena 3.0 ({a3['total']} Scenarios · {len(enriched_cats)} Categories)</h2>
    <p class="section-intro">
      Isolated combat, worker-defense, and mineral-runby drills executed inside the real StarCraft II engine.
      Loop {a3['loop_num']} reached a new high of <strong>{html.escape(a3['dummy_rec'])} ({a3['dummy_trade']:.2f}× trade)</strong>
      against the micro dummy and <strong>{html.escape(a3['sp_rec'])} ({a3['sp_trade']:.2f}×)</strong> in self-play.
      Select any category below to inspect its drills and watch real recorded video clips.
    </p>
  </div>

  <div class="interactive-panel">
    <div class="cat-pills" role="tablist" aria-label="Tactical scenario categories">
      {"".join(pills)}
    </div>
    <div class="detail-drawer" id="cat-detail">
      <div class="detail-top-row">
        <div class="detail-title" id="cat-detail-title">{html.escape(first["label"])}</div>
        <span class="detail-badge" id="cat-detail-counts">{first["total"]} drills · {first["core"]} core flagships</span>
      </div>
      <p class="detail-body" id="cat-detail-desc">{html.escape(first["desc"])}</p>
      <div class="metric-strip" id="cat-detail-metrics">
        <div class="m-chip"><span class="m-lbl">vs. Micro Dummy</span><strong>{first["d_w"]}W–{first["d_l"]}L{f"–{first['d_d']}D" if first["d_d"] else ""} ({first["d_tr"]:.2f}×)</strong></div>
        <div class="m-chip"><span class="m-lbl">vs. Mothman Self-Play</span><strong>{first["sp_w"]}W–{first["sp_l"]}L{f"–{first['sp_d']}D" if first["sp_d"] else ""} ({first["sp_tr"]:.2f}×)</strong></div>
      </div>
      <div class="mini-kicker" style="margin-top:0.85rem;">Recorded Video Clips for This Category</div>
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


def render_matchup_evaluation_section(rich: Dict[str, Any]) -> str:
    mus = rich["matchups"]
    mu_list = [mus[m] for m in MATCHUPS_ORDER if m in mus]
    mu_json = json.dumps(mu_list, ensure_ascii=False).replace("</", "<\\/")

    # Interactive 9-matchup pills (top overview & 4.1 Base & Wall selector)
    mu_pills = []
    base_pills = []
    for idx, m in enumerate(mu_list):
        cls = "cat-pill is-active" if idx == 0 else "cat-pill"
        mu_pills.append(
            f'<button type="button" class="{cls}" data-mu-idx="{idx}">{m["matchup"]}</button>'
        )
        base_pills.append(
            f'<button type="button" class="{cls}" data-base-idx="{idx}">{m["matchup"]}</button>'
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
        prd = first["prod"]
        prd_s = f"{prd['w']}–{prd['l']}" + (f"–{prd['t']}" if prd["t"] else "") + f" ({prd['tr']:.2f}×)" if prd["n"] else "—"
        loc_s = f"{loc['w']}–{loc['l']}" + (f"–{loc['t']}" if loc["t"] else "") + f" ({loc['tr']:.2f}×)" if loc["n"] else "—"
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
        <div class="m-chip"><span class="m-lbl">Live AI Arena</span><strong>{prd_s}</strong></div>
        <div class="m-chip"><span class="m-lbl">Local (L42–47)</span><strong>{loc_s}</strong></div>
        <div class="m-chip"><span class="m-lbl">Supply-Blocked</span><strong>{loc['sb']:.1f}%</strong></div>
        <div class="m-chip"><span class="m-lbl">Workers (4m / 6m / Pk)</span><strong>{loc['w4m']:.0f} / {loc['w6m']:.0f} / {loc['pkw']:.0f}</strong></div>
        <div class="m-chip"><span class="m-lbl">Peak Army (Us / Opp)</span><strong>{loc['pka']:,} / {loc['opka']:,}</strong></div>
        <div class="m-chip"><span class="m-lbl">Gas #1 / Nat Timing</span><strong>{_fmt_mmss(first['gas1_sec'])} / {_fmt_mmss(first['nat_sec'])}</strong></div>
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

    # Build 9-row Base Layout & Placement table
    layout_rows = []
    gas_rows = []
    mm_rows = []
    for m in mu_list:
        mu = m["matchup"]
        loc = m["local"]
        an = m["anomalies"]
        n = max(1, loc["n"])
        prod_st = an.get("prod_placement_stall", 0)
        one_b = an.get("one_base_lockout", 0)
        nat_d = an.get("pvp_nat_delay", 0)
        layout_rows.append(
            f"<tr>"
            f"<td><strong>{mu}</strong></td>"
            f'<td style="text-align:right">{loc["bases"]:.1f}</td>'
            f'<td style="text-align:right">{_fmt_mmss(m["nat_sec"])} <span class="t-muted">(Pro {_fmt_mmss(m["pro_nat_sec"])})</span></td>'
            f'<td style="text-align:right">{prod_st}</td>'
            f'<td style="text-align:right">{one_b}</td>'
            f'<td style="text-align:right">{nat_d if mu == "PvP" else "—"}</td>'
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
        aa_s = an.get("air_aa_starvation", 0)
        escr = an.get("escrow_lockouts", 0)
        t0 = an.get("tvt_zero_tank", 0)
        mm_rows.append(
            f"<tr>"
            f"<td><strong>{mu}</strong></td>"
            f'<td style="text-align:right">{cloak_l}</td>'
            f'<td style="text-align:right">{aa_s}</td>'
            f'<td style="text-align:right">{escr}</td>'
            f'<td style="text-align:right">{t0 if mu == "TvT" else "—"}</td>'
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
            f'<td style="text-align:right"><strong>{p_snn}</strong> / {m_snn}</td>'
            f'<td style="text-align:right"><strong>{p_cl}</strong> / {m_cl}</td>'
            f'<td style="text-align:right">{p_mw} / <strong>{m_mw}</strong></td>'
            f'<td style="text-align:right"><strong>{p_nw}</strong> / {m_nw}</td>'
            f'<td style="text-align:right"><strong>{p_ns}</strong> / {m_ns}</td>'
            f'<td style="text-align:right">{p_nd} / {m_nd}</td>'
            f"</tr>"
        )

    pro_bp_block = ""
    if pro_bp_rows:
        pro_bp_block = f"""
    <div style="margin-top:1.65rem;">
      <h4 style="margin:0 0 0.45rem;font-family:var(--serif);font-size:1.15rem;font-weight:600;color:var(--ink);">
        Visual Blueprint Comparison vs. Grandmaster Pros (4:10)
      </h4>
      <p class="prose-tight">
        Normalized 4:10 architectural blueprints comparing <strong>182 Grandmaster ladder games</strong>
        (<code>herO</code>, <code>Stats</code>, <code>Maru</code>, <code>HeroMarine</code>, <code>Serral</code>)
        against <strong>326 recent Mothman games</strong> (Main TownHall at <code>(0,0)</code>, Natural Expansion along <code>+X</code>).
        Switch races below and click any blueprint to zoom full-screen.
      </p>
      <div class="interactive-panel" style="margin-bottom:1.15rem;">
        <div class="race-toggle" role="tablist" aria-label="Select Pro vs Mothman blueprint race" style="margin-bottom:0.85rem;">
          <button type="button" class="cat-pill is-active" data-pro-bp-race="Protoss">Protoss (vs. NULL · herO · Stats)</button>
          <button type="button" class="cat-pill" data-pro-bp-race="Terran">Terran (vs. Maru · Peggies · HeroMarine)</button>
          <button type="button" class="cat-pill" data-pro-bp-race="Zerg">Zerg (vs. Serral)</button>
        </div>
        <div class="pro-bp-slot" data-pro-bp-panel="Protoss">
          <figure class="clip-figure" style="margin:0;">
            <img class="clip-img base-layout-photo" src="./media/pro_vs_mothman_protoss.png"
                 alt="Protoss base layouts at 4:10 — Grandmaster Pros vs Mothman"
                 data-lightbox-src="./media/pro_vs_mothman_protoss.png"
                 data-lightbox-alt="Protoss Base Layouts at 4:10 — Grandmaster Pros (NULL, herO, Stats) vs. Mothman" />
            <figcaption><strong>Protoss Biggest Gap ("Pylon Soup" + Naked Naturals):</strong> Pros spread Pylons 14.5–19.5 tiles apart (only 2–13% clumped) and place Natural Pylons + Batteries in 73–100% of games. Mothman clumps 42–75% of Pylons in one brick inside the Main, leaves PvP Naturals naked (18% Nat Pylon), and occasionally exposes its Robotics Facility in the PvZ front wall.</figcaption>
          </figure>
        </div>
        <div class="pro-bp-slot" data-pro-bp-panel="Terran" style="display:none;">
          <figure class="clip-figure" style="margin:0;">
            <img class="clip-img base-layout-photo" src="./media/pro_vs_mothman_terran.png"
                 alt="Terran base layouts at 4:10 — Grandmaster Pros vs Mothman"
                 data-lightbox-src="./media/pro_vs_mothman_terran.png"
                 data-lightbox-alt="Terran Base Layouts at 4:10 — Grandmaster Pros (Maru, Peggies, HeroMarine) vs. Mothman" />
            <figcaption><strong>Terran (Pro-Grade Main Wall, Wrong Natural Wall):</strong> Mothman’s Depot–Barracks–Depot main ramp wall hits 97–100%, matching Maru and HeroMarine. However, Mothman builds Natural Supply Depot walls in only 21–42% of games (vs. Pro 60–100%), over-building 1.1–1.4 early Bunkers instead and spacing production vertically rather than in a tight addon-swap cluster.</figcaption>
          </figure>
        </div>
        <div class="pro-bp-slot" data-pro-bp-panel="Zerg" style="display:none;">
          <figure class="clip-figure" style="margin:0;">
            <img class="clip-img base-layout-photo" src="./media/pro_vs_mothman_zerg.png"
                 alt="Zerg base layouts at 4:10 — Grandmaster Pros vs Mothman"
                 data-lightbox-src="./media/pro_vs_mothman_zerg.png"
                 data-lightbox-alt="Zerg Base Layouts at 4:10 — Grandmaster Pro (Serral) vs. Mothman" />
            <figcaption><strong>Zerg (Main Front Clutter + Missing Serral ZvZ Wall):</strong> Serral tucks Spawning Pool behind the Main Hatchery and places Spores inside both mineral lines; Mothman clusters tech &amp; Spines right in front of the Main Hatchery. In ZvZ, Pros build a curved Natural partial wall (Evo/Bane/Roach Warren + Queen plug) in 48% of games vs. Mothman’s 20%.</figcaption>
          </figure>
        </div>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Matchup <span class="t-muted">(Pro/Us)</span></th>
              <th style="text-align:right">Spacing</th>
              <th style="text-align:right">Clump &lt;5t</th>
              <th style="text-align:right">Main Wall</th>
              <th style="text-align:right">Nat Wall</th>
              <th style="text-align:right">Nat Supply</th>
              <th style="text-align:right">Nat Def</th>
            </tr>
          </thead>
          <tbody>{"".join(pro_bp_rows)}</tbody>
        </table>
      </div>
      <p class="table-note" style="margin-top:0.45rem;">All columns show <strong>Grandmaster Pro / Mothman</strong> at 4:10 (Supply Spacing in tiles; Wall/Clump/Nat Supply in % of games; Nat Def = avg static defense structures).</p>
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
    <h2 class="section-kicker">Matchup-by-Matchup Evaluation</h2>
    <p class="section-intro">
      Aggregated across recent local benchmarks (Loops 42–47, ~50 games per matchup) and recent live
      AI Arena releases (Loops 37–45). Pick any matchup to inspect outcomes, macro curves, and open gaps.
    </p>
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
    <h3>4.1 Base Layout, Walls &amp; Building Placement</h3>
    <p class="prose-tight">
      Real StarCraft II 3D captures of Mothman’s main base, ramp wall, and natural choke layout at 4:10 across
      all nine matchups—paired with natural timing, placement stall (<code>ProdStall</code>), and one-base lockout counts.
      Select any matchup below (or click an image to zoom full-screen).
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
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Matchup</th>
            <th style="text-align:right">Peak Bases</th>
            <th style="text-align:right">Median Natural (vs. Pro)</th>
            <th style="text-align:right">ProdStall</th>
            <th style="text-align:right">1BaseLock</th>
            <th style="text-align:right">PvP Nat Delay</th>
          </tr>
        </thead>
        <tbody>{"".join(layout_rows)}</tbody>
      </table>
    </div>
    {pro_bp_block}
  </div>

  <div class="eval-subsection">
    <h3>4.2 Production Utilization &amp; Supply Discipline</h3>
    <p class="prose-tight">
      Terran maintains pro-level supply discipline (<strong>1.8%–2.1%</strong> supply-blocked across all three matchups),
      while Protoss and Zerg sit closer to 4–6% under early aggression. Aligning macro-brain and runtime
      Barracks/Gateway caps in Loops 45–48 removes the primary remaining production bottleneck.
    </p>
    <figure class="figure-block">
      <div class="figure-label">Figure 3</div>
      <div class="figure-title">Average time supply-blocked by matchup (Loops 42–47, lower is better)</div>
      {sb_svg}
      <figcaption class="figure-caption">
        Percentage of match time unable to train units due to hitting supply cap (Pylon, Depot, or Overlord).
      </figcaption>
    </figure>
  </div>

  <div class="eval-subsection">
    <h3>4.3 Worker Building &amp; 4.4 Army Value Curves</h3>
    <p class="prose-tight">
      Minute-by-minute active workers (plotted against Grandmaster medians from <code>pro_baselines.json</code>)
      and army value trajectories (Mothman vs. practice opponents). Switch races below to compare all three.
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

  <div class="eval-subsection">
    <h3>4.5 Gas Timings &amp; Resource Balance</h3>
    <p class="prose-tight">
      Median build-start timings for first and second gas structures compared with Grandmaster medians,
      alongside gas-heavy/mineral-starved (<code>GasRich</code>) and zero-worker gas freeze (<code>GasZero</code>) counts.
      Auto-resaturating empty gas buildings within 8 seconds drove <code>GasZero</code> to zero in Loops 45 and 47.
    </p>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Matchup</th>
            <th style="text-align:right">Gas #1 Median (vs. Pro)</th>
            <th style="text-align:right">Gas #2 Median (vs. Pro)</th>
            <th style="text-align:right">GasRich Matches</th>
            <th style="text-align:right">GasZero</th>
          </tr>
        </thead>
        <tbody>{"".join(gas_rows)}</tbody>
      </table>
    </div>
  </div>

  <div class="eval-subsection">
    <h3>4.6 Mirror Mind Evaluation by Matchup</h3>
    <p class="prose-tight">
      Tracks how reliably Mirror Mind detects cloaked units, triggers anti-air and Siege Tank responses,
      and avoids blocking-escrow deadlocks across Loops 42–47. Loop 47 reached <strong>zero CloakLoss</strong>
      across all 84 matches; open work targets early 15-Probe worker rushes and Phoenix-vs-Tempest caps.
    </p>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Matchup</th>
            <th style="text-align:right">CloakLoss</th>
            <th style="text-align:right">Air/AA Starve</th>
            <th style="text-align:right">Escrow Locks</th>
            <th style="text-align:right">TvT 0-Tank</th>
          </tr>
        </thead>
        <tbody>{"".join(mm_rows)}</tbody>
      </table>
    </div>
  </div>
  <script>window.__MATCHUP_DATA__ = {mu_json};</script>
</section>
"""


def render_issues_fixed_section(chart_sym_svg: str, sym: Dict[str, Any], rich: Dict[str, Any]) -> str:
    fw = rich["flywheel"]
    return f"""
<section class="section-rule wide-col" id="issues-section">
  <div class="section-head">
    <p class="section-num">Section 5</p>
    <h2 class="section-kicker">Major Issues Found &amp; Fixed</h2>
    <p class="section-intro">
      Key systemic bugs uncovered by replay forensics and Tactics Arena drills—each traced from
      symptom to root cause to verified fix.
    </p>
  </div>

  <div class="case-grid">
    <article class="case-card case-wide">
      <div class="case-tag">Geometry &amp; Placement · Fixed in Loop 37</div>
      <h3>5.1 North vs. South Spawn Asymmetry</h3>
      <div class="case-split">
        <div>
          <p><strong>Symptom:</strong> Bots won 16 points less often when spawning north-east on Ley Lines (21.7% vs. 37.8%) and trailed nearly 5 points overall across northern spawns.</p>
          <p><strong>Root cause:</strong> Building placement and early scout heuristics assumed the enemy lay roughly up-and-right, causing northern spawns to wall off their own natural expansion.</p>
          <p><strong>Fix &amp; result:</strong> Replaced directional assumptions with coordinate-free BFS pathing. Across {sym["post_n"]} follow-up matches, North vs. South equalized ({sym["all_after_n"]:.1f}% vs. {sym["all_after_s"]:.1f}%), with a 0.0pp gap on live Ship #6.</p>
        </div>
        <figure class="figure-block" style="margin:0;">
          <div class="figure-title" style="font-size:0.98rem;">North vs. South win rate before and after fix</div>
          {chart_sym_svg}
        </figure>
      </div>
    </article>

    <article class="case-card">
      <div class="case-tag">Mirror Mind · Fixed in Loop 43</div>
      <h3>5.2 Death Broodlings Latching False Greater Spire</h3>
      <p><strong>Symptom:</strong> Against pure ground Zerg (Roach/Hydra), Terran abruptly built 4 Starports and 13 Vikings mid-game.</p>
      <p><strong>Root cause:</strong> Killing any Zerg structure spawns death Broodlings, and <code>implied-tech-prereqs</code> mapped <code>broodling → greater-spire</code>, permanently latching capital-air panic.</p>
      <p><strong>Fix &amp; result:</strong> Removed death Broodlings and hallucinations from tech inference. Phantom Viking ticks dropped from 141 to 0, lifting Terran to its first &gt;1.00× overall trade (1.02×).</p>
    </article>

    <article class="case-card">
      <div class="case-tag">Tactical Micro · Fixed in Loops 43–46</div>
      <h3>5.3 Detection-First Dark Templar Doctrine (p15)</h3>
      <p><strong>Symptom:</strong> Blinking Dark Templars directly onto a Planetary Fortress left both Missile Turrets alive, exposing DTs to PF and Tank splash; later, surviving DTs morphed into visible Archons or got recalled home by their own Nexus.</p>
      <p><strong>Fix &amp; result:</strong> Split wings to snipe both Missile Turrets first, blocked Archon morph and Nexus Mass Recall on undetected cloaked DTs, and added visibility-grid fog sweeping—turning a 0.33× loss into a 1.58× permanent-cloak KO win (14/27 DTs alive).</p>
    </article>

    <article class="case-card">
      <div class="case-tag">Prioritization ↔ Runtime · Fixed in Loop 48</div>
      <h3>5.4 Split-Brain Barracks Cap Deadlock</h3>
      <p><strong>Symptom:</strong> In H2H TvT and 3 roster games, Terran stalled production for 54–132 consecutive ticks while banking minerals.</p>
      <p><strong>Root cause:</strong> The macro brain scheduled Barracks #5/#7 while runtime silently enforced a lower <code>2 × CCs</code> cap, refusing to emit the build command.</p>
      <p><strong>Fix &amp; result:</strong> Unified runtime production ceilings with brain scheduling up to 8 facilities and added a Brain↔Runtime contract check to Gate 1.</p>
    </article>

    <article class="case-card">
      <div class="case-tag">Loop Engineering · Shipped in Loop 48</div>
      <h3>5.5 Un-Gated Heuristics &amp; Trajectory Flywheel</h3>
      <p><strong>Symptom:</strong> 6 of 7 recent held builds failed the 2-minute H2H gate—yet ran the 31-minute 84-match roster first (~{fw['total_wasted_min']} GPU minutes burned).</p>
      <p><strong>Fix &amp; result:</strong> Built automated transcript trajectory logging across all 12 agents, inverted testing to run 2-minute H2H and 25-second targeted Arena checks first, and added flip-flop guardrails.</p>
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
  grid-template-columns: repeat(auto-fit, minmax(145px, 1fr));
  gap: 0.55rem;
  margin: 0.55rem 0 0.85rem;
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

  // 3. Tactics Arena 3.0 Category Explorer WITH Per-Category Playable Video Clips
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
      document.getElementById('cat-detail-counts').textContent = c.total + ' drills · ' + c.core + ' core flagships';
      document.getElementById('cat-detail-desc').textContent = c.desc;
      const dRec = c.d_w + 'W–' + c.d_l + 'L' + (c.d_d ? '–' + c.d_d + 'D' : '') + ' (' + Number(c.d_tr).toFixed(2) + '×)';
      const sRec = c.sp_w + 'W–' + c.sp_l + 'L' + (c.sp_d ? '–' + c.sp_d + 'D' : '') + ' (' + Number(c.sp_tr).toFixed(2) + '×)';
      document.getElementById('cat-detail-metrics').innerHTML =
        '<div class="m-chip"><span class="m-lbl">vs. Micro Dummy</span><strong>' + esc(dRec) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">vs. Mothman Self-Play</span><strong>' + esc(sRec) + '</strong></div>';
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
      const prd = m.prod || {};
      const prdS = prd.n ? (prd.w + '–' + prd.l + (prd.t ? '–' + prd.t : '') + ' (' + Number(prd.tr).toFixed(2) + '×)') : '—';
      const locS = loc.n ? (loc.w + '–' + loc.l + (loc.t ? '–' + loc.t : '') + ' (' + Number(loc.tr).toFixed(2) + '×)') : '—';
      document.getElementById('mu-detail-title').textContent = m.matchup + ' (' + m.race + ')';
      document.getElementById('mu-detail-meta').textContent = 'Avg duration ' + Number(loc.dur_m || 0).toFixed(1) + 'm · ' + Number(loc.bases || 0).toFixed(1) + ' peak bases';
      document.getElementById('mu-detail-metrics').innerHTML =
        '<div class="m-chip"><span class="m-lbl">Live AI Arena</span><strong>' + esc(prdS) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">Local (L42–47)</span><strong>' + esc(locS) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">Supply-Blocked</span><strong>' + Number(loc.sb || 0).toFixed(1) + '%</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">Workers (4m / 6m / Pk)</span><strong>' + Math.round(loc.w4m || 0) + ' / ' + Math.round(loc.w6m || 0) + ' / ' + Math.round(loc.pkw || 0) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">Peak Army (Us / Opp)</span><strong>' + Number(loc.pka || 0).toLocaleString() + ' / ' + Number(loc.opka || 0).toLocaleString() + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">Gas #1 / Nat Timing</span><strong>' + fmtMmss(m.gas1_sec) + ' / ' + fmtMmss(m.nat_sec) + '</strong></div>';
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
