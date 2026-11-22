#!/usr/bin/env python3
"""
Atomic producer for `/home/sjaconette/repos/mothman-sc2-bot/scratch/dashboard_state.json`,
consumed statically by the `mothman-dashboard` Antigravity UI plugin.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path("/home/sjaconette/repos/mothman-sc2-bot")
DEFAULT_OUT = REPO_ROOT / "scratch" / "dashboard_state.json"
RUNS_DIR = Path("/home/sjaconette/sc2-local-arena/runs")
BRAIN_SCRATCH = Path("/home/sjaconette/.gemini/antigravity/brain/d28d22f4-2d13-41e2-9b7b-32757f58523b/scratch")
AIARENA_SUMMARY = Path("/tmp/aiarena_v1_v2_fetch/all_bots_summary.json")
AIARENA_META_DIR = Path("/tmp/aiarena_v1_v2_fetch")
ARENA_DIR = BRAIN_SCRATCH / "loop" / "iter58_arena"
PRO_CURVES_JSON = BRAIN_SCRATCH / "pro_curves_and_timings.json"


def fmt_game_time(loops: int | float | None, secs: float | None = None) -> str:
    if secs is not None and secs > 0:
        s = int(round(float(secs)))
        return f"{s // 60:02d}:{s % 60:02d}"
    if not loops or loops <= 0:
        return "00:00"
    s = int(round(float(loops) / 22.4))
    return f"{s // 60:02d}:{s % 60:02d}"


def load_json_safe(path: Path) -> Any:
    try:
        if path.is_file():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        pass
    return None


def collect_aiarena_live() -> dict[str, Any]:
    data = load_json_safe(AIARENA_SUMMARY)
    if not isinstance(data, dict):
        return {"updated_label": "", "bots": []}

    opp_elos: dict[str, list[int]] = {}
    for mp in glob.glob(str(AIARENA_META_DIR / "*_meta.json")):
        m = load_json_safe(Path(mp))
        if not isinstance(m, dict):
            continue
        bname = m.get("our_bot_name")
        oelo = m.get("opp_elo_before")
        if bname and isinstance(oelo, (int, float)) and oelo > 0 and not m.get("both_ours"):
            opp_elos.setdefault(bname, []).append(int(oelo))

    order = [
        "Mothman-P2", "Mothman-T2", "Mothman-Z2", "Mothman-X2",
        "Mothman-T", "Mothman-P", "Mothman-X", "Mothman-Z",
    ]
    by_name = {b.get("name"): b for b in data.get("bots", []) if isinstance(b, dict)}
    rows = []
    for name in order:
        b = by_name.get(name)
        if not b:
            continue
        cp = b.get("competition_participation") or {}
        cohort = "v2" if name.endswith("2") else "v1"
        elos = opp_elos.get(name, [])
        avg_opp = round(sum(elos) / len(elos)) if elos else None
        w = cp.get("win_count", 0)
        l = cp.get("loss_count", 0)
        t = cp.get("tie_count", 0)
        rows.append({
            "name": name,
            "cohort": cohort,
            "elo": cp.get("elo", "--"),
            "division": cp.get("division_num", "--"),
            "record": f"{w}W-{l}L-{t}T",
            "crashes": cp.get("crash_count", 0),
            "avg_opp_elo": avg_opp,
        })
    return {
        "updated_label": "Comp #38 · Ship #10 synced v1+v2",
        "bots": rows,
    }


def pretty_batch_label(raw: str) -> str:
    m = re.match(r"iter(\d+[a-z]?)_(?:ship(\d+)_)?(.+)", raw, flags=re.I)
    if not m:
        return raw
    loop_n, ship_n, rest = m.group(1).upper(), m.group(2), m.group(3).replace("_", " ")
    if ship_n:
        return f"Loop {loop_n} (Ship #{ship_n})"
    return f"Loop {loop_n} · {rest}"


def pretty_sig(sig: str) -> str:
    s = str(sig).strip()
    m = re.match(r"^([A-Z0-9_]+)(?:\((.*)\))?$", s)
    if not m:
        return s
    head = m.group(1).replace("_", " ").lower().capitalize()
    body = (m.group(2) or "").strip()
    if len(body) > 26:
        body = body[:24] + "…"
    return f"{head} ({body})" if body else head


def scan_live_and_recent_matches(max_matches: int = 84) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    running: list[dict[str, Any]] = []
    now_ms = int(time.time() * 1000)

    if RUNS_DIR.is_dir():
        run_dirs = sorted(
            [p for p in RUNS_DIR.iterdir() if p.is_dir()],
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        for rd in run_dirs[:2]:
            workdirs = rd / "workdirs"
            if not workdirs.is_dir():
                continue
            for wd in sorted(workdirs.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
                if not wd.is_dir():
                    continue
                live_json = load_json_safe(wd / "logs" / "live_match_status.json")
                if isinstance(live_json, dict):
                    age_ms = now_ms - int(live_json.get("updated_at_epoch_ms") or 0)
                    if live_json.get("status") == "running" and age_ms < 120_000:
                        running.append(live_json)
                        continue
                # Fallback: check fresh (<90s) Mothman log inside active workdir
                if (time.time() - wd.stat().st_mtime) > 90:
                    continue
                m_logs = list((wd / "logs").glob("*Mothman*.log")) if (wd / "logs").is_dir() else []
                if not m_logs:
                    continue
                try:
                    tail = m_logs[0].read_text(encoding="utf-8", errors="ignore")[-4096:]
                except Exception:
                    continue
                pri = re.findall(r"\[SCBOT_PRIORITY\] f=(\d+) race=(\w+) bank=(\d+)M/(\d+)G sup=(\d+)/(\d+)", tail)
                if not pri:
                    continue
                frame, race, _m, _g, sup, cap = pri[-1]
                parts = wd.name.split("_")
                running.append({
                    "match_id": parts[0] if parts else wd.name,
                    "mode": "live",
                    "map": "_".join(parts[4:]) if len(parts) > 4 else "",
                    "our_bot": parts[1] if len(parts) > 1 else "Mothman",
                    "our_race": race[0].upper(),
                    "opp_bot": parts[3] if len(parts) > 3 else "Opponent",
                    "opp_race": "?",
                    "status": "running",
                    "game_loop": int(frame),
                    "game_time_str": fmt_game_time(int(frame)),
                    "our_supply": int(sup),
                    "our_supply_cap": int(cap),
                })

    # Find newest full/h2h score JSON across brain scratch & repo scratch
    candidates: list[Path] = []
    for base in (BRAIN_SCRATCH, REPO_ROOT / "scratch"):
        if base.is_dir():
            candidates.extend(base.glob("iter*_score.json"))
    # Prefer full/h2h over tiny 4-match smoke, sorted by mtime desc
    candidates.sort(key=lambda p: (0 if "smoke" in p.name else 1, p.stat().st_mtime), reverse=True)

    recent: list[dict[str, Any]] = []
    batch_meta: dict[str, Any] = {
        "batch_label": "",
        "running_count": len(running),
        "total": 0,
        "wins": 0,
        "losses": 0,
        "ties": 0,
    }

    for sf in candidates[:1]:
        d = load_json_safe(sf)
        if not isinstance(d, dict):
            continue
        rows = d.get("matches")
        if not isinstance(rows, list) or not rows:
            continue
        batch_meta["batch_label"] = pretty_batch_label(sf.stem.replace("_score", ""))
        batch_meta["total"] = len(rows)
        batch_meta["wins"] = sum(1 for r in rows if str(r.get("result", "")).lower() == "win")
        batch_meta["losses"] = sum(1 for r in rows if str(r.get("result", "")).lower() == "loss")
        batch_meta["ties"] = len(rows) - batch_meta["wins"] - batch_meta["losses"]

        # Pick an informative spread across races (top wins + worst losses + recent)
        def norm_row(r: dict[str, Any]) -> dict[str, Any]:
            res = str(r.get("result") or "").lower()
            status = "win" if res == "win" else ("loss" if res == "loss" else "tie")
            dur = r.get("duration_sec") or 0.0
            sigs = r.get("signatures") if isinstance(r.get("signatures"), list) else []
            tr = r.get("trade_ratio")
            if isinstance(tr, (int, float)) and tr >= 90:
                tr = None
            return {
                "match_id": str(r.get("id") or ""),
                "mode": r.get("opp_cohort") or ("self" if r.get("is_selfplay") else "full"),
                "map": r.get("map_canon") or r.get("map_name") or "",
                "our_bot": r.get("our_bot") or "Mothman",
                "our_race": str(r.get("our_race") or "?")[:1].upper(),
                "opp_bot": r.get("opp_bot") or "Opponent",
                "opp_race": str(r.get("opp_race") or "?")[:1].upper(),
                "matchup": r.get("matchup") or "",
                "status": status,
                "game_loop": int(round(float(dur) * 22.4)),
                "game_time_str": fmt_game_time(None, dur),
                "our_supply": r.get("our_peak_supply"),
                "opp_supply": r.get("opp_peak_supply"),
                "our_workers": r.get("our_peak_workers"),
                "opp_workers": r.get("opp_peak_workers"),
                "our_bases": r.get("our_bases"),
                "opp_bases": r.get("opp_bases"),
                "our_army_val": r.get("our_peak_army"),
                "opp_army_val": r.get("opp_peak_army"),
                "trade_ratio": round(float(tr), 2) if isinstance(tr, (int, float)) else None,
                "tags": [pretty_sig(x) for x in sigs[:2]],
                "is_peak_metric": True,
            }

        # Sort: interesting mix — recent matches in order, capped to max_matches - len(running)
        limit = max(0, max_matches - len(running))
        # Take balanced sample: alternate newest wins & losses so both show cleanly in Overview & Matches
        wins_rows = [r for r in rows if str(r.get("result", "")).lower() == "win"]
        loss_rows = [r for r in rows if str(r.get("result", "")).lower() == "loss"]
        tie_rows = [r for r in rows if str(r.get("result", "")).lower() not in ("win", "loss")]
        interleaved: list[dict[str, Any]] = []
        wi = li = ti = 0
        while len(interleaved) < limit and (wi < len(wins_rows) or li < len(loss_rows) or ti < len(tie_rows)):
            if wi < len(wins_rows):
                interleaved.append(norm_row(wins_rows[wi])); wi += 1
            if len(interleaved) < limit and li < len(loss_rows):
                interleaved.append(norm_row(loss_rows[li])); li += 1
            if len(interleaved) < limit and ti < len(tie_rows) and (
                len(interleaved) % 6 == 0 or (wi >= len(wins_rows) and li >= len(loss_rows))
            ):
                interleaved.append(norm_row(tie_rows[ti])); ti += 1
        recent = interleaved

    return (running + recent)[:max_matches], batch_meta


def collect_arena_sprint() -> dict[str, Any]:
    passes: list[dict[str, Any]] = []
    latest_ability: dict[str, Any] | None = None
    latest_core: dict[str, Any] | None = None

    if ARENA_DIR.is_dir():
        for jf in sorted(ARENA_DIR.glob("pass*_*.json")):
            d = load_json_safe(jf)
            if not isinstance(d, dict):
                continue
            summ = d.get("summary")
            if not isinstance(summ, dict):
                continue
            comp = d.get("comparison") if isinstance(d.get("comparison"), dict) else {}
            m = re.match(r"pass(\d+)_(ability|core|noncombat)_", jf.stem)
            pnum = int(m.group(1)) if m else 0
            track = m.group(2) if m else "other"
            w = int(summ.get("mothman_wins", 0))
            l = int(summ.get("p2_wins", 0))
            dr = int(summ.get("draws", 0))
            tot = int(summ.get("total", w + l + dr))
            agg = float(summ.get("agg_trade_ratio") or 0.0)
            med = float(summ.get("median_trade_ratio") or 0.0)
            sv = summ.get("spell_verified_count")
            se = summ.get("spell_checks_total")
            nc_avg = summ.get("non_combat_avg_score")
            nc_pass = summ.get("non_combat_passes")
            nc_tot = summ.get("non_combat_total")
            reg_list = comp.get("regressed") if isinstance(comp.get("regressed"), list) else None
            reg_cnt = len(reg_list) if reg_list is not None else None
            wins_delta = comp.get("wins_delta") if isinstance(comp.get("wins_delta"), int) else None
            passes.append({
                "pass": f"P{pnum}",
                "pass_num": pnum,
                "track": track,
                "scope": "Ability Mastery" if track == "ability" else ("Non-Combat" if track == "noncombat" else "Core Suite"),
                "total": tot,
                "wins": w,
                "losses": l,
                "draws": dr,
                "record": f"{nc_pass}P-{nc_tot - nc_pass}F" if (track == "noncombat" and nc_pass is not None and nc_tot) else f"{w}W-{l}L-{dr}D",
                "wins_delta": wins_delta,
                "agg_trade": round(agg, 2),
                "med_trade": round(med, 2),
                "trade": f"{float(nc_avg):.1f}/100" if (track == "noncombat" and nc_avg is not None) else f"{agg:.2f}x",
                "spell_verified": sv,
                "spell_total": se,
                "spells": f"{sv}/{se}" if (sv is not None and se) else "--",
                "regressions": reg_cnt,
            })
            if track == "ability":
                latest_ability = d
            elif track == "core":
                latest_core = d

    # Auto-derive live open targets & verified wins from latest passes
    targets: list[dict[str, Any]] = []
    seen_ids: set[str] = set()

    def add_target(r: dict[str, Any], status: str, prefix: str = "") -> None:
        sid = str(r.get("id") or "")
        if not sid or sid in seen_ids:
            return
        seen_ids.add(sid)
        short_id = "-".join(sid.split("-")[:3])
        tr = float(r.get("trade_ratio") or 0.0)
        tr_str = "KO" if tr >= 90 else f"{tr:.2f}x"
        rej = r.get("p1_ability_rejected") or {}
        rej_str = f" · rej {sum(int(v) for v in rej.values())}" if isinstance(rej, dict) and rej else ""
        exp = r.get("expected_abilities") or []
        sv = r.get("spell_verified")
        sp_str = " · uncast" if (exp and sv is False) else (" · cast OK" if (exp and sv is True) else "")
        raw_desc = str(r.get("description") or sid).split("—")[0].strip()
        # Extract concise title before colon or clean word boundary (never chop mid-word)
        title = raw_desc.split(":", 1)[0].strip()
        title = re.sub(r"^Ability-Mastery\s+[PTZ]v[PTZ]\s*\((.+)\)$", r"\1", title)
        if len(title) > 48:
            title = title[:48].rsplit(" ", 1)[0] + "…"
        targets.append({
            "id": short_id,
            "full_id": sid,
            "status": status,
            "summary": f"{prefix}{title} ({tr_str}{sp_str}{rej_str})",
        })

    # 1. Uncast expected abilities & losses in latest ability-mastery
    if latest_ability:
        ab_rows = latest_ability.get("scenarios") or latest_ability.get("results") or []
        for r in ab_rows:
            if r.get("expected_abilities") and r.get("spell_verified") is False:
                add_target(r, "open")
        for r in ab_rows:
            if r.get("winner") == "p2":
                add_target(r, "open")

    # 2. Regressions vs Pass 0 in latest core
    if latest_core:
        core_rows = latest_core.get("scenarios") or latest_core.get("results") or []
        comp = latest_core.get("comparison") or {}
        reg_ids = set(comp.get("regressed") or [])
        by_id = {r.get("id"): r for r in core_rows if isinstance(r, dict)}
        for rid in sorted(reg_ids):
            if rid in by_id:
                add_target(by_id[rid], "regression", "Regressed: ")
        # 3. Flipped-to-win highlights
        for rid in (comp.get("flipped_to_win") or [])[:8]:
            if rid in by_id:
                add_target(by_id[rid], "fixed", "Flipped WIN: ")

    if latest_ability:
        ab_rows = latest_ability.get("scenarios") or latest_ability.get("results") or []
        comp_a = latest_ability.get("comparison") or {}
        by_id_a = {r.get("id"): r for r in ab_rows if isinstance(r, dict)}
        for rid in (comp_a.get("spell_verified_gained") or []):
            if rid in by_id_a:
                add_target(by_id_a[rid], "fixed", "Spell verified: ")
        for rid in (comp_a.get("flipped_to_win") or []):
            if rid in by_id_a:
                add_target(by_id_a[rid], "fixed", "Flipped WIN: ")

    return {
        "map": "PersephoneAIE_v4 (5.0.14)",
        "passes": passes,
        "targets": targets[:24],
    }


def _round1(v: Any) -> float | None:
    if v is None or not isinstance(v, (int, float)):
        return None
    return round(float(v), 1)


def collect_curves_vs_pro() -> dict[str, Any] | None:
    """Load and compact pro_curves_and_timings.json for the dashboard Curves & Pro tab."""
    raw = load_json_safe(PRO_CURVES_JSON)
    if not isinstance(raw, dict) or not isinstance(raw.get("curves"), dict):
        return None

    meta = raw.get("meta") or {}
    cohorts_in = meta.get("cohorts") or {}
    compact_cohorts = {}
    for ck in ("mothman", "opponents", "pros"):
        c = cohorts_in.get(ck) or {}
        compact_cohorts[ck] = {
            "label": c.get("label", ck.title()),
            "games": c.get("games", 0),
            "ge_games": c.get("game_events_games", c.get("games", 0)),
            "by_race": c.get("by_race") or {},
        }

    metrics_order = [
        "apm", "epm", "spm",
        "army_minerals", "army_gas",
        "collection_minerals", "collection_gas",
    ]
    segments = [s for s in (raw.get("segments") or ["all", "Protoss", "Terran", "Zerg"]) if s in raw["curves"]]

    compact_curves: dict[str, Any] = {}
    compact_summary: dict[str, Any] = {}
    for seg in segments:
        compact_curves[seg] = {}
        compact_summary[seg] = {}
        seg_c = raw["curves"].get(seg) or {}
        seg_s = (raw.get("summary") or {}).get(seg) or {}
        for mk in metrics_order:
            mc = seg_c.get(mk) or {}
            compact_curves[seg][mk] = {}
            for ck in ("mothman", "opponents", "pros"):
                pts = mc.get(ck) or []
                compact_curves[seg][mk][ck] = [
                    {
                        "t": int(pt.get("t", 0)),
                        "n": int(pt.get("n", 0)),
                        "p25": _round1(pt.get("p25")),
                        "med": _round1(pt.get("med")),
                        "p75": _round1(pt.get("p75")),
                    }
                    for pt in pts
                    if isinstance(pt, dict)
                ]
            ms = seg_s.get(mk) or {}
            compact_summary[seg][mk] = {}
            for ck in ("mothman", "opponents", "pros"):
                cs = ms.get(ck) or {}
                ent: dict[str, Any] = {
                    "n": int(cs.get("n", 0) or 0),
                    "p25": _round1(cs.get("p25")),
                    "med": _round1(cs.get("med")),
                    "p75": _round1(cs.get("p75")),
                }
                if isinstance(cs.get("peak"), dict):
                    ent["peak"] = _round1(cs["peak"].get("med"))
                compact_summary[seg][mk][ck] = ent

    compact_timings: dict[str, list[dict[str, Any]]] = {}
    raw_timings = raw.get("timings") or {}
    for rname in ("Protoss", "Terran", "Zerg"):
        rows_out = []
        for item in raw_timings.get(rname) or []:
            if not isinstance(item, dict):
                continue
            row: dict[str, Any] = {
                "key": item.get("key", ""),
                "label": item.get("label", ""),
                "kind": item.get("kind", "structure"),
            }
            for ck in ("mothman", "opponents", "pros"):
                cv = item.get(ck) or {}
                row[ck] = {
                    "n": int(cv.get("n", 0) or 0),
                    "total": int(cv.get("total", 0) or 0),
                    "adopt_pct": _round1(cv.get("adopt_pct")),
                    "p25": _round1(cv.get("p25")),
                    "med": _round1(cv.get("med")),
                    "p75": _round1(cv.get("p75")),
                    "med_fmt": cv.get("med_fmt"),
                }
            rows_out.append(row)
        compact_timings[rname] = rows_out

    return {
        "run_id": meta.get("run_id", ""),
        "generated_at": raw.get("generated_at", ""),
        "buckets_sec": raw.get("buckets_sec") or list(range(0, 901, 30)),
        "segments": segments,
        "cohorts": compact_cohorts,
        "notes": meta.get("notes") or [],
        "summary": compact_summary,
        "curves": compact_curves,
        "timings": compact_timings,
    }


def deep_merge(dst: dict[str, Any], src: dict[str, Any]) -> dict[str, Any]:
    out = dict(dst)
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def atomic_write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--auto", action="store_true", help="Auto-refresh live matches, Arena passes, and AI Arena standings")
    ap.add_argument("--patch", default="", help="JSON object string to merge into state")
    ap.add_argument("--patch-file", default="", help="Path to JSON file to merge into state")
    args = ap.parse_args()

    out_path = Path(args.out)
    state: dict[str, Any] = load_json_safe(out_path) or {}

    if args.auto:
        state["aiarena_live"] = collect_aiarena_live()
        matches, batch_meta = scan_live_and_recent_matches()
        state["live_matches"] = matches
        state["matches_meta"] = batch_meta
        arena = collect_arena_sprint()
        if arena["passes"]:
            state["arena_sprint"] = arena
        curves = collect_curves_vs_pro()
        if curves:
            state["curves_vs_pro"] = curves

    if args.patch_file:
        p = load_json_safe(Path(args.patch_file))
        if isinstance(p, dict):
            state = deep_merge(state, p)

    if args.patch:
        p = json.loads(args.patch)
        if isinstance(p, dict):
            state = deep_merge(state, p)

    state["updated_at_epoch_ms"] = int(time.time() * 1000)
    atomic_write_json(out_path, state)
    print(f"Wrote {out_path} ({out_path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
