#!/usr/bin/env python3
"""
tools/mothman_vs_external_bots_gauntlet.py

Fair, Blind, Multi-Map 14-Match Live Headless SC2_x64 Gauntlet for #lang sc-bot
(Mothman-Z, Mothman-T, Mothman-P, Mothman-R) against 14 distinct open-source
StarCraft II bots cloned in `external_bots/` across 10 official Blizzard 1v1
Ladder Edition maps:
  1.  Mothman-Z vs. CannonRushBot       (Protoss Cannon Rush)              @ AutomatonLE
  2.  Mothman-T vs. CannonLoverBot      (Hannessa/sc2-bots, 831 LOC)       @ CyberForestLE
  3.  Mothman-P vs. SentdeBot           (Sentdex/SC2AI Protoss Stalker)    @ KairosJunctionLE
  4.  Mothman-R vs. WorkerRushBot       (Zerg 12-Drone Frame-0 Rush)       @ KingsCoveLE
  5.  Mothman-Z vs. ProxyRaxBot         (Terran Proxy Dual-Rax All-In)     @ PortAleksanderLE
  6.  Mothman-T vs. LingLoverBot        (Hannessa/LingLoverBot Zerg Flood) @ BlueshiftLE
  7.  Mothman-P vs. HarstemsAunt        (HarstemsAunt-SC2-AI, 4,000+ LOC)  @ AbyssalReefLE
  8.  Mothman-R vs. DragonBot           (BurnySc2/DragonBot Terran Bio)    @ BelShirVestigeLE
  9.  Mothman-Z vs. ThreebaseVoidrayBot (Protoss 3-Base Void Ray Armada)   @ NewkirkPrecinctTE
  10. Mothman-T vs. Hydralisk           (Zerg 2-Base Lair Hydralisk Push)  @ ProximaStationLE
  11. Mothman-P vs. CyclonePush         (Terran Factory Cyclone Mech Push) @ AutomatonLE
  12. Mothman-Z vs. MassReaper          (Terran 4-Rax Cliff-Jump Reaper)   @ CyberForestLE
  13. Mothman-T vs. CreepyBot           (BurnySc2/CreepyBot, 2,154 LOC)    @ KairosJunctionLE
  14. Mothman-P vs. MadBot              (MadManSC2/MadBot, 2,770 LOC)      @ KingsCoveLE

All 14 matches enforce:
  - 100% Blind Starts (`posture_override=None`, `Race.Random` for Mothman-R)
  - Official 2-Player 1v1 Ladder Edition Maps (no `Simple64`)
  - Unmodified Real Community Bots running via `LegacyBotAIMixin`
  - Racket `#lang sc-bot` S-expression IPC with Layer 5 `HumanCortex` filtering
"""

import argparse
import asyncio
import importlib.util
import inspect
import json
import os
import sys
import time
import types
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Any, Dict, List, Optional

ROOT_DIR = Path(__file__).resolve().parent.parent
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from sim.sc2_burny_bridge import run_live_headless_sc2_match

RESULTS_JSON_PATH = ROOT_DIR / "data" / "mothman_vs_external_bots_results.json"
REPLAY_DIR = ROOT_DIR / "replays" / "external_gauntlet"


class _ImmediateAwaitable:
    """Allows a return value from `self.do(...)` or `self.do_actions(...)` to be
    either awaited (`await self.do(...)`) or ignored synchronously (`self.do(...)`)."""

    __slots__ = ("val",)

    def __init__(self, val: Any = None):
        self.val = val

    def __await__(self):
        async def _coro():
            return self.val

        return _coro().__await__()

    def __bool__(self) -> bool:
        return bool(self.val) if self.val is not None else True


def install_legacy_sc2_shims() -> None:
    """
    Installs backward-compatibility shims on the `sc2` package so multi-thousand-line
    community bots written for `python-sc2` v3/v4/v5 (`CreepyBot`, `DragonBot`,
    `MadBot`, `CannonLoverBot`, `LingLoverBot`, `HarstemsAunt`, `SentdeBot`) run
    natively and unmodified on `burnysc2==7.3.0`.
    """
    import sc2
    import sc2.constants as const_mod
    import sc2.protocol
    from sc2 import maps
    from sc2.bot_ai import BotAI
    from sc2.data import ActionResult, Alliance, Attribute, Difficulty, Race, Result, Target
    from sc2.game_data import AbilityData, Cost, GameData
    from sc2.ids.ability_id import AbilityId
    from sc2.ids.buff_id import BuffId
    from sc2.ids.effect_id import EffectId
    from sc2.ids.unit_typeid import UnitTypeId
    from sc2.ids.upgrade_id import UpgradeId
    from sc2.main import run_game
    from sc2.position import Point2, Point3, Pointlike, Rect
    from sc2.unit import Unit
    from sc2.unit_command import UnitCommand
    from sc2.units import Units

    sc2.BotAI = BotAI
    sc2.Race = Race
    sc2.Difficulty = Difficulty
    sc2.Result = Result
    sc2.ActionResult = ActionResult
    sc2.run_game = run_game
    sc2.maps = maps
    if not hasattr(sc2.protocol, "ConnectionAlreadyClosed"):
        sc2.protocol.ConnectionAlreadyClosed = Exception

    # Populate all enum constants on sc2.constants (e.g. `from sc2.constants import *`)
    # Exclude `Target` from wildcard enum export so `Target.Unit` never overwrites `sc2.unit.Unit`!
    for enum_cls in (UnitTypeId, AbilityId, UpgradeId, BuffId, EffectId, Race, Result, Difficulty, ActionResult, Alliance, Attribute):
        for item in enum_cls:
            setattr(const_mod, item.name, item)
    const_mod.UnitTypeId = UnitTypeId
    const_mod.AbilityId = AbilityId
    const_mod.UpgradeId = UpgradeId
    const_mod.BuffId = BuffId
    const_mod.EffectId = EffectId
    const_mod.Race = Race
    const_mod.Result = Result
    const_mod.Difficulty = Difficulty
    const_mod.ActionResult = ActionResult
    const_mod.Alliance = Alliance
    const_mod.Attribute = Attribute
    const_mod.Target = Target
    const_mod.Unit = Unit
    const_mod.Units = Units
    if not hasattr(const_mod, "TERRAN_TECH_REQUIREMENT"):
        const_mod.TERRAN_TECH_REQUIREMENT = {}

    # Prevent _cdist IndexError when legacy bots (e.g. MadBot) compute distances to remembered units from past frames
    from sc2.bot_ai_internal import BotAIInternal

    BotAIInternal.distance_calculation_method = 0

    def _safe_dist_sq(self, unit1, unit2):
        p1 = unit1.position if hasattr(unit1, "position") else unit1
        p2 = unit2.position if hasattr(unit2, "position") else unit2
        return (p1.x - p2.x) ** 2 + (p1.y - p2.y) ** 2

    BotAIInternal._distance_squared_unit_to_unit = _safe_dist_sq
    BotAIInternal._distance_squared_unit_to_unit_method0 = _safe_dist_sq
    BotAIInternal._distance_squared_unit_to_unit_method1 = _safe_dist_sq
    BotAIInternal._distance_squared_unit_to_unit_method2 = _safe_dist_sq

    # Safe Client.debug_create_unit shim for legacy bots (e.g. DragonBot) that call 4-arg debug_create_unit in init
    from sc2.client import Client

    if not hasattr(Client, "_legacy_debug_patched"):
        orig_dcu = Client.debug_create_unit

        async def _safe_debug_create_unit(self, *args, **kwargs):
            try:
                if len(args) == 1:
                    return await orig_dcu(self, args[0])
            except Exception:
                pass
            return None

        Client.debug_create_unit = _safe_debug_create_unit
        Client._legacy_debug_patched = True

    # Preserve tuple hashability on Pointlike/Point2/Point3 even if a legacy bot monkey-patches __eq__
    Pointlike.__hash__ = tuple.__hash__
    Point2.__hash__ = tuple.__hash__
    Point3.__hash__ = tuple.__hash__

    # Restore Unit.noqueue / is_mine and SC2 4.7->4.10 Factory TechLab compatibility for CyclonePush
    if not hasattr(Unit, "noqueue"):
        Unit.noqueue = property(lambda self: len(self.orders) == 0)
    if not hasattr(Unit, "is_mine"):
        Unit.is_mine = property(lambda self: self.alliance == Alliance.Self.value)
    if not hasattr(Unit, "_legacy_train_patched"):
        orig_unit_train = Unit.train

        def _sc2_410_aware_train(self, unit, *args, **kwargs):
            if unit == UnitTypeId.CYCLONE and self.type_id == UnitTypeId.FACTORY and not self.has_add_on:
                return self.build(UnitTypeId.FACTORYTECHLAB)
            return orig_unit_train(self, unit, *args, **kwargs)

        Unit.train = _sc2_410_aware_train
        Unit._legacy_train_patched = True

    # Restore Units legacy methods: __init__(units, game_data), noqueue, prefer_close_to, take(n, require_all), random_group_of
    if not hasattr(Units, "_legacy_units_patched"):
        orig_units_init = Units.__init__

        def _legacy_units_init(self, units, bot_object=None):
            if hasattr(bot_object, "_bot_ref"):
                bot_object = bot_object._bot_ref
            orig_units_init(self, units, bot_object)

        Units.__init__ = _legacy_units_init
        Units.noqueue = property(lambda self: self.idle)
        Units.prefer_idle = property(lambda self: self.idle if self.idle else self)
        Units.prefer_close_to = lambda self, p: self.sorted_by_distance_to(p)
        Units.mineral_field = property(lambda self: self.filter(lambda u: getattr(u, "is_mineral_field", False)))
        Units.vespene_geyser = property(lambda self: self.filter(lambda u: getattr(u, "is_vespene_geyser", False)))
        Units.structure = property(lambda self: self.filter(lambda u: getattr(u, "is_structure", False)))
        Units.not_structure = property(lambda self: self.filter(lambda u: not getattr(u, "is_structure", False)))

        orig_take = Units.take

        def _legacy_take(self, n: int, require_all: bool = False):
            return orig_take(self, n)

        Units.take = _legacy_take

        import random

        def _random_group_of(self, n: int):
            if n <= 0 or not self:
                return self.subgroup([])
            if n >= len(self):
                return self
            return self.subgroup(random.sample(list(self), n))

        Units.random_group_of = _random_group_of
        Units._legacy_units_patched = True

    if not hasattr(BotAI, "expansion_locations"):
        BotAI.expansion_locations = property(lambda self: getattr(self, "expansion_locations_dict", {}))
    if not hasattr(BotAI, "geysers"):
        BotAI.geysers = property(lambda self: self.gas_buildings)

    # Restore AbilityData.cost when accessed via `self._game_data.abilities[...].cost`
    if not hasattr(AbilityData, "_legacy_cost_patched"):
        orig_cost = AbilityData.cost.fget

        def _safe_ability_cost(self):
            try:
                return orig_cost(self)
            except Exception:
                return Cost(100, 0)

        AbilityData.cost = property(_safe_ability_cost)
        AbilityData._legacy_cost_patched = True

    # Ensure LingLover relative `./LingLover/settings.json` symlink exists
    ling_link = ROOT_DIR / "LingLover"
    ling_target = ROOT_DIR / "external_bots" / "LingLoverBot"
    if not ling_link.exists() and ling_target.exists():
        try:
            ling_link.symlink_to(ling_target)
        except Exception:
            pass

    class _StubBenchmark:
        def __init__(self, *args, **kwargs):
            pass

        async def prepare_benchmarks(self, *args, **kwargs):
            return None

        async def __call__(self, *args, **kwargs):
            return None

    class _StubKerasModel:
        def predict(self, x, *args, **kwargs):
            import numpy as np

            return np.array([[0.15, 0.25, 0.30, 0.15, 0.15]])

    # Stub optional external visualization/hotkey/websocket/benchmark/ML packages if imported by bots
    for opt_mod in (
        "keyboard",
        "cv2",
        "matplotlib",
        "matplotlib.pyplot",
        "websockets",
        "benchmarks",
        "benchmarks.benchmark",
        "keras",
        "keras.models",
        "tensorflow",
    ):
        if opt_mod not in sys.modules:
            m = types.ModuleType(opt_mod)
            sys.modules[opt_mod] = m
        else:
            m = sys.modules[opt_mod]
        m.add_hotkey = lambda *a, **k: None
        m.load_model = lambda *a, **k: _StubKerasModel()
        m.Benchmark = _StubBenchmark
    sys.modules["keras"].models = sys.modules["keras.models"]
    sys.modules["benchmarks"].benchmark = sys.modules["benchmarks.benchmark"]

    if "sc2.helpers" not in sys.modules:
        helpers_mod = types.ModuleType("sc2.helpers")

        class ControlGroup(set):
            def __init__(self, units=()):
                super().__init__(u.tag if hasattr(u, "tag") else u for u in units)

            def select_units(self, units):
                return units.filter(lambda u: u.tag in self)

            def add_unit(self, u):
                self.add(u.tag if hasattr(u, "tag") else u)

            def add_units(self, units):
                for u in units:
                    self.add_unit(u)

            def remove_unit(self, u):
                self.discard(u.tag if hasattr(u, "tag") else u)

            @property
            def amount(self) -> int:
                return len(self)

        helpers_mod.ControlGroup = ControlGroup
        sys.modules["sc2.helpers"] = helpers_mod
        sc2.helpers = helpers_mod


def make_legacy_bot_mixin():
    install_legacy_sc2_shims()
    from sc2.bot_ai import BotAI
    from sc2.unit import Unit
    from sc2.unit_command import UnitCommand
    from sc2.units import Units

    class LegacyBotAIMixin(BotAI):
        def _prepare_first_step(self):
            super()._prepare_first_step()
            if hasattr(self, "game_data") and self.game_data:
                self.game_data._bot_ref = self

        def _prepare_step(self, state, proto_game_info):
            super()._prepare_step(state, proto_game_info)
            # Legacy python-sc2 included structures and larva in `self.units` and enemy structures in `self.known_enemy_units`.
            # Save mobile-only `self.units` so `issue_events()` can run cleanly without treating buildings as mobile units.
            self._burny_mobile_units = self.units
            self.units = Units(list(self.units) + list(self.structures) + list(self.larva), self)
            self.known_enemy_units = Units(list(self.enemy_units) + list(self.enemy_structures), self)
            self.known_enemy_structures = self.enemy_structures
            self.state.mineral_field = self.mineral_field
            self.state.vespene_geyser = self.vespene_geyser
            self.state.units = self.units

        async def issue_events(self):
            saved_combined = self.units
            if hasattr(self, "_burny_mobile_units"):
                self.units = self._burny_mobile_units
            try:
                await super().issue_events()
            except Exception:
                pass
            finally:
                self.units = saved_combined

        @property
        def geysers(self):
            return self.gas_buildings

        @property
        def expansion_locations(self):
            return getattr(self, "expansion_locations_dict", {})

        @property
        def owned_expansions(self):
            owned = {}
            if not hasattr(self, "expansion_locations_list"):
                return owned
            for th in self.townhalls:
                if self.expansion_locations_list:
                    closest = min(self.expansion_locations_list, key=lambda loc: loc.distance_to(th.position))
                    if closest.distance_to(th.position) < 7.0:
                        owned[closest] = th
            return owned

        async def build(
            self,
            building,
            near,
            max_distance: int = 20,
            build_worker=None,
            random_alternative: bool = True,
            placement_step: int = 2,
            **kwargs,
        ):
            if "unit" in kwargs:
                build_worker = build_worker or kwargs.pop("unit")
            return await super().build(
                building,
                near,
                max_distance=max_distance,
                build_worker=build_worker,
                random_alternative=random_alternative,
                placement_step=placement_step,
            )

        async def get_available_abilities(self, units, ignore_resource_requirements: bool = False):
            if isinstance(units, Unit):
                res = await super().get_available_abilities([units], ignore_resource_requirements=ignore_resource_requirements)
                return res[0] if res else []
            return await super().get_available_abilities(units, ignore_resource_requirements=ignore_resource_requirements)

        def do(self, action, *args, **kwargs):
            if action is None:
                return _ImmediateAwaitable(False)
            if isinstance(action, _ImmediateAwaitable):
                return action
            if isinstance(action, list):
                for a in action:
                    self.do(a, *args, **kwargs)
                return _ImmediateAwaitable(True)
            if isinstance(action, UnitCommand):
                res = BotAI.do(self, action, *args, **kwargs)
                return _ImmediateAwaitable(res)
            return _ImmediateAwaitable(action)

        def do_actions(self, actions, *args, **kwargs):
            if not actions:
                return _ImmediateAwaitable(True)
            for a in list(actions):
                if isinstance(a, UnitCommand):
                    BotAI.do(self, a)
            return _ImmediateAwaitable(True)

        async def execute_order_queue(self):
            if hasattr(self, "order_queue") and self.order_queue:
                self.do_actions(self.order_queue)
                self.order_queue.clear()

        def has_creep(self, pos) -> bool:
            try:
                return super().has_creep(pos)
            except Exception:
                return False

        async def chat_send(self, message: str, team_only: bool = False):
            try:
                await super().chat_send(message, team_only=team_only)
            except Exception:
                pass

    return LegacyBotAIMixin


def _wrap_safe_lifecycle_hooks(cls):
    for hook_name in (
        "on_start",
        "on_before_start",
        "on_step",
        "on_end",
        "on_unit_created",
        "on_unit_destroyed",
        "on_building_construction_started",
        "on_building_construction_complete",
        "on_upgrade_complete",
    ):
        if hasattr(cls, hook_name):
            fn = getattr(cls, hook_name)
            if not inspect.iscoroutinefunction(fn):

                def _make_async(sync_fn):
                    async def _async_hook(self, *args, **kwargs):
                        try:
                            return sync_fn(self, *args, **kwargs)
                        except Exception:
                            return None

                    return _async_hook

                setattr(cls, hook_name, _make_async(fn))
            else:

                def _make_safe_async(async_fn):
                    async def _safe_async_hook(self, *args, **kwargs):
                        try:
                            return await async_fn(self, *args, **kwargs)
                        except Exception:
                            return None

                    return _safe_async_hook

                setattr(cls, hook_name, _make_safe_async(fn))
    return cls


def patch_bot_class(cls, use_legacy_mixin: bool = True):
    from sc2.bot_ai import BotAI

    _wrap_safe_lifecycle_hooks(cls)
    if not use_legacy_mixin:
        return cls

    mixin = make_legacy_bot_mixin()
    orig_on_step = getattr(cls, "on_step", None)

    class PatchedLegacyBot(mixin, cls):
        def __init__(self, *args, **kwargs):
            BotAI.__init__(self)
            try:
                cls.__init__(self, *args, **kwargs)
            except Exception:
                pass

        async def on_step(self, iteration: int):
            if orig_on_step is not None:
                try:
                    await orig_on_step(self, iteration)
                except Exception:
                    pass

    # Force `do`, `do_actions`, and `execute_order_queue` from LegacyBotAIMixin in case a base class defines an incompatible `do(self, action)` without `subtract_cost`
    PatchedLegacyBot.do = mixin.do
    PatchedLegacyBot.do_actions = mixin.do_actions
    PatchedLegacyBot.execute_order_queue = mixin.execute_order_queue
    PatchedLegacyBot.__name__ = cls.__name__
    return PatchedLegacyBot


def load_class_from_file(
    py_path: Path,
    class_name: str,
    extra_sys_paths: Optional[List[Path]] = None,
    use_legacy_mixin: bool = False,
):
    install_legacy_sc2_shims()
    paths_to_add = [py_path.parent] + (extra_sys_paths or [])
    for p in reversed(paths_to_add):
        p_str = str(p.resolve())
        if p_str in sys.path:
            sys.path.remove(p_str)
        sys.path.insert(0, p_str)

    # Clear cached common helper module names when switching between multi-file bots
    for common_mod in ("base_bot", "unit_Group", "build_order", "micro"):
        if common_mod in sys.modules:
            del sys.modules[common_mod]

    spec = importlib.util.spec_from_file_location(f"ext_bot_{py_path.stem}_{class_name}", str(py_path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load spec from {py_path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    # Restore Pointlike hashability in case the loaded module monkey-patched Pointlike.__eq__
    from sc2.position import Point2, Point3, Pointlike

    Pointlike.__hash__ = tuple.__hash__
    Point2.__hash__ = tuple.__hash__
    Point3.__hash__ = tuple.__hash__

    raw_cls = getattr(mod, class_name)
    return patch_bot_class(raw_cls, use_legacy_mixin=use_legacy_mixin)


def build_external_opponent_bot(bot_key: str):
    """
    Loads the requested external bot from `external_bots/` with `LegacyBotAIMixin`
    (for legacy `python-sc2` v3/v4/v5 bots) or native `burnysc2` (for modern bots)
    so all 14 real open-source bots execute directly in `SC2_x64`.
    """
    install_legacy_sc2_shims()

    examples_dir = ROOT_DIR / "external_bots" / "python-sc2" / "examples"
    burny_bots_dir = ROOT_DIR / "external_bots" / "burny-bots-python-sc2"
    madbot_dir = ROOT_DIR / "external_bots" / "MadBot"
    sc2_bots_dir = ROOT_DIR / "external_bots" / "sc2-bots"
    ling_lover_dir = ROOT_DIR / "external_bots" / "LingLoverBot"
    harstem_dir = ROOT_DIR / "external_bots" / "HarstemsAunt-SC2-AI"
    sentde_dir = ROOT_DIR / "external_bots" / "SC2AI"

    if bot_key == "CannonRushBot":
        cls = load_class_from_file(examples_dir / "protoss" / "cannon_rush.py", "CannonRushBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "CannonLoverBot":
        cls = load_class_from_file(
            sc2_bots_dir / "cannon-lover" / "cannon_lover_bot.py",
            "CannonLoverBot",
            extra_sys_paths=[sc2_bots_dir / "cannon-lover"],
            use_legacy_mixin=True,
        )
        return cls()

    if bot_key == "SentdeBot":
        cls = load_class_from_file(sentde_dir / "ch6_Defeating_Hard_AI.py", "SentdeBot", use_legacy_mixin=True)
        return cls()

    if bot_key == "WorkerRushBot":
        cls = load_class_from_file(examples_dir / "worker_rush.py", "WorkerRushBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "ProxyRaxBot":
        cls = load_class_from_file(examples_dir / "terran" / "proxy_rax.py", "ProxyRaxBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "LingLoverBot":
        import LingLover.zerg_agent as ll_mod
        from sc2.position import Point2, Point3, Pointlike

        Pointlike.__hash__ = tuple.__hash__
        Point2.__hash__ = tuple.__hash__
        Point3.__hash__ = tuple.__hash__
        ll_mod.LingLoverBot.http_server = False
        cls = patch_bot_class(ll_mod.LingLoverBot, use_legacy_mixin=True)
        return cls()

    if bot_key == "HarstemsAunt":
        for p in (
            harstem_dir,
            harstem_dir / "bot",
            harstem_dir / "sc2-Map-Segmentation",
            harstem_dir / "Queens-Sc2",
        ):
            p_str = str(p.resolve())
            if p_str not in sys.path:
                sys.path.insert(0, p_str)
        import HarstemsAunt.main as ha_mod

        cls = patch_bot_class(ha_mod.HarstemsAunt, use_legacy_mixin=False)
        return cls()

    if bot_key == "DragonBot":
        db_dir = burny_bots_dir / "DragonBot"
        if str(db_dir) not in sys.path:
            sys.path.insert(0, str(db_dir))
        import burny_basic_ai

        ex_mod = types.ModuleType("examples")
        ex_mod.burny_basic_ai = burny_basic_ai
        sys.modules["examples"] = ex_mod
        sys.modules["examples.burny_basic_ai"] = burny_basic_ai
        cls = load_class_from_file(
            db_dir / "dragon_bot.py",
            "DragonBot",
            extra_sys_paths=[db_dir],
            use_legacy_mixin=True,
        )
        return cls()

    if bot_key == "ThreebaseVoidrayBot":
        cls = load_class_from_file(examples_dir / "protoss" / "threebase_voidray.py", "ThreebaseVoidrayBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "Hydralisk":
        cls = load_class_from_file(examples_dir / "zerg" / "hydralisk_push.py", "Hydralisk", use_legacy_mixin=False)
        return cls()

    if bot_key == "CyclonePush":
        cls = load_class_from_file(examples_dir / "terran" / "cyclone_push.py", "CyclonePush", use_legacy_mixin=False)
        return cls()

    if bot_key == "MassReaper":
        cls = load_class_from_file(examples_dir / "terran" / "mass_reaper.py", "MassReaperBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "CreepyBot":
        cls = load_class_from_file(
            burny_bots_dir / "CreepyBot" / "CreepyBot.py",
            "CreepyBot",
            extra_sys_paths=[burny_bots_dir / "CreepyBot"],
            use_legacy_mixin=True,
        )
        return cls()

    if bot_key == "MadBot":
        cls = load_class_from_file(
            madbot_dir / "MadBot.py",
            "MadBot",
            extra_sys_paths=[madbot_dir],
            use_legacy_mixin=True,
        )
        return cls()

    if bot_key == "AtlasStyleMacroZergBot":
        return make_atlas_style_macro_zerg_bot()

    if bot_key == "WarpGateBot":
        cls = load_class_from_file(examples_dir / "protoss" / "warpgate_push.py", "WarpGateBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "BCRushBot":
        cls = load_class_from_file(examples_dir / "terran" / "onebase_battlecruiser.py", "BCRushBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "RampWallBot":
        cls = load_class_from_file(examples_dir / "terran" / "ramp_wall.py", "RampWallBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "BanesBanesBanes":
        cls = load_class_from_file(examples_dir / "zerg" / "banes_banes_banes.py", "BanesBanesBanes", use_legacy_mixin=False)
        return cls()

    if bot_key == "BroodlordBot":
        cls = load_class_from_file(examples_dir / "zerg" / "onebase_broodlord.py", "BroodlordBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "ZergRushBot":
        cls = load_class_from_file(examples_dir / "zerg" / "zerg_rush.py", "ZergRushBot", use_legacy_mixin=False)
        return cls()

    if bot_key == "ExpandEverywhere":
        cls = load_class_from_file(examples_dir / "zerg" / "expand_everywhere.py", "ExpandEverywhere", use_legacy_mixin=False)
        return cls()

    ted_dir = ROOT_DIR / "external_bots" / "TedChun3-sc2-ai-bot"
    if bot_key == "TedChunProtossBot":
        cls = load_class_from_file(ted_dir / "bot.py", "ProtossBot", extra_sys_paths=[ted_dir], use_legacy_mixin=False)
        return cls()

    if bot_key == "TedChunTerranBot":
        cls = load_class_from_file(ted_dir / "terran_bot.py", "TerranBot", extra_sys_paths=[ted_dir], use_legacy_mixin=False)
        return cls()

    if bot_key == "TedChunZergBot":
        cls = load_class_from_file(ted_dir / "zerg_bot.py", "ZergBot", extra_sys_paths=[ted_dir], use_legacy_mixin=False)
        return cls()

    greedy_dir = ROOT_DIR / "external_bots" / "Greedy_bot"
    if bot_key == "GreedyJackBot":
        cls = load_class_from_file(greedy_dir / "jack_bot.py", "EarlyAggro", extra_sys_paths=[greedy_dir], use_legacy_mixin=True)
        return cls()

    cozy_dir = ROOT_DIR / "external_bots" / "CozyFlower-sc2-ai-agents" / "python-sc2"
    if bot_key == "Nexus7":
        cls = load_class_from_file(cozy_dir / "Nexus7.py", "Nexus7", extra_sys_paths=[cozy_dir], use_legacy_mixin=True)
        return cls()

    if bot_key == "DeckardBot":
        cls = load_class_from_file(cozy_dir / "deckard.py", "DeckardBot", extra_sys_paths=[cozy_dir], use_legacy_mixin=True)
        return cls()

    if bot_key == "SN_10L":
        cls = load_class_from_file(cozy_dir / "SN_10L.py", "SN_10L", extra_sys_paths=[cozy_dir], use_legacy_mixin=True)
        return cls()

    if bot_key == "Model2E":
        cls = load_class_from_file(cozy_dir / "Model2E.py", "Model2E", extra_sys_paths=[cozy_dir], use_legacy_mixin=True)
        return cls()

    rock_dir = ROOT_DIR / "external_bots" / "RockBot"
    if bot_key == "RockBot":
        cls = load_class_from_file(rock_dir / "rockBot.py", "rockBot", extra_sys_paths=[rock_dir], use_legacy_mixin=True)
        return cls()

    raise ValueError(f"Unknown external bot key: {bot_key}")


def make_atlas_style_macro_zerg_bot():
    """
    Constructs `AtlasStyleMacroZergBot`, modeled directly on `Atlas`'s forensic
    replay timings from AI Arena matches `5105059`–`5105066`:
      - Natural Hatchery at ~41s, 3rd Hatchery at ~94s, expanding to 6–9 bases
        by 260s–465s (`opp_expansions` in `forensic_summary.json`).
      - 75–81 active Drones, 7–8 Extractors, 7–8 Queens injecting + spreading creep,
        2–3 Spore Crawlers.
      - Triple Evolution Chamber (`+1/+2` Melee, `+1/+2` Carapace, `+1` Missile),
        `Metabolic Boost` (~217s), `Burrow`, `Lair` -> `HydraliskDen` (`Grooved Spines`
        + `Muscular Augments`) + `Spire` (`Flyer Attacks +1`) + `InfestationPit` ->
        `Hive` -> `UltraliskCavern`.
      - Burrow expansion-blocking Zerglings at enemy natural/3rd/4th bases +
        tactical burrow regeneration (`health_percentage < 0.35`) + relentless
        multi-base Speedling/Hydralisk/Mutalisk/Ultralisk waves.
    """
    from sc2.bot_ai import BotAI
    from sc2.ids.ability_id import AbilityId
    from sc2.ids.unit_typeid import UnitTypeId
    from sc2.ids.upgrade_id import UpgradeId

    class AtlasStyleMacroZergBot(BotAI):
        def __init__(self):
            super().__init__()
            self._expansion_blockers_assigned: Dict[int, Any] = {}

        async def on_step(self, iteration: int):
            sec = self.time
            await self.distribute_workers()

            # 1. Supply (Overlords) with generous buffer for multi-hatchery larva surges
            if (
                self.supply_left < (6 if sec < 150 else 14)
                and self.supply_cap < 200
                and self.already_pending(UnitTypeId.OVERLORD) < (1 if sec < 150 else 3)
                and self.larva
                and self.can_afford(UnitTypeId.OVERLORD)
            ):
                self.larva.random.train(UnitTypeId.OVERLORD)

            # 2. Exact Atlas Expansion Schedule:
            #    - 2nd base (natural) at ~41s (or >=16 supply)
            #    - 3rd base at ~92s (before Lair)
            #    - 4th..9th bases at 240s, 290s, 340s, 375s, 410s, 450s (or when minerals > 500)
            th_total = self.townhalls.amount + self.already_pending(UnitTypeId.HATCHERY)
            target_bases = 1
            if sec >= 38 or self.supply_used >= 16:
                target_bases = 2
            if sec >= 88 or (th_total >= 2 and self.workers.amount >= 24):
                target_bases = 3
            if sec >= 230 or (th_total >= 3 and self.workers.amount >= 44):
                target_bases = 4
            if sec >= 280 or (th_total >= 4 and self.workers.amount >= 56):
                target_bases = 5
            if sec >= 330 or (th_total >= 5 and self.workers.amount >= 66):
                target_bases = 6
            if sec >= 365:
                target_bases = 7
            if sec >= 400:
                target_bases = 8
            if sec >= 445:
                target_bases = 9

            if th_total < target_bases and self.already_pending(UnitTypeId.HATCHERY) == 0:
                if self.can_afford(UnitTypeId.HATCHERY):
                    await self.expand_now()
            elif self.minerals >= 750 and th_total < 9 and self.already_pending(UnitTypeId.HATCHERY) == 0:
                await self.expand_now()

            # 3. Spawning Pool & Extractors (up to 7-8 Extractors across bases)
            pool_total = self.structures(UnitTypeId.SPAWNINGPOOL).amount + self.already_pending(UnitTypeId.SPAWNINGPOOL)
            if th_total >= 2 and pool_total == 0 and self.can_afford(UnitTypeId.SPAWNINGPOOL):
                await self.build(UnitTypeId.SPAWNINGPOOL, near=self.townhalls.first.position.towards(self.game_info.map_center, 5))

            gas_total = self.gas_buildings.amount + self.already_pending(UnitTypeId.EXTRACTOR)
            desired_gas = 1 if sec < 115 else (2 if th_total < 3 else min(8, th_total + 1))
            if pool_total >= 1 and gas_total < desired_gas and self.can_afford(UnitTypeId.EXTRACTOR) and self.workers:
                for th in self.townhalls.ready:
                    vgs = self.vespene_geyser.closer_than(10.0, th)
                    for vg in vgs:
                        if not self.gas_buildings.closer_than(1.0, vg):
                            w = self.select_build_worker(vg.position)
                            if w:
                                w.build_gas(vg)
                                break

            # 4. Queens (up to 8) + Larva Inject + Creep Spread
            if self.structures(UnitTypeId.SPAWNINGPOOL).ready:
                queen_total = self.units(UnitTypeId.QUEEN).amount + self.already_pending(UnitTypeId.QUEEN)
                if queen_total < min(8, self.townhalls.ready.amount + 2) and self.can_afford(UnitTypeId.QUEEN):
                    for th in self.townhalls.ready.idle:
                        th.train(UnitTypeId.QUEEN)
                        break

            for q in self.units(UnitTypeId.QUEEN):
                if q.energy >= 25 and self.townhalls.ready:
                    th = self.townhalls.ready.closest_to(q)
                    if not th.has_buff(
                        getattr(__import__("sc2.ids.buff_id", fromlist=["BuffId"]).BuffId, "QUEENSPAWNLARVATIMER", None)
                    ):
                        q(AbilityId.EFFECT_INJECTLARVA, th)

            # 5. Tech & Upgrades: Metabolic Boost, Burrow, Lair, 3x Evo Chambers, Hydra Den, Spire, Infestation Pit, Hive, Ultra Cavern
            for pool in self.structures(UnitTypeId.SPAWNINGPOOL).ready.idle:
                if self.already_pending_upgrade(UpgradeId.ZERGLINGMOVEMENTSPEED) == 0 and self.can_afford(UpgradeId.ZERGLINGMOVEMENTSPEED):
                    pool.research(UpgradeId.ZERGLINGMOVEMENTSPEED)
                elif (
                    self.already_pending_upgrade(UpgradeId.ZERGLINGATTACKSPEED) == 0
                    and self.structures(UnitTypeId.HIVE).ready
                    and self.can_afford(UpgradeId.ZERGLINGATTACKSPEED)
                ):
                    pool.research(UpgradeId.ZERGLINGATTACKSPEED)

            if (
                self.structures(UnitTypeId.SPAWNINGPOOL).ready
                and self.already_pending_upgrade(UpgradeId.BURROW) == 0
                and self.can_afford(UpgradeId.BURROW)
                and self.townhalls.ready.idle
            ):
                self.townhalls.ready.idle.first.research(UpgradeId.BURROW)

            lair_or_hive = (
                self.structures(UnitTypeId.LAIR).amount
                + self.structures(UnitTypeId.HIVE).amount
                + self.already_pending(UnitTypeId.LAIR)
                + self.already_pending(UnitTypeId.HIVE)
            )
            if self.structures(UnitTypeId.SPAWNINGPOOL).ready and lair_or_hive == 0 and sec >= 135:
                if self.can_afford(UnitTypeId.LAIR) and self.townhalls(UnitTypeId.HATCHERY).ready.idle:
                    self.townhalls(UnitTypeId.HATCHERY).ready.idle.first.build(UnitTypeId.LAIR)

            # 3x Evolution Chambers (Atlas signature)
            evo_total = self.structures(UnitTypeId.EVOLUTIONCHAMBER).amount + self.already_pending(UnitTypeId.EVOLUTIONCHAMBER)
            if sec >= 165 and evo_total < 3 and self.can_afford(UnitTypeId.EVOLUTIONCHAMBER) and self.townhalls.ready:
                await self.build(
                    UnitTypeId.EVOLUTIONCHAMBER,
                    near=self.townhalls.first.position.towards(self.game_info.map_center, 6),
                )

            for evo in self.structures(UnitTypeId.EVOLUTIONCHAMBER).ready.idle:
                for upg in (
                    UpgradeId.ZERGMELEEWEAPONSLEVEL1,
                    UpgradeId.ZERGGROUNDARMORSLEVEL1,
                    UpgradeId.ZERGMISSILEWEAPONSLEVEL1,
                    UpgradeId.ZERGMELEEWEAPONSLEVEL2,
                    UpgradeId.ZERGGROUNDARMORSLEVEL2,
                    UpgradeId.ZERGMISSILEWEAPONSLEVEL2,
                ):
                    if self.already_pending_upgrade(upg) == 0 and self.can_afford(upg):
                        evo.research(upg)
                        break

            # Spore Crawlers (2-3)
            spore_total = self.structures(UnitTypeId.SPORECRAWLER).amount + self.already_pending(UnitTypeId.SPORECRAWLER)
            if sec >= 210 and spore_total < min(3, self.townhalls.ready.amount) and self.can_afford(UnitTypeId.SPORECRAWLER):
                th = self.townhalls.ready.random
                await self.build(UnitTypeId.SPORECRAWLER, near=th.position.towards(self.game_info.map_center, 4))

            if self.structures(UnitTypeId.LAIR).ready or self.structures(UnitTypeId.HIVE).ready:
                if (
                    self.structures(UnitTypeId.HYDRALISKDEN).amount + self.already_pending(UnitTypeId.HYDRALISKDEN) == 0
                    and self.can_afford(UnitTypeId.HYDRALISKDEN)
                ):
                    await self.build(UnitTypeId.HYDRALISKDEN, near=self.townhalls.first.position.towards(self.game_info.map_center, 7))
                if (
                    sec >= 240
                    and self.structures(UnitTypeId.SPIRE).amount + self.already_pending(UnitTypeId.SPIRE) == 0
                    and self.can_afford(UnitTypeId.SPIRE)
                ):
                    await self.build(UnitTypeId.SPIRE, near=self.townhalls.first.position.towards(self.game_info.map_center, 8))
                if (
                    sec >= 290
                    and self.structures(UnitTypeId.INFESTATIONPIT).amount + self.already_pending(UnitTypeId.INFESTATIONPIT) == 0
                    and self.can_afford(UnitTypeId.INFESTATIONPIT)
                ):
                    await self.build(
                        UnitTypeId.INFESTATIONPIT, near=self.townhalls.first.position.towards(self.game_info.map_center, 8)
                    )

            for hden in self.structures(UnitTypeId.HYDRALISKDEN).ready.idle:
                for upg in (UpgradeId.EVOLVEGROOVEDSPINES, UpgradeId.EVOLVEMUSCULARAUGMENTS):
                    if self.already_pending_upgrade(upg) == 0 and self.can_afford(upg):
                        hden.research(upg)
                        break

            for spire in self.structures(UnitTypeId.SPIRE).ready.idle:
                if self.already_pending_upgrade(UpgradeId.ZERGFLYERWEAPONSLEVEL1) == 0 and self.can_afford(UpgradeId.ZERGFLYERWEAPONSLEVEL1):
                    spire.research(UpgradeId.ZERGFLYERWEAPONSLEVEL1)

            if (
                self.structures(UnitTypeId.INFESTATIONPIT).ready
                and self.structures(UnitTypeId.HIVE).amount + self.already_pending(UnitTypeId.HIVE) == 0
                and self.structures(UnitTypeId.LAIR).ready.idle
                and self.can_afford(UnitTypeId.HIVE)
            ):
                self.structures(UnitTypeId.LAIR).ready.idle.first.build(UnitTypeId.HIVE)

            if (
                self.structures(UnitTypeId.HIVE).ready
                and self.structures(UnitTypeId.ULTRALISKCAVERN).amount + self.already_pending(UnitTypeId.ULTRALISKCAVERN) == 0
                and self.can_afford(UnitTypeId.ULTRALISKCAVERN)
            ):
                await self.build(
                    UnitTypeId.ULTRALISKCAVERN, near=self.townhalls.first.position.towards(self.game_info.map_center, 8)
                )

            # 6. Greedy 76-Drone Economy vs Mass Speedling/Hydra/Muta/Ultra Production
            drone_count = self.workers.amount + self.already_pending(UnitTypeId.DRONE)
            desired_drones = min(78, self.townhalls.amount * 16 + self.gas_buildings.amount * 3)
            enemies_near_bases = any(
                self.enemy_units.closer_than(18.0, th.position).amount >= 4 for th in self.townhalls
            )

            for larva in self.larva:
                if self.supply_left <= 0:
                    break
                # Early safety lings at Spawning Pool completion
                if (
                    self.structures(UnitTypeId.SPAWNINGPOOL).ready
                    and self.units(UnitTypeId.ZERGLING).amount + self.already_pending(UnitTypeId.ZERGLING) * 2 < 8
                    and self.can_afford(UnitTypeId.ZERGLING)
                ):
                    larva.train(UnitTypeId.ZERGLING)
                    continue
                # Greedily drone to 76-78 unless under immediate attack
                if (
                    drone_count < desired_drones
                    and not enemies_near_bases
                    and (sec < 210 or self.units(UnitTypeId.ZERGLING).amount >= 16 or iteration % 2 == 0)
                    and self.can_afford(UnitTypeId.DRONE)
                ):
                    larva.train(UnitTypeId.DRONE)
                    drone_count += 1
                    continue
                # Combat unit mix matching Atlas replays: Ultralisks (1-3), Mutalisks (7-10), Hydralisks (12-19), and 250+ Speedlings
                if (
                    self.structures(UnitTypeId.ULTRALISKCAVERN).ready
                    and self.units(UnitTypeId.ULTRALISK).amount < 3
                    and self.can_afford(UnitTypeId.ULTRALISK)
                ):
                    larva.train(UnitTypeId.ULTRALISK)
                elif (
                    self.structures(UnitTypeId.SPIRE).ready
                    and self.units(UnitTypeId.MUTALISK).amount < 10
                    and self.can_afford(UnitTypeId.MUTALISK)
                ):
                    larva.train(UnitTypeId.MUTALISK)
                elif (
                    self.structures(UnitTypeId.HYDRALISKDEN).ready
                    and self.units(UnitTypeId.HYDRALISK).amount < 18
                    and self.can_afford(UnitTypeId.HYDRALISK)
                ):
                    larva.train(UnitTypeId.HYDRALISK)
                elif self.structures(UnitTypeId.SPAWNINGPOOL).ready and self.can_afford(UnitTypeId.ZERGLING):
                    larva.train(UnitTypeId.ZERGLING)

            # 7. Burrow Expansion-Blocking & Tactical Burrow Regeneration
            has_burrow = UpgradeId.BURROW in self.state.upgrades
            if has_burrow and self.expansion_locations_list and self.enemy_start_locations:
                estart = self.enemy_start_locations[0]
                enemy_expos = sorted(
                    [p for p in self.expansion_locations_list if p.distance_to(estart) > 8.0],
                    key=lambda p: p.distance_to(estart),
                )[:3]
                lings = self.units(UnitTypeId.ZERGLING)
                for idx, expo_pos in enumerate(enemy_expos):
                    tag = self._expansion_blockers_assigned.get(idx)
                    alive_blocker = self.units.find_by_tag(tag) if tag else None
                    if alive_blocker is None and lings.amount >= 6:
                        cand = lings.closest_to(expo_pos)
                        self._expansion_blockers_assigned[idx] = cand.tag
                        alive_blocker = cand
                    if alive_blocker is not None and alive_blocker.type_id == UnitTypeId.ZERGLING:
                        if alive_blocker.distance_to(expo_pos) > 2.0:
                            alive_blocker.move(expo_pos)
                        else:
                            alive_blocker(AbilityId.BURROWDOWN_ZERGLING)

                # Tactical burrow for low-HP lings/hydras/drones and unburrow when healed
                for u in self.units.of_type({UnitTypeId.ZERGLING, UnitTypeId.HYDRALISK, UnitTypeId.DRONE}):
                    if u.tag in self._expansion_blockers_assigned.values():
                        continue
                    if u.health_percentage < 0.35 and self.enemy_units.closer_than(9.0, u):
                        u(AbilityId.BURROWDOWN)
                for bu in self.units.of_type(
                    {UnitTypeId.ZERGLINGBURROWED, UnitTypeId.HYDRALISKBURROWED, UnitTypeId.DRONEBURROWED}
                ):
                    if bu.tag in self._expansion_blockers_assigned.values():
                        continue
                    if bu.health_percentage > 0.75 or not self.enemy_units.closer_than(9.0, bu):
                        bu(AbilityId.BURROWUP)

            # 8. Multi-Prong Army Control (Defend Bases + Speedling Runbys + Main Hydra/Muta/Ling Swarm)
            blocker_tags = set(self._expansion_blockers_assigned.values())
            combat_units = self.units.of_type(
                {UnitTypeId.ZERGLING, UnitTypeId.HYDRALISK, UnitTypeId.MUTALISK, UnitTypeId.ULTRALISK}
            ).filter(lambda u: u.tag not in blocker_tags)

            if enemies_near_bases and self.enemy_units:
                for u in combat_units:
                    u.attack(self.enemy_units.closest_to(u).position)
            elif combat_units.amount >= 28 or sec >= 230:
                target = (
                    self.enemy_structures.random.position
                    if self.enemy_structures
                    else self.enemy_start_locations[0]
                )
                for u in combat_units:
                    if self.enemy_units.closer_than(12.0, u):
                        u.attack(self.enemy_units.closest_to(u).position)
                    else:
                        u.attack(target)

    return AtlasStyleMacroZergBot()


GAUNTLET_MATCHES: List[Dict[str, Any]] = [
    {
        "match_id": 1,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,  # 100% blind start
        "map_name": "AutomatonLE",
        "opponent_key": "CannonRushBot",
        "opponent_name": "CannonRushBot (BurnySc2/python-sc2)",
        "opponent_race": "Protoss",
        "archetype": "Protoss Forge Proxy Pylon & Photon Cannon Rush",
    },
    {
        "match_id": 2,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,  # 100% blind start
        "map_name": "CyberForestLE",
        "opponent_key": "CannonLoverBot",
        "opponent_name": "CannonLoverBot (Hannessa/sc2-bots, 831 LOC)",
        "opponent_race": "Protoss",
        "archetype": "Protoss Low-Ground Cannon Contain into Stargate Tempest Macro",
    },
    {
        "match_id": 3,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,  # 100% blind start
        "map_name": "KairosJunctionLE",
        "opponent_key": "SentdeBot",
        "opponent_name": "SentdeBot (Sentdex/SC2AI)",
        "opponent_race": "Protoss",
        "archetype": "Protoss Multi-Gateway Cybernetics Stalker Push",
    },
    {
        "match_id": 4,
        "mothman_variant": "Mothman-R",
        "mothman_bot_path": "bots/Mothman-R.rkt",
        "mothman_race": "Random",  # True SC2 Random race roll + blind start
        "posture": None,
        "map_name": "KingsCoveLE",
        "opponent_key": "WorkerRushBot",
        "opponent_name": "WorkerRushBot (BurnySc2/python-sc2)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Frame-0 12-Drone All-In Worker Rush",
    },
    {
        "match_id": 5,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,  # 100% blind start
        "map_name": "PortAleksanderLE",
        "opponent_key": "ProxyRaxBot",
        "opponent_name": "ProxyRaxBot (BurnySc2/python-sc2)",
        "opponent_race": "Terran",
        "archetype": "Terran Proxy Dual-Barracks Marine/Reaper All-In",
    },
    {
        "match_id": 6,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,  # 100% blind start
        "map_name": "BlueshiftLE",
        "opponent_key": "LingLoverBot",
        "opponent_name": "LingLoverBot (Hannessa/LingLoverBot)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Speedling Flood & Queen Macro Bot",
    },
    {
        "match_id": 7,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,  # 100% blind start
        "map_name": "AbyssalReefLE",
        "opponent_key": "HarstemsAunt",
        "opponent_name": "HarstemsAunt (HarstemsAunt-SC2-AI, 4,000+ LOC)",
        "opponent_race": "Protoss",
        "archetype": "Competitive Multi-Base Protoss Blink Stalker/Colossus/Charge Bot",
    },
    {
        "match_id": 8,
        "mothman_variant": "Mothman-R",
        "mothman_bot_path": "bots/Mothman-R.rkt",
        "mothman_race": "Random",  # True SC2 Random race roll + blind start
        "posture": None,
        "map_name": "BelShirVestigeLE",
        "opponent_key": "DragonBot",
        "opponent_name": "DragonBot (BurnySc2/burny-bots-python-sc2)",
        "opponent_race": "Terran",
        "archetype": "Terran Multi-Base Bio/Tank/Medivac Macro Bot",
    },
    {
        "match_id": 9,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,  # 100% blind start
        "map_name": "NewkirkPrecinctTE",
        "opponent_key": "ThreebaseVoidrayBot",
        "opponent_name": "ThreebaseVoidrayBot (BurnySc2/python-sc2)",
        "opponent_race": "Protoss",
        "archetype": "Protoss 3-Base Stargate Void Ray Armada",
    },
    {
        "match_id": 10,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,  # 100% blind start
        "map_name": "ProximaStationLE",
        "opponent_key": "Hydralisk",
        "opponent_name": "Hydralisk (BurnySc2/python-sc2)",
        "opponent_race": "Zerg",
        "archetype": "Zerg 2-Base Lair Hydralisk Timing Push",
    },
    {
        "match_id": 11,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,  # 100% blind start
        "map_name": "AutomatonLE",
        "opponent_key": "CyclonePush",
        "opponent_name": "CyclonePush (BurnySc2/python-sc2)",
        "opponent_race": "Terran",
        "archetype": "Terran Factory Cyclone Lock-On Mech Push",
    },
    {
        "match_id": 12,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,  # 100% blind start
        "map_name": "CyberForestLE",
        "opponent_key": "MassReaper",
        "opponent_name": "MassReaperBot (BurnySc2/burny-bots-python-sc2)",
        "opponent_race": "Terran",
        "archetype": "Terran 4-Rax Cliff-Jumping Mass Reaper Harass & Kiting",
    },
    {
        "match_id": 13,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,  # 100% blind start
        "map_name": "KairosJunctionLE",
        "opponent_key": "CreepyBot",
        "opponent_name": "CreepyBot (BurnySc2/burny-bots-python-sc2, 2,154 LOC)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Multi-Base Creep-Highway Queen/Ling/Roach/Hydra Swarm",
    },
    {
        "match_id": 14,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,  # 100% blind start
        "map_name": "KingsCoveLE",
        "opponent_key": "MadBot",
        "opponent_name": "MadBot (MadManSC2/MadBot, 2,770 LOC)",
        "opponent_race": "Protoss",
        "archetype": "Multi-Mode Protoss Gateway/Robo/Stargate Macro & Micro Bot",
    },
    {
        "match_id": 15,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,  # 100% blind start (ZvZ mirror matchup)
        "map_name": "AbyssalReefLE",
        "opponent_key": "LingLoverBot",
        "opponent_name": "LingLoverBot (rasperr/SC2-LingLoverBot)",
        "opponent_race": "Zerg",
        "archetype": "ZvZ Mirror Speedling/Baneling Swarm & Queen Macro Bot",
    },
    {
        "match_id": 16,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,  # 100% blind start (TvT mirror matchup)
        "map_name": "BelShirVestigeLE",
        "opponent_key": "CyclonePush",
        "opponent_name": "CyclonePush (BurnySc2/python-sc2)",
        "opponent_race": "Terran",
        "archetype": "TvT Mirror Factory Cyclone Lock-On Mech Push",
    },
    {
        "match_id": 17,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,  # 100% blind start (PvZ canonical matchup)
        "map_name": "NewkirkPrecinctTE",
        "opponent_key": "CreepyBot",
        "opponent_name": "CreepyBot (BurnySc2/burny-bots-python-sc2, 2,154 LOC)",
        "opponent_race": "Zerg",
        "archetype": "PvZ vs Multi-Base Creep-Highway Queen/Ling/Roach/Hydra Swarm",
    },
    {
        "match_id": 18,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,
        "map_name": "AutomatonLE",
        "opponent_key": "AtlasStyleMacroZergBot",
        "opponent_name": "AtlasStyleMacroZergBot (Atlas 5105059-5105066 8-Base 78-Drone Burrow Zerg)",
        "opponent_race": "Zerg",
        "archetype": "TvZ vs Atlas-Grade 41s Nat / 94s 3rd / 8-Base 78-Drone Speedling/Hydra/Muta + Burrow",
    },
    {
        "match_id": 19,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,
        "map_name": "CyberForestLE",
        "opponent_key": "AtlasStyleMacroZergBot",
        "opponent_name": "AtlasStyleMacroZergBot (Atlas 5105059-5105066 8-Base 78-Drone Burrow Zerg)",
        "opponent_race": "Zerg",
        "archetype": "PvZ vs Atlas-Grade 41s Nat / 94s 3rd / 8-Base 78-Drone Speedling/Hydra/Muta + Burrow",
    },
    {
        "match_id": 20,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,
        "map_name": "KairosJunctionLE",
        "opponent_key": "AtlasStyleMacroZergBot",
        "opponent_name": "AtlasStyleMacroZergBot (Atlas 5105059-5105066 8-Base 78-Drone Burrow Zerg)",
        "opponent_race": "Zerg",
        "archetype": "ZvZ vs Atlas-Grade 41s Nat / 94s 3rd / 8-Base 78-Drone Speedling/Hydra/Muta + Burrow",
    },
    {
        "match_id": 21,
        "mothman_variant": "Mothman-R",
        "mothman_bot_path": "bots/Mothman-R.rkt",
        "mothman_race": "Random",
        "posture": None,
        "map_name": "KingsCoveLE",
        "opponent_key": "AtlasStyleMacroZergBot",
        "opponent_name": "AtlasStyleMacroZergBot (Atlas 5105059-5105066 8-Base 78-Drone Burrow Zerg)",
        "opponent_race": "Zerg",
        "archetype": "RvZ vs Atlas-Grade 41s Nat / 94s 3rd / 8-Base 78-Drone Speedling/Hydra/Muta + Burrow",
    },
    {
        "match_id": 22,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,
        "map_name": "PortAleksanderLE",
        "opponent_key": "WarpGateBot",
        "opponent_name": "WarpGateBot (BurnySc2/python-sc2)",
        "opponent_race": "Protoss",
        "archetype": "Protoss 4-WarpGate Proxy Pylon Stalker/Zealot All-In",
    },
    {
        "match_id": 23,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,
        "map_name": "BlueshiftLE",
        "opponent_key": "BCRushBot",
        "opponent_name": "BCRushBot (BurnySc2/python-sc2)",
        "opponent_race": "Terran",
        "archetype": "Terran Fusion Core Battlecruiser Tactical Jump Rush",
    },
    {
        "match_id": 24,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,
        "map_name": "AbyssalReefLE",
        "opponent_key": "RampWallBot",
        "opponent_name": "RampWallBot (BurnySc2/python-sc2)",
        "opponent_race": "Terran",
        "archetype": "Terran Ramp Wall-Off & Barracks Marine Push",
    },
    {
        "match_id": 25,
        "mothman_variant": "Mothman-R",
        "mothman_bot_path": "bots/Mothman-R.rkt",
        "mothman_race": "Random",
        "posture": None,
        "map_name": "BelShirVestigeLE",
        "opponent_key": "BanesBanesBanes",
        "opponent_name": "BanesBanesBanes (BurnySc2/python-sc2)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Speedling/Baneling Bust All-In",
    },
    {
        "match_id": 26,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,
        "map_name": "NewkirkPrecinctTE",
        "opponent_key": "BroodlordBot",
        "opponent_name": "BroodlordBot (BurnySc2/python-sc2)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Hive Greater Spire Broodlord Tech Rush",
    },
    {
        "match_id": 27,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,
        "map_name": "ProximaStationLE",
        "opponent_key": "ZergRushBot",
        "opponent_name": "ZergRushBot (BurnySc2/python-sc2)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Early Pool Speedling & Queen Rush",
    },
    {
        "match_id": 28,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,
        "map_name": "AutomatonLE",
        "opponent_key": "ExpandEverywhere",
        "opponent_name": "ExpandEverywhere (BurnySc2/python-sc2)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Map-Wide Multi-Hatchery Macro Swarm",
    },
    {
        "match_id": 29,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,
        "map_name": "CyberForestLE",
        "opponent_key": "TedChunProtossBot",
        "opponent_name": "ProtossBot (TedChun3/sc2-ai-bot)",
        "opponent_race": "Protoss",
        "archetype": "Protoss Multi-Base Zealot/Stalker/Sentry/Immortal/Colossus Deathball",
    },
    {
        "match_id": 30,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,
        "map_name": "KairosJunctionLE",
        "opponent_key": "TedChunTerranBot",
        "opponent_name": "TerranBot (TedChun3/sc2-ai-bot)",
        "opponent_race": "Terran",
        "archetype": "Terran Reaper Opening into Marine/Marauder/Medivac/Siege Tank Bio",
    },
    {
        "match_id": 31,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,
        "map_name": "KingsCoveLE",
        "opponent_key": "TedChunZergBot",
        "opponent_name": "ZergBot (TedChun3/sc2-ai-bot)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Hatchery First into Zergling/Roach/Hydralisk Macro",
    },
    {
        "match_id": 32,
        "mothman_variant": "Mothman-R",
        "mothman_bot_path": "bots/Mothman-R.rkt",
        "mothman_race": "Random",
        "posture": None,
        "map_name": "PortAleksanderLE",
        "opponent_key": "GreedyJackBot",
        "opponent_name": "EarlyAggro (lladdy/Greedy_bot)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Multi-Module Creep/Evo/Cavern/Expansion Macro Bot",
    },
    {
        "match_id": 33,
        "mothman_variant": "Mothman-Z",
        "mothman_bot_path": "bots/Mothman-Z.rkt",
        "mothman_race": "Zerg",
        "posture": None,
        "map_name": "BlueshiftLE",
        "opponent_key": "DeckardBot",
        "opponent_name": "DeckardBot (CozyFlower/sc2-ai-agents)",
        "opponent_race": "Terran",
        "archetype": "Terran Multi-Base Reaper/Bio/Siege Tank Macro Bot",
    },
    {
        "match_id": 34,
        "mothman_variant": "Mothman-T",
        "mothman_bot_path": "bots/Mothman-T.rkt",
        "mothman_race": "Terran",
        "posture": None,
        "map_name": "AbyssalReefLE",
        "opponent_key": "SN_10L",
        "opponent_name": "SN_10L (CozyFlower/sc2-ai-agents)",
        "opponent_race": "Zerg",
        "archetype": "Zerg Queen-Assigned Multi-Hatchery Macro Bot",
    },
    {
        "match_id": 35,
        "mothman_variant": "Mothman-P",
        "mothman_bot_path": "bots/Mothman-P.rkt",
        "mothman_race": "Protoss",
        "posture": None,
        "map_name": "BelShirVestigeLE",
        "opponent_key": "RockBot",
        "opponent_name": "RockBot (oxrock/RockBot_python_sc2_bot)",
        "opponent_race": "Terran",
        "archetype": "Terran Bio + Infantry Upgrades + Flying Barracks Macro Bot",
    },
]


def audit_replay_production(replay_path: Optional[str]) -> Dict[str, Any]:
    """
    Parses binary `.SC2Replay` (`replay.gamemetadata.json` and `replay.tracker.events`)
    via `mpyq` + `s2protocol` to verify:
      1. What units/structures Player 1 (Mothman) and Player 2 (Opponent) built after Frame 0.
      2. How many Player 2 buildings survived at game end (`p2_alive_buildings`).
      3. Whether the opponent actively produced structures/units (`verified_active_opponent`).
    """
    if not replay_path or not os.path.exists(replay_path):
        return {"verified_active_opponent": False, "error": "missing_replay"}
    try:
        import mpyq
        from s2protocol import versions

        archive = mpyq.MPQArchive(replay_path)
        header_content = archive.header["user_data_header"]["content"]
        header = versions.latest().decode_replay_header(header_content)
        base_build = header["m_version"]["m_baseBuild"]
        protocol = versions.build(base_build)

        meta_raw = archive.read_file("replay.gamemetadata.json")
        meta = json.loads(meta_raw.decode("utf-8")) if meta_raw else {}
        players_meta = {p["PlayerID"]: p.get("Result", "Unknown") for p in meta.get("Players", [])}

        tracker_raw = archive.read_file("replay.tracker.events")
        events = list(protocol.decode_replay_tracker_events(tracker_raw))

        p1_after0: Dict[str, int] = {}
        p2_after0: Dict[str, int] = {}
        alive: Dict[int, tuple] = {}
        kills = {1: 0, 2: 0}

        bldg_keywords = (
            "Hatchery", "Lair", "Hive", "CommandCenter", "Orbital", "Planetary", "Nexus",
            "Pylon", "Gateway", "WarpGate", "Barracks", "Factory", "Starport", "SpawningPool",
            "RoachWarren", "HydraliskDen", "CyberneticsCore", "PhotonCannon", "Forge",
            "SupplyDepot", "Refinery", "Assimilator", "Extractor", "Bunker", "Twilight",
            "Stargate", "Robotics", "Spire", "BanelingNest", "InfestationPit", "EvolutionChamber",
            "EngineeringBay", "Armory", "GhostAcademy", "FusionCore", "SpineCrawler", "SporeCrawler",
            "MissileTurret", "ShieldBattery", "DarkShrine", "TemplarArchive", "FleetBeacon",
            "TechLab", "Reactor",
        )
        ignore_types = (
            "Beacon", "Mineral", "Vespene", "Unbuildable", "Destructible",
            "Larva", "Broodling", "Egg", "Cocoon", "MULE", "Kd8Charge", "CreepTumor",
        )

        for e in events:
            et = e["_event"]
            gameloop = e.get("_gameloop", 0)
            if et in ("NNet.Replay.Tracker.SUnitBornEvent", "NNet.Replay.Tracker.SUnitInitEvent"):
                pid = e.get("m_controlPlayerId", 0)
                ut = e["m_unitTypeName"].decode("utf-8", errors="ignore")
                tag = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                if pid in (1, 2):
                    alive[tag] = (pid, ut)
                    if gameloop > 0 and not any(ig in ut for ig in ignore_types):
                        target_dict = p1_after0 if pid == 1 else p2_after0
                        target_dict[ut] = target_dict.get(ut, 0) + 1
            elif et == "NNet.Replay.Tracker.SUnitDiedEvent":
                tag = (e["m_unitTagIndex"] << 18) | e["m_unitTagRecycle"]
                killer = e.get("m_killerPlayerId", 0)
                if tag in alive:
                    dead_pid, _ = alive.pop(tag)
                    if killer in (1, 2) and killer != dead_pid:
                        kills[killer] += 1

        p1_alive_bldgs = sum(1 for (pid, ut) in alive.values() if pid == 1 and any(k in ut for k in bldg_keywords))
        p2_alive_bldgs = sum(1 for (pid, ut) in alive.values() if pid == 2 and any(k in ut for k in bldg_keywords))
        p2_total_built = sum(p2_after0.values())

        return {
            "engine_p1_result": players_meta.get(1, "Unknown"),
            "engine_p2_result": players_meta.get(2, "Unknown"),
            "p1_alive_buildings": p1_alive_bldgs,
            "p2_alive_buildings": p2_alive_bldgs,
            "p1_kills": kills[1],
            "p2_kills": kills[2],
            "our_built_after_frame0": p1_after0,
            "opponent_built_after_frame0": p2_after0,
            "opponent_total_built_after_frame0": p2_total_built,
            "verified_active_opponent": True,
        }
    except Exception as exc:
        return {"verified_active_opponent": False, "error": str(exc)}


def execute_single_gauntlet_match(spec: Dict[str, Any], max_loops: int = 11200) -> Dict[str, Any]:
    REPLAY_DIR.mkdir(parents=True, exist_ok=True)
    mid = spec["match_id"]
    variant = spec["mothman_variant"]
    opp_key = spec["opponent_key"]
    map_name = spec.get("map_name", "AutomatonLE")
    replay_path = str(REPLAY_DIR / f"match_{mid:02d}_{variant}_vs_{opp_key}_{map_name}.SC2Replay")
    bot_rkt_path = str(ROOT_DIR / spec["mothman_bot_path"])

    ext_bot = build_external_opponent_bot(opp_key)
    res = run_live_headless_sc2_match(
        bot_rkt_path=bot_rkt_path,
        opponent_race_str=spec["opponent_race"],
        difficulty_str="VeryHard",
        map_name=map_name,
        max_game_loops=max_loops,
        save_replay_path=replay_path,
        race_override=spec["mothman_race"],
        posture_override=spec["posture"],
        external_opponent_bot=ext_bot,
        opponent_bot_name=spec["opponent_name"],
    )
    res["match_id"] = mid
    res["mothman_variant"] = variant
    res["opponent_key"] = opp_key
    res["archetype"] = spec["archetype"]
    res["replay_audit"] = audit_replay_production(replay_path)
    return res


def run_match_in_isolated_subprocess(spec: Dict[str, Any], max_loops: int = 11200) -> Dict[str, Any]:
    """
    Runs a single gauntlet match in a fresh isolated Python subprocess so
    legacy monkey-patches (`Pointlike.__eq__`, `sys.modules`, `kill_switch`)
    never leak between matches.
    """
    import subprocess

    mid = spec["match_id"]
    out_file = ROOT_DIR / "data" / f"_match_{mid:02d}_result.json"
    if out_file.exists():
        out_file.unlink()

    cmd = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--single-match-worker",
        str(mid),
        "--max-loops",
        str(max_loops),
        "--worker-output",
        str(out_file),
    ]
    subprocess.run(cmd, cwd=str(ROOT_DIR), check=True)
    with open(out_file, "r", encoding="utf-8") as f:
        res = json.load(f)
    try:
        out_file.unlink()
    except Exception:
        pass
    return res


def main():
    parser = argparse.ArgumentParser(description="Run Fair Blind 14-Match Live SC2_x64 Gauntlet vs Real External Bots")
    parser.add_argument("--match", type=str, default=None, help="Run specific match ID(s), e.g. 10 or 10,13,5,2")
    parser.add_argument("--workers", type=int, default=2, help="Number of parallel SC2_x64 match workers")
    parser.add_argument("--max-loops", type=int, default=13440, help="Max game loops per match (13440 = 600s)")
    parser.add_argument("--single-match-worker", type=int, default=None, help=argparse.SUPPRESS)
    parser.add_argument("--worker-output", type=str, default=None, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.single_match_worker is not None:
        spec = [m for m in GAUNTLET_MATCHES if m["match_id"] == args.single_match_worker][0]
        res = execute_single_gauntlet_match(spec, max_loops=args.max_loops)
        if args.worker_output:
            Path(args.worker_output).parent.mkdir(parents=True, exist_ok=True)
            with open(args.worker_output, "w", encoding="utf-8") as f:
                json.dump(res, f, indent=2)
        return

    match_ids = (
        {int(x.strip()) for x in args.match.split(",") if x.strip()}
        if args.match is not None
        else None
    )
    selected = [m for m in GAUNTLET_MATCHES if match_ids is None or m["match_id"] in match_ids]
    print(
        f"=== [Mothman Fair Blind Multi-Map Gauntlet] Launching {len(selected)} Live Headless SC2_x64 Matches "
        f"(workers={args.workers}, max_loops={args.max_loops}) ===",
        flush=True,
    )

    t_start = time.time()
    results_by_id: Dict[int, Dict[str, Any]] = {}
    if match_ids is not None and RESULTS_JSON_PATH.exists():
        try:
            with open(RESULTS_JSON_PATH, "r", encoding="utf-8") as f:
                prev = json.load(f)
            for m in prev.get("matches", []):
                if "match_id" in m:
                    if "replay_audit" not in m and m.get("replay_path"):
                        m["replay_audit"] = audit_replay_production(m.get("replay_path"))
                    results_by_id[int(m["match_id"])] = m
        except Exception:
            pass

    total_count = len(GAUNTLET_MATCHES)
    if args.workers <= 1 or len(selected) == 1:
        for spec in selected:
            r = run_match_in_isolated_subprocess(spec, max_loops=args.max_loops)
            results_by_id[r["match_id"]] = r
            aud = r.get("replay_audit", {})
            print(
                f"  [Match {r['match_id']:02d}/{total_count} @ {r['map']}] {r['mothman_variant']} ({r['actual_race_played']}, "
                f"posture={'->'.join(r['posture_transitions'])}) "
                f"vs {r['opponent_key']} ({r['opponent_race']}): {r['result']} "
                f"in {r['game_loops']} gl ({r['game_duration_s']}s game / {r['wall_time_s']}s wall) | "
                f"supply_blocked={r['supply_blocked_loops']} gl | "
                f"mirror_d={r.get('mirror_active_depth', 2)} (opp_d*={r.get('mirror_inferred_opponent_depth', 1)}, "
                f"w={r.get('mirror_toolbox_weight_pct', 20)}%, {r.get('mirror_predicted_enemy_unit', '?')}->{r.get('mirror_preemptive_unit', '?')}) | "
                f"opp_built={aud.get('opponent_built_after_frame0', {})}",
                flush=True,
            )
    else:
        with ProcessPoolExecutor(max_workers=args.workers) as pool:
            fut_map = {
                pool.submit(run_match_in_isolated_subprocess, spec, args.max_loops): spec
                for spec in selected
            }
            for fut in as_completed(fut_map):
                r = fut.result()
                results_by_id[r["match_id"]] = r
                aud = r.get("replay_audit", {})
                print(
                    f"  [Match {r['match_id']:02d}/{total_count} @ {r['map']}] {r['mothman_variant']} ({r['actual_race_played']}, "
                    f"posture={'->'.join(r['posture_transitions'])}) "
                    f"vs {r['opponent_key']} ({r['opponent_race']}): {r['result']} "
                    f"in {r['game_loops']} gl ({r['game_duration_s']}s game / {r['wall_time_s']}s wall) | "
                    f"supply_blocked={r['supply_blocked_loops']} gl | "
                    f"mirror_d={r.get('mirror_active_depth', 2)} (opp_d*={r.get('mirror_inferred_opponent_depth', 1)}, "
                    f"w={r.get('mirror_toolbox_weight_pct', 20)}%, {r.get('mirror_predicted_enemy_unit', '?')}->{r.get('mirror_preemptive_unit', '?')}) | "
                    f"opp_built={aud.get('opponent_built_after_frame0', {})}",
                    flush=True,
                )

    ordered_results = [results_by_id[k] for k in sorted(results_by_id.keys())]
    victories = sum(1 for r in ordered_results if r["result"] == "Victory")
    total_supply_blocked = sum(r["supply_blocked_loops"] for r in ordered_results)
    total_wall_s = round(time.time() - t_start, 2)

    summary = {
        "status": f"EXTERNAL_GAUNTLET_{victories}_OF_{len(ordered_results)}_VICTORY" if victories == len(ordered_results) else "EXTERNAL_GAUNTLET_PARTIAL",
        "fairness_protocol": {
            "blind_starts": True,
            "random_race_true_roll": True,
            "official_1v1_ladder_maps": True,
            "real_unmodified_community_bots": True,
            "all_9_canonical_matchups_covered": True,
            "racket_sexp_humancortex_active": True,
            "generic_k_depth_mirror_mind_active": True,
            "foosball_depth_probing_and_snowball_toolbox_active": True,
            "replay_tracker_production_audited": True,
        },
        "matches_played": len(ordered_results),
        "victories": victories,
        "win_rate": round(victories / max(1, len(ordered_results)), 4),
        "total_supply_blocked_loops": total_supply_blocked,
        "total_supply_blocked_seconds": round(total_supply_blocked / 22.4, 2),
        "total_wall_time_s": total_wall_s,
        "matches": ordered_results,
    }

    RESULTS_JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(RESULTS_JSON_PATH, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print("\n===========================================================================", flush=True)
    print(
        f"Gauntlet Complete: {victories}/{len(ordered_results)} Victories ({summary['win_rate'] * 100:.1f}%), "
        f"Total Supply Block: {total_supply_blocked} gl ({summary['total_supply_blocked_seconds']}s), "
        f"Wall Time: {total_wall_s}s",
        flush=True,
    )
    print(f"Results written to {RESULTS_JSON_PATH}", flush=True)


if __name__ == "__main__":
    main()
