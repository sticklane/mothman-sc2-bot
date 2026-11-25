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
        self.assertEqual(len(specs), 286)
        self.assertEqual(len(raw["scenarios"]), 286)
        self.assertEqual(sum(1 for s in specs if s.fast_core), 106)

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
        # Verify Swarm Host drills spawn strictly swarm-host (authentic single 20-Locust wave, no pre-spawned double-wave) at >= 15t separation
        for sh_sid in (
            "sc2-sh-d01-pvz-colossi-archon-stand-clear-locusts",
            "sc2-sh-d02-pvz-stalker-immortal-retreat-locusts",
            "sc2-sh-d03-tvz-hellbat-tank-clear-locusts",
        ):
            sc_sh = by_id[sh_sid]
            self.assertEqual([u[0] for u in sc_sh.p2_units], ["swarm-host"])
            self.assertEqual(sc_sh.p2_units[0][1], 10)
            p1_max_dx = max(u[2] for u in sc_sh.p1_units)
            p2_min_dx = min(u[2] for u in sc_sh.p2_units)
            self.assertGreaterEqual(p2_min_dx - p1_max_dx, 15.0)

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


if __name__ == "__main__":
    unittest.main()
