#!/usr/bin/env python3
"""
tools/iteration-loop/compare-vs-pro.py

Fast, durable quantitative comparator fusing Mothman gauntlet score JSONs
(produced by `tools/score-replay-batch.rkt`) + optional tactical scorecard JSON
(produced by `tools/tactics-unit-tester.rkt`) against canonical Pro Replay
Corpus baselines (`tools/iteration-loop/pro_baselines.json`).

Usage:
  python3 tools/iteration-loop/compare-vs-pro.py \\
      --current scratch/iter1_wave1_score.json \\
      --baseline scratch/baseline_32ab101a_score.json \\
      [--tactics scratch/loop/tactics_wave1.json] \\
      [--out-json scratch/loop/pro_comparison_iter1_wave1.json] \\
      [--exclude-opp-crash]
"""

import argparse
import json
import math
import os
import statistics
import sys
from collections import defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PRO_BASELINES = os.path.join(SCRIPT_DIR, "pro_baselines.json")

RACES = ("Protoss", "Terran", "Zerg")
MATCHUPS = ("PvP", "PvT", "PvZ", "TvP", "TvT", "TvZ", "ZvP", "ZvT", "ZvZ")


def safe_num(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)) and math.isfinite(v):
        return float(v)
    return None


def mean_opt(vals):
    xs = [x for x in (safe_num(v) for v in vals) if x is not None]
    return round(sum(xs) / len(xs), 1) if xs else None


def med_opt(vals):
    xs = [x for x in (safe_num(v) for v in vals) if x is not None]
    return round(statistics.median(xs), 1) if xs else None


def med_opt2(vals):
    xs = [x for x in (safe_num(v) for v in vals) if x is not None]
    return round(statistics.median(xs), 2) if xs else None


def normalize_match(m):
    """Support both legacy v1 and upgraded v2 `score-replay-batch.rkt` JSON schemas."""
    mt = m.get("macro_timings") or {}
    our_race = m.get("our_race") or "Unknown"
    opp_race = m.get("opp_race") or "Unknown"
    matchup = m.get("matchup") or (
        f"{our_race[0]}v{opp_race[0]}"
        if our_race in RACES and opp_race in RACES
        else "Unknown"
    )
    dur = safe_num(m.get("duration_sec")) or 0.0
    opp_crash = bool(
        m.get("opp_early_crash")
        or (dur < 20.0 and m.get("result") == "win" and (m.get("killed_val") or 0) == 0)
    )
    return {
        "match_id": str(m.get("id") if m.get("id") is not None else m.get("match_id", "")),
        "file": m.get("file", ""),
        "our_bot": m.get("our_bot", ""),
        "opp_bot": m.get("opp_bot", ""),
        "our_race": our_race,
        "opp_race": opp_race,
        "matchup": matchup,
        "result": m.get("result", "unknown"),
        "opp_early_crash": opp_crash,
        "duration_sec": dur,
        "killed_val": safe_num(m.get("killed_val")) or 0.0,
        "lost_val": safe_num(m.get("lost_val")) or 0.0,
        "trade_ratio": safe_num(m.get("trade_ratio")),
        "our_bases": safe_num(m.get("our_bases")),
        "opp_bases": safe_num(m.get("opp_bases")),
        "our_w2": safe_num(m.get("our_w2") if m.get("our_w2") is not None else mt.get("w2m")),
        "our_w4": safe_num(m.get("our_w4") if m.get("our_w4") is not None else mt.get("w4m")),
        "our_w6": safe_num(m.get("our_w6") if m.get("our_w6") is not None else mt.get("w6m")),
        "our_w8": safe_num(m.get("our_w8") if m.get("our_w8") is not None else mt.get("w8m")),
        "opp_w4": safe_num(m.get("opp_w4")),
        "opp_w6": safe_num(m.get("opp_w6")),
        "our_peak_workers": safe_num(m.get("our_peak_workers")),
        "our_peak_army": safe_num(m.get("our_peak_army")),
        "opp_peak_army": safe_num(m.get("opp_peak_army")),
        "our_avg_min": safe_num(m.get("our_avg_min")),
        "our_avg_gas": safe_num(m.get("our_avg_gas")),
        "supply_block_pct": safe_num(m.get("supply_block_pct")),
        "upgrades": safe_num(m.get("upgrades")),
        "nat_sec": safe_num(mt.get("nat_sec")),
        "third_sec": safe_num(mt.get("third_sec")),
        "gas1_sec": safe_num(mt.get("gas1_sec")),
        "gas2_sec": safe_num(mt.get("gas2_sec")),
        "prod1_sec": safe_num(mt.get("prod1_sec")),
        "tech1_sec": safe_num(mt.get("tech1_sec")),
        "lair_sec": safe_num(mt.get("lair_sec")),
        "orbital1_sec": safe_num(mt.get("orbital1_sec")),
        "army_to_worker_6m": safe_num(
            m.get("army_to_worker_6m")
            if m.get("army_to_worker_6m") is not None
            else mt.get("army_to_worker_6m")
        ),
        "army_to_worker_8m": safe_num(
            m.get("army_to_worker_8m")
            if m.get("army_to_worker_8m") is not None
            else mt.get("army_to_worker_8m")
        ),
        "step_p50": safe_num(m.get("step_p50") if m.get("step_p50") is not None else m.get("step_ms_p50")),
        "step_p95": safe_num(m.get("step_p95") if m.get("step_p95") is not None else m.get("step_ms_p95")),
        "action_rejects": int(m.get("action_rejects") or 0),
        "crashes": m.get("crashes") or [],
        "signatures": m.get("signatures") or [],
        "anomalies": m.get("anomalies") or {},
    }


def load_score_json(path, exclude_opp_crash=False):
    with open(path) as f:
        data = json.load(f)
    matches = [normalize_match(m) for m in data.get("matches", [])]
    if exclude_opp_crash:
        matches = [m for m in matches if not m["opp_early_crash"]]
    return data, matches


def summarize_slice(rows):
    n = len(rows)
    if n == 0:
        return {"n": 0}
    wins = sum(1 for r in rows if r["result"] == "win")
    losses = sum(1 for r in rows if r["result"] == "loss")
    ties = sum(1 for r in rows if r["result"] == "tie")
    tot_k = sum(r["killed_val"] for r in rows)
    tot_l = sum(r["lost_val"] for r in rows)
    agg_trade = round(tot_k / tot_l, 2) if tot_l > 0 else (round(tot_k / 100.0, 2) if tot_k > 0 else 1.0)
    med_trade = med_opt2([r["trade_ratio"] for r in rows])

    # Alive-at-timestamp worker filter (> 0) to separate macro trajectory from already-dead games
    w4_all = [r["our_w4"] for r in rows if r["our_w4"] is not None]
    w4_alive = [r["our_w4"] for r in rows if r["our_w4"] is not None and r["our_w4"] >= 10]
    w6_all = [r["our_w6"] for r in rows if r["our_w6"] is not None]
    w6_alive = [r["our_w6"] for r in rows if r["our_w6"] is not None and r["our_w6"] >= 10]
    w8_alive = [r["our_w8"] for r in rows if r["our_w8"] is not None and r["our_w8"] >= 10]

    anom_counts = defaultdict(int)
    for r in rows:
        an = r["anomalies"]
        if isinstance(an, dict):
            if an.get("zero_fire_retreat"):
                anom_counts["zero_fire_retreat"] += 1
            if an.get("escrow_lockouts"):
                anom_counts["escrow_lockouts"] += 1
            if an.get("self_cancel_loops"):
                anom_counts["self_cancel_loops"] += 1
            if an.get("endgame_stall"):
                anom_counts["endgame_stall"] += 1
            if an.get("air_aa_starvation"):
                anom_counts["air_aa_starvation"] += 1

    return {
        "n": n,
        "wins": wins,
        "losses": losses,
        "ties": ties,
        "wr_pct": round(100.0 * wins / n, 1),
        "killed_val": round(tot_k),
        "lost_val": round(tot_l),
        "trade_agg": agg_trade,
        "trade_med": med_trade,
        "bases_avg": mean_opt([r["our_bases"] for r in rows]),
        "w2_med": med_opt([r["our_w2"] for r in rows]),
        "w4_avg": mean_opt(w4_all),
        "w4_alive_med": med_opt(w4_alive),
        "w6_avg": mean_opt(w6_all),
        "w6_alive_med": med_opt(w6_alive),
        "w8_alive_med": med_opt(w8_alive),
        "pk_workers_avg": mean_opt([r["our_peak_workers"] for r in rows]),
        "pk_army_avg": mean_opt([r["our_peak_army"] for r in rows]),
        "opp_pk_army_avg": mean_opt([r["opp_peak_army"] for r in rows]),
        "avg_min_bank": mean_opt([r["our_avg_min"] for r in rows]),
        "avg_gas_bank": mean_opt([r["our_avg_gas"] for r in rows]),
        "sup_blk_avg": mean_opt([r["supply_block_pct"] for r in rows]),
        "upgrades_avg": mean_opt([r["upgrades"] for r in rows]),
        "nat_sec_med": med_opt([r["nat_sec"] for r in rows]),
        "third_sec_med": med_opt([r["third_sec"] for r in rows]),
        "gas1_sec_med": med_opt([r["gas1_sec"] for r in rows]),
        "gas2_sec_med": med_opt([r["gas2_sec"] for r in rows]),
        "prod1_sec_med": med_opt([r["prod1_sec"] for r in rows]),
        "tech1_sec_med": med_opt([r["tech1_sec"] for r in rows]),
        "lair_sec_med": med_opt([r["lair_sec"] for r in rows]),
        "army_to_worker_6m_med": med_opt2([r["army_to_worker_6m"] for r in rows]),
        "army_to_worker_8m_med": med_opt2([r["army_to_worker_8m"] for r in rows]),
        "step_p50_med": med_opt([r["step_p50"] for r in rows]),
        "step_p95_med": med_opt([r["step_p95"] for r in rows]),
        "action_rejects": sum(r["action_rejects"] for r in rows),
        "crashes": sum(len(r["crashes"]) for r in rows),
        "anomalies": dict(anom_counts),
    }


def diff_val(a, b, prec=1):
    if a is None or b is None:
        return None
    return round(a - b, prec)


def fmt(v, suffix="", prec=1):
    if v is None:
        return "-"
    if isinstance(v, int):
        return f"{v}{suffix}"
    return f"{v:.{prec}f}{suffix}"


def fmt_delta(v, suffix="", prec=1):
    if v is None:
        return "-"
    sign = "+" if v > 0 else ""
    return f"{sign}{v:.{prec}f}{suffix}"


def compare_vs_pro(summary, pro_ref):
    """Compute signed gaps (Mothman - Pro) and normalized divergence flags."""
    if not summary or summary.get("n", 0) == 0 or not pro_ref:
        return {}
    gaps = {
        "w2_gap": diff_val(summary.get("w2_med"), pro_ref.get("w2m")),
        "w4_gap": diff_val(summary.get("w4_alive_med"), pro_ref.get("w4m")),
        "w6_gap": diff_val(summary.get("w6_alive_med"), pro_ref.get("w6m")),
        "w8_gap": diff_val(summary.get("w8_alive_med"), pro_ref.get("w8m")),
        "nat_sec_gap": diff_val(summary.get("nat_sec_med"), pro_ref.get("nat_sec")),
        "third_sec_gap": diff_val(summary.get("third_sec_med"), pro_ref.get("third_sec")),
        "gas1_sec_gap": diff_val(summary.get("gas1_sec_med"), pro_ref.get("gas1_sec")),
        "gas2_sec_gap": diff_val(summary.get("gas2_sec_med"), pro_ref.get("gas2_sec")),
        "prod1_sec_gap": diff_val(summary.get("prod1_sec_med"), pro_ref.get("prod1_sec")),
        "tech1_sec_gap": diff_val(
            summary.get("lair_sec_med") if pro_ref.get("tech1_sym") == "lair" and summary.get("lair_sec_med") is not None else summary.get("tech1_sec_med"),
            pro_ref.get("tech1_sec"),
        ),
        "a2w_6m_gap": diff_val(summary.get("army_to_worker_6m_med"), pro_ref.get("army_val_per_worker_6m"), 1),
        "trade_gap_vs_1x": diff_val(summary.get("trade_agg"), 1.0, 2),
        "sup_blk_gap_vs_5pct": diff_val(summary.get("sup_blk_avg"), 5.0),
    }
    flags = []
    if gaps["w4_gap"] is not None and gaps["w4_gap"] <= -5.0:
        flags.append(f"WORKER_DEFICIT_4M({gaps['w4_gap']:+.1f})")
    if gaps["w6_gap"] is not None and gaps["w6_gap"] <= -8.0:
        flags.append(f"WORKER_DEFICIT_6M({gaps['w6_gap']:+.1f})")
    if gaps["nat_sec_gap"] is not None and abs(gaps["nat_sec_gap"]) >= 25.0:
        tag = "LATE_NAT" if gaps["nat_sec_gap"] > 0 else "EARLY_NAT"
        flags.append(f"{tag}({gaps['nat_sec_gap']:+.0f}s)")
    if gaps["tech1_sec_gap"] is not None and gaps["tech1_sec_gap"] >= 35.0:
        flags.append(f"LATE_TECH1({gaps['tech1_sec_gap']:+.0f}s)")
    if summary.get("trade_agg") is not None and summary["trade_agg"] < 0.70:
        flags.append(f"LOW_TRADE({summary['trade_agg']:.2f}x)")
    if summary.get("sup_blk_avg") is not None and summary["sup_blk_avg"] >= 8.0:
        flags.append(f"HIGH_SUP_BLK({summary['sup_blk_avg']:.1f}%)")
    gaps["divergence_flags"] = flags
    return gaps


def evaluate_promotion_gates(overall, by_race, tactics_data=None):
    """Explicit closed-loop promotion criteria before shipping to AI Arena."""
    gates = {
        "zero_crashes_and_rejects": (overall.get("crashes", 0) == 0 and overall.get("action_rejects", 0) == 0),
        "overall_wr_ge_50pct": (overall.get("wr_pct", 0.0) >= 50.0),
        "overall_trade_agg_ge_1_0x": (overall.get("trade_agg", 0.0) >= 1.0),
        "overall_trade_med_ge_0_85x": ((overall.get("trade_med") or 0.0) >= 0.85),
        "ties_le_2": (overall.get("ties", 99) <= 2),
        "sup_blk_le_6pct": ((overall.get("sup_blk_avg") or 99.0) <= 6.0),
        "every_race_wr_ge_33pct": all(
            (by_race.get(r, {}).get("wr_pct", 0.0) >= 33.0) for r in RACES if by_race.get(r, {}).get("n", 0) > 0
        ),
        "every_race_w4_within_6_of_pro": True,  # filled below
    }
    if tactics_data:
        passed = tactics_data.get("passed")
        total = tactics_data.get("total")
        if passed is not None and total:
            gates["tactics_suite_100pct"] = (passed == total)
    return gates


def main():
    ap = argparse.ArgumentParser(description="Compare Mothman gauntlet scores against Pro Replay Corpus baselines.")
    ap.add_argument("--current", required=True, help="Current wave score JSON from score-replay-batch.rkt")
    ap.add_argument("--baseline", default=None, help="Optional baseline/previous wave score JSON for delta")
    ap.add_argument("--pro-baselines", default=DEFAULT_PRO_BASELINES, help="Path to pro_baselines.json")
    ap.add_argument("--tactics", default=None, help="Optional tactics scorecard JSON")
    ap.add_argument("--out-json", default=None, help="Optional output JSON path")
    ap.add_argument("--exclude-opp-crash", action="store_true", help="Exclude early opponent crash matches (<20s, 0 kills)")
    args = ap.parse_args()

    with open(args.pro_baselines) as f:
        pro = json.load(f)

    cur_raw, cur_rows = load_score_json(args.current, args.exclude_opp_crash)
    base_raw, base_rows = (None, [])
    if args.baseline:
        base_raw, base_rows = load_score_json(args.baseline, args.exclude_opp_crash)

    tactics_data = None
    if args.tactics and os.path.exists(args.tactics):
        with open(args.tactics) as f:
            tactics_data = json.load(f)

    cur_all = summarize_slice(cur_rows)
    base_all = summarize_slice(base_rows) if base_rows else None

    by_race = {}
    for r in RACES:
        cr = summarize_slice([m for m in cur_rows if m["our_race"] == r])
        br = summarize_slice([m for m in base_rows if m["our_race"] == r]) if base_rows else None
        pr = pro["by_race"].get(r, {})
        gaps = compare_vs_pro(cr, pr)
        by_race[r] = {"current": cr, "baseline": br, "pro": pr, "gaps_vs_pro": gaps}

    by_matchup = {}
    for mu in MATCHUPS:
        cm = summarize_slice([m for m in cur_rows if m["matchup"] == mu])
        if cm["n"] == 0:
            continue
        bm = summarize_slice([m for m in base_rows if m["matchup"] == mu]) if base_rows else None
        pm = pro["by_matchup"].get(mu, {})
        gaps = compare_vs_pro(cm, pm)
        by_matchup[mu] = {"current": cm, "baseline": bm, "pro": pm, "gaps_vs_pro": gaps}

    gates = evaluate_promotion_gates(cur_all, {r: by_race[r]["current"] for r in RACES}, tactics_data)
    gates["every_race_w4_within_6_of_pro"] = all(
        (by_race[r]["gaps_vs_pro"].get("w4_gap") is None or by_race[r]["gaps_vs_pro"]["w4_gap"] >= -6.0)
        for r in RACES
    )
    gates["ready_to_promote"] = all(gates.values())

    report = {
        "current_path": os.path.abspath(args.current),
        "baseline_path": os.path.abspath(args.baseline) if args.baseline else None,
        "exclude_opp_crash": args.exclude_opp_crash,
        "overall": {"current": cur_all, "baseline": base_all},
        "by_race": by_race,
        "by_matchup": by_matchup,
        "tactics": tactics_data,
        "promotion_gates": gates,
    }

    if args.out_json:
        os.makedirs(os.path.dirname(os.path.abspath(args.out_json)), exist_ok=True)
        with open(args.out_json, "w") as f:
            json.dump(report, f, indent=2)

    # Print compact Markdown summary
    print(f"### Pro-Corpus Comparison (`n={cur_all['n']}`, excl_opp_crash={args.exclude_opp_crash})")
    print("| Race | W-L-T (WR%) | Trade Agg/Med | W@4m (Alive Med / Pro) | W@6m (Alive Med / Pro) | Nat@ (Bot / Pro) | Gas1@ (Bot / Pro) | Tech1@ (Bot / Pro) | A/W@6m (Bot / Pro) | SupBlk% | Flags |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|")
    for r in RACES:
        c = by_race[r]["current"]
        p = by_race[r]["pro"]
        g = by_race[r]["gaps_vs_pro"]
        if c["n"] == 0:
            continue
        t1_bot = c.get("lair_sec_med") if p.get("tech1_sym") == "lair" and c.get("lair_sec_med") is not None else c.get("tech1_sec_med")
        print(
            f"| **{r}** (`n={c['n']}`) | {c['wins']}-{c['losses']}-{c['ties']} ({c['wr_pct']:.1f}%) "
            f"| {fmt(c['trade_agg'],'x',2)} / {fmt(c['trade_med'],'x',2)} "
            f"| {fmt(c['w4_alive_med'])} / {fmt(p.get('w4m'))} ({fmt_delta(g.get('w4_gap'))}) "
            f"| {fmt(c['w6_alive_med'])} / {fmt(p.get('w6m'))} ({fmt_delta(g.get('w6_gap'))}) "
            f"| {fmt(c['nat_sec_med'],'s',0)} / {fmt(p.get('nat_sec'),'s',0)} "
            f"| {fmt(c['gas1_sec_med'],'s',0)} / {fmt(p.get('gas1_sec'),'s',0)} "
            f"| {fmt(t1_bot,'s',0)} / {fmt(p.get('tech1_sec'),'s',0)} "
            f"| {fmt(c['army_to_worker_6m_med'],'',1)} / {fmt(p.get('army_val_per_worker_6m'),'',1)} "
            f"| {fmt(c['sup_blk_avg'],'%')} "
            f"| {', '.join(g.get('divergence_flags', [])) or 'OK'} |"
        )

    print("\n### Matchup Breakdown vs Pro Medians")
    print("| Matchup | n | W-L-T | Trade Agg | W@4m (Bot/Pro) | W@6m (Bot/Pro) | Nat@ (Bot/Pro) | Tech1@ (Bot/Pro) | PkArmy | SupBlk% |")
    print("|---|---:|---|---:|---:|---:|---:|---:|---:|---:|")
    for mu, d in by_matchup.items():
        c, p = d["current"], d["pro"]
        t1_bot = c.get("lair_sec_med") if p.get("tech1_sym") == "lair" and c.get("lair_sec_med") is not None else c.get("tech1_sec_med")
        print(
            f"| **{mu}** | {c['n']} | {c['wins']}-{c['losses']}-{c['ties']} | {fmt(c['trade_agg'],'x',2)} "
            f"| {fmt(c['w4_alive_med'])}/{fmt(p.get('w4m'))} "
            f"| {fmt(c['w6_alive_med'])}/{fmt(p.get('w6m'))} "
            f"| {fmt(c['nat_sec_med'],'s',0)}/{fmt(p.get('nat_sec'),'s',0)} "
            f"| {fmt(t1_bot,'s',0)}/{fmt(p.get('tech1_sec'),'s',0)} "
            f"| {fmt(c['pk_army_avg'],'',0)} | {fmt(c['sup_blk_avg'],'%')} |"
        )

    passed_gates = sum(1 for k, v in gates.items() if k != "ready_to_promote" and v)
    total_gates = sum(1 for k in gates if k != "ready_to_promote")
    print(f"\n### Promotion Gates: {passed_gates}/{total_gates} PASS (ready_to_promote={gates['ready_to_promote']})")
    for k, v in gates.items():
        if k != "ready_to_promote":
            print(f"- `[{'PASS' if v else 'FAIL'}]` `{k}`")


if __name__ == "__main__":
    main()
