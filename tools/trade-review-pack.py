#!/usr/bin/env python3
"""
tools/trade-review-pack.py

Post-match Replay + Video Trade Review generator for Mothman SC2 Bot.

Supports two modes:
  1. Arena mode (`--tactics-json` + `--video-dir`):
     Ranks worst-trading fights from a Tactics Arena 3.0 run (`tactics_sc2_*.json`),
     extracts a 6-frame visual contact sheet (.jpg) from each fight's .mp4 video,
     and pairs it with a replay telemetry card (trade ratio, losses/kills, abilities,
     zero-fire/retreat/idle flags).
  2. Real-match mode (`--run-id` + `--replay-db` [+ optional `--video-dir`, `--score-json`]):
     Ranks worst-trading external matches from read-only `arena_replays.sqlite`,
     locates each match's decisive worst-trading battle minute via `match_minute_stats`,
     extracts a 6-frame visual contact sheet (.jpg) focused on that battle window from
     the rendered match .mp4, and pairs it with unit loss/kill totals, command/ability
     summaries, and anomaly/retreat/stall flags.

Outputs:
  - <out-dir>/sheets/01_<slug>.jpg ... (6-frame contact sheets)
  - <out-dir>/trade_review_pack.md     (review index + telemetry cards)
  - <out-dir>/trade_review_pack.json   (machine-readable manifest)
"""

from __future__ import annotations

import argparse
import io
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont

DEFAULT_DB_PATH = Path.home() / "sc2-local-arena" / "arena_replays.sqlite"

# Common SC2 raw ability IDs -> readable labels for Tactics Arena telemetry cards
ABILITY_NAMES: dict[int, str] = {
    4: "Stop",
    16: "Move",
    17: "Patrol",
    18: "HoldPos",
    23: "Attack",
    166: "EMP",
    168: "Snipe",
    173: "GravitonBeam",
    174: "Yamato",
    253: "Stim(Marine)",
    366: "Cloak",
    367: "Decloak",
    380: "Stim(Marauder)",
    388: "Siege",
    390: "Unsiege",
    560: "Repair",
    1006: "Ability1006",
    1036: "PsiStorm",
    1442: "Blink",
    1526: "ForceField",
    1528: "GuardianShield",
    1622: "Fungal",
    1624: "Neural",
    1729: "WidowBurrow",
    2095: "MineBurrow",
    2097: "MineUnburrow",
    2330: "CorrosiveBile",
    2346: "PurifNova",
    2362: "ThorAP",
    2364: "ThorExplosive",
    2375: "PulsarBeamOn",
    2376: "PulsarBeamOff",
    2393: "ParasiticBomb",
    2395: "BlindingCloud",
    2401: "Abduct",
    2505: "StasisWard",
    2558: "LibAG",
    2560: "LibAA",
    2586: "LockOn",
    2588: "AdeptShade",
    2604: "PrismaticAlign",
    3666: "Harvest",
    3674: "AttackMove",
    3675: "Stim",
    3687: "Blink",
    3755: "Special3755",
}

NOISY_LOSS_UNITS = frozenset({
    "Larva", "Egg", "Interceptor", "Broodling", "BroodlingEscort",
    "MULE", "AdeptPhaseShift", "KD8Charge", "LocustMP", "LocustMPFlying",
    "DisruptorPhased", "Changeling", "ChangelingMarine", "ChangelingMarineShield",
    "ChangelingZealot", "ChangelingZergling", "ChangelingZerglingWings",
    "ScannerSweep", "PointDefenseDrone", "ParasiticBombDummy",
})

SPELLCASTER_UNITS = frozenset({
    "high_templar", "sentry", "oracle", "disruptor", "phoenix",
    "ghost", "raven", "medivac", "battlecruiser", "liberator", "siege_tank", "widow_mine",
    "viper", "infestor", "ravager", "queen", "lurker",
})


def _safe_float(v: Any, default: float = 0.0) -> float:
    if isinstance(v, bool) or v is None:
        return default
    try:
        f = float(v)
        return f if math.isfinite(f) else default
    except (TypeError, ValueError):
        return default


def _slugify(s: str, max_len: int = 64) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", s).strip("_")
    return cleaned[:max_len] or "fight"


def _fmt_mmss(sec: float | None) -> str:
    if sec is None:
        return "-"
    s = max(0, int(round(sec)))
    return f"{s // 60}:{s % 60:02d}"


def _probe_video_duration(mp4_path: Path) -> float | None:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe or not mp4_path.is_file():
        return None
    try:
        res = subprocess.run(
            [
                ffprobe, "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                str(mp4_path),
            ],
            capture_output=True, text=True, timeout=15, check=False,
        )
        if res.returncode == 0 and res.stdout.strip():
            d = float(res.stdout.strip())
            if math.isfinite(d) and d > 0.0:
                return d
    except Exception:
        return None
    return None


def _extract_frame_pil(mp4_path: Path, timestamp_sec: float) -> Image.Image | None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg or not mp4_path.is_file():
        return None
    ts = max(0.0, float(timestamp_sec))
    try:
        res = subprocess.run(
            [
                ffmpeg, "-hide_banner", "-loglevel", "error",
                "-ss", f"{ts:.3f}",
                "-i", str(mp4_path),
                "-frames:v", "1",
                "-f", "image2pipe",
                "-vcodec", "mjpeg",
                "-q:v", "3",
                "pipe:1",
            ],
            capture_output=True, timeout=20, check=False,
        )
        if res.returncode == 0 and res.stdout:
            img = Image.open(io.BytesIO(res.stdout))
            img.load()
            return img.convert("RGB")
    except Exception:
        return None
    return None


def _load_font(size: int) -> ImageFont.ImageFont:
    for cand in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
    ):
        if os.path.isfile(cand):
            try:
                return ImageFont.truetype(cand, size)
            except Exception:
                pass
    return ImageFont.load_default()


def build_contact_sheet(
    mp4_path: Path,
    out_jpg: Path,
    title: str,
    subtitle: str,
    footer_lines: list[str],
    window_frac: tuple[float, float] = (0.05, 0.94),
    game_duration_sec: float | None = None,
    n_frames: int = 6,
) -> dict[str, Any] | None:
    """Extract 6 evenly-spaced frames from `mp4_path` and render a 3x2 labeled JPEG contact sheet."""
    vid_dur = _probe_video_duration(mp4_path)
    if vid_dur is None or vid_dur <= 0.05:
        return None

    f0 = max(0.0, min(0.95, window_frac[0]))
    f1 = max(f0 + 0.04, min(0.98, window_frac[1]))
    t_start = max(0.05, min(vid_dur - 0.15, vid_dur * f0))
    t_end = max(t_start + 0.05, min(vid_dur - 0.05, vid_dur * f1))

    if n_frames <= 1:
        timestamps = [0.5 * (t_start + t_end)]
    else:
        step = (t_end - t_start) / (n_frames - 1)
        timestamps = [t_start + i * step for i in range(n_frames)]

    frames: list[tuple[float, Image.Image]] = []
    for ts in timestamps:
        im = _extract_frame_pil(mp4_path, ts)
        if im is None and ts > 0.2:
            im = _extract_frame_pil(mp4_path, max(0.05, ts - 0.25))
        if im is not None:
            frames.append((ts, im))

    if not frames:
        return None

    # Wrap footer lines cleanly so telemetry never clips at the right edge
    wrapped_footer: list[str] = []
    max_chars = 148
    for fline in footer_lines:
        if len(fline) <= max_chars:
            wrapped_footer.append(fline)
        else:
            words = fline.split(" ")
            cur = ""
            for w in words:
                if cur and len(cur) + 1 + len(w) > max_chars:
                    wrapped_footer.append(cur)
                    cur = "  " + w
                else:
                    cur = (cur + " " + w) if cur else w
            if cur:
                wrapped_footer.append(cur)

    # Layout geometry: 3 columns x 2 rows
    cols = 3
    rows = max(1, math.ceil(len(frames) / cols))
    tile_w, tile_h = 460, 310
    pad = 12
    header_h = 66
    footer_h = 20 + 21 * max(1, len(wrapped_footer))
    canvas_w = pad + cols * (tile_w + pad)
    canvas_h = header_h + pad + rows * (tile_h + pad) + footer_h

    canvas = Image.new("RGB", (canvas_w, canvas_h), (18, 22, 28))
    draw = ImageDraw.Draw(canvas)
    f_title = _load_font(18)
    f_sub = _load_font(13)
    f_badge = _load_font(13)
    f_foot = _load_font(13)

    # Top header banner
    draw.rectangle([(0, 0), (canvas_w, header_h)], fill=(28, 35, 46))
    draw.text((pad, 10), title[:115], fill=(242, 246, 252), font=f_title)
    draw.text((pad, 38), subtitle[:145], fill=(176, 194, 214), font=f_sub)

    for idx, (ts, im) in enumerate(frames):
        r = idx // cols
        c = idx % cols
        x0 = pad + c * (tile_w + pad)
        y0 = header_h + pad + r * (tile_h + pad)
        resized = im.resize((tile_w, tile_h), Image.Resampling.LANCZOS)
        canvas.paste(resized, (x0, y0))
        draw.rectangle([(x0, y0), (x0 + tile_w, y0 + tile_h)], outline=(65, 78, 96), width=2)

        # Frame timestamp pill in bottom-right corner (keeps top HUD & bottom-left minimap unobscured)
        if game_duration_sec and game_duration_sec > 0.0:
            est_game = (ts / vid_dur) * game_duration_sec
            lbl = f"#{idx + 1}  vid {ts:.1f}s (~{_fmt_mmss(est_game)})"
        else:
            lbl = f"#{idx + 1}  t={ts:.1f}s / {vid_dur:.1f}s"
        pill_w = min(tile_w - 8, 16 + 8 * len(lbl))
        px0 = x0 + tile_w - pill_w - 4
        py0 = y0 + tile_h - 26
        draw.rectangle([(px0, py0), (x0 + tile_w - 4, y0 + tile_h - 4)], fill=(12, 16, 22))
        draw.text((px0 + 8, py0 + 4), lbl, fill=(245, 220, 120), font=f_badge)

    # Bottom telemetry footer
    fy0 = header_h + pad + rows * (tile_h + pad)
    draw.rectangle([(0, fy0), (canvas_w, canvas_h)], fill=(24, 30, 39))
    for i, fline in enumerate(wrapped_footer):
        draw.text((pad, fy0 + 9 + i * 21), fline, fill=(224, 232, 240), font=f_foot)

    out_jpg.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out_jpg, format="JPEG", quality=88, optimize=True)
    return {
        "sheet_path": str(out_jpg),
        "video_path": str(mp4_path),
        "video_duration_sec": round(vid_dur, 2),
        "frames_extracted": len(frames),
        "timestamps_sec": [round(ts, 2) for ts, _ in frames],
    }


# ---------------------------------------------------------------------------
# Mode 1: Tactics Arena Review Pack
# ---------------------------------------------------------------------------

def _decode_arena_abilities(breakdown: dict[str, Any] | None) -> list[str]:
    if not breakdown:
        return []
    items = []
    for k, v in breakdown.items():
        try:
            aid = int(k)
            cnt = int(v)
        except (TypeError, ValueError):
            continue
        name = ABILITY_NAMES.get(aid, f"ab#{aid}")
        items.append((cnt, f"{name}:{cnt}"))
    items.sort(key=lambda x: (-x[0], x[1]))
    return [lbl for _, lbl in items[:6]]


def _derive_arena_flags(s: dict[str, Any]) -> list[str]:
    flags: list[str] = []
    atk = int(s.get("mothman_attack_unit_cmds") or 0)
    mov = int(s.get("mothman_move_unit_cmds") or 0)
    spl = int(s.get("mothman_spell_unit_cmds") or 0)
    p1_lost = _safe_float(s.get("p1_lost_val"))
    p2_lost = _safe_float(s.get("p2_lost_val"))
    first_off = _safe_float(s.get("first_action_loop_offset"), 0.0)
    p1_types = set((s.get("p1_start_types") or {}).keys())
    mode = s.get("scoring_mode") or "combat"

    if atk == 0:
        flags.append("ZERO_ATTACK_CMDS")
    elif mov > 2 * atk and mov >= 20:
        flags.append(f"HIGH_MOVE_LOW_ATK({mov}m/{atk}a)")
    if p2_lost <= 0.0 and p1_lost > 0.0:
        flags.append("ZERO_ENEMY_KILLS")
    if first_off > 24.0:
        flags.append(f"SLOW_START(+{int(first_off)}f)")
    if (p1_types & SPELLCASTER_UNITS) and spl == 0:
        flags.append("ZERO_SPELLS_WITH_CASTERS")
    if mode == "worker-runby" and int(s.get("enemy_workers_killed") or 0) == 0:
        flags.append("RUNBY_0_WORKERS_KILLED")
    if s.get("end_reason") == "timeout":
        flags.append("TIMEOUT")
    return flags


def _find_arena_video(video_dir: Path | None, scen_id: str) -> Path | None:
    if not video_dir or not video_dir.is_dir():
        return None
    for name in (f"{scen_id}.mp4", f"arena_{scen_id}.mp4", f"selfplay_{scen_id}.mp4"):
        p = video_dir / name
        if p.is_file():
            return p
    cands = sorted(video_dir.glob(f"*{scen_id}*.mp4"))
    return cands[0] if cands else None


def run_arena_review(
    tactics_json: Path,
    video_dir: Path | None,
    out_dir: Path,
    top_n: int = 8,
    race_filter: str | None = None,
    category_filter: str | None = None,
) -> dict[str, Any]:
    raw = json.loads(tactics_json.read_text(encoding="utf-8"))
    scenarios = raw.get("scenarios") or []
    opp_mode = raw.get("opponent_mode") or "dummy"

    filtered = []
    for s in scenarios:
        if race_filter and (s.get("race") or "").lower() != race_filter.lower():
            continue
        if category_filter and (s.get("category") or "").lower() != category_filter.lower():
            continue
        p1_lost = _safe_float(s.get("p1_lost_val"))
        winner = str(s.get("winner") or "")
        is_loss = winner not in ("Mothman", "Mothman-P1")
        tr = _safe_float(s.get("p1_trade_ratio", s.get("trade_ratio")), 99.0)
        # Skip clean zero-loss wins when ranking worst trades
        if not is_loss and p1_lost <= 0.0:
            continue
        filtered.append((0 if is_loss else 1, tr, -p1_lost, s))

    filtered.sort(key=lambda x: (x[0], x[1], x[2]))
    selected = [x[3] for x in filtered[:top_n]]

    sheets_dir = out_dir / "sheets"
    items: list[dict[str, Any]] = []
    flag_counter = Counter()

    for rank, s in enumerate(selected, 1):
        sid = str(s.get("id") or f"scen_{rank}")
        race = s.get("race") or "?"
        erace = s.get("enemy_race") or "?"
        mu = f"{race[0]}v{erace[0]}" if race != "?" and erace != "?" else "?"
        tr = _safe_float(s.get("p1_trade_ratio", s.get("trade_ratio")))
        p1_lost = _safe_float(s.get("p1_lost_val"))
        p2_lost = _safe_float(s.get("p2_lost_val"))
        atk = int(s.get("mothman_attack_unit_cmds") or 0)
        mov = int(s.get("mothman_move_unit_cmds") or 0)
        spl = int(s.get("mothman_spell_unit_cmds") or 0)
        top_ab = _decode_arena_abilities(s.get("mothman_ability_breakdown"))
        flags = _derive_arena_flags(s)
        for fl in flags:
            flag_counter[fl.split("(")[0]] += 1

        mp4 = _find_arena_video(video_dir, sid)
        sheet_info = None
        if mp4 is not None:
            sheet_path = sheets_dir / f"{rank:02d}_{_slugify(sid)}.jpg"
            title = f"#{rank} {sid}  [{mu} | {s.get('category', '-')}]"
            subtitle = (
                f"Winner: {s.get('winner')} ({s.get('end_reason')}) | Trade: {tr:.2f}x | "
                f"Killed {int(p2_lost)} vs Lost {int(p1_lost)} | "
                f"Alive: {s.get('p1_alive_cnt')}/{s.get('p1_start_cnt')} vs {s.get('p2_alive_cnt')}/{s.get('p2_start_cnt')}"
            )
            foot = [
                f"Units: {s.get('p1_spec')}  VS  {s.get('p2_spec')}",
                f"Cmds: ATK={atk} MOV={mov} SPELL={spl} | Top: {', '.join(top_ab) or '-'} | Flags: {', '.join(flags) or 'none'}",
            ]
            sheet_info = build_contact_sheet(
                mp4, sheet_path, title, subtitle, foot,
                window_frac=(0.05, 0.94),
                game_duration_sec=round(_safe_float(s.get("loops_simulated")) / 22.4, 1),
            )

        items.append({
            "rank": rank,
            "id": sid,
            "matchup": mu,
            "race": race,
            "category": s.get("category"),
            "terrain": s.get("terrain"),
            "scoring_mode": s.get("scoring_mode"),
            "winner": s.get("winner"),
            "end_reason": s.get("end_reason"),
            "trade_ratio": round(tr, 2),
            "killed_val": round(p2_lost, 1),
            "lost_val": round(p1_lost, 1),
            "p1_spec": s.get("p1_spec"),
            "p2_spec": s.get("p2_spec"),
            "p1_alive": f"{s.get('p1_alive_cnt')}/{s.get('p1_start_cnt')}",
            "p2_alive": f"{s.get('p2_alive_cnt')}/{s.get('p2_start_cnt')}",
            "enemy_workers_killed": s.get("enemy_workers_killed"),
            "cmds": {"attack": atk, "move": mov, "spell": spl, "top_abilities": top_ab},
            "flags": flags,
            "video_path": str(mp4) if mp4 else None,
            "contact_sheet": sheet_info["sheet_path"] if sheet_info else None,
            "sheet_meta": sheet_info,
        })

    return {
        "mode": "arena",
        "opponent_mode": opp_mode,
        "source_json": str(tactics_json),
        "video_dir": str(video_dir) if video_dir else None,
        "total_scenarios": len(scenarios),
        "reviewed_count": len(items),
        "flag_summary": dict(flag_counter.most_common()),
        "items": items,
    }


# ---------------------------------------------------------------------------
# Mode 2: Real-Match SQLite + Rendered Match MP4 Review Pack
# ---------------------------------------------------------------------------

def _find_match_video(
    video_dir: Path | None,
    match_index: int | None,
    bot: str,
    opponent: str,
    replay_filename: str | None,
) -> Path | None:
    if not video_dir or not video_dir.is_dir():
        return None
    cands: list[Path] = []
    if match_index is not None:
        cands.extend(sorted(video_dir.glob(f"full_m{match_index:03d}_*.mp4")))
        cands.extend(sorted(video_dir.glob(f"full_h2h{match_index:03d}_*.mp4")))
        cands.extend(sorted(video_dir.glob(f"*_m{match_index}_{bot}_vs_{opponent}*.mp4")))
    if not cands and bot and opponent:
        cands.extend(sorted(video_dir.glob(f"*{bot}_vs_{opponent}*.mp4")))
    if not cands and replay_filename:
        stem = Path(replay_filename).stem
        cands.extend(sorted(video_dir.glob(f"*{stem}*.mp4")))
    return cands[0] if cands else None


def _find_worst_fight_window(
    minute_rows: list[sqlite3.Row],
    duration_sec: float,
) -> dict[str, Any]:
    """Identify the minute with the largest net resource trade deficit (`delta_lost - delta_killed`)."""
    if not minute_rows:
        return {"worst_minute": None, "delta_killed": 0.0, "delta_lost": 0.0, "window_sec": (0.0, duration_sec)}
    prev_k, prev_l = 0.0, 0.0
    best_score = -1e9
    best_min = None
    best_dk, best_dl = 0.0, 0.0

    for r in minute_rows:
        mn = int(r["minute"] or 0)
        kt = _safe_float(r["killed_total"])
        lt = _safe_float(r["lost_total"])
        dk = max(0.0, kt - prev_k)
        dl = max(0.0, lt - prev_l)
        prev_k, prev_l = kt, lt
        if dl < 250.0:
            continue
        score = dl - 0.85 * dk
        if score > best_score:
            best_score = score
            best_min = mn
            best_dk, best_dl = dk, dl

    if best_min is None:
        # Fallback to last 30% of the match (final engagement)
        t0 = max(0.0, duration_sec * 0.65)
        t1 = max(t0 + 20.0, duration_sec * 0.96)
        return {
            "worst_minute": None,
            "delta_killed": 0.0,
            "delta_lost": 0.0,
            "window_sec": (round(t0, 1), round(min(duration_sec, t1), 1)),
        }

    # Fight happened between (best_min - 1):00 and best_min:00 -> frame [best_min*60 - 50s, best_min*60 + 15s]
    t0 = max(10.0, best_min * 60.0 - 55.0)
    t1 = min(max(t0 + 20.0, duration_sec - 5.0), best_min * 60.0 + 15.0)
    return {
        "worst_minute": best_min,
        "delta_killed": round(best_dk, 0),
        "delta_lost": round(best_dl, 0),
        "window_sec": (round(t0, 1), round(t1, 1)),
    }


def run_match_review(
    db_path: Path,
    run_id: str,
    video_dir: Path | None,
    score_json: Path | None,
    out_dir: Path,
    top_n: int = 8,
    race_filter: str | None = None,
    include_selfplay: bool = False,
) -> dict[str, Any]:
    p = os.path.abspath(os.path.expanduser(str(db_path)))
    conn = sqlite3.connect(Path(p).as_uri() + "?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        run_row = conn.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()
        if score_json is None and run_row and run_row["score_json_path"]:
            cand_sj = Path(run_row["score_json_path"])
            if cand_sj.is_file():
                score_json = cand_sj

        score_by_file: dict[str, dict[str, Any]] = {}
        if score_json and score_json.is_file():
            try:
                sj = json.loads(score_json.read_text(encoding="utf-8"))
                for m in sj.get("matches") or []:
                    fn = os.path.basename(m.get("file") or "")
                    if fn:
                        score_by_file[fn] = m
            except Exception:
                pass

        sp_clause = "" if include_selfplay else "AND COALESCE(is_selfplay, 0) = 0"
        mrows = conn.execute(
            f"""
            SELECT * FROM matches
            WHERE run_id = ? {sp_clause}
            ORDER BY match_index
            """,
            (run_id,),
        ).fetchall()

        ranked = []
        for m in mrows:
            race = m["actual_race"] or m["our_race"] or ""
            if race_filter and race.lower() != race_filter.lower():
                continue
            lost = _safe_float(m["lost_val"])
            killed = _safe_float(m["killed_val"])
            if lost < 400.0 and m["result"] == "win":
                continue
            tr = _safe_float(m["trade_ratio"], (killed / max(1.0, lost)))
            is_loss = 0 if str(m["result"]).lower() == "loss" else (1 if str(m["result"]).lower() == "tie" else 2)
            ranked.append((is_loss, tr, -lost, m))

        ranked.sort(key=lambda x: (x[0], x[1], x[2]))
        selected = [x[3] for x in ranked[:top_n]]

        sheets_dir = out_dir / "sheets"
        items: list[dict[str, Any]] = []
        flag_counter = Counter()

        for rank, m in enumerate(selected, 1):
            rid = m["replay_id"]
            our_pid = int(m["our_player_id"] or 1)
            opp_pid = 2 if our_pid == 1 else 1
            dur = _safe_float(m["duration_sec"], 300.0)

            min_rows = conn.execute(
                "SELECT minute, minerals_current, vespene_current, minerals_rate, vespene_rate, "
                "       workers_active, food_used, food_made, killed_total, lost_total "
                "FROM match_minute_stats WHERE replay_id = ? AND player_id = ? ORDER BY minute",
                (rid, our_pid),
            ).fetchall()
            fight_win = _find_worst_fight_window(min_rows, dur)

            our_losses = [
                f"{r['unit_type']}:{r['died']}"
                for r in conn.execute(
                    "SELECT unit_type, died FROM match_unit_totals "
                    "WHERE replay_id = ? AND player_id = ? AND died > 0 "
                    "ORDER BY died DESC LIMIT 20",
                    (rid, our_pid),
                ).fetchall()
                if r["unit_type"] not in NOISY_LOSS_UNITS
            ][:6]
            opp_losses = [
                f"{r['unit_type']}:{r['died']}"
                for r in conn.execute(
                    "SELECT unit_type, died FROM match_unit_totals "
                    "WHERE replay_id = ? AND player_id = ? AND died > 0 "
                    "ORDER BY died DESC LIMIT 20",
                    (rid, opp_pid),
                ).fetchall()
                if r["unit_type"] not in NOISY_LOSS_UNITS
            ][:6]

            # Command / ability usage summary if game events were extracted
            ab_counter = Counter()
            for r in conn.execute(
                "SELECT top_abilities_json FROM match_cmd_summary WHERE replay_id = ? AND user_id = ?",
                (rid, our_pid - 1),
            ).fetchall():
                try:
                    for ab, cnt in json.loads(r["top_abilities_json"] or "{}").items():
                        ab_counter[str(ab)] += int(cnt)
                except Exception:
                    pass
            top_abilities = [f"{k}:{v}" for k, v in ab_counter.most_common(6)]

            # Collect flags from match_anomalies + score JSON + Stall Watchdog minute stats
            flags: list[str] = [
                r["anomaly_name"]
                for r in conn.execute(
                    "SELECT DISTINCT anomaly_name FROM match_anomalies "
                    "WHERE replay_id = ? AND player_side = 'ours'",
                    (rid,),
                ).fetchall()
            ]
            srow = score_by_file.get(m["replay_filename"] or "")
            if srow:
                for k, v in (srow.get("anomalies") or {}).items():
                    if v and k not in flags:
                        flags.append(k)
                if srow.get("zero_fire_retreat") and "zero_fire_retreat" not in flags:
                    flags.append("zero_fire_retreat")
                if srow.get("siege_range_zero_dps_loss") and "siege_range_zero_dps_loss" not in flags:
                    flags.append("siege_range_zero_dps_loss")
                if srow.get("drip_feed_collapse") and "drip_feed_collapse" not in flags:
                    flags.append("drip_feed_collapse")
                if srow.get("cloaked_unit_damage_loss") and "cloaked_unit_damage_loss" not in flags:
                    flags.append("cloaked_unit_damage_loss")

            # Live minute-level Stall Watchdog flags
            if any(int(r["minute"] or 0) >= 1 and _safe_float(r["food_made"]) < 195 and _safe_float(r["food_used"]) >= _safe_float(r["food_made"]) for r in min_rows):
                flags.append("sup_cap_min")
            if any(int(r["minute"] or 0) >= 2 and _safe_float(r["workers_active"]) >= 5 and _safe_float(r["minerals_rate"]) <= 0 for r in min_rows):
                flags.append("zero_income")
            if any(int(r["minute"] or 0) >= 5 and _safe_float(r["workers_active"]) >= 16 and _safe_float(r["vespene_rate"]) <= 0 and _safe_float(r["vespene_current"]) < 450 for r in min_rows):
                flags.append("zero_gas")
            if any(int(r["minute"] or 0) == 8 and _safe_float(r["workers_active"]) <= 36 for r in min_rows):
                flags.append("wk_plateau_8m")

            flags = sorted(set(flags))
            for fl in flags:
                flag_counter[fl] += 1

            mp4 = _find_match_video(
                video_dir, m["match_index"], m["bot"] or "", m["opponent"] or "", m["replay_filename"]
            )
            sheet_info = None
            if mp4 is not None:
                vid_dur = _probe_video_duration(mp4) or 0.0
                if vid_dur >= 30.0 and dur > 0.0:
                    w0, w1 = fight_win["window_sec"]
                    wfrac = (max(0.02, w0 / dur), min(0.98, w1 / dur))
                else:
                    wfrac = (0.08, 0.94)
                slug = f"m{int(m['match_index'] or rank):03d}_{m['bot']}_vs_{m['opponent']}"
                sheet_path = sheets_dir / f"{rank:02d}_{_slugify(slug)}.jpg"
                tr = _safe_float(m["trade_ratio"])
                wmin = fight_win["worst_minute"]
                win_lbl = (
                    f"Worst fight @ min {wmin} (killed {int(fight_win['delta_killed'])} vs lost {int(fight_win['delta_lost'])})"
                    if wmin is not None
                    else f"Endgame window {_fmt_mmss(fight_win['window_sec'][0])}-{_fmt_mmss(fight_win['window_sec'][1])}"
                )
                title = f"#{rank} {m['bot']} vs {m['opponent']}  [{m['matchup']} | {m['map_name']} | {str(m['result']).upper()}]"
                subtitle = (
                    f"Trade {tr:.2f}x (killed {int(_safe_float(m['killed_val']))} / lost {int(_safe_float(m['lost_val']))}) | "
                    f"Dur {_fmt_mmss(dur)} | {win_lbl}"
                )
                foot = [
                    f"Our Losses: {', '.join(our_losses) or '-'}  |  Opp Losses: {', '.join(opp_losses) or '-'}",
                    f"Flags: {', '.join(flags) or 'none'}  |  Abilities: {', '.join(top_abilities) or 'n/a (no game-events)'}",
                ]
                sheet_info = build_contact_sheet(
                    mp4, sheet_path, title, subtitle, foot,
                    window_frac=wfrac,
                    game_duration_sec=dur if vid_dur >= 30.0 else None,
                )

            items.append({
                "rank": rank,
                "replay_id": rid[:12],
                "match_index": m["match_index"],
                "bot": m["bot"],
                "opponent": m["opponent"],
                "matchup": m["matchup"],
                "race": m["actual_race"] or m["our_race"],
                "map_name": m["map_name"],
                "spawn_corner": m["our_spawn_corner"],
                "result": m["result"],
                "duration_sec": round(dur, 1),
                "trade_ratio": round(_safe_float(m["trade_ratio"]), 2),
                "killed_val": round(_safe_float(m["killed_val"]), 1),
                "lost_val": round(_safe_float(m["lost_val"]), 1),
                "worst_fight_window": fight_win,
                "our_top_losses": our_losses,
                "opp_top_losses": opp_losses,
                "top_abilities": top_abilities,
                "flags": flags,
                "video_path": str(mp4) if mp4 else None,
                "contact_sheet": sheet_info["sheet_path"] if sheet_info else None,
                "sheet_meta": sheet_info,
            })

        return {
            "mode": "match",
            "run_id": run_id,
            "replay_db": str(db_path),
            "video_dir": str(video_dir) if video_dir else None,
            "total_matches": len(mrows),
            "reviewed_count": len(items),
            "flag_summary": dict(flag_counter.most_common()),
            "items": items,
        }
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Plain-English Markdown Review Pack Renderer
# ---------------------------------------------------------------------------

def render_review_markdown(pack: dict[str, Any], out_dir: Path) -> str:
    mode = pack["mode"]
    lines: list[str] = []
    if mode == "arena":
        lines.append(f"# Arena Replay + Video Trade Review Pack ({pack.get('opponent_mode', 'dummy')})")
        lines.append("")
        lines.append(
            f"Ranked worst **{pack['reviewed_count']}** of **{pack['total_scenarios']}** scenarios "
            f"from `{Path(pack['source_json']).name}`. Inspect BOTH the 6-frame contact sheet and "
            "the telemetry card below for each fight to identify generalizable trade fixes."
        )
    else:
        lines.append(f"# Match Replay + Video Trade Review Pack (`{pack['run_id']}`)")
        lines.append("")
        lines.append(
            f"Ranked worst **{pack['reviewed_count']}** of **{pack['total_matches']}** matches "
            f"in `{pack['run_id']}`. Each contact sheet frames the decisive worst-trading battle window."
        )
    lines.append("")

    if pack.get("flag_summary"):
        fstr = ", ".join(f"`{k}` ({v})" for k, v in pack["flag_summary"].items())
        lines.append(f"**Recurring Flags:** {fstr}")
        lines.append("")

    # Summary index table
    if mode == "arena":
        lines.append("| # | Scenario | MU | Category | Trade | Killed / Lost | Cmds (A/M/S) | Flags | Sheet |")
        lines.append("|---:|---|---|---|---:|---:|---|---|---|")
        for it in pack["items"]:
            rel = os.path.relpath(it["contact_sheet"], out_dir) if it.get("contact_sheet") else "-"
            c = it["cmds"]
            lines.append(
                f"| {it['rank']} | `{it['id']}` | {it['matchup']} | {it['category']} "
                f"| **{it['trade_ratio']:.2f}x** | {int(it['killed_val'])} / {int(it['lost_val'])} "
                f"| {c['attack']}/{c['move']}/{c['spell']} "
                f"| {', '.join(it['flags']) or '-'} "
                f"| {f'`{rel}`' if rel != '-' else 'no video'} |"
            )
    else:
        lines.append("| # | Match | MU | Map | Res | Trade | Worst Battle | Flags | Sheet |")
        lines.append("|---:|---|---|---|---|---:|---|---|---|")
        for it in pack["items"]:
            rel = os.path.relpath(it["contact_sheet"], out_dir) if it.get("contact_sheet") else "-"
            wf = it["worst_fight_window"]
            wlbl = f"min {wf['worst_minute']} ({int(wf['delta_killed'])}/{int(wf['delta_lost'])})" if wf["worst_minute"] is not None else "endgame"
            lines.append(
                f"| {it['rank']} | `#{it['match_index']}` {it['bot']} vs {it['opponent']} | {it['matchup']} "
                f"| {it['map_name']} | {str(it['result']).upper()} | **{it['trade_ratio']:.2f}x** "
                f"| {wlbl} | {', '.join(it['flags'][:4]) or '-'} "
                f"| {f'`{rel}`' if rel != '-' else 'no video'} |"
            )
    lines.append("")

    # Per-fight cards
    lines.append("## Per-Fight Visual Sheets & Telemetry Cards")
    lines.append("")
    for it in pack["items"]:
        if mode == "arena":
            lines.append(f"### #{it['rank']} `{it['id']}` ({it['matchup']} · {it['category']} · {it['trade_ratio']:.2f}x)")
            lines.append(
                f"- **Outcome:** Winner `{it['winner']}` (`{it['end_reason']}`), "
                f"killed `{int(it['killed_val'])}` vs lost `{int(it['lost_val'])}`, "
                f"alive `{it['p1_alive']}` vs `{it['p2_alive']}`"
            )
            lines.append(f"- **Armies:** `{it['p1_spec']}` vs `{it['p2_spec']}` (terrain `{it['terrain']}`)")
            c = it["cmds"]
            lines.append(
                f"- **Commands & Abilities:** ATK `{c['attack']}`, MOV `{c['move']}`, SPELL `{c['spell']}` "
                f"({', '.join(c['top_abilities']) or 'none'})"
            )
            lines.append(f"- **Flags:** {', '.join(f'`{f}`' for f in it['flags']) or 'none'}")
        else:
            lines.append(
                f"### #{it['rank']} `#{it['match_index']}` {it['bot']} vs {it['opponent']} "
                f"({it['matchup']} · {it['map_name']} · {str(it['result']).upper()} · {it['trade_ratio']:.2f}x)"
            )
            wf = it["worst_fight_window"]
            lines.append(
                f"- **Outcome:** Trade `{it['trade_ratio']:.2f}x` (killed `{int(it['killed_val'])}` vs lost `{int(it['lost_val'])}`), "
                f"duration `{_fmt_mmss(it['duration_sec'])}`, spawn `{it['spawn_corner']}`, replay `{it['replay_id']}`"
            )
            lines.append(
                f"- **Worst Fight Window:** `{_fmt_mmss(wf['window_sec'][0])}–{_fmt_mmss(wf['window_sec'][1])}` "
                f"(min `{wf['worst_minute']}`, killed `{int(wf['delta_killed'])}` vs lost `{int(wf['delta_lost'])}`)"
            )
            lines.append(f"- **Our Top Losses:** {', '.join(it['our_top_losses']) or '-'}")
            lines.append(f"- **Enemy Top Losses:** {', '.join(it['opp_top_losses']) or '-'}")
            lines.append(f"- **Top Abilities:** {', '.join(it['top_abilities']) or 'n/a (extract with --include-game-events)'}")
            lines.append(f"- **Flags:** {', '.join(f'`{f}`' for f in it['flags']) or 'none'}")

        if it.get("contact_sheet"):
            rel = os.path.relpath(it["contact_sheet"], out_dir)
            lines.append(f"- **Contact Sheet:** `{rel}` (source `{Path(it['video_path']).name}`)")
            lines.append("")
            lines.append(f"![Fight #{it['rank']}]({rel})")
        else:
            lines.append("- **Contact Sheet:** _No `.mp4` found in video directory; render clips first to inspect visually._")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description="Generate 6-frame video contact sheets + replay telemetry cards for worst-trading fights.")
    ap.add_argument("--mode", choices=("auto", "arena", "match"), default="auto", help="Review mode (auto detects from --tactics-json vs --run-id)")
    ap.add_argument("--tactics-json", default=None, help="Arena mode: path to tactics_sc2_*.json")
    ap.add_argument("--run-id", default=None, help="Match mode: SQLite runs.run_id")
    ap.add_argument("--replay-db", default=str(DEFAULT_DB_PATH), help="Match mode: read-only arena_replays.sqlite path")
    ap.add_argument("--score-json", default=None, help="Match mode: optional score JSON override for extra anomaly flags")
    ap.add_argument("--video-dir", default=None, help="Directory containing rendered .mp4 videos")
    ap.add_argument("--out-dir", required=True, help="Output directory for contact sheets, Markdown, and JSON manifest")
    ap.add_argument("--top", type=int, default=8, help="Number of worst-trading fights to include (default: 8)")
    ap.add_argument("--race", default=None, help="Optional race filter (Protoss, Terran, Zerg)")
    ap.add_argument("--category", default=None, help="Arena mode: optional category filter")
    ap.add_argument("--include-selfplay", action="store_true", help="Match mode: include self-play matches")
    args = ap.parse_args()

    mode = args.mode
    if mode == "auto":
        if args.tactics_json:
            mode = "arena"
        elif args.run_id:
            mode = "match"
        else:
            ap.error("Specify either --tactics-json (arena mode) or --run-id (match mode).")

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    video_dir = Path(args.video_dir) if args.video_dir else None

    if mode == "arena":
        if not args.tactics_json:
            ap.error("--tactics-json is required in arena mode.")
        pack = run_arena_review(
            Path(args.tactics_json),
            video_dir=video_dir,
            out_dir=out_dir,
            top_n=args.top,
            race_filter=args.race,
            category_filter=args.category,
        )
    else:
        if not args.run_id:
            ap.error("--run-id is required in match mode.")
        pack = run_match_review(
            Path(args.replay_db),
            run_id=args.run_id,
            video_dir=video_dir,
            score_json=Path(args.score_json) if args.score_json else None,
            out_dir=out_dir,
            top_n=args.top,
            race_filter=args.race,
            include_selfplay=args.include_selfplay,
        )

    md = render_review_markdown(pack, out_dir)
    out_md = out_dir / "trade_review_pack.md"
    out_json = out_dir / "trade_review_pack.json"
    out_md.write_text(md, encoding="utf-8")
    out_json.write_text(json.dumps(pack, indent=2), encoding="utf-8")

    sheets_made = sum(1 for it in pack["items"] if it.get("contact_sheet"))
    print(
        f"TRADE_REVIEW_PACK_OK: mode={pack['mode']}, reviewed={pack['reviewed_count']}, "
        f"sheets={sheets_made}, out={out_dir}"
    )


if __name__ == "__main__":
    main()
