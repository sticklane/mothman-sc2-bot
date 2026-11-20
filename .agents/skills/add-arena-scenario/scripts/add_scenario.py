#!/usr/bin/env python3
"""
Human-friendly helper CLI to list, validate, add, or remove tactics arena
scenarios in `tools/arena-scenarios.json`.

Examples:
  # List current scenarios with P1/P2 combat values
  python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --list

  # List all supported SC2 unit names
  python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --list-units

  # Preview a new scenario (dry-run)
  python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py \
    --race Protoss --enemy-race Terran --slug blink-vs-tanks \
    --p1 "zealot:4,stalker:6,immortal:2" \
    --p2 "marine:10,siege-tank-sieged:2,medivac:1" \
    --separation 11.0 \
    --description "4 Zealots + 6 Stalkers + 2 Immortals diving 2 Sieged Tanks + 10 Marines + 1 Medivac" \
    --dry-run

  # Add for real (omit --dry-run), or pass explicit @dx,dy coordinates:
  #   --p2 "void-ray:2@6.0,0,tempest:1@7.5,-2.5,tempest:1@7.5,0,tempest:1@7.5,2.5"
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[4]
DEFAULT_CATALOG = REPO_ROOT / "tools" / "arena-scenarios.json"

# Canonical Blizzard 4.10 SC2 UnitTypeIds, (id, value, role_offset_from_front)
# role_offset_from_front: 0.0 = melee front, 1.0 = ranged mid, 2.0 = caster/air/siege, 3.0 = far-rear capital/siege
UNITS: dict[str, tuple[int, float, float]] = {
    # Protoss
    "zealot": (73, 100.0, 0.0),
    "adept": (311, 137.5, 0.8),
    "stalker": (74, 200.0, 1.2),
    "sentry": (77, 200.0, 1.6),
    "immortal": (83, 425.0, 0.5),
    "archon": (141, 550.0, 0.0),
    "dark-templar": (76, 312.5, 0.0),
    "high-templar": (75, 275.0, 2.2),
    "colossus": (4, 600.0, 2.4),
    "disruptor": (694, 375.0, 2.4),
    "phoenix": (78, 300.0, 1.5),
    "oracle": (495, 375.0, 2.0),
    "void-ray": (80, 475.0, 1.5),
    "tempest": (496, 512.5, 3.0),
    "carrier": (79, 725.0, 3.0),
    "observer": (82, 137.5, 2.2),
    "warp-prism": (81, 250.0, 2.5),
    "probe": (84, 50.0, 0.5),
    # Terran
    "hellbat": (484, 100.0, 0.0),
    "hellion": (53, 100.0, 0.5),
    "marauder": (51, 137.5, 0.3),
    "marine": (48, 50.0, 1.0),
    "reaper": (49, 125.0, 0.4),
    "cyclone": (692, 300.0, 0.9),
    "thor": (52, 600.0, 0.6),
    "ghost": (50, 337.5, 2.0),
    "siege-tank": (33, 337.5, 2.2),
    "siege-tank-sieged": (32, 337.5, 2.8),
    "widow-mine": (498, 112.5, 0.7),
    "widow-mine-burrowed": (500, 112.5, 0.7),
    "medivac": (54, 250.0, 2.4),
    "viking-fighter": (35, 262.5, 1.6),
    "viking-assault": (34, 262.5, 1.0),
    "banshee": (55, 300.0, 2.0),
    "raven": (56, 400.0, 2.4),
    "liberator": (689, 375.0, 2.2),
    "liberator-ag": (734, 375.0, 2.2),
    "battlecruiser": (57, 850.0, 2.8),
    "scv": (45, 50.0, 0.5),
    # Zerg
    "zergling": (105, 25.0, 0.0),
    "baneling": (9, 87.5, 0.4),
    "ultralisk": (109, 575.0, 0.2),
    "roach": (110, 112.5, 0.4),
    "ravager": (688, 250.0, 1.3),
    "hydralisk": (107, 175.0, 1.4),
    "queen": (126, 150.0, 1.8),
    "lurker-mp": (502, 375.0, 1.6),
    "lurker-mp-burrowed": (503, 375.0, 1.6),
    "infestor": (111, 325.0, 2.2),
    "swarm-host": (494, 212.5, 2.4),
    "mutalisk": (108, 250.0, 1.5),
    "corruptor": (112, 300.0, 1.5),
    "viper": (499, 400.0, 2.4),
    "brood-lord": (114, 675.0, 3.0),
    "overseer": (129, 225.0, 2.2),
    "drone": (104, 50.0, 0.5),
}

ALIASES: dict[str, str] = {
    "ling": "zergling",
    "lings": "zergling",
    "zerglings": "zergling",
    "bane": "baneling",
    "banes": "baneling",
    "banelings": "baneling",
    "hydra": "hydralisk",
    "hydras": "hydralisk",
    "hydralisks": "hydralisk",
    "muta": "mutalisk",
    "mutas": "mutalisk",
    "ultra": "ultralisk",
    "ultras": "ultralisk",
    "lurker": "lurker-mp",
    "lurkers": "lurker-mp",
    "burrowed-lurker": "lurker-mp-burrowed",
    "broodlord": "brood-lord",
    "broodlords": "brood-lord",
    "bl": "brood-lord",
    "roaches": "roach",
    "ravagers": "ravager",
    "queens": "queen",
    "infestors": "infestor",
    "vipers": "viper",
    "corruptors": "corruptor",
    "marines": "marine",
    "marauders": "marauder",
    "medivacs": "medivac",
    "reapers": "reaper",
    "hellions": "hellion",
    "hellbats": "hellbat",
    "cyclones": "cyclone",
    "ghosts": "ghost",
    "ravens": "raven",
    "thors": "thor",
    "banshees": "banshee",
    "liberators": "liberator",
    "tank": "siege-tank",
    "tanks": "siege-tank",
    "sieged-tank": "siege-tank-sieged",
    "sieged-tanks": "siege-tank-sieged",
    "viking": "viking-fighter",
    "vikings": "viking-fighter",
    "bc": "battlecruiser",
    "battlecruisers": "battlecruiser",
    "mine": "widow-mine",
    "mines": "widow-mine",
    "zealots": "zealot",
    "stalkers": "stalker",
    "adepts": "adept",
    "sentries": "sentry",
    "immortals": "immortal",
    "archons": "archon",
    "colossi": "colossus",
    "colossuses": "colossus",
    "ht": "high-templar",
    "hts": "high-templar",
    "dt": "dark-templar",
    "dts": "dark-templar",
    "disruptors": "disruptor",
    "oracles": "oracle",
    "phoenixes": "phoenix",
    "voidray": "void-ray",
    "voidrays": "void-ray",
    "void-rays": "void-ray",
    "tempests": "tempest",
    "carriers": "carrier",
}

RACE_PREFIX = {"Protoss": "p", "Terran": "t", "Zerg": "z"}
RACE_ORDER = {"Protoss": 0, "Terran": 1, "Zerg": 2}


def normalize_unit(raw: str) -> str:
    key = raw.strip().lower().replace("_", "-").replace(" ", "-")
    key = ALIASES.get(key, key)
    if key not in UNITS:
        raise ValueError(f"Unknown unit '{raw}'. Run --list-units to see supported keys.")
    return key


def parse_army_spec(spec: str, side: int, separation: float) -> list[list[Any]]:
    """
    Parse comma-separated unit specs:
      'zealot:4,stalker:4' or explicit offsets 'tempest:1@7.5,-2.5,tempest:1@7.5,0'
    side: -1 for P1 (Mothman, left), +1 for P2 (opponent, right).
    """
    half_sep = max(3.0, separation / 2.0)
    groups: list[list[Any]] = []
    for token in [t.strip() for t in spec.split(",") if t.strip()]:
        explicit_xy = None
        if "@" in token:
            head, coords = token.split("@", 1)
            parts = coords.split(",")
            if len(parts) != 2:
                raise ValueError(f"Bad @dx,dy offset in '{token}'")
            explicit_xy = (float(parts[0]), float(parts[1]))
            token = head
        if ":" in token:
            uname_raw, cnt_raw = token.split(":", 1)
            cnt = int(cnt_raw)
        else:
            uname_raw, cnt = token, 1
        if cnt <= 0:
            raise ValueError(f"Unit count must be > 0 in '{token}'")
        uname = normalize_unit(uname_raw)
        if explicit_xy is not None:
            dx, dy = explicit_xy
        else:
            role_off = UNITS[uname][2]
            dx = round(side * (half_sep - 0.5 + role_off), 2)
            dy = 0.0
        groups.append([uname, cnt, dx, dy])
    if not groups:
        raise ValueError("Army spec cannot be empty.")
    return groups


def army_value(units: list[list[Any]]) -> float:
    return sum(UNITS[u[0]][1] * int(u[1]) for u in units)


def army_summary(units: list[list[Any]]) -> str:
    agg: dict[str, int] = {}
    for u in units:
        agg[u[0]] = agg.get(u[0], 0) + int(u[1])
    return " + ".join(f"{cnt} {name}" for name, cnt in agg.items())


def load_catalog(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        raise FileNotFoundError(f"Scenario catalog not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, dict) and "scenarios" in data:
        return list(data["scenarios"])
    if isinstance(data, list):
        return data
    raise ValueError(f"Unexpected JSON structure in {path}")


def save_catalog(path: Path, scenarios: list[dict[str, Any]]) -> None:
    scenarios_sorted = sorted(
        scenarios,
        key=lambda s: (RACE_ORDER.get(s.get("our_race", ""), 9), s.get("id", "")),
    )
    payload = {
        "schema_version": 1,
        "notes": "Real-SC2_x64 micro skirmish scenarios loaded by tools/sc2-tactics-arena.py. Add or edit via .agents/skills/add-arena-scenario/scripts/add_scenario.py.",
        "scenarios": scenarios_sorted,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def next_id(scenarios: list[dict[str, Any]], race: str, slug: str) -> str:
    pfx = RACE_PREFIX[race]
    pat = re.compile(rf"^sc2-real-{pfx}(\d+)-")
    max_n = 0
    for s in scenarios:
        m = pat.match(s.get("id", ""))
        if m:
            max_n = max(max_n, int(m.group(1)))
    clean_slug = re.sub(r"[^a-z0-9]+", "-", slug.strip().lower()).strip("-")
    if not clean_slug:
        clean_slug = "custom-duel"
    return f"sc2-real-{pfx}{max_n + 1:02d}-{clean_slug}"


def validate_catalog(scenarios: list[dict[str, Any]]) -> list[str]:
    errs: list[str] = []
    seen: set[str] = set()
    for i, s in enumerate(scenarios):
        sid = s.get("id", "")
        if not sid:
            errs.append(f"Scenario #{i} missing 'id'")
        elif sid in seen:
            errs.append(f"Duplicate scenario id: {sid}")
        seen.add(sid)
        for field in ("our_race", "enemy_race"):
            if s.get(field) not in RACE_PREFIX:
                errs.append(f"{sid}: invalid {field}={s.get(field)!r}")
        for side_key in ("p1_units", "p2_units"):
            ulist = s.get(side_key)
            if not isinstance(ulist, list) or not ulist:
                errs.append(f"{sid}: {side_key} must be a non-empty list")
                continue
            for item in ulist:
                if not isinstance(item, list) or len(item) != 4:
                    errs.append(f"{sid}: bad {side_key} entry {item!r}")
                else:
                    uname, cnt, dx, dy = item
                    if uname not in UNITS:
                        errs.append(f"{sid}: unknown unit {uname!r} in {side_key}")
                    if not isinstance(cnt, int) or cnt <= 0:
                        errs.append(f"{sid}: invalid count {cnt!r} in {side_key}")
    return errs


def main() -> int:
    ap = argparse.ArgumentParser(description="Manage Mothman real-SC2 tactics arena scenarios")
    ap.add_argument("--catalog", default=str(DEFAULT_CATALOG))
    ap.add_argument("--list", action="store_true", help="List all scenarios with combat value balance")
    ap.add_argument("--list-units", action="store_true", help="List all supported SC2 unit names")
    ap.add_argument("--validate", action="store_true", help="Validate the scenario catalog")
    ap.add_argument("--remove", default="", help="Remove scenario with exact id")
    ap.add_argument("--race", choices=["Protoss", "Terran", "Zerg"], help="Mothman's race (P1)")
    ap.add_argument("--enemy-race", choices=["Protoss", "Terran", "Zerg"], help="Opponent's race (P2)")
    ap.add_argument("--id", default="", help="Explicit scenario id (auto-generated from --slug if omitted)")
    ap.add_argument("--slug", default="", help="Short kebab-case slug (e.g. blink-vs-tanks)")
    ap.add_argument("--p1", default="", help="Mothman army spec, e.g. 'zealot:4,stalker:4'")
    ap.add_argument("--p2", default="", help="Opponent army spec, e.g. 'marine:12,marauder:3'")
    ap.add_argument("--separation", type=float, default=9.0, help="Front-line separation in tiles (default 9.0)")
    ap.add_argument("--max-loops", type=int, default=336, help="Max combat loops (~22.4 loops/sec, default 336)")
    ap.add_argument("--description", default="", help="Human-readable description for reports & 3D clip context")
    ap.add_argument("--dry-run", action="store_true", help="Preview scenario without modifying catalog")
    args = ap.parse_args()

    if args.list_units:
        print(f"{'Unit Key':22s} {'SC2 ID':>6s} {'Value':>7s} {'Layer':>6s}")
        print("-" * 46)
        for k in sorted(UNITS):
            uid, val, layer = UNITS[k]
            print(f"{k:22s} {uid:6d} {val:7.1f} {layer:6.1f}")
        return 0

    cat_path = Path(args.catalog)
    scenarios = load_catalog(cat_path)

    if args.validate:
        errs = validate_catalog(scenarios)
        if errs:
            for e in errs:
                print(f"ERROR: {e}", file=sys.stderr)
            return 1
        print(f"OK: {len(scenarios)} scenarios validated cleanly in {cat_path}")
        return 0

    if args.list:
        print(f"{'ID':46s} {'Matchup':7s} {'P1 Val':>7s} {'P2 Val':>7s} {'Ratio':>6s}")
        print("-" * 80)
        for s in scenarios:
            v1 = army_value(s["p1_units"])
            v2 = army_value(s["p2_units"])
            mu = f"{s['our_race'][0]}v{s['enemy_race'][0]}"
            print(f"{s['id']:46s} {mu:7s} {v1:7.0f} {v2:7.0f} {v1/max(1.0,v2):5.2f}x")
        print(f"\nTotal: {len(scenarios)} scenarios ({cat_path})")
        return 0

    if args.remove:
        before = len(scenarios)
        scenarios = [s for s in scenarios if s.get("id") != args.remove]
        if len(scenarios) == before:
            print(f"Scenario not found: {args.remove}", file=sys.stderr)
            return 1
        if not args.dry_run:
            save_catalog(cat_path, scenarios)
        print(f"Removed {args.remove} ({len(scenarios)} remaining)")
        return 0

    if not (args.race and args.enemy_race and args.p1 and args.p2):
        ap.error("To add a scenario, provide --race, --enemy-race, --p1, and --p2 (or use --list / --list-units / --validate).")

    p1_units = parse_army_spec(args.p1, side=-1, separation=args.separation)
    p2_units = parse_army_spec(args.p2, side=+1, separation=args.separation)
    sid = args.id.strip() or next_id(scenarios, args.race, args.slug or f"{p1_units[0][0]}-vs-{p2_units[0][0]}")
    if any(s.get("id") == sid for s in scenarios):
        print(f"ERROR: Scenario id already exists: {sid}", file=sys.stderr)
        return 1

    desc = args.description.strip() or f"Real SC2: {army_summary(p1_units)} vs {army_summary(p2_units)}"
    entry = {
        "id": sid,
        "our_race": args.race,
        "enemy_race": args.enemy_race,
        "description": desc,
        "p1_units": p1_units,
        "p2_units": p2_units,
        "max_loops": int(args.max_loops),
    }

    v1 = army_value(p1_units)
    v2 = army_value(p2_units)
    print(json.dumps(entry, indent=2))
    print(f"\nBalance: P1 ({args.race}) = {v1:.1f} vs P2 ({args.enemy_race}) = {v2:.1f}  (P1/P2 = {v1/max(1.0,v2):.2f}x)")

    if args.dry_run:
        print("[dry-run] Catalog not modified.")
    else:
        scenarios.append(entry)
        errs = validate_catalog(scenarios)
        if errs:
            for e in errs:
                print(f"VALIDATION ERROR: {e}", file=sys.stderr)
            return 1
        save_catalog(cat_path, scenarios)
        print(f"Added '{sid}' to {cat_path} ({len(scenarios)} total scenarios).")

    print("\nQuick 3D preview command (~10s):")
    print(
        f"  python3 tools/sc2-tactics-arena.py --mode duel --race {args.race} "
        f"--scenario {sid} --render-dir /tmp/arena_preview_{sid} "
        f"--out /tmp/arena_preview_{sid}/result.json"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
