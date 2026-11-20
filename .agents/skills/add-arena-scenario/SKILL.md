---
name: add-arena-scenario
description: >-
  Add, edit, extract from replays, list, validate, and 3D-preview custom StarCraft II
  micro-skirmish scenarios in Mothman's Real-SC2 Tactics Arena 2.0 (`tools/arena-scenarios.json`
  and `tools/sc2-tactics-arena.py`), including Mothman-vs-Mothman self-play (`--opponent self`),
  real SC2 terrain modes (`high-ground-ramp`, `flank-surround`, `cliff-air-chasm`,
  `mineral-line-harass`), and selective per-player upgrades/burrow/cloak. Use whenever the user
  asks to add an arena scenario, turn a match replay fight into an arena duel, test specific unit
  compositions or self-play matchups, or manage scenarios in the tactics arena.
---

# Add or Edit a Mothman Tactics Arena 2.0 Scenario

This skill makes it fast and safe to add new real-`SC2_x64` combat scenarios to Mothman's Tactics Arena 2.0 (`36` scenarios across `5` real SC2 terrain modes + selective upgrades + Mothman-vs-Mothman self-play) and immediately preview them in **real 3D StarCraft II graphics** (animated WebP + Peak-Clash PNG).

## Architecture

- **Scenario catalog (human-editable JSON):** `tools/arena-scenarios.json` (`schema_version: 2`)
- **Arena 2.0 runner & 3D renderer:** `tools/sc2-tactics-arena.py`
  - Supports `--opponent dummy` (default focus-firing MicroDummy) and **`--opponent self`** (live Mothman-vs-Mothman self-play matching both `our_race` and `enemy_race`!)
  - Supports filters: `--race`, `--enemy-race`, `--scenario <substring>`, `--terrain <mode>`, `--source <tag>`
- **Helper CLI:** [add_scenario.py](./scripts/add_scenario.py) (includes **`--from-replay <path.SC2Replay>`** peak-clash extractor!)
- **Supported SC2 units, terrains & upgrades:** [unit-catalog.md](./references/unit-catalog.md)

## Workflow

### 1. Translate the Request (or Extract Directly From a Replay!)

**Option A — Extract from a real `.SC2Replay` match fight (`--from-replay`):**
```bash
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py \
  --from-replay /path/to/match.SC2Replay \
  --slug match-peak-clash \
  --terrain open \
  --opponent self \
  --dry-run
```

**Option B — Author from a natural-language description:**
Determine:
- **`our_race`** & **`enemy_race`** (`Protoss` | `Terran` | `Zerg`)
- **`p1_units` & `p2_units`** — canonical unit names from [unit-catalog.md](./references/unit-catalog.md) (including burrowed/sieged variants like `roach-burrowed`, `lurker-mp-burrowed`, `widow-mine-burrowed`, `siege-tank-sieged`, `liberator-ag`).
- **`--terrain`** — choose from 5 real SC2 map terrain modes:
  - `open` (default): central open flat clearing
  - `high-ground-ramp`: real walkable elevation ramp (`--high-ground-side p1|p2`)
  - `flank-surround`: wide clearing supporting 2-prong pincer `@dx,dy` offsets
  - `cliff-air-chasm`: pathable cliff edge directly overlooking unpathable chasm for hovering air (`Tempest`/`Carrier`/`BroodLord`/`Corruptor`/`Viper`)
  - `mineral-line-harass`: unoccupied real expansion mineral line (for worker/harass/12-Pool defense)
- **`--upgrades` / `--p1-upgrades` / `--p2-upgrades`** — selective per-player upgrades researched in real SC2 before the fight (`Burrow`, `TunnelingClaws`, `GlialReconstitution`, `MetabolicBoost`, `CentrifugalHooks`, `LurkerRange`, `AdaptiveTalons`, `GroovedSpines`, `Blink`, `Charge`, `ThermalLance`, `PsiStorm`, `Stim`, `CombatShield`, `DrillingClaws`, `Cloak`, `BansheeCloak`, `PersonalCloaking`, etc.) plus optional `--p1-pre-cloaked` / `--p2-pre-cloaked`.
- **`--source`** (`match-forensics` | `pro-db` | `pattern-coverage` | `replay-extract` | `custom`) and **`--patterns`** (comma-separated tags).

### 2. Preview & Add via `add_scenario.py`

```bash
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --list
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --list-units
```

Dry-run first to inspect ID, formation, terrain, upgrades, and P1/P2 combat value balance:
```bash
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py \
  --race Zerg --enemy-race Protoss \
  --slug roach-burrow-ramp \
  --terrain high-ground-ramp --high-ground-side p1 \
  --p1 "roach:10,ravager:2" \
  --p2 "stalker:6,immortal:2" \
  --p1-upgrades "Burrow,TunnelingClaws,GlialReconstitution" \
  --p2-upgrades "Blink" \
  --patterns "roach-burrow-heal,high-ground-ramp" \
  --opponent self \
  --dry-run
```
Re-run without `--dry-run` to save cleanly to `tools/arena-scenarios.json`.

### 3. Live Real-SC2 Smoke Test & 3D Preview (~10–15 Seconds)

Test vs MicroDummy (default) OR **Mothman-vs-Mothman Self-Play (`--opponent self`)**:
```bash
python3 tools/sc2-tactics-arena.py \
  --mode duel \
  --opponent self \
  --race <our_race> \
  --scenario <new-id> \
  --render-dir /tmp/arena_preview_<new-id> \
  --out /tmp/arena_preview_<new-id>/result.json
```

Verify from `result.json`:
- `p1_start_cnt` and `p2_start_cnt` match expected unit counts; `applied_p1_upgrade_ids` / `applied_p2_upgrade_ids` confirm upgrades took effect.
- `winner`, `trade_ratio` (and `p2_trade_ratio` / `p2_attack_unit_cmds` in `--opponent self` mode), `mothman_spell_unit_cmds`, and `loops_simulated` look sensible.
- **Zero** stray containers (`podman ps -q | wc -l == 0`) or stray `SC2_x64` processes.

### 4. Visually Inspect & Finalize

1. Read `/tmp/arena_preview_<new-id>/<new-id>.png` with `read_file` to verify real-3D framing, terrain (ramp/chasm/minerals), and combat flow.
2. Validate the entire catalog:
```bash
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py --validate
```
3. Describe and push cleanly following the repo's `jj` workflow.
