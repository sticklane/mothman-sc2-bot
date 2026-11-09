#!/usr/bin/env python3
"""
sim/scbot_telemetry.py

Generalized, Schema-Versioned Telemetry & Opponent-Profile Architecture (Schema 2.0)
for #lang sc-bot (Mothman).

Decouples structured telemetry logging, periodic snapshot introspection,
Guns-vs-Butter economic regime tracking, production utilization diagnostics,
and AI Arena Tag/JSONL persistence from the tactical/macro actuator bridge.
"""

import json
from pathlib import Path
from typing import Any, Dict, List, Optional

SCHEMA_VERSION = "2.0"


def _safe_int(val: Any, default: int = 0) -> int:
    try:
        return int(val)
    except Exception:
        return default


def _safe_float(val: Any, default: float = 0.0) -> float:
    try:
        return float(val)
    except Exception:
        return default


def _safe_len(val: Any) -> int:
    try:
        return len(val)
    except Exception:
        return 0


class TelemetryRecorder:
    """
    Centralized Schema-2.0 telemetry emitter and forensic diagnostics recorder
    for the SC2 actuator bridge (`sim/sc2_burny_bridge.py`).
    """

    def __init__(self, schema_version: str = SCHEMA_VERSION):
        self.schema_version = schema_version
        self.events_emitted = 0
        self.snapshots_emitted = 0

    @staticmethod
    def _extract_core_bot_fields(bot: Any) -> Dict[str, Any]:
        state = getattr(bot, "state", None)
        loop = _safe_int(getattr(state, "game_loop", 0)) if state is not None else 0
        sec = round(loop / 22.4, 1)

        race_obj = getattr(bot, "race", None)
        race_str = (
            getattr(race_obj, "name", None)
            or getattr(bot, "configured_race", None)
            or "Unknown"
        )
        posture_str = str(getattr(bot, "current_posture", "balanced-opening"))

        townhalls = getattr(bot, "townhalls", None)
        bases = _safe_len(townhalls) if townhalls is not None else _safe_int(getattr(bot, "peak_bases", 1), 1)
        eff_bases = round(_safe_float(getattr(bot, "last_eff_bases", float(bases)), float(bases)), 2)
        depleting_bases = _safe_int(getattr(bot, "last_depleting_bases", 0), 0)

        workers_obj = getattr(bot, "workers", None)
        workers = _safe_len(workers_obj) if workers_obj is not None else 0
        target_workers = _safe_int(getattr(bot, "last_target_workers", max(16, bases * 18)), max(16, bases * 18))

        supply_used = _safe_int(getattr(bot, "supply_used", 0), 0)
        supply_cap = _safe_int(getattr(bot, "supply_cap", 0), 0)
        army_sup = _safe_int(getattr(bot, "supply_army", 0), 0)
        minerals = _safe_int(getattr(bot, "minerals", 0), 0)
        gas = _safe_int(getattr(bot, "vespene", 0), 0)

        return {
            "schema_version": SCHEMA_VERSION,
            "loop": loop,
            "sec": sec,
            "race": str(race_str),
            "posture": posture_str,
            "bases": bases,
            "eff_bases": eff_bases,
            "depleting_bases": depleting_bases,
            "workers": workers,
            "target_workers": target_workers,
            "supply_used": supply_used,
            "supply_cap": supply_cap,
            "army_sup": army_sup,
            "minerals": minerals,
            "gas": gas,
        }

    @staticmethod
    def compute_production_utilization(bot: Any, loop: int) -> Dict[str, Any]:
        active_loops = max(1, loop - 112)
        idle_w = _safe_int(getattr(bot, "idle_worker_production_loops", 0), 0)
        idle_u = _safe_int(getattr(bot, "idle_unit_production_loops", 0), 0)
        sup_blocked = _safe_int(getattr(bot, "supply_blocked_loops", 0), 0)

        w_util = round(100.0 * max(0.0, min(1.0, 1.0 - (float(idle_w) / float(active_loops)))), 1)
        u_util = round(100.0 * max(0.0, min(1.0, 1.0 - (float(idle_u) / float(active_loops)))), 1)
        return {
            "idle_worker_prod_loops": idle_w,
            "idle_unit_prod_loops": idle_u,
            "worker_prod_utilization_pct": w_util,
            "unit_prod_utilization_pct": u_util,
            "supply_blocked_loops": sup_blocked,
        }

    @staticmethod
    def extract_upgrades_and_tech(bot: Any) -> Dict[str, Any]:
        state = getattr(bot, "state", None)
        completed: List[str] = []
        if state is not None and hasattr(state, "upgrades"):
            try:
                completed = sorted(getattr(u, "name", str(u)) for u in state.upgrades)
            except Exception:
                completed = []

        pending: List[str] = []
        if hasattr(bot, "_get_pending_upgrade_names"):
            try:
                pending = list(bot._get_pending_upgrade_names())
            except Exception:
                pending = []

        active_goal = str(getattr(bot, "active_build_goal", "macro-scaling"))
        return {
            "completed_upgrades": completed,
            "pending_upgrades": pending,
            "active_build_goal": active_goal,
        }

    @staticmethod
    def extract_enemy_tech_and_upgrades(bot: Any) -> Dict[str, Any]:
        obs_upgs = sorted(str(x) for x in (getattr(bot, "_observed_enemy_upgrades", set()) or set()))
        obs_spells = sorted(str(x) for x in (getattr(bot, "_observed_enemy_spells", set()) or set()))
        imp_tech = sorted(str(x) for x in (getattr(bot, "_implied_enemy_tech_buildings", set()) or set()))
        act_imp_tech = sorted(str(x) for x in (getattr(bot, "_active_implied_enemy_tech_buildings", set()) or set()))
        crippled_tech = sorted(str(x) for x in (getattr(bot, "_crippled_enemy_tech_buildings", set()) or set()))
        active_res = sorted(str(x) for x in (getattr(bot, "_active_enemy_research_buildings", set()) or set()))
        inferred_res = sorted(str(x) for x in (getattr(bot, "_inferred_enemy_active_research", set()) or set()))
        in_prog_bldgs = sorted(str(x) for x in (getattr(bot, "_in_progress_enemy_buildings", set()) or set()))
        sg_previews = sorted(str(x) for x in (getattr(bot, "_stargate_preview_units", set()) or set()))
        excluded_branches = sorted(str(x) for x in (getattr(bot, "_enemy_excluded_branches", set()) or set()))
        halluc_tags = getattr(bot, "_confirmed_hallucination_tags", set()) or set()
        return {
            "observed_enemy_upgrades": obs_upgs,
            "observed_enemy_spells": obs_spells,
            "implied_enemy_tech_buildings": imp_tech,
            "active_implied_enemy_tech_buildings": act_imp_tech,
            "crippled_enemy_tech_buildings": crippled_tech,
            "active_enemy_research_buildings": active_res,
            "inferred_enemy_active_research": inferred_res,
            "in_progress_enemy_buildings": in_prog_bldgs,
            "stargate_preview_units": sg_previews,
            "confirmed_enemy_hallucinations": _safe_len(halluc_tags),
            "max_enemy_atk_upg": _safe_int(getattr(bot, "_max_enemy_atk_upg", 0), 0),
            "max_enemy_arm_upg": _safe_int(getattr(bot, "_max_enemy_arm_upg", 0), 0),
            "max_enemy_shd_upg": _safe_int(getattr(bot, "_max_enemy_shd_upg", 0), 0),
            "enemy_requires_detection": bool(getattr(bot, "_enemy_requires_detection", False)),
            "enemy_requires_anti_air": bool(getattr(bot, "_enemy_requires_anti_air", False)),
            "enemy_committed_branch": str(getattr(bot, "_enemy_committed_branch", "unknown")),
            "enemy_excluded_branches": excluded_branches,
            "enemy_bluff_suspected": bool(getattr(bot, "_enemy_bluff_suspected", False)),
            "estimated_enemy_gas_mined": _safe_int(getattr(bot, "_estimated_enemy_gas_mined", 0), 0),
            "accounted_enemy_gas_spent": _safe_int(getattr(bot, "_accounted_enemy_gas_spent", 0), 0),
            "estimated_enemy_workers": _safe_int(getattr(bot, "_estimated_enemy_workers", 16), 16),
            "estimated_enemy_min_rate": _safe_int(getattr(bot, "_estimated_enemy_min_rate", 640), 640),
            "estimated_enemy_gas_rate": _safe_int(getattr(bot, "_estimated_enemy_gas_rate", 0), 0),
            "our_lost_minerals": _safe_int(getattr(bot, "_our_lost_minerals", 0), 0),
            "our_lost_gas": _safe_int(getattr(bot, "_our_lost_gas", 0), 0),
            "enemy_lost_minerals": _safe_int(getattr(bot, "_enemy_lost_minerals", 0), 0),
            "enemy_lost_gas": _safe_int(getattr(bot, "_enemy_lost_gas", 0), 0),
            "our_workers_lost": _safe_int(getattr(bot, "_our_workers_lost", 0), 0),
            "enemy_workers_killed": _safe_int(getattr(bot, "_enemy_workers_killed", 0), 0),
            "seen_enemy_army_supply": round(_safe_float(getattr(bot, "_seen_enemy_army_supply", 0.0), 0.0), 1),
            "unaccounted_enemy_army_supply": round(_safe_float(getattr(bot, "_unaccounted_enemy_army_supply", 0.0), 0.0), 1),
            "enemy_eta_to_our_natural_sec": round(_safe_float(getattr(bot, "_enemy_eta_to_our_natural_sec", 99.0), 99.0), 1),
            "spatial_maneuver": str(getattr(bot, "_spatial_maneuver", "standard_posture")),
        }

    @staticmethod
    def extract_human_apm_metrics(bot: Any, sec: float) -> Dict[str, Any]:
        minutes = max(0.25, sec / 60.0)
        saccades = _safe_int(getattr(bot, "camera_saccades_emitted", 0), 0)
        batched_cmds = _safe_int(getattr(bot, "batched_group_commands_issued", 0), 0)
        indiv_cmds = _safe_int(getattr(bot, "commands_issued", 0), 0)
        skipped_redundant = _safe_int(getattr(bot, "redundant_orders_skipped", 0), 0)
        effective_actions = indiv_cmds + batched_cmds + saccades
        est_epm = round(effective_actions / minutes, 1)
        est_apm = round((effective_actions * 1.02) / minutes, 1)
        est_spm = round(saccades / minutes, 1)
        return {
            "estimated_apm": est_apm,
            "estimated_epm": est_epm,
            "estimated_spm": est_spm,
            "camera_saccades": saccades,
            "batched_group_commands": batched_cmds,
            "redundant_orders_skipped": skipped_redundant,
        }

    @staticmethod
    def extract_guns_vs_butter(bot: Any, core: Dict[str, Any]) -> Dict[str, Any]:
        gas_w = _safe_int(getattr(bot, "gas_workers", 0), 0)
        min_w = _safe_int(getattr(bot, "mineral_workers", max(0, core["workers"] - gas_w)), 0)
        ratio = round(_safe_float(getattr(bot, "gas_to_mineral_ratio", gas_w / float(max(1, min_w)))), 2)
        regime = str(getattr(bot, "guns_vs_butter_regime", "guns_army_surge"))
        res_ratio = round(_safe_float(getattr(bot, "target_resource_ratio", 1.5), 1.5), 2)
        escrow_min = _safe_int(getattr(bot, "last_escrow_minerals", 0), 0)
        return {
            "gas_workers": gas_w,
            "mineral_workers": min_w,
            "gas_to_mineral_ratio": ratio,
            "guns_vs_butter_regime": regime,
            "target_resource_ratio": res_ratio,
            "escrow_minerals": escrow_min,
        }

    @staticmethod
    def extract_mirror_and_disruption(bot: Any) -> Dict[str, Any]:
        mirror_depth = _safe_int(getattr(bot, "mirror_active_depth", 2), 2)
        opp_depth = _safe_int(getattr(bot, "mirror_inferred_opponent_depth", 1), 1)
        pred_bases = _safe_int(getattr(bot, "predicted_enemy_bases", 1), 1)
        pred_workers = _safe_int(getattr(bot, "predicted_enemy_workers", 16), 16)
        known_enemy_bases = _safe_int(getattr(bot, "enemy_known_bases", 1), 1)
        verdict = str(getattr(bot, "mirror_macro_verdict", "macro_parity_pressure"))

        blockers_dict = getattr(bot, "_expansion_blocker_targets", {}) or {}
        raiders_set = getattr(bot, "_harass_raider_tags", set()) or set()
        raw_acc_map = getattr(bot, "_depth_ema_accuracy", {0: 60.0, 1: 65.0, 2: 67.0, 3: 63.0, 4: 60.0, 5: 58.0}) or {}
        depth_acc_map = {str(k): round(_safe_float(v, 60.0), 1) for k, v in raw_acc_map.items()}
        return {
            "mirror_depth": mirror_depth,
            "active_mirror_depth": mirror_depth,
            "opp_depth": opp_depth,
            "depth": mirror_depth,
            "depth_accuracy_map": depth_acc_map,
            "predicted_enemy_bases": pred_bases,
            "predicted_enemy_workers": pred_workers,
            "enemy_known_bases": known_enemy_bases,
            "mirror_macro_verdict": verdict,
            "base_blockers_active": _safe_len(blockers_dict),
            "burrow_blocks_activated": _safe_int(getattr(bot, "burrow_blocks_activated", 0), 0),
            "raiders_active": _safe_len(raiders_set),
            "base_blockers_dispatched": _safe_int(getattr(bot, "base_blockers_dispatched", 0), 0),
            "raider_squads_dispatched": _safe_int(getattr(bot, "raider_squads_dispatched", 0), 0),
            "deception_spells_cast": _safe_int(getattr(bot, "deception_spells_cast", 0), 0),
            "protective_auras_cast": _safe_int(getattr(bot, "protective_auras_cast", 0), 0),
            "presplit_concave_maneuvers": _safe_int(getattr(bot, "presplit_concave_maneuvers", 0), 0),
        }

    def emit_event(self, bot: Any, event_type: str, **extra: Any) -> Dict[str, Any]:
        core = self._extract_core_bot_fields(bot)
        rec: Dict[str, Any] = {
            "schema_version": self.schema_version,
            "event": event_type,
        }
        rec.update(core)
        rec.update(extra)
        self.events_emitted += 1
        print(f"[SCBOT_TELEMETRY] {json.dumps(rec, sort_keys=False)}", flush=True)
        return rec

    def emit_periodic_snapshot(self, bot: Any) -> Dict[str, Any]:
        core = self._extract_core_bot_fields(bot)
        loop = core["loop"]
        prod_util = self.compute_production_utilization(bot, loop)
        tech_info = self.extract_upgrades_and_tech(bot)
        enemy_tech_info = self.extract_enemy_tech_and_upgrades(bot)
        apm_info = self.extract_human_apm_metrics(bot, core["sec"])
        gvb_info = self.extract_guns_vs_butter(bot, core)
        mirror_disrupt = self.extract_mirror_and_disruption(bot)

        pending_bases = _safe_int(getattr(bot, "last_pending_bases", 0), 0)
        mined_out_bases = _safe_int(getattr(bot, "last_mined_out_bases", 0), 0)
        step_List = getattr(bot, "_step_durations_ms", []) or []
        avg_ms = (
            round(sum(step_List[-64:]) / len(step_List[-64:]), 2)
            if step_List
            else 0.0
        )
        deployed_cnt = _safe_len(getattr(bot, "_deployed_unit_tags", ()))

        payload: Dict[str, Any] = {
            "pending_bases": pending_bases,
            "mined_out_bases": mined_out_bases,
            "supply": f"{core['supply_used']}/{core['supply_cap']}",
            **gvb_info,
            **prod_util,
            **tech_info,
            **enemy_tech_info,
            **apm_info,
            **mirror_disrupt,
            "deployed": deployed_cnt,
            "step_ms_avg": avg_ms,
        }
        self.snapshots_emitted += 1
        return self.emit_event(bot, "MINUTE_SNAPSHOT", **payload)

    def diagnose_bottlenecks(self, bot: Any) -> List[str]:
        bottlenecks: List[str] = []
        core = self._extract_core_bot_fields(bot)
        max_sec = core["sec"]
        peak_bases = _safe_int(getattr(bot, "peak_bases", core["bases"]), core["bases"])
        peak_workers = _safe_int(getattr(bot, "peak_workers", core["workers"]), core["workers"])
        peak_army = _safe_int(getattr(bot, "peak_army_supply", core["army_sup"]), core["army_sup"])
        max_gas = _safe_int(getattr(bot, "max_gas_banked", core["gas"]), core["gas"])
        max_min = _safe_int(getattr(bot, "max_minerals_banked", core["minerals"]), core["minerals"])
        sup_blocked = _safe_int(getattr(bot, "supply_blocked_loops", 0), 0)

        prod_util = self.compute_production_utilization(bot, core["loop"])
        tech_info = self.extract_upgrades_and_tech(bot)

        if max_sec >= 240 and peak_bases < 2:
            bottlenecks.append("one_base_starvation")
        elif max_sec >= 420 and peak_bases < 3:
            bottlenecks.append("low_bases")
        if max_sec >= 300 and peak_workers < 38:
            bottlenecks.append("worker_starvation")
        if max_gas >= 400:
            bottlenecks.append("gas_float")
        if max_min >= 900:
            bottlenecks.append("mineral_float")
        if sup_blocked >= 350:
            bottlenecks.append("supply_blocked")
        if (
            max_sec >= 180
            and prod_util["worker_prod_utilization_pct"] < 55.0
            and peak_workers < core["target_workers"]
        ):
            bottlenecks.append("idle_worker_production")
        if (
            max_sec >= 240
            and prod_util["unit_prod_utilization_pct"] < 50.0
            and peak_army < 30
        ):
            bottlenecks.append("idle_unit_production")
        if (
            max_sec >= 300
            and not tech_info["completed_upgrades"]
            and not tech_info["pending_upgrades"]
        ):
            bottlenecks.append("zero_upgrades")
        if not bottlenecks:
            bottlenecks.append("healthy_macro")
        return bottlenecks

    def load_opponent_profile(self, bot: Any, data_dir: Path) -> Optional[Dict[str, Any]]:
        opp_id = str(getattr(bot, "opponent_id", None) or "local_opponent")
        data_dir.mkdir(parents=True, exist_ok=True)
        p = data_dir / "mirror_mind_opponents.json"
        if not p.exists():
            return None
        try:
            db = json.loads(p.read_text(encoding="utf-8"))
            rec = db.get("opponents", {}).get(opp_id)
            if not isinstance(rec, dict):
                return None
            bot.mirror_inferred_opponent_depth = _safe_int(rec.get("last_inferred_opponent_depth", 1), 1)
            bot.mirror_active_depth = _safe_int(rec.get("last_active_depth", 2), 2)
            bot.mirror_accuracy_pct = _safe_int(rec.get("last_accuracy_pct", 67), 67)
            if rec.get("saw_air_tech"):
                bot._mirror_air_alert = True
                bot._enemy_requires_anti_air = True
            if rec.get("saw_cloak_or_burrow"):
                bot._enemy_requires_detection = True
            if rec.get("saw_early_rush"):
                bot.mirror_strategic_hypothesis = "opponent-committed-early-all-in"
                bot.mirror_tactical_target = "natural-choke-defense"
            elif rec.get("saw_greedy_macro"):
                bot.mirror_strategic_hypothesis = "opponent-greedy-fast-expand"
                bot.mirror_tactical_target = "enemy-third-expansion-denial"
            games = _safe_int(rec.get("games_played", 0), 0)
            print(f"Tag: prior_games_{games}", flush=True)
            return rec
        except Exception:
            return None

    def finalize_match_summary(self, bot: Any, game_result: Any, data_dir: Path) -> Dict[str, Any]:
        data_dir.mkdir(parents=True, exist_ok=True)
        opp_path = data_dir / "mirror_mind_opponents.json"
        hist_path = data_dir / "match_telemetry_history.jsonl"

        opp_id = str(getattr(bot, "opponent_id", None) or "local_opponent")
        try:
            db = json.loads(opp_path.read_text(encoding="utf-8")) if opp_path.exists() else {"opponents": {}}
        except Exception:
            db = {"opponents": {}}
        if "opponents" not in db or not isinstance(db["opponents"], dict):
            db["opponents"] = {}

        rec = db["opponents"].get(opp_id, {})
        games = _safe_int(rec.get("games_played", 0), 0) + 1
        res_name = getattr(game_result, "name", str(game_result))
        wins = _safe_int(rec.get("wins", 0), 0) + (1 if "Victory" in res_name else 0)
        losses = _safe_int(rec.get("losses", 0), 0) + (1 if "Defeat" in res_name else 0)
        ties = _safe_int(rec.get("ties", 0), 0) + (1 if "Tie" in res_name else 0)

        core = self._extract_core_bot_fields(bot)
        prod_util = self.compute_production_utilization(bot, core["loop"])
        tech_info = self.extract_upgrades_and_tech(bot)
        enemy_tech_info = self.extract_enemy_tech_and_upgrades(bot)
        apm_info = self.extract_human_apm_metrics(bot, core["sec"])
        gvb_info = self.extract_guns_vs_butter(bot, core)
        mirror_disrupt = self.extract_mirror_and_disruption(bot)
        bottlenecks = self.diagnose_bottlenecks(bot)

        countermeasures = getattr(bot, "countermeasures_triggered", {}) or {}
        pro_mechanics = getattr(bot, "pro_mechanics_triggered", {}) or {}

        saw_rush = bool(rec.get("saw_early_rush", False)) or (
            getattr(bot, "mirror_strategic_hypothesis", "") == "opponent-committed-early-all-in"
            or mirror_disrupt["mirror_macro_verdict"] == "defend_one_base_all_in"
            or "pull-workers-attack" in countermeasures
            or "anti-cannon-proxy-pull" in countermeasures
            or "worker-rush-defense" in countermeasures
        )
        saw_air = (
            bool(rec.get("saw_air_tech", False))
            or bool(getattr(bot, "_mirror_air_alert", False))
            or enemy_tech_info["enemy_requires_anti_air"]
        )
        saw_cloak_or_burrow = (
            bool(rec.get("saw_cloak_or_burrow", False))
            or enemy_tech_info["enemy_requires_detection"]
        )
        observed_enemy_bases = max(
            _safe_int(getattr(bot, "peak_enemy_bases_seen", 1), 1),
            mirror_disrupt["enemy_known_bases"],
        )
        saw_greedy_macro = bool(rec.get("saw_greedy_macro", False)) or observed_enemy_bases >= 3

        prev_avg_bases = _safe_float(rec.get("avg_enemy_bases", float(observed_enemy_bases)), float(observed_enemy_bases))
        avg_enemy_bases = round(((prev_avg_bases * (games - 1)) + observed_enemy_bases) / float(games), 2)
        macro_profile = (
            "early_rush_all_in"
            if (saw_rush and observed_enemy_bases <= 1)
            else ("greedy_multi_base" if saw_greedy_macro else "standard_macro")
        )

        my_race = core["race"]
        enemy_race_obj = getattr(bot, "enemy_race", None)
        enemy_race = getattr(enemy_race_obj, "name", None) or "Unknown"

        ipc_mode = "python_fallback"
        bridge = getattr(bot, "bridge", None)
        if bridge and getattr(bridge, "cmd", None):
            ipc_mode = (
                "python_fallback"
                if "racket_sexp_fallback.py" in " ".join(bridge.cmd)
                else "racket_native"
            )

        step_sorted = sorted(getattr(bot, "_step_durations_ms", []) or [])
        p50_ms = round(step_sorted[len(step_sorted) // 2], 2) if step_sorted else 0.0
        p95_ms = round(step_sorted[int(len(step_sorted) * 0.95)], 2) if step_sorted else 0.0
        max_ms = round(step_sorted[-1], 2) if step_sorted else 0.0

        game_info = getattr(bot, "game_info", None)
        map_name = getattr(game_info, "map_name", "unknown") if game_info is not None else "unknown"

        summary_record: Dict[str, Any] = {
            "schema_version": self.schema_version,
            "opponent_id": opp_id,
            "map": map_name,
            "my_race": my_race,
            "enemy_race": enemy_race,
            "result": res_name,
            "ipc_mode": ipc_mode,
            "peak_bases": _safe_int(getattr(bot, "peak_bases", core["bases"]), core["bases"]),
            "peak_workers": _safe_int(getattr(bot, "peak_workers", core["workers"]), core["workers"]),
            "peak_army_supply": _safe_int(getattr(bot, "peak_army_supply", core["army_sup"]), core["army_sup"]),
            "expansions_started": _safe_int(getattr(bot, "expansions_started", 0), 0),
            "expansions_failed": _safe_int(getattr(bot, "expansions_failed", 0), 0),
            "depletion_expansions_started": _safe_int(getattr(bot, "depletion_expansions_started", 0), 0),
            "waves_launched": _safe_int(getattr(bot, "waves_launched", 0), 0),
            "squad_retreats": _safe_int(getattr(bot, "squad_retreats", 0), 0),
            "max_minerals_banked": _safe_int(getattr(bot, "max_minerals_banked", core["minerals"]), core["minerals"]),
            "max_gas_banked": _safe_int(getattr(bot, "max_gas_banked", core["gas"]), core["gas"]),
            **gvb_info,
            **prod_util,
            **tech_info,
            **enemy_tech_info,
            **apm_info,
            **mirror_disrupt,
            "racket_commands_executed": _safe_int(getattr(bot, "racket_commands_executed", 0), 0),
            "mirror_active_depth": mirror_disrupt["mirror_depth"],
            "mirror_inferred_opponent_depth": mirror_disrupt["opp_depth"],
            "mirror_toolbox_weight_pct": _safe_int(getattr(bot, "mirror_toolbox_weight_pct", 20), 20),
            "final_posture": core["posture"],
            "posture_transitions": list(getattr(bot, "posture_transitions", [])[-10:]),
            "pro_mechanics": dict(pro_mechanics),
            "countermeasures": dict(countermeasures),
            "bottlenecks": bottlenecks,
            "step_ms_p50": p50_ms,
            "step_ms_p95": p95_ms,
            "step_ms_max": max_ms,
        }

        db["opponents"][opp_id] = {
            "schema_version": self.schema_version,
            "games_played": games,
            "wins": wins,
            "losses": losses,
            "ties": ties,
            "last_result": res_name,
            "last_inferred_opponent_depth": mirror_disrupt["opp_depth"],
            "last_active_depth": mirror_disrupt["mirror_depth"],
            "last_accuracy_pct": _safe_int(getattr(bot, "mirror_accuracy_pct", 67), 67),
            "last_toolbox_weight_pct": _safe_int(getattr(bot, "mirror_toolbox_weight_pct", 20), 20),
            "observed_enemy_bases": observed_enemy_bases,
            "avg_enemy_bases": avg_enemy_bases,
            "macro_profile": macro_profile,
            "saw_early_rush": saw_rush,
            "saw_air_tech": saw_air,
            "saw_cloak_or_burrow": saw_cloak_or_burrow,
            "saw_greedy_macro": saw_greedy_macro,
            "observed_enemy_upgrades": enemy_tech_info["observed_enemy_upgrades"],
            "implied_enemy_tech_buildings": enemy_tech_info["implied_enemy_tech_buildings"],
            "last_mirror_macro_verdict": mirror_disrupt["mirror_macro_verdict"],
            "last_posture": core["posture"],
            "last_bottlenecks": bottlenecks,
        }

        try:
            opp_path.write_text(json.dumps(db, indent=2), encoding="utf-8")
            with open(hist_path, "a", encoding="utf-8") as hf:
                hf.write(json.dumps(summary_record) + "\n")
        except Exception:
            pass

        print(f"Tag: race_{my_race}_vs_{enemy_race}", flush=True)
        print(f"Tag: bases_{summary_record['peak_bases']}_w_{summary_record['peak_workers']}", flush=True)
        print(f"Tag: depth_{mirror_disrupt['mirror_depth']}_opp_{mirror_disrupt['opp_depth']}", flush=True)
        print(f"Tag: posture_{core['posture']}", flush=True)
        print(f"Tag: ipc_{ipc_mode}", flush=True)
        print(f"Tag: bottleneck_{bottlenecks[0]}", flush=True)

        return self.emit_event(bot, "MATCH_SUMMARY", **summary_record)
