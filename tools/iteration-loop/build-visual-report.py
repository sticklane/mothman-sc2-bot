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
import shutil
from pathlib import Path
from typing import Any


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
                "race", "enemy_race", "terrain", "source", "opponent_mode", "p2_bot",
                "win_type", "end_reason", "p1_combat_alive_cnt", "p2_combat_alive_cnt",
                "p2_trade_ratio", "p2_attack_unit_cmds", "p2_move_unit_cmds", "p2_spell_unit_cmds",
                "applied_p1_upgrade_ids", "applied_p2_upgrade_ids",
            ):
                if merged.get(k) in (None, "") or (k == "race" and "_" in str(merged.get(k))):
                    if extra.get(k) is not None:
                        merged[k] = extra[k]
        merged["race"] = _norm_race(merged)
        out.append(merged)
    out.sort(key=lambda x: str(x.get("id") or ""))
    return out


def _render_arena_section(
    lines: list[str],
    section_num: int,
    title: str,
    aclips: list[dict[str, Any]],
    copy_dir: Path | None,
    prefix: str,
    is_selfplay: bool,
) -> None:
    lines.append(f"## {section_num}. {title} ({len(aclips)} Micro Duels)")
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
        lines.append(f"### {race} Duels ({lbl})")
        lines.append("")
        if is_selfplay:
            lines.append("| Duel | Terrain | Winner | P1 Trade | P1 A/M/S | P2 A/M/S | Matchup Context |")
            lines.append("|---|---|---|---:|---:|---:|---|")
        else:
            lines.append("| Duel | Terrain | Winner | Trade | ATK / MOV / SPL | Matchup Context |")
            lines.append("|---|---|---|---:|---:|---|")
        for c in rclips:
            sid = str(c.get("id", "")).replace("sc2-real-", "")
            terr = str(c.get("terrain") or "open")
            tr = c.get("trade_ratio")
            tr_s = f"{float(tr):.2f}x" if tr is not None else "—"
            wt = c.get("win_type")
            win_lbl = f"**{c.get('winner', '')}** (`{wt}`)" if wt else f"**{c.get('winner', '')}**"
            cmds1 = f"{c.get('mothman_attack_unit_cmds', '—')}/{c.get('mothman_move_unit_cmds', '—')}/{c.get('mothman_spell_unit_cmds', '—')}"
            ctx = c.get("context") or c.get("description") or ""
            if is_selfplay:
                cmds2 = f"{c.get('p2_attack_unit_cmds', '—')}/{c.get('p2_move_unit_cmds', '—')}/{c.get('p2_spell_unit_cmds', '—')}"
                lines.append(f"| `{sid}` | `{terr}` | {win_lbl} | `{tr_s}` | `{cmds1}` | `{cmds2}` | {ctx} |")
            else:
                lines.append(f"| `{sid}` | `{terr}` | {win_lbl} | `{tr_s}` | `{cmds1}` | {ctx} |")
        lines.append("")

        lines.append("````carousel")
        for idx, c in enumerate(rclips):
            if idx > 0:
                lines.append("<!-- slide -->")
            webp_p = _stage_media(c.get("webp"), copy_dir, prefix=prefix)
            png_p = _stage_media(c.get("png"), copy_dir, prefix=prefix)
            sid = str(c.get("id", "")).replace("sc2-real-", "")
            terr = str(c.get("terrain") or "open")
            tr = c.get("trade_ratio")
            tr_s = f"{float(tr):.2f}x" if tr is not None else "—"
            lines.append(f"#### `{sid}` (`{terr}`) — **{c.get('winner', '')}** (`{tr_s}`)")
            lines.append("")
            if webp_p:
                lines.append(f"![{sid} animated 3D duel]({webp_p})")
            elif png_p:
                lines.append(f"![{sid} peak clash]({png_p})")
            lines.append("")
            lines.append(f"- **Scenario:** {c.get('context') or c.get('description') or ''} (`terrain={terr}`, `source={c.get('source') or 'core'}`)")
            if c.get("p1_spec") or c.get("p2_spec"):
                p2_name = c.get("p2_bot") or ("Mothman-P2" if is_selfplay else "MicroDummy")
                p1_name = c.get("bot") or ("Mothman-P1" if is_selfplay else "Mothman")
                lines.append(f"- **Forces:** {p1_name} (`{c.get('p1_spec', '')}`) vs {p2_name} (`{c.get('p2_spec', '')}`)")
            if is_selfplay:
                lines.append(
                    f"- **Wire Telemetry:** P1 `ATK={c.get('mothman_attack_unit_cmds', '—')}` / `MOV={c.get('mothman_move_unit_cmds', '—')}` / `SPL={c.get('mothman_spell_unit_cmds', '—')}` | "
                    f"P2 `ATK={c.get('p2_attack_unit_cmds', '—')}` / `MOV={c.get('p2_move_unit_cmds', '—')}` / `SPL={c.get('p2_spell_unit_cmds', '—')}` | "
                    f"Media: `{_fmt_kb(c.get('webp_bytes'))}` WebP (`{c.get('frames', 0)}`f)"
                )
            else:
                lines.append(
                    f"- **Wire Telemetry:** `ATK={c.get('mothman_attack_unit_cmds', '—')}` | "
                    f"`MOV={c.get('mothman_move_unit_cmds', '—')}` | `SPL={c.get('mothman_spell_unit_cmds', '—')}` | "
                    f"Media: `{_fmt_kb(c.get('webp_bytes'))}` WebP (`{c.get('frames', 0)}`f)"
                )
            if png_p:
                lines.append(f"- **Peak-Clash 960×720 Keyframe:** [Peak PNG](file://{png_p})")
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
) -> str:
    lines: list[str] = []
    lines.append(f"# Mothman SC2 Bot — Real-3D Gameplay Visuals ({loop_label})")
    lines.append("")
    lines.append(
        "> [!NOTE]\n"
        "> Every animated WebP (`800×600 @ 16 fps`) and Peak-Clash PNG (`960×720`) below is rendered directly by the real **StarCraft II (`SC2_x64` Base75689)** 3D engine on host AMD Radeon OpenGL/EGL — zero custom 2D drawing. On-clip overlays stay minimal (3D viewport + real SC2 minimap + single-line top-left pill); full tactical context is provided beside each clip."
    )
    lines.append("")

    aclips = _enrich_arena_clips(arena_manifest, arena_json)
    sclips = _enrich_arena_clips(selfplay_manifest, selfplay_json)

    # Top KPI banner if score_json provided
    if score_data:
        ms = score_data.get("matches") or []
        wins = sum(1 for m in ms if m.get("result") == "win")
        losses = sum(1 for m in ms if m.get("result") == "loss")
        ties = sum(1 for m in ms if m.get("result") == "tie")
        tot_k = sum(m.get("killed_val") or 0 for m in ms)
        tot_l = sum(m.get("lost_val") or 0 for m in ms)
        tr_agg = round(tot_k / max(1.0, tot_l), 2)
        lines.append("## Campaign Snapshot")
        lines.append("")
        lines.append(
            f"- **Gauntlet Record (`n={len(ms)}`):** **`{wins}W-{losses}L-{ties}T`** (`{100.0 * wins / max(1, len(ms)):.1f}%` WR) | "
            f"**Aggregate Trade:** **`{tr_agg:.2f}x`** (`{int(tot_k):,}` killed / `{int(tot_l):,}` lost)"
        )
        if replays_manifest:
            lines.append(
                f"- **Critical Replay Clips:** `{replays_manifest.get('clips_count', 0)}` clips rendered in "
                f"`{replays_manifest.get('wall_sec', 0)}s` (`{_fmt_kb(replays_manifest.get('total_webp_bytes'))}` WebP total)"
            )
        if arena_manifest and aclips:
            aw = sum(1 for c in aclips if c.get("winner") == "Mothman")
            al = sum(1 for c in aclips if c.get("winner") == "MicroDummy")
            ad = len(aclips) - aw - al
            rec_s = (arena_json.get("summary") or {}).get("record_str") if arena_json else None
            lbl_s = rec_s or f"{aw}W-{al}L-{ad}D"
            lines.append(
                f"- **Real-`SC2_x64` {len(aclips)}-Duel Tactics Arena (`--opponent dummy`):** **`{lbl_s}`** — all `{len(aclips)}` duels rendered in "
                f"`{arena_manifest.get('wall_sec', 0)}s` (`{_fmt_kb(arena_manifest.get('total_webp_bytes'))}` WebP total)"
            )
        if selfplay_manifest and sclips:
            sp1 = sum(1 for c in sclips if c.get("winner") == "Mothman-P1")
            sp2 = sum(1 for c in sclips if c.get("winner") == "Mothman-P2")
            spd = len(sclips) - sp1 - sp2
            rec_sp = (selfplay_json.get("summary") or {}).get("record_str") if selfplay_json else None
            lbl_sp = rec_sp or f"P1={sp1}W / P2={sp2}W / {spd}D"
            lines.append(
                f"- **Real-`SC2_x64` {len(sclips)}-Duel Mothman-vs-Mothman Self-Play (`--opponent self`):** **`{lbl_sp}`** — all `{len(sclips)}` duels rendered in "
                f"`{selfplay_manifest.get('wall_sec', 0)}s` (`{_fmt_kb(selfplay_manifest.get('total_webp_bytes'))}` WebP total)"
            )
        lines.append("")

    # -------------------------------------------------------------------------
    # SECTION 1: CRITICAL REPLAY MOMENTS
    # -------------------------------------------------------------------------
    if replays_manifest and replays_manifest.get("clips"):
        clips = replays_manifest["clips"]
        lines.append(f"## 1. Critical Match Moments ({len(clips)} Real-3D Replay Clips)")
        lines.append("")
        lines.append("| # | Category | Match | Map (Sym) | Window | Outcome & Trade | Clash Units Destroyed (Ours / Opp) |")
        lines.append("|---:|---|---|---|---|---|---|")
        for idx, c in enumerate(clips, start=1):
            cw = c.get("clash_window_stats") or {}
            tr = c.get("trade_ratio")
            tr_s = f"{float(tr):.2f}x" if tr is not None else "—"
            res_u = str(c.get("result") or "").upper()
            lines.append(
                f"| {idx} | **{c.get('category', '')}** | `#{c.get('match_id', '')}` `{c.get('our_bot', '')}` vs `{c.get('opp_bot', '')}` "
                f"| `{str(c.get('map', '')).replace('.SC2Map', '')}` (`{c.get('map_symmetry_kind') or '—'}`) "
                f"| `{c.get('clock_window', '')}` | **{res_u}** (`{tr_s}`) "
                f"| {_fmt_units(cw.get('p1_lost_units'))} / {_fmt_units(cw.get('p2_lost_units'))} |"
            )
        lines.append("")

        lines.append("### Animated 3D Replay Carousel")
        lines.append("")
        lines.append("````carousel")
        for idx, c in enumerate(clips):
            if idx > 0:
                lines.append("<!-- slide -->")
            webp_p = _stage_media(c.get("webp"), copy_dir, prefix="rep_")
            png_p = _stage_media(c.get("png"), copy_dir, prefix="rep_")
            cw = c.get("clash_window_stats") or {}
            tr = c.get("trade_ratio")
            tr_s = f"{float(tr):.2f}x" if tr is not None else "—"
            res_u = str(c.get("result") or "").upper()
            lines.append(
                f"#### {idx + 1}. {c.get('category', 'CLASH')}: `#{c.get('match_id', '')}` {c.get('our_bot', '')} vs {c.get('opp_bot', '')} ({res_u} · {tr_s} · `{c.get('clock_window', '')}`)"
            )
            lines.append("")
            if webp_p:
                lines.append(f"![{c.get('category', '')} animated clip]({webp_p})")
            elif png_p:
                lines.append(f"![{c.get('category', '')} peak clash]({png_p})")
            lines.append("")
            lines.append(f"- **Context:** {c.get('context', '')}")
            lines.append(f"- **What to Watch:** {c.get('what_to_watch', '')}")
            lines.append(
                f"- **Match Stats:** Map `{str(c.get('map', '')).replace('.SC2Map', '')}` | "
                f"Peak Army `{c.get('our_peak_army', '—')}` vs `{c.get('opp_peak_army', '—')}` | "
                f"Killed `{c.get('killed_val', '—')}` / Lost `{c.get('lost_val', '—')}` | "
                f"Anomalies: `{', '.join(c.get('anomalies') or []) or 'none'}` | "
                f"Media: `{_fmt_kb(c.get('webp_bytes'))}` WebP (`{c.get('frames', 0)}`f @ `{replays_manifest.get('fps', 16)}`fps)"
            )
            if png_p:
                lines.append(f"- **Peak-Clash 960×720 Keyframe (`{c.get('peak_loop', '')}`):** [Peak PNG](file://{png_p})")
        lines.append("````")
        lines.append("")

    # -------------------------------------------------------------------------
    # SECTION 2: REAL-SC2_x64 TACTICS ARENA 2.0 (--opponent dummy)
    # -------------------------------------------------------------------------
    if aclips:
        _render_arena_section(
            lines,
            section_num=2,
            title="Real-`SC2_x64` Tactics Arena 2.0 (`--opponent dummy`)",
            aclips=aclips,
            copy_dir=copy_dir,
            prefix="arena_",
            is_selfplay=False,
        )

    # -------------------------------------------------------------------------
    # SECTION 3: MOTHMAN-VS-MOTHMAN SELF-PLAY (--opponent self)
    # -------------------------------------------------------------------------
    if sclips:
        _render_arena_section(
            lines,
            section_num=3,
            title="Real-`SC2_x64` Mothman-vs-Mothman Self-Play (`--opponent self`)",
            aclips=sclips,
            copy_dir=copy_dir,
            prefix="selfplay_",
            is_selfplay=True,
        )

    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description="Build Markdown visual report with carousels from 3D SC2_x64 manifests.")
    ap.add_argument("--loop-label", required=True, help="Human-readable label (e.g. 'Loop 18 Shipped bf1043b7')")
    ap.add_argument("--score-json", default=None)
    ap.add_argument("--replays-manifest", default=None)
    ap.add_argument("--arena-manifest", default=None)
    ap.add_argument("--arena-json", default=None, help="Optional Tactics Arena dummy JSON report for terrain/source metadata")
    ap.add_argument("--selfplay-manifest", default=None, help="Optional Self-Play arena_manifest.json")
    ap.add_argument("--selfplay-json", default=None, help="Optional Tactics Arena selfplay JSON report for P2 telemetry & terrain")
    ap.add_argument("--copy-media-to", default=None, help="Optional directory to copy WebP/PNG files for artifact embedding")
    ap.add_argument("--out-md", required=True, help="Output Markdown path")
    args = ap.parse_args()

    score_data = json.loads(Path(args.score_json).read_text(encoding="utf-8")) if args.score_json and Path(args.score_json).exists() else None
    rep_man = json.loads(Path(args.replays_manifest).read_text(encoding="utf-8")) if args.replays_manifest and Path(args.replays_manifest).exists() else None
    arena_man = json.loads(Path(args.arena_manifest).read_text(encoding="utf-8")) if args.arena_manifest and Path(args.arena_manifest).exists() else None
    arena_js = json.loads(Path(args.arena_json).read_text(encoding="utf-8")) if args.arena_json and Path(args.arena_json).exists() else None
    sp_man = json.loads(Path(args.selfplay_manifest).read_text(encoding="utf-8")) if args.selfplay_manifest and Path(args.selfplay_manifest).exists() else None
    sp_js = json.loads(Path(args.selfplay_json).read_text(encoding="utf-8")) if args.selfplay_json and Path(args.selfplay_json).exists() else None
    copy_dir = Path(args.copy_media_to) if args.copy_media_to else None

    md = build_report(
        args.loop_label,
        score_data,
        rep_man,
        arena_man,
        copy_dir,
        selfplay_manifest=sp_man,
        arena_json=arena_js,
        selfplay_json=sp_js,
    )
    out_p = Path(args.out_md)
    out_p.parent.mkdir(parents=True, exist_ok=True)
    out_p.write_text(md, encoding="utf-8")
    print(f"Wrote visual report -> {out_p} ({len(md):,} chars)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
