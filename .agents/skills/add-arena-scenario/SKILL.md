---
name: add-arena-scenario
description: >-
  Add, edit, list, validate, and 3D-preview custom StarCraft II micro-skirmish
  scenarios in Mothman's real-SC2 tactics arena (`tools/arena-scenarios.json` and
  `tools/sc2-tactics-arena.py`). Use whenever the user asks to add an arena
  scenario, create a new tactics duel, test specific unit compositions against
  each other (e.g. "test 6 Stalkers + 2 Immortals vs 2 Siege Tanks + 10 Marines"),
  turn a match fight into an arena test, or manage scenarios in the tactics arena.
---

# Add or Edit a Mothman Tactics Arena Scenario

This skill makes it fast and safe for humans to add new real-`SC2_x64` combat scenarios to Mothman's tactics arena and immediately preview them in **real 3D StarCraft II graphics** (animated WebP + Peak-Clash PNG).

## Architecture

- **Scenario catalog (human-editable JSON):** `tools/arena-scenarios.json`
- **Arena runner & 3D renderer:** `tools/sc2-tactics-arena.py` (loads `tools/arena-scenarios.json` automatically; supports `--scenario <id-or-substring>` to test & 3D-render a single scenario in ~8–12s)
- **Helper CLI:** [add_scenario.py](./scripts/add_scenario.py)
- **Supported SC2 unit names, IDs, & values:** [unit-catalog.md](./references/unit-catalog.md)

## Workflow

### 1. Translate the Request into a Concrete Scenario Spec

From the user's description, determine:
- **`our_race`** (`Protoss` | `Terran` | `Zerg`) — the race Mothman plays (`P1`, spawns on the left, negative `dx`).
- **`enemy_race`** (`Protoss` | `Terran` | `Zerg`) — the scripted focus-firing opponent (`P2`, spawns on the right, positive `dx`).
- **`p1_units` & `p2_units`** — canonical unit names from [unit-catalog.md](./references/unit-catalog.md) and counts (e.g. `zealot:4,stalker:4` vs `marine:12,marauder:3`).
  - For transformable units, choose the intended starting mode explicitly (e.g. `siege-tank` vs `siege-tank-sieged`, `liberator` vs `liberator-ag`, `widow-mine` vs `widow-mine-burrowed`, `lurker-mp` vs `lurker-mp-burrowed`, `viking-fighter` vs `viking-assault`).
- **Separation & formation** — default `--separation 9.0` places melee front (`±3.5`), ranged mid (`±4.5`), and casters/siege/air rear (`±5.5..6.5`). Use larger separation (e.g. `12.0–14.0`) for long-range siege/capital-air dives (Siege Tanks, Tempests, Carriers, Lurkers), or pass explicit `@dx,dy` offsets per group (e.g. `tempest:1@7.5,-2.5,tempest:1@7.5,0,tempest:1@7.5,2.5`).
- **`description`** — concise human-readable summary of the matchup and what micro behavior it tests (used verbatim in reports and 3D clip context).
- **`max_loops`** — default `336` (~15s Faster game time); bump to `448–560` (~20–25s) only for slow capital-ship or siege stalemates.

If any essential detail is ambiguous (e.g., which side Mothman plays, or whether tanks start pre-sieged), ask a brief clarifying question before adding.

### 2. Preview & Add via `add_scenario.py`

First inspect unit names or existing IDs if needed:

```bash
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --list
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --list-units
```

Dry-run first to inspect the auto-generated ID, `(dx, dy)` formation, and P1 vs P2 resource-value balance (`mineral + 1.5 * gas`):

```bash
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py \
  --race Protoss --enemy-race Terran \
  --slug blink-stalkers-vs-tanks \
  --p1 "zealot:4,stalker:6,immortal:2" \
  --p2 "marine:10,siege-tank-sieged:2,medivac:1" \
  --separation 11.0 \
  --description "4 Zealots + 6 Stalkers + 2 Immortals diving 2 Sieged Tanks + 10 Marines + 1 Medivac" \
  --dry-run
```

Once the formation and balance look right, re-run without `--dry-run` to write it cleanly to `tools/arena-scenarios.json` (the script validates all unit names, checks duplicate IDs, and keeps `tools/arena-scenarios.json` neatly sorted by race).

> [!NOTE]
> If the user asks for a valid SC2 unit not yet in `UNIT_IDS` inside `tools/sc2-tactics-arena.py`, add its Blizzard 4.10 `UnitTypeId` and `mineral + 1.5*gas` value to `UNIT_IDS` / `UNIT_VALUES` in `tools/sc2-tactics-arena.py` and mirror it in [unit-catalog.md](./references/unit-catalog.md).

### 3. Live Real-SC2 Smoke Test & 3D Preview (~10 Seconds)

Run **only** the newly added scenario with `--scenario <new-id>` and `--render-dir` so the human can immediately verify unit spawning, physics, Mothman's micro response, and watch the real 3D SC2 rendering:

```bash
python3 tools/sc2-tactics-arena.py \
  --mode duel \
  --race <our_race> \
  --scenario <new-id> \
  --render-dir /tmp/arena_preview_<new-id> \
  --out /tmp/arena_preview_<new-id>/result.json
```

Verify from `result.json` and stdout:
- Both sides spawned with the exact expected `p1_start_cnt` and `p2_start_cnt` (if `0` spawned, check `UNIT_IDS` or map clearing space).
- `winner`, `trade_ratio`, `mothman_attack_unit_cmds`, `mothman_move_unit_cmds`, `mothman_spell_unit_cmds`, and `loops_simulated` look sensible.
- **Zero** stray containers (`podman ps -q | wc -l == 0`) or stray `SC2_x64` processes.

### 4. Visually Inspect & Present to the User

1. Read `/tmp/arena_preview_<new-id>/<new-id>.png` with `read_file` to visually confirm unit positioning, camera framing, and clarity.
2. Copy the rendered `.png` and `.webp` into the conversation artifact directory (or link them clearly) and present:
   - Scenario ID, exact unit comps, and P1/P2 resource value balance
   - Live duel result (`Winner`, `Trade Ratio`, `Alive`, `Attack/Move/Spell` commands, `Loops`)
   - The real-3D Peak-Clash screenshot (and WebP clip) so the user can judge whether to tweak unit counts, starting distance, or `max_loops`
3. Ask if they want to adjust anything, keep it as-is, or also add an offline deterministic assertion in `tests/tactics-tests.rkt`.

### 5. Finalize

Validate the full catalog before committing via `jj`:

```bash
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --validate
```

Then describe and push cleanly following the repo's `jj` workflow.
