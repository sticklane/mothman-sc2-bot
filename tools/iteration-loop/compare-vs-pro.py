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
      [--replay-db ~/sc2-local-arena/arena_replays.sqlite] \\
      [--run-id RUN_ID] [--baseline-run-id BASE_RUN_ID] \\
      [--out-json scratch/loop/pro_comparison_iter1_wave1.json] \\
      [--exclude-opp-crash]
"""

import argparse
import json
import math
import os
import sqlite3
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PRO_BASELINES = os.path.join(SCRIPT_DIR, "pro_baselines.json")
DEFAULT_REPLAY_DB = str(Path.home() / "sc2-local-arena" / "arena_replays.sqlite")

RACES = ("Protoss", "Terran", "Zerg")
MATCHUPS = ("PvP", "PvT", "PvZ", "TvP", "TvT", "TvZ", "ZvP", "ZvT", "ZvZ")
CORE_12_OPPONENTS = frozenset({
    "12PoolBot", "Chance", "Creepy_strategies", "RustyNikolaj", "SmoothBrain",
    "Thssprtssbt", "mini-puck", "monsterbot", "oberon", "puck",
    "sludgement2-revived", "titania",
})
CORE_14_PROMOTED = frozenset({"who", "onlyfans"})
CORE_14_OPPONENTS = CORE_12_OPPONENTS | CORE_14_PROMOTED


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
    kv = safe_num(m.get("killed_val")) or 0.0
    lv = safe_num(m.get("lost_val")) or 0.0
    opp_pk = safe_num(m.get("opp_peak_army")) or 0.0
    opp_crash = bool(
        m.get("opp_early_crash")
        or (dur < 20.0 and m.get("result") == "win" and kv == 0)
        or (dur < 180.0 and m.get("result") == "win" and kv == 0 and lv == 0 and opp_pk == 0)
    )
    ut = m.get("upgrade_timings") or {}
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
        "killed_val": kv,
        "lost_val": lv,
        "trade_ratio": safe_num(m.get("trade_ratio")),
        "our_bases": safe_num(m.get("our_bases")),
        "opp_bases": safe_num(m.get("opp_bases")),
        "our_w2": safe_num(m.get("our_w2") if m.get("our_w2") is not None else mt.get("w2m")),
        "our_w4": safe_num(m.get("our_w4") if m.get("our_w4") is not None else mt.get("w4m")),
        "our_w6": safe_num(m.get("our_w6") if m.get("our_w6") is not None else mt.get("w6m")),
        "our_w8": safe_num(m.get("our_w8") if m.get("our_w8") is not None else mt.get("w8m")),
        "our_w10": safe_num(m.get("our_w10") if m.get("our_w10") is not None else mt.get("w10m")),
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
        "tech2_sec": safe_num(mt.get("tech2_sec")),
        "lair_sec": safe_num(mt.get("lair_sec")),
        "orbital1_sec": safe_num(mt.get("orbital1_sec")),
        "bases_4m": safe_num(mt.get("bases_4m")),
        "bases_6m": safe_num(mt.get("bases_6m")),
        "bases_8m": safe_num(mt.get("bases_8m")),
        "bases_10m": safe_num(mt.get("bases_10m")),
        "prod_cnt_4m": safe_num(mt.get("prod_cnt_4m")),
        "prod_cnt_6m": safe_num(mt.get("prod_cnt_6m")),
        "prod_cnt_8m": safe_num(mt.get("prod_cnt_8m")),
        "prod_cnt_10m": safe_num(mt.get("prod_cnt_10m")),
        "primary_prod_4m": safe_num(mt.get("primary_prod_4m")),
        "primary_prod_6m": safe_num(mt.get("primary_prod_6m")),
        "primary_prod_8m": safe_num(mt.get("primary_prod_8m")),
        "primary_prod_10m": safe_num(mt.get("primary_prod_10m")),
        "queens_4m": safe_num(mt.get("queens_4m")),
        "queens_6m": safe_num(mt.get("queens_6m")),
        "queens_8m": safe_num(mt.get("queens_8m")),
        "army_val_2m": safe_num(mt.get("army_val_2m")),
        "army_val_4m": safe_num(mt.get("army_val_4m")),
        "army_val_6m": safe_num(mt.get("army_val_6m")),
        "army_val_8m": safe_num(mt.get("army_val_8m")),
        "army_val_10m": safe_num(mt.get("army_val_10m")),
        "army_sup_4m": safe_num(mt.get("army_sup_4m")),
        "army_sup_6m": safe_num(mt.get("army_sup_6m")),
        "army_sup_8m": safe_num(mt.get("army_sup_8m")),
        "first_scout_sec": safe_num(m.get("first_scout_sec") if m.get("first_scout_sec") is not None else mt.get("first_scout_sec")),
        "enemy_first_seen_sec": safe_num(mt.get("enemy_first_seen_sec")),
        "first_scout_unit": m.get("first_scout_unit") or m.get("first_scout_unit_type") or None,
        "opening_bo_sequence": m.get("opening_bo_sequence") or None,
        "warpgate_sec": safe_num(ut.get("warpgate_sec") if ut.get("warpgate_sec") is not None else mt.get("warpgate_sec")),
        "blink_sec": safe_num(ut.get("blink_sec") if ut.get("blink_sec") is not None else mt.get("blink_sec")),
        "charge_sec": safe_num(ut.get("charge_sec") if ut.get("charge_sec") is not None else mt.get("charge_sec")),
        "stim_sec": safe_num(ut.get("stim_sec") if ut.get("stim_sec") is not None else mt.get("stim_sec")),
        "combat_shield_sec": safe_num(ut.get("combat_shield_sec") if ut.get("combat_shield_sec") is not None else mt.get("combat_shield_sec")),
        "ling_speed_sec": safe_num(ut.get("ling_speed_sec") if ut.get("ling_speed_sec") is not None else mt.get("ling_speed_sec")),
        "bane_speed_sec": safe_num(ut.get("bane_speed_sec") if ut.get("bane_speed_sec") is not None else mt.get("bane_speed_sec")),
        "roach_speed_sec": safe_num(ut.get("roach_speed_sec") if ut.get("roach_speed_sec") is not None else mt.get("roach_speed_sec")),
        "plus1_atk_sec": safe_num(ut.get("plus1_atk_sec") if ut.get("plus1_atk_sec") is not None else mt.get("plus1_atk_sec")),
        "plus1_arm_sec": safe_num(ut.get("plus1_arm_sec") if ut.get("plus1_arm_sec") is not None else mt.get("plus1_arm_sec")),
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
        "step_max": safe_num(m.get("step_max") if m.get("step_max") is not None else m.get("step_ms_max")),
        "endgame_home_stall_sec": safe_num(m.get("endgame_home_stall_sec")),
        "own_base_retreat_frames": safe_num(m.get("own_base_retreat_frames")),
        "non_combat_robo_waste_val": safe_num(m.get("non_combat_robo_waste_val")),
        "zerg_non_ling_army_pct": safe_num(m.get("zerg_non_ling_army_pct")),
        "siege_range_zero_dps_loss": bool(m.get("siege_range_zero_dps_loss") or (m.get("anomalies") or {}).get("siege_range_zero_dps_loss")),
        "cloaked_unit_damage_loss": bool(m.get("cloaked_unit_damage_loss") or (m.get("anomalies") or {}).get("cloaked_unit_damage_loss")),
        "army_val_4m_ratio_vs_pro": safe_num(
            m.get("army_val_4m_ratio_vs_pro")
            if m.get("army_val_4m_ratio_vs_pro") is not None
            else mt.get("army_val_4m_ratio_vs_pro")
        ),
        "army_val_8m_ratio_vs_pro": safe_num(
            m.get("army_val_8m_ratio_vs_pro")
            if m.get("army_val_8m_ratio_vs_pro") is not None
            else mt.get("army_val_8m_ratio_vs_pro")
        ),
        "gas_rich_min_starved_ticks": safe_num(m.get("gas_rich_min_starved_ticks")),
        "gas_rich_min_starved": bool(m.get("gas_rich_min_starved") or (m.get("anomalies") or {}).get("gas_rich_min_starved")),
        "early_rush_idle_bank_3m": bool(m.get("early_rush_idle_bank_3m") or (m.get("anomalies") or {}).get("early_rush_idle_bank_3m")),
        "own_territory_retreat_frames": safe_num(m.get("own_territory_retreat_frames")),
        "prod_placement_stall_ticks": safe_num(m.get("prod_placement_stall_ticks")),
        "prod_placement_stall": bool(m.get("prod_placement_stall") or (m.get("anomalies") or {}).get("prod_placement_stall")),
        "pvp_nat_delay_flag": bool(m.get("pvp_nat_delay_flag") or (m.get("anomalies") or {}).get("pvp_nat_delay")),
        "map_symmetry_kind": m.get("map_symmetry_kind"),
        "t3_first_sec": safe_num(m.get("t3_first_sec") if m.get("t3_first_sec") is not None else mt.get("t3_first_sec")),
        "t3_bases_at_start": safe_num(m.get("t3_bases_at_start")),
        "t3_premature_starve": bool(m.get("t3_premature_starve") or (m.get("anomalies") or {}).get("t3_premature_starve")),
        "prod_idle_bank_freeze": bool(m.get("prod_idle_bank_freeze") or (m.get("anomalies") or {}).get("prod_idle_bank_freeze")),
        "prod_idle_bank_freeze_sec": safe_num(m.get("prod_idle_bank_freeze_sec")),
        "gas_zero_harvest_freeze": bool(m.get("gas_zero_harvest_freeze") or (m.get("anomalies") or {}).get("gas_zero_harvest_freeze")),
        "tr_p95_ms": safe_num(m.get("tr_p95_ms")),
        "wall_timeout_tie": bool(m.get("wall_timeout_tie") or (m.get("anomalies") or {}).get("wall_timeout_tie")),
        "wall_timeout_winning_tie": bool(m.get("wall_timeout_winning_tie") or (m.get("anomalies") or {}).get("wall_timeout_winning_tie")),
        "one_base_lockout": bool(m.get("one_base_lockout") or (m.get("anomalies") or {}).get("one_base_lockout")),
        "spire_sched_drop": bool(m.get("spire_sched_drop") or (m.get("anomalies") or {}).get("spire_sched_drop")),
        "drip_feed_collapse": bool(m.get("drip_feed_collapse") or (m.get("anomalies") or {}).get("drip_feed_collapse")),
        "zero_kill_collapse": bool(
            m.get("zero_kill_collapse_loss")
            or m.get("zero_kill_collapse")
            or (m.get("anomalies") or {}).get("zero_kill_collapse_loss")
            or (m.get("anomalies") or {}).get("zero_kill_collapse")
        ),
        "early_opening_order_fault": bool(
            m.get("early_opening_order_fault")
            or (m.get("anomalies") or {}).get("early_opening_order_fault")
        ),
        "terran_111_opening_stall": bool(
            m.get("terran_111_opening_stall")
            or (m.get("anomalies") or {}).get("terran_111_opening_stall")
        ),
        "worker_econ_eff_4m_6m": safe_num(
            m.get("worker_econ_eff_4m_6m")
            if m.get("worker_econ_eff_4m_6m") is not None
            else mt.get("worker_econ_eff_4m_6m")
        ),
        "opp_worker_econ_eff_4m_6m": safe_num(m.get("opp_worker_econ_eff_4m_6m")),
        "econ_eff_collapse": bool(
            m.get("econ_eff_collapse")
            or (m.get("anomalies") or {}).get("econ_eff_collapse")
        ),
        "early_atk_pct_2m_6m": safe_num(
            m.get("early_atk_pct_2m_6m")
            if m.get("early_atk_pct_2m_6m") is not None
            else mt.get("early_atk_pct_2m_6m")
        ),
        "protoss_warpgate_sec": safe_num(
            m.get("protoss_warpgate_sec")
            if m.get("protoss_warpgate_sec") is not None
            else mt.get("protoss_warpgate_sec")
        ),
        "zerg_roach_warren_sec": safe_num(
            m.get("zerg_roach_warren_sec")
            if m.get("zerg_roach_warren_sec") is not None
            else mt.get("zerg_roach_warren_sec")
        ),
        "combat_death_home_pct": safe_num(
            m.get("combat_death_home_pct")
            if m.get("combat_death_home_pct") is not None
            else mt.get("combat_death_home_pct")
        ),
        "combat_death_enemy_pct": safe_num(
            m.get("combat_death_enemy_pct")
            if m.get("combat_death_enemy_pct") is not None
            else mt.get("combat_death_enemy_pct")
        ),
        "late_game_stalemate_tie": bool(
            m.get("late_game_stalemate_tie")
            or (m.get("anomalies") or {}).get("late_game_stalemate_tie")
        ),
        "action_rejects": int(m.get("action_rejects") or 0),
        "crashes": m.get("crashes") or [],
        "signatures": m.get("signatures") or [],
        "anomalies": m.get("anomalies") or {},
        "opp_cohort": m.get("opp_cohort") or "",
        "opp_supply_block_pct": safe_num(m.get("opp_supply_block_pct")),
        "p2_anomalies": m.get("p2_anomalies") if isinstance(m.get("p2_anomalies"), dict) else {},
        "is_selfplay": bool(
            m.get("is_selfplay")
            or (m.get("opp_cohort") == "selfplay")
            or str(m.get("opp_bot") or "").startswith("Mothman-")
        ),
    }


def is_selfplay_row(row):
    return bool(row.get("is_selfplay") or row.get("opp_cohort") == "selfplay" or str(row.get("opp_bot") or "").startswith("Mothman-"))


def is_core_row(row):
    if is_selfplay_row(row):
        return False
    c = str(row.get("opp_cohort") or "").strip().lower()
    if c.startswith("core"):
        return True
    if c.startswith("unseen"):
        return False
    return row.get("opp_bot") in CORE_14_OPPONENTS


def is_core12_row(row):
    return (not is_selfplay_row(row)) and (row.get("opp_bot") in CORE_12_OPPONENTS)


def is_unseen_row(row):
    return (not is_selfplay_row(row)) and (not is_core_row(row))


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
    w10_alive = [r["our_w10"] for r in rows if r["our_w10"] is not None and r["our_w10"] >= 10]

    scout_units = Counter(r["first_scout_unit"] for r in rows if r.get("first_scout_unit"))
    bo_seqs = Counter(r["opening_bo_sequence"] for r in rows if r.get("opening_bo_sequence"))

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
            if an.get("endgame_home_stall") or (r.get("endgame_home_stall_sec") or 0.0) >= 90.0:
                anom_counts["endgame_home_stall"] += 1
            if an.get("own_base_retreat") or (r.get("own_base_retreat_frames") or 0.0) >= 440.0:
                anom_counts["own_base_retreat"] += 1
            if an.get("air_aa_starvation"):
                anom_counts["air_aa_starvation"] += 1

    ehs_vals = [r["endgame_home_stall_sec"] for r in rows if r.get("endgame_home_stall_sec") is not None]
    obr_vals = [r["own_base_retreat_frames"] for r in rows if r.get("own_base_retreat_frames") is not None]
    robo_waste_vals = [r["non_combat_robo_waste_val"] for r in rows if r.get("non_combat_robo_waste_val") is not None]
    znl_vals = [r["zerg_non_ling_army_pct"] for r in rows if r.get("zerg_non_ling_army_pct") is not None and r["our_race"] == "Zerg"]
    grms_vals = [r["gas_rich_min_starved_ticks"] for r in rows if r.get("gas_rich_min_starved_ticks") is not None]
    otr_vals = [r["own_territory_retreat_frames"] for r in rows if r.get("own_territory_retreat_frames") is not None]
    pps_vals = [r["prod_placement_stall_ticks"] for r in rows if r.get("prod_placement_stall_ticks") is not None]
    sym_counts = Counter(r["map_symmetry_kind"] for r in rows if r.get("map_symmetry_kind"))
    t3_secs = [r["t3_first_sec"] for r in rows if r.get("t3_first_sec") is not None]
    tr_p95_vals = [r["tr_p95_ms"] for r in rows if r.get("tr_p95_ms") is not None]

    pk_army_ratios = [
        r["our_peak_army"] / max(1.0, r["opp_peak_army"])
        for r in rows
        if r["our_peak_army"] is not None and r["opp_peak_army"] is not None and r["opp_peak_army"] > 0
    ]
    step_max_vals = [r["step_max"] for r in rows if r["step_max"] is not None]
    step_outliers = [
        {"match_id": r["match_id"], "our_bot": r["our_bot"], "opp_bot": r["opp_bot"], "step_max": round(r["step_max"], 1)}
        for r in rows
        if r["step_max"] is not None and r["step_max"] > 500.0
    ]

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
        "w10_alive_med": med_opt(w10_alive),
        "bases_4m_med": med_opt([r["bases_4m"] for r in rows]),
        "bases_6m_med": med_opt([r["bases_6m"] for r in rows]),
        "bases_8m_med": med_opt([r["bases_8m"] for r in rows]),
        "prod_cnt_4m_med": med_opt([r["prod_cnt_4m"] for r in rows]),
        "prod_cnt_6m_med": med_opt([r["prod_cnt_6m"] for r in rows]),
        "prod_cnt_8m_med": med_opt([r["prod_cnt_8m"] for r in rows]),
        "prod_cnt_10m_med": med_opt([r["prod_cnt_10m"] for r in rows]),
        "primary_prod_4m_med": med_opt([r["primary_prod_4m"] for r in rows]),
        "primary_prod_6m_med": med_opt([r["primary_prod_6m"] for r in rows]),
        "primary_prod_8m_med": med_opt([r["primary_prod_8m"] for r in rows]),
        "queens_4m_med": med_opt([r["queens_4m"] for r in rows]),
        "queens_6m_med": med_opt([r["queens_6m"] for r in rows]),
        "queens_8m_med": med_opt([r["queens_8m"] for r in rows]),
        "army_val_4m_med": med_opt([r["army_val_4m"] for r in rows]),
        "army_val_6m_med": med_opt([r["army_val_6m"] for r in rows]),
        "army_val_8m_med": med_opt([r["army_val_8m"] for r in rows]),
        "army_val_10m_med": med_opt([r["army_val_10m"] for r in rows]),
        "first_scout_sec_med": med_opt([r["first_scout_sec"] for r in rows]),
        "enemy_first_seen_sec_med": med_opt([r["enemy_first_seen_sec"] for r in rows]),
        "scout_unit_counts": scout_units.most_common(4),
        "top_opening_sequences": bo_seqs.most_common(3),
        "upgrades_med": {
            "warpgate_sec": med_opt([r["warpgate_sec"] for r in rows]),
            "blink_sec": med_opt([r["blink_sec"] for r in rows]),
            "charge_sec": med_opt([r["charge_sec"] for r in rows]),
            "stim_sec": med_opt([r["stim_sec"] for r in rows]),
            "combat_shield_sec": med_opt([r["combat_shield_sec"] for r in rows]),
            "ling_speed_sec": med_opt([r["ling_speed_sec"] for r in rows]),
            "bane_speed_sec": med_opt([r["bane_speed_sec"] for r in rows]),
            "roach_speed_sec": med_opt([r["roach_speed_sec"] for r in rows]),
            "plus1_atk_sec": med_opt([r["plus1_atk_sec"] for r in rows]),
            "plus1_arm_sec": med_opt([r["plus1_arm_sec"] for r in rows]),
        },
        "tech2_sec_med": med_opt([r["tech2_sec"] for r in rows]),
        "pk_workers_avg": mean_opt([r["our_peak_workers"] for r in rows]),
        "pk_army_avg": mean_opt([r["our_peak_army"] for r in rows]),
        "opp_pk_army_avg": mean_opt([r["opp_peak_army"] for r in rows]),
        "dur_avg_sec": mean_opt([r["duration_sec"] for r in rows]),
        "pk_army_ratio_med": med_opt2(pk_army_ratios),
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
        "step_max_worst": round(max(step_max_vals), 1) if step_max_vals else None,
        "step_outliers_gt_500ms": step_outliers,
        "endgame_home_stall_count": sum(1 for v in ehs_vals if v >= 90.0),
        "endgame_home_stall_max_sec": round(max(ehs_vals), 1) if ehs_vals else None,
        "total_own_base_retreat_frames": int(round(sum(obr_vals))) if obr_vals else None,
        "own_base_retreat_matches": sum(1 for v in obr_vals if v >= 440.0),
        "total_non_combat_robo_waste_val": int(round(sum(robo_waste_vals))) if robo_waste_vals else None,
        "avg_zerg_non_ling_army_pct": mean_opt(znl_vals),
        "siege_range_zero_dps_losses": sum(1 for r in rows if r.get("siege_range_zero_dps_loss")),
        "cloaked_unit_damage_losses": sum(1 for r in rows if r.get("cloaked_unit_damage_loss")),
        "army_val_4m_ratio_vs_pro_med": med_opt2([r["army_val_4m_ratio_vs_pro"] for r in rows]),
        "army_val_8m_ratio_vs_pro_med": med_opt2([r["army_val_8m_ratio_vs_pro"] for r in rows]),
        "gas_rich_min_starved_matches": sum(1 for r in rows if r.get("gas_rich_min_starved") or (r.get("gas_rich_min_starved_ticks") or 0) >= 30),
        "total_gas_rich_min_starved_ticks": int(round(sum(grms_vals))) if grms_vals else None,
        "early_rush_idle_bank_3m_losses": sum(1 for r in rows if r.get("early_rush_idle_bank_3m")),
        "total_own_territory_retreat_frames": int(round(sum(otr_vals))) if otr_vals else None,
        "own_territory_retreat_matches": sum(1 for v in otr_vals if v >= 440.0),
        "prod_placement_stall_matches": sum(1 for r in rows if r.get("prod_placement_stall")),
        "total_prod_placement_stall_ticks": int(round(sum(pps_vals))) if pps_vals else None,
        "pvp_nat_delay_matches": sum(1 for r in rows if r.get("pvp_nat_delay_flag")),
        "map_symmetry_counts": dict(sym_counts) if sym_counts else None,
        "t3_started_matches": len(t3_secs) if (t3_secs or sym_counts) else None,
        "t3_first_sec_med": med_opt(t3_secs),
        "t3_early_2base_matches": sum(1 for r in rows if r.get("t3_first_sec") is not None and (r.get("t3_bases_at_start") or 99) <= 2) if (t3_secs or sym_counts) else None,
        "t3_premature_starve_matches": sum(1 for r in rows if r.get("t3_premature_starve")),
        "prod_idle_bank_freeze_matches": sum(1 for r in rows if r.get("prod_idle_bank_freeze")),
        "gas_zero_harvest_freeze_matches": sum(1 for r in rows if r.get("gas_zero_harvest_freeze")),
        "tr_p95_worst_ms": round(max(tr_p95_vals), 1) if tr_p95_vals else None,
        "wall_timeout_ties": sum(1 for r in rows if r.get("wall_timeout_tie")),
        "wall_timeout_winning_ties": sum(1 for r in rows if r.get("wall_timeout_winning_tie")),
        "one_base_lockout_matches": sum(1 for r in rows if r.get("one_base_lockout")),
        "spire_sched_drop_matches": sum(1 for r in rows if r.get("spire_sched_drop")),
        "drip_feed_collapse_matches": sum(1 for r in rows if r.get("drip_feed_collapse")),
        "zero_kill_collapse_matches": sum(1 for r in rows if r.get("zero_kill_collapse")),
        "early_opening_order_fault_matches": sum(1 for r in rows if r.get("early_opening_order_fault")),
        "terran_111_opening_stall_matches": sum(1 for r in rows if r.get("terran_111_opening_stall")),
        "worker_econ_eff_4m_6m_avg": mean_opt([r["worker_econ_eff_4m_6m"] for r in rows]),
        "opp_worker_econ_eff_4m_6m_avg": mean_opt([r["opp_worker_econ_eff_4m_6m"] for r in rows]),
        "econ_eff_collapse_matches": sum(1 for r in rows if r.get("econ_eff_collapse")),
        "early_atk_pct_2m_6m_avg": mean_opt([r["early_atk_pct_2m_6m"] for r in rows]),
        "protoss_warpgate_sec_med": med_opt([r["protoss_warpgate_sec"] for r in rows if r["our_race"] == "Protoss"]),
        "zerg_roach_warren_sec_med": med_opt([r["zerg_roach_warren_sec"] for r in rows if r["our_race"] == "Zerg"]),
        "combat_death_home_pct_avg": mean_opt([r["combat_death_home_pct"] for r in rows]),
        "combat_death_enemy_pct_avg": mean_opt([r["combat_death_enemy_pct"] for r in rows]),
        "late_game_stalemate_tie_matches": sum(1 for r in rows if r.get("late_game_stalemate_tie")),
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


def compare_vs_pro(summary, pro_ref, race=None):
    """Compute signed gaps (Mothman - Pro) and normalized divergence flags."""
    if not summary or summary.get("n", 0) == 0 or not pro_ref:
        return {}
    mc = pro_ref.get("minute_curves") or {}
    m4, m6, m8, m10 = mc.get("m4") or {}, mc.get("m6") or {}, mc.get("m8") or {}, mc.get("m10") or {}
    pro_prod4 = safe_num(m4.get("prod_cnt_med"))
    pro_prod6 = safe_num(m6.get("prod_cnt_med"))
    pro_prod8 = safe_num(m8.get("prod_cnt_med"))
    pro_av4 = safe_num(m4.get("army_val_med"))
    pro_av6 = safe_num(m6.get("army_val_med"))
    pro_av8 = safe_num(m8.get("army_val_med"))
    pro_av10 = safe_num(m10.get("army_val_med"))
    pro_q4 = safe_num(m4.get("queens_med"))

    av6_ratio = (
        round(summary["army_val_6m_med"] / pro_av6, 2)
        if summary.get("army_val_6m_med") is not None and pro_av6 and pro_av6 > 0
        else None
    )
    av8_ratio = (
        round(summary["army_val_8m_med"] / pro_av8, 2)
        if summary.get("army_val_8m_med") is not None and pro_av8 and pro_av8 > 0
        else None
    )

    gaps = {
        "w2_gap": diff_val(summary.get("w2_med"), pro_ref.get("w2m")),
        "w4_gap": diff_val(summary.get("w4_alive_med"), pro_ref.get("w4m")),
        "w6_gap": diff_val(summary.get("w6_alive_med"), pro_ref.get("w6m")),
        "w8_gap": diff_val(summary.get("w8_alive_med"), pro_ref.get("w8m")),
        "w10_gap": diff_val(summary.get("w10_alive_med"), pro_ref.get("w10m")),
        "prod4_gap": diff_val(summary.get("prod_cnt_4m_med"), pro_prod4),
        "prod6_gap": diff_val(summary.get("prod_cnt_6m_med"), pro_prod6),
        "prod8_gap": diff_val(summary.get("prod_cnt_8m_med"), pro_prod8),
        "queens4_gap": diff_val(summary.get("queens_4m_med"), pro_q4) if race == "Zerg" else None,
        "army_val_4m_gap": diff_val(summary.get("army_val_4m_med"), pro_av4, 0),
        "army_val_6m_gap": diff_val(summary.get("army_val_6m_med"), pro_av6, 0),
        "army_val_8m_gap": diff_val(summary.get("army_val_8m_med"), pro_av8, 0),
        "army_val_10m_gap": diff_val(summary.get("army_val_10m_med"), pro_av10, 0),
        "army_val_6m_ratio": av6_ratio,
        "army_val_8m_ratio": av8_ratio,
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
    if gaps["prod6_gap"] is not None and gaps["prod6_gap"] <= -2.0:
        flags.append(f"PROD_DEFICIT_6M({gaps['prod6_gap']:+.1f})")
    if gaps["prod8_gap"] is not None and gaps["prod8_gap"] <= -2.5:
        flags.append(f"PROD_DEFICIT_8M({gaps['prod8_gap']:+.1f})")
    if av8_ratio is not None and av8_ratio < 0.55:
        flags.append(f"ARMY_DEFICIT_8M({av8_ratio:.2f}x)")
    if race == "Zerg" and gaps["queens4_gap"] is not None and gaps["queens4_gap"] <= -1.5:
        flags.append(f"QUEEN_DEFICIT_4M({gaps['queens4_gap']:+.1f})")
    if race == "Zerg":
        su = dict(summary.get("scout_unit_counts") or [])
        tot_s = sum(su.values())
        if tot_s > 0 and (su.get("Drone", 0) / tot_s) > 0.25:
            flags.append(f"ANTI_PRO_DRONE_SCOUT({su['Drone']}/{tot_s})")
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


def compute_paired_diff(cur_rows, base_rows):
    """Pair matches strictly by (our_bot, opp_bot) — never numeric match_id."""
    if not base_rows:
        return []
    b_idx = {(r["our_bot"], r["opp_bot"]): r for r in base_rows}
    pairs = []
    for c in sorted(cur_rows, key=lambda r: (r["our_bot"], r["opp_bot"])):
        b = b_idx.get((c["our_bot"], c["opp_bot"]))
        if not b:
            continue
        pairs.append({
            "our_bot": c["our_bot"],
            "opp_bot": c["opp_bot"],
            "matchup": c["matchup"],
            "base_result": b["result"],
            "cur_result": c["result"],
            "flipped": b["result"] != c["result"],
            "base_trade": b["trade_ratio"],
            "cur_trade": c["trade_ratio"],
            "trade_delta": diff_val(c["trade_ratio"], b["trade_ratio"], 2),
            "base_pk_army": b["our_peak_army"],
            "cur_pk_army": c["our_peak_army"],
            "opp_pk_army": c["opp_peak_army"],
            "base_w6": b["our_w6"],
            "cur_w6": c["our_w6"],
            "base_sup_blk": b["supply_block_pct"],
            "cur_sup_blk": c["supply_block_pct"],
            "cur_step_max": c["step_max"],
            "cur_anomalies": [k for k, v in (c["anomalies"] or {}).items() if v],
        })
    return pairs


# ---------------------------------------------------------------------------
# Read-only SQLite KPIs: Stall Watchdog (4-Law Audit) & Pro-vs-Mothman Base Geometry (4:10)
# ---------------------------------------------------------------------------

BASE_TOWN_HALLS = frozenset({
    "Nexus", "CommandCenter", "OrbitalCommand", "PlanetaryFortress",
    "Hatchery", "Lair", "Hive",
})
BASE_GASES = frozenset({
    "Assimilator", "Refinery", "Extractor",
    "AssimilatorRich", "RefineryRich", "ExtractorRich",
})
BASE_SUPPLY = frozenset({"Pylon", "SupplyDepot", "SupplyDepotLowered"})
BASE_STATIC_DEF = frozenset({
    "PhotonCannon", "ShieldBattery", "Bunker",
    "MissileTurret", "SpineCrawler", "SporeCrawler",
})
BASE_PROD = frozenset({
    "Gateway", "WarpGate", "RoboticsFacility", "Stargate",
    "Barracks", "Factory", "Starport",
})
BASE_TECH = frozenset({
    "CyberneticsCore", "TwilightCouncil", "Forge", "RoboticsBay",
    "TemplarArchive", "DarkShrine", "FleetBeacon",
    "EngineeringBay", "Armory", "GhostAcademy", "FusionCore",
    "SpawningPool", "RoachWarren", "BanelingNest", "EvolutionChamber",
    "HydraliskDen", "Spire", "InfestationPit", "LurkerDenMP",
})
BASE_ADDONS = frozenset({
    "TechLab", "Reactor",
    "BarracksTechLab", "BarracksReactor",
    "FactoryTechLab", "FactoryReactor",
    "StarportTechLab", "StarportReactor",
})
BASE_ALL_BLDGS = (
    BASE_TOWN_HALLS | BASE_GASES | BASE_SUPPLY | BASE_STATIC_DEF
    | BASE_PROD | BASE_TECH | BASE_ADDONS
)
TH_FOR_RACE = {"Protoss": "Nexus", "Terran": "CommandCenter", "Zerg": "Hatchery"}

# 519-match Stall Watchdog audit reference (Loops 42-48 + Live Ships #5/#6)
STALL_WATCHDOG_AUDIT_REF = {
    "n": 519,
    "sup_cap_min_pct": 32.4,
    "zero_income_pct": 9.4,
    "zero_gas_pct": 12.1,
    "wk_plateau_8m_pct": 23.7,
    "gas_rich_min_starved_pct": 13.9,
}

# Canonical Grandmaster Pro 4:10 base geometry reference (182 pro_corpus ladder games:
# herO, Stats, Maru, HeroMarine, Serral; Main TH=(0,0), Natural along +X).
PRO_BASE_GEOMETRY_BY_MATCHUP = {
    "PvP": {"n": 22, "sup_nn": 14.53, "sup_clump_pct": 7.9, "main_wall_pct": 81.8, "nat_wall_pct": 31.8, "nat_sup_pct": 72.7, "nat_def": 0.45, "tech_exposed": 0.0},
    "PvT": {"n": 25, "sup_nn": 16.26, "sup_clump_pct": 2.0, "main_wall_pct": 44.0, "nat_wall_pct": 36.0, "nat_sup_pct": 92.0, "nat_def": 0.24, "tech_exposed": 0.4},
    "PvZ": {"n": 25, "sup_nn": 19.51, "sup_clump_pct": 12.7, "main_wall_pct": 48.0, "nat_wall_pct": 100.0, "nat_sup_pct": 100.0, "nat_def": 0.0, "tech_exposed": 1.28},
    "TvP": {"n": 25, "sup_nn": 7.75, "sup_clump_pct": 69.6, "main_wall_pct": 88.0, "nat_wall_pct": 40.0, "nat_sup_pct": 60.0, "nat_def": 0.28, "tech_exposed": 0.04},
    "TvT": {"n": 3, "sup_nn": 7.39, "sup_clump_pct": 66.7, "main_wall_pct": 100.0, "nat_wall_pct": 66.7, "nat_sup_pct": 100.0, "nat_def": 0.0, "tech_exposed": 0.0},
    "TvZ": {"n": 25, "sup_nn": 6.53, "sup_clump_pct": 72.1, "main_wall_pct": 76.0, "nat_wall_pct": 68.0, "nat_sup_pct": 76.0, "nat_def": 0.24, "tech_exposed": 0.16},
    "ZvP": {"n": 25, "sup_nn": None, "sup_clump_pct": 0.0, "main_wall_pct": 0.0, "nat_wall_pct": 24.0, "nat_sup_pct": 0.0, "nat_def": 0.6, "tech_exposed": 0.76},
    "ZvT": {"n": 7, "sup_nn": None, "sup_clump_pct": 0.0, "main_wall_pct": 0.0, "nat_wall_pct": 28.6, "nat_sup_pct": 0.0, "nat_def": 0.57, "tech_exposed": 0.71},
    "ZvZ": {"n": 25, "sup_nn": None, "sup_clump_pct": 0.0, "main_wall_pct": 0.0, "nat_wall_pct": 48.0, "nat_sup_pct": 0.0, "nat_def": 0.04, "tech_exposed": 2.12},
}


def _build_pro_base_geometry_ref():
    def _wavg(mus, key, prec=1):
        tot_w = 0
        tot_v = 0.0
        for mu in mus:
            d = PRO_BASE_GEOMETRY_BY_MATCHUP[mu]
            v = d.get(key)
            if v is not None and d["n"] > 0:
                tot_w += d["n"]
                tot_v += d["n"] * float(v)
        return round(tot_v / tot_w, prec) if tot_w else None

    p_mus = ("PvP", "PvT", "PvZ")
    t_mus = ("TvP", "TvT", "TvZ")
    pt_mus = p_mus + t_mus
    return {
        "n": sum(d["n"] for d in PRO_BASE_GEOMETRY_BY_MATCHUP.values()),
        "pylon_clump_pct": _wavg(p_mus, "sup_clump_pct", 1),
        "pylon_spacing_nn": _wavg(p_mus, "sup_nn", 1),
        "nat_supply_pct": _wavg(pt_mus, "nat_sup_pct", 1),
        "protoss_nat_supply_pct": _wavg(p_mus, "nat_sup_pct", 1),
        "terran_nat_supply_pct": _wavg(t_mus, "nat_sup_pct", 1),
        "zvz_nat_wall_pct": PRO_BASE_GEOMETRY_BY_MATCHUP["ZvZ"]["nat_wall_pct"],
        "early_bunkers_4m": _wavg(t_mus, "nat_def", 2),
        "terran_nat_def": _wavg(t_mus, "nat_def", 2),
        "pvz_tech_exposed": PRO_BASE_GEOMETRY_BY_MATCHUP["PvZ"]["tech_exposed"],
        "by_matchup": PRO_BASE_GEOMETRY_BY_MATCHUP,
    }


PRO_BASE_GEOMETRY_REF = _build_pro_base_geometry_ref()


def open_replay_db_ro(db_path):
    """Open arena_replays.sqlite strictly read-only (?mode=ro). Returns None if unavailable."""
    if not db_path:
        return None
    p = os.path.abspath(os.path.expanduser(str(db_path)))
    if not os.path.isfile(p):
        return None
    try:
        conn = sqlite3.connect(Path(p).as_uri() + "?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        return conn
    except sqlite3.Error:
        return None


def _chunked_in_query(conn, sql_template, ids, extra_params=(), chunk_size=400):
    """Execute a query with `{ph}` placeholder safely across arbitrary ID list sizes."""
    out = []
    id_list = list(ids)
    for i in range(0, len(id_list), chunk_size):
        chunk = id_list[i:i + chunk_size]
        ph = ",".join("?" for _ in chunk)
        sql = sql_template.format(ph=ph)
        out.extend(conn.execute(sql, tuple(chunk) + tuple(extra_params)).fetchall())
    return out


def resolve_sqlite_run_and_replay_ids(conn, score_path, rows, run_id=None):
    """
    Resolve the SQLite `run_id` and exact matched `replay_id`s corresponding to a
    `score-replay-batch.rkt` JSON and its already-filtered `rows` (self-play / opp-crash excluded).
    Returns `(resolved_run_id, replay_ids)`.
    """
    if conn is None:
        return None, []
    fnames = {os.path.basename(m["file"]) for m in (rows or []) if m.get("file")}
    resolved_run_id = run_id

    try:
        if not resolved_run_id and score_path:
            abs_sp = os.path.abspath(score_path)
            r = conn.execute(
                "SELECT run_id FROM runs WHERE score_json_path = ? OR score_json_path = ? "
                "ORDER BY ingested_at DESC LIMIT 1",
                (abs_sp, score_path),
            ).fetchone()
            if r:
                resolved_run_id = r["run_id"]
            else:
                base_sp = os.path.basename(score_path)
                for cand in conn.execute(
                    "SELECT run_id, score_json_path FROM runs "
                    "WHERE score_json_path IS NOT NULL ORDER BY ingested_at DESC"
                ).fetchall():
                    if os.path.basename(cand["score_json_path"]) == base_sp:
                        resolved_run_id = cand["run_id"]
                        break

        if not resolved_run_id and fnames:
            counts = Counter()
            latest_mt = defaultdict(float)
            fn_list = sorted(fnames)
            for i in range(0, len(fn_list), 400):
                chunk = fn_list[i:i + 400]
                ph = ",".join("?" for _ in chunk)
                for r in conn.execute(
                    f"SELECT run_id, replay_filename, COALESCE(replay_mtime, 0) AS mt "
                    f"FROM matches WHERE replay_filename IN ({ph})",
                    chunk,
                ).fetchall():
                    counts[r["run_id"]] += 1
                    if float(r["mt"] or 0.0) > latest_mt[r["run_id"]]:
                        latest_mt[r["run_id"]] = float(r["mt"] or 0.0)
            if counts:
                best_rid, best_hits = max(
                    counts.items(),
                    key=lambda kv: (kv[1], latest_mt[kv[0]], kv[0]),
                )
                if best_hits >= max(1, (len(fnames) + 1) // 2):
                    resolved_run_id = best_rid

        if not resolved_run_id:
            return None, []

        mrows = conn.execute(
            "SELECT replay_id, replay_filename, COALESCE(is_selfplay, 0) AS is_selfplay "
            "FROM matches WHERE run_id = ?",
            (resolved_run_id,),
        ).fetchall()
        if not mrows:
            return resolved_run_id, []

        if fnames:
            matched = [r["replay_id"] for r in mrows if r["replay_filename"] in fnames]
            if matched:
                return resolved_run_id, matched

        ext = [r["replay_id"] for r in mrows if not r["is_selfplay"]]
        selected = ext if ext else [r["replay_id"] for r in mrows]
        return resolved_run_id, selected
    except sqlite3.Error:
        return None, []


def _summarize_stall_watchdog_matches(rep_entries):
    """Aggregate Stall Watchdog KPIs across a list of `(race, snaps)` entries."""
    n = len(rep_entries)
    if n == 0:
        return None
    sup_cap_matches = 0
    sup_cap_snaps = 0
    sup_cap_snaps_denom = 0
    zero_income_matches = 0
    zero_gas_matches = 0
    zero_gas_5m_denom = 0
    wk_plateau_8m_matches = 0
    wk_plateau_8m_denom = 0
    wk_plateau_5m_matches = 0
    wk_plateau_5m_denom = 0
    wk_plateau_5m_or_8m_matches = 0
    gas_rich_min_starved_matches = 0

    for _race, snaps in rep_entries:
        has_sup_cap = False
        has_zero_inc = False
        has_zero_gas = False
        has_5m_plus = False
        has_5m = False
        plat_5m = False
        has_8m = False
        plat_8m = False
        has_grms = False
        for s in snaps:
            mn = int(s["minute"] or 0)
            fm = float(s["food_made"] or 0.0)
            fu = float(s["food_used"] or 0.0)
            wa = float(s["workers_active"] or 0.0)
            mr = float(s["minerals_rate"] or 0.0)
            vr = float(s["vespene_rate"] or 0.0)
            mc = float(s["minerals_current"] or 0.0)
            vc = float(s["vespene_current"] or 0.0)

            if mn >= 1 and fm < 195.0:
                sup_cap_snaps_denom += 1
                if fu >= fm:
                    has_sup_cap = True
                    sup_cap_snaps += 1
            if mn >= 2 and wa >= 5.0 and mr <= 0.0:
                has_zero_inc = True
            if mn >= 5:
                has_5m_plus = True
                # True zero-gas stall: >=16 active workers, 0 gas income, and not intentionally
                # banked above the Law-2 gas valve cutoff (>=450 vespene).
                if wa >= 16.0 and vr <= 0.0 and vc < 450.0:
                    has_zero_gas = True
            if mn == 5:
                has_5m = True
                if wa <= 24.0:
                    plat_5m = True
            if mn == 8:
                has_8m = True
                if wa <= 36.0:
                    plat_8m = True
            if vc >= 450.0 and mc < 200.0 and fu < 175.0:
                has_grms = True

        if has_sup_cap:
            sup_cap_matches += 1
        if has_zero_inc:
            zero_income_matches += 1
        if has_5m_plus:
            zero_gas_5m_denom += 1
            if has_zero_gas:
                zero_gas_matches += 1
        if has_5m:
            wk_plateau_5m_denom += 1
            if plat_5m:
                wk_plateau_5m_matches += 1
        if has_8m:
            wk_plateau_8m_denom += 1
            if plat_8m:
                wk_plateau_8m_matches += 1
        if plat_5m or plat_8m:
            wk_plateau_5m_or_8m_matches += 1
        if has_grms:
            gas_rich_min_starved_matches += 1

    return {
        "n": n,
        "sup_cap_min_pct": round(100.0 * sup_cap_matches / n, 1),
        "sup_cap_matches": sup_cap_matches,
        "sup_cap_snapshots_pct": (
            round(100.0 * sup_cap_snaps / sup_cap_snaps_denom, 1)
            if sup_cap_snaps_denom > 0
            else None
        ),
        "zero_income_matches": zero_income_matches,
        "zero_income_pct": round(100.0 * zero_income_matches / n, 1),
        "zero_gas_matches": zero_gas_matches,
        "zero_gas_pct": round(100.0 * zero_gas_matches / n, 1),
        "zero_gas_5m_denom": zero_gas_5m_denom,
        "zero_gas_5m_pct": (
            round(100.0 * zero_gas_matches / zero_gas_5m_denom, 1)
            if zero_gas_5m_denom > 0
            else None
        ),
        "wk_plateau_8m_pct": (
            round(100.0 * wk_plateau_8m_matches / wk_plateau_8m_denom, 1)
            if wk_plateau_8m_denom > 0
            else None
        ),
        "wk_plateau_8m_matches": wk_plateau_8m_matches,
        "wk_plateau_8m_denom": wk_plateau_8m_denom,
        "wk_plateau_5m_matches": wk_plateau_5m_matches,
        "wk_plateau_5m_denom": wk_plateau_5m_denom,
        "wk_plateau_5m_or_8m_pct": round(100.0 * wk_plateau_5m_or_8m_matches / n, 1),
        "gas_rich_min_starved_matches": gas_rich_min_starved_matches,
        "gas_rich_min_starved_pct": round(100.0 * gas_rich_min_starved_matches / n, 1),
    }


def compute_stall_watchdog_kpis(conn, replay_ids):
    """Compute Stall Watchdog 4-Law KPIs from read-only `arena_replays.sqlite`."""
    if conn is None or not replay_ids:
        return None
    try:
        rows = _chunked_in_query(
            conn,
            "SELECT m.replay_id, m.actual_race, m.our_race, "
            "       s.minute, s.minerals_current, s.vespene_current, "
            "       s.minerals_rate, s.vespene_rate, s.workers_active, "
            "       s.food_used, s.food_made "
            "FROM matches m "
            "JOIN match_minute_stats s "
            "  ON s.replay_id = m.replay_id AND s.player_id = m.our_player_id "
            "WHERE m.replay_id IN ({ph}) "
            "ORDER BY m.replay_id, s.minute",
            replay_ids,
        )
    except sqlite3.Error:
        return None
    if not rows:
        return None

    by_rep = defaultdict(list)
    race_by_rep = {}
    for r in rows:
        rid = r["replay_id"]
        by_rep[rid].append(r)
        if rid not in race_by_rep:
            ar = r["actual_race"] if r["actual_race"] in RACES else r["our_race"]
            race_by_rep[rid] = ar if ar in RACES else "Unknown"

    entries = [(race_by_rep[rid], snaps) for rid, snaps in by_rep.items()]
    summary = _summarize_stall_watchdog_matches(entries)
    if summary is None:
        return None
    summary["by_race"] = {}
    for race in RACES:
        sub = [e for e in entries if e[0] == race]
        if sub:
            summary["by_race"][race] = _summarize_stall_watchdog_matches(sub)
    return summary


def compute_stall_watchdog_delta(cur, base):
    if not cur or not base:
        return None
    return {
        "sup_cap_min_pct": diff_val(cur.get("sup_cap_min_pct"), base.get("sup_cap_min_pct"), 1),
        "sup_cap_matches": diff_val(cur.get("sup_cap_matches"), base.get("sup_cap_matches"), 0),
        "zero_income_matches": diff_val(cur.get("zero_income_matches"), base.get("zero_income_matches"), 0),
        "zero_income_pct": diff_val(cur.get("zero_income_pct"), base.get("zero_income_pct"), 1),
        "zero_gas_matches": diff_val(cur.get("zero_gas_matches"), base.get("zero_gas_matches"), 0),
        "zero_gas_pct": diff_val(cur.get("zero_gas_pct"), base.get("zero_gas_pct"), 1),
        "wk_plateau_8m_pct": diff_val(cur.get("wk_plateau_8m_pct"), base.get("wk_plateau_8m_pct"), 1),
        "wk_plateau_8m_matches": diff_val(cur.get("wk_plateau_8m_matches"), base.get("wk_plateau_8m_matches"), 0),
        "gas_rich_min_starved_matches": diff_val(
            cur.get("gas_rich_min_starved_matches"),
            base.get("gas_rich_min_starved_matches"),
            0,
        ),
    }


def normalize_base_coords(bldgs):
    """
    Given `[(unit_type, x, y, sec), ...]`, find Main TH (earliest TH) and Natural TH
    (first subsequent TH at distance 18..55 tiles). Rotate coordinate frame so
    Main=(0, 0) and Natural=(+nat_dist, 0), flipping Y deterministically so early
    buildings (`0 < sec <= 120`) sit on +Y. Returns `(nat_dist, norm_bldgs)` or `None`.
    """
    ths = [b for b in bldgs if b[0] in BASE_TOWN_HALLS]
    if not ths:
        return None
    ths.sort(key=lambda b: b[3])
    mx, my = ths[0][1], ths[0][2]
    nat = None
    for b in ths[1:]:
        d = math.hypot(b[1] - mx, b[2] - my)
        if 18.0 <= d <= 55.0:
            nat = b
            break
    if nat is None:
        return None
    dx, dy = nat[1] - mx, nat[2] - my
    nat_dist = math.hypot(dx, dy)
    if nat_dist <= 0.0:
        return None
    ux, uy = dx / nat_dist, dy / nat_dist
    vx, vy = -uy, ux

    out = []
    for ut, x, y, sec in bldgs:
        px, py = x - mx, y - my
        rx = px * ux + py * uy
        ry = px * vx + py * vy
        out.append((ut, rx, ry, sec))
    early_ref = [
        b[2] for b in out
        if b[0] in (BASE_SUPPLY | BASE_PROD | BASE_TECH) and 0.0 < b[3] <= 120.0
    ]
    if early_ref and sum(early_ref) < 0.0:
        out = [(ut, rx, -ry, sec) for ut, rx, ry, sec in out]
    return nat_dist, out


def compute_single_base_geometry(race, nat_dist, norm_bldgs):
    """Compute normalized 4:10 (<=250s) base geometry metrics for one match."""
    b250 = [b for b in norm_bldgs if b[3] <= 250.0]
    non_th_gas = [
        b for b in b250
        if b[0] not in BASE_TOWN_HALLS and b[0] not in BASE_GASES and b[0] not in BASE_ADDONS
    ]
    if len(non_th_gas) < 3:
        return None

    sups = [b for b in b250 if b[0] in BASE_SUPPLY]
    sup_nn = []
    sup_clumped = 0
    for i, a in enumerate(sups):
        dists = [math.hypot(a[1] - b[1], a[2] - b[2]) for j, b in enumerate(sups) if i != j]
        if dists:
            md = min(dists)
            sup_nn.append(md)
            if md < 5.0:
                sup_clumped += 1

    main_ramp_bldgs = [
        b for b in non_th_gas
        if 0.25 * nat_dist <= b[1] <= 0.75 * nat_dist and abs(b[2]) <= 12.0
    ]
    nat_area_bldgs = [b for b in non_th_gas if math.hypot(b[1] - nat_dist, b[2]) <= 16.0]

    main_wall_tight = any(
        math.hypot(a[1] - b[1], a[2] - b[2]) <= 4.2
        for i, a in enumerate(main_ramp_bldgs)
        for b in main_ramp_bldgs[i + 1:]
    )
    nat_wall_tight = any(
        math.hypot(a[1] - b[1], a[2] - b[2]) <= 4.2
        for i, a in enumerate(nat_area_bldgs)
        for b in nat_area_bldgs[i + 1:]
    )

    tech_objs = [
        b for b in b250
        if b[0] in BASE_TECH or b[0] in {"RoboticsFacility", "Stargate", "Factory", "Starport"}
    ]
    exposed_tech = sum(1 for b in tech_objs if (b[1] / nat_dist) >= 0.70)
    nat_static = sum(
        1 for b in b250
        if b[0] in BASE_STATIC_DEF and math.hypot(b[1] - nat_dist, b[2]) <= 15.0
    )
    early_bunkers_4m = sum(1 for b in b250 if b[0] == "Bunker")
    has_nat_supply = any(math.hypot(b[1] - nat_dist, b[2]) <= 14.0 for b in sups)

    return {
        "race": race,
        "nat_dist": nat_dist,
        "bldg_cnt": len(non_th_gas),
        "sup_cnt": len(sups),
        "sup_nn_avg": (sum(sup_nn) / len(sup_nn)) if sup_nn else None,
        "sup_clump_pct": (100.0 * sup_clumped / len(sups)) if len(sups) >= 2 else None,
        "main_wall_tight": 100.0 if main_wall_tight else 0.0,
        "nat_wall_tight": 100.0 if nat_wall_tight else 0.0,
        "has_nat_supply": 100.0 if has_nat_supply else 0.0,
        "nat_static": nat_static,
        "early_bunkers_4m": early_bunkers_4m,
        "tech_exposed_cnt": exposed_tech,
    }


def _avg_prec(vals, prec=1):
    xs = [float(v) for v in vals if v is not None]
    return round(sum(xs) / len(xs), prec) if xs else None


def _summarize_base_geometry_slice(mets):
    if not mets:
        return None
    return {
        "n": len(mets),
        "sup_nn": _avg_prec([m["sup_nn_avg"] for m in mets], 2),
        "sup_clump_pct": _avg_prec([m["sup_clump_pct"] for m in mets], 1),
        "main_wall_pct": _avg_prec([m["main_wall_tight"] for m in mets], 1),
        "nat_wall_pct": _avg_prec([m["nat_wall_tight"] for m in mets], 1),
        "nat_sup_pct": _avg_prec([m["has_nat_supply"] for m in mets], 1),
        "nat_def": _avg_prec([m["nat_static"] for m in mets], 2),
        "early_bunkers_4m": _avg_prec([m["early_bunkers_4m"] for m in mets], 2),
        "tech_exposed": _avg_prec([m["tech_exposed_cnt"] for m in mets], 2),
    }


def compute_base_geometry_kpis(conn, replay_ids):
    """Compute Pro-vs-Mothman 4:10 Base Geometry KPIs from read-only `arena_replays.sqlite`."""
    if conn is None or not replay_ids:
        return None
    try:
        mrows = _chunked_in_query(
            conn,
            "SELECT replay_id, actual_race, our_race, opp_race, matchup, "
            "       our_player_id, our_start_x, our_start_y, duration_sec "
            "FROM matches "
            "WHERE replay_id IN ({ph}) "
            "  AND COALESCE(duration_sec, 0) >= 250.0 "
            "  AND our_start_x IS NOT NULL AND our_start_y IS NOT NULL",
            replay_ids,
        )
        if not mrows:
            return None
        cand_ids = [r["replay_id"] for r in mrows]
        bev_rows = _chunked_in_query(
            conn,
            "SELECT replay_id, player_id, unit_type, sec, x, y "
            "FROM match_build_events "
            "WHERE replay_id IN ({ph}) "
            "  AND event_type IN ('born', 'init') "
            "  AND sec <= 270.0 "
            "  AND x IS NOT NULL AND y IS NOT NULL",
            cand_ids,
        )
    except sqlite3.Error:
        return None

    bmap = defaultdict(list)
    for r in bev_rows:
        ut = r["unit_type"]
        if ut in BASE_ALL_BLDGS:
            bmap[(r["replay_id"], r["player_id"])].append(
                (ut, float(r["x"]), float(r["y"]), float(r["sec"]))
            )

    all_mets = []
    by_race_mets = defaultdict(list)
    by_mu_mets = defaultdict(list)

    for m in mrows:
        orace = m["actual_race"] if m["actual_race"] in RACES else m["our_race"]
        if orace not in TH_FOR_RACE:
            continue
        mu = m["matchup"]
        if mu not in MATCHUPS and m["opp_race"] in RACES:
            mu = f"{orace[0]}v{m['opp_race'][0]}"
        bldgs = [(TH_FOR_RACE[orace], float(m["our_start_x"]), float(m["our_start_y"]), 0.0)]
        bldgs.extend(bmap.get((m["replay_id"], m["our_player_id"]), []))
        norm = normalize_base_coords(bldgs)
        if norm is None:
            continue
        nat_dist, norm_bldgs = norm
        met = compute_single_base_geometry(orace, nat_dist, norm_bldgs)
        if met is None:
            continue
        all_mets.append(met)
        by_race_mets[orace].append(met)
        if mu in MATCHUPS:
            by_mu_mets[mu].append(met)

    if not all_mets:
        return None

    p_mets = by_race_mets["Protoss"]
    t_mets = by_race_mets["Terran"]
    pt_mets = p_mets + t_mets
    zvz_mets = by_mu_mets["ZvZ"]
    pvz_mets = by_mu_mets["PvZ"]
    p_clump_vals = [m["sup_clump_pct"] for m in p_mets if m["sup_clump_pct"] is not None]

    return {
        "n": len(all_mets),
        "pylon_clump_pct": _avg_prec(p_clump_vals, 1),
        "pylon_clump_n": len(p_clump_vals),
        "pylon_spacing_nn": _avg_prec([m["sup_nn_avg"] for m in p_mets], 1),
        "nat_supply_pct": _avg_prec([m["has_nat_supply"] for m in pt_mets], 1),
        "nat_supply_n": len(pt_mets),
        "protoss_nat_supply_pct": _avg_prec([m["has_nat_supply"] for m in p_mets], 1),
        "protoss_n": len(p_mets),
        "terran_nat_supply_pct": _avg_prec([m["has_nat_supply"] for m in t_mets], 1),
        "terran_n": len(t_mets),
        "zvz_nat_wall_pct": _avg_prec([m["nat_wall_tight"] for m in zvz_mets], 1),
        "zvz_n": len(zvz_mets),
        "early_bunkers_4m": _avg_prec([m["early_bunkers_4m"] for m in t_mets], 2),
        "terran_nat_def": _avg_prec([m["nat_static"] for m in t_mets], 2),
        "pvz_tech_exposed": _avg_prec([m["tech_exposed_cnt"] for m in pvz_mets], 2),
        "pvz_n": len(pvz_mets),
        "by_race": {
            r: _summarize_base_geometry_slice(by_race_mets[r])
            for r in RACES if by_race_mets[r]
        },
        "by_matchup": {
            mu: _summarize_base_geometry_slice(by_mu_mets[mu])
            for mu in MATCHUPS if by_mu_mets[mu]
        },
    }


def compute_base_geometry_delta(cur, base):
    if not cur or not base:
        return None
    return {
        "pylon_clump_pct": diff_val(cur.get("pylon_clump_pct"), base.get("pylon_clump_pct"), 1),
        "pylon_spacing_nn": diff_val(cur.get("pylon_spacing_nn"), base.get("pylon_spacing_nn"), 1),
        "nat_supply_pct": diff_val(cur.get("nat_supply_pct"), base.get("nat_supply_pct"), 1),
        "protoss_nat_supply_pct": diff_val(cur.get("protoss_nat_supply_pct"), base.get("protoss_nat_supply_pct"), 1),
        "terran_nat_supply_pct": diff_val(cur.get("terran_nat_supply_pct"), base.get("terran_nat_supply_pct"), 1),
        "zvz_nat_wall_pct": diff_val(cur.get("zvz_nat_wall_pct"), base.get("zvz_nat_wall_pct"), 1),
        "early_bunkers_4m": diff_val(cur.get("early_bunkers_4m"), base.get("early_bunkers_4m"), 2),
        "terran_nat_def": diff_val(cur.get("terran_nat_def"), base.get("terran_nat_def"), 2),
        "pvz_tech_exposed": diff_val(cur.get("pvz_tech_exposed"), base.get("pvz_tech_exposed"), 2),
    }


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
        tsum = tactics_data.get("summary") if isinstance(tactics_data.get("summary"), dict) else tactics_data
        passed = tsum.get("passed")
        total = tsum.get("total")
        if passed is not None and total:
            gates["tactics_suite_100pct"] = (passed == total and tsum.get("total_wire_rejects", 0) == 0)
        elif tactics_data.get("mode") == "duel" and total:
            if "draws" in tsum:
                # Honest KO/Points/Draw Arena 2.0 scoring: >=80% win rate AND >=1.25x agg trade
                wr = tsum.get("mothman_wins", 0) / max(1, total)
                gates["tactics_suite_100pct"] = (wr >= 0.80 and float(tsum.get("agg_trade_ratio", 0.0)) >= 1.25)
            else:
                gates["tactics_suite_100pct"] = (tsum.get("p2_wins", 99) == 0 and tsum.get("mothman_wins", 0) > 0)
    return gates


def main():
    ap = argparse.ArgumentParser(description="Compare Mothman gauntlet scores against Pro Replay Corpus baselines.")
    ap.add_argument("--current", required=True, help="Current wave score JSON from score-replay-batch.rkt")
    ap.add_argument("--baseline", default=None, help="Optional baseline/previous wave score JSON for delta")
    ap.add_argument("--hwm", default=None, help="Optional High-Water Mark score JSON for side-by-side HWM delta")
    ap.add_argument("--pro-baselines", default=DEFAULT_PRO_BASELINES, help="Path to pro_baselines.json")
    ap.add_argument("--tactics", default=None, help="Optional tactics scorecard JSON")
    ap.add_argument("--out-json", default=None, help="Optional output JSON path")
    ap.add_argument("--exclude-opp-crash", action="store_true", help="Exclude early opponent crash matches (<20s, 0 kills)")
    ap.add_argument(
        "--replay-db",
        default=DEFAULT_REPLAY_DB,
        help="Read-only arena_replays.sqlite path for Stall Watchdog & Base Geometry KPIs (pass '' to disable)",
    )
    ap.add_argument("--run-id", default=None, help="Optional SQLite runs.run_id override for --current")
    ap.add_argument("--baseline-run-id", default=None, help="Optional SQLite runs.run_id override for --baseline")
    args = ap.parse_args()

    with open(args.pro_baselines) as f:
        pro = json.load(f)

    cur_raw, cur_rows_all = load_score_json(args.current, args.exclude_opp_crash)
    cur_selfplay_rows = [m for m in cur_rows_all if is_selfplay_row(m)]
    cur_ext_rows = [m for m in cur_rows_all if not is_selfplay_row(m)]
    # Keep Pro-Corpus / core_12 / unseen_6 / Promotion Gates 100% pure by excluding self-play when external matches exist!
    cur_rows = cur_ext_rows if cur_ext_rows else cur_rows_all

    base_raw, base_rows_all = (None, [])
    if args.baseline:
        base_raw, base_rows_all = load_score_json(args.baseline, args.exclude_opp_crash)
    base_rows = [m for m in base_rows_all if not is_selfplay_row(m)] or base_rows_all

    hwm_raw, hwm_rows_all = (None, [])
    if args.hwm:
        hwm_raw, hwm_rows_all = load_score_json(args.hwm, args.exclude_opp_crash)
    hwm_rows = [m for m in hwm_rows_all if not is_selfplay_row(m)] or hwm_rows_all

    tactics_data = None
    if args.tactics and os.path.exists(args.tactics):
        with open(args.tactics) as f:
            tactics_data = json.load(f)

    cur_all = summarize_slice(cur_rows)
    base_all = summarize_slice(base_rows) if base_rows else None
    hwm_all = summarize_slice(hwm_rows) if hwm_rows else None

    selfplay_report = None
    if cur_selfplay_rows:
        sp_mus = sorted(set(m["matchup"] for m in cur_selfplay_rows))
        selfplay_report = {
            "summary": summarize_slice(cur_selfplay_rows),
            "by_matchup": {
                mu: summarize_slice([m for m in cur_selfplay_rows if m["matchup"] == mu])
                for mu in sp_mus
            },
            "matches": [
                {
                    "id": m["match_id"],
                    "our_bot": m["our_bot"],
                    "opp_bot": m["opp_bot"],
                    "matchup": m["matchup"],
                    "result": m["result"],
                    "trade_ratio": m["trade_ratio"],
                    "duration_sec": m["duration_sec"],
                    "our_peak_army": m["our_peak_army"],
                    "opp_peak_army": m["opp_peak_army"],
                    "supply_block_pct": m["supply_block_pct"],
                    "opp_supply_block_pct": m.get("opp_supply_block_pct"),
                    "p2_anomalies": [k for k, v in (m.get("p2_anomalies") or {}).items() if v],
                }
                for m in cur_selfplay_rows
            ],
        }

    cur_core_rows = [m for m in cur_rows if is_core_row(m)]
    cur_core_nc_rows = [m for m in cur_core_rows if m["opp_bot"] != "Chance"]
    cur_core12_rows = [m for m in cur_rows if is_core12_row(m)]
    cur_core12_nc_rows = [m for m in cur_core12_rows if m["opp_bot"] != "Chance"]
    cur_promoted_rows = [m for m in cur_core_rows if m["opp_bot"] not in CORE_12_OPPONENTS]
    cur_unseen_rows = [m for m in cur_rows if is_unseen_row(m)]
    cohorts = None
    if cur_unseen_rows or cur_promoted_rows:
        core_opps = sorted(set(m["opp_bot"] for m in cur_core_rows))
        promoted_opps = sorted(set(m["opp_bot"] for m in cur_promoted_rows))
        unseen_opps = sorted(set(m["opp_bot"] for m in cur_unseen_rows))
        core_label = f"core_{len(core_opps)}" if len(core_opps) > 12 else "core_12"
        cohorts = {
            "core_label": core_label,
            "core_opponents": core_opps,
            "core_active": summarize_slice(cur_core_rows),
            "core_active_non_chance": summarize_slice(cur_core_nc_rows),
            "core_14": summarize_slice(cur_core_rows) if cur_promoted_rows else None,
            "core_14_non_chance": summarize_slice(cur_core_nc_rows) if cur_promoted_rows else None,
            "promoted_core_opponents": promoted_opps,
            "promoted_core_by_opponent": {
                opp: summarize_slice([m for m in cur_promoted_rows if m["opp_bot"] == opp])
                for opp in promoted_opps
            },
            "core_12": summarize_slice(cur_core12_rows),
            "core_12_non_chance": summarize_slice(cur_core12_nc_rows),
            "unseen_roster": summarize_slice(cur_unseen_rows) if cur_unseen_rows else None,
            "unseen_opponents": unseen_opps,
            "unseen_by_opponent": {
                opp: summarize_slice([m for m in cur_unseen_rows if m["opp_bot"] == opp])
                for opp in unseen_opps
            },
        }

    by_race = {}
    for r in RACES:
        cr = summarize_slice([m for m in cur_rows if m["our_race"] == r])
        br = summarize_slice([m for m in base_rows if m["our_race"] == r]) if base_rows else None
        pr = pro["by_race"].get(r, {})
        gaps = compare_vs_pro(cr, pr, race=r)
        by_race[r] = {"current": cr, "baseline": br, "pro": pr, "gaps_vs_pro": gaps}

    by_matchup = {}
    for mu in MATCHUPS:
        cm = summarize_slice([m for m in cur_rows if m["matchup"] == mu])
        if cm["n"] == 0:
            continue
        bm = summarize_slice([m for m in base_rows if m["matchup"] == mu]) if base_rows else None
        pm = pro["by_matchup"].get(mu, {})
        race_for_mu = {"P": "Protoss", "T": "Terran", "Z": "Zerg"}.get(mu[0])
        gaps = compare_vs_pro(cm, pm, race=race_for_mu)
        by_matchup[mu] = {"current": cm, "baseline": bm, "pro": pm, "gaps_vs_pro": gaps}

    gates = evaluate_promotion_gates(cur_all, {r: by_race[r]["current"] for r in RACES}, tactics_data)
    gates["every_race_w4_within_6_of_pro"] = all(
        (by_race[r]["gaps_vs_pro"].get("w4_gap") is None or by_race[r]["gaps_vs_pro"]["w4_gap"] >= -6.0)
        for r in RACES
    )
    gates["ready_to_promote"] = all(gates.values())

    paired_diff = compute_paired_diff(cur_rows, base_rows)

    sqlite_meta = None
    stall_watchdog_report = None
    base_geometry_report = None
    conn = open_replay_db_ro(args.replay_db)
    if conn is not None:
        try:
            cur_run_id, cur_rids = resolve_sqlite_run_and_replay_ids(
                conn, args.current, cur_rows, run_id=args.run_id
            )
            base_run_id, base_rids = (None, [])
            if args.baseline or args.baseline_run_id:
                base_run_id, base_rids = resolve_sqlite_run_and_replay_ids(
                    conn, args.baseline, base_rows, run_id=args.baseline_run_id
                )
            sqlite_meta = {
                "db_path": os.path.abspath(os.path.expanduser(str(args.replay_db))),
                "current_run_id": cur_run_id,
                "current_matched_replays": len(cur_rids),
                "baseline_run_id": base_run_id,
                "baseline_matched_replays": len(base_rids),
            }
            sw_cur = compute_stall_watchdog_kpis(conn, cur_rids)
            sw_base = compute_stall_watchdog_kpis(conn, base_rids) if base_rids else None
            if sw_cur is not None or sw_base is not None:
                stall_watchdog_report = {
                    "run_id": cur_run_id,
                    "baseline_run_id": base_run_id,
                    "current": sw_cur,
                    "baseline": sw_base,
                    "delta": compute_stall_watchdog_delta(sw_cur, sw_base),
                    "audit_reference": STALL_WATCHDOG_AUDIT_REF,
                }
            bg_cur = compute_base_geometry_kpis(conn, cur_rids)
            bg_base = compute_base_geometry_kpis(conn, base_rids) if base_rids else None
            if bg_cur is not None or bg_base is not None:
                base_geometry_report = {
                    "run_id": cur_run_id,
                    "baseline_run_id": base_run_id,
                    "current": bg_cur,
                    "baseline": bg_base,
                    "delta": compute_base_geometry_delta(bg_cur, bg_base),
                    "pro_reference": PRO_BASE_GEOMETRY_REF,
                }
        finally:
            conn.close()

    report = {
        "current_path": os.path.abspath(args.current),
        "baseline_path": os.path.abspath(args.baseline) if args.baseline else None,
        "hwm_path": os.path.abspath(args.hwm) if args.hwm else None,
        "exclude_opp_crash": args.exclude_opp_crash,
        "overall": {"current": cur_all, "baseline": base_all, "hwm": hwm_all},
        "cohorts": cohorts,
        "selfplay": selfplay_report,
        "by_race": by_race,
        "by_matchup": by_matchup,
        "paired_diff": paired_diff,
        "tactics": tactics_data,
        "sqlite_replay_db": sqlite_meta,
        "stall_watchdog_kpis": stall_watchdog_report,
        "base_geometry_kpis": base_geometry_report,
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

    print("\n### Pro-Corpus v2 Curves: Production, ArmyVal, Scouting, Opening BO & Upgrades (`Bot / Pro`)")
    print("| Race | ProdFac 4/6/8m (Bot / Pro) | ArmyVal 4/6/8m (Bot / Pro) | Scout 1st (Unit / Seen@) | Top BO vs Pro #1 | Key Upgrades (Bot / Pro) |")
    print("|---|---|---|---|---|---|")
    for r in RACES:
        c = by_race[r]["current"]
        p = by_race[r]["pro"]
        if c["n"] == 0:
            continue
        mc = p.get("minute_curves") or {}
        m4, m6, m8 = mc.get("m4") or {}, mc.get("m6") or {}, mc.get("m8") or {}
        prod_bot = f"{fmt(c.get('prod_cnt_4m_med'),'',0)}/{fmt(c.get('prod_cnt_6m_med'),'',0)}/{fmt(c.get('prod_cnt_8m_med'),'',0)}"
        prod_pro = f"{fmt(safe_num(m4.get('prod_cnt_med')),'',0)}/{fmt(safe_num(m6.get('prod_cnt_med')),'',0)}/{fmt(safe_num(m8.get('prod_cnt_med')),'',0)}"
        if r == "Zerg":
            prod_bot += f" (Q4:{fmt(c.get('queens_4m_med'),'',0)})"
            prod_pro += f" (Q4:{fmt(safe_num(m4.get('queens_med')),'',0)})"
        av_bot = f"{fmt(c.get('army_val_4m_med'),'',0)}/{fmt(c.get('army_val_6m_med'),'',0)}/{fmt(c.get('army_val_8m_med'),'',0)}"
        av_pro = f"{fmt(safe_num(m4.get('army_val_med')),'',0)}/{fmt(safe_num(m6.get('army_val_med')),'',0)}/{fmt(safe_num(m8.get('army_val_med')),'',0)}"
        su_str = ", ".join(f"{u}:{cnt}" for u, cnt in (c.get("scout_unit_counts") or [])[:2]) or "-"
        seen_str = fmt(c.get("enemy_first_seen_sec_med"), "s", 0)
        pro_sc = (p.get("scouting") or {}).get("first_scout_top_units") or []
        pro_sc_top = pro_sc[0] if pro_sc else "-"
        bo_top = c["top_opening_sequences"][0][0] if c.get("top_opening_sequences") else "-"
        pro_bo_top = (p.get("top_opening_sequences") or ["-"])[0].split(" (")[0]
        bo_match = "MATCH" if bo_top == pro_bo_top else "DRIFT"
        up_b = c.get("upgrades_med") or {}
        up_p = p.get("tech_and_upgrade_sec_med") or {}
        if r == "Protoss":
            up_str = f"WG {fmt(up_b.get('warpgate_sec'),'s',0)}/{fmt(safe_num(up_p.get('warp_gate')),'s',0)}, +1A {fmt(up_b.get('plus1_atk_sec'),'s',0)}/{fmt(safe_num(up_p.get('plus1_atk')),'s',0)}"
        elif r == "Terran":
            up_str = f"Stim {fmt(up_b.get('stim_sec'),'s',0)}/{fmt(safe_num(up_p.get('stimpack')),'s',0)}, CS {fmt(up_b.get('combat_shield_sec'),'s',0)}/{fmt(safe_num(up_p.get('combat_shield')),'s',0)}"
        else:
            up_str = f"LingSpd {fmt(up_b.get('ling_speed_sec'),'s',0)}/{fmt(safe_num(up_p.get('ling_speed')),'s',0)}, +1A {fmt(up_b.get('plus1_atk_sec'),'s',0)}/{fmt(safe_num(up_p.get('plus1_atk')),'s',0)}"
        print(
            f"| **{r}** | {prod_bot} / {prod_pro} | {av_bot} / {av_pro} "
            f"| {su_str} ({seen_str}) vs {pro_sc_top} | `{bo_top}` ({bo_match}) | {up_str} |"
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

    if paired_diff:
        flips = [p for p in paired_diff if p["flipped"]]
        if flips:
            print("\n### Paired `(our_bot, opp_bot)` Result Flips vs Baseline")
            print("| Match | MU | Result | Trade | PkArmy (Ours/Opp) | SupBlk% | Anomalies |")
            print("|---|---|---|---:|---:|---:|---|")
            for p in flips:
                print(
                    f"| `{p['our_bot']}` vs `{p['opp_bot']}` | {p['matchup']} "
                    f"| {p['base_result'][0].upper()}->{p['cur_result'][0].upper()} "
                    f"| {fmt(p['base_trade'],'x',2)}->{fmt(p['cur_trade'],'x',2)} "
                    f"| {fmt(p['base_pk_army'],'',0)}->{fmt(p['cur_pk_army'],'',0)}/{fmt(p['opp_pk_army'],'',0)} "
                    f"| {fmt(p['base_sup_blk'],'%')}->{fmt(p['cur_sup_blk'],'%')} "
                    f"| {', '.join(p['cur_anomalies']) or '-'} |"
                )

    outliers = cur_all.get("step_outliers_gt_500ms") or []
    if outliers:
        print(f"\n### Latency Outliers (`step_max > 500ms`: {len(outliers)}/{cur_all['n']})")
        for o in outliers:
            print(f"- `#{o['match_id']}` `{o['our_bot']}` vs `{o['opp_bot']}`: **`{o['step_max']}ms`**")

    if cur_all.get("endgame_home_stall_max_sec") is not None or cur_all.get("total_own_base_retreat_frames") is not None:
        extra_w8 = ""
        if cur_all.get("total_non_combat_robo_waste_val") is not None or cur_all.get("avg_zerg_non_ling_army_pct") is not None:
            extra_w8 = (
                f" | `P RoboWaste` = **{cur_all.get('total_non_combat_robo_waste_val', 0):,}**"
                f" | `Z NonLing6-10m` = **{fmt(cur_all.get('avg_zerg_non_ling_army_pct'),'%')}**"
                f" | `Siege0DPS` = **{cur_all.get('siege_range_zero_dps_losses', 0)}**"
                f" | `CloakLoss` = **{cur_all.get('cloaked_unit_damage_losses', 0)}**"
            )
            if (
                cur_all.get("army_val_4m_ratio_vs_pro_med") is not None
                or cur_all.get("army_val_8m_ratio_vs_pro_med") is not None
                or cur_all.get("total_gas_rich_min_starved_ticks") is not None
            ):
                extra_w8 += (
                    f" | `A4/A8Pro` = **{fmt(cur_all.get('army_val_4m_ratio_vs_pro_med'),'',2)}/{fmt(cur_all.get('army_val_8m_ratio_vs_pro_med'),'',2)}**"
                    f" | `GasRichMinStarve` = **{cur_all.get('gas_rich_min_starved_matches', 0)}/{cur_all['n']} ({(cur_all.get('total_gas_rich_min_starved_ticks') or 0):,}t)**"
                )
            if cur_all.get("total_own_territory_retreat_frames") is not None or cur_all.get("early_rush_idle_bank_3m_losses", 0) > 0:
                extra_w8 += (
                    f" | `RushIdle3m` = **{cur_all.get('early_rush_idle_bank_3m_losses', 0)}**"
                    f" | `OwnTerrRet(<=38t)` = **{cur_all.get('own_territory_retreat_matches', 0)}/{cur_all['n']} ({(cur_all.get('total_own_territory_retreat_frames') or 0):,}f)**"
                )
            if cur_all.get("total_prod_placement_stall_ticks") is not None or cur_all.get("pvp_nat_delay_matches", 0) > 0:
                extra_w8 += (
                    f" | `ProdPlaceStall` = **{cur_all.get('prod_placement_stall_matches', 0)}/{cur_all['n']} ({(cur_all.get('total_prod_placement_stall_ticks') or 0):,}t)**"
                    f" | `PvPNatDelay` = **{cur_all.get('pvp_nat_delay_matches', 0)}**"
                )
            if cur_all.get("t3_started_matches") is not None:
                extra_w8 += (
                    f" | `T3` = **{cur_all.get('t3_started_matches', 0)}/{cur_all['n']}** "
                    f"(med `{fmt(cur_all.get('t3_first_sec_med'),'s',0)}`, 2b=`{cur_all.get('t3_early_2base_matches', 0)}`, premStarve=`{cur_all.get('t3_premature_starve_matches', 0)}`)"
                )
            if cur_all.get("map_symmetry_counts"):
                sym_str = ", ".join(f"{k}:{v}" for k, v in sorted(cur_all["map_symmetry_counts"].items()))
                extra_w8 += f" | `MapSym` = `{sym_str}`"
            if cur_all.get("prod_idle_bank_freeze_matches", 0) > 0 or cur_all.get("t3_started_matches") is not None:
                extra_w8 += f" | `IdleBankFreeze` = **{cur_all.get('prod_idle_bank_freeze_matches', 0)}**"
            if cur_all.get("gas_zero_harvest_freeze_matches", 0) > 0 or cur_all.get("tr_p95_worst_ms") is not None:
                extra_w8 += (
                    f" | `GasZeroFreeze` = **{cur_all.get('gas_zero_harvest_freeze_matches', 0)}**"
                    f" | `WorstTrP95` = **{fmt(cur_all.get('tr_p95_worst_ms'),'ms')}**"
                )
            if cur_all.get("wall_timeout_ties", 0) > 0 or cur_all.get("wall_timeout_winning_ties", 0) > 0:
                extra_w8 += (
                    f" | `WallTies` = **{cur_all.get('wall_timeout_ties', 0)}** "
                    f"(Win=`{cur_all.get('wall_timeout_winning_ties', 0)}`)"
                )
            if cur_all.get("one_base_lockout_matches", 0) > 0 or cur_all.get("spire_sched_drop_matches", 0) > 0 or cur_all.get("drip_feed_collapse_matches", 0) > 0 or cur_all.get("zero_kill_collapse_matches", 0) > 0 or cur_all.get("early_opening_order_fault_matches", 0) > 0 or cur_all.get("terran_111_opening_stall_matches", 0) > 0 or cur_all.get("tr_p95_worst_ms") is not None:
                extra_w8 += (
                    f" | `1BaseLock` = **{cur_all.get('one_base_lockout_matches', 0)}**"
                    f" | `SpireDrop` = **{cur_all.get('spire_sched_drop_matches', 0)}**"
                    f" | `DripFeed` = **{cur_all.get('drip_feed_collapse_matches', 0)}**"
                    f" | `ZeroKillCol` = **{cur_all.get('zero_kill_collapse_matches', 0)}**"
                    f" | `OpenFault` = **{cur_all.get('early_opening_order_fault_matches', 0)}**"
                    f" | `T111Stall` = **{cur_all.get('terran_111_opening_stall_matches', 0)}**"
                )
            if cur_all.get("worker_econ_eff_4m_6m_avg") is not None or cur_all.get("econ_eff_collapse_matches", 0) > 0:
                extra_w8 += (
                    f" | `Eff4-6` = **{fmt(cur_all.get('worker_econ_eff_4m_6m_avg'),'/w')}/{fmt(cur_all.get('opp_worker_econ_eff_4m_6m_avg'),'/w')}**"
                    f" | `EconEffCol` = **{cur_all.get('econ_eff_collapse_matches', 0)}**"
                )
            if cur_all.get("early_atk_pct_2m_6m_avg") is not None:
                extra_w8 += (
                    f" | `Atk2-6` = **{fmt(cur_all.get('early_atk_pct_2m_6m_avg'),'%')}**"
                    f" | `P:WG` = **{fmt(cur_all.get('protoss_warpgate_sec_med'),'s',0)}**"
                    f" | `Z:RW` = **{fmt(cur_all.get('zerg_roach_warren_sec_med'),'s',0)}**"
                )
            if cur_all.get("combat_death_home_pct_avg") is not None or cur_all.get("late_game_stalemate_tie_matches", 0) > 0:
                extra_w8 += (
                    f" | `Dth(H/E)` = **{fmt(cur_all.get('combat_death_home_pct_avg'),'%',0)}/{fmt(cur_all.get('combat_death_enemy_pct_avg'),'%',0)}**"
                    f" | `StaleTie` = **{cur_all.get('late_game_stalemate_tie_matches', 0)}**"
                )
        print(
            f"\n### Stall, Retreat & Waste Watch (`W7/W8-LOOP-2`): "
            f"`endgame_home_stall >= 90s` = **{cur_all.get('endgame_home_stall_count', 0)}/{cur_all['n']}** "
            f"(max `{fmt(cur_all.get('endgame_home_stall_max_sec'),'s')}`) | "
            f"`own_base_retreat >= 440f` = **{cur_all.get('own_base_retreat_matches', 0)}/{cur_all['n']}** "
            f"(total `{cur_all.get('total_own_base_retreat_frames', 0):,}f`){extra_w8}"
        )

    if stall_watchdog_report and stall_watchdog_report.get("current"):
        swc = stall_watchdog_report["current"]
        swb = stall_watchdog_report.get("baseline")
        swd = stall_watchdog_report.get("delta") or {}
        swref = stall_watchdog_report.get("audit_reference") or STALL_WATCHDOG_AUDIT_REF
        rid_lbl = stall_watchdog_report.get("run_id") or "matched"
        base_lbl = stall_watchdog_report.get("baseline_run_id") or "-"
        swb_sup = f"{fmt(swb['sup_cap_min_pct'],'%')} ({swb['sup_cap_matches']}/{swb['n']})" if swb else "-"
        swb_inc = f"{swb['zero_income_matches']} ({fmt(swb['zero_income_pct'],'%')})" if swb else "-"
        swb_gas = f"{swb['zero_gas_matches']} ({fmt(swb['zero_gas_pct'],'%')})" if swb else "-"
        swb_wk8 = f"{fmt(swb['wk_plateau_8m_pct'],'%')} ({swb['wk_plateau_8m_matches']}/{swb['wk_plateau_8m_denom']})" if swb else "-"
        swb_grm = f"{swb['gas_rich_min_starved_matches']} ({fmt(swb['gas_rich_min_starved_pct'],'%')})" if swb else "-"
        swd_inc = (
            f"{fmt_delta(swd.get('zero_income_matches'),'',0)} ({fmt_delta(swd.get('zero_income_pct'),'%')})"
            if swb
            else "-"
        )
        swd_gas = (
            f"{fmt_delta(swd.get('zero_gas_matches'),'',0)} ({fmt_delta(swd.get('zero_gas_pct'),'%')})"
            if swb
            else "-"
        )
        print(
            f"\n### Stall Watchdog KPIs (SQLite 4-Law Audit, `run={rid_lbl}`, `n={swc['n']}`"
            + (f" vs `base={base_lbl}`, `n={swb['n']}`" if swb else "")
            + ")"
        )
        print("| KPI | Current | Baseline | Delta | 519-Match Audit Ref | Goal |")
        print("|---|---:|---:|---:|---:|---|")
        print(
            f"| **`sup_cap_min_pct`** (capped `<195` at min mark) "
            f"| **{fmt(swc['sup_cap_min_pct'],'%')}** ({swc['sup_cap_matches']}/{swc['n']}) "
            f"| {swb_sup} | {fmt_delta(swd.get('sup_cap_min_pct'),'%')} "
            f"| {fmt(swref.get('sup_cap_min_pct'),'%')} | Lower ↓ |"
        )
        print(
            f"| **`zero_income_matches`** (`>=5` wk, `>=2m`, `0` min/s) "
            f"| **{swc['zero_income_matches']}** ({fmt(swc['zero_income_pct'],'%')}) "
            f"| {swb_inc} | {swd_inc} "
            f"| {fmt(swref.get('zero_income_pct'),'%')} | 0 ↓ |"
        )
        print(
            f"| **`zero_gas_matches`** (`>=16` wk, `>=5m`, `0` gas/s, `<450g`) "
            f"| **{swc['zero_gas_matches']}** ({fmt(swc['zero_gas_pct'],'%')}) "
            f"| {swb_gas} | {swd_gas} "
            f"| {fmt(swref.get('zero_gas_pct'),'%')} | 0 ↓ |"
        )
        print(
            f"| **`wk_plateau_8m_pct`** (`<=36` wk @8m) "
            f"| **{fmt(swc['wk_plateau_8m_pct'],'%')}** ({swc['wk_plateau_8m_matches']}/{swc['wk_plateau_8m_denom']}) "
            f"| {swb_wk8} | {fmt_delta(swd.get('wk_plateau_8m_pct'),'%')} "
            f"| {fmt(swref.get('wk_plateau_8m_pct'),'%')} | Lower ↓ |"
        )
        print(
            f"| `gas_rich_min_starved_matches` (`>=450g`, `<200m`, `<175s`) "
            f"| {swc['gas_rich_min_starved_matches']} ({fmt(swc['gas_rich_min_starved_pct'],'%')}) "
            f"| {swb_grm} | {fmt_delta(swd.get('gas_rich_min_starved_matches'),'',0)} "
            f"| {fmt(swref.get('gas_rich_min_starved_pct'),'%')} | 0 ↓ |"
        )
        if swc.get("by_race"):
            race_bits = []
            for r in RACES:
                sr = swc["by_race"].get(r)
                if sr:
                    race_bits.append(
                        f"**{r[0]}**(`n={sr['n']}`): SupCap `{fmt(sr['sup_cap_min_pct'],'%')}`, "
                        f"ZeroInc `{sr['zero_income_matches']}`, ZeroGas `{sr['zero_gas_matches']}`, "
                        f"WkPlat8m `{fmt(sr['wk_plateau_8m_pct'],'%')}`"
                    )
            if race_bits:
                print("- **By Race:** " + " | ".join(race_bits))

    if base_geometry_report and base_geometry_report.get("current"):
        bgc = base_geometry_report["current"]
        bgb = base_geometry_report.get("baseline")
        bgd = base_geometry_report.get("delta") or {}
        bgp = base_geometry_report.get("pro_reference") or PRO_BASE_GEOMETRY_REF
        rid_lbl = base_geometry_report.get("run_id") or "matched"
        base_lbl = base_geometry_report.get("baseline_run_id") or "-"
        bgb_clump = f"{fmt(bgb.get('pylon_clump_pct'),'%')} (NN `{fmt(bgb.get('pylon_spacing_nn'),'t')}`)" if bgb else "-"
        bgb_nsup = (
            f"{fmt(bgb.get('nat_supply_pct'),'%')} "
            f"(P `{fmt(bgb.get('protoss_nat_supply_pct'),'%')}` / T `{fmt(bgb.get('terran_nat_supply_pct'),'%')}`)"
            if bgb
            else "-"
        )
        bgb_zvz = f"{fmt(bgb.get('zvz_nat_wall_pct'),'%')} (`n={bgb.get('zvz_n', 0)}`)" if bgb else "-"
        bgb_bnk = f"{fmt(bgb.get('early_bunkers_4m'),'',2)} (NatDef `{fmt(bgb.get('terran_nat_def'),'',2)}`)" if bgb else "-"
        print(
            f"\n### Pro-vs-Mothman Base Geometry KPIs (4:10 / 250s, `run={rid_lbl}`, `n={bgc['n']}`"
            + (f" vs `base={base_lbl}`, `n={bgb['n']}`" if bgb else "")
            + ")"
        )
        print("| KPI | Current | Baseline | Delta | GM Pro Ref (`n=182`) | Goal |")
        print("|---|---:|---:|---:|---:|---|")
        print(
            f"| **`pylon_clump_pct`** (Protoss Pylons `<5t` NN) "
            f"| **{fmt(bgc.get('pylon_clump_pct'),'%')}** (NN `{fmt(bgc.get('pylon_spacing_nn'),'t')}`, `n={bgc.get('pylon_clump_n', 0)}`) "
            f"| {bgb_clump} | {fmt_delta(bgd.get('pylon_clump_pct'),'%')} "
            f"| {fmt(bgp.get('pylon_clump_pct'),'%')} (NN `{fmt(bgp.get('pylon_spacing_nn'),'t')}`) | Lower ↓ |"
        )
        print(
            f"| **`nat_supply_pct`** (P+T Supply `<=14t` of Nat) "
            f"| **{fmt(bgc.get('nat_supply_pct'),'%')}** (P `{fmt(bgc.get('protoss_nat_supply_pct'),'%')}` / T `{fmt(bgc.get('terran_nat_supply_pct'),'%')}`) "
            f"| {bgb_nsup} | {fmt_delta(bgd.get('nat_supply_pct'),'%')} "
            f"| {fmt(bgp.get('nat_supply_pct'),'%')} (P `{fmt(bgp.get('protoss_nat_supply_pct'),'%')}` / T `{fmt(bgp.get('terran_nat_supply_pct'),'%')}`) | Higher ↑ |"
        )
        print(
            f"| **`zvz_nat_wall_pct`** (ZvZ Nat Tight Wall `<=4.2t`) "
            f"| **{fmt(bgc.get('zvz_nat_wall_pct'),'%')}** (`n={bgc.get('zvz_n', 0)}`) "
            f"| {bgb_zvz} | {fmt_delta(bgd.get('zvz_nat_wall_pct'),'%')} "
            f"| {fmt(bgp.get('zvz_nat_wall_pct'),'%')} | Higher ↑ |"
        )
        print(
            f"| **`early_bunkers_4m`** (Terran Bunkers `<=250s`) "
            f"| **{fmt(bgc.get('early_bunkers_4m'),'',2)}** (NatDef `{fmt(bgc.get('terran_nat_def'),'',2)}`, `n={bgc.get('terran_n', 0)}`) "
            f"| {bgb_bnk} | {fmt_delta(bgd.get('early_bunkers_4m'),'',2)} "
            f"| {fmt(bgp.get('early_bunkers_4m'),'',2)} | Lower ↓ |"
        )
        if bgc.get("by_matchup"):
            pro_mu_map = bgp.get("by_matchup") or {}
            print("\n| Matchup (`n`) | SupNN (Bot/Pro) | Clump<5t (Bot/Pro) | MainWall% | NatWall% (Bot/Pro) | NatSup% (Bot/Pro) | NatDef / Bunk4m (Bot/Pro) | ExpTech |")
            print("|---|---:|---:|---:|---:|---:|---:|---:|")
            for mu in MATCHUPS:
                mc = bgc["by_matchup"].get(mu)
                if not mc:
                    continue
                mp = pro_mu_map.get(mu) or {}
                sup_nn_s = f"{fmt(mc.get('sup_nn'),'t')}/{fmt(mp.get('sup_nn'),'t')}" if mu[0] in ("P", "T") else "-"
                clump_s = f"{fmt(mc.get('sup_clump_pct'),'%')}/{fmt(mp.get('sup_clump_pct'),'%')}" if mu[0] in ("P", "T") else "-"
                natsup_s = f"{fmt(mc.get('nat_sup_pct'),'%')}/{fmt(mp.get('nat_sup_pct'),'%')}" if mu[0] in ("P", "T") else "-"
                def_s = (
                    f"{fmt(mc.get('nat_def'),'',2)} (B:{fmt(mc.get('early_bunkers_4m'),'',2)}) / {fmt(mp.get('nat_def'),'',2)}"
                    if mu[0] == "T"
                    else f"{fmt(mc.get('nat_def'),'',2)} / {fmt(mp.get('nat_def'),'',2)}"
                )
                print(
                    f"| **{mu}** (`n={mc['n']}`) | {sup_nn_s} | {clump_s} "
                    f"| {fmt(mc.get('main_wall_pct'),'%')} "
                    f"| {fmt(mc.get('nat_wall_pct'),'%')}/{fmt(mp.get('nat_wall_pct'),'%')} "
                    f"| {natsup_s} | {def_s} | {fmt(mc.get('tech_exposed'),'',2)} |"
                )

    if cohorts:
        c_act = cohorts["core_active"]
        c_act_nc = cohorts["core_active_non_chance"]
        c_lbl = cohorts.get("core_label") or "core_12"
        c12 = cohorts["core_12"]
        c12_nc = cohorts["core_12_non_chance"]
        cu = cohorts.get("unseen_roster")
        has_prom = bool(cohorts.get("promoted_core_opponents"))
        if cu and has_prom:
            hdr = f"### Full-Roster Generalization Split (`{c_lbl}` vs historical `core_12` vs `unseen_{len(cohorts['unseen_opponents'])}`)"
        elif cu:
            hdr = f"### Full-Roster Generalization Split (`{c_lbl}` vs `unseen_{len(cohorts['unseen_opponents'])}`)"
        else:
            hdr = f"### Core Cohort Continuity (`{c_lbl}` Primary vs Historical `core_12`)"
        print(f"\n{hdr}")
        if has_prom and c_act["n"] > 0:
            print(f"- **`{c_lbl}` Primary (`n={c_act['n']}`, incl. {', '.join(cohorts['promoted_core_opponents'])}):** `{c_act['wins']}W-{c_act['losses']}L-{c_act['ties']}T` (`{c_act['wr_pct']:.1f}%` WR, Trade `{fmt(c_act['trade_agg'],'x',2)}`/`{fmt(c_act['trade_med'],'x',2)}`, SupBlk `{fmt(c_act['sup_blk_avg'],'%')}`, PkArmy `{fmt(c_act['pk_army_avg'],'',0)}`, WallTies `{c_act.get('wall_timeout_ties', 0)}` Win=`{c_act.get('wall_timeout_winning_ties', 0)}`)")
            if c_act_nc["n"] > 0:
                print(f"- **`{c_lbl}` Non-Chance (`n={c_act_nc['n']}`):** `{c_act_nc['wins']}W-{c_act_nc['losses']}L-{c_act_nc['ties']}T` (`{c_act_nc['wr_pct']:.1f}%` WR, Trade `{fmt(c_act_nc['trade_agg'],'x',2)}`/`{fmt(c_act_nc['trade_med'],'x',2)}`, SupBlk `{fmt(c_act_nc['sup_blk_avg'],'%')}`, PkArmy `{fmt(c_act_nc['pk_army_avg'],'',0)}`)")
        if c12["n"] > 0:
            print(f"- **`core_12` Historical (`n={c12['n']}`):** `{c12['wins']}W-{c12['losses']}L-{c12['ties']}T` (`{c12['wr_pct']:.1f}%` WR, Trade `{fmt(c12['trade_agg'],'x',2)}`/`{fmt(c12['trade_med'],'x',2)}`, SupBlk `{fmt(c12['sup_blk_avg'],'%')}`, PkArmy `{fmt(c12['pk_army_avg'],'',0)}`, WallTies `{c12.get('wall_timeout_ties', 0)}` Win=`{c12.get('wall_timeout_winning_ties', 0)}`)")
        if c12_nc["n"] > 0:
            print(f"- **`core_12` Non-Chance (`n={c12_nc['n']}`):** `{c12_nc['wins']}W-{c12_nc['losses']}L-{c12_nc['ties']}T` (`{c12_nc['wr_pct']:.1f}%` WR, Trade `{fmt(c12_nc['trade_agg'],'x',2)}`/`{fmt(c12_nc['trade_med'],'x',2)}`, SupBlk `{fmt(c12_nc['sup_blk_avg'],'%')}`, PkArmy `{fmt(c12_nc['pk_army_avg'],'',0)}`)")
        if cohorts.get("promoted_core_by_opponent"):
            print("\n| Promoted Core Opponent | n | W-L-T | Trade Agg | PkArmy | SupBlk% | CloakLoss | Siege0DPS |")
            print("|---|---:|---|---:|---:|---:|---:|---:|")
            for opp, osum in cohorts["promoted_core_by_opponent"].items():
                print(
                    f"| `{opp}` | {osum['n']} | {osum['wins']}-{osum['losses']}-{osum['ties']} "
                    f"| {fmt(osum['trade_agg'],'x',2)} | {fmt(osum['pk_army_avg'],'',0)} "
                    f"| {fmt(osum['sup_blk_avg'],'%')} | {osum.get('cloaked_unit_damage_losses', 0)} "
                    f"| {osum.get('siege_range_zero_dps_losses', 0)} |"
                )
        if cu and cu["n"] > 0:
            print(f"\n- **`unseen_{len(cohorts['unseen_opponents'])}` (`n={cu['n']}`, {', '.join(cohorts['unseen_opponents'])}):** `{cu['wins']}W-{cu['losses']}L-{cu['ties']}T` (`{cu['wr_pct']:.1f}%` WR, Trade `{fmt(cu['trade_agg'],'x',2)}`/`{fmt(cu['trade_med'],'x',2)}`, SupBlk `{fmt(cu['sup_blk_avg'],'%')}`, PkArmy `{fmt(cu['pk_army_avg'],'',0)}`)")
            if cohorts.get("unseen_by_opponent"):
                print("\n| Unseen Opponent | n | W-L-T | Trade Agg | PkArmy | SupBlk% | CloakLoss | Siege0DPS |")
                print("|---|---:|---|---:|---:|---:|---:|---:|")
                for opp, osum in cohorts["unseen_by_opponent"].items():
                    print(
                        f"| `{opp}` | {osum['n']} | {osum['wins']}-{osum['losses']}-{osum['ties']} "
                        f"| {fmt(osum['trade_agg'],'x',2)} | {fmt(osum['pk_army_avg'],'',0)} "
                        f"| {fmt(osum['sup_blk_avg'],'%')} | {osum.get('cloaked_unit_damage_losses', 0)} "
                        f"| {osum.get('siege_range_zero_dps_losses', 0)} |"
                    )

    if selfplay_report:
        sps = selfplay_report["summary"]
        print(
            f"\n### Full-Match Self-Play Cohort (`n={sps['n']}`, isolated from Pro-Corpus & core/unseen): "
            f"P1 `{sps['wins']}W-{sps['losses']}L-{sps['ties']}T` (`{sps['wr_pct']:.1f}%`, Trade `{fmt(sps['trade_agg'],'x',2)}`, "
            f"SupBlk `{fmt(sps['sup_blk_avg'],'%')}`, PkArmy `{fmt(sps['pk_army_avg'],'',0)}`, "
            f"AvgDur `{fmt(sps.get('dur_avg_sec'),'s',0)}`)"
        )
        print("| Match | MU | P1 Result | Trade | Dur | PkArmy (P1/P2) | SB% (P1/P2) | P2 Anomalies |")
        print("|---|---|---|---:|---:|---:|---:|---|")
        for sm in selfplay_report["matches"]:
            p2_sb = fmt(sm.get("opp_supply_block_pct"), "%") if sm.get("opp_supply_block_pct") is not None else "-"
            p2_an = ", ".join(sm.get("p2_anomalies") or []) or "-"
            print(
                f"| `#{sm['id']}` `{sm['our_bot']}` vs `{sm['opp_bot']}` | **{sm['matchup']}** "
                f"| {str(sm['result']).upper()} | {fmt(sm['trade_ratio'],'x',2)} "
                f"| {fmt(sm['duration_sec'],'s',0)} | {fmt(sm['our_peak_army'],'',0)}/{fmt(sm['opp_peak_army'],'',0)} "
                f"| {fmt(sm['supply_block_pct'],'%')}/{p2_sb} | {p2_an} |"
            )

    if hwm_all:
        cmp_slice = cohorts["core_12"] if (cohorts and cohorts["core_12"]["n"] > 0 and hwm_all["n"] <= 36 and cur_all["n"] > 36) else cur_all
        cmp_lbl = "Current core_12" if cmp_slice is not cur_all else "Current"
        hwm_slice = (
            summarize_slice([m for m in hwm_rows if m["opp_bot"] in CORE_12_OPPONENTS])
            if (hwm_all["n"] > 36 and cmp_slice["n"] <= 36)
            else hwm_all
        )
        hwm_lbl = "HWM core_12" if hwm_slice is not hwm_all else "HWM"
        print(
            f"\n### High-Water Mark Check: {cmp_lbl} `{cmp_slice['wins']}W-{cmp_slice['losses']}L-{cmp_slice['ties']}T` "
            f"(`{cmp_slice['wr_pct']:.1f}%`, Trade `{fmt(cmp_slice['trade_agg'],'x',2)}`/`{fmt(cmp_slice['trade_med'],'x',2)}`, "
            f"SupBlk `{fmt(cmp_slice['sup_blk_avg'],'%')}`) vs {hwm_lbl} `{hwm_slice['wins']}W-{hwm_slice['losses']}L-{hwm_slice['ties']}T` "
            f"(`{hwm_slice['wr_pct']:.1f}%`, Trade `{fmt(hwm_slice['trade_agg'],'x',2)}`/`{fmt(hwm_slice['trade_med'],'x',2)}`, "
            f"SupBlk `{fmt(hwm_slice['sup_blk_avg'],'%')}`) -> **{'NEW HWM!' if (cmp_slice['wins'] > hwm_slice['wins'] or (cmp_slice['wins'] == hwm_slice['wins'] and (cmp_slice['losses'] < hwm_slice['losses'] or (cmp_slice['losses'] == hwm_slice['losses'] and cmp_slice['trade_agg'] >= hwm_slice['trade_agg'])))) else 'BELOW HWM (hold commit)'}**"
        )
        if cohorts and cohorts.get("core_14") and cohorts["core_14"]["n"] > 0:
            c14 = cohorts["core_14"]
            print(
                f"- **Primary `core_14` (`n={c14['n']}`):** `{c14['wins']}W-{c14['losses']}L-{c14['ties']}T` "
                f"(`{c14['wr_pct']:.1f}%`, Trade `{fmt(c14['trade_agg'],'x',2)}`/`{fmt(c14['trade_med'],'x',2)}`, "
                f"SupBlk `{fmt(c14['sup_blk_avg'],'%')}`, PkArmy `{fmt(c14['pk_army_avg'],'',0)}`)"
            )

    passed_gates = sum(1 for k, v in gates.items() if k != "ready_to_promote" and v)
    total_gates = sum(1 for k in gates if k != "ready_to_promote")
    print(f"\n### Promotion Gates: {passed_gates}/{total_gates} PASS (ready_to_promote={gates['ready_to_promote']})")
    for k, v in gates.items():
        if k != "ready_to_promote":
            print(f"- `[{'PASS' if v else 'FAIL'}]` `{k}`")


if __name__ == "__main__":
    main()
