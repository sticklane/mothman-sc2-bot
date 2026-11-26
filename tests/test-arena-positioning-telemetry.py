#!/usr/bin/env python3
"""Unit tests for Loop 76 P4 Tactics Arena positioning telemetry & scenario catalog upgrades."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import types
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ARENA_SCRIPT = REPO_ROOT / "tools" / "sc2-tactics-arena.py"
SCENARIOS_JSON = REPO_ROOT / "tools" / "arena-scenarios.json"


def _load_arena_module():
    mod_name = "_sc2_tactics_arena_test_mod"
    if mod_name in sys.modules:
        return sys.modules[mod_name]
    spec = importlib.util.spec_from_file_location(mod_name, ARENA_SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = mod
    spec.loader.exec_module(mod)
    return mod


def _mk_proto_unit(unit_type: int, x: float, y: float, weapon_cooldown: float = 0.0, order_abs: tuple[int, ...] = ()):
    return types.SimpleNamespace(
        unit_type=unit_type,
        pos=types.SimpleNamespace(x=x, y=y),
        weapon_cooldown=weapon_cooldown,
        orders=[types.SimpleNamespace(ability_id=a) for a in order_abs],
    )


class TestArenaPositioningTelemetry(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.arena = _load_arena_module()

    def test_concave_arc_width_clump_vs_wide_arc(self) -> None:
        enemy = [{"type": "stalker", "x": 95.0, "y": 80.0}]
        # Clumped single-file column along forward axis (y == 80.0 -> perpendicular spread == 0.0)
        clumped = [
            {"type": "stalker", "x": 85.0 - 0.5 * i, "y": 80.0, "weapon_cooldown": 0.4}
            for i in range(6)
        ]
        f_clump = self.arena.compute_positioning_frame_metrics(clumped, enemy)
        self.assertTrue(f_clump["valid"])
        self.assertAlmostEqual(f_clump["concave_arc_width"], 0.0, places=2)

        # Wide U-concave arc spanning y in [75.0, 85.0] -> perpendicular width == 10.0t
        wide_arc = [
            _mk_proto_unit(74, 87.0, 75.0, weapon_cooldown=0.5),
            _mk_proto_unit(74, 86.0, 77.5, weapon_cooldown=0.5),
            _mk_proto_unit(74, 85.5, 80.0, weapon_cooldown=0.5),
            _mk_proto_unit(74, 86.0, 82.5, weapon_cooldown=0.5),
            _mk_proto_unit(74, 87.0, 85.0, weapon_cooldown=0.5),
        ]
        f_arc = self.arena.compute_positioning_frame_metrics(wide_arc, enemy)
        self.assertTrue(f_arc["valid"])
        self.assertAlmostEqual(f_arc["concave_arc_width"], 10.0, places=2)
        agg = self.arena.aggregate_positioning_metrics([f_arc])
        self.assertGreater(agg["concave_arc_width"], 9.5)

    def test_role_inversion_tanks_in_front_vs_behind_marines(self) -> None:
        enemy = [{"type": "roach", "x": 95.0, "y": 80.0}]
        # Inverted (sc2-real-t02 failure): Tanks (x=86) ahead of Marines (x=82)
        inverted_p1 = [
            {"type": "siege-tank-sieged", "x": 86.0, "y": 79.0},
            {"type": "siege-tank-sieged", "x": 86.0, "y": 81.0},
            {"type": "marine", "x": 82.0, "y": 78.0},
            {"type": "marine", "x": 82.0, "y": 80.0},
            {"type": "marine", "x": 82.0, "y": 82.0},
        ]
        f_inv = self.arena.compute_positioning_frame_metrics(inverted_p1, enemy)
        self.assertTrue(f_inv["role_check_valid"])
        self.assertTrue(f_inv["role_inverted"])
        self.assertEqual(self.arena.aggregate_positioning_metrics([f_inv])["role_inversion_pct"], 100.0)

        # Proper screen: Marines (x=86) ahead of Tanks (x=82)
        screened_p1 = [
            {"type": "siege-tank-sieged", "x": 82.0, "y": 79.0},
            {"type": "siege-tank-sieged", "x": 82.0, "y": 81.0},
            {"type": "marine", "x": 86.0, "y": 78.0},
            {"type": "marine", "x": 86.0, "y": 80.0},
            {"type": "marine", "x": 86.0, "y": 82.0},
        ]
        f_ok = self.arena.compute_positioning_frame_metrics(screened_p1, enemy)
        self.assertTrue(f_ok["role_check_valid"])
        self.assertFalse(f_ok["role_inverted"])
        self.assertEqual(self.arena.aggregate_positioning_metrics([f_ok])["role_inversion_pct"], 0.0)

        # Mixed 50/50 frames
        self.assertEqual(self.arena.aggregate_positioning_metrics([f_inv, f_ok])["role_inversion_pct"], 50.0)

        # Single-role squad (no frontline/backline split) -> 0.0%
        pure_stalkers = [{"type": "stalker", "x": 84.0, "y": 80.0 + i} for i in range(4)]
        f_single = self.arena.compute_positioning_frame_metrics(pure_stalkers, enemy)
        self.assertFalse(f_single["role_check_valid"])
        self.assertEqual(self.arena.aggregate_positioning_metrics([f_single])["role_inversion_pct"], 0.0)

    def test_anti_splash_clump_score_drops_on_spread_and_zero_without_splash(self) -> None:
        enemy_splash = [{"type": "archon", "x": 92.0, "y": 80.0}]
        enemy_no_splash = [{"type": "zealot", "x": 92.0, "y": 80.0}]

        # Tightly clumped 5 hydralisks within 0.5t of each other (4 neighbors each!)
        clumped = [{"type": "hydralisk", "x": 85.0 + 0.1 * i, "y": 80.0} for i in range(5)]
        f_clump = self.arena.compute_positioning_frame_metrics(clumped, enemy_splash)
        self.assertTrue(f_clump["splash_check_valid"])
        self.assertAlmostEqual(f_clump["anti_splash_clump"], 4.0, places=2)

        # Spread 3.0t apart (> 2.2t splash neighbor threshold -> 0 neighbors each!)
        spread = [{"type": "hydralisk", "x": 85.0, "y": 74.0 + 3.0 * i} for i in range(5)]
        f_spread = self.arena.compute_positioning_frame_metrics(spread, enemy_splash)
        self.assertTrue(f_spread["splash_check_valid"])
        self.assertAlmostEqual(f_spread["anti_splash_clump"], 0.0, places=2)

        agg_clump = self.arena.aggregate_positioning_metrics([f_clump])
        agg_spread = self.arena.aggregate_positioning_metrics([f_spread])
        self.assertGreater(agg_clump["anti_splash_clump_score"], agg_spread["anti_splash_clump_score"])

        # No enemy splash alive -> splash_check_valid False, aggregate 0.0
        f_nosplash = self.arena.compute_positioning_frame_metrics(clumped, enemy_no_splash)
        self.assertFalse(f_nosplash["splash_check_valid"])
        self.assertEqual(self.arena.aggregate_positioning_metrics([f_nosplash])["anti_splash_clump_score"], 0.0)

    def test_dps_active_pct_bounds_and_activity(self) -> None:
        enemy = [{"type": "roach", "x": 90.0, "y": 80.0}]
        # Marine range = 5.0 -> eligible within 7.0t (x >= 83.0):
        # u1: active via weapon_cooldown > 0 (in range)
        # u2: active via attack order 23 (in range)
        # u3: idle/moving in range (eligible, NOT active)
        # u4: far away at x=70.0 (not eligible)
        # u5: pure caster (viper) -> excluded from auto-attack DPS denominator
        p1 = [
            _mk_proto_unit(48, 86.0, 80.0, weapon_cooldown=0.6),
            _mk_proto_unit(48, 85.0, 81.0, weapon_cooldown=0.0, order_abs=(23,)),
            _mk_proto_unit(48, 85.0, 79.0, weapon_cooldown=0.0, order_abs=(16,)),
            _mk_proto_unit(48, 70.0, 80.0, weapon_cooldown=0.0, order_abs=(16,)),
            _mk_proto_unit(499, 86.0, 82.0, weapon_cooldown=0.0, order_abs=()),
        ]
        f = self.arena.compute_positioning_frame_metrics(p1, enemy)
        self.assertEqual(f["dps_eligible"], 3)
        self.assertEqual(f["dps_active"], 2)
        agg = self.arena.aggregate_positioning_metrics([f])
        self.assertAlmostEqual(agg["dps_active_pct"], 66.7, places=1)
        self.assertGreaterEqual(agg["dps_active_pct"], 0.0)
        self.assertLessEqual(agg["dps_active_pct"], 100.0)

        # Empty frame safety
        empty_agg = self.arena.aggregate_positioning_metrics([])
        self.assertEqual(empty_agg["dps_active_pct"], 0.0)
        self.assertEqual(empty_agg["concave_arc_width"], 0.0)

    def test_markdown_table_and_aggregate_report_summary(self) -> None:
        sample_scens = [
            {
                "id": "sc2-kit-k03-zvp-hydra-roach-concave-vs-chargelot-archon",
                "race": "Zerg",
                "tier": "canonical",
                "category": "kiting-concave",
                "winner": "Mothman",
                "win_type": "ko",
                "p1_lost_val": 500.0,
                "p2_lost_val": 1500.0,
                "trade_ratio": 3.0,
                "mothman_attack_unit_cmds": 120,
                "mothman_move_unit_cmds": 30,
                "mothman_spell_unit_cmds": 0,
                "concave_arc_width": 8.4,
                "role_inversion_pct": 0.0,
                "anti_splash_clump_score": 0.85,
                "dps_active_pct": 88.5,
            },
            {
                "id": "sc2-real-t02-tank-marine-vs-roach-ling",
                "race": "Terran",
                "tier": "canonical",
                "category": "kiting-concave",
                "winner": "Mothman",
                "win_type": "ko",
                "p1_lost_val": 400.0,
                "p2_lost_val": 800.0,
                "trade_ratio": 2.0,
                "mothman_attack_unit_cmds": 80,
                "mothman_move_unit_cmds": 20,
                "mothman_spell_unit_cmds": 2,
                "concave_arc_width": 5.6,
                "role_inversion_pct": 10.0,
                "anti_splash_clump_score": 0.0,
                "dps_active_pct": 75.5,
            },
        ]
        md = self.arena.format_positioning_markdown_table(sample_scens)
        self.assertIn("Arc Width", md)
        self.assertIn("8.40t", md)
        self.assertIn("10.0%", md)

        args = argparse.Namespace(map="PersephoneAIE_v4.SC2Map")
        rep = self.arena._build_aggregate_report(args, sample_scens, sc2_wall_ms=1000.0, opp_mode="dummy")
        s = rep["summary"]
        self.assertAlmostEqual(s["avg_concave_arc_width"], 7.0, places=2)
        self.assertAlmostEqual(s["avg_role_inversion_pct"], 5.0, places=1)
        self.assertAlmostEqual(s["avg_anti_splash_clump_score"], 0.42, places=2)
        self.assertAlmostEqual(s["avg_dps_active_pct"], 82.0, places=1)
        cat_s = s["by_category"]["kiting-concave"]
        self.assertAlmostEqual(cat_s["avg_concave_arc_width"], 7.0, places=2)
        self.assertAlmostEqual(cat_s["avg_role_inversion_pct"], 5.0, places=1)

    def test_arena_scenarios_schema_fast_core_and_single_spawn_flanks(self) -> None:
        raw = json.loads(SCENARIOS_JSON.read_text(encoding="utf-8"))
        specs = self.arena.load_scenarios(str(SCENARIOS_JSON), REPO_ROOT)
        errs = self.arena.validate_scenarios(specs)
        self.assertEqual(errs, [], f"Scenario validation errors: {errs}")
        self.assertEqual(len(specs), 295)
        self.assertEqual(len(raw["scenarios"]), 295)
        self.assertEqual(sum(1 for s in specs if s.fast_core), 115)

        # Verify Loop 79 Locust unit registration (free spawned ground + flying)
        self.assertEqual(self.arena.UNIT_IDS["locust"], 489)
        self.assertEqual(self.arena.UNIT_IDS["locust-mp"], 489)
        self.assertEqual(self.arena.UNIT_IDS["locust-flying"], 693)
        self.assertEqual(self.arena.UNIT_IDS["locust-mp-flying"], 693)
        self.assertEqual(self.arena.UNIT_VALUES[489], 0.0)
        self.assertEqual(self.arena.UNIT_VALUES[693], 0.0)
        self.assertIn(489, self.arena.COMBAT_IDS)
        self.assertIn(693, self.arena.AIR_UNIT_IDS)

        by_id = {s.id: s for s in specs}
        self.assertEqual(len(by_id), len(specs), "Duplicate scenario IDs found")

        loop79_pro_drills = {
            "sc2-sh-d01-pvz-colossi-archon-stand-clear-locusts": ("Protoss", "Zerg", "kiting-concave", "combat"),
            "sc2-sh-d02-pvz-stalker-immortal-retreat-locusts": ("Protoss", "Zerg", "kiting-concave", "combat"),
            "sc2-sh-d03-tvz-hellbat-tank-clear-locusts": ("Terran", "Zerg", "kiting-concave", "combat"),
            "sc2-lib-m01-tvz-dual-liberator-deadspace-harass": ("Terran", "Zerg", "runby-offense", "worker-runby"),
            "sc2-car-b01-zvp-hydras-viper-interceptor-burn": ("Zerg", "Protoss", "air-superiority", "combat"),
            "sc2-car-b02-tvp-bio-viking-binary-carrier-snipe": ("Terran", "Protoss", "air-superiority", "combat"),
        }
        for sid, (our_r, en_r, cat, smode) in loop79_pro_drills.items():
            self.assertIn(sid, by_id)
            sc = by_id[sid]
            self.assertTrue(sc.fast_core, f"{sid} must be fast_core=True")
            self.assertEqual(sc.our_race, our_r)
            self.assertEqual(sc.enemy_race, en_r)
            self.assertEqual(sc.category, cat)
            self.assertEqual(sc.scoring_mode, smode)
        self.assertTrue(by_id["sc2-lib-m01-tvz-dual-liberator-deadspace-harass"].use_p2_main_base)
        self.assertIn(2558, by_id["sc2-lib-m01-tvz-dual-liberator-deadspace-harass"].expected_abilities)
        self.assertIn(2542, by_id["sc2-car-b01-zvp-hydras-viper-interceptor-burn"].expected_abilities)

        # Loop 83: Swarm Host drills use mixed Zerg ground army (roach+hydra+swarm-host), 8t front vision, 11.5-12.5t SH gap
        for sh_sid in (
            "sc2-sh-d01-pvz-colossi-archon-stand-clear-locusts",
            "sc2-sh-d02-pvz-stalker-immortal-retreat-locusts",
            "sc2-sh-d03-tvz-hellbat-tank-clear-locusts",
        ):
            sc_sh = by_id[sh_sid]
            p2_names = [u[0] for u in sc_sh.p2_units]
            self.assertEqual(p2_names, ["roach", "hydralisk", "swarm-host"])
            self.assertIn("GlialReconstitution", sc_sh.p2_upgrades)
            self.assertIn("MuscularAugments", sc_sh.p2_upgrades)
            self.assertIn("GroovedSpines", sc_sh.p2_upgrades)
            p1_front = max(u[2] for u in sc_sh.p1_units)
            p2_front = min(u[2] for u in sc_sh.p2_units)
            sh_dx = next(u[2] for u in sc_sh.p2_units if u[0] == "swarm-host")
            self.assertLessEqual(p2_front - p1_front, 9.0)
            self.assertGreaterEqual(sh_dx - p1_front, 11.5)
            self.assertLessEqual(sh_dx - p1_front, 12.5)

        # Loop 83: Carrier drills include realistic Skytoss Storm + Archon support
        for car_sid in (
            "sc2-car-b01-zvp-hydras-viper-interceptor-burn",
            "sc2-car-b02-tvp-bio-viking-binary-carrier-snipe",
        ):
            sc_car = by_id[car_sid]
            p2_types = {u[0] for u in sc_car.p2_units}
            self.assertTrue({"carrier", "archon", "high-templar"} <= p2_types)
            self.assertIn("PsiStorm", sc_car.p2_upgrades)

        promoted_core = [
            "sc2-kit-k01-tvp-cyclone-lockon-kite-vs-stalker-immortal",
            "sc2-kit-k02-tvz-cyclone-hellion-kite-vs-speed-roaches",
            "sc2-kit-k03-zvp-hydra-roach-concave-vs-chargelot-archon",
            "sc2-kit-k04-tvp-bio-split-vs-disruptor-colossus",
            "sc2-kit-k05-pvz-glaive-adept-kite-vs-ling-bane",
            "sc2-real-t02-tank-marine-vs-roach-ling",
        ]
        for sid in promoted_core:
            self.assertIn(sid, by_id)
            self.assertTrue(by_id[sid].fast_core, f"{sid} must be promoted to fast_core=True")

        # Verify both new single-spawn flank drills exist, are fast_core, open terrain, single cohesive P1 clump
        f05 = by_id.get("sc2-flk-f05-zvt-single-spawn-ling-roach-wrap-vs-bio-tank")
        f06 = by_id.get("sc2-flk-f06-tvz-single-spawn-bio-split-arc-vs-tank-bane")
        self.assertIsNotNone(f05)
        self.assertIsNotNone(f06)
        assert f05 is not None and f06 is not None
        self.assertEqual(f05.our_race, "Zerg")
        self.assertEqual(f05.enemy_race, "Terran")
        self.assertEqual(f05.category, "flank-surround")
        self.assertEqual(f05.terrain, "open")
        self.assertTrue(f05.fast_core)
        self.assertTrue(all(dx < 0.0 and dy == 0.0 for _, _, dx, dy in f05.p1_units))
        self.assertTrue(all(dx > 0.0 for _, _, dx, _ in f05.p2_units))

        self.assertEqual(f06.our_race, "Terran")
        self.assertEqual(f06.enemy_race, "Zerg")
        self.assertEqual(f06.category, "flank-surround")
        self.assertEqual(f06.terrain, "open")
        self.assertTrue(f06.fast_core)
        self.assertTrue(all(dx < 0.0 and dy == 0.0 for _, _, dx, dy in f06.p1_units))
        self.assertTrue(all(dx > 0.0 for _, _, dx, _ in f06.p2_units))

    def test_loop83_bot_map_and_nomacro_cmd_and_batch_isolation(self) -> None:
        # BOT_MAP must reference real existing PascalCase bot files
        self.assertEqual(set(self.arena.BOT_MAP.keys()), {"Protoss", "Terran", "Zerg"})
        for race, (bname, container_path) in self.arena.BOT_MAP.items():
            self.assertTrue(container_path.startswith("/mothman-repo/bots/Mothman-"), f"{race}: {container_path}")
            rel = container_path.removeprefix("/mothman-repo/")
            self.assertTrue((REPO_ROOT / rel).is_file(), f"Missing bot entrypoint for {race}: {REPO_ROOT / rel}")
            self.assertTrue(bname.startswith("Mothman-"))

        # build_mothman_bot_cmd passes --no-macro by default and omits it only when allow_macro=True
        cmd_nomacro = self.arena.build_mothman_bot_cmd("Mothman-P", 8081, 8090, "MicroDummy")
        self.assertIn("--no-macro", cmd_nomacro)
        cmd_macro = self.arena.build_mothman_bot_cmd("Mothman-P", 8081, 8090, "MicroDummy", allow_macro=True)
        self.assertNotIn("--no-macro", cmd_macro)

        # partition_duel_batches strictly isolates allow_macro=True from --no-macro scenarios
        specs = self.arena.load_scenarios(str(SCENARIOS_JSON), REPO_ROOT)
        allow_macro_ids = {s.id for s in specs if s.allow_macro}
        expected_allow_macro = {
            "sc2-reg-r14-zvp-full-lifecycle-vs-15-kiting-probes",
            "sc2-reg-r15-tvp-full-lifecycle-vs-15-kiting-probes",
            "sc2-reg-r16-pvp-full-lifecycle-vs-15-kiting-probes",
            "sc2-ab-z10-queen-inject-and-creep-tumor-defense",
            "sc2-nc-11-terran-depot-wall-raise-and-lower-march",
            "sc2-nc-12-protoss-natural-wall-door-hold-and-open",
            "sc2-nc-16-queen-creep-tumor-highway-and-pillar-vision",
        }
        self.assertEqual(allow_macro_ids, expected_allow_macro)
        batches = self.arena.partition_duel_batches(specs)
        for _m, _r1, _r2, _bi, blist in batches:
            flags = {bool(s.allow_macro) for s in blist}
            self.assertEqual(len(flags), 1, f"Mixed allow_macro and --no-macro batch: {[s.id for s in blist]}")
            if True in flags:
                self.assertEqual(len(blist), 1, f"allow_macro scenario must be isolated: {[s.id for s in blist]}")

    def test_loop83_macro_leak_metrics_and_5014_spell_gating_and_summary(self) -> None:
        # Tactical abilities (Prism Warp-In 1413, Interceptor 1042, Nydus Worm 1768, Creep Tumor 3691,
        # Queen Inject 251, Mass Recall 3757, Energy Recharge 4126) MUST NOT trigger macro-leak counters!
        tactical_only = {"23": 120, "16": 40, "1413": 4, "1042": 8, "1768": 1, "3691": 2, "251": 1, "3757": 1, "4126": 1}
        m_clean = self.arena.compute_macro_leak_metrics(tactical_only)
        self.assertEqual(m_clean["macro_buildings_built"], 0)
        self.assertEqual(m_clean["macro_workers_trained"], 0)
        self.assertEqual(m_clean["macro_ability_cmds"], 0)
        self.assertEqual(m_clean["macro_ability_breakdown"], {})

        # Real L2 macro leaks: TrainProbe(1006) x2, BuildPylon(881) x1, ChronoBoost(3755) x1
        leaked = {"23": 50, "1006": 2, "881": 1, "3755": 1, "1413": 3}
        m_leak = self.arena.compute_macro_leak_metrics(leaked)
        self.assertEqual(m_leak["macro_buildings_built"], 1)
        self.assertEqual(m_leak["macro_workers_trained"], 2)
        self.assertEqual(m_leak["macro_ability_cmds"], 4)
        self.assertEqual(m_leak["macro_ability_breakdown"], {"1006": 2, "881": 1, "3755": 1})

        # evaluate_spell_verification handles 5.0.14-gated abilities on Base75689 cleanly
        sv_pg, is_pg = self.arena.evaluate_spell_verification([4111], 1, {}, requires_5014=True, engine_is_5014=False)
        self.assertIsNone(sv_pg)
        self.assertTrue(is_pg)

        sv_5014, is_pg_5014 = self.arena.evaluate_spell_verification([4111], 1, {}, requires_5014=True, engine_is_5014=True)
        self.assertFalse(sv_5014)
        self.assertFalse(is_pg_5014)

        sv_ok, is_pg_ok = self.arena.evaluate_spell_verification([4126], 1, {"4126": 1}, requires_5014=True, engine_is_5014=False)
        self.assertTrue(sv_ok)
        self.assertFalse(is_pg_ok)

        sv_miss, is_pg_miss = self.arena.evaluate_spell_verification([2338], 1, {}, requires_5014=False, engine_is_5014=False)
        self.assertFalse(sv_miss)
        self.assertFalse(is_pg_miss)

        # _build_aggregate_report excludes patch-gated rows from spell_checks_total and tracks --no-macro leaks only on allow_macro=False
        sample = [
            {
                "id": "sc2-ab-z01-infestor-microbial-shroud-vs-air-5014",
                "race": "Zerg", "tier": "canonical", "category": "ability-mastery",
                "winner": "Mothman", "win_type": "ko",
                "p1_lost_val": 200.0, "p2_lost_val": 600.0, "trade_ratio": 3.0,
                "expected_abilities": [4111], "spell_verified": None, "spell_patch_gated": True,
                "allow_macro": False, "macro_buildings_built": 0, "macro_workers_trained": 0, "macro_ability_cmds": 0,
            },
            {
                "id": "sc2-zvz-m02-roach-ravager-bile-concave",
                "race": "Zerg", "tier": "canonical", "category": "kiting-concave",
                "winner": "Mothman", "win_type": "ko",
                "p1_lost_val": 300.0, "p2_lost_val": 900.0, "trade_ratio": 3.0,
                "expected_abilities": [2338], "spell_verified": True,
                "allow_macro": False, "macro_buildings_built": 1, "macro_workers_trained": 0, "macro_ability_cmds": 1,
            },
            {
                "id": "sc2-reg-r16-pvp-full-lifecycle-vs-15-kiting-probes",
                "race": "Protoss", "tier": "regression", "category": "regression",
                "winner": "Mothman", "win_type": "econ_pass",
                "p1_lost_val": 100.0, "p2_lost_val": 750.0, "trade_ratio": 7.5,
                "allow_macro": True, "macro_buildings_built": 2, "macro_workers_trained": 3, "macro_ability_cmds": 5,
            },
        ]
        rep = self.arena._build_aggregate_report(
            argparse.Namespace(map="PersephoneAIE_v4.SC2Map"), sample, sc2_wall_ms=500.0, opp_mode="dummy"
        )
        s = rep["summary"]
        self.assertEqual(s["spell_checks_total"], 1)
        self.assertEqual(s["spell_verified_count"], 1)
        self.assertEqual(s["spell_verified_pct"], 100.0)
        self.assertEqual(s["spell_unverified_ids"], [])
        self.assertEqual(s["spell_patch_gated_count"], 1)
        self.assertEqual(s["spell_patch_gated_ids"], ["sc2-ab-z01-infestor-microbial-shroud-vs-air-5014"])
        self.assertEqual(s["total_macro_buildings_built"], 3)
        self.assertEqual(s["total_macro_workers_trained"], 3)
        self.assertEqual(s["total_macro_ability_cmds"], 6)
        self.assertEqual(s["nomacro_scenarios_total"], 2)
        self.assertEqual(s["nomacro_leak_count"], 1)
        self.assertEqual(s["nomacro_leak_scenarios"], ["sc2-zvz-m02-roach-ravager-bile-concave"])

    def test_loop83_strip_hidden_enemy_townhall_from_obs(self) -> None:
        def _mk_obs():
            units = [
                types.SimpleNamespace(tag=101, alliance=1, unit_type=59, pos=types.SimpleNamespace(x=25.0, y=25.0)),   # P1 own Nexus
                types.SimpleNamespace(tag=202, alliance=4, unit_type=86, pos=types.SimpleNamespace(x=150.0, y=150.0)), # P2 live Hatchery
                types.SimpleNamespace(tag=999, alliance=4, unit_type=86, pos=types.SimpleNamespace(x=150.0, y=150.0)), # P2 fog snapshot Hatchery
                types.SimpleNamespace(tag=303, alliance=4, unit_type=110, pos=types.SimpleNamespace(x=92.0, y=88.0)),  # P2 combat Roach
            ]
            return types.SimpleNamespace(raw_data=types.SimpleNamespace(units=units))

        # Non-main-base skirmish: strips BOTH live tag=202 and fog snapshot tag=999 at (150, 150)
        obs1 = _mk_obs()
        removed1 = self.arena.strip_hidden_enemy_townhall_from_obs(
            obs1, enemy_orig_th_tag=202, keep_enemy_th=False, enemy_orig_th_pos=(150.0, 150.0)
        )
        self.assertEqual(removed1, 2)
        self.assertEqual([u.tag for u in obs1.raw_data.units], [101, 303])

        # Main-base raid (keep_enemy_th=True): keeps everything intact
        obs2 = _mk_obs()
        removed2 = self.arena.strip_hidden_enemy_townhall_from_obs(
            obs2, enemy_orig_th_tag=202, keep_enemy_th=True, enemy_orig_th_pos=(150.0, 150.0)
        )
        self.assertEqual(removed2, 0)
        self.assertEqual(len(obs2.raw_data.units), 4)

    def test_loop83_pro_realism_catalog_upgrades_and_9_new_drills(self) -> None:
        specs = self.arena.load_scenarios(str(SCENARIOS_JSON), REPO_ROOT)
        by_id = {s.id: s for s in specs}

        # 1. All 9 new Tier 2 fast_core drills exist with proper matchups, upgrades, and categories
        new_9 = {
            "sc2-zvz-m01-ling-bane-micro-war": ("Zerg", "Zerg", "kiting-concave"),
            "sc2-zvz-m02-roach-ravager-bile-concave": ("Zerg", "Zerg", "kiting-concave"),
            "sc2-zvz-m03-muta-ling-bane-vs-hydra-lurker": ("Zerg", "Zerg", "air-superiority"),
            "sc2-tvt-m01-marine-tank-viking-leapfrog": ("Terran", "Terran", "high-ground-ramp"),
            "sc2-tvt-m02-reaper-hellion-early-skirmish": ("Terran", "Terran", "kiting-concave"),
            "sc2-pvp-m01-blink-immortal-disruptor-skirmish": ("Protoss", "Protoss", "spellcasters"),
            "sc2-pvp-m02-shield-battery-overcharge-hold": ("Protoss", "Protoss", "early-rush-defense"),
            "sc2-pvz-m01-2adept-shade-harass-vs-queen-ling": ("Protoss", "Zerg", "runby-offense"),
            "sc2-pvz-m02-speedling-flood-incomplete-wall-hold": ("Protoss", "Zerg", "early-rush-defense"),
        }
        for sid, (r1, r2, cat) in new_9.items():
            self.assertIn(sid, by_id)
            sc = by_id[sid]
            self.assertTrue(sc.fast_core, f"{sid} must be fast_core=True")
            self.assertEqual((sc.our_race, sc.enemy_race, sc.category), (r1, r2, cat))
        self.assertIn(2338, by_id["sc2-zvz-m02-roach-ravager-bile-concave"].expected_abilities)
        self.assertIn(2346, by_id["sc2-pvp-m01-blink-immortal-disruptor-skirmish"].expected_abilities)
        self.assertIn(2544, by_id["sc2-pvz-m01-2adept-shade-harass-vs-queen-ling"].expected_abilities)
        self.assertTrue(by_id["sc2-pvz-m01-2adept-shade-harass-vs-queen-ling"].use_p2_main_base)
        self.assertTrue(by_id["sc2-pvp-m02-shield-battery-overcharge-hold"].use_main_base)
        self.assertTrue(by_id["sc2-pvz-m02-speedling-flood-incomplete-wall-hold"].use_main_base)

        # 2. All 5 previously zero-creep Zerg scenarios now have creep (tumor or main Hatchery)
        self.assertTrue(any(u[0] == "creep-tumor-burrowed" for u in by_id["sc2-spl-sp09-zvp-queen-transfuse-brood-hydra-vs-voidray"].p1_units))
        self.assertTrue(any(u[0] == "creep-tumor-burrowed" for u in by_id["sc2-real-z04-queen-ultra-ling-vs-stalker-immortal"].p1_units))
        self.assertTrue(any(u[0] == "creep-tumor-burrowed" for u in by_id["sc2-det-d03-p-nonblink-dt-stalker-vs-spores-roach-hydra"].p2_units))
        self.assertTrue(any(u[0] == "creep-tumor-burrowed" for u in by_id["sc2-trn-n15-pvz-prism-cliff-ladder-immortals"].p2_units))
        self.assertTrue(by_id["sc2-rsh-er04-zvp-proxy-voidray-queen-spore-hold"].use_main_base)

        # 3. Zero mineral-line-harass scenarios lack a main-base TownHall
        no_th_mlh = [s.id for s in specs if s.terrain == "mineral-line-harass" and not s.use_main_base and not s.use_p2_main_base]
        self.assertEqual(no_th_mlh, [], f"mineral-line-harass drills missing TownHall: {no_th_mlh}")

        # 4. Intentional premise preservation: blk-b01 keeps P2 non-Blink, rmp-h06 keeps no flying Medivac
        self.assertEqual(by_id["sc2-blk-b01-pvp-12-blink-stalkers-vs-14-stalkers"].p2_upgrades, [])
        self.assertFalse(any(u[0] == "medivac" for u in by_id["sc2-rmp-h06-tvp-blind-uphill-scan-tank-break"].p1_units))


if __name__ == "__main__":
    unittest.main()
