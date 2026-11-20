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
from collections import Counter, defaultdict

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PRO_BASELINES = os.path.join(SCRIPT_DIR, "pro_baselines.json")

RACES = ("Protoss", "Terran", "Zerg")
MATCHUPS = ("PvP", "PvT", "PvZ", "TvP", "TvT", "TvZ", "ZvP", "ZvT", "ZvZ")
CORE_12_OPPONENTS = frozenset({
    "12PoolBot", "Chance", "Creepy_strategies", "RustyNikolaj", "SmoothBrain",
    "Thssprtssbt", "mini-puck", "monsterbot", "oberon", "puck",
    "sludgement2-revived", "titania",
})


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
    args = ap.parse_args()

    with open(args.pro_baselines) as f:
        pro = json.load(f)

    cur_raw, cur_rows = load_score_json(args.current, args.exclude_opp_crash)
    base_raw, base_rows = (None, [])
    if args.baseline:
        base_raw, base_rows = load_score_json(args.baseline, args.exclude_opp_crash)
    hwm_raw, hwm_rows = (None, [])
    if args.hwm:
        hwm_raw, hwm_rows = load_score_json(args.hwm, args.exclude_opp_crash)

    tactics_data = None
    if args.tactics and os.path.exists(args.tactics):
        with open(args.tactics) as f:
            tactics_data = json.load(f)

    cur_all = summarize_slice(cur_rows)
    base_all = summarize_slice(base_rows) if base_rows else None
    hwm_all = summarize_slice(hwm_rows) if hwm_rows else None

    cur_core_rows = [m for m in cur_rows if m["opp_bot"] in CORE_12_OPPONENTS]
    cur_core_nc_rows = [m for m in cur_core_rows if m["opp_bot"] != "Chance"]
    cur_unseen_rows = [m for m in cur_rows if m["opp_bot"] not in CORE_12_OPPONENTS]
    cohorts = None
    if cur_unseen_rows:
        unseen_opps = sorted(set(m["opp_bot"] for m in cur_unseen_rows))
        cohorts = {
            "core_12": summarize_slice(cur_core_rows),
            "core_12_non_chance": summarize_slice(cur_core_nc_rows),
            "unseen_roster": summarize_slice(cur_unseen_rows),
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

    report = {
        "current_path": os.path.abspath(args.current),
        "baseline_path": os.path.abspath(args.baseline) if args.baseline else None,
        "hwm_path": os.path.abspath(args.hwm) if args.hwm else None,
        "exclude_opp_crash": args.exclude_opp_crash,
        "overall": {"current": cur_all, "baseline": base_all, "hwm": hwm_all},
        "cohorts": cohorts,
        "by_race": by_race,
        "by_matchup": by_matchup,
        "paired_diff": paired_diff,
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

    if cohorts:
        c12 = cohorts["core_12"]
        c12_nc = cohorts["core_12_non_chance"]
        cu = cohorts["unseen_roster"]
        print("\n### Full-Roster Generalization Split (`core_12` vs `unseen_roster`)")
        print(f"- **`core_12` (`n={c12['n']}`):** `{c12['wins']}W-{c12['losses']}L-{c12['ties']}T` (`{c12['wr_pct']:.1f}%` WR, Trade `{fmt(c12['trade_agg'],'x',2)}`/`{fmt(c12['trade_med'],'x',2)}`, SupBlk `{fmt(c12['sup_blk_avg'],'%')}`, PkArmy `{fmt(c12['pk_army_avg'],'',0)}`, WallTies `{c12.get('wall_timeout_ties', 0)}` Win=`{c12.get('wall_timeout_winning_ties', 0)}`)")
        print(f"- **`core_12 Non-Chance` (`n={c12_nc['n']}`):** `{c12_nc['wins']}W-{c12_nc['losses']}L-{c12_nc['ties']}T` (`{c12_nc['wr_pct']:.1f}%` WR, Trade `{fmt(c12_nc['trade_agg'],'x',2)}`/`{fmt(c12_nc['trade_med'],'x',2)}`, SupBlk `{fmt(c12_nc['sup_blk_avg'],'%')}`, PkArmy `{fmt(c12_nc['pk_army_avg'],'',0)}`)")
        print(f"- **`unseen_roster` (`n={cu['n']}`, {', '.join(cohorts['unseen_opponents'])}):** `{cu['wins']}W-{cu['losses']}L-{cu['ties']}T` (`{cu['wr_pct']:.1f}%` WR, Trade `{fmt(cu['trade_agg'],'x',2)}`/`{fmt(cu['trade_med'],'x',2)}`, SupBlk `{fmt(cu['sup_blk_avg'],'%')}`, PkArmy `{fmt(cu['pk_army_avg'],'',0)}`)")
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

    if hwm_all:
        cmp_slice = cohorts["core_12"] if (cohorts and hwm_all["n"] <= 36 and cur_all["n"] > 36) else cur_all
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

    passed_gates = sum(1 for k, v in gates.items() if k != "ready_to_promote" and v)
    total_gates = sum(1 for k in gates if k != "ready_to_promote")
    print(f"\n### Promotion Gates: {passed_gates}/{total_gates} PASS (ready_to_promote={gates['ready_to_promote']})")
    for k, v in gates.items():
        if k != "ready_to_promote":
            print(f"- `[{'PASS' if v else 'FAIL'}]` `{k}`")


if __name__ == "__main__":
    main()
