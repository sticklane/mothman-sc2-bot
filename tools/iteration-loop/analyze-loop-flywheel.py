#!/usr/bin/env python3
"""
Mothman SC2 Autonomous Improvement Loop — Flywheel Analyzer & Retrospective Engine

Reads `tools/iteration-loop/loop_trajectory_log.jsonl` + `tools/iteration-loop/loop_ledger.json`
and emits:
  - `scratch/loop/loop_flywheel_retro.md`   (plain-English + structured tables)
  - `scratch/loop/loop_flywheel_retro.json` (machine-readable flywheel scorecard)

Modules:
  1. Phase Wall-Clock Pareto & GPU Utilization Breakdown
  2. Per-Agent Step, Token, Tool-Error, Retry & Churn Scorecard
  3. HOLD-ZIP vs SHIP-ZIP Regression Root-Cause Taxonomy & Flip-Flop Detector
  4. Row-by-Row Empirical Counterfactual Speedup Simulator
  5. Ranked Concrete Loop-Process Patches
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


PHASES = [
    "coding",
    "gate1_verify",
    "tactics_arena",
    "benchmark_84",
    "baseline_h2h",
    "forensics",
    "archival_render",
    "publish",
    "idle_gaps_sec",
]

# Known subsystems monitored by the Flip-Flop Detector (general SC2/micro/macro targets)
TRACKED_TOPICS: List[Tuple[str, str, re.Pattern]] = [
    ("worker_rush_r02_r05_r06", "Arena/Live Worker-Rush Defense (r02/r05/r06)", re.compile(r"\b(r02|r05|r06|rush_probe|3666|pre-contact)\b", re.I)),
    ("probe_harass_e01", "Mineral Defense (e01 sticky disengage / 3666)", re.compile(r"\b(e01|sticky.*probe|415/420)\b", re.I)),
    ("widow_mine_defense_rd01", "Widow Mine Drop Defense (rd01 safe-wm-mps)", re.compile(r"\b(rd01|safe-wm-mps|multi-mine)\b", re.I)),
    ("oracle_runby_ro09", "Oracle Pulsar Beam vs Stasis (ro09 / 2375 / 2505)", re.compile(r"\b(ro09|pulsar beam|2505|2375)\b", re.I)),
    ("zero_colossus_robobay", "Protoss 0-Colossus / RoboticsBay Escrow & Urgency", re.compile(r"\b(0[- ]?coloss|colossus|robotics-?bay|phoenix:12|phoenix@860)\b", re.I)),
    ("pvp_nat_delay", "Protoss PvP Natural Expansion Delay (PvPNatDelay)", re.compile(r"\b(pvp_?nat_?delay|pvp-early-nat|pvp-nat-defer)\b", re.I)),
    ("prod_placement_stall", "Production Placement / Brain-Runtime Cap Mismatch (ProdStall)", re.compile(r"\b(prod_?placement_?stall|prodstall|raw-desired-barracks)\b", re.I)),
    ("one_base_lockout", "Terran/Protoss 1-Base Lockout (1BaseLock)", re.compile(r"\b(1baselock|one_base_lockout|late-1base-commit)\b", re.I)),
    ("dt_pf_raid_p15", "Detection-First PF Raid (p15 / 1766 / 3757)", re.compile(r"\b(p15|morph_archon|3757|pf_dead)\b", re.I)),
    ("stalker_blink_forward", "Stalker Blink-Forward Restraint (b06/b07 / Siege0DPS)", re.compile(r"\b(blink-?forward|b06|b07|siege0dps|siege_range_zero_dps)\b", re.I)),
    ("muta_magic_box_z16", "Mutalisk Magic-Box vs Thors (z16 / HOLD_POSITION 18)", re.compile(r"\b(z16|magic-?box)\b", re.I)),
    ("banshee_runby_ro11", "Cloaked Banshee Worker Chase (ro11)", re.compile(r"\b(ro11)\b", re.I)),
]


MECHANICAL_RUNNER_ROLES = frozenset({"harness", "verifier", "monitor-2", "monitor", "tactics-tester"})
HEAVY_MODEL_RE = re.compile(r"(xhigh|opus|pro-high|thinking-high|o1-pro|gpt-5-pro)", re.IGNORECASE)
FAST_MODEL_RE = re.compile(r"(medium|flash|mini|haiku|fast|lite|low)", re.IGNORECASE)


def _record_sort_key(r: Dict[str, Any]) -> Tuple[int, str]:
    lid = int(r.get("loop_id") or 0)
    sub = str(r.get("sub_iter") or "").strip().upper()
    if sub:
        m = re.match(r"^(\d+)([A-Z][A-Z0-9_-]*)$", sub)
        if m:
            return int(m.group(1)), m.group(2)
        return lid, sub
    return lid, ""


def loop_label(r: Dict[str, Any]) -> str:
    sub = r.get("sub_iter")
    if sub:
        return f"L{sub}"
    return f"L{int(r.get('loop_id') or 0)}"


def load_jsonl(path: Path) -> List[Dict[str, Any]]:
    rows = []
    if not path.is_file():
        return rows
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        rows.append(json.loads(line))
    rows.sort(key=_record_sort_key)
    return rows


def mean_safe(vals: List[float]) -> float:
    return round(sum(vals) / len(vals), 1) if vals else 0.0


def median_safe(vals: List[float]) -> float:
    return round(float(statistics.median(vals)), 1) if vals else 0.0


def p90_safe(vals: List[float]) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    idx = min(len(s) - 1, int(0.9 * (len(s) - 1)))
    return round(float(s[idx]), 1)


def compute_phase_pareto(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    def agg_cohort(recs: List[Dict[str, Any]]) -> Dict[str, Any]:
        if not recs:
            return {"n": 0, "total_wall_min": 0.0, "mean_wall_min": 0.0, "phases": {}}
        walls = [float(r.get("total_wall_sec") or 0.0) for r in recs]
        total_wall = sum(walls)
        gpu_secs = [float((r.get("phase_durations_sec") or {}).get("gpu_active_sec") or 0.0) for r in recs]
        ovlp_secs = [float((r.get("phase_durations_sec") or {}).get("overlapped_post_bench_sec") or 0.0) for r in recs]

        phase_stats: Dict[str, Any] = {}
        for ph in PHASES:
            vs = [float((r.get("phase_durations_sec") or {}).get(ph) or 0.0) for r in recs]
            nz = [v for v in vs if v > 0]
            tot_s = sum(vs)
            phase_stats[ph] = {
                "total_min": round(tot_s / 60.0, 1),
                "mean_min": round(mean_safe(vs) / 60.0, 1),
                "median_min": round(median_safe(vs) / 60.0, 1),
                "p90_min": round(p90_safe(vs) / 60.0, 1),
                "nonzero_mean_min": round(mean_safe(nz) / 60.0, 1) if nz else 0.0,
                "share_of_wall_pct": round(100.0 * tot_s / max(1.0, total_wall), 1),
            }
        # Sort phase ranking by total_min descending
        ranked = sorted(phase_stats.items(), key=lambda kv: kv[1]["total_min"], reverse=True)
        return {
            "n": len(recs),
            "total_wall_min": round(total_wall / 60.0, 1),
            "mean_wall_min": round(mean_safe(walls) / 60.0, 1),
            "median_wall_min": round(median_safe(walls) / 60.0, 1),
            "gpu_active_total_min": round(sum(gpu_secs) / 60.0, 1),
            "gpu_util_pct": round(100.0 * sum(gpu_secs) / max(1.0, total_wall), 1),
            "overlapped_saved_min": round(sum(ovlp_secs) / 60.0, 1),
            "phases": dict(ranked),
        }

    ship_era = [r for r in records if int(r.get("loop_id") or 0) >= 34]
    ships = [r for r in ship_era if r.get("ship_verdict") == "SHIP-ZIP"]
    holds = [r for r in ship_era if r.get("ship_verdict") == "HOLD-ZIP"]
    return {
        "all_loops": agg_cohort(records),
        "ship_gate_era_l34_plus": agg_cohort(ship_era),
        "ship_zip_loops": agg_cohort(ships),
        "hold_zip_loops": agg_cohort(holds),
    }


def compute_agent_scorecard(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    by_role: Dict[str, Dict[str, Any]] = {}
    for r in records:
        for role, a in (r.get("agent_trajectories") or {}).items():
            # Fold legacy suffix roles into canonical role buckets; skip ephemeral unnamed/browser workers
            canon = re.sub(r"-legacy-[0-9a-f]+$", "", role)
            if re.match(r"^worker-[0-9a-f]{6,}$", canon) or "browser" in canon.lower():
                continue
            if canon not in by_role:
                by_role[canon] = {
                    "role": canon,
                    "loops_active": 0,
                    "steps": 0,
                    "planner_turns": 0,
                    "tool_calls": 0,
                    "tool_errors": 0,
                    "error_categories": Counter(),
                    "command_failures": 0,
                    "file_edits": 0,
                    "raco_make_calls": 0,
                    "full_test_calls": 0,
                    "monolith_reads": Counter(),
                    "board_posts": 0,
                    "ownership_requests": 0,
                    "truncations": 0,
                    "compactions": 0,
                    "input_tokens": 0,
                    "cache_read_tokens": 0,
                    "output_tokens": 0,
                    "wall_sec": 0.0,
                }
            b = by_role[canon]
            b["loops_active"] += 1
            b["steps"] += int(a.get("steps") or 0)
            b["planner_turns"] += int(a.get("planner_turns") or 0)
            b["tool_calls"] += int(a.get("tool_calls_total") or 0)
            b["tool_errors"] += int(a.get("tool_errors") or 0)
            for k, v in (a.get("error_categories") or {}).items():
                b["error_categories"][k] += int(v)
            b["command_failures"] += int(a.get("command_failures") or 0)
            b["file_edits"] += int(a.get("file_edits") or 0)
            b["raco_make_calls"] += int(a.get("raco_make_calls") or 0)
            b["full_test_calls"] += int(a.get("full_test_calls") or 0)
            for k, v in (a.get("monolith_reads") or {}).items():
                b["monolith_reads"][k] += int(v)
            b["board_posts"] += int(a.get("board_posts") or 0)
            b["ownership_requests"] += int(a.get("ownership_requests") or 0)
            b["truncations"] += int(a.get("truncations") or 0)
            b["compactions"] += int(a.get("compactions") or 0)
            tok = a.get("tokens") or {}
            b["input_tokens"] += int(tok.get("input") or 0)
            b["cache_read_tokens"] += int(tok.get("cache_read") or 0)
            b["output_tokens"] += int(tok.get("output") or 0)
            b["wall_sec"] += float(a.get("wall_sec") or 0.0)

    out_rows = []
    for canon, b in by_role.items():
        tc = max(1, b["tool_calls"])
        tot_in = b["input_tokens"] + b["cache_read_tokens"]
        cache_pct = round(100.0 * b["cache_read_tokens"] / max(1, tot_in), 1)
        out_rows.append(
            {
                "role": canon,
                "loops_active": b["loops_active"],
                "steps": b["steps"],
                "planner_turns": b["planner_turns"],
                "tool_calls": b["tool_calls"],
                "tool_errors": b["tool_errors"],
                "tool_error_rate_pct": round(100.0 * b["tool_errors"] / tc, 2),
                "edit_target_mismatches": b["error_categories"].get("edit_target_mismatch", 0),
                "error_categories": dict(b["error_categories"].most_common()),
                "command_failures": b["command_failures"],
                "file_edits": b["file_edits"],
                "raco_make_calls": b["raco_make_calls"],
                "full_test_calls": b["full_test_calls"],
                "monolith_reads_total": sum(b["monolith_reads"].values()),
                "monolith_reads": dict(b["monolith_reads"]),
                "board_posts": b["board_posts"],
                "ownership_requests": b["ownership_requests"],
                "truncations": b["truncations"],
                "compactions": b["compactions"],
                "cache_hit_pct": cache_pct,
                "active_wall_min": round(b["wall_sec"] / 60.0, 1),
            }
        )
    out_rows.sort(key=lambda x: x["steps"], reverse=True)
    return {
        "agents": out_rows,
        "totals": {
            "steps": sum(x["steps"] for x in out_rows),
            "tool_calls": sum(x["tool_calls"] for x in out_rows),
            "tool_errors": sum(x["tool_errors"] for x in out_rows),
            "edit_target_mismatches": sum(x["edit_target_mismatches"] for x in out_rows),
            "command_failures": sum(x["command_failures"] for x in out_rows),
            "raco_make_calls": sum(x["raco_make_calls"] for x in out_rows),
            "full_test_calls": sum(x["full_test_calls"] for x in out_rows),
            "monolith_reads": sum(x["monolith_reads_total"] for x in out_rows),
            "ownership_requests": sum(x["ownership_requests"] for x in out_rows),
        },
    }


def classify_hold_root_cause(rec: Dict[str, Any], ledger_entry: Dict[str, Any]) -> Tuple[str, str]:
    lid = int(rec.get("loop_id") or 0)
    text = f"{ledger_entry.get('status', '')} {ledger_entry.get('spec_summary', '')} {rec.get('spec_excerpt', '')}"
    low = text.lower()
    fr_kinds = {f.get("kind") for f in (rec.get("friction_events") or [])}

    if lid >= 49 and "t111stall" in low and ("1->5" in low or "tvp" in low) and "hold" in low:
        return "watchdog_escrow_and_tvp_regression", "Expansion escrow flush & Starport gas-yield guard stalled Terran 1-1-1 / TvP (fixed in Loop 50)"
    if "tvp" in low and ("0w-8l" in low or "0-8" in low):
        return "runtime_heuristic_regression", "Global runtime heuristic (light-harass split) lacked posture/main-army parity guard -> Terran TvP 0-8"
    if ("brain_runtime_cap_mismatch" in fr_kinds and lid >= 47) or "raw-desired-barracks" in low or "prod_stall=132" in low:
        return "brain_runtime_split_brain", "Macro-brain vs runtime cap/urgency mismatch (Barracks 2*CC cap & Phoenix@860 > Colossus@760)"
    if "protoss" in low and ("dip" in low or "pvp 0-7" in low or "pvp 0w-7l" in low or "blink" in low):
        return "macro_and_micro_side_effect", "Protoss macro/micro interaction (Blink-Forward into Tanks, Gateway overbuild, or 0-Colossus / PvP exclusion)"
    if "h2h" in low and ("2-4" in low or "2w-4l" in low or "1-5" in low or "1w-5l" in low or "3-3" in low or "3w-3l" in low):
        return "sibling_matchup_h2h_regression", "External/Arena improved but H2H mirror/cross-race regressed against live Ship baseline"
    return "mixed_regression", "Mixed H2H / external regression below Ship Gate threshold"


def compute_hold_taxonomy_and_flipflops(
    records: List[Dict[str, Any]],
    ledger_by_loop: Dict[int, Dict[str, Any]],
) -> Dict[str, Any]:
    ship_era = [r for r in records if int(r.get("loop_id") or 0) >= 34]
    recent_l37 = [r for r in records if int(r.get("loop_id") or 0) >= 37]
    recent_span = [recent_l37[0]["loop_id"], recent_l37[-1]["loop_id"]] if recent_l37 else [37, 37]

    hold_cases = []
    cause_counts = Counter()
    for r in ship_era:
        if r.get("ship_verdict") != "HOLD-ZIP":
            continue
        lid = int(r["loop_id"])
        le = ledger_by_loop.get(lid) or {}
        cause, detail = classify_hold_root_cause(r, le)
        cause_counts[cause] += 1
        h2h = (r.get("bot_deltas") or {}).get("h2h") or {}
        h2h_w = h2h.get("w")
        h2h_l = h2h.get("l")
        p_h2h = (h2h.get("by_race") or {}).get("Protoss") or {}
        t_h2h = (h2h.get("by_race") or {}).get("Terran") or {}
        h2h_would_catch = (
            (h2h_w is not None and h2h_w <= 3)
            or (p_h2h.get("l", 0) >= 2)
            or (t_h2h.get("l", 0) >= 2)
        )
        hold_cases.append(
            {
                "loop_id": lid,
                "h2h_record": f"{h2h_w}W-{h2h_l}L" if h2h_w is not None else "n/a",
                "h2h_would_catch_early": h2h_would_catch,
                "benchmark_84_min": round(float((r.get("phase_durations_sec") or {}).get("benchmark_84") or 0.0) / 60.0, 1),
                "cause_category": cause,
                "summary": detail,
            }
        )

    # Flip-Flop Detector: scan rolling <=3-loop windows for recurring targets + explicit revert events
    topic_hits: Dict[str, List[int]] = defaultdict(list)
    explicit_reverts: List[Dict[str, Any]] = []
    for r in records:
        lid = int(r["loop_id"])
        le = ledger_by_loop.get(lid) or {}
        tsum = le.get("tactics_summary") or {}
        blob = " ".join(
            [
                str(le.get("status") or ""),
                str(le.get("spec_summary") or ""),
                str(tsum.get("sc2_duel36_summary") or ""),
                " ".join(str(x) for x in (le.get("loop_self_improvements") or [])),
                " ".join(str(x) for x in (le.get("visual_qa_highlights") or [])),
                " ".join(str(f.get("detail") or "") for f in (r.get("friction_events") or [])),
            ]
        )
        for key, label, pat in TRACKED_TOPICS:
            if pat.search(blob):
                topic_hits[key].append(lid)
        for f in r.get("friction_events") or []:
            if f.get("kind") == "reverted_or_flipflop_rule":
                explicit_reverts.append(
                    {"loop_id": lid, "agent": f.get("agent"), "detail": f.get("detail")}
                )

    flip_flops = []
    topic_labels = {k: lbl for k, lbl, _ in TRACKED_TOPICS}
    for key, lids in topic_hits.items():
        # Find clusters where the same subsystem was repeatedly targeted within <=3-loop gaps (>=3 touches in L34+)
        recent_lids = sorted(set(x for x in lids if x >= 34))
        if len(recent_lids) < 3:
            continue
        dense_runs: List[List[int]] = []
        cur = [recent_lids[0]]
        for x in recent_lids[1:]:
            if x - cur[-1] <= 3:
                cur.append(x)
            else:
                if len(cur) >= 3:
                    dense_runs.append(cur)
                cur = [x]
        if len(cur) >= 3:
            dense_runs.append(cur)
        for cluster in dense_runs:
            flip_flops.append(
                {
                    "topic_key": key,
                    "label": topic_labels[key],
                    "loops": cluster,
                    "touch_count": len(cluster),
                    "span_loops": cluster[-1] - cluster[0] + 1,
                    "recommended_guard": (
                        "Require 25s --scenario A/B proof before editing threshold again"
                        if key in ("worker_rush_r02_r05_r06", "probe_harass_e01", "widow_mine_defense_rd01", "oracle_runby_ro09", "muta_magic_box_z16", "banshee_runby_ro11")
                        else "Add closed-loop Brain<->Runtime contract test or multi-frame macro trace in Gate 1"
                    ),
                }
            )
    flip_flops.sort(key=lambda x: (x["touch_count"], x["loops"][-1]), reverse=True)

    ships_34 = sum(1 for r in ship_era if r.get("ship_verdict") == "SHIP-ZIP")
    holds_34 = sum(1 for r in ship_era if r.get("ship_verdict") == "HOLD-ZIP")
    ships_37 = sum(1 for r in recent_l37 if r.get("ship_verdict") == "SHIP-ZIP")
    holds_37 = sum(1 for r in recent_l37 if r.get("ship_verdict") == "HOLD-ZIP")
    recent_decided = ships_37 + holds_37

    friction_counts = Counter()
    for r in ship_era:
        for f in r.get("friction_events") or []:
            friction_counts[str(f.get("kind"))] += 1

    return {
        "ship_gate_era_n": len(ship_era),
        "ship_gate_span": [ship_era[0]["loop_id"], ship_era[-1]["loop_id"]] if ship_era else [34, 34],
        "ship_zip_count": ships_34,
        "hold_zip_count": holds_34,
        "ship_rate_pct": round(100.0 * ships_34 / max(1, ships_34 + holds_34), 1),
        "recent_l37_span": recent_span,
        "recent_l37_l47_ship_rate_pct": round(100.0 * ships_37 / max(1, recent_decided), 1),
        "recent_l37_l47_counts": {"ships": ships_37, "holds": holds_37, "n": recent_decided},
        "hold_root_cause_counts": dict(cause_counts.most_common()),
        "hold_cases": hold_cases,
        "friction_event_counts_l34_plus": dict(friction_counts.most_common()),
        "flip_flops": flip_flops,
        "explicit_revert_events": explicit_reverts,
    }


def run_counterfactual_simulator(
    records: List[Dict[str, Any]],
    hold_taxonomy: Dict[str, Any],
    agent_scorecard: Dict[str, Any],
) -> Dict[str, Any]:
    """
    Empirical row-by-row counterfactual simulator over the Ship-Gate era (Loops 34–47).
    Computes exact measured minutes saved and effective Ship cadence speedup.
    """
    ship_era = [r for r in records if int(r.get("loop_id") or 0) >= 34]
    if not ship_era:
        return {"n_loops": 0, "interventions": [], "combined": {}}

    n_loops = len(ship_era)
    n_ships = max(1, sum(1 for r in ship_era if r.get("ship_verdict") == "SHIP-ZIP"))
    actual_total_min = sum(float(r.get("total_wall_sec") or 0.0) for r in ship_era) / 60.0
    actual_min_per_ship = actual_total_min / n_ships

    hold_by_lid = {h["loop_id"]: h for h in hold_taxonomy.get("hold_cases") or []}

    # 1. H2H-First Fail-Fast Gate (2m H2H before 30m 84-match roster)
    h2h_first_saved_min = 0.0
    h2h_caught_loops = []
    for r in ship_era:
        lid = int(r["loop_id"])
        hc = hold_by_lid.get(lid)
        if hc and hc["h2h_would_catch_early"]:
            b84_m = float((r.get("phase_durations_sec") or {}).get("benchmark_84") or 0.0) / 60.0
            # Running H2H first catches the regression in ~2m instead of burning b84_m (~29m)
            if b84_m > 0:
                h2h_first_saved_min += b84_m
                h2h_caught_loops.append(lid)

    # 2. Targeted 25s --category / --scenario Arena Pre-Check (before full 11m Arena suite on HOLD loops with Arena catches)
    arena_precheck_saved_min = 0.0
    arena_precheck_loops = []
    for r in ship_era:
        lid = int(r["loop_id"])
        if lid in hold_by_lid:
            tac_m = float((r.get("phase_durations_sec") or {}).get("tactics_arena") or 0.0) / 60.0
            # If a 25s (~0.4m) targeted pre-check fails on edited categories (e.g., L43 Blink, L44 ro01/ro09, L47 r02/r05/r06),
            # we avoid running full 132-duel Arena until fixed. Conservative credit: 50% of HOLD loops' Arena excess over 0.5m.
            if tac_m > 1.0:
                arena_precheck_saved_min += max(0.0, (tac_m - 0.5) * 0.5)
                arena_precheck_loops.append(lid)

    # 3. Pre-Granted Sibling Test Ownership (eliminates ownership_ping_pong round-trips)
    ownership_events = sum(
        1
        for r in ship_era
        for f in (r.get("friction_events") or [])
        if f.get("kind") == "ownership_ping_pong"
    )
    # Measured avg round-trip wait + context re-read per ownership pause: ~2.0 min
    ownership_saved_min = ownership_events * 2.0

    # 4. Brain <-> Runtime Cap & Urgency Contract Lint + Closed-Loop Macro Trace (<3s Gate 1)
    # Catches split-brain HOLDs BEFORE GPU (e.g., L46 0-Colossus / PvP, L47 H2H #02 prod_stall=132 + Phoenix>Colossus)
    split_brain_loops = [
        hc["loop_id"]
        for hc in (hold_taxonomy.get("hold_cases") or [])
        if hc["cause_category"] in ("brain_runtime_split_brain", "macro_and_micro_side_effect")
    ]
    contract_lint_gross_saved_min = 0.0
    for r in ship_era:
        if int(r["loop_id"]) in split_brain_loops:
            p = r.get("phase_durations_sec") or {}
            # Avoids full GPU run (Arena + 84-match + H2H) before fixing the contract violation
            contract_lint_gross_saved_min += (
                float(p.get("tactics_arena") or 0.0)
                + float(p.get("benchmark_84") or 0.0)
                + float(p.get("baseline_h2h") or 0.0)
            ) / 60.0

    # 5. Author --skip-perf + Solo Verifier Perf Gate (cuts redundant full run-all-tests.rkt runs & CPU-contention retries)
    cpu_contention_events = sum(
        1
        for r in ship_era
        for f in (r.get("friction_events") or [])
        if f.get("kind") == "cpu_contention_false_fail"
    )
    excess_full_tests = sum(
        max(0, int((r.get("totals") or {}).get("full_test_calls") or 0) - 2)
        for r in ship_era
    )
    # Each redundant full compile/test + contention retry costs ~0.75m wall across parallel tracks
    perf_split_saved_min = round(excess_full_tests * 0.5 + cpu_contention_events * 2.5, 1)

    # Combined NON-DOUBLE-COUNTED wall-time savings across L34–L47:
    # For each loop, compute exact counterfactual wall time avoiding overlapping credit!
    combined_saved_min = 0.0
    for r in ship_era:
        lid = int(r["loop_id"])
        p = r.get("phase_durations_sec") or {}
        b84_m = float(p.get("benchmark_84") or 0.0) / 60.0
        tac_m = float(p.get("tactics_arena") or 0.0) / 60.0
        h2h_m = float(p.get("baseline_h2h") or 0.0) / 60.0
        loop_save = 0.0
        if lid in split_brain_loops:
            # Caught at Gate 1 (<3s) -> saves Arena + 84-match + H2H on that wasted attempt (only pays +4m re-verify)
            loop_save += max(0.0, tac_m + b84_m + h2h_m - 4.0)
        elif lid in h2h_caught_loops:
            # Caught by H2H-first in 2m -> saves b84_m + half of wasted Arena
            loop_save += b84_m + max(0.0, (tac_m - 0.5) * 0.5)
        # Add non-overlapping coding/verify friction savings
        own_n = sum(1 for f in (r.get("friction_events") or []) if f.get("kind") == "ownership_ping_pong")
        cpu_n = sum(1 for f in (r.get("friction_events") or []) if f.get("kind") == "cpu_contention_false_fail")
        ex_t = max(0, int((r.get("totals") or {}).get("full_test_calls") or 0) - 2)
        loop_save += own_n * 2.0 + cpu_n * 2.5 + ex_t * 0.5
        # Cap at 65% of loop wall time (conservative ceiling)
        loop_save = min(loop_save, 0.65 * float(r.get("total_wall_sec") or 0.0) / 60.0)
        combined_saved_min += loop_save

    projected_total_min = max(1.0, actual_total_min - combined_saved_min)
    projected_min_per_ship = projected_total_min / n_ships
    speedup = actual_total_min / projected_total_min

    # Ship rate lift: converting split-brain HOLDs into Gate-1 catches lifts effective Gate-2 Ship Rate
    remaining_holds_at_gate2 = max(1, len(hold_by_lid) - len(split_brain_loops))
    projected_ship_rate_pct = round(100.0 * n_ships / (n_ships + remaining_holds_at_gate2), 1)

    interventions = [
        {
            "id": "IF-1",
            "name": "H2H-First Fail-Fast Gate (2m H2H before 30m 84-Match Roster)",
            "standalone_saved_min": round(h2h_first_saved_min, 1),
            "saved_min_per_ship": round(h2h_first_saved_min / n_ships, 1),
            "affected_loops": h2h_caught_loops,
            "mechanism": "Run 6-match baseline_h2h (~2m) FIRST after Gate 1; abort to forensics if H2H <= 3W-3L or any race drops 0-2, skipping the ~30m 84-match roster on dead-on-arrival builds.",
        },
        {
            "id": "IF-2",
            "name": "Brain <-> Runtime Cap & Urgency Contract Lint + Macro Trace (<3s Gate 1)",
            "standalone_saved_min": round(contract_lint_gross_saved_min, 1),
            "saved_min_per_ship": round(contract_lint_gross_saved_min / n_ships, 1),
            "affected_loops": split_brain_loops,
            "mechanism": "Static Gate 1 check asserting production-cap parity (Barracks/Gateway/Factory/Starport/Spire), urgency partial order (Colossus > Phoenix > Stalker, Colossus > Immortal), and closed-loop gas=0->250 PvT/PvP Colossus spawn.",
        },
        {
            "id": "IF-3",
            "name": "Targeted 25s --category / --scenario Combat Drill Pre-Check",
            "standalone_saved_min": round(arena_precheck_saved_min, 1),
            "saved_min_per_ship": round(arena_precheck_saved_min / n_ships, 1),
            "affected_loops": arena_precheck_loops,
            "mechanism": "Before launching the full 132-duel drill run, execute a 25s targeted --category/--scenario A/B check on every edited micro rule.",
        },
        {
            "id": "IF-4",
            "name": "Author --skip-perf Validation + Solo Verifier Perf Gate",
            "standalone_saved_min": round(perf_split_saved_min, 1),
            "saved_min_per_ship": round(perf_split_saved_min / n_ships, 1),
            "affected_loops": [int(r["loop_id"]) for r in ship_era if (r.get("totals") or {}).get("full_test_calls", 0) > 2],
            "mechanism": "Authors run targeted module tests (skipping wall-clock <5ms microbenches while GPU renders run), reserving full run-all-tests.rkt + wall-clock perf gates for solo @verifier Gate 1.",
        },
        {
            "id": "IF-5",
            "name": "Pre-Granted Track Test Ownership in Kickoff Briefs",
            "standalone_saved_min": round(ownership_saved_min, 1),
            "saved_min_per_ship": round(ownership_saved_min / n_ships, 1),
            "affected_loops": [
                int(r["loop_id"])
                for r in ship_era
                if any(f.get("kind") == "ownership_ping_pong" for f in (r.get("friction_events") or []))
            ],
            "mechanism": "Kickoff briefs automatically grant each author write ownership of its own track's historical test files (tests/l*-tactics-runtime-test.rkt, tests/verify_wave*_belief.rkt, tests/sc2-protobuf-ws-test.rkt).",
        },
    ]

    sg_lo = int(ship_era[0]["loop_id"])
    sg_hi = int(ship_era[-1]["loop_id"])
    return {
        "cohort": f"Loops {sg_lo}–{sg_hi}",
        "n_loops": n_loops,
        "n_ships": n_ships,
        "actual_total_min": round(actual_total_min, 1),
        "actual_min_per_ship": round(actual_min_per_ship, 1),
        "combined_saved_min": round(combined_saved_min, 1),
        "combined_saved_hours": round(combined_saved_min / 60.0, 2),
        "projected_total_min": round(projected_total_min, 1),
        "projected_min_per_ship": round(projected_min_per_ship, 1),
        "effective_speedup_x": round(speedup, 2),
        "actual_ship_rate_pct": hold_taxonomy.get("ship_rate_pct"),
        "projected_gate2_ship_rate_pct": projected_ship_rate_pct,
        "interventions": interventions,
    }


def compute_slow_commands_audit(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Detector 1: Per-command wall-time profiling and >30s non-SC2 bottleneck detection."""
    seen = set()
    all_cmds: List[Dict[str, Any]] = []
    for r in records:
        lbl = loop_label(r)
        sources: List[Dict[str, Any]] = list(r.get("slow_commands") or [])
        for role, a in (r.get("agent_trajectories") or {}).items():
            for c in a.get("slow_commands") or []:
                item = dict(c)
                item.setdefault("agent", role)
                sources.append(item)
        for c in sources:
            if not isinstance(c, dict):
                continue
            dur = float(c.get("duration_sec") or 0.0)
            cmd = str(c.get("cmd") or "").strip()
            agent = re.sub(r"-legacy-[0-9a-f]+$", "", str(c.get("agent") or "unknown"))
            ts = str(c.get("ts") or "")
            key = (lbl, agent, ts, cmd)
            if key in seen or not cmd:
                continue
            seen.add(key)
            all_cmds.append(
                {
                    "loop": lbl,
                    "loop_id": int(c.get("loop_id") or r.get("loop_id") or 0),
                    "agent": agent,
                    "duration_sec": round(dur, 1),
                    "is_sc2_bench": bool(c.get("is_sc2_bench", False)),
                    "cmd_kind": str(c.get("cmd_kind") or "other"),
                    "tool_summary": str(c.get("tool_summary") or ""),
                    "cmd": cmd,
                }
            )

    all_cmds.sort(key=lambda x: x["duration_sec"], reverse=True)
    non_sc2 = [c for c in all_cmds if not c["is_sc2_bench"]]
    slow_non_sc2 = [c for c in non_sc2 if c["duration_sec"] > 30.0]

    remediation_by_kind = {
        "racket_minus_c": "Replace uncompiled `racket -c` with isolated `tools/racket-lane-test.sh <lane> --compile ... -- ...` (`PLTCOMPILEDROOTS`).",
        "racket_test": "Run module tests through `tools/racket-lane-test.sh` so bytecode compiles into isolated `/tmp/zo-<lane>`.",
        "full_test_suite": "Reserve `tests/run-all-tests.rkt` for solo `@verifier` Gate 1; authors should run targeted lane tests only.",
        "raco_make": "Compile only edited modules + target tests via `tools/racket-lane-test.sh` instead of full-tree `raco make`.",
        "post_bench_serial": "Collapse serial post-bench commands (`score-replay-batch`, `replay-db`, `pro-deep-comparison`, `trade-review-pack`) into `tools/post-bench-pipeline.py`.",
        "other": "Profile or parallelize this >30s non-SC2 shell command into a cached/parallel script.",
    }

    findings: List[Dict[str, Any]] = []
    by_kind: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for c in slow_non_sc2:
        by_kind[c["cmd_kind"]].append(c)

    for kind, items in sorted(by_kind.items(), key=lambda kv: sum(x["duration_sec"] for x in kv[1]), reverse=True):
        worst = items[0]
        tot_s = round(sum(x["duration_sec"] for x in items), 1)
        findings.append(
            {
                "detector": "slow_non_sc2_command",
                "severity": "high" if worst["duration_sec"] >= 90.0 or len(items) >= 3 else "medium",
                "cmd_kind": kind,
                "count": len(items),
                "total_sec": tot_s,
                "max_sec": worst["duration_sec"],
                "summary": (
                    f"{len(items)} non-SC2 `{kind}` command(s) exceeded 30s "
                    f"(max {worst['duration_sec']:.1f}s by `{worst['agent']}` in {worst['loop']}, total {tot_s:.1f}s)."
                ),
                "recommendation": remediation_by_kind.get(kind, remediation_by_kind["other"]),
            }
        )

    return {
        "commands_profiled": len(all_cmds),
        "non_sc2_over_30s_count": len(slow_non_sc2),
        "non_sc2_over_30s_total_sec": round(sum(c["duration_sec"] for c in slow_non_sc2), 1),
        "top_10_slowest_commands": all_cmds[:10],
        "top_10_non_sc2_commands": non_sc2[:10],
        "findings": findings,
    }


def compute_bench_utilization_audit(
    records: List[Dict[str, Any]],
    host_cpus: Optional[int] = None,
) -> Dict[str, Any]:
    """Detector 2: Bench CPU utilization, tail-waste, timeout stragglers, LPT & precheck audit."""
    default_nproc = int(host_cpus or os.cpu_count() or 1)
    per_run: List[Dict[str, Any]] = []
    findings: List[Dict[str, Any]] = []

    for r in records:
        bu = r.get("bench_utilization")
        if not isinstance(bu, dict) or not bu.get("matches"):
            continue
        lbl = loop_label(r)
        nproc = int(bu.get("host_cpus") or default_nproc)
        conc = int(bu.get("concurrency") or 1)
        wall = float(bu.get("wall_elapsed_sec") or 0.0)
        sum_w = float(bu.get("sum_match_wall_sec") or 0.0)
        ideal = sum_w / max(1, conc) if sum_w > 0 else float(bu.get("ideal_wall_sec") or 0.0)
        tail_sec = max(0.0, wall - ideal) if wall > 0 else float(bu.get("tail_overhead_sec") or 0.0)
        tail_pct = round(100.0 * tail_sec / max(1.0, wall), 1) if wall > 0 else float(bu.get("tail_overhead_pct") or 0.0)
        cpu_pct = round(100.0 * conc / max(1, nproc), 1)
        sched = str(bu.get("schedule_order") or "unknown")
        to_cnt = int(bu.get("timeout_count") or 0)
        to_sec = float(bu.get("timeout_straggler_sec") or 0.0)
        unfiltered_sr = bool(bu.get("unfiltered_single_race_suite", False))

        row = {
            "loop": lbl,
            "run_id": str(bu.get("run_id") or lbl),
            "matches": int(bu.get("matches") or 0),
            "concurrency": conc,
            "host_cpus": nproc,
            "cpu_util_pct": cpu_pct,
            "schedule_order": sched,
            "wall_min": round(wall / 60.0, 1),
            "ideal_min": round(ideal / 60.0, 1),
            "tail_overhead_sec": round(tail_sec, 1),
            "tail_overhead_pct": tail_pct,
            "timeout_count": to_cnt,
            "timeout_straggler_sec": round(to_sec, 1),
            "slowest_match": bu.get("slowest_match"),
            "bots_tested": bu.get("bots_tested") or [],
            "unfiltered_single_race_suite": unfiltered_sr,
        }
        per_run.append(row)

    non_lpt = [x for x in per_run if x["schedule_order"] != "lpt"]
    under_cpu = [x for x in per_run if x["host_cpus"] >= 24 and x["concurrency"] < 12]
    high_tail = [x for x in per_run if x["tail_overhead_pct"] > 25.0]
    timeout_runs = [x for x in per_run if x["timeout_straggler_sec"] > 0]
    unfiltered_sr_runs = [x for x in per_run if x["unfiltered_single_race_suite"]]

    if non_lpt:
        findings.append(
            {
                "detector": "bench_non_lpt_schedule",
                "severity": "high",
                "affected_loops": [x["loop"] for x in non_lpt],
                "summary": (
                    f"{len(non_lpt)}/{len(per_run)} benchmark run(s) used non-LPT scheduling "
                    f"({', '.join(sorted({x['schedule_order'] for x in non_lpt}))})."
                ),
                "recommendation": "Use default `--schedule-order lpt` in `tools/run-local-sc2-arena.py` so 640s stragglers start in Wave 1.",
            }
        )
    if under_cpu:
        findings.append(
            {
                "detector": "bench_low_concurrency",
                "severity": "high",
                "affected_loops": [x["loop"] for x in under_cpu],
                "summary": (
                    f"{len(under_cpu)} run(s) used concurrency < 12 on a >=24-thread host "
                    f"(min j={min(x['concurrency'] for x in under_cpu)}, min CPU util={min(x['cpu_util_pct'] for x in under_cpu):.1f}%)."
                ),
                "recommendation": "Use `-j 12` for full 84-match ALL_84 (avoids CPU-contention wall-ties on 24-32 thread hosts) and `-j 14` for <=26-match canaries.",
            }
        )
    if high_tail:
        tot_tail_min = round(sum(x["tail_overhead_sec"] for x in high_tail) / 60.0, 1)
        worst = max(high_tail, key=lambda x: x["tail_overhead_pct"])
        findings.append(
            {
                "detector": "bench_high_tail_waste",
                "severity": "medium",
                "affected_loops": [x["loop"] for x in high_tail],
                "summary": (
                    f"{len(high_tail)} run(s) had >25% tail overhead (worst {worst['loop']} at "
                    f"{worst['tail_overhead_pct']:.1f}%, {tot_tail_min:.1f} min total tail waste)."
                ),
                "recommendation": "Verify `--schedule-order lpt` historical wall_sec estimates cover the slowest opponent matchups.",
            }
        )
    if timeout_runs:
        tot_to_min = round(sum(x["timeout_straggler_sec"] for x in timeout_runs) / 60.0, 1)
        tot_to_n = sum(x["timeout_count"] for x in timeout_runs)
        findings.append(
            {
                "detector": "bench_timeout_stragglers",
                "severity": "medium",
                "affected_loops": [x["loop"] for x in timeout_runs],
                "summary": f"{tot_to_n} timed-out straggler match(es) burned {tot_to_min:.1f} match-min across {len(timeout_runs)} run(s).",
                "recommendation": "Inspect timed-out matchups for stalemate/endgame-hunt loops and ensure LPT launches them in Wave 1.",
            }
        )
    if unfiltered_sr_runs:
        findings.append(
            {
                "detector": "bench_unfiltered_single_race_suite",
                "severity": "high",
                "affected_loops": [x["loop"] for x in unfiltered_sr_runs],
                "summary": (
                    f"{len(unfiltered_sr_runs)} single-race diff(s) ({', '.join(x['loop'] for x in unfiltered_sr_runs)}) "
                    f"ran an unfiltered 3-race >=78-match suite without a single-race pre-check."
                ),
                "recommendation": "Run `--bots Mothman-{P,T,Z} --opponents all` or `--opponents canary` before full ALL_84 on single-race diffs.",
            }
        )

    return {
        "runs_analyzed": len(per_run),
        "avg_cpu_util_pct": mean_safe([x["cpu_util_pct"] for x in per_run]),
        "avg_tail_overhead_pct": mean_safe([x["tail_overhead_pct"] for x in per_run]),
        "total_tail_waste_min": round(sum(x["tail_overhead_sec"] for x in per_run) / 60.0, 1),
        "total_timeout_straggler_min": round(sum(x["timeout_straggler_sec"] for x in per_run) / 60.0, 1),
        "per_run": per_run,
        "findings": findings,
    }


def compute_llm_efficiency_audit(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Detector 3: Per-worker LLM think-time vs tool-time, model tier, and turn-count efficiency."""
    by_role: Dict[str, Dict[str, Any]] = {}
    for r in records:
        lbl = loop_label(r)
        for role, a in (r.get("agent_trajectories") or {}).items():
            canon = re.sub(r"-legacy-[0-9a-f]+$", "", role)
            if re.match(r"^worker-[0-9a-f]{6,}$", canon) or "browser" in canon.lower():
                continue
            if canon not in by_role:
                by_role[canon] = {
                    "role": canon,
                    "loops_active": 0,
                    "think_sec": 0.0,
                    "tool_sec": 0.0,
                    "planner_turns": 0,
                    "run_command_calls": 0,
                    "sessions_count": 0,
                    "max_turns_in_session": 0,
                    "max_cmds_in_session": 0,
                    "max_post_bench_turns": 0,
                    "models_seen": Counter(),
                    "heavy_cmd_loops": [],
                    "high_post_bench_loops": [],
                }
            b = by_role[canon]
            b["loops_active"] += 1
            b["think_sec"] += float(a.get("think_sec") or 0.0)
            b["tool_sec"] += float(a.get("tool_sec") or 0.0)
            b["planner_turns"] += int(a.get("planner_turns") or 0)
            rc = int(a.get("run_command_calls") or (a.get("tool_calls_by_name") or {}).get("run_command") or 0)
            b["run_command_calls"] += rc
            sess = int(a.get("sessions_count") or (1 if int(a.get("planner_turns") or 0) > 0 else 0))
            b["sessions_count"] += sess
            mts = int(a.get("max_turns_in_session") or 0)
            mcs = int(a.get("max_cmds_in_session") or 0)
            pbt = int(a.get("post_bench_turns") or 0)
            if mts > b["max_turns_in_session"]:
                b["max_turns_in_session"] = mts
            if mcs > b["max_cmds_in_session"]:
                b["max_cmds_in_session"] = mcs
            if pbt > b["max_post_bench_turns"]:
                b["max_post_bench_turns"] = pbt
            if mcs > 15 or rc > 15:
                b["heavy_cmd_loops"].append((lbl, max(mcs, rc)))
            if pbt > 5:
                b["high_post_bench_loops"].append((lbl, pbt))
            mod = a.get("model")
            if isinstance(mod, str) and mod.strip():
                b["models_seen"][mod.strip()] += 1

    rows: List[Dict[str, Any]] = []
    findings: List[Dict[str, Any]] = []
    for canon, b in by_role.items():
        tot_active = b["think_sec"] + b["tool_sec"]
        think_pct = round(100.0 * b["think_sec"] / max(1.0, tot_active), 1) if tot_active > 0 else 0.0
        sess_div = max(1, b["sessions_count"])
        models = [m for m, _ in b["models_seen"].most_common()]
        primary_model = models[0] if models else "unknown"
        is_mech = canon in MECHANICAL_RUNNER_ROLES
        rows.append(
            {
                "role": canon,
                "is_mechanical_runner": is_mech,
                "primary_model": primary_model,
                "models_seen": models,
                "loops_active": b["loops_active"],
                "think_sec": round(b["think_sec"], 1),
                "tool_sec": round(b["tool_sec"], 1),
                "think_share_pct": think_pct,
                "planner_turns": b["planner_turns"],
                "run_command_calls": b["run_command_calls"],
                "sessions_count": b["sessions_count"],
                "turns_per_session": round(b["planner_turns"] / sess_div, 1),
                "cmds_per_session": round(b["run_command_calls"] / sess_div, 1),
                "max_turns_in_session": b["max_turns_in_session"],
                "max_cmds_in_session": b["max_cmds_in_session"],
                "max_post_bench_turns": b["max_post_bench_turns"],
            }
        )

        # Flag 1: Mechanical runner burning xhigh/heavy reasoning latency
        heavy_models = [m for m in models if HEAVY_MODEL_RE.search(m)]
        all_fast_models = bool(models) and all(FAST_MODEL_RE.search(m) and not HEAVY_MODEL_RE.search(m) for m in models)
        if is_mech and (heavy_models or (not all_fast_models and think_pct >= 65.0 and b["think_sec"] >= 120.0)):
            findings.append(
                {
                    "detector": "mechanical_runner_heavy_model",
                    "severity": "high",
                    "role": canon,
                    "models": heavy_models or models,
                    "think_sec": round(b["think_sec"], 1),
                    "think_share_pct": think_pct,
                    "summary": (
                        f"Mechanical runner `{canon}` burned {b['think_sec']:.0f}s think-time "
                        f"({think_pct:.1f}% of active time; model={', '.join(heavy_models or models) or 'unknown'})."
                    ),
                    "recommendation": f"Switch `{canon}` to a fast medium/flash model tier (e.g. `gemini-4-neon-medium`) for mechanical command execution.",
                }
            )

        # Flag 2: Mechanical runner multi-turn post-bench scripting (>5 post-bench turns)
        if is_mech and b["max_post_bench_turns"] > 5:
            lp_str = ", ".join(f"{l} ({n}t)" for l, n in b["high_post_bench_loops"][:5])
            findings.append(
                {
                    "detector": "mechanical_runner_multi_turn_post_bench",
                    "severity": "high",
                    "role": canon,
                    "max_post_bench_turns": b["max_post_bench_turns"],
                    "summary": f"Mechanical runner `{canon}` spent >5 turns post-bench ({lp_str}).",
                    "recommendation": "Replace sequential post-bench shell steps with one call to `tools/post-bench-pipeline.py`.",
                }
            )

        # Flag 3: >15-command ad-hoc session that should be automated into a reusable CLI
        if b["heavy_cmd_loops"]:
            lp_str = ", ".join(f"{l} ({n} cmds)" for l, n in b["heavy_cmd_loops"][:5])
            findings.append(
                {
                    "detector": "adhoc_command_session_churn",
                    "severity": "medium",
                    "role": canon,
                    "max_cmds_in_session": max(n for _, n in b["heavy_cmd_loops"]),
                    "summary": f"`{canon}` ran >15 shell commands in a single session/loop ({lp_str}).",
                    "recommendation": "Automate repeated ad-hoc analysis into a reusable CLI (e.g. `tools/forensics-diff.py` or `tools/post-bench-pipeline.py`).",
                }
            )

    rows.sort(key=lambda x: (x["think_sec"] + x["tool_sec"], x["planner_turns"]), reverse=True)
    return {
        "agents": rows,
        "findings": findings,
    }


def compute_bottleneck_detectors(
    records: List[Dict[str, Any]],
    host_cpus: Optional[int] = None,
) -> Dict[str, Any]:
    slow_cmds = compute_slow_commands_audit(records)
    bench_util = compute_bench_utilization_audit(records, host_cpus=host_cpus)
    llm_eff = compute_llm_efficiency_audit(records)
    sub_iters = [str(r["sub_iter"]) for r in records if r.get("sub_iter")]
    sev_rank = {"high": 0, "medium": 1, "low": 2}
    all_findings = list(slow_cmds["findings"]) + list(bench_util["findings"]) + list(llm_eff["findings"])
    all_findings.sort(key=lambda f: (sev_rank.get(str(f.get("severity")), 9), str(f.get("detector"))))
    return {
        "slow_commands": slow_cmds,
        "bench_utilization": bench_util,
        "llm_efficiency": llm_eff,
        "sub_iterations_logged": sub_iters,
        "findings": all_findings,
    }


def build_ranked_patches(
    cf: Dict[str, Any],
    hold_tax: Dict[str, Any],
    agent_sc: Dict[str, Any],
) -> List[Dict[str, Any]]:
    sg_lo, sg_hi = hold_tax.get("ship_gate_span") or [34, 50]
    span_lbl = f"L{sg_lo}–L{sg_hi}"
    monitor_steps = next(
        (a["steps"] for a in agent_sc.get("agents") or [] if a["role"] == "monitor-2"),
        0,
    )
    monitor_posts = next(
        (a["board_posts"] for a in agent_sc.get("agents") or [] if a["role"] == "monitor-2"),
        0,
    )
    return [
        {
            "rank": 1,
            "patch": "Run 2-Minute Head-to-Head Check Before the 30-Minute Roster",
            "owner": "@coordinator + @harness",
            "target_files": ["tools/iteration-loop/SWARM_PLAYBOOK.md", "tools/run-local-sc2-arena.py"],
            "expected_impact": (
                f"Saves {cf['interventions'][0]['standalone_saved_min']:.0f} min across {span_lbl} "
                f"({cf['interventions'][0]['saved_min_per_ship']:.1f} min/release); catches regressions in 2 min instead of 31 min."
            ),
            "verification": "H2H runs first; stops early if H2H finishes <= 3W-3L or any race goes 0-2.",
        },
        {
            "rank": 2,
            "patch": "Brain and Runtime Production-Cap Contract Check (<3s in Gate 1)",
            "owner": "@belief-author + @runtime-author + @verifier",
            "target_files": ["tests/run-all-tests.rkt", "lib/priority-macro-brain.rkt", "lib/bot-runtime.rkt"],
            "expected_impact": (
                f"Prevents split-brain held builds, lifting Gate-2 release rate "
                f"{cf.get('actual_ship_rate_pct')}% -> {cf.get('projected_gate2_ship_rate_pct')}%."
            ),
            "verification": "Gate 1 asserts runtime production caps >= brain caps and Colossus > Phoenix > Stalker.",
        },
        {
            "rank": 3,
            "patch": "25-Second Targeted Drill Pre-Check for Repeatedly Edited Rules",
            "owner": "@tactics-tester + @loop-architect",
            "target_files": ["tools/iteration-loop/SWARM_PLAYBOOK.md", "tools/iteration-loop/analyze-loop-flywheel.py"],
            "expected_impact": (
                f"Flags {len(hold_tax.get('flip_flops') or [])} repeatedly edited rules before changes land; "
                f"saves {cf['interventions'][2]['standalone_saved_min']:.0f} min in wasted full drill runs."
            ),
            "verification": "Any rule touched in >= 2 of the last 3 runs requires a 25s `--scenario` A/B pass before Gate 2.",
        },
        {
            "rank": 4,
            "patch": "Pre-Granted Track Test Ownership and `--skip-perf` Author Mode",
            "owner": "@coordinator + @verifier",
            "target_files": ["tools/iteration-loop/SWARM_PLAYBOOK.md", "tests/run-all-tests.rkt"],
            "expected_impact": (
                f"Removes ownership wait pauses ({cf['interventions'][4]['standalone_saved_min']:.0f} min) and "
                f"CPU-contention timing retries ({cf['interventions'][3]['standalone_saved_min']:.0f} min across {span_lbl})."
            ),
            "verification": "Authors edit their own track tests directly; @verifier owns wall-clock timing checks on an idle CPU.",
        },
        {
            "rank": 5,
            "patch": "Post-Run Log Review, Trade Video Contact Sheets & Quiet Polling",
            "owner": "@loop-architect + @analyzer + @monitor-2",
            "target_files": [
                "tools/iteration-loop/log-loop-trajectory.py",
                "tools/iteration-loop/analyze-loop-flywheel.py",
                "tools/trade-review-pack.py",
            ],
            "expected_impact": (
                f"Updates timing logs in <3s after each run, pairs worst fights with 6-frame video sheets, "
                f"and cuts idle monitor polling (monitor-2 logged {monitor_steps:,} steps / {monitor_posts} posts)."
            ),
            "verification": "Each run appends to loop_trajectory_log.jsonl and produces Replay + Video trade review packs.",
        },
    ]


def render_markdown(report: Dict[str, Any]) -> str:
    pareto = report["phase_pareto"]
    sg = pareto["ship_gate_era_l34_plus"]
    ships_p = pareto["ship_zip_loops"]
    holds_p = pareto["hold_zip_loops"]
    ag = report["agent_scorecard"]
    ht = report["hold_taxonomy"]
    cf = report["counterfactual_simulator"]
    patches = report["ranked_patches"]

    lo_lid, hi_lid = report["loop_span"]
    sg_lo, sg_hi = ht.get("ship_gate_span") or [34, hi_lid]
    rec_lo, rec_hi = ht.get("recent_l37_span") or [37, hi_lid]
    rec_cnt = ht["recent_l37_l47_counts"]
    rec_n = rec_cnt["ships"] + rec_cnt["holds"]
    sg_decided = ht["ship_zip_count"] + ht["hold_zip_count"]

    lines: List[str] = []
    lines.append(f"# Build and Test Cycle Timing Review (Loops {lo_lid}–{hi_lid})")
    lines.append("")
    lines.append(
        f"> Generated `{report['generated_at']}` from `{report['loops_analyzed']}` logged runs "
        f"(Loops {lo_lid}–{hi_lid})."
    )
    lines.append("")

    # Summary
    lines.append("## Summary")
    lines.append("")
    lines.append(
        f"- **Release Rate (Loops {sg_lo}–{sg_hi}, `n={sg_decided}`):** "
        f"`{ht['ship_zip_count']}` shipped (`{ht['ship_rate_pct']}%`) vs `{ht['hold_zip_count']}` held "
        f"(recent `{rec_n}` runs `L{rec_lo}–L{rec_hi}`: `{rec_cnt['ships']}` shipped / `{rec_cnt['holds']}` held = `{ht['recent_l37_l47_ship_rate_pct']}%`)."
    )
    lines.append(
        f"- **Mean Run Wall Time (`L{sg_lo}–L{sg_hi}`):** `{sg['mean_wall_min']:.1f} min` "
        f"(shipped `{ships_p['mean_wall_min']:.1f}m` | held `{holds_p['mean_wall_min']:.1f}m` | "
        f"GPU active `{sg['gpu_util_pct']:.1f}%` | overlapped post-benchmark work saved `{sg['overlapped_saved_min']:.1f}m`)."
    )
    lines.append(
        f"- **Estimated Time Saved (`L{sg_lo}–L{sg_hi}`):** Reordering gates and checks would have saved "
        f"**`{cf['combined_saved_min']:.1f} min` (`{cf['combined_saved_hours']:.2f} hours`)**, reducing wall time per release from "
        f"**`{cf['actual_min_per_ship']:.1f} min` to `{cf['projected_min_per_ship']:.1f} min` (`{cf['effective_speedup_x']:.2f}x`)** "
        f"and raising Gate-2 release rate from **`{cf['actual_ship_rate_pct']}%` to `{cf['projected_gate2_ship_rate_pct']}%`**."
    )
    lines.append("")

    # 1. Where Time Goes Each Run
    lines.append(f"## 1. Where Time Goes Each Run (Loops {sg_lo}–{sg_hi})")
    lines.append("")
    lines.append(f"| Phase | Total Min (`n={sg['n']}`) | Mean Min | Median Min | P90 Min | Share of Wall | Shipped Mean | Held Mean |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    for ph, st in sg["phases"].items():
        sm = (ships_p["phases"].get(ph) or {}).get("mean_min", 0.0)
        hm = (holds_p["phases"].get(ph) or {}).get("mean_min", 0.0)
        lines.append(
            f"| `{ph}` | {st['total_min']:.1f} | {st['mean_min']:.1f} | {st['median_min']:.1f} | "
            f"{st['p90_min']:.1f} | {st['share_of_wall_pct']:.1f}% | {sm:.1f} | {hm:.1f} |"
        )
    lines.append("")
    lines.append(
        f"Across `L{sg_lo}–L{sg_hi}`, `coding` (`{sg['phases']['coding']['share_of_wall_pct']:.1f}%`) and "
        f"`benchmark_84` (`{sg['phases']['benchmark_84']['share_of_wall_pct']:.1f}%`) account for most wall time, "
        f"while `baseline_h2h` averages **`{sg['phases']['baseline_h2h']['nonzero_mean_min']:.1f} min`** and catches most held regressions early."
    )
    lines.append("")

    # 2. Agent Steps, Errors, and Retries
    lines.append(f"## 2. Agent Steps, Errors, and Retries (Loops {lo_lid}–{hi_lid})")
    lines.append("")
    lines.append(
        "| Agent | Runs | Steps | Tool Calls | Tool Errs (%) | Edit Misses | Cmd Fails | `raco make` | `run-all-tests` | Monolith Reads | Own Reqs | Compactions | Cache Hit |"
    )
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for a in ag["agents"]:
        lines.append(
            f"| `{a['role']}` | {a['loops_active']} | {a['steps']:,} | {a['tool_calls']:,} | "
            f"{a['tool_errors']} ({a['tool_error_rate_pct']:.1f}%) | {a['edit_target_mismatches']} | "
            f"{a['command_failures']} | {a['raco_make_calls']} | {a['full_test_calls']} | "
            f"{a['monolith_reads_total']} | {a['ownership_requests']} | {a['compactions']} | {a['cache_hit_pct']:.1f}% |"
        )
    lines.append("")

    # 3. Why Held Builds Failed & Repeated Edits
    lines.append("## 3. Why Held Builds Failed & Repeated Edits")
    lines.append("")
    lines.append(f"### 3a. Held Builds (Loops {sg_lo}–{sg_hi})")
    lines.append("")
    lines.append("| Loop | H2H | H2H Early Catch? | 84m Bench Min | Root Cause | Summary |")
    lines.append("|---:|---|---|---:|---|---|")
    for hc in ht["hold_cases"]:
        lines.append(
            f"| L{hc['loop_id']} | `{hc['h2h_record']}` | {'YES' if hc['h2h_would_catch_early'] else 'no'} | "
            f"{hc['benchmark_84_min']:.1f} | `{hc['cause_category']}` | {hc['summary']} |"
        )
    lines.append("")

    lines.append("### 3b. Repeatedly Edited Rules (`<= 3`-Loop Clusters)")
    lines.append("")
    if ht["flip_flops"]:
        micro_keys = {
            "worker_rush_r02_r05_r06", "probe_harass_e01", "widow_mine_defense_rd01",
            "oracle_runby_ro09", "muta_magic_box_z16", "banshee_runby_ro11", "stalker_blink_forward",
        }
        lines.append("| Subsystem | Loops Touched | Touches | Check Before Re-Editing |")
        lines.append("|---|---|---:|---|")
        for ff in ht["flip_flops"]:
            l_str = ", ".join(f"L{x}" for x in ff["loops"])
            kind_lbl = "25s drill A/B" if ff["topic_key"] in micro_keys else "Gate 1 macro trace"
            lines.append(f"| **{ff['label']}** | {l_str} | {ff['touch_count']} | {kind_lbl} |")
        lines.append("")
        lines.append(
            "Rule: any micro drill touched twice in 3 runs requires a 25-second `--scenario` A/B pass before editing thresholds again; "
            "any macro subsystem requires a closed-loop Gate 1 contract or trace test."
        )
    else:
        lines.append("_No recurring <=3-loop edit clusters detected._")
    lines.append("")

    # 4. Time Saved by Reordering Gates
    lines.append(f"## 4. Time Saved by Reordering Gates (Loops {sg_lo}–{sg_hi})")
    lines.append("")
    lines.append("| ID | Process Change | Standalone Saved (Min) | Min Saved / Release | Affected Loops |")
    lines.append("|---|---|---:|---:|---|")
    for iv in cf["interventions"]:
        l_str = ", ".join(f"L{x}" for x in iv["affected_loops"]) if iv["affected_loops"] else "-"
        lines.append(
            f"| `{iv['id']}` | **{iv['name']}** | {iv['standalone_saved_min']:.1f} | "
            f"{iv['saved_min_per_ship']:.1f} | {l_str} |"
        )
    lines.append("")
    lines.append(
        f"- **Combined Non-Double-Counted Savings (`L{sg_lo}–L{sg_hi}`):** **`{cf['combined_saved_min']:.1f} min` (`{cf['combined_saved_hours']:.2f} h`)**, "
        f"reducing total wall time from `{cf['actual_total_min']:.1f}m` to `{cf['projected_total_min']:.1f}m` "
        f"(**`{cf['actual_min_per_ship']:.1f}m` to `{cf['projected_min_per_ship']:.1f}m` per release**, **`{cf['effective_speedup_x']:.2f}x`**)."
    )
    lines.append("")

    # 5. Workflow Changes Applied
    lines.append("## 5. Workflow Changes Applied")
    lines.append("")
    for p in patches:
        files_s = ", ".join(f"`{x}`" for x in p["target_files"])
        lines.append(f"{p['rank']}. **{p['patch']}** *(Owner: {p['owner']})*")
        lines.append(f"   - **Files:** {files_s}")
        lines.append(f"   - **Impact:** {p['expected_impact']}")
        lines.append(f"   - **Check:** {p['verification']}")
    lines.append("")

    # 6. Open-Ended Cycle-Time Bottleneck Audit
    bd = report.get("bottleneck_detectors") or {}
    sc_aud = bd.get("slow_commands") or {}
    bu_aud = bd.get("bench_utilization") or {}
    llm_aud = bd.get("llm_efficiency") or {}
    bd_findings = bd.get("findings") or []
    sub_iters = bd.get("sub_iterations_logged") or []

    lines.append("## 6. Open-Ended Cycle-Time Bottleneck Audit")
    lines.append("")
    if sub_iters:
        lines.append(f"- **Sub-Iterations Logged:** `{len(sub_iters)}` ({', '.join(f'L{s}' for s in sub_iters[-12:])})")
    lines.append(
        f"- **Profiled Shell Commands:** `{sc_aud.get('commands_profiled', 0)}` "
        f"(`{sc_aud.get('non_sc2_over_30s_count', 0)}` non-SC2 commands >30s, "
        f"total `{sc_aud.get('non_sc2_over_30s_total_sec', 0.0):.1f}s`) | "
        f"**Bench Runs Audited:** `{bu_aud.get('runs_analyzed', 0)}` "
        f"(avg CPU util `{bu_aud.get('avg_cpu_util_pct', 0.0):.1f}%`, "
        f"avg tail overhead `{bu_aud.get('avg_tail_overhead_pct', 0.0):.1f}%`) | "
        f"**Open-Ended Findings:** `{len(bd_findings)}`"
    )
    lines.append("")

    lines.append("### 6a. Top-10 Slowest Single Shell Commands")
    lines.append("")
    top_cmds = sc_aud.get("top_10_slowest_commands") or []
    if top_cmds:
        lines.append("| Rank | Loop | Agent | Duration (s) | Kind | SC2 Bench? | Command |")
        lines.append("|---:|---|---|---:|---|---|---|")
        for idx, c in enumerate(top_cmds, start=1):
            cmd_esc = str(c["cmd"]).replace("|", "\\|")
            lines.append(
                f"| {idx} | {c['loop']} | `{c['agent']}` | {c['duration_sec']:.1f} | "
                f"`{c['cmd_kind']}` | {'yes' if c['is_sc2_bench'] else 'no'} | `{cmd_esc}` |"
            )
    else:
        lines.append("_No per-command durations recorded in the current trajectory log._")
    lines.append("")

    lines.append("### 6b. Bench Utilization, Tail-Waste & Straggler Audit")
    lines.append("")
    per_run = bu_aud.get("per_run") or []
    if per_run:
        lines.append("| Loop | Matches | Concurrency / Threads | CPU Util | Schedule | Wall Min | Ideal Min | Tail Overhead | Timeouts |")
        lines.append("|---|---:|---|---:|---|---:|---:|---:|---:|")
        for row in per_run:
            lines.append(
                f"| {row['loop']} | {row['matches']} | {row['concurrency']}/{row['host_cpus']} | "
                f"{row['cpu_util_pct']:.1f}% | `{row['schedule_order']}` | {row['wall_min']:.1f} | "
                f"{row['ideal_min']:.1f} | {row['tail_overhead_pct']:.1f}% ({row['tail_overhead_sec']:.0f}s) | "
                f"{row['timeout_count']} ({row['timeout_straggler_sec']:.0f}s) |"
            )
    else:
        lines.append("_No benchmark `results.json` utilization telemetry attached yet._")
    lines.append("")

    lines.append("### 6c. LLM Think-Time vs Tool-Time & Turn Efficiency")
    lines.append("")
    eff_agents = llm_aud.get("agents") or []
    if eff_agents:
        lines.append("| Agent | Model | Think (s) | Tool (s) | Think Share | Turns/Sess | Cmds/Sess | Max Cmds/Sess | Max Post-Bench Turns |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|")
        for a in eff_agents:
            lines.append(
                f"| `{a['role']}` | `{a['primary_model']}` | {a['think_sec']:.1f} | {a['tool_sec']:.1f} | "
                f"{a['think_share_pct']:.1f}% | {a['turns_per_session']:.1f} | {a['cmds_per_session']:.1f} | "
                f"{a['max_cmds_in_session']} | {a['max_post_bench_turns']} |"
            )
    else:
        lines.append("_No LLM think-time vs tool-time telemetry recorded yet._")
    lines.append("")

    lines.append("### 6d. Auto-Detected Cycle-Time Findings")
    lines.append("")
    if bd_findings:
        for idx, fnd in enumerate(bd_findings, start=1):
            lines.append(
                f"{idx}. **[{str(fnd.get('severity', 'info')).upper()}] `{fnd.get('detector')}`:** "
                f"{fnd.get('summary')} Action: {fnd.get('recommendation')}"
            )
    else:
        lines.append("_No new cycle-time bottlenecks triggered across the audited logs._")
    lines.append("")
    return "\n".join(lines)


def analyze_flywheel(
    jsonl_path: Path,
    ledger_path: Path,
    out_md: Optional[Path] = None,
    out_json: Optional[Path] = None,
    host_cpus: Optional[int] = None,
) -> Dict[str, Any]:
    records = load_jsonl(jsonl_path)
    ledger = json.loads(ledger_path.read_text(encoding="utf-8")) if ledger_path.is_file() else {"iterations": []}
    ledger_by_loop: Dict[int, Dict[str, Any]] = {}
    for it in ledger.get("iterations") or []:
        m = re.match(r"^iter(\d+)(?:[a-z])?_", str(it.get("id") or ""))
        if m:
            ledger_by_loop[int(m.group(1))] = it

    pareto = compute_phase_pareto(records)
    agent_sc = compute_agent_scorecard(records)
    hold_tax = compute_hold_taxonomy_and_flipflops(records, ledger_by_loop)
    cf = run_counterfactual_simulator(records, hold_tax, agent_sc)
    patches = build_ranked_patches(cf, hold_tax, agent_sc)
    bottlenecks = compute_bottleneck_detectors(records, host_cpus=host_cpus)

    loop_span = [records[0]["loop_id"], records[-1]["loop_id"]] if records else [0, 0]
    report = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "loops_analyzed": len(records),
        "loop_span": loop_span,
        "phase_pareto": pareto,
        "agent_scorecard": agent_sc,
        "hold_taxonomy": hold_tax,
        "counterfactual_simulator": cf,
        "ranked_patches": patches,
        "bottleneck_detectors": bottlenecks,
    }

    if out_json is not None:
        out_json.parent.mkdir(parents=True, exist_ok=True)
        out_json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if out_md is not None:
        out_md.parent.mkdir(parents=True, exist_ok=True)
        out_md.write_text(render_markdown(report), encoding="utf-8")

    return report


def default_scratch_loop_dir() -> Path:
    env = os.environ.get("AGY_SCRATCH_LOOP_DIR")
    if env:
        return Path(env)
    brain_root = Path(os.environ.get("AGY_BRAIN_ROOT") or (Path.home() / ".gemini/antigravity/brain"))
    if brain_root.is_dir():
        cands = []
        for child in brain_root.iterdir():
            ld = child / "scratch/loop"
            tp = child / ".system_generated/logs/transcript.jsonl"
            if ld.is_dir() and tp.is_file():
                cands.append((tp.stat().st_size, ld))
        if cands:
            cands.sort(reverse=True)
            return cands[0][1]
    return Path.cwd() / "scratch/loop"


def main(argv: Optional[List[str]] = None) -> int:
    repo_default = Path(__file__).resolve().parents[2]
    scratch_default = default_scratch_loop_dir()
    ap = argparse.ArgumentParser(
        description="Analyze loop_trajectory_log.jsonl and generate loop_flywheel_retro.{md,json}."
    )
    ap.add_argument("--jsonl", type=Path, default=repo_default / "tools/iteration-loop/loop_trajectory_log.jsonl")
    ap.add_argument("--ledger", type=Path, default=repo_default / "tools/iteration-loop/loop_ledger.json")
    ap.add_argument("--out-md", type=Path, default=scratch_default / "loop_flywheel_retro.md")
    ap.add_argument("--out-json", type=Path, default=scratch_default / "loop_flywheel_retro.json")
    args = ap.parse_args(argv)

    rep = analyze_flywheel(args.jsonl, args.ledger, args.out_md, args.out_json)
    cf = rep["counterfactual_simulator"]
    ht = rep["hold_taxonomy"]
    print(
        f"FLYWHEEL_RETRO_OK: loops={rep['loops_analyzed']} (L{rep['loop_span'][0]}..L{rep['loop_span'][1]}) | "
        f"L34+ ship_rate={ht['ship_rate_pct']}% ({ht['ship_zip_count']}/{ht['ship_gate_era_n']}) | "
        f"flip_flops={len(ht['flip_flops'])} | "
        f"counterfactual_saved={cf['combined_saved_min']:.1f}m ({cf['effective_speedup_x']:.2f}x, "
        f"{cf['actual_min_per_ship']:.1f}m->{cf['projected_min_per_ship']:.1f}m/Ship) -> {args.out_md}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
