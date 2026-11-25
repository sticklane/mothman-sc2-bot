#!/usr/bin/env python3
"""
Unit tests for Track 1A canonical mining base clustering (<=5.5t BFS, >=4 patches),
tag-reuse-safe Terran flying-CC tracking + SCmdEvent Land fallback, 5-role TownHall
classification (canonical_mining_expansion, canonical_rebuild, macro_hatchery,
macro_oc/macro_nexus, defensive_pf + mining_pf sub-tag), 0..24m buckets, and
aggregate_all schema v5 output.
"""
from __future__ import annotations

import importlib.util
import math
import unittest
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
EXTRACTOR_PATH = REPO_ROOT / "tools" / "extract-pro-comparison-curves.py"


def _load_extractor():
    spec = importlib.util.spec_from_file_location("extract_pro_curves_mod", str(EXTRACTOR_PATH))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = _load_extractor()


def _make_mineral_arc(cx: float, cy: float, radius: float = 6.0, count: int = 8) -> list[tuple[float, float]]:
    """Generate a realistic 8-patch SC2 mineral line arc ~6.0t from TownHall center (cx, cy)."""
    pts: list[tuple[float, float]] = []
    for i in range(count):
        ang = -0.75 + (1.50 * i / max(1, count - 1))
        pts.append((cx + radius * math.cos(ang), cy + radius * math.sin(ang)))
    return pts


def _make_th(
    tag: int,
    init_sec: float,
    done_sec: float | None,
    init_xy: tuple[float, float],
    *,
    died_sec: float = float("inf"),
    cur_xy: tuple[float, float] | None = None,
    ut_init: str = "CommandCenter",
    morphed_oc: bool = False,
    morphed_pf: bool = False,
    pf_sec: float | None = None,
    flew: bool = False,
    first_lift_sec: float | None = None,
    ever_landed: bool = False,
    landed_lp: int = -1,
    landed_sec: float | None = None,
    last_pos_lp: int = -1,
    self_canceled: bool = False,
    is_starting: bool = False,
) -> dict[str, Any]:
    return {
        "tag": tag,
        "uidx": tag >> 18,
        "init_sec": init_sec,
        "done_sec": done_sec,
        "died_sec": died_sec,
        "init_xy": init_xy,
        "cur_xy": cur_xy if cur_xy is not None else init_xy,
        "ut_init": ut_init,
        "ut_final": "PlanetaryFortress" if morphed_pf else ("OrbitalCommand" if morphed_oc else ut_init),
        "morphed_oc": morphed_oc,
        "morphed_pf": morphed_pf,
        "pf_sec": pf_sec,
        "flew": flew,
        "first_lift_sec": first_lift_sec,
        "ever_landed": ever_landed,
        "landed_lp": landed_lp,
        "landed_sec": landed_sec,
        "first_landed_sec": landed_sec,
        "last_pos_lp": last_pos_lp,
        "alive": math.isinf(died_sec),
        "self_canceled": self_canceled,
        "is_starting": is_starting,
    }


class TestMineralClusteringAndMatching(unittest.TestCase):
    def test_neutral_mineral_name_filter(self) -> None:
        for ok in (
            "MineralField",
            "MineralField750",
            "MineralField450",
            "RichMineralField",
            "RichMineralField750",
            "PurifierMineralField",
            "LabMineralField750",
            "BattleStationMineralField",
            "MineralFieldOpaque900",
        ):
            self.assertTrue(MOD.is_neutral_mineral_field(ok), ok)
        for bad in ("VespeneGeyser", "RichVespeneGeyser", "MineralShield", "MineralCrystal", "XelNagaTower"):
            self.assertFalse(MOD.is_neutral_mineral_field(bad), bad)

    def test_adjacent_mineral_lines_stay_separate_and_walls_excluded(self) -> None:
        # Two adjacent bases whose closest mineral patches are ~7.2t apart (> 5.5t BFS link)
        base_a = _make_mineral_arc(30.0, 30.0)
        base_b = _make_mineral_arc(30.0, 48.0)
        # 3-patch mineral wall (< 4 patches) should be filtered out
        wall = [(80.0, 80.0), (81.5, 80.0), (83.0, 80.0)]
        clusters = MOD.cluster_mineral_fields(base_a + base_b + wall)
        self.assertEqual(len(clusters), 2)
        c_a = MOD.match_townhall_to_mineral_cluster(30.0, 30.0, clusters)
        c_b = MOD.match_townhall_to_mineral_cluster(30.0, 48.0, clusters)
        self.assertIsNotNone(c_a)
        self.assertIsNotNone(c_b)
        self.assertNotEqual(c_a, c_b)
        # Off-mineral point near wall or center of map returns None
        self.assertIsNone(MOD.match_townhall_to_mineral_cluster(81.5, 84.0, clusters))
        self.assertIsNone(MOD.match_townhall_to_mineral_cluster(100.0, 100.0, clusters))

    def test_distance_thresholds_enforced(self) -> None:
        # 8-patch arc centered at x=36.0, y=30.0; TH at (30.0, 30.0) has dp_min=6.0, dc_cen~5.4
        clusters = MOD.cluster_mineral_fields(_make_mineral_arc(30.0, 30.0))
        self.assertEqual(len(clusters), 1)
        self.assertEqual(MOD.match_townhall_to_mineral_cluster(30.0, 30.0, clusters), 0)
        # Slightly shifted TH still within dp_min <= 8.0 and dc_cen <= 10.5
        self.assertEqual(MOD.match_townhall_to_mineral_cluster(28.5, 30.0, clusters), 0)
        # Too far behind (dp_min > 8.0 and dc_cen > 10.5)
        self.assertIsNone(MOD.match_townhall_to_mineral_cluster(20.0, 30.0, clusters))


class TestFiveRoleTownHallClassification(unittest.TestCase):
    def setUp(self) -> None:
        # 8 canonical mineral bases spread around the map
        self.base_xy = [
            (30.0, 30.0),    # 1st (Main)
            (55.0, 30.0),    # 2nd (Natural)
            (80.0, 30.0),    # 3rd
            (105.0, 30.0),   # 4th
            (30.0, 65.0),    # 5th
            (55.0, 65.0),    # 6th
            (80.0, 65.0),    # 7th
            (105.0, 65.0),   # 8th
        ]
        pts: list[tuple[float, float]] = []
        for x, y in self.base_xy:
            pts.extend(_make_mineral_arc(x, y))
        self.clusters = MOD.cluster_mineral_fields(pts)
        self.assertEqual(len(self.clusters), 8)

    def test_zerg_canonical_8_bases_vs_macro_hatch_rebuild_and_cancel(self) -> None:
        ths = [
            # 1st..4th canonical bases
            _make_th(1 << 18, 0.0, 0.0, self.base_xy[0], ut_init="Hatchery", is_starting=True),
            _make_th(2 << 18, 50.0, 121.0, self.base_xy[1], ut_init="Hatchery"),
            # Self-canceled Hatch trick at 3rd should NOT claim 3rd or shift timings
            _make_th(3 << 18, 130.0, None, self.base_xy[2], died_sec=135.0, ut_init="Hatchery", self_canceled=True),
            # Real 3rd base (destroyed at 450s, rebuilt at 500s)
            _make_th(4 << 18, 175.0, 246.0, self.base_xy[2], died_sec=450.0, ut_init="Hatchery"),
            # In-main Macro Hatchery at occupied main cluster (30, 30) -> macro_hatchery!
            _make_th(5 << 18, 320.0, 391.0, (29.0, 31.0), ut_init="Hatchery"),
            # Off-mineral Macro Hatchery -> macro_hatchery!
            _make_th(6 << 18, 360.0, 431.0, (140.0, 140.0), ut_init="Hatchery"),
            # 4th canonical base
            _make_th(7 << 18, 410.0, 481.0, self.base_xy[3], ut_init="Hatchery"),
            # Rebuild of destroyed 3rd base at 500s -> canonical_rebuild (NOT 5th base!)
            _make_th(8 << 18, 500.0, 571.0, self.base_xy[2], ut_init="Hatchery"),
            # 5th..8th canonical bases
            _make_th(9 << 18, 610.0, 681.0, self.base_xy[4], ut_init="Hatchery"),
            _make_th(10 << 18, 760.0, 831.0, self.base_xy[5], ut_init="Hatchery"),
            _make_th(11 << 18, 920.0, 991.0, self.base_xy[6], ut_init="Hatchery"),
            _make_th(12 << 18, 1120.0, 1191.0, self.base_xy[7], ut_init="Hatchery"),
        ]
        res = MOD.classify_player_townhalls(ths, self.clusters, "Zerg", dur_sec=1320.0)
        self.assertEqual(
            res["canonical_base_timings"],
            {"fourth": 410.0, "fifth": 610.0, "sixth": 760.0, "seventh": 920.0, "eighth": 1120.0},
        )
        self.assertEqual(res["total_canonical_bases"], 8)
        self.assertEqual(res["peak_canonical_bases"], 8)
        self.assertEqual(res["non_mining_counts"]["macro_hatchery"], 2)
        self.assertEqual(res["non_mining_counts"]["rebuilds"], 1)
        self.assertEqual(res["non_mining_first_sec"]["macro_hatchery"], 320.0)
        self.assertEqual(res["non_mining_first_sec"]["rebuilds"], 500.0)

        # Verify active_canonical_bases over BUCKETS_24M_SEC (0..1440s, 25 entries)
        acb = res["active_canonical_bases"]
        self.assertEqual(len(acb), 25)
        self.assertEqual(acb[0], 1)    # 0:00 -> Main
        self.assertEqual(acb[7], 3)    # 7:00 (420s) -> Main, Nat, 3rd (2 Macro Hatches ignored!)
        self.assertEqual(acb[8], 2)    # 8:00 (480s) -> 3rd died at 450s, 4th finishes at 481s -> 2!
        self.assertEqual(acb[9], 3)    # 9:00 (540s) -> Main, Nat, 4th (rebuild finishes at 571s)
        self.assertEqual(acb[10], 4)   # 10:00 (600s) -> Main, Nat, rebuilt 3rd, 4th
        self.assertEqual(acb[20], 8)   # 20:00 (1200s) -> all 8 canonical bases active
        self.assertIsNone(acb[23])     # 23:00 (1380s > dur_sec 1320s) -> None

    def test_terran_flying_cc_mining_pf_defensive_pf_macro_oc_and_migration(self) -> None:
        ths = [
            # 1st Main CC: starts at Main, later lifts at 860s and migrates to 5th base at 900s!
            _make_th(
                1 << 18, 0.0, 0.0, self.base_xy[0], cur_xy=self.base_xy[4],
                ut_init="CommandCenter", morphed_oc=True, flew=True,
                first_lift_sec=860.0, ever_landed=True, landed_lp=int(900 * 22.4), landed_sec=900.0,
                last_pos_lp=int(910 * 22.4), is_starting=True,
            ),
            # 2nd Natural CC built in-main at 105s, finishes 176s, floats and lands at Natural at 205s
            _make_th(
                2 << 18, 105.0, 176.0, (28.0, 29.0), cur_xy=self.base_xy[1],
                ut_init="CommandCenter", morphed_oc=True, flew=True,
                first_lift_sec=185.0, ever_landed=True, landed_lp=int(205 * 22.4), landed_sec=205.0,
                last_pos_lp=int(215 * 22.4),
            ),
            # 3rd CC built in-main at 260s, lands at 3rd via SCmdEvent Land fallback (last_pos_lp < landed_lp)
            _make_th(
                3 << 18, 260.0, 331.0, (28.5, 31.0), cur_xy=(50.0, 30.0),  # stale mid-flight pos!
                ut_init="CommandCenter", morphed_oc=True, flew=True,
                first_lift_sec=340.0, ever_landed=True, landed_lp=int(370 * 22.4), landed_sec=370.0,
                last_pos_lp=int(355 * 22.4),
            ),
            # 4th CC built directly at 4th base and morphed to Mining PF at 540s (later destroyed at 700s)
            _make_th(
                4 << 18, 430.0, 501.0, self.base_xy[3], died_sec=700.0,
                ut_init="CommandCenter", morphed_pf=True, pf_sec=540.0,
            ),
            # Macro OC built in-main at 520s (never flies to unoccupied cluster) -> macro_oc
            _make_th(5 << 18, 520.0, 591.0, (29.0, 28.5), ut_init="CommandCenter", morphed_oc=True),
            # Defensive PF built off-mineral in map center -> defensive_pf
            _make_th(6 << 18, 600.0, 671.0, (140.0, 140.0), ut_init="CommandCenter", morphed_pf=True, pf_sec=710.0),
            # Defensive PF built right next to already-alive 3rd OC -> defensive_pf!
            _make_th(7 << 18, 620.0, 691.0, (79.0, 31.0), ut_init="CommandCenter", morphed_pf=True, pf_sec=730.0),
            # Rebuild of destroyed 4th base as Mining PF at 740s -> canonical_rebuild + mining_pf!
            _make_th(8 << 18, 740.0, 811.0, self.base_xy[3], ut_init="CommandCenter", morphed_pf=True, pf_sec=850.0),
        ]
        # Apply SCmdEvent Land fallback for tag 3 << 18
        land_cmds = [
            (int(362 * 22.4), self.base_xy[2][0], self.base_xy[2][1], (3 << 18,)),
        ]
        MOD.resolve_terran_flying_th_positions(ths, land_cmds)
        self.assertEqual(ths[2]["cur_xy"], self.base_xy[2])
        self.assertTrue(ths[2].get("used_land_cmd_fallback"))
        # TH #2 already had fresh SUnitPositionsEvent (last_pos_lp >= landed_lp) -> untouched
        self.assertFalse(ths[1].get("used_land_cmd_fallback", False))

        res = MOD.classify_player_townhalls(ths, self.clusters, "Terran", dur_sec=1000.0)
        by_tag = {c["tag"]: c for c in res["classified"]}
        self.assertEqual(by_tag[1 << 18]["role"], "canonical_mining_expansion")
        self.assertEqual(by_tag[2 << 18]["role"], "canonical_mining_expansion")
        self.assertEqual(by_tag[3 << 18]["role"], "canonical_mining_expansion")
        self.assertEqual(by_tag[4 << 18]["role"], "canonical_mining_expansion")
        self.assertTrue(by_tag[4 << 18]["is_mining_pf"])
        self.assertEqual(by_tag[5 << 18]["role"], "macro_oc")
        self.assertEqual(by_tag[6 << 18]["role"], "defensive_pf")
        self.assertEqual(by_tag[7 << 18]["role"], "defensive_pf")
        self.assertEqual(by_tag[8 << 18]["role"], "canonical_rebuild")
        self.assertTrue(by_tag[8 << 18]["is_mining_pf"])

        # Canonical timings: 4th=430s, 5th=900s (from migrated Main OC, NOT 0.0s!)
        self.assertEqual(res["canonical_base_timings"]["fourth"], 430.0)
        self.assertEqual(res["canonical_base_timings"]["fifth"], 900.0)
        self.assertIsNone(res["canonical_base_timings"]["sixth"])
        self.assertEqual(res["non_mining_counts"]["macro_oc"], 1)
        self.assertEqual(res["non_mining_counts"]["mining_pf"], 2)
        self.assertEqual(res["non_mining_counts"]["defensive_pf"], 2)
        self.assertEqual(res["non_mining_counts"]["rebuilds"], 1)
        self.assertEqual(res["non_mining_first_sec"]["mining_pf"], 540.0)
        self.assertEqual(res["non_mining_first_sec"]["defensive_pf"], 710.0)

        # Active canonical bases: at 3:00 (180s), CC #2 hasn't landed at Nat yet -> still 1!
        # At 4:00 (240s), CC #2 landed at 205s -> 2!
        # At 15:00 (900s), Main OC vacated cluster 0 at 860s and landed at cluster 4 at 900s -> 4!
        acb = res["active_canonical_bases"]
        self.assertEqual(acb[3], 1)
        self.assertEqual(acb[4], 2)
        self.assertEqual(acb[15], 4)

    def test_protoss_macro_nexus_and_static_coordinates(self) -> None:
        ths = [
            _make_th(1 << 18, 0.0, 0.0, self.base_xy[0], ut_init="Nexus", is_starting=True),
            _make_th(2 << 18, 95.0, 166.0, self.base_xy[1], ut_init="Nexus"),
            # Extra Chrono Nexus built inside Main -> macro_nexus
            _make_th(3 << 18, 420.0, 491.0, (28.5, 31.5), ut_init="Nexus"),
        ]
        res = MOD.classify_player_townhalls(ths, self.clusters, "Protoss", dur_sec=600.0)
        self.assertEqual(res["non_mining_counts"]["macro_nexus"], 1)
        self.assertEqual(res["non_mining_first_sec"]["macro_nexus"], 420.0)
        self.assertEqual(res["peak_canonical_bases"], 2)
        self.assertEqual(res["total_canonical_bases"], 2)
        self.assertIsNone(res["canonical_base_timings"]["fourth"])


class TestAggregateSchemaV5(unittest.TestCase):
    def _dummy_rec(
        self, cohort: str, race: str, dur: float, canon_b: list[int | None], th_b: list[int | None],
        gas_b: list[int | None], b_timings: dict[str, float | None], g_timings: dict[str, float | None],
        nm_counts: dict[str, int], nm_first: dict[str, float | None], peak_canon: int, tot_canon: int,
    ) -> dict[str, Any]:
        b0 = [0, 30, 60]
        return {
            "cohort": cohort,
            "race": race,
            "matchup": f"{race[0]}vT",
            "won": True,
            "result_code": 1,
            "duration_sec": dur,
            "base_build": 90870,
            "replay": "synth.SC2Replay",
            "game_events_ok": False,
            "curves": {
                "apm": None, "epm": None, "spm": None,
                "army_minerals": [0.0] * len(b0), "army_gas": [0.0] * len(b0),
                "collection_minerals": [500.0] * len(b0), "collection_gas": [0.0] * len(b0),
            },
            "summary": {
                "apm": None, "epm": None, "spm": None,
                "army_minerals": 500.0, "army_gas": 200.0,
                "collection_minerals": 1200.0, "collection_gas": 400.0,
                "army_minerals_peak": 1000.0, "army_gas_peak": 500.0,
                "collection_minerals_peak": 2000.0, "collection_gas_peak": 800.0,
                "army_fragmentation_pct": None, "active_clusters": None,
                "army_retention_ratio": None, "peak_to_cum_retention": None,
                "peak_active_bases": max((x for x in th_b if x is not None), default=1),
                "peak_canonical_bases": peak_canon,
                "total_canonical_bases": tot_canon,
                "peak_active_gas": max((x for x in gas_b if x is not None), default=0),
                "reached_4plus_bases": tot_canon >= 4,
                "reached_5plus_bases": tot_canon >= 5,
                "reached_6plus_bases": tot_canon >= 6,
                "reached_7plus_bases": tot_canon >= 7,
                "gas_per_base_4plus": 1.6,
            },
            "timings": {},
            "cohesion_16m": {
                "army_fragmentation_pct": [None] * len(MOD.BUCKETS_16M_SEC),
                "active_clusters": [None] * len(MOD.BUCKETS_16M_SEC),
                "army_retention_ratio": [None] * len(MOD.BUCKETS_16M_SEC),
            },
            "clashes": [],
            "expansions_18m": {
                "active_townhalls": th_b,
                "active_canonical_bases": canon_b,
                "active_gas_geysers": gas_b,
                "base_4plus_timings": b_timings,
                "gas_7plus_timings": g_timings,
                "non_mining_counts": nm_counts,
                "non_mining_first_sec": nm_first,
            },
            "tier_mix": [None] * len(MOD.BUCKETS_TIER_SEC),
            "all_upgrades": {},
            "concave_samples": [],
            "rotation_mp": {
                "def_rotations": [], "off_rot_count": 0, "off_front_idle_pcts": [],
                "mp_count": 0, "bs_count": 0, "bs_wk_kills": 0,
            },
            "unit_comp_2_18m": [None] * len(MOD.BUCKETS_TIER_SEC),
        }

    def test_aggregate_all_emits_schema_v5_fields(self) -> None:
        zeros = {k: 0 for k, _ in MOD.NON_MINING_TH_ROLES}
        nones = {k: None for k, _ in MOD.NON_MINING_TH_ROLES}
        pro_nm = dict(zeros, macro_hatchery=2, rebuilds=1)
        pro_first = dict(nones, macro_hatchery=410.0, rebuilds=680.0)
        recs = [
            self._dummy_rec(
                "pros", "Zerg", 1200.0,
                [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, None, None, None, None],
                [1, 1, 2, 2, 3, 3, 4, 5, 6, 7, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, None, None, None, None],
                [0, 0, 1, 2, 3, 4, 6, 7, 8, 9, 10, 11, 12, 12, 12, 12, 12, 12, 12, 12, 12, None, None, None, None],
                {"fourth": 350.0, "fifth": 480.0, "sixth": 600.0, "seventh": 780.0, "eighth": 980.0},
                {"gas_7": 420.0, "gas_8": 460.0, "gas_9": 560.0, "gas_10": 610.0, "gas_11": 720.0, "gas_12": 760.0},
                pro_nm, pro_first, peak_canon=7, tot_canon=8,
            ),
            self._dummy_rec(
                "mothman", "Zerg", 1020.0,
                [1, 1, 2, 2, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, None, None, None, None, None, None, None],
                [1, 1, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, None, None, None, None, None, None, None],
                [0, 0, 1, 2, 3, 4, 5, 6, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8, None, None, None, None, None, None, None],
                {"fourth": 420.0, "fifth": None, "sixth": None, "seventh": None, "eighth": None},
                {"gas_7": 480.0, "gas_8": 600.0, "gas_9": None, "gas_10": None, "gas_11": None, "gas_12": None},
                dict(zeros, macro_hatchery=1), dict(nones, macro_hatchery=590.0), peak_canon=4, tot_canon=4,
            ),
        ]
        out = MOD.aggregate_all(recs, [0, 30, 60], {"run_id": "test"})
        self.assertEqual(out["schema_version"], 5)

        e4 = out["expansions_4plus"]
        self.assertEqual(len(e4["buckets_sec"]), 25)
        self.assertEqual(e4["buckets_sec"][-1], 1440)
        self.assertEqual(e4["buckets_label"][-1], "24:00")
        self.assertEqual(len(e4["active_canonical_bases"]["Zerg"]["pros"]), 25)
        self.assertEqual(e4["active_canonical_bases"]["Zerg"]["pros"][10]["med"], 6.0)
        self.assertEqual(e4["active_townhalls"]["Zerg"]["pros"][10]["med"], 8.0)

        # Base timings cover fourth..eighth
        bt_keys = [row["key"] for row in e4["base_timings"]["Zerg"]]
        self.assertEqual(bt_keys, ["fourth", "fifth", "sixth", "seventh", "eighth"])
        bt_by_k = {row["key"]: row for row in e4["base_timings"]["Zerg"]}
        self.assertEqual(bt_by_k["eighth"]["pros"]["med"], 980.0)
        self.assertEqual(bt_by_k["fifth"]["mothman"]["adopt_pct"], 0.0)

        # Reach 4+/5+/6+/7+ including >=16m
        r4_pro = e4["reach_4plus"]["Zerg"]["pros"]
        self.assertEqual(r4_pro["pct_ge16m"], 100.0)
        self.assertEqual(r4_pro["peak_canonical_bases"]["med"], 7.0)
        self.assertEqual(r4_pro["reach_7plus"]["pct_ge16m"], 100.0)
        r4_m = e4["reach_4plus"]["Zerg"]["mothman"]
        self.assertEqual(r4_m["pct_ge16m"], 100.0)
        self.assertEqual(r4_m["reach_5plus"]["pct_ge16m"], 0.0)

        # Non-mining townhalls
        nm_z = e4["non_mining_townhalls"]["Zerg"]
        self.assertEqual(nm_z["macro_hatchery"]["pros"]["total_count"], 2)
        self.assertEqual(nm_z["macro_hatchery"]["pros"]["mean_count"], 2.0)
        self.assertEqual(nm_z["macro_hatchery"]["pros"]["adopt_pct"], 100.0)
        self.assertEqual(nm_z["macro_hatchery"]["pros"]["first_med_s"], 410.0)
        self.assertEqual(nm_z["macro_hatchery"]["pros"]["first_med_fmt"], "6:50")

        # Gas 7..12 over 0..24m
        g7 = out["gas_7plus"]
        self.assertEqual(len(g7["buckets_sec"]), 25)
        self.assertEqual([row["key"] for row in g7["gas_timings"]["Zerg"]],
                         ["gas_7", "gas_8", "gas_9", "gas_10", "gas_11", "gas_12"])


class TestRealReplaySmoke(unittest.TestCase):
    def test_pro_terran_flying_cc_replay(self) -> None:
        rp = REPO_ROOT / "replays" / "pro_corpus" / "Starcraft2Metrics_188cf9606fc7_2019-07-11_-__T_Zoom_VS__P_NULL.SC2Replay"
        pylibs = Path("/home/sjaconette/sc2-local-arena/pylibs")
        if not rp.is_file() or not pylibs.is_dir():
            self.skipTest("Pro replay or pylibs unavailable in this environment")
        recs = MOD._parse_single_replay((str(rp), str(pylibs), "pro", 60.0, list(range(0, 901, 30)), 30, None))
        self.assertEqual(len(recs), 2)
        by_race = {r["race"]: r for r in recs}
        self.assertIn("Terran", by_race)
        self.assertIn("Protoss", by_race)
        # Terran built a Mining PF at canonical expansion; Protoss rebuilt destroyed Nexuses
        self.assertGreaterEqual(by_race["Terran"]["expansions_18m"]["non_mining_counts"]["mining_pf"], 1)
        self.assertGreaterEqual(by_race["Protoss"]["expansions_18m"]["non_mining_counts"]["rebuilds"], 1)
        for r in recs:
            e18 = r["expansions_18m"]
            self.assertEqual(len(e18["active_canonical_bases"]), 25)
            self.assertEqual(len(e18["active_townhalls"]), 25)
            self.assertEqual(len(e18["active_gas_geysers"]), 25)
            self.assertEqual(e18["active_canonical_bases"][0], 1)
            self.assertGreaterEqual(r["summary"]["peak_canonical_bases"], 3)
            self.assertSetEqual(
                set(e18["base_4plus_timings"].keys()),
                {"fourth", "fifth", "sixth", "seventh", "eighth"},
            )
            self.assertSetEqual(
                set(e18["gas_7plus_timings"].keys()),
                {"gas_7", "gas_8", "gas_9", "gas_10", "gas_11", "gas_12"},
            )
            self.assertSetEqual(
                set(e18["non_mining_counts"].keys()),
                {"macro_hatchery", "macro_oc", "macro_nexus", "mining_pf", "defensive_pf", "rebuilds"},
            )


if __name__ == "__main__":
    unittest.main()
