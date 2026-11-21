#!/usr/bin/env python3
"""
tools/iteration-loop/build-visual-report.py

Builds a crisp Markdown visual showcase report combining:
  - Full-match critical replay clips (`manifest.json` from `render-replay-clips.py`)
  - All 21 real-SC2_x64 tactics-arena duels (`arena_manifest.json` from `sc2-tactics-arena.py`)
  - Optional gauntlet summary metrics from `score-replay-batch.rkt` JSON

Supports `--copy-media-to <dir>` so embedded images/animated WebPs can be copied
cleanly into an artifact directory with valid absolute paths, and renders clean
four-backtick carousels with rich narrative context per clip (units fought,
clock window, trade/outcome, why it matters, and what to watch!).

Usage:
  python3 tools/iteration-loop/build-visual-report.py \
      --loop-label "Loop 18 (Shipped bf1043b7 — 3D Visuals Proof)" \
      --score-json /path/to/iter18_wave18_score.json \
      --replays-manifest /path/to/visuals_iter18/replays/manifest.json \
      --arena-manifest /path/to/visuals_iter18/arena/arena_manifest.json \
      [--copy-media-to /path/to/artifact_dir/media] \
      --out-md /path/to/visual_report.md
"""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import sqlite3
from collections import defaultdict
from pathlib import Path
from typing import Any

DEFAULT_REPLAY_DB = Path("/home/sjaconette/sc2-local-arena/arena_replays.sqlite")


def _canon_map(raw: str | None) -> str:
    s = str(raw or "").strip()
    if not s:
        return "Unknown"
    s = re.sub(r"\.SC2Map$", "", s, flags=re.IGNORECASE)
    s = re.sub(r"[\s_-]*AIE(?:_?v\d+)?$", "", s, flags=re.IGNORECASE)
    s = re.sub(r"(?:[\s_-]+(?:LE|TE)|[\s_-]*v\d+)$", "", s, flags=re.IGNORECASE)
    s = re.sub(r"[\s_]+", "", s)
    return s or "Unknown"


def _two_prop_z(w1: int, n1: int, w2: int, n2: int) -> float:
    if n1 <= 0 or n2 <= 0:
        return 0.0
    p_pool = (w1 + w2) / (n1 + n2)
    if p_pool <= 0.0 or p_pool >= 1.0:
        return 0.0
    return ((w1 / n1) - (w2 / n2)) / math.sqrt(max(1e-12, p_pool * (1.0 - p_pool) * (1.0 / n1 + 1.0 / n2)))


def _query_longitudinal_spawn_outliers(db_path: Path | None, limit: int = 8) -> list[dict[str, Any]]:
    if not db_path or not db_path.is_file():
        return []
    try:
        conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=10.0)
        conn.row_factory = sqlite3.Row
        conn.create_function("canon_map", 1, _canon_map)
        out: list[dict[str, Any]] = []
        for scope, grp_expr in (
            ("map", "canon_map(map_name)"),
            ("matchup_map", "COALESCE(matchup, '?v?') || '|' || canon_map(map_name)"),
        ):
            rows = conn.execute(
                f"""
                SELECT {grp_expr} AS grp_key,
                       our_spawn_corner AS corner,
                       COUNT(*) AS n,
                       SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) AS w,
                       ROUND(100.0 * SUM(CASE WHEN result='win' THEN 1 ELSE 0 END) / COUNT(*), 1) AS wr_pct,
                       ROUND(AVG(sup_blk_pct), 1) AS sb_pct,
                       ROUND(SUM(COALESCE(killed_val,0)) / MAX(1.0, SUM(COALESCE(lost_val,0))), 2) AS trade_agg
                FROM matches
                WHERE our_spawn_corner IS NOT NULL AND result IN ('win','loss','tie')
                  AND is_selfplay = 0 AND is_clean = 1
                GROUP BY grp_key, our_spawn_corner
                """
            ).fetchall()
            by_g: dict[str, list[sqlite3.Row]] = defaultdict(list)
            for r in rows:
                by_g[str(r["grp_key"])].append(r)
            for grp_key, items in by_g.items():
                items.sort(key=lambda x: str(x["corner"]))
                for i in range(len(items)):
                    for j in range(i + 1, len(items)):
                        a, b = items[i], items[j]
                        na, nb = int(a["n"]), int(b["n"])
                        if min(na, nb) < 5:
                            continue
                        wra, wrb = float(a["wr_pct"] or 0.0), float(b["wr_pct"] or 0.0)
                        dw = round(wra - wrb, 1)
                        z = round(_two_prop_z(int(a["w"]), na, int(b["w"]), nb), 2)
                        sba, sbb = a["sb_pct"], b["sb_pct"]
                        sb_ratio = 1.0
                        max_sb = 0.0
                        if sba is not None and sbb is not None:
                            max_sb = max(float(sba), float(sbb))
                            sb_ratio = round(max_sb / max(0.5, min(float(sba), float(sbb))), 2) if max_sb > 0 else 1.0
                        reasons: list[str] = []
                        if abs(z) >= 1.65 or abs(dw) >= 15.0:
                            reasons.append(f"WR_GAP({dw:+.1f}pp, z={z:+.2f})")
                        if max_sb >= 6.0 and sb_ratio >= 1.8:
                            reasons.append(f"SB_RATIO({sb_ratio:.2f}x)")
                        if reasons:
                            out.append({
                                "scope": scope,
                                "key": grp_key,
                                "corners": f"{a['corner']} vs {b['corner']}",
                                "ns": f"{na}/{nb}",
                                "wrs": f"{wra}% / {wrb}%",
                                "dw": dw,
                                "z": z,
                                "sbs": f"{sba if sba is not None else '-'}% / {sbb if sbb is not None else '-'}%",
                                "trades": f"{a['trade_agg']}x / {b['trade_agg']}x",
                                "reason": ", ".join(reasons),
                            })
        conn.close()
        out.sort(key=lambda o: abs(o["z"]) * 12.0 + abs(o["dw"]), reverse=True)
        return out[:limit]
    except Exception:
        return []


def _render_spawn_watch_section(
    lines: list[str],
    score_data: dict[str, Any] | None,
    replay_db_path: Path | None,
) -> None:
    by_ms = (score_data or {}).get("by_map_spawn") or {}
    run_outliers = (score_data or {}).get("spawn_outliers") or []
    long_outliers = _query_longitudinal_spawn_outliers(replay_db_path, limit=8)
    if not by_ms and not run_outliers and not long_outliers:
        return

    lines.append("<details>")
    lines.append("<summary><strong>Detailed Map &amp; Starting-Corner Fairness Tables (for developers)</strong></summary>")
    lines.append("")
    lines.append("## Map × Spawn-Position × Matchup & Outlier Watch")
    lines.append("")
    if by_ms:
        lines.append("### Current Run Map × Spawn-Corner Breakdown (Clean External)")
        lines.append("")
        lines.append("| Map | Starting Corner | Games | Won-Lost-Tied | Win Rate | Non-Loss Rate | Army Value Traded | Time Supply-Blocked |")
        lines.append("|---|---|---:|---|---:|---:|---:|---:|")
        for k in sorted(by_ms.keys()):
            b = by_ms[k]
            lines.append(
                f"| `{b.get('map_canon', k)}` | `{b.get('corner', '?')}` | {b.get('n', 0)} "
                f"| `{b.get('wins', 0)}-{b.get('losses', 0)}-{b.get('ties', 0)}` "
                f"| {b.get('wr_pct', 0.0):.1f}% | {b.get('nl_pct', 0.0):.1f}% "
                f"| `{b.get('trade_agg', 0.0):.2f}x` | {b.get('avg_sb_pct', 0.0):.1f}% |"
            )
        lines.append("")

    if run_outliers:
        lines.append("### Current Run Spawn-Position Outliers")
        lines.append("")
        lines.append("| Scope | Key | A vs B | nA/nB | WR (A / B) | ΔWR | SB% (A / B) | Trade (A / B) | Flag |")
        lines.append("|---|---|---|---|---|---:|---|---|---|")
        for o in run_outliers[:10]:
            lines.append(
                f"| `{o.get('scope')}` | `{o.get('key')}` | `{o.get('corner_a')} vs {o.get('corner_b')}` "
                f"| `{o.get('n_a')}/{o.get('n_b')}` | `{o.get('wr_a')}% / {o.get('wr_b')}%` "
                f"| `{float(o.get('wr_delta_pp') or 0):+.1f}pp` "
                f"| `{o.get('sb_a')}% / {o.get('sb_b')}%` "
                f"| `{o.get('trade_a')}x / {o.get('trade_b')}x` | `{o.get('reason')}` |"
            )
        lines.append("")

    if long_outliers:
        lines.append("### Longitudinal SQLite Spawn-Corner Outliers (All Clean Local+Prod, min_pair_n=5)")
        lines.append("")
        lines.append("| Scope | Key | A vs B | nA/nB | WR (A / B) | ΔWR | z | SB% (A / B) | Trade (A / B) | Flag |")
        lines.append("|---|---|---|---|---|---:|---:|---|---|---|")
        for o in long_outliers:
            lines.append(
                f"| `{o['scope']}` | `{o['key']}` | `{o['corners']}` | `{o['ns']}` "
                f"| `{o['wrs']}` | `{o['dw']:+.1f}pp` | `{o['z']:+.2f}` "
                f"| `{o['sbs']}` | `{o['trades']}` | `{o['reason']}` |"
            )
        lines.append("")
    lines.append("</details>")
    lines.append("")


def _fmt_kb(n_bytes: int | None) -> str:
    if not n_bytes:
        return "0 KB"
    if n_bytes >= 1024 * 1024:
        return f"{n_bytes / (1024 * 1024):.2f} MB"
    return f"{n_bytes / 1024.0:.0f} KB"


def _stage_media(src: str | None, copy_dir: Path | None, prefix: str = "") -> str | None:
    if not src:
        return None
    sp = Path(src)
    if not sp.exists():
        return None
    if copy_dir is None:
        return str(sp.resolve())
    copy_dir.mkdir(parents=True, exist_ok=True)
    dst_name = f"{prefix}{sp.name}" if prefix else sp.name
    dst = copy_dir / dst_name
    if sp.resolve() != dst.resolve():
        shutil.copy2(sp, dst)
    return str(dst.resolve())


def _stage_clip_media(
    clip: dict[str, Any],
    copy_dir: Path | None,
    prefix: str = "",
) -> tuple[str | None, str | None, str | None, int, str]:
    """
    Stage `.mp4` (preferred), `.webp`, and `.png` poster into `copy_dir`.
    Returns `(mp4_path, webp_path, png_path, video_bytes, fmt_label)`.
    """
    raw_mp4 = clip.get("mp4")
    raw_webp = clip.get("webp")
    raw_vid = clip.get("video")
    if not raw_mp4 and raw_vid and str(raw_vid).lower().endswith(".mp4"):
        raw_mp4 = raw_vid
    if not raw_webp and raw_vid and str(raw_vid).lower().endswith(".webp"):
        raw_webp = raw_vid

    mp4_p = _stage_media(raw_mp4, copy_dir, prefix=prefix)
    webp_p = _stage_media(raw_webp, copy_dir, prefix=prefix)
    png_p = _stage_media(clip.get("png"), copy_dir, prefix=prefix)

    if mp4_p:
        v_bytes = int(clip.get("mp4_bytes") or clip.get("video_bytes") or 0)
        return mp4_p, webp_p, png_p, v_bytes, "MP4"
    v_bytes = int(clip.get("webp_bytes") or clip.get("video_bytes") or 0)
    return None, webp_p, png_p, v_bytes, "WebP"


def _embed_media_player(
    mp4_p: str | None,
    webp_p: str | None,
    png_p: str | None,
    alt_text: str,
) -> str:
    if mp4_p:
        poster_attr = f' poster="{png_p}"' if png_p else ""
        return f'<video controls preload="none" playsinline{poster_attr} src="{mp4_p}"></video>'
    if webp_p:
        return f"![{alt_text}]({webp_p})"
    if png_p:
        return f"![{alt_text}]({png_p})"
    return ""


def _fmt_dur(sec: float | int | None) -> str:
    if sec is None:
        return "—"
    s = max(0, int(round(float(sec))))
    return f"{s // 60:02d}:{s % 60:02d}"


def _human_cohort(cohort: str | None) -> str:
    c = str(cohort or "").strip().lower()
    if c in ("baseline_h2h", "h2h"):
        return "Head-to-Head vs Live Bot"
    if c.startswith("core"):
        return "Core Opponents"
    if c.startswith("unseen"):
        return "Unseen Opponents"
    if c == "selfplay":
        return "Bot-vs-Bot Practice"
    return cohort or "Match"


def _fmt_units(pairs: list[Any] | None) -> str:
    if not pairs:
        return "—"
    return ", ".join(f"{cnt}× {name}" for name, cnt in pairs)


def _norm_race(clip: dict[str, Any]) -> str:
    raw = str(clip.get("race") or "").split("_")[0]
    if raw in ("Protoss", "Terran", "Zerg"):
        return raw
    sid = str(clip.get("id") or "").replace("sc2-real-", "")
    if sid.startswith("p"):
        return "Protoss"
    if sid.startswith("t"):
        return "Terran"
    if sid.startswith("z"):
        return "Zerg"
    return raw or "Other"


def _enrich_arena_clips(
    manifest: dict[str, Any] | None,
    duel_json: dict[str, Any] | None,
) -> list[dict[str, Any]]:
    if not manifest or not manifest.get("clips"):
        return []
    by_id: dict[str, dict[str, Any]] = {}
    if duel_json:
        for s in duel_json.get("scenarios") or []:
            if s.get("id"):
                by_id[str(s["id"])] = s
    out: list[dict[str, Any]] = []
    for c in manifest["clips"]:
        merged = dict(c)
        extra = by_id.get(str(c.get("id") or ""))
        if extra:
            for k in (
                "race", "enemy_race", "terrain", "source", "tier", "scoring_mode",
                "opponent_mode", "p2_bot", "win_type", "end_reason",
                "p1_combat_alive_cnt", "p2_combat_alive_cnt",
                "p2_trade_ratio", "p2_attack_unit_cmds", "p2_move_unit_cmds", "p2_spell_unit_cmds",
                "applied_p1_upgrade_ids", "applied_p2_upgrade_ids",
                "minerals_gathered", "mining_uptime_pct", "workers_lost",
                "enemy_killed_val", "net_econ_score", "pass_net_econ_min",
            ):
                if merged.get(k) in (None, "") or (k == "race" and "_" in str(merged.get(k))):
                    if extra.get(k) is not None:
                        merged[k] = extra[k]
        merged["race"] = _norm_race(merged)
        out.append(merged)
    out.sort(key=lambda x: str(x.get("id") or ""))
    return out


def _render_full_matches_section(
    lines: list[str],
    section_num: int,
    full_manifest: dict[str, Any],
    copy_dir: Path | None,
) -> None:
    clips = full_manifest.get("clips") or []
    if not clips:
        return
    tot_mb = (full_manifest.get("total_mp4_bytes") or full_manifest.get("total_video_bytes") or 0) / (1024 * 1024)
    lines.append(f"## {section_num}. Complete Match Video Library (All {len(clips)} Full-Length `00:00 → GG` Replays)")
    lines.append("")
    lines.append(
        f"Every single match from this test run is recorded start-to-finish (`00:00 → GG`, live player names, team colors, workers, supply, and game clock — `{tot_mb:.1f} MB` total H.264 MP4). Click any match below to watch the full replay or jump to its peak battle screenshot."
    )
    lines.append("")
    lines.append("| Match | Group | Matchup | Opponent | Map (Corner) | Outcome | Army Value Traded | Length | Time Supply-Blocked | Watch Full Game |")
    lines.append("|---|---|---|---|---|---|---:|---:|---:|---|")
    for c in clips:
        mp4_p, webp_p, png_p, v_bytes, v_fmt = _stage_clip_media(c, copy_dir, prefix="full_")
        vid_p = mp4_p or webp_p
        mid = str(c.get("match_id") or "")
        grp = _human_cohort(c.get("cohort"))
        mu = str(c.get("matchup") or "—")
        opp = str(c.get("opp_bot") or c.get("p2_name") or "—")
        mname = _canon_map(c.get("map_canon") or c.get("map"))
        corner = str(c.get("our_spawn_corner") or "")
        map_col = f"`{mname}` ({corner})" if corner else f"`{mname}`"
        res_u = str(c.get("result") or "").upper()
        tr = c.get("trade_ratio")
        tr_s = f"`{float(tr):.2f}x`" if tr is not None else "—"
        dur_s = _fmt_dur(c.get("duration_sec"))
        sb = (
            c.get("supply_block_pct")
            if c.get("supply_block_pct") is not None
            else c.get("supply_blocked_pct")
        )
        sb_s = f"{float(sb):.1f}%" if sb is not None else "—"
        links: list[str] = []
        if vid_p:
            links.append(f"[Watch {v_fmt} ({_fmt_kb(v_bytes)})](file://{vid_p})")
        if png_p:
            links.append(f"[Poster](file://{png_p})")
        link_s = " · ".join(links) or "—"
        lines.append(
            f"| `#{mid}` | {grp} | `{mu}` | `{opp}` | {map_col} | **{res_u}** | {tr_s} | `{dur_s}` | {sb_s} | {link_s} |"
        )
    lines.append("")


def _render_arena_section(
    lines: list[str],
    section_num: int,
    title: str,
    aclips: list[dict[str, Any]],
    copy_dir: Path | None,
    prefix: str,
    is_selfplay: bool,
) -> None:
    lines.append(f"## {section_num}. {title} ({len(aclips)} Full-Length Battle Drills)")
    lines.append("")
    by_race: dict[str, list[dict[str, Any]]] = {"Protoss": [], "Terran": [], "Zerg": []}
    for c in aclips:
        by_race.setdefault(_norm_race(c), []).append(c)

    p1_win_tags = ("Mothman-P1",) if is_selfplay else ("Mothman",)
    p2_win_tags = ("Mothman-P2",) if is_selfplay else ("MicroDummy",)

    for race in ("Protoss", "Terran", "Zerg"):
        rclips = by_race.get(race) or []
        if not rclips:
            continue
        rw = sum(1 for c in rclips if c.get("winner") in p1_win_tags)
        rl = sum(1 for c in rclips if c.get("winner") in p2_win_tags)
        rd = len(rclips) - rw - rl
        has_honest = any(c.get("win_type") for c in rclips)
        d_ch = "D" if has_honest else "T"
        lbl = f"`P1={rw}W / P2={rl}W / {rd}{d_ch}`" if is_selfplay else f"`{rw}W-{rl}L-{rd}{d_ch}`"
        lines.append(f"### {race} Drills ({lbl})")
        lines.append("")

        staged_rows: list[tuple[dict[str, Any], str | None, str | None, str | None, int, str]] = []
        for c in rclips:
            mp4_p, webp_p, png_p, v_bytes, v_fmt = _stage_clip_media(c, copy_dir, prefix=prefix)
            staged_rows.append((c, mp4_p, webp_p, png_p, v_bytes, v_fmt))

        lines.append("| Drill | Terrain | Outcome | Army Value Traded | Watch Video | Scenario Summary |")
        lines.append("|---|---|---|---:|---|---|")
        for c, mp4_p, webp_p, png_p, v_bytes, v_fmt in staged_rows:
            sid = str(c.get("id", "")).replace("sc2-real-", "").replace("sc2-econ-", "").replace("sc2-reg-", "")
            terr = str(c.get("terrain") or "open")
            tr = c.get("trade_ratio")
            tr_s = f"{float(tr):.2f}x" if tr is not None else "—"
            wt = c.get("win_type")
            win_lbl = f"**{c.get('winner', '')}** (`{wt}`)" if wt else f"**{c.get('winner', '')}**"
            vid_p = mp4_p or webp_p
            vlink = f"[Watch {v_fmt}](file://{vid_p})" if vid_p else "—"
            ctx = c.get("description") or c.get("context") or ""
            lines.append(f"| `{sid}` | `{terr}` | {win_lbl} | `{tr_s}` | {vlink} | {ctx} |")
        lines.append("")

        lines.append("````carousel")
        for idx, (c, mp4_p, webp_p, png_p, v_bytes, v_fmt) in enumerate(staged_rows):
            if idx > 0:
                lines.append("<!-- slide -->")
            sid = str(c.get("id", "")).replace("sc2-real-", "").replace("sc2-econ-", "").replace("sc2-reg-", "")
            terr = str(c.get("terrain") or "open")
            tr = c.get("trade_ratio")
            tr_s = f"{float(tr):.2f}x" if tr is not None else "—"
            lines.append(f"#### `{sid}` (`{terr}`) — **{c.get('winner', '')}** (`{tr_s}`)")
            lines.append("")
            embed = _embed_media_player(mp4_p, webp_p, png_p, f"{sid} 3D drill")
            if embed:
                lines.append(embed)
                lines.append("")
            lines.append(f"- **Scenario:** {c.get('description') or c.get('context') or ''} (`terrain={terr}`)")
            if c.get("p1_spec") or c.get("p2_spec"):
                p2_name = c.get("p2_name") or c.get("p2_bot") or ("Mothman-P2" if is_selfplay else "MicroDummy")
                p1_name = c.get("p1_name") or c.get("bot") or ("Mothman-P1" if is_selfplay else "Mothman")
                lines.append(f"- **Armies:** {p1_name} (`{c.get('p1_spec', '')}`) vs {p2_name} (`{c.get('p2_spec', '')}`)")
            if is_selfplay:
                lines.append(
                    f"- **Developer Telemetry:** P1 `ATK={c.get('mothman_attack_unit_cmds', '—')}` / `MOV={c.get('mothman_move_unit_cmds', '—')}` / `SPL={c.get('mothman_spell_unit_cmds', '—')}` | "
                    f"P2 `ATK={c.get('p2_attack_unit_cmds', '—')}` / `MOV={c.get('p2_move_unit_cmds', '—')}` / `SPL={c.get('p2_spell_unit_cmds', '—')}` | "
                    f"Media: `{_fmt_kb(v_bytes)}` {v_fmt} (`{c.get('frames', 0)}`f)"
                )
            else:
                lines.append(
                    f"- **Developer Telemetry:** `ATK={c.get('mothman_attack_unit_cmds', '—')}` | "
                    f"`MOV={c.get('mothman_move_unit_cmds', '—')}` | `SPL={c.get('mothman_spell_unit_cmds', '—')}` | "
                    f"Media: `{_fmt_kb(v_bytes)}` {v_fmt} (`{c.get('frames', 0)}`f)"
                )
            if png_p:
                lines.append(f"- **Peak Battle Screenshot (960×720):** [Peak PNG](file://{png_p})")
        lines.append("````")
        lines.append("")


def build_report(
    loop_label: str,
    score_data: dict[str, Any] | None,
    replays_manifest: dict[str, Any] | None,
    arena_manifest: dict[str, Any] | None,
    copy_dir: Path | None,
    selfplay_manifest: dict[str, Any] | None = None,
    arena_json: dict[str, Any] | None = None,
    selfplay_json: dict[str, Any] | None = None,
    full_matches_manifest: dict[str, Any] | None = None,
    replay_db_path: Path | None = DEFAULT_REPLAY_DB,
) -> str:
    lines: list[str] = []
    lines.append(f"# Mothman SC2 Bot — Match Videos & Battle Highlights ({loop_label})")
    lines.append("")
    lines.append(
        "> [!NOTE]\n"
        "> Every video and screenshot below is recorded directly inside the real **StarCraft II** 3D game engine with a live spectator HUD showing player names, team colors, live worker counts, supply (`used/cap`), game clock, and the real in-game minimap."
    )
    lines.append("")

    aclips = _enrich_arena_clips(arena_manifest, arena_json)
    sclips = _enrich_arena_clips(selfplay_manifest, selfplay_json)
    fclips = (full_matches_manifest or {}).get("clips") or []

    # Plain-English Executive Snapshot ("How Our Bots Played")
    if score_data:
        ms = score_data.get("matches") or []
        wins = sum(1 for m in ms if m.get("result") == "win")
        losses = sum(1 for m in ms if m.get("result") == "loss")
        ties = sum(1 for m in ms if m.get("result") == "tie")
        tot_k = sum(m.get("killed_val") or 0 for m in ms)
        tot_l = sum(m.get("lost_val") or 0 for m in ms)
        tr_agg = round(tot_k / max(1.0, tot_l), 2)
        sb_vals = [
            float(v)
            for m in ms
            for v in (
                m.get("supply_block_pct")
                if m.get("supply_block_pct") is not None
                else m.get("supply_blocked_pct"),
            )
            if v is not None
        ]
        avg_sb = sum(sb_vals) / max(1, len(sb_vals)) if sb_vals else 0.0
        lines.append("## How Our Bots Played (Plain-English Summary)")
        lines.append("")
        lines.append(
            f"- **Local Test Record (`{len(ms)}` matches):** **`{wins} Wins – {losses} Losses – {ties} Ties`** "
            f"(`{100.0 * wins / max(1, len(ms)):.1f}%` Win Rate, `{100.0 * (wins + ties) / max(1, len(ms)):.1f}%` Win-or-Tie)"
        )
        lines.append(
            f"- **Army Value Traded:** **`{tr_agg:.2f}×`** "
            f"(`{int(tot_k):,}` enemy resources destroyed vs `{int(tot_l):,}` lost) | "
            f"**Time Supply-Blocked:** **`{avg_sb:.1f}%`** *(lower is better — goal `< 6%`)*"
        )
        if replays_manifest:
            rv_fmt = str(replays_manifest.get("video_format") or "webp").upper()
            rv_b = replays_manifest.get("total_mp4_bytes") or replays_manifest.get("total_video_bytes") or replays_manifest.get("total_webp_bytes")
            lines.append(
                f"- **Featured Battle Highlights:** `{replays_manifest.get('clips_count', 0)}` extended clips "
                f"(`{_fmt_kb(rv_b)}` {rv_fmt} total)"
            )
        if full_matches_manifest and fclips:
            fv_b = full_matches_manifest.get("total_mp4_bytes") or full_matches_manifest.get("total_video_bytes")
            lines.append(
                f"- **Complete Full-Length Match Library:** **`{len(fclips)}` full `00:00 → GG` replays** "
                f"(`{_fmt_kb(fv_b)}` MP4 total)"
            )
        if arena_manifest and aclips:
            aw = sum(1 for c in aclips if c.get("winner") == "Mothman")
            al = sum(1 for c in aclips if c.get("winner") == "MicroDummy")
            ad = len(aclips) - aw - al
            av_fmt = str(arena_manifest.get("video_format") or "webp").upper()
            av_b = arena_manifest.get("total_mp4_bytes") or arena_manifest.get("total_video_bytes") or arena_manifest.get("total_webp_bytes")
            lines.append(
                f"- **Battle Micro Drills (`{len(aclips)}` scenarios vs Practice AI):** **`{aw}W–{al}L–{ad}D`** "
                f"(`{_fmt_kb(av_b)}` {av_fmt} total)"
            )
        if selfplay_manifest and sclips:
            sp1 = sum(1 for c in sclips if c.get("winner") == "Mothman-P1")
            sp2 = sum(1 for c in sclips if c.get("winner") == "Mothman-P2")
            spd = len(sclips) - sp1 - sp2
            sv_fmt = str(selfplay_manifest.get("video_format") or "webp").upper()
            sv_b = selfplay_manifest.get("total_mp4_bytes") or selfplay_manifest.get("total_video_bytes") or selfplay_manifest.get("total_webp_bytes")
            lines.append(
                f"- **Bot-vs-Bot Practice Drills (`{len(sclips)}` scenarios):** **`P1 {sp1}W / P2 {sp2}W / {spd}D`** "
                f"(`{_fmt_kb(sv_b)}` {sv_fmt} total)"
            )
        lines.append("")
        lines.append("<details>")
        lines.append("<summary><strong>Quick Guide to Terms (plain English)</strong></summary>")
        lines.append("")
        lines.append("- **Army Value Traded (`Trade Ratio`):** How much enemy army/building value our bot destroys for every 1 resource it loses (`1.00×` = even, `2.00×` = destroys twice as much as it loses).")
        lines.append("- **Time Supply-Blocked:** Percentage of the game where our bot forgot to build enough supply (Pylons, Supply Depots, or Overlords) and temporarily couldn't train new units. Lower is better.")
        lines.append("- **Core vs Unseen Opponents:** *Core* bots are 14 familiar benchmark opponents we track every round; *Unseen* bots are 12 held-out opponents we never tune against directly, proving real skill rather than memorization.")
        lines.append("- **Head-to-Head Ship Gate:** Before releasing a new update to the live AI Arena ladder, the new bot must defeat our currently live bot head-to-head across all matchups.")
        lines.append("- **Battle Micro Drills (Tactics Arena):** Focused short battles testing one specific StarCraft II skill at a time (spellcasting, defending worker harassment, flanking siege tanks, or replaying real ladder losses).")
        lines.append("")
        lines.append("</details>")
        lines.append("")

    # -------------------------------------------------------------------------
    # SECTION 1: FEATURED KEY-MOMENT BATTLE HIGHLIGHTS
    # -------------------------------------------------------------------------
    sec_idx = 1
    if replays_manifest and replays_manifest.get("clips"):
        clips = replays_manifest["clips"]
        lines.append(f"## {sec_idx}. Featured Battle Highlights ({len(clips)} Extended 3D Clips)")
        lines.append("")
        lines.append("| # | Highlight | Match | Map | Clock Window | Outcome & Trade | Key Units Lost (Ours / Opponent) |")
        lines.append("|---:|---|---|---|---|---|---|")
        for idx, c in enumerate(clips, start=1):
            cw = c.get("clash_window_stats") or {}
            tr = c.get("trade_ratio")
            tr_s = f"{float(tr):.2f}x" if tr is not None else "—"
            res_u = str(c.get("result") or "").upper()
            mname = _canon_map(c.get("map"))
            lines.append(
                f"| {idx} | **{c.get('category', '')}** | `#{c.get('match_id', '')}` `{c.get('our_bot', '')}` vs `{c.get('opp_bot', '')}` "
                f"| `{mname}` | `{c.get('clock_window', '')}` | **{res_u}** (`{tr_s}`) "
                f"| {_fmt_units(cw.get('p1_lost_units'))} / {_fmt_units(cw.get('p2_lost_units'))} |"
            )
        lines.append("")

        lines.append("### Watch Featured Highlights")
        lines.append("")
        lines.append("````carousel")
        for idx, c in enumerate(clips):
            if idx > 0:
                lines.append("<!-- slide -->")
            mp4_p, webp_p, png_p, v_bytes, v_fmt = _stage_clip_media(c, copy_dir, prefix="rep_")
            tr = c.get("trade_ratio")
            tr_s = f"{float(tr):.2f}x" if tr is not None else "—"
            res_u = str(c.get("result") or "").upper()
            lines.append(
                f"#### {idx + 1}. {c.get('category', 'CLASH')}: `#{c.get('match_id', '')}` {c.get('our_bot', '')} vs {c.get('opp_bot', '')} ({res_u} · {tr_s} · `{c.get('clock_window', '')}`)"
            )
            lines.append("")
            embed = _embed_media_player(mp4_p, webp_p, png_p, f"{c.get('category', '')} clip")
            if embed:
                lines.append(embed)
                lines.append("")
            lines.append(f"- **What Happened:** {c.get('context', '')}")
            lines.append(f"- **What to Watch:** {c.get('what_to_watch', '')}")
            lines.append(
                f"- **Match Stats:** Map `{_canon_map(c.get('map'))}` | "
                f"Peak Army `{c.get('our_peak_army', '—')}` vs `{c.get('opp_peak_army', '—')}` | "
                f"Value Destroyed `{c.get('killed_val', '—')}` / Lost `{c.get('lost_val', '—')}` | "
                f"Media: `{_fmt_kb(v_bytes)}` {v_fmt} (`{c.get('frames', 0)}`f @ `{replays_manifest.get('fps', 16)}`fps)"
            )
            if png_p:
                lines.append(f"- **Peak Battle Screenshot (960×720):** [Peak PNG](file://{png_p})")
        lines.append("````")
        lines.append("")
        sec_idx += 1

    # -------------------------------------------------------------------------
    # SECTION 2: COMPLETE FULL-LENGTH 00:00 -> GG MATCH VIDEO LIBRARY (90/90)
    # -------------------------------------------------------------------------
    if full_matches_manifest and fclips:
        _render_full_matches_section(lines, sec_idx, full_matches_manifest, copy_dir)
        sec_idx += 1

    # -------------------------------------------------------------------------
    # COLLAPSIBLE DEVELOPER TELEMETRY: SPAWN FAIRNESS & 3-TIER ARENA BREAKDOWN
    # -------------------------------------------------------------------------
    _render_spawn_watch_section(lines, score_data, replay_db_path)

    a_tiers = ((arena_json or {}).get("summary") or {}).get("by_tier") or {}
    sp_tiers = ((selfplay_json or {}).get("summary") or {}).get("by_tier") or {}
    if a_tiers or sp_tiers:
        lines.append("<details>")
        lines.append("<summary><strong>Detailed 3-Tier Tactics Drills &amp; Mineral-Defense Tables (for developers)</strong></summary>")
        lines.append("")
        lines.append("## 3-Tier Tactics Arena 2.0 Summary (`canonical` / `econ-harass` / `regression`)")
        lines.append("")
        lines.append("| Tier | Dummy Record | Dummy Trade / A:M | Self-Play Record | SP Trade / A:M |")
        lines.append("|---|---|---|---|---|")
        for tname in ("canonical", "econ-harass", "regression"):
            at = a_tiers.get(tname) or {}
            st = sp_tiers.get(tname) or {}
            if not at and not st:
                continue
            a_rec = at.get("record_str", "—")
            s_rec = st.get("record_str", "—")
            if tname == "econ-harass":
                a_m = f"`net={at.get('avg_net_econ_score', 0):+.1f}M, mined={at.get('avg_minerals_gathered', 0):.0f}M, up={at.get('avg_mining_uptime_pct', 0):.1f}%`" if at else "—"
                s_m = f"`net={st.get('avg_net_econ_score', 0):+.1f}M, mined={st.get('avg_minerals_gathered', 0):.0f}M, up={st.get('avg_mining_uptime_pct', 0):.1f}%`" if st else "—"
            else:
                a_m = f"`{at.get('agg_trade_ratio', 0):.2f}x` / `A:M {at.get('am_ratio', 0):.2f}`" if at else "—"
                s_m = f"`{st.get('agg_trade_ratio', 0):.2f}x` / `A:M {st.get('am_ratio', 0):.2f}`" if st else "—"
            lines.append(f"| **`{tname}`** | `{a_rec}` | {a_m} | `{s_rec}` | {s_m} |")
        lines.append("")

        econ_d = [s for s in ((arena_json or {}).get("scenarios") or []) if s.get("tier") == "econ-harass"]
        econ_sp = {str(s.get("id")): s for s in ((selfplay_json or {}).get("scenarios") or []) if s.get("tier") == "econ-harass"}
        if econ_d:
            lines.append("### Tier 2 Worker Harassment Defense Results")
            lines.append("")
            lines.append("| Drill | Target Net | vs Practice AI (Mined / Uptime / Workers Lost / Net) | Bot-vs-Bot (Mined / Uptime / Workers Lost / Net) |")
            lines.append("|---|---:|---|---|")
            for s in econ_d:
                sid = str(s.get("id", ""))
                short_id = sid.replace("sc2-econ-", "")
                tgt = s.get("pass_net_econ_min")
                tgt_s = f"`>= {tgt}M`" if tgt is not None else "—"
                d_ok = "PASS" if s.get("win_type") == "econ_pass" else "FAIL"
                d_str = f"**{d_ok}** (`{s.get('minerals_gathered', 0):.0f}M` / `{s.get('mining_uptime_pct', 0):.1f}%` / `{s.get('workers_lost', 0)}w` / `{s.get('net_econ_score', 0):+.0f}M`)"
                sp_s = econ_sp.get(sid)
                if sp_s:
                    sp_ok = "PASS" if sp_s.get("win_type") == "econ_pass" else "FAIL"
                    s_str = f"**{sp_ok}** (`{sp_s.get('minerals_gathered', 0):.0f}M` / `{sp_s.get('mining_uptime_pct', 0):.1f}%` / `{sp_s.get('workers_lost', 0)}w` / `{sp_s.get('net_econ_score', 0):+.0f}M`)"
                else:
                    s_str = "—"
                lines.append(f"| `{short_id}` | {tgt_s} | {d_str} | {s_str} |")
            lines.append("")
        lines.append("</details>")
        lines.append("")

    # -------------------------------------------------------------------------
    # SECTION 3: TACTICS ARENA DRILLS (--opponent dummy)
    # -------------------------------------------------------------------------
    if aclips:
        _render_arena_section(
            lines,
            section_num=sec_idx,
            title="Battle Micro Drills (vs Practice AI)",
            aclips=aclips,
            copy_dir=copy_dir,
            prefix="arena_",
            is_selfplay=False,
        )
        sec_idx += 1

    # -------------------------------------------------------------------------
    # SECTION 4: MOTHMAN-VS-MOTHMAN SELF-PLAY DRILLS (--opponent self)
    # -------------------------------------------------------------------------
    if sclips:
        _render_arena_section(
            lines,
            section_num=sec_idx,
            title="Bot-vs-Bot Practice Drills (Mothman vs Mothman)",
            aclips=sclips,
            copy_dir=copy_dir,
            prefix="selfplay_",
            is_selfplay=True,
        )

    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="Build plain-English Markdown visual report with HTML5 MP4 video players from 3D SC2_x64 manifests.")
    ap.add_argument("--loop-label", required=True, help="Human-readable label (e.g. 'Loop 42 Ship #5')")
    ap.add_argument("--score-json", default=None)
    ap.add_argument("--replays-manifest", default=None)
    ap.add_argument("--full-matches-manifest", default=None, help="Optional full_matches_manifest.json (all 90/90 full-length 00:00->GG MP4s)")
    ap.add_argument("--arena-manifest", default=None)
    ap.add_argument("--arena-json", default=None, help="Optional Tactics Arena dummy JSON report for terrain/source metadata")
    ap.add_argument("--selfplay-manifest", default=None, help="Optional Self-Play arena_manifest.json")
    ap.add_argument("--selfplay-json", default=None, help="Optional Tactics Arena selfplay JSON report for P2 telemetry & terrain")
    ap.add_argument("--copy-media-to", default=None, help="Optional directory to copy MP4/WebP/PNG files for artifact embedding")
    ap.add_argument("--replay-db", default=str(DEFAULT_REPLAY_DB), help="SQLite replay DB for longitudinal spawn outlier table")
    ap.add_argument("--out-md", required=True, help="Output Markdown path")
    args = ap.parse_args()

    score_data = json.loads(Path(args.score_json).read_text(encoding="utf-8")) if args.score_json and Path(args.score_json).exists() else None
    rep_man = json.loads(Path(args.replays_manifest).read_text(encoding="utf-8")) if args.replays_manifest and Path(args.replays_manifest).exists() else None
    full_man = json.loads(Path(args.full_matches_manifest).read_text(encoding="utf-8")) if args.full_matches_manifest and Path(args.full_matches_manifest).exists() else None
    arena_man = json.loads(Path(args.arena_manifest).read_text(encoding="utf-8")) if args.arena_manifest and Path(args.arena_manifest).exists() else None
    arena_js = json.loads(Path(args.arena_json).read_text(encoding="utf-8")) if args.arena_json and Path(args.arena_json).exists() else None
    sp_man = json.loads(Path(args.selfplay_manifest).read_text(encoding="utf-8")) if args.selfplay_manifest and Path(args.selfplay_manifest).exists() else None
    sp_js = json.loads(Path(args.selfplay_json).read_text(encoding="utf-8")) if args.selfplay_json and Path(args.selfplay_json).exists() else None
    copy_dir = Path(args.copy_media_to) if args.copy_media_to else None
    rdb_path = Path(args.replay_db) if args.replay_db else None

    md = build_report(
        args.loop_label,
        score_data,
        rep_man,
        arena_man,
        copy_dir,
        selfplay_manifest=sp_man,
        arena_json=arena_js,
        selfplay_json=sp_js,
        full_matches_manifest=full_man,
        replay_db_path=rdb_path,
    )
    out_p = Path(args.out_md)
    out_p.parent.mkdir(parents=True, exist_ok=True)
    out_p.write_text(md, encoding="utf-8")
    print(f"Wrote visual report -> {out_p} ({len(md):,} chars)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
