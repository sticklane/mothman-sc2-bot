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
        "working": "Blink Stalker micro, Immortal and Colossus mid-game pushes, and fast natural Nexus timing when early probes stay unharassed.",
        "gaps": "Trails when early aggression delays the second Nexus, forces single-file fights into enemy Colossi, or pushes third-base timing late.",
    },
    "PvT": {
        "working": "Early Observer detection, fast first Stalkers, and Blink/Colossus counter-armies when openings stay uninterrupted.",
        "gaps": "Heavy Siege Tank pushes still punish Protoss before Robotics Bay and Colossi come online, and early Reaper pressure can disrupt Probe mining.",
    },
    "PvZ": {
        "working": "Colossus, Immortal, and Disruptor pushes backed by natural-base power coverage and clean walling.",
        "gaps": "Fast 12-Pool Zergling floods and high-supply Roach/Ravager timings still punish greedy openings and late third bases.",
    },
    "TvP": {
        "working": "Disciplined low supply-block time, fast natural Command Centers, faster Stimpack completion, and live Raven Interference Matrix against Colossi.",
        "gaps": "Mid-game bio pushes can trickle into Colossus or Disruptor splash when Medivacs lag behind or Starport placement stalls.",
    },
    "TvT": {
        "working": "Low supply-blocked time, clean Depot lowering for rapid main-ramp exits, and strong Bio-Tank-Medivac scaling once Siege Tanks are out.",
        "gaps": "Aggressive early Reaper, Proxy Marauder, or cloaked Banshee openings can stall the first Siege Tank or contest the natural Command Center.",
    },
    "TvZ": {
        "working": "Consistent Bio-Tank-Medivac compositions, fast Stimpack timing, and low supply-blocked time across macro games.",
        "gaps": "Mid-game transition onto a third Command Center and extra Barracks lags behind fast Zerg Roach/Hydra/Lurker expansions.",
    },
    "ZvP": {
        "working": "Fast natural Hatchery and drone economy, zero Spore Crawler self-cancel loops, and active Overseer Oversight sieges.",
        "gaps": "Late-game Skytoss fleets (Tempests and Carriers) and mid-game timing pushes still overwhelm ground armies when Spire tech arrives late or Corruptors fly in piecemeal.",
    },
    "ZvT": {
        "working": "Strong late-game Roach, Hydra, Lurker, and Brood Lord scaling when Zerg reaches four or five bases cleanly.",
        "gaps": "Early cloaked Banshees, Bio-Tank timing pushes, and over-droning at minutes 6 to 8 drain army supply.",
    },
    "ZvZ": {
        "working": "Fast Roach, Ravager, and Hydralisk transitions backed by strong early drone saturation and positive combat concaves.",
        "gaps": "Supply blocks during early Zergling/Baneling exchanges and saving minerals for extra Hatcheries while an enemy push crosses the map.",
    },
}

CATEGORY_META: Dict[str, Tuple[str, str]] = {
    "ability-mastery": ("Ability Mastery", "Targeted spell and activated-ability checks verifying cast acceptance and tactical impact across Protoss, Terran, and Zerg."),
    "non-combat": ("Non-Combat", "Worker mining splits, probe harass, mineral-wall clearing, destructible rocks, ramp wall toggles, mineral-walk shortcuts, and map utility drills scored 0 to 100."),
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

def _compact_floats(obj: Any, digits: int = 3) -> Any:
    if isinstance(obj, float):
        return round(obj, digits)
    if isinstance(obj, list):
        return [_compact_floats(x, digits) for x in obj]
    if isinstance(obj, dict):
        return {k: _compact_floats(v, digits) for k, v in obj.items()}
    return obj


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
        "pro_combat_positioning": {},
        "pro_army_group_positioning": {},
        "pro_curves": {},
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

    # Load shipped release IDs from loop_ledger.json upfront so BOTH Section 2.2/2.3 (pro_deep)
    # and Section 2 (SQLite current_build) always agree on the latest SHIPPED release (never leaking HOLD runs).
    shipped_ids: set[str] = set()
    live_ship_iter = 57
    live_ship_num = 10
    ledger_p = repo_dir / "tools/iteration-loop/loop_ledger.json"
    if ledger_p.is_file():
        try:
            ldata = json.loads(ledger_p.read_text(encoding="utf-8"))
            for it in ldata.get("iterations", []):
                st = str(it.get("status") or "").upper()
                if "SHIP" in st and "HOLD" not in st and "FAIL" not in st:
                    iid = str(it.get("id") or "")
                    shipped_ids.add(iid)
                    m_li = re.search(r"iter(\d+)([a-z]?)_ship(\d+)_full", iid, flags=re.I)
                    if m_li:
                        li_n, ls_n = int(m_li.group(1)), int(m_li.group(3))
                        if (li_n, ls_n) > (live_ship_iter, live_ship_num):
                            live_ship_iter, live_ship_num = li_n, ls_n
        except Exception:
            pass

    def _is_shipped_build(it_n: int, suf: str, sh_n: int) -> bool:
        canon_id = f"iter{it_n}{suf.lower()}_ship{sh_n}_full"
        return (
            (canon_id in shipped_ids)
            or (it_n == 57 and not suf and sh_n == 10)
            or (it_n == 59 and suf.lower() == "c" and sh_n == 11)
            or (it_n == 60 and suf.lower() == "b" and sh_n == 12)
            or (it_n == 61 and suf.lower() == "c" and sh_n == 13)
            or (it_n == 62 and suf.lower() == "c" and sh_n == 14)
            or (it_n == 63 and suf.lower() == "b" and sh_n == 15)
            or (it_n == 64 and suf.lower() == "b" and sh_n == 16)
            or (it_n == 65 and suf.lower() == "h" and sh_n == 17)
            or (it_n == 66 and not suf and sh_n == 18)
        )

    # A2. Load Combat Positioning (Section 5) & Army-Group Positioning (Section 6) vs. Pro
    # Prefer latest SHIPPED iter*_ship*_full/pro_deep.json so Sections 2.2/2.3 match Sections 1/2/2.4.
    loop_scratch_a = brain_dir / "scratch" / "loop"
    latest_pro_deep: Optional[Tuple[Tuple[int, int, str, int, float], str, Path]] = None
    if loop_scratch_a.is_dir():
        for pdp in loop_scratch_a.glob("iter*_ship*_full/pro_deep.json"):
            m_pd = re.fullmatch(r"iter(\d+)([a-z]?)_ship(\d+)_full", pdp.parent.name, flags=re.I)
            if not m_pd or not pdp.is_file():
                continue
            it_n = int(m_pd.group(1))
            suf = m_pd.group(2).upper()
            sh_n = int(m_pd.group(3))
            is_sh = 1 if _is_shipped_build(it_n, suf, sh_n) else 0
            rk = (is_sh, it_n, suf, sh_n, pdp.stat().st_mtime)
            if latest_pro_deep is None or rk > latest_pro_deep[0]:
                latest_pro_deep = (rk, f"Build {it_n}{suf}", pdp)
    if latest_pro_deep is not None:
        try:
            pd_data = json.loads(latest_pro_deep[2].read_text(encoding="utf-8"))
            pd_meta = pd_data.get("meta") or {}
            pd_races = pd_data.get("by_race") or {}
            our_lbl_pd = latest_pro_deep[1]
            cp_races: Dict[str, Dict[str, Any]] = {}
            ag_races: Dict[str, Dict[str, Any]] = {}
            for rname in ("Protoss", "Terran", "Zerg"):
                rd = pd_races.get(rname) or {}
                pr_cp = (rd.get("pro") or {}).get("combat_positioning")
                mm_cp = (rd.get("mothman") or {}).get("combat_positioning")
                if pr_cp and mm_cp:
                    cp_races[rname] = {"pro": pr_cp, "mothman": mm_cp}
                pr_ag = (rd.get("pro") or {}).get("army_group_positioning")
                mm_ag = (rd.get("mothman") or {}).get("army_group_positioning")
                if pr_ag and mm_ag:
                    ag_races[rname] = {"pro": pr_ag, "mothman": mm_ag}
            if cp_races:
                out["pro_combat_positioning"] = {
                    "our_label": our_lbl_pd,
                    "meta": {
                        "pro_games": int(pd_meta.get("pro_combat_games_total", 371) or 371),
                        "pro_battles": int(pd_meta.get("pro_combat_battles_total", 2513) or 2513),
                        "our_games": int(pd_meta.get("mothman_games_total", 0) or 0),
                        "our_battles": int(pd_meta.get("mothman_combat_battles_total", 0) or 0),
                    },
                    "by_race": cp_races,
                }
            if ag_races:
                out["pro_army_group_positioning"] = {
                    "our_label": our_lbl_pd,
                    "meta": {
                        "pro_games": int(pd_meta.get("pro_army_group_games_total", 371) or 371),
                        "our_games": int(pd_meta.get("mothman_army_group_games_total", 0) or 0),
                    },
                    "by_race": ag_races,
                }
        except Exception:
            pass

    if not out["pro_combat_positioning"]:
        pcp_path = brain_dir / "scratch/loop/pro_combat_positioning_audit.json"
        if pcp_path.is_file():
            try:
                raw_pcp = json.loads(pcp_path.read_text(encoding="utf-8"))
                br = raw_pcp.get("by_race") or {}
                pm = raw_pcp.get("meta") or {}
                sample_rd = br.get("Protoss") or next(iter(br.values()), {})
                single_keys = [
                    (int(m.group(1)), str(k))
                    for k in sample_rd.keys()
                    for m in [re.fullmatch(r"mothman_l(\d+)", str(k))]
                    if m
                ]
                if single_keys:
                    ln, mk = max(single_keys)
                    olbl = f"Build {ln}"
                else:
                    mk = "mothman_l55_57"
                    olbl = "Builds 55–57"
                cp_fb = {
                    r: {"pro": br[r]["pro"], "mothman": br[r][mk]}
                    for r in ("Protoss", "Terran", "Zerg")
                    if r in br and "pro" in br[r] and mk in br[r]
                }
                if cp_fb:
                    out["pro_combat_positioning"] = {
                        "our_label": olbl,
                        "meta": {
                            "pro_games": int(pm.get("pro_games_lotv", 371) or 371),
                            "pro_battles": int(pm.get("pro_battles_total", 2513) or 2513),
                            "our_games": int(pm.get(f"{mk}_games", 0) or 0),
                            "our_battles": int(pm.get(f"{mk}_battles", 0) or 0),
                        },
                        "by_race": cp_fb,
                    }
            except Exception:
                pass

    if not out["pro_army_group_positioning"]:
        pag_path = brain_dir / "scratch/loop/pro_army_group_positioning_audit.json"
        if pag_path.is_file():
            try:
                raw_pag = json.loads(pag_path.read_text(encoding="utf-8"))
                br = raw_pag.get("by_race") or {}
                pm = raw_pag.get("meta") or {}
                sample_rd = br.get("Protoss") or next(iter(br.values()), {})
                single_keys = [
                    (int(m.group(1)), str(k))
                    for k in sample_rd.keys()
                    for m in [re.fullmatch(r"mothman_l(\d+)", str(k))]
                    if m
                ]
                mk, olbl = (max(single_keys)[1], f"Build {max(single_keys)[0]}") if single_keys else ("mothman_l55_57", "Builds 55–57")
                ag_fb = {
                    r: {"pro": br[r]["pro"], "mothman": br[r][mk]}
                    for r in ("Protoss", "Terran", "Zerg")
                    if r in br and "pro" in br[r] and mk in br[r]
                }
                if ag_fb:
                    out["pro_army_group_positioning"] = {
                        "our_label": olbl,
                        "meta": {
                            "pro_games": int(pm.get("pro_games_lotv", 371) or 371),
                            "our_games": int(pm.get(f"{mk}_games", 0) or 0),
                        },
                        "by_race": ag_fb,
                    }
            except Exception:
                pass

    # A3. Load Compact 8-Metric Pro Comparison Curves & Timings (Mothman vs. Opponents vs. Pros)
    curves_path = brain_dir / "scratch/pro_curves_and_timings.json"
    if curves_path.is_file():
        try:
            raw_cv = json.loads(curves_path.read_text(encoding="utf-8"))
            if isinstance(raw_cv, dict) and isinstance(raw_cv.get("curves"), dict):
                def _r1(v: Any) -> Optional[float]:
                    return round(float(v), 1) if isinstance(v, (int, float)) else None

                c_meta = raw_cv.get("meta") or {}
                c_coh_in = c_meta.get("cohorts") or {}
                c_cohorts = {
                    ck: {
                        "label": (c_coh_in.get(ck) or {}).get("label", ck.title()),
                        "games": int((c_coh_in.get(ck) or {}).get("games", 0) or 0),
                        "ge_games": int((c_coh_in.get(ck) or {}).get("game_events_games", 0) or 0),
                        "by_race": (c_coh_in.get(ck) or {}).get("by_race") or {},
                    }
                    for ck in ("mothman", "opponents", "pros")
                }
                c_metrics = (
                    "apm", "epm", "spm",
                    "army_minerals", "army_gas",
                    "collection_minerals", "collection_gas",
                )
                c_segs = [s for s in (raw_cv.get("segments") or ["all", "Protoss", "Terran", "Zerg"]) if s in raw_cv["curves"]]
                c_curves: Dict[str, Any] = {}
                c_summary: Dict[str, Any] = {}
                for seg in c_segs:
                    c_curves[seg] = {}
                    c_summary[seg] = {}
                    sc_d = raw_cv["curves"].get(seg) or {}
                    ss_d = (raw_cv.get("summary") or {}).get(seg) or {}
                    for mk in c_metrics:
                        mc_d = sc_d.get(mk) or {}
                        c_curves[seg][mk] = {
                            ck: [
                                {
                                    "t": int(pt.get("t", 0)),
                                    "n": int(pt.get("n", 0)),
                                    "p25": _r1(pt.get("p25")),
                                    "med": _r1(pt.get("med")),
                                    "p75": _r1(pt.get("p75")),
                                }
                                for pt in (mc_d.get(ck) or [])
                                if isinstance(pt, dict)
                            ]
                            for ck in ("mothman", "opponents", "pros")
                        }
                        ms_d = ss_d.get(mk) or {}
                        c_summary[seg][mk] = {}
                        for ck in ("mothman", "opponents", "pros"):
                            cs_v = ms_d.get(ck) or {}
                            ent_s: Dict[str, Any] = {
                                "n": int(cs_v.get("n", 0) or 0),
                                "p25": _r1(cs_v.get("p25")),
                                "med": _r1(cs_v.get("med")),
                                "p75": _r1(cs_v.get("p75")),
                            }
                            if isinstance(cs_v.get("peak"), dict):
                                ent_s["peak"] = _r1(cs_v["peak"].get("med"))
                            c_summary[seg][mk][ck] = ent_s
                c_timings: Dict[str, List[Dict[str, Any]]] = {}
                raw_tm = raw_cv.get("timings") or {}
                for rname in ("Protoss", "Terran", "Zerg"):
                    t_list = []
                    for item in raw_tm.get(rname) or []:
                        if not isinstance(item, dict):
                            continue
                        t_row: Dict[str, Any] = {
                            "key": item.get("key", ""),
                            "label": item.get("label", ""),
                            "kind": item.get("kind", "structure"),
                        }
                        for ck in ("mothman", "opponents", "pros"):
                            cv_i = item.get(ck) or {}
                            t_row[ck] = {
                                "n": int(cv_i.get("n", 0) or 0),
                                "total": int(cv_i.get("total", 0) or 0),
                                "adopt_pct": _r1(cv_i.get("adopt_pct")),
                                "p25": _r1(cv_i.get("p25")),
                                "med": _r1(cv_i.get("med")),
                                "p75": _r1(cv_i.get("p75")),
                                "med_fmt": cv_i.get("med_fmt"),
                            }
                        t_list.append(t_row)
                    c_timings[rname] = t_list
                obs_extra_keys = (
                    "army_cohesion",
                    "engage_retreat",
                    "expansions_4plus",
                    "gas_7plus",
                    "tier_composition",
                    "all_upgrades",
                    "concave_layering",
                    "army_rotation",
                    "multiprong_backstabs",
                    "unit_comp_clusters",
                    "production_utilization",
                    "macro_abilities",
                    "macro_energy",
                    "combat_spells",
                )
                pro_cv_out: Dict[str, Any] = {
                    "schema_version": raw_cv.get("schema_version", 4),
                    "run_id": c_meta.get("run_id", ""),
                    "buckets_sec": raw_cv.get("buckets_sec") or list(range(0, 901, 30)),
                    "segments": c_segs,
                    "matchups": raw_cv.get("matchups") or [],
                    "cohorts": c_cohorts,
                    "summary": c_summary,
                    "curves": c_curves,
                    "timings": c_timings,
                }
                for ek in obs_extra_keys:
                    if ek in raw_cv and raw_cv[ek] is not None:
                        pro_cv_out[ek] = _compact_floats(raw_cv[ek], 3)
                out["pro_curves"] = pro_cv_out
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
                    desc = re.sub(
                        r"^(?:Ability-Mastery|Non-Combat|Real SC2|Pro-DB|Match-forensics|Replay Regression|Econ-Harass)[^:]*:\s*",
                        "",
                        desc,
                        flags=re.I,
                    )
                    desc = desc.replace("`", "")
                    desc = re.sub(r"\s*\(guards\s+[^)]+\)", "", desc, flags=re.I)
                    desc = re.sub(r",?\s*\bguards\s+arena-minimax\s+retreat\b", "", desc, flags=re.I)
                    desc = re.sub(r"\(\d{3,4}\s+([^()]+)\)", r"(\1)", desc)
                    desc = re.sub(r"\(\d{3,4},\s*([^()]+)\)", r"(\1)", desc)
                    desc = re.sub(r"\s*\(\d{2,4}(?:/\d{2,4})*\)", "", desc)
                    desc = desc.replace("MineralField450 (5M)", "5-mineral")
                    desc = desc.replace("RichMineralField (7M)", "7-mineral rich")
                    desc = desc.replace("BattleStationMineralField750 (150M)", "150-mineral")
                    desc = desc.replace("(no IM)", "(no Interference Matrix)")
                    desc = re.sub(r"\bcasting AAM\b", "casting Anti-Armor Missile", desc)
                    desc = desc.replace("(0 AA)", "(no anti-air)")
                    desc = desc.replace("(100e, 0 Obs)", "(100e, no Observers)")
                    desc = desc.replace("(100e, 0 flyers)", "(100e, no flyers)")
                    desc = desc.replace("(0 flyers)", "(no flyers)")
                    desc = re.sub(r"\bP2\s+active\b", "enemy", desc)
                    desc = re.sub(r"\bP2\s+base\b", "enemy base", desc)
                    desc = re.sub(r"\s+", " ", desc).strip()
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

    # Also ingest any iter*_arena/pass*.json runs (Loop 58+ inner Arena passes: ability-mastery, core, non-combat, full catalog)
    arena_scenario_results: Dict[str, Dict[str, Any]] = {}
    d_by_cat_rank: Dict[str, Tuple[int, int, int, int]] = {}
    if latest_d_json and latest_d_json.is_file():
        try:
            dj_tmp = json.loads(latest_d_json.read_text(encoding="utf-8"))
            for sc in dj_tmp.get("scenarios", dj_tmp.get("results", [])):
                if isinstance(sc, dict) and sc.get("id"):
                    arena_scenario_results[str(sc["id"])] = dict(sc, _src_loop=latest_loop_num, _src_pass=0)
        except Exception:
            pass
    if loop_scratch.is_dir():
        def _arena_pass_rank(fname: str) -> int:
            low = fname.lower()
            if "final" in low:
                return 999
            if "sanity" in low:
                return 500
            m_p = re.search(r"pass(\d+)", low)
            return int(m_p.group(1)) if m_p else 0

        iter_arena_dirs = sorted(
            (d for d in loop_scratch.glob("iter*_arena") if d.is_dir()),
            key=lambda p: int(re.search(r"iter(\d+)_arena$", p.name).group(1))
            if re.search(r"iter(\d+)_arena$", p.name)
            else 0,
        )
        for adir in iter_arena_dirs:
            m_it = re.search(r"iter(\d+)_arena$", adir.name)
            if not m_it:
                continue
            alnum = int(m_it.group(1))
            pass_files = sorted(
                adir.glob("*.json"),
                key=lambda p: (_arena_pass_rank(p.name), p.stat().st_mtime),
            )
            for pf in pass_files:
                low_name = pf.name.lower()
                if "selfplay" in low_name or low_name.startswith("recheck_"):
                    continue
                try:
                    pdata = json.loads(pf.read_text(encoding="utf-8"))
                except Exception:
                    continue
                sc_list = pdata.get("scenarios", pdata.get("results", []))
                if not isinstance(sc_list, list) or not sc_list:
                    continue
                pnum = _arena_pass_rank(low_name)
                if alnum >= out["arena3"].get("loop_num", 0):
                    out["arena3"]["loop_num"] = alnum
                pdata_summ = pdata.get("summary") or {}
                if "core" in low_name and int(pdata_summ.get("total", 0) or 0) >= 60:
                    dw_t = int(pdata_summ.get("mothman_wins", pdata_summ.get("wins", 0)) or 0)
                    dl_t = int(pdata_summ.get("p2_wins", pdata_summ.get("losses", 0)) or 0)
                    dd_t = int(pdata_summ.get("draws", 0) or 0)
                    out["arena3"]["dummy_rec"] = f"{dw_t}–{dl_t}–{dd_t}"
                    out["arena3"]["dummy_trade"] = float(
                        pdata_summ.get("agg_trade_ratio", pdata_summ.get("trade_ratio", 0.0)) or 0.0
                    )
                elif "all" in low_name and int(pdata_summ.get("total", 0) or 0) >= 200:
                    aw_t = int(pdata_summ.get("mothman_wins", pdata_summ.get("wins", 0)) or 0)
                    al_t = int(pdata_summ.get("p2_wins", pdata_summ.get("losses", 0)) or 0)
                    ad_t = int(pdata_summ.get("draws", 0) or 0)
                    out["arena3"]["all_rec"] = f"{aw_t}–{al_t}–{ad_t}"
                    out["arena3"]["all_trade"] = float(
                        pdata_summ.get("agg_trade_ratio", pdata_summ.get("trade_ratio", 0.0)) or 0.0
                    )
                    out["arena3"]["all_total"] = int(pdata_summ.get("total", len(sc_list)) or len(sc_list))
                for sc in sc_list:
                    if not isinstance(sc, dict) or not sc.get("id"):
                        continue
                    sid = str(sc["id"])
                    prev_sc = arena_scenario_results.get(sid)
                    prev_key = (int(prev_sc.get("_src_loop", 0)), int(prev_sc.get("_src_pass", -1))) if prev_sc else (-1, -1)
                    if (alnum, pnum) >= prev_key:
                        merged = dict(sc)
                        merged["_src_loop"] = alnum
                        merged["_src_pass"] = pnum
                        arena_scenario_results[sid] = merged
                # Recompute per-category dummy rollup for categories present in this pass file
                summ_by_cat = pdata_summ.get("by_category") or {}
                cats_in_pass: Dict[str, Dict[str, Any]] = {}
                for sc in sc_list:
                    if not isinstance(sc, dict):
                        continue
                    c = str(sc.get("category") or "other")
                    b = cats_in_pass.setdefault(
                        c,
                        {"wins": 0, "losses": 0, "draws": 0, "k": 0.0, "l": 0.0, "sv_ok": 0, "sv_n": 0, "nc_scores": []},
                    )
                    r = str(sc.get("winner") or sc.get("outcome") or "").lower()
                    wt = str(sc.get("win_type") or "").lower()
                    if r in ("mothman", "win", "p1", "pass", "econ_pass", "runby_pass", "non_combat_pass") or wt == "non_combat_pass":
                        b["wins"] += 1
                    elif r in ("draw", "tie"):
                        b["draws"] += 1
                    else:
                        b["losses"] += 1
                    b["k"] += float(sc.get("p2_lost_val", sc.get("enemy_lost_value", sc.get("killed_val", 0))) or 0)
                    b["l"] += float(sc.get("p1_lost_val", sc.get("our_lost_value", sc.get("lost_val", 0))) or 0)
                    if "spell_verified" in sc and sc.get("spell_verified") is not None:
                        b["sv_n"] += 1
                        if sc.get("spell_verified"):
                            b["sv_ok"] += 1
                    if sc.get("non_combat_score") is not None:
                        try:
                            b["nc_scores"].append(float(sc["non_combat_score"]))
                        except (TypeError, ValueError):
                            pass
                for c, b in cats_in_pass.items():
                    if c in summ_by_cat and summ_by_cat[c].get("agg_trade_ratio") is not None:
                        b["agg_trade_ratio"] = summ_by_cat[c]["agg_trade_ratio"]
                    nc_list = b.pop("nc_scores", [])
                    if c in summ_by_cat and summ_by_cat[c].get("avg_non_combat_score") is not None:
                        b["nc_avg"] = float(summ_by_cat[c]["avg_non_combat_score"])
                        b["nc_n"] = len(nc_list) or int(summ_by_cat[c].get("total", 0) or 0)
                    elif nc_list:
                        b["nc_avg"] = round(sum(nc_list) / len(nc_list), 1)
                        b["nc_n"] = len(nc_list)
                    b_tot = b["wins"] + b["losses"] + b["draws"]
                    cat_tot = int((cat_catalog.get(c) or {}).get("total", 0) or 0)
                    is_full_cat = 1 if (cat_tot <= 0 or b_tot >= cat_tot) else 0
                    cand_rank = (is_full_cat, alnum, pnum, b_tot)
                    if cand_rank >= d_by_cat_rank.get(c, (-1, -1, -1, -1)):
                        d_by_cat_rank[c] = cand_rank
                        d_by_cat[c] = b
    out["arena3"]["scenario_results"] = arena_scenario_results

    ordered_cats: List[Dict[str, Any]] = []
    seen_cids: set[str] = set()
    cat_entries: List[Tuple[str, str, str]] = [
        (cid, clabel, cdesc) for cid, (clabel, cdesc) in CATEGORY_META.items() if cid in cat_catalog
    ]
    for cid in sorted(cat_catalog.keys()):
        if cid not in CATEGORY_META:
            cat_entries.append((cid, cid.replace("-", " ").title(), "Isolated StarCraft II tactical drill scenarios."))

    for cid, clabel, cdesc in cat_entries:
        if cid in seen_cids:
            continue
        seen_cids.add(cid)
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
                "sv_ok": int(dc.get("sv_ok", 0) or 0),
                "sv_n": int(dc.get("sv_n", 0) or 0),
                "is_non_combat": (cid == "non-combat") or ("non-combat" in ci.get("scoring_modes", set())),
                "nc_avg": float(dc["nc_avg"]) if dc.get("nc_avg") is not None else None,
                "nc_n": int(dc.get("nc_n", 0) or 0),
            }
        )
    out["arena3"]["categories"] = ordered_cats

    # C. Load Live SQLite Matchup Metrics, Minute Curves, Build Timings, Anomalies & APM
    out["current_build"] = {}
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

        # Auto-detect latest full 84-match local benchmark (e.g. iter58b_ship11_full) AND highest shipped release (e.g. Release #10 / Build 57)
        ship_cands = cur.execute(
            """
            SELECT run_id, COUNT(*) AS n
            FROM matches
            WHERE source_type='local_arena'
              AND run_id LIKE '%_ship%_full%'
              AND run_id NOT LIKE '%iter49_ship8_full%'
            GROUP BY run_id
            HAVING COUNT(*) >= 78
            """
        ).fetchall()
        latest_ship_run = ""
        latest_ship_iter = 0
        latest_ship_suffix = ""
        latest_ship_num = 0
        latest_is_shipped = False
        best_ship_key: Tuple[int, int, str, int, str] = (-1, -1, "", -1, "")
        for rid, _cnt in ship_cands:
            m_sh = re.search(r"iter(\d+)([a-z]?)_ship(\d+)_full", str(rid), flags=re.I)
            if not m_sh:
                continue
            it_n = int(m_sh.group(1))
            suf = m_sh.group(2).upper()
            sh_n = int(m_sh.group(3))
            cand_shipped = _is_shipped_build(it_n, suf, sh_n)
            cand_key = (1 if cand_shipped else 0, it_n, suf, sh_n, str(rid))
            if cand_key > best_ship_key:
                best_ship_key = cand_key
                latest_ship_iter = it_n
                latest_ship_suffix = suf
                latest_ship_num = sh_n
                latest_ship_run = str(rid)
                latest_is_shipped = cand_shipped
        if latest_is_shipped and (latest_ship_iter, latest_ship_num) > (live_ship_iter, live_ship_num):
            live_ship_iter, live_ship_num = latest_ship_iter, latest_ship_num

        if latest_ship_run:
            def _agg_cohort(where_sql: str, params: Tuple[Any, ...] = ()) -> Dict[str, Any]:
                r = cur.execute(
                    f"""
                    SELECT COUNT(*),
                           SUM(CASE WHEN LOWER(m.result)='win' THEN 1 ELSE 0 END),
                           SUM(CASE WHEN LOWER(m.result)='loss' THEN 1 ELSE 0 END),
                           SUM(CASE WHEN LOWER(m.result)='tie' THEN 1 ELSE 0 END),
                           ROUND(SUM(m.killed_val)*1.0/NULLIF(SUM(m.lost_val),0), 2),
                           ROUND(AVG(m.sup_blk_pct), 1),
                           ROUND(AVG(m.avg_step_ms), 2),
                           ROUND(SUM(CASE WHEN m.opp_min_collected > 0 THEN m.our_min_collected END)*1.0/NULLIF(SUM(CASE WHEN m.opp_min_collected > 0 THEN m.opp_min_collected END),0), 2),
                           ROUND(AVG(CASE WHEN m.opp_min_collected > 0 THEN m.our_min_collected END), 0),
                           ROUND(AVG(CASE WHEN m.opp_min_collected > 0 THEN m.opp_min_collected END), 0),
                           ROUND(SUM(CASE WHEN m.opp_gas_collected > 0 THEN m.our_gas_collected END)*1.0/NULLIF(SUM(CASE WHEN m.opp_gas_collected > 0 THEN m.opp_gas_collected END),0), 2),
                           ROUND(AVG(CASE WHEN m.opp_gas_collected > 0 THEN m.our_gas_collected END), 0),
                           ROUND(AVG(CASE WHEN m.opp_gas_collected > 0 THEN m.opp_gas_collected END), 0),
                           ROUND(AVG(m.our_upg_levels), 1),
                           ROUND(AVG(m.opp_upg_levels), 1),
                           ROUND(AVG(m.our_t1_pct), 1),
                           ROUND(AVG(m.our_t2_pct), 1),
                           ROUND(AVG(m.our_t3_pct), 1)
                    FROM matches m WHERE {where_sql}
                    """,
                    params,
                ).fetchone()
                n_v = int(r[0] or 0)
                w_v = int(r[1] or 0)
                l_v = int(r[2] or 0)
                t_v = int(r[3] or 0)
                return {
                    "n": n_v,
                    "w": w_v,
                    "l": l_v,
                    "t": t_v,
                    "wr": round(100.0 * w_v / n_v, 1) if n_v else 0.0,
                    "nl": round(100.0 * (w_v + t_v) / n_v, 1) if n_v else 0.0,
                    "tr": float(r[4] or 0.0),
                    "sb": float(r[5] or 0.0),
                    "step_ms": float(r[6] or 0.0),
                    "min_ratio": float(r[7]) if r[7] is not None else None,
                    "our_min_avg": float(r[8]) if r[8] is not None else None,
                    "opp_min_avg": float(r[9]) if r[9] is not None else None,
                    "gas_ratio": float(r[10]) if r[10] is not None else None,
                    "our_gas_avg": float(r[11]) if r[11] is not None else None,
                    "opp_gas_avg": float(r[12]) if r[12] is not None else None,
                    "our_upg_lv": float(r[13]) if r[13] is not None else None,
                    "opp_upg_lv": float(r[14]) if r[14] is not None else None,
                    "t1_pct": float(r[15]) if r[15] is not None else None,
                    "t2_pct": float(r[16]) if r[16] is not None else None,
                    "t3_pct": float(r[17]) if r[17] is not None else None,
                }

            # Matching H2H run for the exact same build (never fall back from a suffixed ship like 65H to held 65A)
            h2h_row = cur.execute(
                """
                SELECT run_id FROM matches
                WHERE source_type='local_arena' AND run_id LIKE ?
                GROUP BY run_id
                ORDER BY COUNT(*) DESC, run_id DESC LIMIT 1
                """,
                (f"%iter{latest_ship_iter}{latest_ship_suffix.lower()}_h2h%",),
            ).fetchone()
            h2h_run_id = str(h2h_row[0]) if h2h_row else ""

            cb_cohorts = {
                "all": _agg_cohort("m.run_id = ?", (latest_ship_run,)),
                "ext": _agg_cohort("m.run_id = ? AND COALESCE(m.is_selfplay,0)=0", (latest_ship_run,)),
                "core": _agg_cohort("m.run_id = ? AND COALESCE(m.is_selfplay,0)=0 AND m.opp_cohort='core_12'", (latest_ship_run,)),
                "unseen": _agg_cohort("m.run_id = ? AND COALESCE(m.is_selfplay,0)=0 AND m.opp_cohort!='core_12'", (latest_ship_run,)),
                "selfplay": _agg_cohort("m.run_id = ? AND COALESCE(m.is_selfplay,0)=1", (latest_ship_run,)),
                "h2h": _agg_cohort("m.run_id = ?", (h2h_run_id,)) if h2h_run_id else {"n": 0, "w": 0, "l": 0, "t": 0, "wr": 0.0, "nl": 0.0, "tr": 0.0, "sb": 0.0, "step_ms": 0.0},
            }
            cb_by_race: Dict[str, Dict[str, Any]] = {}
            for rname in ("Protoss", "Terran", "Zerg"):
                cb_by_race[rname] = {
                    "ext": _agg_cohort("m.run_id = ? AND COALESCE(m.is_selfplay,0)=0 AND m.our_race = ?", (latest_ship_run, rname)),
                    "core": _agg_cohort("m.run_id = ? AND COALESCE(m.is_selfplay,0)=0 AND m.opp_cohort='core_12' AND m.our_race = ?", (latest_ship_run, rname)),
                    "unseen": _agg_cohort("m.run_id = ? AND COALESCE(m.is_selfplay,0)=0 AND m.opp_cohort!='core_12' AND m.our_race = ?", (latest_ship_run, rname)),
                }
            cb_by_mu: Dict[str, Dict[str, Any]] = {}
            for mu in MATCHUPS_ORDER:
                r = cur.execute(
                    """
                    SELECT COUNT(*),
                           SUM(CASE WHEN LOWER(m.result)='win' THEN 1 ELSE 0 END),
                           SUM(CASE WHEN LOWER(m.result)='loss' THEN 1 ELSE 0 END),
                           SUM(CASE WHEN LOWER(m.result)='tie' THEN 1 ELSE 0 END),
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
                    WHERE m.run_id = ? AND COALESCE(m.is_selfplay,0)=0 AND m.matchup = ?
                    """,
                    (latest_ship_run, mu),
                ).fetchone()
                n_m = int(r[0] or 0)
                w_m = int(r[1] or 0)
                l_m = int(r[2] or 0)
                t_m = int(r[3] or 0)
                cor_m = _agg_cohort("m.run_id = ? AND COALESCE(m.is_selfplay,0)=0 AND m.opp_cohort='core_12' AND m.matchup = ?", (latest_ship_run, mu))
                cb_by_mu[mu] = {
                    "ext": {
                        "n": n_m, "w": w_m, "l": l_m, "t": t_m,
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
                    },
                    "core": cor_m,
                }
            cb_anoms: Dict[str, int] = {}
            for aname, acnt in cur.execute(
                """
                SELECT a.anomaly_name, COUNT(*)
                FROM match_anomalies a JOIN matches m ON m.replay_id = a.replay_id
                WHERE a.player_side='p1' AND m.run_id = ? AND COALESCE(m.is_selfplay,0)=0
                GROUP BY a.anomaly_name
                """,
                (latest_ship_run,),
            ).fetchall():
                cb_anoms[str(aname)] = int(acnt)
            cb_wk: Dict[str, List[Dict[str, Any]]] = {"Protoss": [], "Terran": [], "Zerg": []}
            cb_ar: Dict[str, List[Dict[str, Any]]] = {"Protoss": [], "Terran": [], "Zerg": []}
            for rname in ("Protoss", "Terran", "Zerg"):
                for minute, wk, our_a, opp_a in cur.execute(
                    """
                    SELECT ms.minute,
                           ROUND(AVG(CASE WHEN ms.player_id = m.our_player_id THEN ms.workers_active END), 1),
                           ROUND(AVG(CASE WHEN ms.player_id = m.our_player_id THEN ms.army_value_total END), 0),
                           ROUND(AVG(CASE WHEN ms.player_id != m.our_player_id THEN ms.army_value_total END), 0)
                    FROM match_minute_stats ms JOIN matches m ON m.replay_id = ms.replay_id
                    WHERE m.our_race = ? AND m.run_id = ? AND COALESCE(m.is_selfplay,0)=0 AND ms.minute BETWEEN 1 AND 12
                    GROUP BY ms.minute ORDER BY ms.minute ASC
                    """,
                    (rname, latest_ship_run),
                ).fetchall():
                    mi = int(minute)
                    if mi <= 10 and wk is not None:
                        cb_wk[rname].append({"m": mi, "w": float(wk)})
                    if our_a is not None and opp_a is not None:
                        cb_ar[rname].append({"m": mi, "our": float(our_a), "opp": float(opp_a)})
            out["current_build"] = {
                "loop_num": latest_ship_iter,
                "loop_suffix": latest_ship_suffix,
                "build_tag": f"{latest_ship_iter}{latest_ship_suffix}",
                "ship_num": latest_ship_num,
                "is_shipped": latest_is_shipped,
                "live_ship_num": live_ship_num,
                "live_loop_num": live_ship_iter,
                "run_id": latest_ship_run,
                "h2h_run_id": h2h_run_id,
                "cohorts": cb_cohorts,
                "by_race": cb_by_race,
                "by_matchup": cb_by_mu,
                "anomalies": cb_anoms,
                "worker_curves": cb_wk,
                "army_curves": cb_ar,
            }

            # Attach North Star Mine x Trade summary & scatter to out["pro_curves"] from SQLite
            if isinstance(out.get("pro_curves"), dict) and out["pro_curves"].get("curves"):
                obs_rid = str(out["pro_curves"].get("run_id") or "") or latest_ship_run
                sc_rows = cur.execute(
                    """
                    SELECT m.match_index, m.our_race, m.matchup, m.opponent, LOWER(m.result),
                           m.killed_val, m.lost_val, m.trade_ratio,
                           m.our_min_collected, m.opp_min_collected, m.min_collected_ratio,
                           m.our_gas_collected, m.opp_gas_collected, m.gas_collected_ratio,
                           m.our_upg_levels, m.opp_upg_levels,
                           m.our_t1_pct, m.our_t2_pct, m.our_t3_pct
                    FROM matches m
                    WHERE m.run_id = ? AND COALESCE(m.is_selfplay,0)=0
                    ORDER BY m.match_index ASC
                    """,
                    (obs_rid,),
                ).fetchall()
                if not sc_rows and obs_rid != latest_ship_run:
                    sc_rows = cur.execute(
                        """
                        SELECT m.match_index, m.our_race, m.matchup, m.opponent, LOWER(m.result),
                               m.killed_val, m.lost_val, m.trade_ratio,
                               m.our_min_collected, m.opp_min_collected, m.min_collected_ratio,
                               m.our_gas_collected, m.opp_gas_collected, m.gas_collected_ratio,
                               m.our_upg_levels, m.opp_upg_levels,
                               m.our_t1_pct, m.our_t2_pct, m.our_t3_pct
                        FROM matches m
                        WHERE m.run_id = ? AND COALESCE(m.is_selfplay,0)=0
                        ORDER BY m.match_index ASC
                        """,
                        (latest_ship_run,),
                    ).fetchall()
                if sc_rows:
                    def _mt_slice(rlist: List[Tuple[Any, ...]]) -> Dict[str, Any]:
                        if not rlist:
                            return {}
                        ks = sum(float(x[5] or 0) for x in rlist)
                        ls = sum(float(x[6] or 0) for x in rlist)
                        trs = [float(x[7]) for x in rlist if x[7] is not None and float(x[7]) < 90.0]
                        mvalid = [x for x in rlist if x[8] is not None and x[9] is not None and float(x[9]) > 0]
                        om_s = sum(float(x[8]) for x in mvalid)
                        em_s = sum(float(x[9]) for x in mvalid)
                        gvalid = [x for x in rlist if x[11] is not None and x[12] is not None and float(x[12]) > 0]
                        og_s = sum(float(x[11]) for x in gvalid)
                        eg_s = sum(float(x[12]) for x in gvalid)
                        uvalid = [x for x in rlist if x[14] is not None and x[15] is not None]
                        tvalid = [x for x in rlist if x[16] is not None and x[17] is not None and x[18] is not None]
                        return {
                            "n": len(rlist),
                            "trade_agg": round(ks / ls, 2) if ls > 0 else None,
                            "trade_med": round(statistics.median(trs), 2) if trs else None,
                            "agg_min_ratio": round(om_s / em_s, 2) if em_s > 0 else None,
                            "our_min_collected_avg": round(om_s / len(mvalid), 0) if mvalid else None,
                            "opp_min_collected_avg": round(em_s / len(mvalid), 0) if mvalid else None,
                            "agg_gas_ratio": round(og_s / eg_s, 2) if eg_s > 0 else None,
                            "our_gas_collected_avg": round(og_s / len(gvalid), 0) if gvalid else None,
                            "opp_gas_collected_avg": round(eg_s / len(gvalid), 0) if gvalid else None,
                            "our_upg_levels": round(sum(float(x[14]) for x in uvalid) / len(uvalid), 1) if uvalid else None,
                            "opp_upg_levels": round(sum(float(x[15]) for x in uvalid) / len(uvalid), 1) if uvalid else None,
                            "our_t1_pct": round(sum(float(x[16]) for x in tvalid) / len(tvalid), 1) if tvalid else None,
                            "our_t2_pct": round(sum(float(x[17]) for x in tvalid) / len(tvalid), 1) if tvalid else None,
                            "our_t3_pct": round(sum(float(x[18]) for x in tvalid) / len(tvalid), 1) if tvalid else None,
                        }

                    mt_by_race = {
                        rn: _mt_slice([x for x in sc_rows if x[1] == rn])
                        for rn in ("Protoss", "Terran", "Zerg")
                        if any(x[1] == rn for x in sc_rows)
                    }
                    mt_pts = []
                    for x in sc_rows:
                        if x[7] is None or x[10] is None:
                            continue
                        mt_pts.append({
                            "id": str(x[0] or ""),
                            "race": str(x[1] or ""),
                            "matchup": str(x[2] or ""),
                            "opp": str(x[3] or "Opponent"),
                            "result": x[4] if x[4] in ("win", "loss") else "tie",
                            "trade_ratio": round(min(9.99, float(x[7])), 2),
                            "min_ratio": round(float(x[10]), 2),
                            "our_min": int(round(float(x[8] or 0))),
                            "opp_min": int(round(float(x[9] or 0))),
                            "gas_ratio": round(float(x[13]), 2) if x[13] is not None else None,
                            "upg_lv": int(x[14]) if x[14] is not None else None,
                            "opp_upg_lv": int(x[15]) if x[15] is not None else None,
                            "t1": round(float(x[16]), 1) if x[16] is not None else None,
                            "t2": round(float(x[17]), 1) if x[17] is not None else None,
                            "t3": round(float(x[18]), 1) if x[18] is not None else None,
                        })
                    out["pro_curves"]["mine_trade_summary"] = {
                        "overall": _mt_slice(sc_rows),
                        "by_race": mt_by_race,
                    }
                    out["pro_curves"]["mine_trade_scatter"] = mt_pts

        # APM per race from match_cmd_summary
        for rname, avg_apm, max_apm in cur.execute(
            """
            SELECT m.our_race, ROUND(AVG(c.apm), 1), ROUND(MAX(c.apm), 1)
            FROM match_cmd_summary c JOIN matches m ON m.replay_id = c.replay_id
            WHERE c.user_id = m.our_player_id AND (m.run_id LIKE '%iter4%' OR m.run_id LIKE '%iter5%')
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
                 OR m.run_id LIKE '%iter48%' OR m.run_id LIKE '%iter49_ship8_clean_full%'
                 OR m.run_id LIKE '%iter50_w3_full%' OR m.run_id LIKE '%iter51_ship9_full%'
                 OR m.run_id LIKE '%iter57_ship10_full%' OR m.run_id LIKE '%iter58b_ship11_full%'
                 OR m.run_id LIKE '%iter59c_ship11_full%' OR m.run_id LIKE '%iter60b_ship12_full%'
                 OR m.run_id LIKE '%iter61c_ship13_full%' OR m.run_id LIKE '%iter62c_ship14_full%'
                 OR m.run_id LIKE '%iter63b_ship15_full%' OR m.run_id LIKE '%iter64b_ship16_full%'
                 OR m.run_id LIKE '%iter65h_ship17_full%' OR m.run_id LIKE '%iter66_ship18_full%')
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
            f'<video class="clip-video" controls playsinline webkit-playsinline preload="none"{p_attr}>'
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


def render_loop_diagram_section(rich: Dict[str, Any], section_num: str = "Section 2") -> str:
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
                "Eight Mothman bots play continuously on AI Arena and across local practice batches. "
                "Every replay is parsed into minute-by-minute worker counts, army values, expansion timings, and fault flags."
            ),
            "why": (
                "Win rate bounces around over ten-game samples. Recording economy curves and fault flags "
                "catches silent bugs, such as production stalling mid-game, even in matches Mothman wins."
            ),
            "metric": f"{lp['prod_replays']} public AI Arena matches · 0 crashes across recent live builds",
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
                "Every candidate first plays a 6- to 12-game head-to-head set (about 2 to 5 minutes) against the build currently live on AI Arena. "
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
            "metric": f"{int((rich.get('current_build') or {}).get('live_ship_num') or 15)} live releases shipped across 8 AI Arena bots (Div 6–7 & Div 9)",
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
    <text x="122" y="196" text-anchor="middle" class="node-sub">8 bots (v1+v2) → AI Arena</text>
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
    <p class="section-num">{html.escape(section_num)}</p>
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


def render_economy_stalls_history_details() -> str:
    return """
  <details style="margin-top:1.1rem;">
    <summary>Economy stalls addressed in Loops 49–51</summary>
    <p class="prose-tight" style="margin-top:0.65rem;">
      Across Loops 42–48 and earlier ladder builds, most macro losses traced to seven recurring economy stalls.
      Loops 49 through 51 shipped four general fallback checks to unstick blocked builds, rebalance mineral and gas workers,
      build supply ahead of production spikes, and resume halted structures. Those checks cut high-gas/low-mineral
      imbalances by 58% (12 to 5), zero-income stalls by 43% (7 to 4), and escrow lockouts by 41% (17 to 10).
    </p>
    <div class="table-wrap" style="margin-bottom:0.5rem;">
      <table>
        <thead>
          <tr>
            <th>Economy Stall</th>
            <th style="text-align:right">Baseline (L42–48)</th>
            <th style="text-align:right">Loss Rate</th>
            <th>Shipped Fallback (L49–51)</th>
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
"""


def render_architecture_section(
    rich: Dict[str, Any],
    section_num: str = "Section 4",
    include_history_details: bool = False,
) -> str:
    lp = rich["live_perf"]
    a3 = rich["arena3"]
    cb = rich.get("current_build") or {}
    t_sb = ((cb.get("by_race") or {}).get("Terran") or {}).get("ext", {}).get("sb", 2.3)

    pieces = {
        "sc2": {
            "title": "StarCraft II Engine (22.4 Steps / Sec)",
            "badge": "Game State",
            "what": "Every 45 milliseconds, StarCraft II sends everything visible on the map: our units, resources, building progress, and enemy units outside the fog of war.",
            "connects": "Feeds the six state readers and executes the filtered command batch returned at the end of the step.",
            "perf": f"{lp['avg_step_ms']:.2f} ms average bot step time (200 ms tournament limit) · 0 crashes on current build",
        },
        "econ": {
            "title": "Economy & Supply",
            "badge": "State Reader → Spending Queue",
            "what": "Tracks minerals, gas, active workers per base, free supply, and resources already promised to workers walking to build sites.",
            "connects": "Tells the spending queue what Mothman can afford right now, when supply is tight, and when a gas geyser has idle slots.",
            "perf": f"Re-assigns empty gas geysers within 8 seconds · Terran supply-blocked {t_sb:.1f}% of match time",
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
            "perf": "Filters out Sentry hallucinations and short-lived Broodlings so tech counters stay accurate",
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
            "perf": "Pathing-distance placement keeps north and south spawn win rates within 1.0 percentage point locally",
        },
        "prio": {
            "title": "Build & Spending Queue (What to Build)",
            "badge": "Decision → Command Filter",
            "what": "Every tick, workers, supply buildings, expansions, tech, upgrades, and army units compete on one priority list. When an expensive item like a second Nexus (400 minerals) or Robotics Bay is almost affordable, it sets cash aside (\"escrow\") so cheaper units do not drain the bank first.",
            "connects": "Turns all six state readers into ranked build and train orders, then hands them to the command filter.",
            "perf": "Shared facility caps keep the build queue and unit executor aligned",
        },
        "micro": {
            "title": "Squad & Worker Control (How to Fight)",
            "badge": "Decision → Command Filter",
            "what": "Controls squads and workers in fights: sniping enemy detectors before cloaked units engage, blinking hurt Stalkers back, dropping Widow Mines into mineral lines, casting spells, and pulling workers against early rushes.",
            "connects": "Uses scouting memory, enemy tech clues, fight simulations, and map geometry to issue unit orders to the command filter.",
            "perf": "Detector sniping, Blink kiting, transport juggles, spellcasting, and rush defense",
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
    history_block = render_economy_stalls_history_details() if include_history_details else ""
    return f"""
<section class="section-rule wide-col" id="architecture-section">
  <div class="section-head">
    <p class="section-num">{html.escape(section_num)}</p>
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
  {history_block}
  <script>
    window.__ARCH_PIECES__ = {pieces_json};
    window.__ARCH_WALKS__ = {walks_json};
  </script>
</section>
"""


def render_tactics_explorer_section(
    rich: Dict[str, Any],
    clips_by_cat: Optional[Dict[str, List[Dict[str, Any]]]] = None,
    section_num: str = "Section 3",
) -> str:
    a3 = rich["arena3"]
    cats = a3["categories"]
    clips_lookup = clips_by_cat or {}

    enriched_cats: List[Dict[str, Any]] = []
    total_recorded_clips = 0
    for c in cats:
        entry = dict(c)
        cat_clips = list(clips_lookup.get(c["id"], []))
        entry["clips"] = cat_clips
        entry["clip_count"] = len(cat_clips)
        total_recorded_clips += len(cat_clips)
        enriched_cats.append(entry)

    # Pick first populated category as default active tab (keeps initial poster load fast & zero-blank)
    default_idx = 0
    for idx, c in enumerate(enriched_cats):
        if c["clip_count"] > 0:
            default_idx = idx
            break

    cats_json = json.dumps(enriched_cats, ensure_ascii=False).replace("</", "<\\/")

    pills = [
        f'<button type="button" class="cat-pill" data-cat-idx="all">'
        f'All Scenarios <span class="pill-n">{total_recorded_clips}</span>'
        f"</button>"
    ]
    for idx, c in enumerate(enriched_cats):
        cls = "cat-pill is-active" if idx == default_idx else "cat-pill"
        count_lbl = f'{c["clip_count"]}' if c["clip_count"] else f'0/{c["total"]}'
        pills.append(
            f'<button type="button" class="{cls}" data-cat-idx="{idx}">'
            f'{html.escape(c["label"])} <span class="pill-n">{count_lbl}</span>'
            f"</button>"
        )

    first = enriched_cats[default_idx] if enriched_cats else {
        "label": "Sniping Detectors",
        "desc": "",
        "total": 20,
        "core": 8,
        "clip_count": 0,
        "d_w": 0,
        "d_l": 0,
        "d_d": 0,
        "d_tr": 0.0,
        "sp_w": 0,
        "sp_l": 0,
        "sp_d": 0,
        "sp_tr": 0.0,
        "sv_ok": 0,
        "sv_n": 0,
        "examples": [],
        "clips": [],
    }

    def _initial_clip_cards(clips: List[Dict[str, Any]]) -> str:
        if not clips:
            return '<p class="t-muted">No verified 3D recordings are staged for this category yet.</p>'
        cards = []
        for cl in clips:
            res_cls = "t-win" if cl.get("outcome") == "win" else ("t-loss" if cl.get("outcome") == "loss" else "t-muted")
            nc_score = cl.get("non_combat_score")
            nc_html = ""
            if isinstance(nc_score, (int, float)):
                nc_cls = "spell-ok" if cl.get("outcome") == "win" else "spell-miss"
                nc_html = f'<span class="spell-badge {nc_cls}">Score {float(nc_score):.0f}/100</span>'
            sv = cl.get("spell_verified")
            sv_html = ""
            if sv is True:
                sv_html = '<span class="spell-badge spell-ok">Spell verified</span>'
            elif sv is False:
                sv_html = '<span class="spell-badge spell-miss">Spell uncast</span>'
            sid_txt = str(cl.get("id") or "")
            m_sc = re.match(r"^sc2-([a-z0-9]+-[a-z0-9]+)(?:-|$)", sid_txt, flags=re.I)
            short_sid = m_sc.group(1) if m_sc else sid_txt
            sid_html = f'<div class="sid-pill" data-sid="{html.escape(sid_txt, quote=True)}" title="{html.escape(sid_txt, quote=True)}">{html.escape(short_sid)}</div>' if sid_txt else ""
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
                f'<span class="meta-badges">{nc_html}{sv_html}<span class="{res_cls}">{html.escape(cl.get("result_label", ""))}</span></span>'
                f"</div>"
                f'<h4>{html.escape(cl["title"])}</h4>'
                f"{sid_html}"
                f'<figure class="clip-figure">{vhtml}<figcaption>{html.escape(cl.get("caption", ""))}</figcaption></figure>'
                f"</article>"
            )
        return "".join(cards)

    d_suf = f"–{first['d_d']}" if first["d_d"] else ""
    s_suf = f"–{first['sp_d']}" if first["sp_d"] else ""
    if first.get("is_non_combat"):
        nc_tot = int(first.get("d_w", 0)) + int(first.get("d_l", 0)) + int(first.get("d_d", 0))
        nc_rec_lbl = f'{first["d_w"]}–{first["d_l"]}{d_suf}' if nc_tot else "Pending run"
        nc_avg_lbl = f'{float(first["nc_avg"]):.1f}/100' if first.get("nc_avg") is not None else "Pending"
        first_metrics = [
            f'<div class="m-chip"><span class="m-lbl">Pass / Fail</span><strong>{nc_rec_lbl}</strong></div>',
            f'<div class="m-chip"><span class="m-lbl">Avg Objective Score</span><strong>{nc_avg_lbl}</strong></div>',
        ]
    else:
        sp_tot = int(first.get("sp_w", 0)) + int(first.get("sp_l", 0)) + int(first.get("sp_d", 0))
        sp_chip_val = f'{first["sp_w"]}–{first["sp_l"]}{s_suf} ({first["sp_tr"]:.2f}×)' if sp_tot else "Scripted AI only"
        first_metrics = [
            f'<div class="m-chip"><span class="m-lbl">vs. Scripted AI</span><strong>{first["d_w"]}–{first["d_l"]}{d_suf} ({first["d_tr"]:.2f}×)</strong></div>',
            f'<div class="m-chip"><span class="m-lbl">vs. Mothman Copy</span><strong>{sp_chip_val}</strong></div>',
        ]
        if first.get("sv_n"):
            first_metrics.append(
                f'<div class="m-chip"><span class="m-lbl">Spell Cast Verified</span><strong>{first["sv_ok"]}/{first["sv_n"]}</strong></div>'
            )
    first_counts_lbl = (
        f'{first["clip_count"]} recorded · {first["total"]} in catalog (non-combat suite)'
        if (first.get("is_non_combat") and not first.get("core"))
        else f'{first["clip_count"]} recorded · {first["total"]} in catalog ({first["core"]} core)'
    )
    metric_cls = "metric-strip" if len(first_metrics) >= 3 else "metric-strip metric-strip-2"
    pop_cats = sum(1 for c in enriched_cats if c["clip_count"] > 0)

    all_suite_note = (
        f"full {a3['all_total']}-scenario sweep: <strong>{html.escape(a3['all_rec'])}</strong> at "
        f"<strong>{a3['all_trade']:.2f}×</strong> trade; "
        if a3.get("all_rec") and a3.get("all_total")
        else ""
    )
    l60_arena_note = (
        "Loop 62 updates lifted Ability Mastery to a new high of <strong>23–9</strong> "
        "(28 of 32 spells verified in-engine; Protoss <strong>9–0</strong> sweep, Zerg <strong>8–2</strong>) "
        "alongside <strong>62.0/100</strong> average on Non-Combat destructible-rock and mineral-walk drills. "
        if int(a3.get("loop_num") or 0) >= 62
        else (
            "Loop 60 updates lifted Ability Mastery to <strong>22–10</strong> (Protoss <strong>9–0</strong> sweep) "
            "and restored Non-Combat destructible-rock and mineral-walk shortcuts to <strong>62.0/100</strong> average. "
            if int(a3.get("loop_num") or 0) >= 60
            else ""
        )
    )

    return f"""
<section class="section-rule wide-col" id="tactics-section">
  <div class="section-head">
    <p class="section-num">{html.escape(section_num)}</p>
    <h2 class="section-kicker">Tactics Arena Scenarios</h2>
    <p class="section-intro">
      Isolated combat, harassment, and spell-casting drills run inside StarCraft II so we can verify unit control
      without playing a full match. Below are all <strong>{total_recorded_clips}</strong> tactical scenarios currently
      captured as real 3D StarCraft II video across <strong>{pop_cats}</strong> categories ({all_suite_note}latest core check:
      <strong>{html.escape(a3['dummy_rec'])}</strong> at <strong>{a3['dummy_trade']:.2f}×</strong> trade vs. scripted AI,
      <strong>{html.escape(a3['sp_rec'])}</strong> at <strong>{a3['sp_trade']:.2f}×</strong> vs. self). {l60_arena_note}Videos stay unloaded until you press play.
    </p>
  </div>

  <div class="interactive-panel">
    <div class="cat-pills" role="tablist" aria-label="Tactics Arena categories">
      {"".join(pills)}
    </div>
    <div class="arena-filter-bar" aria-label="Filter recorded scenarios">
      <div class="arena-filter-group" role="group" aria-label="Filter by race">
        <button type="button" class="cat-pill is-active" data-arena-race="all">All Races</button>
        <button type="button" class="cat-pill" data-arena-race="Protoss">Protoss</button>
        <button type="button" class="cat-pill" data-arena-race="Terran">Terran</button>
        <button type="button" class="cat-pill" data-arena-race="Zerg">Zerg</button>
      </div>
      <div class="arena-filter-group" role="group" aria-label="Filter by outcome">
        <button type="button" class="cat-pill is-active" data-arena-outcome="all">All Outcomes</button>
        <button type="button" class="cat-pill" data-arena-outcome="win">Win / Pass</button>
        <button type="button" class="cat-pill" data-arena-outcome="loss">Loss / Fail</button>
        <button type="button" class="cat-pill" data-arena-outcome="spell_ok">Spell Verified</button>
      </div>
      <input type="search" id="arena-search-input" class="arena-search-input"
             placeholder="Search unit, spell, or scenario ID…" aria-label="Search tactical scenarios" />
    </div>
    <div class="detail-drawer" id="cat-detail">
      <div class="detail-top-row">
        <div class="detail-title" id="cat-detail-title">{html.escape(first["label"])}</div>
        <span class="detail-badge" id="cat-detail-counts">{html.escape(first_counts_lbl)}</span>
      </div>
      <p class="detail-body" id="cat-detail-desc">{html.escape(first["desc"])}</p>
      <div class="{metric_cls}" id="cat-detail-metrics">
        {"".join(first_metrics)}
      </div>
      <div class="mini-kicker" id="cat-clips-heading" style="margin-top:0.85rem;">Recorded Scenarios ({first["clip_count"]} shown)</div>
      <div class="featured-grid" id="cat-detail-clips" style="margin-top:0.5rem;">
        {_initial_clip_cards(first.get("clips", []))}
      </div>
    </div>
  </div>
  <script>window.__ARENA_CATS__ = {cats_json}; window.__ARENA_DEFAULT_IDX__ = {default_idx};</script>
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


def _render_matchup_wr_svg(mu_list: List[Dict[str, Any]], build_label: str = "Current Build") -> str:
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
        f'<text x="{pl+16}" y="17.5" fill="#141413" font-size="11" font-weight="600">Recent Live Ladder (v1)</text>'
        f'<rect x="{pl+184}" y="8" width="11" height="11" rx="2" fill="#4A6B82" />'
        f'<text x="{pl+200}" y="17.5" fill="#141413" font-size="11" font-weight="600">{html.escape(build_label)} · 14 Core</text>'
        f'<rect x="{pl+378}" y="8" width="11" height="11" rx="2" fill="#C5C0B4" />'
        f'<text x="{pl+394}" y="17.5" fill="#5E5D59" font-size="11">{html.escape(build_label)} · All 26 Local</text>',
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
        cor = m.get("cur_core") or m.get("core") or {}
        loc = m.get("cur_local") or m.get("local") or {}
        p_wr = float(prd.get("wr") or 0.0)
        c_wr = float(cor.get("wr") or 0.0)
        l_wr = float(loc.get("wr") or 0.0)
        bars = [
            (cx - bw * 1.5 - gap, p_wr, "#C4633E", f"{m['matchup']} Live Ladder: {p_wr:.1f}% ({prd.get('w',0)}W-{prd.get('l',0)}L)"),
            (cx - bw * 0.5,       c_wr, "#4A6B82", f"{m['matchup']} {build_label} Core-14: {c_wr:.1f}% ({cor.get('w',0)}W-{cor.get('l',0)}L)"),
            (cx + bw * 0.5 + gap, l_wr, "#C5C0B4", f"{m['matchup']} {build_label} All 26 Local: {l_wr:.1f}% ({loc.get('w',0)}W-{loc.get('l',0)}L)"),
        ]
        for bx, val, fill, tip in bars:
            by = _y(val)
            bh = max(1.5, (h - pb) - by) if val > 0 else 0.0
            if bh > 0:
                parts.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bw:.1f}" height="{bh:.1f}" rx="2.5" fill="{fill}"><title>{html.escape(tip)}</title></rect>')
        # Label current local WR% cleanly above right bar so per-matchup spread stands out
        ly_lbl = _y(l_wr) - 5
        parts.append(
            f'<text x="{cx + bw + gap:.1f}" y="{max(pt - 3, ly_lbl):.1f}" text-anchor="middle" '
            f'fill="#4A4945" font-size="9.5" font-weight="600">{l_wr:.0f}%</text>'
        )
        parts.append(f'<text x="{cx:.1f}" y="{h-pb+16}" text-anchor="middle" fill="#141413" font-size="11.5" font-weight="600">{m["matchup"]}</text>')
        t_suf = f"–{loc['t']}" if loc.get("t") else ""
        parts.append(f'<text x="{cx:.1f}" y="{h-pb+29}" text-anchor="middle" fill="#7A7870" font-size="9.2">{loc.get("w",0)}–{loc.get("l",0)}{t_suf} local</text>')

    parts.append("</svg>")
    return "".join(parts)


def render_historical_faults_details(rich: Dict[str, Any]) -> str:
    """Multi-loop historical fault counts moved onto history.html."""
    mus = rich["matchups"]
    mu_list = [mus[m] for m in MATCHUPS_ORDER if m in mus]
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
    return f"""
  <details style="margin-top:1.25rem;">
    <summary>Cumulative expansion, gas, and fault counts across recent practice runs</summary>
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
      <p class="table-note" style="margin-top:0.35rem;">Cumulative fault counts across recent practice batches ({total_cloak_losses} cloak wipeouts total; TvT zero-Tank games: {tvt_zero_tank_cnt} of {tvt_total_n}).</p>
    </div>
  </details>
"""


def render_matchup_evaluation_section(
    rich: Dict[str, Any],
    section_num: str = "Section 2",
) -> str:
    mus = rich["matchups"]
    cb = rich.get("current_build") or {}
    has_cb = bool(cb.get("by_matchup"))
    b_tag = cb.get("build_tag") or cb.get("loop_num")
    build_lbl = f"Build {b_tag}" if b_tag else "Current Build"
    if cb.get("is_shipped") and cb.get("ship_num"):
        rel_lbl = f"Release #{cb['ship_num']} ({build_lbl})"
        rel_in_parens = f"Release #{cb['ship_num']}, {build_lbl}"
    elif b_tag:
        rel_lbl = f"{build_lbl} (Latest Benchmark)"
        rel_in_parens = f"{build_lbl}, Latest Benchmark"
    else:
        rel_lbl = build_lbl
        rel_in_parens = build_lbl

    # Enrich matchup entries with current-build stats so charts, tables, and JS drawer reflect current state
    mu_list: List[Dict[str, Any]] = []
    for mu in MATCHUPS_ORDER:
        if mu not in mus:
            continue
        ent = dict(mus[mu])
        if has_cb and mu in cb["by_matchup"]:
            ent["cur_local"] = cb["by_matchup"][mu]["ext"]
            ent["cur_core"] = cb["by_matchup"][mu]["core"]
        else:
            ent["cur_local"] = ent["local"]
            ent["cur_core"] = ent["core"]
        ent["build_label"] = build_lbl
        mu_list.append(ent)

    mu_json = json.dumps(mu_list, ensure_ascii=False).replace("</", "<\\/")

    def _fmt_wlt(d: Dict[str, Any]) -> str:
        return f"{d.get('w', 0)}–{d.get('l', 0)}" + (f"–{d['t']}" if d.get("t") else "")

    # Headline cohort strip for current shipped build
    cohort_strip_html = ""
    if has_cb:
        co = cb["cohorts"]
        def _min_tag(c_obj: Dict[str, Any]) -> str:
            return f" · {c_obj['min_ratio']:.2f}× min" if c_obj.get("min_ratio") is not None else ""
        chips = [
            ("All 84 Local", f"{_fmt_wlt(co['all'])}", f"{co['all']['wr']:.1f}% wins · {co['all']['tr']:.2f}× trade{_min_tag(co['all'])}"),
            ("78 External", f"{_fmt_wlt(co['ext'])}", f"{co['ext']['wr']:.1f}% wins · {co['ext']['tr']:.2f}× trade{_min_tag(co['ext'])}"),
            ("14 Core Bots", f"{_fmt_wlt(co['core'])}", f"{co['core']['wr']:.1f}% wins · {co['core']['tr']:.2f}× trade{_min_tag(co['core'])}"),
            ("12 Held-Out Bots", f"{_fmt_wlt(co['unseen'])}", f"{co['unseen']['wr']:.1f}% wins · {co['unseen']['tr']:.2f}× trade{_min_tag(co['unseen'])}"),
        ]
        if co["h2h"]["n"]:
            chips.append(
                (f"Head-to-Head ({co['h2h']['n']}g)", f"{_fmt_wlt(co['h2h'])}", f"{co['h2h']['wr']:.1f}% vs. prev live · {co['h2h']['tr']:.2f}×")
            )
        elif (co.get("selfplay") or {}).get("n"):
            sp = co["selfplay"]
            chips.append(
                (f"Self-Play ({sp['n']}g)", f"{_fmt_wlt(sp)}", f"{sp['wr']:.1f}% vs. self · {sp['tr']:.2f}×")
            )
        cohort_strip_html = (
            '<div class="cohort-strip">'
            + "".join(
                f'<div class="cohort-card"><span class="m-lbl">{html.escape(k)}</span>'
                f'<strong>{html.escape(v)}</strong><span class="cohort-sub">{html.escape(sub)}</span></div>'
                for k, v, sub in chips
            )
            + "</div>"
        )

    # Per-race current table (Protoss / Terran / Zerg)
    race_table_html = ""
    if has_cb and cb.get("by_race"):
        r_rows = []
        for rname in ("Protoss", "Terran", "Zerg"):
            rd = cb["by_race"][rname]
            ex, cr, un = rd["ext"], rd["core"], rd["unseen"]
            min_cell = f'{ex["min_ratio"]:.2f}×' if ex.get("min_ratio") is not None else "--"
            r_rows.append(
                f"<tr>"
                f"<td><strong>{rname}</strong></td>"
                f'<td style="text-align:right"><strong>{ex["wr"]:.1f}%</strong> <span class="t-muted">({_fmt_wlt(ex)})</span></td>'
                f'<td style="text-align:right">{ex["nl"]:.1f}%</td>'
                f'<td style="text-align:right">{cr["wr"]:.1f}% <span class="t-muted">({_fmt_wlt(cr)})</span></td>'
                f'<td style="text-align:right">{un["wr"]:.1f}% <span class="t-muted">({_fmt_wlt(un)})</span></td>'
                f'<td style="text-align:right">{ex["tr"]:.2f}×</td>'
                f'<td style="text-align:right">{min_cell}</td>'
                f'<td style="text-align:right">{ex["sb"]:.1f}%</td>'
                f"</tr>"
            )
        ext_ov = cb["cohorts"]["ext"]
        sec_bits = []
        if ext_ov.get("gas_ratio") is not None:
            sec_bits.append(f"Gas collected {ext_ov['gas_ratio']:.2f}× ({ext_ov.get('our_gas_avg', 0):,.0f} vs. {ext_ov.get('opp_gas_avg', 0):,.0f} avg)")
        if ext_ov.get("our_upg_lv") is not None and ext_ov.get("opp_upg_lv") is not None:
            sec_bits.append(f"combat upgrade levels {ext_ov['our_upg_lv']:.1f} vs. opponent {ext_ov['opp_upg_lv']:.1f}")
        if ext_ov.get("t1_pct") is not None:
            sec_bits.append(f"unit tier mix {ext_ov['t1_pct']:.0f}% T1 / {ext_ov['t2_pct']:.0f}% T2 / {ext_ov['t3_pct']:.0f}% T3")
        sec_diag_p = (
            f'\n  <p class="t-muted" style="margin:-0.9rem 0 1.2rem;font-size:0.84rem;">'
            f'Secondary diagnostics across all 78 external games: {"; ".join(sec_bits)}.</p>'
            if sec_bits
            else ""
        )
        race_table_html = f"""
  <h3 style="margin:1.25rem 0 0.45rem;font-size:1.08rem;">Current Build by Race ({html.escape(rel_in_parens)})</h3>
  <div class="table-wrap table-compact" style="margin-bottom:1.35rem;">
    <table>
      <thead>
        <tr>
          <th>Race</th>
          <th style="text-align:right">All 26 External</th>
          <th style="text-align:right">Win + Tie %</th>
          <th style="text-align:right">14 Core Bots</th>
          <th style="text-align:right">12 Held-Out Bots</th>
          <th style="text-align:right">Trade Ratio</th>
          <th style="text-align:right">Minerals Collected</th>
          <th style="text-align:right">Supply-Blocked</th>
        </tr>
      </thead>
      <tbody>{"".join(r_rows)}</tbody>
    </table>
  </div>{sec_diag_p}
"""

    # Interactive 9-matchup pills (show current local WR% right on each pill!)
    mu_pills = []
    base_pills = []
    for idx, m in enumerate(mu_list):
        cls = "cat-pill is-active" if idx == 0 else "cat-pill"
        c_wr = (m.get("cur_local") or {}).get("wr", 0.0)
        mu_pills.append(
            f'<button type="button" class="{cls}" data-mu-idx="{idx}">{m["matchup"]} · {c_wr:.0f}%</button>'
        )
        base_pills.append(
            f'<button type="button" class="{cls}" data-base-idx="{idx}">{m["matchup"]}</button>'
        )

    # Complete 9-matchup Win-Rate & Discrepancy summary table
    wr_svg = _render_matchup_wr_svg(mu_list, build_label=build_lbl)
    wr_rows = []
    for m in mu_list:
        prd = m.get("prod") or {}
        cor = m.get("cur_core") or {}
        loc = m.get("cur_local") or {}
        p_rec = _fmt_wlt(prd)
        c_rec = _fmt_wlt(cor)
        l_rec = _fmt_wlt(loc)
        l_wr = float(loc.get("wr") or 0.0)
        wr_cls = ' style="color:#1F6E43;font-weight:700;"' if l_wr >= 50.0 else (' style="color:#B43C2E;font-weight:700;"' if l_wr <= 25.0 else ' style="font-weight:600;"')
        wr_rows.append(
            f"<tr>"
            f"<td><strong>{m['matchup']}</strong></td>"
            f'<td style="text-align:right"><span{wr_cls}>{l_wr:.1f}%</span> <span class="t-muted">({l_rec})</span></td>'
            f'<td style="text-align:right">{float(loc.get("nl") or 0.0):.1f}%</td>'
            f'<td style="text-align:right">{float(cor.get("wr") or 0.0):.1f}% <span class="t-muted">({c_rec})</span></td>'
            f'<td style="text-align:right">{float(loc.get("tr") or 0.0):.2f}×</td>'
            f'<td style="text-align:right">{float(loc.get("sb") or 0.0):.1f}%</td>'
            f'<td style="text-align:right">{float(prd.get("wr") or 0.0):.1f}% <span class="t-muted">({p_rec})</span></td>'
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
        loc = first["cur_local"]
        cor = first.get("cur_core") or {}
        prd = first["prod"]
        prd_s = f"{prd.get('wr',0):.1f}% · {_fmt_wlt(prd)} ({prd['tr']:.2f}×)" if prd["n"] else "—"
        cor_s = f"{cor.get('wr',0):.1f}% · {_fmt_wlt(cor)} ({cor.get('tr',0):.2f}×)" if cor.get("n") else "—"
        loc_s = f"{loc.get('wr',0):.1f}% · {_fmt_wlt(loc)} ({loc['tr']:.2f}×)" if loc["n"] else "—"
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
        <div class="m-chip"><span class="m-lbl">{html.escape(build_lbl)} · All 26</span><strong>{loc_s}</strong></div>
        <div class="m-chip"><span class="m-lbl">{html.escape(build_lbl)} · 14 Core</span><strong>{cor_s}</strong></div>
        <div class="m-chip"><span class="m-lbl">Recent Live Ladder (v1)</span><strong>{prd_s}</strong></div>
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
            <figcaption>Grandmaster reference maps alongside Mothman's 4:10 baseline layouts. In our 4:10 base-layout audit (Release #14, Build 62C), Protoss Pylon clumping held at 0.0% (15.1-tile average spacing, 92.0% natural-base power placement, and zero fragile tech structures in walls).</figcaption>
          </figure>
        </div>
        <div class="pro-bp-slot" data-pro-bp-panel="Terran" style="display:none;">
          <figure class="clip-figure" style="margin:0;">
            <img class="clip-img base-layout-photo" src="./media/pro_vs_mothman_terran.png"
                 alt="Terran base layouts at 4:10 comparing Grandmaster pros and Mothman"
                 data-lightbox-src="./media/pro_vs_mothman_terran.png"
                 data-lightbox-alt="Terran base layouts at 4:10 comparing Grandmaster pros and Mothman" />
            <figcaption>Mothman's Depot-Barracks-Depot main ramp wall forms in 98–100% of games, matching pro ramp timing, and second-base Supply Depot coverage reached 86.4% in our post-redesign audit.</figcaption>
          </figure>
        </div>
        <div class="pro-bp-slot" data-pro-bp-panel="Zerg" style="display:none;">
          <figure class="clip-figure" style="margin:0;">
            <img class="clip-img base-layout-photo" src="./media/pro_vs_mothman_zerg.png"
                 alt="Zerg base layouts at 4:10 comparing Grandmaster pros and Mothman"
                 data-lightbox-src="./media/pro_vs_mothman_zerg.png"
                 data-lightbox-alt="Zerg base layouts at 4:10 comparing Grandmaster pros and Mothman" />
            <figcaption>Serral tucks his Spawning Pool behind the Main Hatchery and puts Spore Crawlers inside each mineral line; Zerg natural choke walling and mineral-line Spore placement remain active layout targets.</figcaption>
          </figure>
        </div>
      </div>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Matchup <span class="t-muted">(Pro / Pre-Fix)</span></th>
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
      <p class="table-note" style="margin-top:0.45rem;">Reference audit table compares Grandmaster Pros against our pre-redesign 4:10 baseline (spacing in tiles, walls and power in % of games, static defense in average structures). After the layout redesign, Release #10 (Build 57) cut Protoss Pylon clumping to 3.9% (15.3-tile spacing) with 93.3% natural-base supply placement (100.0% Protoss, 86.4% Terran), and Releases #11 through #14 held 0.0% Pylon clumping.</p>
    </div>
"""

    # Build Combat Positioning & Concave vs. Pro table (Section 5, normalized {our_label, meta, by_race})
    pcp = rich.get("pro_combat_positioning") or {}
    pcp_by_race = pcp.get("by_race") or {}
    pcp_meta = pcp.get("meta") or {}
    pcp_our_lbl = str(pcp.get("our_label") or build_lbl)
    pro_combat_section = ""
    if pcp_by_race:
        def _fmt_pcp_pct(v: Any) -> str:
            return "—" if v is None else f"{float(v):.1f}%"

        def _fmt_pcp_tile(v: Any) -> str:
            return "—" if v is None else f"{float(v):.2f}t"

        def _fmt_pcp_signed(v: Any) -> str:
            return "—" if v is None else f"{float(v):+.2f}"

        pcp_rows = []
        pro_large_vals: List[float] = []
        our_large_vals: List[float] = []
        our_wrap_bits: List[str] = []
        for rname in ("Protoss", "Terran", "Zerg"):
            rd = pcp_by_race.get(rname) or {}
            pr = rd.get("pro") or {}
            mm = rd.get("mothman") or {}
            if not pr or not mm:
                continue
            if pr.get("large_battle_pct") is not None:
                pro_large_vals.append(float(pr["large_battle_pct"]))
            if mm.get("large_battle_pct") is not None:
                our_large_vals.append(float(mm["large_battle_pct"]))
            if mm.get("concave_wrap_score") is not None and pr.get("concave_wrap_score") is not None:
                our_wrap_bits.append(
                    f"{rname} {float(pr['concave_wrap_score']):+.2f} vs. {float(mm['concave_wrap_score']):+.2f}"
                )
            p_nb = int(pr.get("n_battles", 0) or 0)
            m_nb = int(mm.get("n_battles", 0) or 0)
            pcp_rows.append(
                f"<tr>"
                f"<td><strong>{rname}</strong> <span class=\"t-muted\">({p_nb:,} / {m_nb:,})</span></td>"
                f'<td style="text-align:right">{_fmt_pcp_pct(pr.get("large_battle_pct"))} / <strong>{_fmt_pcp_pct(mm.get("large_battle_pct"))}</strong></td>'
                f'<td style="text-align:right">{_fmt_pcp_tile(pr.get("frontage_width_t"))} / {_fmt_pcp_tile(mm.get("frontage_width_t"))}</td>'
                f'<td style="text-align:right">{_fmt_pcp_signed(pr.get("concave_wrap_score"))} / <strong>{_fmt_pcp_signed(mm.get("concave_wrap_score"))}</strong></td>'
                f'<td style="text-align:right">{_fmt_pcp_pct(pr.get("role_inversion_pct"))} / {_fmt_pcp_pct(mm.get("role_inversion_pct"))}</td>'
                f'<td style="text-align:right">{_fmt_pcp_pct(pr.get("in_range_pct"))} / {_fmt_pcp_pct(mm.get("in_range_pct"))}</td>'
                f'<td style="text-align:right">{_fmt_pcp_pct(pr.get("fighting_uphill_pct"))} / {_fmt_pcp_pct(mm.get("fighting_uphill_pct"))}</td>'
                f'<td style="text-align:right">{_fmt_pcp_pct(pr.get("splash_clump_pct"))} / {_fmt_pcp_pct(mm.get("splash_clump_pct"))}</td>'
                f"</tr>"
            )
        if pcp_rows:
            pro_g = int(pcp_meta.get("pro_games", 371) or 371)
            pro_b = int(pcp_meta.get("pro_battles", 2513) or 2513)
            pcp_our_games = int(pcp_meta.get("our_games", 0) or 0)
            pcp_our_battles = int(pcp_meta.get("our_battles", 0) or 0)
            summary_bits = []
            if pro_large_vals and our_large_vals:
                summary_bits.append(
                    f"Grandmaster armies engage in packs of 10 or more units in {min(pro_large_vals):.0f}% to {max(pro_large_vals):.0f}% "
                    f"of battles versus {min(our_large_vals):.0f}% to {max(our_large_vals):.0f}% on {html.escape(pcp_our_lbl)}"
                )
            if our_wrap_bits:
                summary_bits.append(f"concave wrap (Pro vs. {html.escape(pcp_our_lbl)}) sits at {', '.join(our_wrap_bits)}")
            summary_tail = ("; ".join(summary_bits) + ".") if summary_bits else ""
            pro_combat_section = f"""
  <div class="eval-subsection" id="combat-positioning">
    <h3>2.2 Combat Positioning and Concaves vs. Pros</h3>
    <p class="prose-tight">
      Battle geometry measured across {pro_g:,} Grandmaster replays ({pro_b:,} battles) compared against {pcp_our_games} {html.escape(pcp_our_lbl)} local games ({pcp_our_battles:,} battles).
      {summary_tail}
    </p>
    <div class="table-wrap table-compact">
      <table>
        <thead>
          <tr>
            <th>Race <span class="t-muted">(Pro / {html.escape(pcp_our_lbl)})</span></th>
            <th style="text-align:right">Pack &ge;10</th>
            <th style="text-align:right">Frontage</th>
            <th style="text-align:right">Concave</th>
            <th style="text-align:right">Role Inv.</th>
            <th style="text-align:right">In-Range</th>
            <th style="text-align:right">Uphill</th>
            <th style="text-align:right">2t Clump</th>
          </tr>
        </thead>
        <tbody>{"".join(pcp_rows)}</tbody>
      </table>
    </div>
    <p class="table-note" style="margin-top:0.45rem;">
      Cells show Pro / {html.escape(pcp_our_lbl)}. Frontage is firing-line width in tiles; positive concave wrap means flanks arc forward around the enemy;
      role inversion counts battles where rear ranged units sit closer to the enemy than frontline melee; In-Range is the share of combat units within weapon range;
      Uphill is the share of attacks fired from low ground; 2t Clump is the share of units standing within two tiles of an ally during splash fights (— marks zero splash-weapon battles in sample).
    </p>
  </div>
"""

    # Build Section 6 Army-Group Positioning, Rotation, Regroup & Multiprong vs. Pro table
    pag = rich.get("pro_army_group_positioning") or {}
    pag_by_race = pag.get("by_race") or {}
    pag_meta = pag.get("meta") or {}
    pag_our_lbl = str(pag.get("our_label") or build_lbl)
    pro_army_group_section = ""
    our_rot_vals: List[float] = []
    pro_rot_vals: List[float] = []
    if pag_by_race:
        def _fmt_ag_pct(v: Any) -> str:
            return "—" if v is None else f"{float(v):.1f}%"

        def _fmt_ag_num(v: Any) -> str:
            return "—" if v is None else f"{float(v):.2f}"

        ag_rows = []
        our_reg_vals: List[float] = []
        pro_reg_vals: List[float] = []
        for rname in ("Protoss", "Terran", "Zerg"):
            rd = pag_by_race.get(rname) or {}
            pr = rd.get("pro") or {}
            mm = rd.get("mothman") or {}
            if not pr or not mm:
                continue
            if pr.get("rotations_per_game") is not None:
                pro_rot_vals.append(float(pr["rotations_per_game"]))
            if mm.get("rotations_per_game") is not None:
                our_rot_vals.append(float(mm["rotations_per_game"]))
            if pr.get("disengage_and_regroup_pct") is not None:
                pro_reg_vals.append(float(pr["disengage_and_regroup_pct"]))
            if mm.get("disengage_and_regroup_pct") is not None:
                our_reg_vals.append(float(mm["disengage_and_regroup_pct"]))
            p_ng = int(pr.get("n_games", 0) or 0)
            m_ng = int(mm.get("n_games", 0) or 0)
            ag_rows.append(
                f"<tr>"
                f"<td><strong>{rname}</strong> <span class=\"t-muted\">({p_ng:,} / {m_ng:,})</span></td>"
                f'<td style="text-align:right">{_fmt_ag_pct(pr.get("multiprong_attack_pct"))} / {_fmt_ag_pct(mm.get("multiprong_attack_pct"))}</td>'
                f'<td style="text-align:right">{_fmt_ag_pct(pr.get("synchronized_harass_pct"))} / {_fmt_ag_pct(mm.get("synchronized_harass_pct"))}</td>'
                f'<td style="text-align:right">{_fmt_ag_num(pr.get("harass_events_per_10m"))} / {_fmt_ag_num(mm.get("harass_events_per_10m"))}</td>'
                f'<td style="text-align:right">{_fmt_ag_pct(pr.get("reinforce_linked_pct"))} / {_fmt_ag_pct(mm.get("reinforce_linked_pct"))}</td>'
                f'<td style="text-align:right">{_fmt_ag_pct(pr.get("solo_trickle_death_pct"))} / <strong>{_fmt_ag_pct(mm.get("solo_trickle_death_pct"))}</strong></td>'
                f'<td style="text-align:right">{_fmt_ag_pct(pr.get("disengage_and_regroup_pct"))} / {_fmt_ag_pct(mm.get("disengage_and_regroup_pct"))}</td>'
                f'<td style="text-align:right">{_fmt_ag_pct(pr.get("fight_to_annihilation_pct"))} / {_fmt_ag_pct(mm.get("fight_to_annihilation_pct"))}</td>'
                f'<td style="text-align:right">{_fmt_ag_num(pr.get("rotations_per_game"))} / <strong>{_fmt_ag_num(mm.get("rotations_per_game"))}</strong></td>'
                f"</tr>"
            )
        if ag_rows:
            ag_pro_g = int(pag_meta.get("pro_games", 371) or 371)
            ag_our_g = int(pag_meta.get("our_games", 0) or 0)
            ag_summary = ""
            if pro_rot_vals and our_rot_vals and pro_reg_vals and our_reg_vals:
                ag_summary = (
                    f" Pros rotate between defended bases {min(pro_rot_vals):.2f} to {max(pro_rot_vals):.2f} times per game "
                    f"(vs. {min(our_rot_vals):.2f} to {max(our_rot_vals):.2f} on {html.escape(pag_our_lbl)}) and complete a "
                    f"disengage-and-regroup cycle in {min(pro_reg_vals):.1f}% to {max(pro_reg_vals):.1f}% of fights "
                    f"(vs. {min(our_reg_vals):.1f}% to {max(our_reg_vals):.1f}%)."
                )
            pro_army_group_section = f"""
  <div class="eval-subsection" id="army-group-positioning">
    <h3>2.3 Army-Group Rotation, Regroup and Multiprong vs. Pros</h3>
    <p class="prose-tight">
      Operational army movement measured across {ag_pro_g:,} Grandmaster replays vs. {ag_our_g} {html.escape(pag_our_lbl)} local games.{ag_summary}
    </p>
    <div class="table-wrap table-compact">
      <table>
        <thead>
          <tr>
            <th>Race <span class="t-muted">(Pro / {html.escape(pag_our_lbl)})</span></th>
            <th style="text-align:right">Multiprong</th>
            <th style="text-align:right">Sync Harass</th>
            <th style="text-align:right">Harass/10m</th>
            <th style="text-align:right">Reinf. Link</th>
            <th style="text-align:right">Trickle</th>
            <th style="text-align:right">Regroup</th>
            <th style="text-align:right">Annihil.</th>
            <th style="text-align:right">Rot./Game</th>
          </tr>
        </thead>
        <tbody>{"".join(ag_rows)}</tbody>
      </table>
    </div>
    <p class="table-note" style="margin-top:0.45rem;">
      Cells show Pro / {html.escape(pag_our_lbl)}. Multiprong counts offensive windows where two or more squads at least 25 tiles apart pressure separate bases;
      Sync Harass is the share of drops and worker raids timed alongside a main-army push; Reinf. Link is the share of new units merging into an active squad rather than fighting solo;
      Trickle counts mid-game combat deaths with two or fewer allies within 10 tiles; Annihil. is the share of fights ending in a near-total wipeout;
      Rot./Game counts intentional switches away from a defended enemy base to an alternate live base.
    </p>
  </div>
"""

    # Build 2.4 Performance Curves & Timings vs. Opponents & Pros (All 8 Interactive Charts)
    pro_curves = rich.get("pro_curves") or {}
    pro_curves_section = ""
    pro_curves_json = "null"
    if pro_curves.get("curves"):
        pro_curves_json = json.dumps(pro_curves, ensure_ascii=False).replace("</", "<\\/")
        cv_coh = pro_curves.get("cohorts") or {}
        cv_m_g = int((cv_coh.get("mothman") or {}).get("games", 0) or 0)
        cv_o_g = int((cv_coh.get("opponents") or {}).get("games", 0) or 0)
        cv_p_g = int((cv_coh.get("pros") or {}).get("games", 0) or 0)
        cv_p_ge = int((cv_coh.get("pros") or {}).get("ge_games", cv_p_g) or cv_p_g)
        cv_s_all = (pro_curves.get("summary") or {}).get("all") or {}
        apm_m = (cv_s_all.get("apm") or {}).get("mothman", {}).get("med")
        apm_o = (cv_s_all.get("apm") or {}).get("opponents", {}).get("med")
        apm_p = (cv_s_all.get("apm") or {}).get("pros", {}).get("med")
        epm_m = (cv_s_all.get("epm") or {}).get("mothman", {}).get("med")
        epm_p = (cv_s_all.get("epm") or {}).get("pros", {}).get("med")
        spm_m = (cv_s_all.get("spm") or {}).get("mothman", {}).get("med")
        spm_p = (cv_s_all.get("spm") or {}).get("pros", {}).get("med")
        apm_note = (
            f" Unthrottled local opponent bots emit {apm_o:,.0f} median APM vs. {apm_m:.0f} for Mothman and {apm_p:.0f} for Pros, "
            f"so APM and EPM default to a log scale with a one-click Linear toggle focused on Mothman vs. Pros."
            if (apm_m is not None and apm_o is not None and apm_p is not None)
            else ""
        )
        run_id_low = str(pro_curves.get("run_id") or "").lower()
        if epm_m is not None and epm_p is not None and spm_m is not None and spm_p is not None and "iter66_" in run_id_low:
            col_gas_m = (cv_s_all.get("collection_gas") or {}).get("mothman", {}).get("med")
            col_gas_str = f"{col_gas_m:,.1f}" if col_gas_m is not None else "234.5"
            apm_m_str = f"{apm_m:.1f}" if apm_m is not None else "295.8"
            epm_rel = "topped" if epm_m >= epm_p else "tracked right near"
            r_mech_para = (
                f'\n    <p class="prose-tight">'
                f"On {html.escape(rel_lbl)}, held-out Unseen-12 play set a new all-time high at 11–22–3 (30.6% wins, "
                f"38.9% win+tie, 12–24 state-adjudicated, 34.5/100 state score, 0.84× minerals, and 0.92× gas), while "
                f"overall external mineral collection hit a new record at 0.82× across 78 external games (28–44–6 raw, "
                f"29–49 state-adjudicated, 37.4/100 state score, 0.73× trade). Full 84-match validation finished 32–46–6 "
                f"(33–51 state-adjudicated, 39.5/100 state score, 0.78× trade), self-play reached 4–2 at a record 1.29× "
                f"trade, and the 18-match external canary went 14–3–1 (77.8% wins, 81.5/100 state score, 1.79× trade). "
                f"All three races cleared a 34.6% external win rate (Protoss 10–15–1 at 38.5% with 42.3/100 state score "
                f"and 0.82× trade, Terran 9–15–2 at 42.3% win+tie and 0.83× trade, Zerg 9–14–3 at 46.2% win+tie and 0.87× "
                f"minerals). Median EPM {epm_rel} the Grandmaster benchmark ({epm_m:.1f} vs. Pro {epm_p:.1f}), median SPM "
                f"held at {spm_m:.1f} (+{spm_m - spm_p:.1f} above Pro {spm_p:.1f}), median APM held at {apm_m_str}, and "
                f"median gas income climbed to {col_gas_str} per minute with zero crashes and zero rejected commands "
                f"(9.69 ms average step time in the 4–0 standalone BotZip smoke pass at 8.09× trade)."
                f'</p>\n    <p class="prose-tight">'
                f"Worker rally assignment, emergency cloak detection, and Supply Depot raise/lower control now run directly "
                f"inside the core planner and tactics modules with zero retroactive transport-layer overrides. Protoss "
                f"warped in a record 64 forward Chargelots via Warp Prism across the 84-match suite (plus 41 in the "
                f"18-match canary pass, without rapid mode-toggle loops), built a record 35 Colossi, and lifted Nexus Energy "
                f"Recharge adoption to 73.1%. Terran fired a record 209 Scanner Sweeps and 10 Orbital Command Supply Drops "
                f"while holding cloaked-unit losses to 1 (all-time low) and drip-feed collapses to 22 (tied for all-time "
                f"low). Zerg lifted external tumor-to-tumor Creep spread adoption to 84.6% (123 spreads, ahead of Pro "
                f"Grandmaster 80.2%) and matched Grandmaster peaceful Queen energy splits (74.3% Inject, 24.9% Creep Tumor, "
                f"and 0.8% Transfuse vs. Pro 73.4%, 25.7%, and 0.9%). Full end-to-end build and test cycle time dropped to "
                f"83.5 minutes (down from a 258.3-minute historical average per release), with 2.9% benchmark tail wait "
                f"under longest-first scheduling and zero timeouts."
                f"</p>"
            )
        elif epm_m is not None and epm_p is not None and spm_m is not None and spm_p is not None and "65h" in run_id_low:
            col_gas_m = (cv_s_all.get("collection_gas") or {}).get("mothman", {}).get("med")
            col_gas_str = f"{col_gas_m:,.1f}" if col_gas_m is not None else "221.3"
            apm_m_str = f"{apm_m:.1f}" if apm_m is not None else "290.2"
            epm_rel = "topped" if epm_m >= epm_p else "tracked right near"
            r_mech_para = (
                f'\n    <p class="prose-tight">'
                f"On {html.escape(rel_lbl)}, full 84-match local validation reached 33–43–8 (48.8% win+tie, tied for our "
                f"all-time win high with four fewer losses and a 40.8/100 end-of-game state score). Core 14-opponent play set "
                f"a campaign record at 21–19–2 (50.0% win rate, 54.8% win+tie, 1.03× trade, 51.0/100 state score, with 3–0 "
                f"sweeps of puck, CryptBotRevival, and Chance), our original 12-bot baseline set hit 24–6–6 (66.7% wins, "
                f"83.3% win+tie), self-play reached 5–1–0 (83.3%, 1.27× trade), and all three races cleared a 34.6% external "
                f"win rate (Protoss 10–15–1 at 38.5%, Terran 9–13–4 at 50.0% win+tie, Zerg 9–14–3 at 46.2% win+tie). Median "
                f"EPM {epm_rel} the Grandmaster benchmark ({epm_m:.1f} vs. Pro {epm_p:.1f}), median SPM held at {spm_m:.1f} "
                f"(+{spm_m - spm_p:.1f} above Pro {spm_p:.1f}), median APM held at {apm_m_str}, and median gas income sat at "
                f"{col_gas_str} per minute with zero crashes and zero rejected commands (10.04 ms average step time in the "
                f"4–0 standalone BotZip smoke pass at 10.79× trade)."
                f'</p>\n    <p class="prose-tight">'
                f"A dedicated multi-prong army coordinator now routes forward squads through the resource-budget arbiter, "
                f"paired with unit-order tracking fixes so staging groups keep their shape under load. Protoss achieved "
                f"its first sustained Warp Prism forward Chargelot warp-ins (57 forward Zealots across the 84-match suite "
                f"plus 74 in the Protoss validation pass, without rapid mode-toggle loops), cast 29 Force Fields across 13 "
                f"games, and eliminated PvP natural-expansion delays completely (0 occurrences). Terran produced 156 Siege "
                f"Tanks across the 84 matches, raised third Command Center adoption from 19% to 31%, used Orbital Command "
                f"Supply Drop live (2 casts), and held external supply block to 1.9%. Zerg added base-site clearance checks "
                f"so Creep Tumors never block future expansions while sustaining 76.9% external tumor-to-tumor spread "
                f"adoption (193 external spreads and 442 total Creep Tumors) alongside 79.7% Inject and 20.3% Creep Tumor "
                f"peaceful Queen energy allocation. Local benchmark tooling also added parallel post-match scoring, "
                f"longest-first match scheduling, and a temporary 25-minute local match cap with end-of-game state scoring "
                f"to speed up development cycles without altering AI Arena rules."
                f"</p>"
            )
        elif epm_m is not None and epm_p is not None and spm_m is not None and spm_p is not None and "64b" in run_id_low:
            col_gas_m = (cv_s_all.get("collection_gas") or {}).get("mothman", {}).get("med")
            col_gas_str = f"{col_gas_m:,.1f}" if col_gas_m is not None else "242.9"
            apm_m_str = f"{apm_m:.1f}" if apm_m is not None else "288.1"
            epm_rel = "topped" if epm_m >= epm_p else "tracked right near"
            r_mech_para = (
                f'\n    <p class="prose-tight">'
                f"On {html.escape(rel_lbl)}, external trade efficiency hit a new all-time high of 0.81× across 78 external games "
                f"(29–45–4, +0.15× over Release #15), held-out Unseen-12 trade climbed to a new record of 0.72× (10–24–2, tied for "
                f"our held-out win high), and all three races cleared a 33% external win rate (Protoss 42.3%, Terran 34.6%, Zerg "
                f"34.6% with 50.0% win+tie). Across all 84 local matches, average peak army value (3,757), minerals collected ratio "
                f"(0.85×), gas collected ratio (0.97×), and combat upgrade levels (2.3 vs. opponent 1.8) all reached campaign highs. "
                f"Median gas income rose to {col_gas_str} per minute, median EPM {epm_rel} the Grandmaster benchmark ({epm_m:.1f} "
                f"vs. Pro {epm_p:.1f}), median SPM held at {spm_m:.1f} (+{spm_m - spm_p:.1f} above Pro {spm_p:.1f}), median APM "
                f"held at {apm_m_str}, and average step time improved to 12.58 ms (zero crashes and zero rejected commands) with "
                f"the new resource-budget arbiter and stricter module-layer checks active."
                f'</p>\n    <p class="prose-tight">'
                f"Fixing Zerg Creep Tumor spread cooldown and placement queries lifted tumor-to-tumor spread adoption from 3.8% to "
                f"88.5% across external games (151 spreads externally and 187 across all 84), above the Pro Grandmaster rate of "
                f"80.2%, while peaceful Queen energy allocation (74.4% Inject, 24.4% Creep Tumor) matched Grandmaster ratios "
                f"(73.4% and 25.7%). Protoss shifted Chrono Boost onto Tech Upgrades at minute 4 (11.9% to 49.9% overall), "
                f"researched +1 Ground Weapons first in all 18 Forge games (8:05 median vs. Pro 8:07), reached four or more bases in "
                f"50.0% of games past minute 10 (up from 28.6%), and raised Nexus Energy Recharge to 65.4% adoption (0.250 casts per "
                f"minute during minutes 4 to 8, at 99.2% of Pro pace). Terran cut mid-game drip-feed collapses by 69.2% (13 down to "
                f"4), lifted trade ratio +0.48× to 0.98× (tied for its external high), raised outnumbered disengage rate from 1.7% to "
                f"8.9% (97% of Pro 9.2%), and trimmed Medivac army share from 37.2% to 20.1% in TvP. Concave wrap improved across "
                f"all three races (Protoss +1.25, Zerg +0.08, and Terran from -0.46 to -0.03), alongside 3–0 sweeps of onlyfans and "
                f"Creepy_strategies and our first win over QueenBot."
                f"</p>"
            )
        elif epm_m is not None and epm_p is not None and spm_m is not None and spm_p is not None and "63b" in run_id_low:
            col_min_m = (cv_s_all.get("collection_minerals") or {}).get("mothman", {}).get("med")
            col_min_str = f"{col_min_m:,.1f}" if col_min_m is not None else "1,101.8"
            apm_m_str = f"{apm_m:.1f}" if apm_m is not None else "289.1"
            epm_rel = "topped" if epm_m >= epm_p else "tracked right near"
            r_mech_para = (
                f'\n    <p class="prose-tight">'
                f"On {html.escape(rel_lbl)}, Protoss set a new all-time local external record at 12–14 (46.2% wins, 0.95× trade, "
                f"+3 wins over Release #14). Fixing Nexus Energy Recharge floor rounding and wire cooldown tracking raised live casts "
                f"from 1 in 1 game to 33 across 17 games (53.8% external adoption, with 4–8 minute pace at 70% of Pro Grandmasters), "
                f"sped up Blink by 90 seconds (9:08 to 7:38), and cut outnumbered engagements under 0.75× force ratio from 59.7% to "
                f"35.0% (ahead of the Pro 37.4% benchmark). Across all three races, median mineral income reached an all-time high of "
                f"{col_min_str} per minute, median EPM {epm_rel} the Grandmaster benchmark ({epm_m:.1f} vs. Pro {epm_p:.1f}), median "
                f"SPM held at {spm_m:.1f} (+4.1 above Pro {spm_p:.1f}), median APM held at {apm_m_str}, supply-blocked time fell to "
                f"a campaign-low 3.6% across 84 matches, worker-rally command churn dropped 44.8%, and action-cap drops fell 17.5%."
                f'</p>\n    <p class="prose-tight">'
                f"Zerg improved to 9–15–2 (+1 win over Release #14), raised its minerals-collected ratio from 0.76× to 0.94×, hit "
                f"100% four-base reach in games past minute 14 (above Pro 98.2%), nearly tripled Queen Creep Tumor placements "
                f"(67 to 178 casts), and boosted Ravager Corrosive Bile casts by 39% (796 to 1,108). Local validation recorded our "
                f"first 3–0 sweep of zig-reapers (4.32× trade), our first win over mini-puck, and zero crashes or rejected wire "
                f"commands across 96 games. Terran recovered its opening economy (38.0 median workers at minute 6, 2.0% supply-blocked "
                f"time, and 0.75 early Bunkers before minute 4 vs. 0.82 on Release #14), though mid-game reinforcement trickle and two "
                f"Random Zerg rolls kept Terran at 7–18–1 (0.50× trade)."
                f"</p>"
            )
        elif epm_m is not None and epm_p is not None and spm_m is not None and spm_p is not None and "62c" in run_id_low:
            col_min_m = (cv_s_all.get("collection_minerals") or {}).get("mothman", {}).get("med")
            col_min_str = f"{col_min_m:,.1f}" if col_min_m is not None else "1,082.6"
            apm_m_str = f"{apm_m:.1f}" if apm_m is not None else "292.8"
            epm_rel = "topped" if epm_m >= epm_p else "tracked right near"
            r_mech_para = (
                f'\n    <p class="prose-tight">'
                f"On {html.escape(rel_lbl)}, Mothman completed its three-phase patch-resilience refactor with unified spell execution "
                f"and an extracted macro-ability policy layer (zero crashes and zero rejected commands). Mechanics and mineral "
                f"income hit new all-time highs: median APM reached {apm_m_str} (Zerg rose from 290.9 to 309.6), median EPM "
                f"{epm_rel} the Grandmaster benchmark ({epm_m:.1f} vs. Pro {epm_p:.1f}), median SPM reached {spm_m:.1f} "
                f"(+4.1 above Pro {spm_p:.1f}), and median mineral collection climbed to {col_min_str} per minute. At minute 9, "
                f"mineral income reached 1,959 per minute (224 ahead of local opponents' 1,735; Terran jumped +448 to 1,959), "
                f"gas income reached 627 per minute (ahead of opponents' 571), and army value climbed over Release #13 in both "
                f"minerals (1,525 to 1,638) and gas (575 to 650; Terran up +250 to 800)."
                f'</p>\n    <p class="prose-tight">'
                f"One-base lockouts fell to zero across all 84 local matches. Protoss natural Nexus adoption rose from 88.5% to "
                f"96.2% (1:39), Terran natural Command Center hit 1:34 (11 seconds faster than Pro 1:45) with Stimpack at 5:13 "
                f"and +2/+2 Infantry adoption at 26.9%, and Zerg natural Hatchery hit 0:53 (one second off Pro 0:52) with third "
                f"Hatchery at 4:59 and Baneling Nest at 3:56. Terran matched its external high (11–14–1, 0.94× trade, all Pro "
                f"timing checks clear), Protoss improved to 9–15–2 (PvT 5–3–1 at 1.33× trade), Core-14 held 52.4% win+tie "
                f"(19–20–3), and held-out Unseen-12 recorded our first series win over AxeFighter (2–1) alongside series wins "
                f"over Mulebot (2–1), CryptBot (3–0), and onlyfans (2–1)."
                f"</p>"
            )
        elif epm_m is not None and epm_p is not None and spm_m is not None and spm_p is not None and "61c" in run_id_low:
            r_mech_para = (
                f'\n    <p class="prose-tight">'
                f"On {html.escape(rel_lbl)}, every economy and army curve hit new all-time highs across all three races, "
                f"with effective speed topping the Grandmaster median (median EPM {epm_m:.1f} vs. Pro {epm_p:.1f}; "
                f"median SPM {spm_m:.1f} vs. Pro {spm_p:.1f}). Compared with Release #12 (Build 60B), median army minerals "
                f"climbed 44.4% (from 455 to 657; 2,438 vs. local opponents' 2,313 at minute 12), median army gas climbed 72.2% "
                f"(from 140 to 241; 950 vs. local opponents' 663 at minute 12; Terran up 131.5%), and mineral and gas income "
                f"reached 1,077 and 237 per minute. Parallel per-building upgrade scheduling now beats Grandmaster medians on "
                f"Protoss Warp Gate (4:02 vs. Pro 4:03) and Charge (6:28 vs. 8:01), Terran +2 Infantry Weapons (10:24 vs. 10:52) "
                f"and +1 Vehicle Weapons (8:45 vs. 10:56), and Zerg +1 Missile Attacks (7:16 vs. 7:44)."
                f'</p>\n    <p class="prose-tight">'
                f"Adding 3-race tag-based townhall worker rallies (963 rally orders across 84 games) and midgame harvest "
                f"throttling cut throttled harvest commands by 89.6% (from 70,080 down to 7,296) and economy-tier drops by 90.4% "
                f"(from 58,392 down to 5,630). Local benchmarks reached new highs across all 84 games (34–43–7, 48.8% win+tie, "
                f"0.85× trade), all 78 external games (30–41–7, 47.4% win+tie), the 12 held-out bots (10 wins), Terran "
                f"(11–14–1, 0.98×; 1.08× across all games), Zerg (11–11–4, 57.7% win+tie), and six 3–0 opponent sweeps."
                f"</p>"
            )
        elif epm_m is not None and epm_p is not None and spm_m is not None and spm_p is not None and "60b" in run_id_low:
            col_min_m = (cv_s_all.get("collection_minerals") or {}).get("mothman", {}).get("med")
            col_min_str = f"{col_min_m:,.0f}" if col_min_m is not None else "1,031"
            r_mech_para = (
                f'\n    <p class="prose-tight">'
                f"On {html.escape(rel_lbl)}, the bot now reads live StarCraft II unit costs, supply, abilities, and upgrades directly "
                f"from the game engine at frame 0 (zero rejected commands across all 96 local validation games) and keeps effective speed "
                f"and camera pace right on Grandmaster medians (median EPM {epm_m:.1f} vs. Pro {epm_p:.1f}; median SPM {spm_m:.1f} vs. Pro {spm_p:.1f}). "
                f"Moving routine SCV Repair and building-land orders out of the economy tier cut high-priority economy command drops by 75.0% "
                f"(from 74,602 to 18,634 across 84 games; Terran down 85.3%) and emergency spell drops by 27.4% (Inject Larva cut over 83%, "
                f"Stimpack over 75%). Natural expansions hit Pro marks for Protoss (1:33 vs. Pro 1:29) and Zerg (0:53 vs. Pro 0:52), "
                f"median mineral income rose to {col_min_str} per minute, and Protoss set a new local benchmark high (10–15–1 at 0.90× trade; "
                f"PvP jumped from 1–7 to 4–4)."
                f"</p>"
            )
        elif epm_m is not None and epm_p is not None and spm_m is not None and spm_p is not None and "59c" in run_id_low:
            r_mech_para = (
                f'\n    <p class="prose-tight">'
                f"On {html.escape(rel_lbl)}, effective speed and screen pace match Grandmaster benchmarks closely "
                f"(median EPM {epm_m:.1f} vs. Pro {epm_p:.1f}; median SPM {spm_m:.1f} vs. Pro {spm_p:.1f}). "
                f"Switching from edge scrolling to base-centered camera hotkeys and minimap clicks cut short camera pans "
                f"(under 12 tiles) from 16.9%, 19.4%, and 31.8% down to 0.8%, 0.3%, and 3.1% across early, mid, and late game, "
                f"while crisp camera jumps (18+ tiles) rose to 98.9%, 98.9%, and 91.6%. "
                f"Compared with our previous benchmark (Build 58B), median army gas value climbed 43.4% (from 125 to 180 overall, and from 550 to 800 at minute 12), "
                f"minute-12 mineral income rose 34.2% (from 1,063 to 1,427 per minute), Protoss third Nexus timing sped up by 86 seconds "
                f"(7:23 to 5:57), Terran natural Command Center timing sped up by 19 seconds (1:54 to 1:35, ahead of the Pro 1:45 median), "
                f"and Zerg Spire timing dropped by 110 seconds (10:02 to 8:12)."
                f"</p>"
            )
        else:
            r_mech_para = ""
        pro_curves_section = f"""
  <div class="eval-subsection" id="performance-curves">
    <h3>2.4 Pro Comparison Observatory (22 Graphs)</h3>
    <p class="prose-tight">
      Five interactive views compare {html.escape(build_lbl)} ({cv_m_g} external games) against its exact local opponents ({cv_o_g} games) and
      Grandmaster LotV replays ({cv_p_g} player-games; {cv_p_ge} with full event streams) across Mine × Trade outcomes, combat positioning,
      late-game expansions and production, unit composition and upgrades, and spell and macro-ability efficiency.{apm_note}
    </p>{r_mech_para}
    <div class="interactive-panel site-curves-panel">
      <div id="site-observatory-mount"></div>
    </div>
    <div id="site-curve-tooltip" class="site-curve-tooltip" style="display:none;" role="status" aria-live="polite"></div>
  </div>
"""

    # Current-build Supply-Blocked SVG + dynamic prose
    sb_source = {m["matchup"]: {"local": m["cur_local"]} for m in mu_list}
    sb_svg = render_supply_block_svg(sb_source)
    t_sbs = [sb_source[mu]["local"]["sb"] for mu in ("TvP", "TvT", "TvZ") if mu in sb_source]
    pz_sbs = [sb_source[mu]["local"]["sb"] for mu in ("PvP", "PvT", "PvZ", "ZvP", "ZvT", "ZvZ") if mu in sb_source]
    t_sb_lo, t_sb_hi = (min(t_sbs), max(t_sbs)) if t_sbs else (2.1, 2.7)
    pz_sb_lo, pz_sb_hi = (min(pz_sbs), max(pz_sbs)) if pz_sbs else (4.1, 5.6)

    # Current-build Worker & Army Curves SVGs + dynamic prose
    wk_data = cb["worker_curves"] if (has_cb and cb.get("worker_curves", {}).get("Protoss")) else rich["worker_curves"]
    ar_data = cb["army_curves"] if (has_cb and cb.get("army_curves", {}).get("Protoss")) else rich["army_curves"]
    wk_svgs = {
        r: render_worker_curves_svg(wk_data, rich["pro_worker_curves"], r)
        for r in ("Protoss", "Terran", "Zerg")
    }
    ar_svgs = {
        r: render_army_curves_svg(ar_data, r)
        for r in ("Protoss", "Terran", "Zerg")
    }
    m12_bits = []
    for r in ("Protoss", "Terran", "Zerg"):
        pts = [p for p in ar_data.get(r, []) if p.get("m") == 12]
        if pts:
            m12_bits.append(f"{r} {pts[0]['our']/1000:.1f}k vs. {pts[0]['opp']/1000:.1f}k")
    m12_note = (
        f" At Minute 12 on {build_lbl}, average army value vs. local opponents sits at {', '.join(m12_bits)}."
        if m12_bits
        else ""
    )

    wr_vals = [(m["matchup"], float(m["cur_local"]["wr"]), _fmt_wlt(m["cur_local"])) for m in mu_list if m["cur_local"]["n"]]
    wr_vals_sorted = sorted(wr_vals, key=lambda x: x[1], reverse=True)
    if len(wr_vals_sorted) >= 2:
        hi_mu, hi_wr, hi_rec = wr_vals_sorted[0]
        lo_mu, lo_wr, lo_rec = wr_vals_sorted[-1]
        spread_pp = round(hi_wr - lo_wr)
        spread_sentence = (
            f"Overall averages hide a <strong>{spread_pp}-percentage-point spread across the nine matchups</strong> on {html.escape(rel_lbl)}: "
            f"from <strong>{hi_mu} ({hi_rec}, {hi_wr:.1f}%)</strong> down to <strong>{lo_mu} ({lo_rec}, {lo_wr:.1f}%)</strong>."
        )
    else:
        spread_sentence = f"Per-race and per-matchup local practice results for {html.escape(rel_lbl)}."

    an_cur = cb.get("anomalies") or {}
    weak_str = ", ".join(f"{mu} {wr:.1f}%" for mu, wr, _ in wr_vals_sorted[-3:][::-1]) if len(wr_vals_sorted) >= 3 else "PvP, PvZ, TvZ"
    rot_gap_note = (
        f"Base-switch rotations sit at {min(our_rot_vals):.2f} to {max(our_rot_vals):.2f} per game "
        f"(vs. Pro {min(pro_rot_vals):.2f} to {max(pro_rot_vals):.2f}), while small ground squads still walk into sieged Tank deadzones or kite without firing in tough games."
        if (our_rot_vals and pro_rot_vals)
        else "Small ground squads still walk into sieged Tank deadzones or kite without firing in tough games."
    )

    # Dynamically compute Zerg 4:00 workers, Terran 3rd CC adoption/timing, and overall median gas income
    # so Section 2.6 stays 100% locked to Section 2.4 & Chart 8 on every release.
    z_w4_num = 0.0
    z_w4_den = 0
    for zmu in ("ZvP", "ZvT", "ZvZ"):
        zex = ((cb.get("by_matchup") or {}).get(zmu) or {}).get("ext") or {}
        zn = int(zex.get("n") or 0)
        zw = float(zex.get("w4m") or 0.0)
        if zn > 0 and zw > 0:
            z_w4_num += zw * zn
            z_w4_den += zn
    z_w4_avg = round(z_w4_num / z_w4_den, 1) if z_w4_den > 0 else 29.2
    pro_z_w4 = float(((rich.get("pro_worker_curves") or {}).get("Zerg") or {}).get(4, 35.0) or 35.0)
    z_w4_gap = max(0.0, round(pro_z_w4 - z_w4_avg, 1))

    t3_m_pct, t3_m_t, t3_p_pct, t3_p_t = 27, "7:53", 77, "5:02"
    for t_row in ((pro_curves.get("timings") or {}).get("Terran") or []):
        tlbl = str(t_row.get("label") or "").lower()
        tkey = str(t_row.get("key") or "").lower()
        if "3rd" in tlbl or "third" in tkey or "3rd" in tkey:
            tm_m = t_row.get("mothman") or {}
            tm_p = t_row.get("pros") or {}
            if tm_m.get("adopt_pct") is not None and tm_m.get("med") is not None:
                t3_m_pct = int(round(float(tm_m["adopt_pct"])))
                t3_m_t = str(tm_m.get("med_fmt") or _fmt_mmss(tm_m["med"]))
            if tm_p.get("adopt_pct") is not None and tm_p.get("med") is not None:
                t3_p_pct = int(round(float(tm_p["adopt_pct"])))
                t3_p_t = str(tm_p.get("med_fmt") or _fmt_mmss(tm_p["med"]))
            break

    gas_all = ((pro_curves.get("summary") or {}).get("all") or {}).get("collection_gas") or {}
    gas_m_med = int(float((gas_all.get("mothman") or {}).get("med") or 234) + 0.5)
    gas_p_med = int(float((gas_all.get("pros") or {}).get("med") or 448) + 0.5)

    def _pl(n: int, sing: str, plur: str) -> str:
        return f"{n} {sing if n == 1 else plur}"

    n_zk = int(an_cur.get("zero_kill_collapse_loss", 0) or 0)
    n_clk = int(an_cur.get("cloaked_unit_damage_loss", 0) or 0)
    n_sg = int(an_cur.get("siege_range_zero_dps_loss", 0) or 0)
    n_zf = int(an_cur.get("zero_fire_retreat", 0) or 0)
    n_df = int(an_cur.get("drip_feed_collapse", 0) or 0)
    n_gm = int(an_cur.get("gas_rich_min_starved", 0) or 0)

    open_gaps = [
        f"<strong>Early cheeses, air harass, and stealth defense ({html.escape(weak_str)}):</strong> Across local benchmarks and live Division 6–7 ladder games, early 1-base Marauder rushes, mass Reapers under 4:30, mass Phoenixes in PvP, mass Banshees in ZvT, and early Dark Templars caused our steepest worker losses ({_pl(n_zk, 'zero-kill collapse', 'zero-kill collapses')} and {_pl(n_clk, 'cloaked-unit loss', 'cloaked-unit losses')} on {html.escape(rel_lbl)}).",
        f"<strong>Capital-air dive commits and siege-line entry ({_pl(n_sg, 'zero-damage siege loss', 'zero-damage siege losses')}, {_pl(n_zf, 'zero-fire retreat', 'zero-fire retreats')}, {_pl(n_df, 'drip-feed collapse', 'drip-feed collapses')}):</strong> Against mass Tempests, Vikings and Corruptors hovered at weapon-range edge instead of committing together. {rot_gap_note}",
        f"<strong>Early Zerg worker tempo and ZvZ macro volume:</strong> Zerg active workers at 4:00 averaged {z_w4_avg:.1f} ({z_w4_gap:.1f} behind the Grandmaster median of {pro_z_w4:.1f}) due to early defensive Zerglings in peaceful openings, which slowed mid-game Roach and Hydralisk scaling against Division 6–7 Zerg opponents and Swarm Host pressure.",
        f"<strong>Early gas over-saturation and late-game expansion cadence:</strong> {_pl(n_gm, 'game', 'games')} hit mineral starvation alongside surplus gas during two-base transitions, while Terran third-base adoption ({t3_m_pct}% at {html.escape(t3_m_t)} vs. Pro {t3_p_pct}% at {html.escape(t3_p_t)}) and overall median gas income ({gas_m_med:,} vs. Pro {gas_p_med:,} per minute) still leave late-game headroom.",
    ]
    open_gaps_html = "".join(f"<li>{item}</li>" for item in open_gaps)

    return f"""
<section class="section-rule wide-col" id="matchups-section">
  <div class="section-head">
    <p class="section-num">{html.escape(section_num)}</p>
    <h2 class="section-kicker">Local Benchmark &amp; Pro Comparison</h2>
    <p class="section-intro">
      {spread_sentence} Locally we test every release candidate against 14 regular practice bots (<em>Core-14</em>),
      12 held-out bots we do not tune against directly (<em>Unseen-12</em>), and head-to-head games against the previous live bot.
    </p>
  </div>

  {cohort_strip_html}
  {race_table_html}

  <figure class="figure-block" style="margin-bottom:1.15rem;">
    <div class="figure-label">Figure 1 · Win Rate by Matchup</div>
    <div class="figure-title">Current build ({html.escape(build_lbl)}) local win rate vs. recent live ladder across all nine matchups</div>
    {wr_svg}
    <figcaption class="figure-caption">
      {html.escape(rel_lbl)} across all 26 external local opponents (gray) and the 14 regular practice bots (slate),
      shown next to recent v1 live ladder results (terracotta).
    </figcaption>
  </figure>

  <h3 style="margin:0 0 0.45rem;font-size:1.08rem;">Full 9-Matchup Breakdown ({html.escape(rel_in_parens)})</h3>
  <p class="table-note" style="margin:0 0 0.5rem;">
    Local columns show {html.escape(build_lbl)} across 78 external games (matches hitting the time limit count as ties). Live Ladder shows recent v1 AI Arena matches for context.
  </p>
  <div class="table-wrap" style="margin-bottom:1.5rem;">
    <table>
      <thead>
        <tr>
          <th>Matchup</th>
          <th style="text-align:right">All 26 Local</th>
          <th style="text-align:right">Win + Tie %</th>
          <th style="text-align:right">14 Core Bots</th>
          <th style="text-align:right">Local Trade</th>
          <th style="text-align:right">Supply-Blocked</th>
          <th style="text-align:right">Live Ladder (v1)</th>
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
    <h3>2.1 Base Layouts and Walls (at 4:10)</h3>
    <p class="prose-tight">
      In-game 3D captures of Mothman's main base, ramp wall, and second-base choke at 4:10 across all nine matchups,
      followed by a comparison against Grandmaster layouts.
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
{pro_combat_section}{pro_army_group_section}{pro_curves_section}
  <div class="eval-subsection">
    <h3>2.5 Supply-Blocked Time and Worker Curves</h3>
    <p class="prose-tight">
      On {html.escape(build_lbl)}, Terran stays between {t_sb_lo:.1f}% and {t_sb_hi:.1f}% supply-blocked across all three matchups,
      while Protoss and Zerg sit between {pz_sb_lo:.1f}% and {pz_sb_hi:.1f}% when early pressure kills Pylons or Overlords.
      Below left is supply-blocked time by matchup; below right are active worker curves through minute 10 compared with Grandmaster medians.
    </p>
    <div class="race-toggle" role="tablist" aria-label="Select race worker curve">
      <button type="button" class="cat-pill is-active" data-race-curve="Protoss">Protoss</button>
      <button type="button" class="cat-pill" data-race-curve="Terran">Terran</button>
      <button type="button" class="cat-pill" data-race-curve="Zerg">Zerg</button>
    </div>
    <div class="charts-pair">
      <figure class="figure-block" style="margin:0;">
        <div class="figure-label">Figure 2 · Supply-Blocked Time</div>
        <div class="figure-title">Average time supply-blocked by matchup ({html.escape(build_lbl)}, lower is better)</div>
        {sb_svg}
        <figcaption class="figure-caption">
          Percentage of match time unable to train units due to hitting supply cap (Pylon, Depot, or Overlord).
        </figcaption>
      </figure>
      <figure class="figure-block" style="margin:0;">
        <div class="figure-label">Figure 3 · Workers vs. Pro Median</div>
        <div class="figure-title">Active workers (minutes 1–10) vs. Pro median</div>
        <div class="race-svg-slot" data-curve-kind="wk" data-race="Protoss">{wk_svgs["Protoss"]}</div>
        <div class="race-svg-slot" data-curve-kind="wk" data-race="Terran" style="display:none;">{wk_svgs["Terran"]}</div>
        <div class="race-svg-slot" data-curve-kind="wk" data-race="Zerg" style="display:none;">{wk_svgs["Zerg"]}</div>
      </figure>
    </div>
  </div>

  <div class="eval-subsection" id="open-gaps">
    <h3>2.6 Current Open Weaknesses</h3>
    <ul class="gaps-list">{open_gaps_html}</ul>
  </div>

  <script>window.__MATCHUP_DATA__ = {mu_json}; window.__PRO_CURVES__ = {pro_curves_json};</script>
</section>
"""


def render_issues_fixed_section(
    chart_sym_svg: str,
    sym: Dict[str, Any],
    rich: Dict[str, Any],
    section_num: str = "Section 3",
) -> str:
    fw = rich["flywheel"]
    return f"""
<section class="section-rule wide-col" id="issues-section">
  <div class="section-head">
    <p class="section-num">{html.escape(section_num)}</p>
    <h2 class="section-kicker">Notable Bugs Found and Fixed</h2>
    <p class="section-intro">
      Six recurring bugs caught in replays and combat drills, what caused them in the code, and what changed after fixing them.
    </p>
  </div>

  <div class="case-grid">
    <article class="case-card case-wide">
      <div class="case-tag">Geometry &amp; Placement · Fixed in Loop 37</div>
      <h3>3.1 Losing More Often from Top-Half Spawns</h3>
      <div class="case-split">
        <div>
          <p><strong>Symptom:</strong> Bots won 16 percentage points less often when spawning north-east on Ley Lines (21.7% vs. 37.8%) and trailed by nearly 5 points across all northern spawns.</p>
          <p><strong>Root cause:</strong> Building placement and early scout offsets assumed the enemy sat roughly up and to the right, so top-half spawns walled off their own second base.</p>
          <p><strong>Fix &amp; result:</strong> Replaced compass-direction offsets with actual ground walking distances. Across {sym["post_n"]:,} local matches since Loop 37, north and south win rates leveled out ({sym["all_after_n"]:.1f}% vs. {sym["all_after_s"]:.1f}%), and recent builds split within 1 percentage point across north and south spawns.</p>
        </div>
        <figure class="figure-block" style="margin:0;">
          <div class="figure-title" style="font-size:0.98rem;">North vs. South win rate before and after fix</div>
          {chart_sym_svg}
        </figure>
      </div>
    </article>

    <article class="case-card">
      <div class="case-tag">Enemy Tech Inference · Fixed in Loop 43</div>
      <h3>3.2 Dead Zerg Buildings Triggering Anti-Air Panic</h3>
      <p><strong>Symptom:</strong> Against pure ground Zerg (Roaches and Hydralisks), Terran suddenly built 4 Starports and 13 Vikings mid-game.</p>
      <p><strong>Root cause:</strong> Destroying any Zerg building spawns short-lived Broodlings. Our tech-prerequisite table mapped Broodlings to Brood Lords and a Greater Spire, which tricked Terran into panicking against non-existent air units.</p>
      <p><strong>Fix &amp; result:</strong> Ignored Broodlings and Sentry hallucinations in tech inference. Unnecessary Viking builds dropped to zero and lifted Terran above a 1.0× overall trade ratio.</p>
    </article>

    <article class="case-card">
      <div class="case-tag">Unit Control · Fixed in Loops 43–46</div>
      <h3>3.3 Dark Templars Attacking Before Clearing Detectors</h3>
      <p><strong>Symptom:</strong> In drill p15, Dark Templars blinked straight onto a Terran Planetary Fortress while both Missile Turrets were still standing and died to splash damage. Even when they killed the turrets, surviving Dark Templars merged into visible Archons or got recalled home by their own Nexus.</p>
      <p><strong>Fix &amp; result:</strong> Dark Templars now split into two groups to destroy nearby detectors first, stay cloaked instead of merging into Archons or taking Mass Recall when no enemy detection remains, and sweep unexplored fog tiles. Drill p15 flipped from a 0.33× loss to a 1.58× win with 14 of 27 Dark Templars surviving.</p>
    </article>

    <article class="case-card">
      <div class="case-tag">Spending &amp; Production · Fixed in Loop 48</div>
      <h3>3.4 Conflicting Barracks Limits Freezing Terran Production</h3>
      <p><strong>Symptom:</strong> In Terran mirrors and three benchmark games, Terran stopped building units for several seconds at a time while sitting on unspent minerals.</p>
      <p><strong>Root cause:</strong> The spending queue scheduled a 5th or 7th Barracks on three bases, while the build executor enforced an older cap of two Barracks per Command Center and quietly dropped the order every frame.</p>
      <p><strong>Fix &amp; result:</strong> Matched the executor's facility cap (up to 8) to the spending queue and added a unit test verifying that both modules agree on every building limit.</p>
    </article>

    <article class="case-card">
      <div class="case-tag">Testing Workflow · Shipped in Loop 48</div>
      <h3>3.5 Running a 2-Minute Check Before the 30-Minute Benchmark</h3>
      <p><strong>Symptom:</strong> Six of seven held builds lost their 2-minute head-to-head match against the live bot, yet our test script ran the 31-minute, 84-game benchmark first and wasted {fw['total_wasted_min']} minutes of simulation.</p>
      <p><strong>Fix &amp; result:</strong> Moved the 2-minute head-to-head gate and targeted combat drills ahead of the full 84-game benchmark, and added a warning whenever the same rule gets tweaked repeatedly across consecutive runs.</p>
    </article>

    <article class="case-card case-wide">
      <div class="case-tag">StarCraft II 5.0.14 Protocol &amp; Regression Hygiene · Loops 50–57</div>
      <h3>3.6 Stale Ability IDs and Stacked Macro Locks</h3>
      <p><strong>Symptom:</strong> Several high-tech abilities silently failed on patch 5.0.14 (Baneling morph 80 vs. 4121, Raven Auto-Turret 349 vs. 1764, Overseer Oversight 3745 vs. 3743, Microbial Shroud 2545 vs. 4111), and stacking macro escrow locks across Loops 52–55 dragged win rates down despite head-to-head gains.</p>
      <p><strong>Fix &amp; result:</strong> Updated all 5.0.14 ability IDs with dynamic upgrade checks, then rebased cleanly onto Build 51 keeping only verified zero-downside fixes (Supply Depot lowering, Overseer cap, Stalker-before-Adept priority, and Spore cancel guard) for Release #10.</p>
    </article>
  </div>
  {render_economy_stalls_history_details()}
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

/* Current-State Cohort Strip, Arena Filters & Open Gaps */
.cohort-strip {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 0.65rem;
  margin: 0.75rem 0 1.25rem;
}
.cohort-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 0.65rem 0.78rem;
  display: flex;
  flex-direction: column;
  gap: 0.16rem;
}
.cohort-card strong {
  font-size: 1.12rem;
  color: var(--ink);
  font-variant-numeric: tabular-nums;
}
.cohort-sub {
  font-size: 0.76rem;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}
.arena-filter-bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.55rem 0.9rem;
  margin-top: 0.75rem;
  padding-top: 0.7rem;
  border-top: 1px solid var(--border);
}
.arena-filter-group {
  display: flex;
  flex-direction: row;
  flex-wrap: wrap;
  flex: 0 1 auto;
  max-width: 100%;
  min-width: 0;
  gap: 0.35rem;
}
.arena-search-input {
  flex: 1 1 220px;
  min-width: 190px;
  padding: 0.36rem 0.65rem;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: #FFFFFF;
  color: var(--ink);
  font-family: var(--sans);
  font-size: 0.84rem;
}
.arena-search-input:focus {
  outline: none;
  border-color: var(--accent);
}
.meta-badges {
  display: inline-flex;
  align-items: center;
  gap: 0.35rem;
  flex-wrap: wrap;
}
.spell-badge {
  font-size: 0.7rem;
  font-weight: 600;
  border-radius: 999px;
  padding: 0.08rem 0.48rem;
  white-space: nowrap;
}
.spell-ok {
  color: #1F6E43;
  background: #E9F6EE;
  border: 1px solid #BFE3CD;
}
.spell-miss {
  color: #9A3426;
  background: #FCECE9;
  border: 1px solid #EBC4BE;
}
.sid-pill {
  font-family: var(--mono);
  font-size: 0.71rem;
  color: var(--muted);
  margin: -0.15rem 0 0.42rem;
  word-break: break-all;
}
.gaps-list {
  margin: 0.45rem 0 0;
  padding-left: 1.2rem;
  max-width: 780px;
  font-size: 0.94rem;
  color: var(--ink-2);
  line-height: 1.58;
}
.gaps-list li { margin: 0.48rem 0; }
.cohort-heading {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  flex-wrap: wrap;
  gap: 0.4rem 0.85rem;
  margin: 1.15rem 0 0.45rem;
}
.cohort-heading h3 { margin: 0; font-size: 1.06rem; }
.cohort-tag {
  font-size: 0.76rem;
  font-weight: 600;
  color: var(--muted);
  font-variant-numeric: tabular-nums;
}
.history-cta {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.2rem;
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.75rem 1.25rem;
}
.history-cta p { margin: 0; font-size: 0.94rem; color: var(--ink-2); }
.history-cta a {
  font-weight: 600;
  color: var(--accent);
  text-decoration: none;
  border-bottom: 1px solid var(--accent);
  padding-bottom: 1px;
  white-space: nowrap;
}

/* Section 2.4 Performance Curves & Timings vs. Opponents & Pros */
.table-wrap.table-compact table { font-size: 0.82rem; }
.table-wrap.table-compact th, .table-wrap.table-compact td { padding: 0.42rem 0.48rem; white-space: nowrap; }
.site-curves-panel { padding: 1.05rem 1.15rem; max-width: 100%; min-width: 0; overflow-x: clip; }
.site-curves-toolbar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 0.5rem 0.9rem;
}
.site-curves-legend {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.55rem 1.1rem;
  margin: 0.65rem 0 0.85rem;
  padding-top: 0.6rem;
  border-top: 1px solid var(--border);
  font-size: 0.83rem;
  color: var(--ink-2);
}
.sc-leg-item { display: inline-flex; align-items: center; gap: 0.42rem; white-space: nowrap; }
.sc-leg-line { display: inline-block; width: 20px; height: 0; border-top: 2.6px solid #C4633E; }
.sc-leg-line.m { border-top-color: #C4633E; }
.sc-leg-line.p { border-top: 2.2px dashed #3B6E9C; }
.sc-leg-line.o { border-top: 2.2px solid #7A5A8E; }
.sc-leg-band { margin-left: auto; font-size: 0.78rem; }
.site-curves-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.9rem;
}
.site-curve-card {
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 0.78rem 0.9rem 0.65rem;
  display: flex;
  flex-direction: column;
  gap: 0.28rem;
  min-width: 0;
}
.site-curve-card.site-curve-span-2 { grid-column: 1 / -1; }
.site-curve-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: 0.5rem;
}
.site-curve-title {
  font-size: 0.9rem;
  font-weight: 600;
  color: var(--ink);
}
.site-curve-badge {
  font-family: var(--mono);
  font-size: 0.72rem;
  padding: 0.1rem 0.45rem;
  border-radius: 4px;
  background: var(--surface);
  color: var(--muted);
  white-space: nowrap;
}
.site-curve-meds {
  display: flex;
  flex-wrap: wrap;
  gap: 0.4rem 0.85rem;
  font-family: var(--mono);
  font-size: 0.77rem;
  color: var(--ink-2);
}
.sc-mpill { display: inline-flex; align-items: center; gap: 0.32rem; }
.sc-dot { width: 7px; height: 7px; border-radius: 50%; display: inline-block; }
.sc-dot.m { background: #C4633E; }
.sc-dot.p { background: #3B6E9C; }
.sc-dot.o { background: #7A5A8E; }
.site-curve-svg { width: 100%; height: auto; display: block; overflow: visible; user-select: none; touch-action: pan-y; }
.site-timings-box {
  margin-top: 1.05rem;
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 0.85rem 0.95rem 0.75rem;
  max-width: 100%;
  min-width: 0;
}
.site-timings-head {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: center;
  gap: 0.55rem 0.9rem;
}
.site-timings-sub { font-size: 0.82rem; color: var(--muted); margin-top: 0.12rem; }
.site-timings-wrap { width: 100%; max-width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }
.st-row-hit { fill: transparent; cursor: crosshair; }
.st-row-hit:hover { fill: rgba(196, 99, 62, 0.06); }
.site-curve-tooltip {
  position: fixed;
  z-index: 9999;
  pointer-events: none;
  background: #1C1B18;
  color: #FAF9F5;
  border: 1px solid rgba(255, 255, 255, 0.14);
  border-radius: 7px;
  padding: 0.5rem 0.7rem;
  font-size: 0.78rem;
  line-height: 1.42;
  box-shadow: 0 10px 26px rgba(20, 20, 19, 0.32);
  max-width: 285px;
}
.site-curve-tooltip strong { color: #FFFFFF; font-weight: 700; }
.sct-head {
  font-weight: 600;
  font-family: var(--mono);
  font-size: 0.77rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.16);
  padding-bottom: 0.22rem;
  margin-bottom: 0.28rem;
}
.sct-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 0.75rem;
  font-family: var(--mono);
  font-size: 0.75rem;
}
.sct-lbl { display: inline-flex; align-items: center; gap: 0.36rem; font-family: var(--sans); }
.sct-sub { font-size: 0.7rem; opacity: 0.76; margin-top: 0.2rem; }

/* 5-Tab 22-Graph Pro Comparison Observatory (Warm Editorial Light Theme) */
.obs-shell {
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
  min-width: 0;
  max-width: 100%;
}
.obs-tabs {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem;
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 9px;
  padding: 0.35rem;
}
.obs-tab {
  border: 1px solid transparent;
  background: transparent;
  color: var(--ink-2);
  font-family: var(--sans);
  font-size: 0.84rem;
  font-weight: 500;
  padding: 0.42rem 0.78rem;
  border-radius: 6px;
  cursor: pointer;
  white-space: nowrap;
  transition: background 0.14s ease, color 0.14s ease, border-color 0.14s ease;
}
.obs-tab:hover { background: var(--surface); color: var(--ink); }
.obs-tab.is-active {
  background: rgba(196, 99, 62, 0.12);
  color: #A84A27;
  border-color: rgba(196, 99, 62, 0.36);
  font-weight: 600;
}
.obs-toolbar {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  align-items: center;
  gap: 0.45rem 0.85rem;
}
.obs-pills {
  display: flex;
  flex-wrap: wrap;
  gap: 0.32rem;
}
.obs-pill {
  border: 1px solid var(--border);
  background: #FFFFFF;
  color: var(--ink-2);
  border-radius: 999px;
  padding: 0.22rem 0.68rem;
  font-family: var(--sans);
  font-size: 0.78rem;
  cursor: pointer;
  white-space: nowrap;
}
.obs-pill:hover { border-color: var(--accent); color: var(--ink); }
.obs-pill.is-active {
  background: var(--ink);
  color: #FAF9F5;
  border-color: var(--ink);
  font-weight: 600;
}
.obs-legend {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.45rem 1.05rem;
  padding: 0.5rem 0.75rem;
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 8px;
  font-size: 0.81rem;
  color: var(--ink-2);
}
.obs-legend > span {
  display: inline-flex;
  align-items: center;
  gap: 0.4rem;
  white-space: nowrap;
}
.obs-line {
  display: inline-block;
  width: 18px;
  height: 2.6px;
  border-radius: 2px;
}
.obs-line.obs-dash {
  height: 0;
  background: transparent !important;
  border-top: 2.2px dashed;
}
.obs-leg-note {
  margin-left: auto;
  color: var(--muted);
  font-size: 0.76rem;
  white-space: normal !important;
}
.obs-kpi-strip {
  display: grid;
  grid-template-columns: repeat(5, minmax(0, 1fr));
  gap: 0.6rem;
  margin-bottom: 0.8rem;
}
.obs-kpi {
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 0.62rem 0.78rem;
  display: flex;
  flex-direction: column;
  gap: 0.1rem;
  min-width: 0;
}
.obs-kpi-primary {
  border-color: rgba(196, 99, 62, 0.42);
  background: linear-gradient(180deg, rgba(196, 99, 62, 0.06), #FFFFFF);
}
.obs-kpi-lbl {
  font-size: 0.63rem;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  color: var(--muted);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.obs-kpi strong {
  font-family: var(--mono);
  font-size: 1.08rem;
  font-weight: 700;
  color: var(--ink);
}
.obs-kpi-sub {
  font-size: 0.73rem;
  color: var(--muted);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.obs-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.9rem;
}
.obs-card {
  background: #FFFFFF;
  border: 1px solid var(--border);
  border-radius: 9px;
  padding: 0.82rem 0.95rem 0.72rem;
  display: flex;
  flex-direction: column;
  gap: 0.35rem;
  min-width: 0;
  overflow: hidden;
}
.obs-card.obs-span-2 { grid-column: 1 / -1; }
.obs-card-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.4rem 0.75rem;
}
.obs-card-title {
  font-size: 0.92rem;
  font-weight: 600;
  color: var(--ink);
}
.obs-card-sub {
  font-size: 0.79rem;
  color: var(--muted);
  margin-top: 0.12rem;
  line-height: 1.38;
}
.obs-badge {
  font-family: var(--mono);
  font-size: 0.73rem;
  padding: 0.12rem 0.48rem;
  border-radius: 4px;
  background: var(--surface);
  color: var(--ink-2);
  white-space: nowrap;
}
.obs-meds {
  display: flex;
  flex-wrap: wrap;
  gap: 0.35rem 0.85rem;
  font-family: var(--mono);
  font-size: 0.77rem;
  color: var(--ink-2);
}
.obs-meds > span {
  display: inline-flex;
  align-items: center;
  gap: 0.32rem;
  white-space: nowrap;
}
.obs-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  display: inline-block;
  flex-shrink: 0;
}
.obs-svg {
  width: 100%;
  height: auto;
  display: block;
  overflow: visible;
  user-select: none;
  touch-action: pan-y;
}
.obs-split-2 {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 0.9rem;
}
.obs-mini-title {
  font-size: 0.82rem;
  font-weight: 600;
  color: var(--ink-2);
  margin-bottom: 0.25rem;
}
.obs-empty {
  padding: 1.2rem 0.75rem;
  text-align: center;
  color: var(--muted);
  font-size: 0.84rem;
}
.obs-missing-box {
  margin-top: 0.55rem;
  padding: 0.6rem 0.75rem;
  border-radius: 7px;
  background: rgba(180, 60, 46, 0.06);
  border: 1px solid rgba(180, 60, 46, 0.22);
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.35rem;
  font-size: 0.79rem;
}
.obs-missing-lbl {
  font-weight: 600;
  color: #B43C2E;
  margin-right: 0.2rem;
}
.obs-missing-pill {
  display: inline-block;
  padding: 0.12rem 0.5rem;
  border-radius: 999px;
  background: #FFFFFF;
  border: 1px solid var(--border);
  color: var(--ink);
  font-family: var(--mono);
  font-size: 0.73rem;
}
.obs-creep-strip {
  margin-top: 0.45rem;
  padding: 0.62rem 0.8rem;
  border-radius: 7px;
  background: var(--surface);
  border-left: 3px solid #B43C2E;
  font-size: 0.83rem;
  color: var(--ink);
}
.obs-tip-head {
  font-weight: 600;
  font-family: var(--mono);
  font-size: 0.77rem;
  border-bottom: 1px solid rgba(255, 255, 255, 0.16);
  padding-bottom: 0.22rem;
  margin-bottom: 0.28rem;
}
.obs-tip-row {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  gap: 0.75rem;
  font-family: var(--mono);
  font-size: 0.75rem;
}
.obs-tip-row > span:first-child {
  display: inline-flex;
  align-items: center;
  gap: 0.36rem;
  font-family: var(--sans);
}
.obs-tip-sub {
  font-size: 0.7rem;
  opacity: 0.76;
  margin-top: 0.2rem;
}

@media (max-width: 900px) {
  .subsys-grid, .charts-pair, .case-grid, .case-split, .mu-two-col, .explain-grid, .hist-pair, .site-curves-grid, .obs-grid, .obs-split-2 { grid-template-columns: minmax(0, 1fr); }
  .site-curve-card.site-curve-span-2, .obs-card.obs-span-2 { grid-column: auto; }
  .obs-kpi-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
@media (max-width: 699px) {
  .interactive-panel { padding: 0.9rem 0.75rem; }
  .detail-drawer { padding: 0.85rem; }
  .diagram-stage { padding: 0.5rem 0.35rem; }
  .metric-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .cohort-strip { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .obs-tab { font-size: 0.78rem; padding: 0.36rem 0.58rem; }
  .obs-leg-note { margin-left: 0; }
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

  // 3. Tactics Arena Gallery (ALL Scenarios We Run + Category/Race/Outcome/Search Filters + preload="none")
  const arenaCats = window.__ARENA_CATS__ || [];
  const catBtns = document.querySelectorAll('[data-cat-idx]');
  const arenaRaceBtns = document.querySelectorAll('[data-arena-race]');
  const arenaOutcomeBtns = document.querySelectorAll('[data-arena-outcome]');
  const arenaSearchEl = document.getElementById('arena-search-input');

  let activeCatKey = typeof window.__ARENA_DEFAULT_IDX__ === 'number' ? String(window.__ARENA_DEFAULT_IDX__) : '0';
  let activeArenaRace = 'all';
  let activeArenaOutcome = 'all';
  let activeArenaQuery = '';

  function renderArenaClipCard(cl) {
    const resCls = cl.outcome === 'win' ? 't-win' : (cl.outcome === 'loss' ? 't-loss' : 't-muted');
    const dlUrl = cl.download_url || cl.src;
    const pAttr = cl.poster ? ' poster="' + esc(cl.poster) + '"' : '';
    let ncHtml = '';
    if (typeof cl.non_combat_score === 'number' && !isNaN(cl.non_combat_score)) {
      const ncCls = cl.outcome === 'win' ? 'spell-ok' : 'spell-miss';
      ncHtml = '<span class="spell-badge ' + ncCls + '">Score ' + Math.round(cl.non_combat_score) + '/100</span>';
    }
    let svHtml = '';
    if (cl.spell_verified === true) {
      svHtml = '<span class="spell-badge spell-ok">Spell verified</span>';
    } else if (cl.spell_verified === false) {
      svHtml = '<span class="spell-badge spell-miss">Spell uncast</span>';
    }
    const sidMatch = cl.id ? String(cl.id).match(/^sc2-([a-z0-9]+-[a-z0-9]+)(?:-|$)/i) : null;
    const shortSid = sidMatch ? sidMatch[1] : (cl.id || '');
    const sidHtml = cl.id ? '<div class="sid-pill" data-sid="' + esc(cl.id) + '" title="' + esc(cl.id) + '">' + esc(shortSid) + '</div>' : '';
    const vHtml =
      '<div class="clip-video-wrap">' +
        '<video class="clip-video" controls playsinline webkit-playsinline preload="none"' + pAttr + '>' +
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
          '<span class="meta-badges">' + ncHtml + svHtml + '<span class="' + resCls + '">' + esc(cl.result_label || '') + '</span></span>' +
        '</div>' +
        '<h4>' + esc(cl.title) + '</h4>' +
        sidHtml +
        '<figure class="clip-figure">' + vHtml + '<figcaption>' + esc(cl.caption || '') + '</figcaption></figure>' +
      '</article>'
    );
  }

  function renderArenaView() {
    if (!arenaCats.length) return;
    const titleEl = document.getElementById('cat-detail-title');
    const countsEl = document.getElementById('cat-detail-counts');
    const descEl = document.getElementById('cat-detail-desc');
    const metricsEl = document.getElementById('cat-detail-metrics');
    const clipsEl = document.getElementById('cat-detail-clips');
    const headEl = document.getElementById('cat-clips-heading');
    if (!clipsEl) return;

    let rawClips = [];
    if (activeCatKey === 'all') {
      let totCat = 0, totCore = 0, dw = 0, dl = 0, dd = 0, sw = 0, sl = 0, sd = 0, svOk = 0, svN = 0;
      arenaCats.forEach(function(c) {
        totCat += (c.total || 0);
        totCore += (c.core || 0);
        dw += (c.d_w || 0); dl += (c.d_l || 0); dd += (c.d_d || 0);
        sw += (c.sp_w || 0); sl += (c.sp_l || 0); sd += (c.sp_d || 0);
        svOk += (c.sv_ok || 0); svN += (c.sv_n || 0);
        (c.clips || []).forEach(function(cl) { rawClips.push(cl); });
      });
      if (titleEl) titleEl.textContent = 'All Recorded Scenarios';
      if (countsEl) countsEl.textContent = rawClips.length + ' recorded · ' + totCat + ' in catalog (' + totCore + ' core)';
      if (descEl) descEl.textContent = 'Every tactical scenario currently captured as real 3D StarCraft II video across all categories. Use the race, outcome, or search controls above to narrow the list.';
      if (metricsEl) {
        let mHtml =
          '<div class="m-chip"><span class="m-lbl">vs. Scripted AI</span><strong>' + dw + '–' + dl + (dd ? '–' + dd : '') + '</strong></div>' +
          '<div class="m-chip"><span class="m-lbl">vs. Mothman Copy</span><strong>' + sw + '–' + sl + (sd ? '–' + sd : '') + '</strong></div>';
        if (svN > 0) {
          mHtml += '<div class="m-chip"><span class="m-lbl">Spell Cast Verified</span><strong>' + svOk + '/' + svN + '</strong></div>';
          metricsEl.className = 'metric-strip';
        } else {
          metricsEl.className = 'metric-strip metric-strip-2';
        }
        metricsEl.innerHTML = mHtml;
      }
    } else {
      const c = arenaCats[parseInt(activeCatKey, 10)];
      if (!c) return;
      rawClips = c.clips || [];
      if (titleEl) titleEl.textContent = c.label;
      if (countsEl) {
        countsEl.textContent = (c.is_non_combat && !c.core)
          ? ((c.clip_count || rawClips.length) + ' recorded · ' + c.total + ' in catalog (non-combat suite)')
          : ((c.clip_count || rawClips.length) + ' recorded · ' + c.total + ' in catalog (' + c.core + ' core)');
      }
      if (descEl) descEl.textContent = c.desc;
      if (metricsEl) {
        if (c.is_non_combat) {
          const ncTot = (c.d_w || 0) + (c.d_l || 0) + (c.d_d || 0);
          const ncRec = ncTot > 0 ? (c.d_w + '–' + c.d_l + (c.d_d ? '–' + c.d_d : '')) : 'Pending run';
          const ncAvg = (typeof c.nc_avg === 'number' && !isNaN(c.nc_avg)) ? (Number(c.nc_avg).toFixed(1) + '/100') : 'Pending';
          metricsEl.className = 'metric-strip metric-strip-2';
          metricsEl.innerHTML =
            '<div class="m-chip"><span class="m-lbl">Pass / Fail</span><strong>' + esc(ncRec) + '</strong></div>' +
            '<div class="m-chip"><span class="m-lbl">Avg Objective Score</span><strong>' + esc(ncAvg) + '</strong></div>';
        } else {
          const dRec = c.d_w + '–' + c.d_l + (c.d_d ? '–' + c.d_d : '') + ' (' + Number(c.d_tr).toFixed(2) + '×)';
          const spTot = (c.sp_w || 0) + (c.sp_l || 0) + (c.sp_d || 0);
          const sRec = spTot > 0 ? (c.sp_w + '–' + c.sp_l + (c.sp_d ? '–' + c.sp_d : '') + ' (' + Number(c.sp_tr).toFixed(2) + '×)') : 'Scripted AI only';
          let mHtml =
            '<div class="m-chip"><span class="m-lbl">vs. Scripted AI</span><strong>' + esc(dRec) + '</strong></div>' +
            '<div class="m-chip"><span class="m-lbl">vs. Mothman Copy</span><strong>' + esc(sRec) + '</strong></div>';
          if (c.sv_n > 0) {
            mHtml += '<div class="m-chip"><span class="m-lbl">Spell Cast Verified</span><strong>' + c.sv_ok + '/' + c.sv_n + '</strong></div>';
            metricsEl.className = 'metric-strip';
          } else {
            metricsEl.className = 'metric-strip metric-strip-2';
          }
          metricsEl.innerHTML = mHtml;
        }
      }
    }

    const q = activeArenaQuery.trim().toLowerCase();
    const filtered = rawClips.filter(function(cl) {
      if (activeArenaRace !== 'all' && (cl.race || '') !== activeArenaRace) return false;
      if (activeArenaOutcome === 'win' && cl.outcome !== 'win') return false;
      if (activeArenaOutcome === 'loss' && cl.outcome !== 'loss') return false;
      if (activeArenaOutcome === 'spell_ok' && cl.spell_verified !== true) return false;
      if (q) {
        const hay = ((cl.id || '') + ' ' + (cl.title || '') + ' ' + (cl.caption || '') + ' ' + (cl.meta || '') + ' ' + (cl.race || '')).toLowerCase();
        if (hay.indexOf(q) === -1) return false;
      }
      return true;
    });
    if (headEl) headEl.textContent = 'Recorded Scenarios (' + filtered.length + ' of ' + rawClips.length + ' shown)';
    clipsEl.innerHTML = filtered.length
      ? filtered.map(renderArenaClipCard).join('')
      : '<p class="t-muted">No recorded scenarios match the current filter.</p>';
  }

  catBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      activeCatKey = btn.getAttribute('data-cat-idx') || '0';
      catBtns.forEach(function(b) { b.classList.toggle('is-active', b === btn); });
      renderArenaView();
    });
  });
  arenaRaceBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      activeArenaRace = btn.getAttribute('data-arena-race') || 'all';
      arenaRaceBtns.forEach(function(b) { b.classList.toggle('is-active', b === btn); });
      renderArenaView();
    });
  });
  arenaOutcomeBtns.forEach(function(btn) {
    btn.addEventListener('click', function() {
      activeArenaOutcome = btn.getAttribute('data-arena-outcome') || 'all';
      arenaOutcomeBtns.forEach(function(b) { b.classList.toggle('is-active', b === btn); });
      renderArenaView();
    });
  });
  if (arenaSearchEl) {
    arenaSearchEl.addEventListener('input', function() {
      activeArenaQuery = arenaSearchEl.value || '';
      if (activeArenaQuery.trim() && activeCatKey !== 'all') {
        activeCatKey = 'all';
        catBtns.forEach(function(b) { b.classList.toggle('is-active', b.getAttribute('data-cat-idx') === 'all'); });
      }
      renderArenaView();
    });
  }

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
      const loc = m.cur_local || m.local || {};
      const cor = m.cur_core || m.core || {};
      const prd = m.prod || {};
      const blbl = m.build_label || 'Current Build';
      const prdS = prd.n ? (Number(prd.wr || 0).toFixed(1) + '% · ' + prd.w + '–' + prd.l + (prd.t ? '–' + prd.t : '') + ' (' + Number(prd.tr).toFixed(2) + '×)') : '—';
      const corS = cor.n ? (Number(cor.wr || 0).toFixed(1) + '% · ' + cor.w + '–' + cor.l + (cor.t ? '–' + cor.t : '') + ' (' + Number(cor.tr).toFixed(2) + '×)') : '—';
      const locS = loc.n ? (Number(loc.wr || 0).toFixed(1) + '% · ' + loc.w + '–' + loc.l + (loc.t ? '–' + loc.t : '') + ' (' + Number(loc.tr).toFixed(2) + '×)') : '—';
      document.getElementById('mu-detail-title').textContent = m.matchup + ' (' + m.race + ')';
      document.getElementById('mu-detail-meta').textContent = 'Avg duration ' + Number(loc.dur_m || 0).toFixed(1) + 'm · ' + Number(loc.bases || 0).toFixed(1) + ' peak bases';
      document.getElementById('mu-detail-metrics').innerHTML =
        '<div class="m-chip"><span class="m-lbl">' + esc(blbl) + ' · All 26</span><strong>' + esc(locS) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">' + esc(blbl) + ' · 14 Core</span><strong>' + esc(corS) + '</strong></div>' +
        '<div class="m-chip"><span class="m-lbl">Recent Live Ladder (v1)</span><strong>' + esc(prdS) + '</strong></div>' +
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

  // 6. Pro Comparison Observatory (5 Tabs, 22 Interactive Graphs)
  const proCurves = window.__PRO_CURVES__;
  const obsMount = document.getElementById('site-observatory-mount');
  const scTip = document.getElementById('site-curve-tooltip');
  if (proCurves && proCurves.curves && obsMount && window.MothmanObservatory) {
    window.MothmanObservatory.mount(obsMount, proCurves, {
      theme: 'light',
      tooltipEl: scTip
    });
  }
})();
</script>
"""

def _load_observatory_inline_script() -> str:
    obs_path = Path(__file__).with_name("observatory_charts.js")
    if obs_path.is_file():
        code = obs_path.read_text(encoding="utf-8").replace("</script>", "<\\/script>")
        return "<script>\n" + code + "\n</script>\n"
    return ""

INTERACTIVE_SECTIONS_JS = _load_observatory_inline_script() + INTERACTIVE_SECTIONS_JS
