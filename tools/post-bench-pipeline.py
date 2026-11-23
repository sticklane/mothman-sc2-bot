#!/usr/bin/env python3
"""
One-command parallel post-bench pipeline for SC2 local arena runs.

Runs all independent post-bench steps in parallel (DAG-scheduled):
  Stage A (parallel):
    - tools/score-replay-batch.rkt -> <out_root>/<label>_score.json
    - s2protocol full-run ability/feature audit -> <out_root>/loop/<label>/s2_features.json
  Stage B (after score, parallel):
    - tools/replay-db.py ingest-runs -> tools/replay-db.py extract-raw (chained on <replay_db>)
    - tools/iteration-loop/compare-vs-pro.py -> <out_root>/loop/<label>/compare_vs_pro.json
  Stage C (after db_ingest + db_extract_raw, parallel):
    - tools/pro-deep-comparison.py -> <out_root>/loop/<label>/pro_deep.{json,md}
    - tools/trade-review-pack.py -> <out_root>/loop/<label>/trade_review/trade_review_pack.md
  Stage D (after pro_deep + score, parallel):
    - tools/forensics-diff.py -> <out_root>/loop/<label>/forensics_diff.{md,json} (if --baseline-run)
    - tools/update-dashboard-state.py --auto (unless --skip-dashboard)
    - tools/iteration-loop/log-loop-trajectory.py (optional non-fatal if --log-trajectory)

Usage:
  python3 tools/post-bench-pipeline.py <run_dir> [--label <name>]
      [--baseline-run <base_run_dir>] [--baseline-score <json>]
      [--out-root <dir>] [--replay-db <sqlite_path>]
      [--skip-dashboard] [--skip-db-ingest] [--skip-pro-deep]
      [--log-trajectory] [--loop-id <N>] [--sub-iter <str>] [--workers 8]
"""
from __future__ import annotations

import argparse
import collections
import concurrent.futures
import json
import math
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
TOOLS_DIR = REPO_ROOT / "tools"
DEFAULT_ARENA_DIR = Path("/home/sjaconette/sc2-local-arena")
DEFAULT_DB_PATH = DEFAULT_ARENA_DIR / "arena_replays.sqlite"
DEFAULT_PYLIBS_DIR = DEFAULT_ARENA_DIR / "pylibs"
DEFAULT_BRAIN_SCRATCH = Path(
    "/home/sjaconette/.gemini/antigravity/brain/d28d22f4-2d13-41e2-9b7b-32757f58523b/scratch"
)

# Reuse verified SC2 5.0.14 s2protocol helpers from tools/forensics-diff.py
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))
import importlib.util as _ilu


def _load_forensics_mod():
    spec = _ilu.spec_from_file_location("forensics_diff_mod", str(TOOLS_DIR / "forensics-diff.py"))
    assert spec and spec.loader
    mod = _ilu.module_from_spec(spec)
    sys.modules["forensics_diff_mod"] = mod
    spec.loader.exec_module(mod)
    return mod


_FD = _load_forensics_mod()

FEATURE_KEYS = (
    "WarpPrism",
    "WarpPrismPhasing",
    "WarpPrismPhasing_tracker",
    "WarpPrismTransport",
    "FwdWarpInit_Zealot",
    "FwdWarpInit_All",
    "CreepTumorSpread",
    "CreepTumorSpread_born",
    "CreepTumorQueen",
    "CreepTumorQueen_born",
    "Hatchery_init",
    "Hatchery_canceled",
    "SiegeTank",
    "Immortal",
    "Colossus",
    "Lurker",
    "SupplyDrop",
    "EnergyRecharge",
    "ForceField",
    "LurkerBurrow",
    "LurkerBurrow_tracker",
    "Bile",
    "Inject",
    "MedivacBoost",
    "Scan",
    "Transfuse",
    "RALLY_WORKERS",
)


def _infer_label(run_dir: Path, explicit_label: str | None) -> str:
    if explicit_label:
        return explicit_label
    m = re.match(r"^\d{8}_\d{6}_(.+)$", run_dir.name)
    return m.group(1) if m else run_dir.name


def _default_out_root() -> Path:
    if DEFAULT_BRAIN_SCRATCH.is_dir():
        return DEFAULT_BRAIN_SCRATCH
    return REPO_ROOT / "scratch"


def _s2_feature_worker(task: tuple[str, str]) -> dict[str, Any]:
    """Decode one SC2Replay and return P1 & P2 s2protocol feature counts."""
    replay_path, pylibs_dir = task
    p1: dict[str, int] = {k: 0 for k in FEATURE_KEYS}
    p2: dict[str, int] = {k: 0 for k in FEATURE_KEYS}
    res: dict[str, Any] = {
        "replay": os.path.basename(replay_path),
        "ok": False,
        "error": None,
        "duration_sec": 0.0,
        "p1": p1,
        "p2": p2,
    }
    try:
        mpyq, versions = _FD.ensure_s2protocol_imports(pylibs_dir)
        arch = mpyq.MPQArchive(replay_path)
        header = versions.latest().decode_replay_header(arch.header["user_data_header"]["content"])
        proto = versions.build(header["m_dataBuildNum"])
        tevs = proto.decode_replay_tracker_events(arch.read_file("replay.tracker.events"))
        gevs = proto.decode_replay_game_events(arch.read_file("replay.game.events"))

        main_xy: dict[int, tuple[float, float]] = {}
        units: dict[int, list[Any]] = {}
        hatch_init: dict[int, int] = {}  # uid -> pid
        hatch_done: set[int] = set()
        max_loop = 0

        for e in tevs:
            gl = int(e.get("_gameloop", 0))
            if gl > max_loop:
                max_loop = gl
            et = e["_event"]
            if et == "NNet.Replay.Tracker.SUnitBornEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                pid = int(e["m_controlPlayerId"])
                ut = _FD._decode_str(e["m_unitTypeName"])
                units[uid] = [pid, ut]
                if pid in (1, 2) and ut in _FD.TOWNHALL_UNITS and pid not in main_xy:
                    main_xy[pid] = (float(e["m_x"]), float(e["m_y"]))
                dst = p1 if pid == 1 else (p2 if pid == 2 else None)
                if dst is not None:
                    if ut == "WarpPrism":
                        dst["WarpPrism"] += 1
                    elif ut in ("SiegeTank", "SiegeTankSieged"):
                        dst["SiegeTank"] += 1
                    elif ut == "Immortal":
                        dst["Immortal"] += 1
                    elif ut == "Colossus":
                        dst["Colossus"] += 1
                    elif ut in ("LurkerMP", "LurkerMPEgg"):
                        dst["Lurker"] += 1
                    elif ut == "CreepTumorQueen":
                        dst["CreepTumorQueen_born"] += 1
                    elif ut == "CreepTumor":
                        dst["CreepTumorSpread_born"] += 1
            elif et == "NNet.Replay.Tracker.SUnitInitEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                pid = int(e["m_controlPlayerId"])
                ut = _FD._decode_str(e["m_unitTypeName"])
                units[uid] = [pid, ut]
                dst = p1 if pid == 1 else (p2 if pid == 2 else None)
                if dst is not None:
                    if ut == "Hatchery":
                        hatch_init[uid] = pid
                        dst["Hatchery_init"] += 1
                    elif ut == "CreepTumorQueen":
                        dst["CreepTumorQueen_born"] += 1
                    elif ut == "CreepTumor":
                        dst["CreepTumorSpread_born"] += 1
                    elif ut in ("Zealot", "Stalker", "Sentry", "Adept", "HighTemplar", "DarkTemplar"):
                        mxy = main_xy.get(pid)
                        if mxy is not None:
                            dh = math.hypot(float(e["m_x"]) - mxy[0], float(e["m_y"]) - mxy[1])
                            if dh > 30.0:
                                dst["FwdWarpInit_All"] += 1
                                if ut == "Zealot":
                                    dst["FwdWarpInit_Zealot"] += 1
            elif et == "NNet.Replay.Tracker.SUnitDoneEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                if uid in hatch_init:
                    hatch_done.add(uid)
            elif et == "NNet.Replay.Tracker.SUnitTypeChangeEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                ut = _FD._decode_str(e["m_unitTypeName"])
                info = units.get(uid)
                if info is not None:
                    pid, prev_ut = info
                    dst = p1 if pid == 1 else (p2 if pid == 2 else None)
                    if dst is not None:
                        if ut == "WarpPrismPhasing" and prev_ut != "WarpPrismPhasing":
                            dst["WarpPrismPhasing_tracker"] += 1
                        elif ut == "LurkerMPBurrowed" and prev_ut != "LurkerMPBurrowed":
                            dst["LurkerBurrow_tracker"] += 1
                        elif ut == "LurkerMPEgg" and prev_ut != "LurkerMPEgg":
                            dst["Lurker"] += 1
                    info[1] = ut
            elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
                uid = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                if uid in hatch_init and uid not in hatch_done:
                    pid = hatch_init[uid]
                    kpid = e.get("m_killerPlayerId")
                    if kpid in (None, pid):
                        dst = p1 if pid == 1 else (p2 if pid == 2 else None)
                        if dst is not None:
                            dst["Hatchery_canceled"] += 1

        for e in gevs:
            if e["_event"] != "NNet.Game.SCmdEvent":
                continue
            uid_info = e.get("_userid")
            if not uid_info:
                continue
            user_id = int(uid_info.get("m_userId", -1))
            dst = p1 if user_id == 0 else (p2 if user_id == 1 else None)
            if dst is None:
                continue
            ab = e.get("m_abil")
            if not ab:
                continue
            key = f"{ab['m_abilLink']}:{ab['m_abilCmdIndex']}"
            if key == _FD.ABIL_WARP_PRISM_PHASING:
                dst["WarpPrismPhasing"] += 1
            elif key == _FD.ABIL_WARP_PRISM_TRANSPORT:
                dst["WarpPrismTransport"] += 1
            elif key == _FD.ABIL_CREEP_TUMOR_SPREAD:
                dst["CreepTumorSpread"] += 1
            elif key == _FD.ABIL_CREEP_TUMOR_QUEEN:
                dst["CreepTumorQueen"] += 1
            elif key == _FD.ABIL_SUPPLY_DROP:
                dst["SupplyDrop"] += 1
            elif key == _FD.ABIL_ENERGY_RECHARGE:
                dst["EnergyRecharge"] += 1
            elif key == _FD.ABIL_FORCE_FIELD:
                dst["ForceField"] += 1
            elif key == _FD.ABIL_LURKER_BURROW:
                dst["LurkerBurrow"] += 1
            elif key == _FD.ABIL_BILE:
                dst["Bile"] += 1
            elif key == _FD.ABIL_INJECT:
                dst["Inject"] += 1
            elif key == _FD.ABIL_MEDIVAC_BOOST:
                dst["MedivacBoost"] += 1
            elif key == _FD.ABIL_SCAN:
                dst["Scan"] += 1
            elif key == _FD.ABIL_TRANSFUSE:
                dst["Transfuse"] += 1
            elif key in _FD.ABIL_RALLY_WORKERS:
                dst["RALLY_WORKERS"] += 1

        res["duration_sec"] = round(max_loop / 22.4, 1)
        res["ok"] = True
    except Exception as exc:
        res["error"] = f"{type(exc).__name__}: {exc}"
    return res


def run_s2_features_audit(
    run_dir: Path,
    out_json: Path,
    *,
    workers: int = 8,
    pylibs_dir: Path = DEFAULT_PYLIBS_DIR,
) -> dict[str, Any]:
    """Run full-run parallel s2protocol feature extraction and write s2_features.json."""
    t0 = time.monotonic()
    replays_dir = run_dir / "replays"
    replays = sorted(replays_dir.glob("*.SC2Replay")) if replays_dir.is_dir() else sorted(run_dir.glob("*.SC2Replay"))
    tasks = [(str(rp), str(pylibs_dir)) for rp in replays]
    per_match: list[dict[str, Any]] = []
    if tasks:
        max_w = max(1, min(workers, len(tasks)))
        with concurrent.futures.ProcessPoolExecutor(max_workers=max_w) as pool:
            per_match = list(pool.map(_s2_feature_worker, tasks))

    p1_totals = {k: 0 for k in FEATURE_KEYS}
    p1_games = {k: 0 for k in FEATURE_KEYS}
    p2_totals = {k: 0 for k in FEATURE_KEYS}
    p2_games = {k: 0 for k in FEATURE_KEYS}
    ok_cnt = 0
    err_cnt = 0
    for row in per_match:
        if row["ok"]:
            ok_cnt += 1
            for k in FEATURE_KEYS:
                v1 = int(row["p1"].get(k, 0))
                v2 = int(row["p2"].get(k, 0))
                p1_totals[k] += v1
                p2_totals[k] += v2
                if v1 > 0:
                    p1_games[k] += 1
                if v2 > 0:
                    p2_games[k] += 1
        else:
            err_cnt += 1

    elapsed = round(time.monotonic() - t0, 3)
    payload = {
        "run_dir": str(run_dir),
        "replays_total": len(replays),
        "replays_ok": ok_cnt,
        "replays_err": err_cnt,
        "elapsed_sec": elapsed,
        "p1_totals": p1_totals,
        "p1_games": p1_games,
        "p2_totals": p2_totals,
        "p2_games": p2_games,
        "per_match": per_match,
    }
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_json.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return {
        "step": "s2_features",
        "ok": err_cnt == 0 and ok_cnt > 0,
        "returncode": 0 if err_cnt == 0 else 1,
        "elapsed_sec": elapsed,
        "out_path": str(out_json),
        "payload": payload,
    }


def _run_subprocess_step(step_name: str, cmd: list[str], cwd: Path = REPO_ROOT) -> dict[str, Any]:
    t0 = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            check=False,
        )
        elapsed = round(time.monotonic() - t0, 3)
        stderr_tail = "\n".join(proc.stderr.splitlines()[-12:]) if proc.stderr else ""
        stdout_tail = "\n".join(proc.stdout.splitlines()[-8:]) if proc.stdout else ""
        return {
            "step": step_name,
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "elapsed_sec": elapsed,
            "cmd": cmd,
            "stderr_tail": stderr_tail,
            "stdout_tail": stdout_tail,
        }
    except Exception as exc:
        return {
            "step": step_name,
            "ok": False,
            "returncode": -1,
            "elapsed_sec": round(time.monotonic() - t0, 3),
            "cmd": cmd,
            "stderr_tail": f"{type(exc).__name__}: {exc}",
            "stdout_tail": "",
        }


def _is_all_selfplay(score_json: Path) -> bool:
    if not score_json.is_file():
        return False
    try:
        d = json.loads(score_json.read_text(encoding="utf-8"))
        ms = d.get("matches") or []
        return bool(ms) and all(bool(m.get("is_selfplay")) for m in ms)
    except Exception:
        return False


def _render_board_summary(summary: dict[str, Any]) -> str:
    lines: list[str] = []
    label = summary["label"]
    lines.append(f"# Post-Bench Pipeline Summary: `{label}`")
    lines.append("")
    lines.append(
        f"- **Run:** `{summary['run_dir']}` | **Total Wall:** `{summary['total_elapsed_sec']:.2f}s` | "
        f"**Status:** `{'OK' if summary['all_ok'] else 'PARTIAL/FAILED'}`"
    )

    sc = summary.get("score_overview")
    if sc:
        ov = sc.get("overall") or {}
        gs_part = ""
        if ov.get("mean_game_state_score") is not None:
            gs_part += f" | **GameState `{ov['mean_game_state_score']:.1f}/100`**"
        if ov.get("state_adjudicated_wlt"):
            gs_part += f" | **StateWLT `{ov['state_adjudicated_wlt']}`**"
        if ov.get("adjudicated_wlt") and ov.get("adjudicated_wlt") != ov.get("state_adjudicated_wlt"):
            gs_part += f" | AdjWLT `{ov['adjudicated_wlt']}`"
        lines.append(
            f"- **Scorecard (`{ov.get('scope', 'ALL')}`):** `{ov.get('w', 0)}W-{ov.get('l', 0)}L-{ov.get('t', 0)}T` "
            f"(`{ov.get('wr_pct', 0.0):.1f}% WR / {ov.get('nl_pct', 0.0):.1f}% NL`){gs_part} | "
            f"Tr `{ov.get('tr_agg', '-')}` | Min `{ov.get('min_agg', '-')}` | Gas `{ov.get('gas_agg', '-')}`"
        )
        race_parts = []
        for rname, rs in sorted((sc.get("by_race") or {}).items()):
            r_gs = (
                f", GS {rs['mean_game_state_score']:.1f}"
                if rs.get("mean_game_state_score") is not None
                else ""
            )
            r_sw = f", State {rs['state_adjudicated_wlt']}" if rs.get("state_adjudicated_wlt") else ""
            race_parts.append(f"{rname}: `{rs['w']}-{rs['l']}-{rs['t']}` (Tr {rs.get('tr', '-')}{r_gs}{r_sw})")
        if race_parts:
            lines.append("- **By Race:** " + " | ".join(race_parts))

    s2 = summary.get("s2_summary")
    if s2:
        p1 = s2["p1_totals"]
        g1 = s2["p1_games"]
        lines.append(
            f"- **s2protocol Features (`{s2['replays_ok']}/{s2['replays_total']}` replays):** "
            f"WarpPrism={p1['WarpPrism']}({g1['WarpPrism']}g) Phasing={p1['WarpPrismPhasing_tracker']}/{p1['WarpPrismPhasing']} FwdWarpZ={p1['FwdWarpInit_Zealot']} | "
            f"Creep={p1['CreepTumorQueen']}+{p1['CreepTumorSpread']}={p1['CreepTumorQueen']+p1['CreepTumorSpread']} (HatchCancel={p1['Hatchery_canceled']}/{p1['Hatchery_init']}) | "
            f"SiegeTank={p1['SiegeTank']} Immortal={p1['Immortal']} Colossus={p1['Colossus']} Lurker={p1['Lurker']} | "
            f"SupplyDrop={p1['SupplyDrop']}({g1['SupplyDrop']}g) EnergyRech={p1['EnergyRecharge']}({g1['EnergyRecharge']}g) "
            f"ForceField={p1['ForceField']}({g1['ForceField']}g) LurkerBurrow={p1['LurkerBurrow']} Bile={p1['Bile']} "
            f"Inject={p1['Inject']} MedivacBoost={p1['MedivacBoost']} Scan={p1['Scan']} Transfuse={p1['Transfuse']} RallyW={p1['RALLY_WORKERS']}"
        )

    pd_ov = summary.get("pro_deep_overview")
    if pd_ov:
        pd_parts = []
        for rname, stats in sorted(pd_ov.items()):
            if not any(v is not None for v in stats.values()):
                continue
            r_s = f"{stats['reinf_pct']}%" if stats.get("reinf_pct") is not None else "-"
            t_s = f"{stats['trickle_pct']}%" if stats.get("trickle_pct") is not None else "-"
            d_s = f"{stats['diseng_pct']}%" if stats.get("diseng_pct") is not None else "-"
            w_s = f"{stats['wrap']}t" if stats.get("wrap") is not None else "-"
            i_s = f"{stats['in_range_pct']}%" if stats.get("in_range_pct") is not None else "-"
            pd_parts.append(f"{rname}: Reinf={r_s} Trickle={t_s} Diseng={d_s} wrap={w_s} inR={i_s}")
        if pd_parts:
            lines.append("- **Pro-Deep AG/Concave:** " + " | ".join(pd_parts))

    fd_ov = summary.get("forensics_diff_overview")
    if fd_ov:
        lines.append(
            f"- **Forensics Diff vs `{fd_ov['base_label']}`:** `dW={fd_ov['dw']:+d}` | "
            f"`W->L: {fd_ov['w_to_l']}` | `L->W: {fd_ov['l_to_w']}` | `other: {fd_ov['other']}`"
        )

    lines.append("")
    lines.append("| Step | Status | Elapsed (s) | Artifact / Note |")
    lines.append("|---|---|---:|---|")
    for st in summary["steps"]:
        status = "OK" if st["ok"] else f"FAIL({st.get('returncode')})"
        note = st.get("out_path") or (st.get("stderr_tail", "").splitlines()[-1] if st.get("stderr_tail") else "-")
        lines.append(f"| `{st['step']}` | {status} | {st['elapsed_sec']:.2f} | `{note}` |")

    return "\n".join(lines).rstrip() + "\n"


def _extract_score_overview(score_json: Path) -> dict[str, Any] | None:
    if not score_json.is_file():
        return None
    try:
        sc = json.loads(score_json.read_text(encoding="utf-8"))
        matches = sc.get("matches") or []
        ext = [m for m in matches if not m.get("is_selfplay")]
        scope_list = ext if ext else matches
        scope_name = f"EXT_{len(ext)}" if ext else f"ALL_{len(matches)}"

        def _norm_gs_100(val: float) -> float:
            return val * 100.0 if val <= 1.0001 else val

        def _agg(ms: list[dict[str, Any]], agg_obj: dict[str, Any] | None = None) -> dict[str, Any]:
            w = sum(1 for m in ms if m.get("result") == "win")
            l = sum(1 for m in ms if m.get("result") == "loss")
            t = sum(1 for m in ms if m.get("result") == "tie")
            n = len(ms)
            kv = sum(float(m.get("killed_val") or 0) for m in ms)
            lv = sum(float(m.get("lost_val") or 0) for m in ms)
            om = sum(float(m.get("our_min_collected") or 0) for m in ms)
            em = sum(float(m.get("opp_min_collected") or 0) for m in ms)
            og = sum(float(m.get("our_gas_collected") or 0) for m in ms)
            eg = sum(float(m.get("opp_gas_collected") or 0) for m in ms)

            # Game-state score (0-100) and state/adjudicated W-L-T when present
            gs_vals = [
                _norm_gs_100(float(m["game_state_score"]))
                for m in ms
                if isinstance(m.get("game_state_score"), (int, float))
            ]
            mean_gs: float | None = round(sum(gs_vals) / len(gs_vals), 1) if gs_vals else None
            if mean_gs is None and isinstance(agg_obj, dict) and isinstance(agg_obj.get("mean_game_state_score"), (int, float)):
                mean_gs = round(_norm_gs_100(float(agg_obj["mean_game_state_score"])), 1)

            state_wlt: str | None = None
            st_outs = [str(m["state_outcome"]).lower() for m in ms if m.get("state_outcome") is not None]
            if st_outs:
                sw = sum(1 for o in st_outs if o == "win")
                sl = sum(1 for o in st_outs if o == "loss")
                st = sum(1 for o in st_outs if o == "tie")
                state_wlt = f"{sw}-{sl}-{st}"
            elif isinstance(agg_obj, dict):
                if isinstance(agg_obj.get("state_adjudicated_wlt"), str):
                    state_wlt = agg_obj["state_adjudicated_wlt"]
                elif all(isinstance(agg_obj.get(k), int) for k in ("state_wins", "state_losses", "state_ties")):
                    state_wlt = f"{agg_obj['state_wins']}-{agg_obj['state_losses']}-{agg_obj['state_ties']}"

            adj_wlt: str | None = None
            adj_outs = [str(m["adjudicated_outcome"]).lower() for m in ms if m.get("adjudicated_outcome") is not None]
            if adj_outs:
                aw = sum(1 for o in adj_outs if o == "win")
                al = sum(1 for o in adj_outs if o == "loss")
                at = sum(1 for o in adj_outs if o == "tie")
                adj_wlt = f"{aw}-{al}-{at}"
            elif isinstance(agg_obj, dict) and all(
                isinstance(agg_obj.get(k), int) for k in ("adjudicated_wins", "adjudicated_losses", "adjudicated_ties")
            ):
                adj_wlt = f"{agg_obj['adjudicated_wins']}-{agg_obj['adjudicated_losses']}-{agg_obj['adjudicated_ties']}"

            if state_wlt is None and adj_wlt is not None:
                state_wlt = adj_wlt

            return {
                "n": n,
                "w": w,
                "l": l,
                "t": t,
                "wr_pct": round(100.0 * w / n, 1) if n else 0.0,
                "nl_pct": round(100.0 * (w + t) / n, 1) if n else 0.0,
                "tr_agg": f"{kv / lv:.2f}x" if lv > 0 else "-",
                "min_agg": f"{om / em:.2f}x" if em > 0 else "-",
                "gas_agg": f"{og / eg:.2f}x" if eg > 0 else "-",
                "mean_game_state_score": mean_gs,
                "state_adjudicated_wlt": state_wlt,
                "adjudicated_wlt": adj_wlt,
            }

        ov_agg_src = (sc.get("overall") if isinstance(sc.get("overall"), dict) else None)
        ov = _agg(scope_list, ov_agg_src)
        ov["scope"] = scope_name
        by_race_src = sc.get("by_race") if isinstance(sc.get("by_race"), dict) else {}
        by_race = {}
        for r in sorted({m.get("our_race") for m in scope_list if m.get("our_race")}):
            ra = _agg([m for m in scope_list if m.get("our_race") == r], by_race_src.get(r))
            by_race[r] = {
                "w": ra["w"],
                "l": ra["l"],
                "t": ra["t"],
                "tr": ra["tr_agg"],
                "mean_game_state_score": ra["mean_game_state_score"],
                "state_adjudicated_wlt": ra["state_adjudicated_wlt"],
                "adjudicated_wlt": ra["adjudicated_wlt"],
            }
        return {"overall": ov, "by_race": by_race}
    except Exception:
        return None


def _extract_pro_deep_overview(pro_deep_json: Path) -> dict[str, Any] | None:
    if not pro_deep_json.is_file():
        return None
    try:
        pd = json.loads(pro_deep_json.read_text(encoding="utf-8"))
        out = {}
        for rname, body in (pd.get("by_race") or {}).items():
            mm = (body or {}).get("mothman") or {}
            ag = mm.get("army_group_positioning") or {}
            cm = mm.get("combat_positioning") or {}
            out[rname] = {
                "reinf_pct": ag.get("reinforce_linked_pct"),
                "trickle_pct": ag.get("solo_trickle_death_pct"),
                "diseng_pct": ag.get("disengage_and_regroup_pct"),
                "wrap": cm.get("concave_wrap_score"),
                "in_range_pct": cm.get("in_range_pct"),
            }
        return out
    except Exception:
        return None


def _run_trajectory_log_step(
    *,
    replay_db: Path,
    eff_label: str,
    loop_id: int | None = None,
    sub_iter: str | None = None,
    out_jsonl: Path | None = None,
) -> dict[str, Any]:
    """Optional non-fatal trajectory logging hook for post-bench sub-iterations."""
    traj_script = TOOLS_DIR / "iteration-loop" / "log-loop-trajectory.py"
    if not traj_script.is_file():
        return {
            "step": "log_trajectory",
            "ok": True,
            "non_fatal": True,
            "returncode": 0,
            "elapsed_sec": 0.0,
            "out_path": "skipped(script_missing)",
        }

    # Probe whether --sub-iter is supported without triggering side effects
    supports_sub_iter = False
    try:
        src_txt = traj_script.read_text(encoding="utf-8", errors="ignore")
        supports_sub_iter = "--sub-iter" in src_txt
    except Exception:
        supports_sub_iter = False

    cmd = [sys.executable, str(traj_script), "--replay-db", str(replay_db)]
    if out_jsonl is not None:
        cmd.extend(["--out-jsonl", str(out_jsonl)])
    if loop_id is not None:
        cmd.extend(["--loop", str(loop_id)])
    elif sub_iter and supports_sub_iter:
        cmd.extend(["--sub-iter", str(sub_iter)])
    elif supports_sub_iter:
        cmd.extend(["--sub-iter", str(eff_label)])
    else:
        cmd.append("--dry-run")

    res = _run_subprocess_step("log_trajectory", cmd)
    res["non_fatal"] = True
    res["out_path"] = str(out_jsonl) if out_jsonl else (res.get("stdout_tail", "").splitlines()[-1] if res.get("stdout_tail") else "trajectory")
    return res


def run_pipeline(
    run_dir: Path,
    *,
    label: str | None = None,
    baseline_run: Path | None = None,
    baseline_score: Path | None = None,
    out_root: Path | None = None,
    replay_db: Path = DEFAULT_DB_PATH,
    pylibs_dir: Path = DEFAULT_PYLIBS_DIR,
    skip_dashboard: bool = False,
    skip_db_ingest: bool = False,
    skip_pro_deep: bool = False,
    log_trajectory: bool = False,
    loop_id: int | None = None,
    sub_iter: str | None = None,
    trajectory_jsonl: Path | None = None,
    workers: int = 8,
) -> dict[str, Any]:
    t_total = time.monotonic()
    run_dir = run_dir.resolve()
    eff_label = _infer_label(run_dir, label)
    eff_out_root = (out_root or _default_out_root()).resolve()
    loop_dir = eff_out_root / "loop" / eff_label
    loop_dir.mkdir(parents=True, exist_ok=True)

    score_json = eff_out_root / f"{eff_label}_score.json"
    s2_json = loop_dir / "s2_features.json"
    cmp_json = loop_dir / "compare_vs_pro.json"
    pro_deep_json = loop_dir / "pro_deep.json"
    pro_deep_md = loop_dir / "pro_deep.md"
    trade_dir = loop_dir / "trade_review"
    diff_md = loop_dir / "forensics_diff.md"
    diff_json = loop_dir / "forensics_diff.json"

    steps_log: list[dict[str, Any]] = []

    # Stage A: score-replay-batch.rkt + full-run s2protocol features audit in parallel!
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as stage_a:
        score_cmd = [
            "racket",
            str(TOOLS_DIR / "score-replay-batch.rkt"),
            "-j",
            str(workers),
            "--json",
            str(score_json),
            str(run_dir),
        ]
        fut_score = stage_a.submit(_run_subprocess_step, "score_replay_batch", score_cmd)
        fut_s2 = stage_a.submit(
            run_s2_features_audit,
            run_dir,
            s2_json,
            workers=workers,
            pylibs_dir=pylibs_dir,
        )
        res_score = fut_score.result()
        res_score["out_path"] = str(score_json)
        res_s2 = fut_s2.result()
        steps_log.extend([res_score, res_s2])

    # Stage B: (db_ingest -> db_extract_raw) + compare-vs-pro in parallel (both depend on score_json)
    res_ingest: dict[str, Any] | None = None
    res_extract: dict[str, Any] | None = None

    def _run_ingest_then_extract() -> list[dict[str, Any]]:
        out_steps: list[dict[str, Any]] = []
        ing_cmd = [
            sys.executable,
            str(TOOLS_DIR / "replay-db.py"),
            "--db",
            str(replay_db),
            "ingest-runs",
            "--runs-dir",
            str(run_dir.parent),
            "--run",
            run_dir.name,
            "--score-json",
            str(score_json),
            "-j",
            str(workers),
        ]
        r_ing = _run_subprocess_step("db_ingest", ing_cmd)
        r_ing["out_path"] = str(replay_db)
        out_steps.append(r_ing)
        if r_ing["ok"]:
            ext_cmd = [
                sys.executable,
                str(TOOLS_DIR / "replay-db.py"),
                "--db",
                str(replay_db),
                "extract-raw",
                "--run",
                run_dir.name,
                "--pylibs-dir",
                str(pylibs_dir),
                "-j",
                str(workers),
            ]
            r_ext = _run_subprocess_step("db_extract_raw", ext_cmd)
            r_ext["out_path"] = str(replay_db)
            out_steps.append(r_ext)
        return out_steps

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as stage_b:
        fut_ing_chain = stage_b.submit(_run_ingest_then_extract) if not skip_db_ingest else None
        fut_cmp = None
        if score_json.is_file():
            cmp_cmd = [
                sys.executable,
                str(TOOLS_DIR / "iteration-loop" / "compare-vs-pro.py"),
                "--current",
                str(score_json),
                "--out-json",
                str(cmp_json),
                "--run-id",
                run_dir.name,
            ]
            if baseline_score and baseline_score.is_file():
                cmp_cmd.extend(["--baseline", str(baseline_score)])
            fut_cmp = stage_b.submit(_run_subprocess_step, "compare_vs_pro", cmp_cmd)

        if fut_ing_chain is not None:
            for r in fut_ing_chain.result():
                steps_log.append(r)
                if r["step"] == "db_ingest":
                    res_ingest = r
                elif r["step"] == "db_extract_raw":
                    res_extract = r
        if fut_cmp is not None:
            r_cmp = fut_cmp.result()
            r_cmp["out_path"] = str(cmp_json)
            steps_log.append(r_cmp)

    # Stage C: pro_deep + trade_review_pack in parallel (after db_ingest + db_extract_raw)
    db_ready = (
        replay_db.is_file()
        and (res_ingest is None or res_ingest["ok"])
        and (res_extract is None or res_extract["ok"])
    )
    all_sp = _is_all_selfplay(score_json)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as stage_c:
        futs_c: list[tuple[concurrent.futures.Future[dict[str, Any]], str]] = []
        if db_ready and not skip_pro_deep:
            pd_cmd = [
                sys.executable,
                str(TOOLS_DIR / "pro-deep-comparison.py"),
                "--replay-db",
                str(replay_db),
                "--pylibs-dir",
                str(pylibs_dir),
                "--run-prefixes",
                run_dir.name,
                "--jobs",
                str(workers),
                "--out-json",
                str(pro_deep_json),
                "--out-md",
                str(pro_deep_md),
            ]
            futs_c.append((stage_c.submit(_run_subprocess_step, "pro_deep", pd_cmd), str(pro_deep_json)))
        if db_ready:
            tr_cmd = [
                sys.executable,
                str(TOOLS_DIR / "trade-review-pack.py"),
                "--mode",
                "match",
                "--run-id",
                run_dir.name,
                "--replay-db",
                str(replay_db),
                "--out-dir",
                str(trade_dir),
            ]
            if score_json.is_file():
                tr_cmd.extend(["--score-json", str(score_json)])
            if all_sp:
                tr_cmd.append("--include-selfplay")
            futs_c.append(
                (
                    stage_c.submit(_run_subprocess_step, "trade_review_pack", tr_cmd),
                    str(trade_dir / "trade_review_pack.md"),
                )
            )
        for fut, outp in futs_c:
            r = fut.result()
            r["out_path"] = outp
            steps_log.append(r)

    # Stage D: forensics_diff + dashboard refresh + optional non-fatal trajectory log
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as stage_d:
        futs_d: list[tuple[concurrent.futures.Future[dict[str, Any]], str | None]] = []
        if baseline_run is not None:
            fd_cmd = [
                sys.executable,
                str(TOOLS_DIR / "forensics-diff.py"),
                str(run_dir),
                str(baseline_run),
                "--new-score",
                str(score_json),
                "--out-md",
                str(diff_md),
                "--out-json",
                str(diff_json),
                "--workers",
                str(workers),
                "--pylibs-dir",
                str(pylibs_dir),
                "--quiet",
            ]
            if baseline_score and baseline_score.is_file():
                fd_cmd.extend(["--base-score", str(baseline_score)])
            if pro_deep_json.is_file():
                fd_cmd.extend(["--new-pro-deep", str(pro_deep_json)])
            futs_d.append((stage_d.submit(_run_subprocess_step, "forensics_diff", fd_cmd), str(diff_md)))
        if not skip_dashboard:
            dash_cmd = [
                sys.executable,
                str(TOOLS_DIR / "update-dashboard-state.py"),
                "--auto",
            ]
            futs_d.append(
                (
                    stage_d.submit(_run_subprocess_step, "dashboard_refresh", dash_cmd),
                    str(REPO_ROOT / "scratch" / "dashboard_state.json"),
                )
            )
        if log_trajectory:
            futs_d.append(
                (
                    stage_d.submit(
                        _run_trajectory_log_step,
                        replay_db=replay_db,
                        eff_label=eff_label,
                        loop_id=loop_id,
                        sub_iter=sub_iter,
                        out_jsonl=trajectory_jsonl,
                    ),
                    None,
                )
            )
        for fut, outp in futs_d:
            r = fut.result()
            if outp is not None:
                r["out_path"] = outp
            steps_log.append(r)

    # Build final summary payload
    s2_payload = res_s2.get("payload") or {}
    fd_overview = None
    if diff_json.is_file():
        try:
            fd = json.loads(diff_json.read_text(encoding="utf-8"))
            fd_overview = {
                "base_label": fd["meta"]["base_label"],
                "dw": fd["overall"]["new"]["w"] - fd["overall"]["base"]["w"],
                "w_to_l": len(fd.get("flips_w_to_l") or []),
                "l_to_w": len(fd.get("flips_l_to_w") or []),
                "other": len(fd.get("flips_other") or []),
            }
        except Exception:
            fd_overview = None

    clean_steps = [{k: v for k, v in s.items() if k != "payload"} for s in steps_log]
    all_ok = all(s["ok"] or s.get("non_fatal") for s in clean_steps)
    summary = {
        "label": eff_label,
        "run_dir": str(run_dir),
        "out_root": str(eff_out_root),
        "loop_dir": str(loop_dir),
        "total_elapsed_sec": round(time.monotonic() - t_total, 3),
        "all_ok": all_ok,
        "steps": clean_steps,
        "score_overview": _extract_score_overview(score_json),
        "s2_summary": {
            "replays_total": s2_payload.get("replays_total", 0),
            "replays_ok": s2_payload.get("replays_ok", 0),
            "p1_totals": s2_payload.get("p1_totals", {}),
            "p1_games": s2_payload.get("p1_games", {}),
        },
        "pro_deep_overview": _extract_pro_deep_overview(pro_deep_json),
        "forensics_diff_overview": fd_overview,
    }
    summary_path = loop_dir / "pipeline_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary["summary_path"] = str(summary_path)
    return summary


def build_arg_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="One-command parallel post-bench pipeline (scoring, SQLite ingest + extract-raw, pro_deep, trade review, s2protocol audit, forensics diff, dashboard, optional trajectory log)."
    )
    ap.add_argument("run_dir", help="Path to SC2 local arena run directory")
    ap.add_argument("--label", default=None, help="Output label (default: run_dir name without timestamp prefix)")
    ap.add_argument("--baseline-run", default=None, help="Optional baseline run directory for forensics-diff.py")
    ap.add_argument("--baseline-score", default=None, help="Optional baseline score JSON for compare-vs-pro & forensics-diff")
    ap.add_argument("--out-root", default=None, help="Output root dir (default: scratch dir)")
    ap.add_argument("--replay-db", default=str(DEFAULT_DB_PATH), help="SQLite DB path (default: arena_replays.sqlite)")
    ap.add_argument("--pylibs-dir", default=str(DEFAULT_PYLIBS_DIR), help="Directory containing mpyq & s2protocol")
    ap.add_argument("--skip-dashboard", action="store_true", help="Skip tools/update-dashboard-state.py --auto")
    ap.add_argument("--skip-db-ingest", action="store_true", help="Skip tools/replay-db.py ingest-runs & extract-raw")
    ap.add_argument("--skip-pro-deep", action="store_true", help="Skip tools/pro-deep-comparison.py")
    ap.add_argument("--log-trajectory", action="store_true", help="Optionally invoke log-loop-trajectory.py (non-fatal)")
    ap.add_argument("--loop-id", type=int, default=None, help="Optional --loop ID passed to log-loop-trajectory.py")
    ap.add_argument("--sub-iter", default=None, help="Optional --sub-iter label passed to log-loop-trajectory.py")
    ap.add_argument("--trajectory-jsonl", default=None, help="Optional --out-jsonl override for --log-trajectory")
    ap.add_argument("--workers", type=int, default=8, help="Parallel worker count (default: 8)")
    return ap


def main(argv: list[str] | None = None) -> int:
    ap = build_arg_parser()
    args = ap.parse_args(argv)

    summary = run_pipeline(
        Path(args.run_dir),
        label=args.label,
        baseline_run=Path(args.baseline_run) if args.baseline_run else None,
        baseline_score=Path(args.baseline_score) if args.baseline_score else None,
        out_root=Path(args.out_root) if args.out_root else None,
        replay_db=Path(args.replay_db),
        pylibs_dir=Path(args.pylibs_dir),
        skip_dashboard=args.skip_dashboard,
        skip_db_ingest=args.skip_db_ingest,
        skip_pro_deep=args.skip_pro_deep,
        log_trajectory=args.log_trajectory,
        loop_id=args.loop_id,
        sub_iter=args.sub_iter,
        trajectory_jsonl=Path(args.trajectory_jsonl) if args.trajectory_jsonl else None,
        workers=args.workers,
    )
    print(_render_board_summary(summary))
    return 0 if summary["all_ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
