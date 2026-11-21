---
name: add-arena-scenario
description: >-
  Add, edit, extract from replays, list, validate, and 3D-preview custom StarCraft II
  micro-skirmish scenarios in Mothman's Real-SC2 Tactics Arena 3.0 (`tools/arena-scenarios.json`
  and `tools/sc2-tactics-arena.py`), including Mothman-vs-Mothman self-play (`--opponent self`),
  `--suite core|all` and `--category` filters, `worker-runby` and `mineral-defense` econ scoring,
  pre-loaded transports/Nydus/Stasis Traps, real SC2 terrain modes (`high-ground-ramp`,
  `flank-surround`, `cliff-air-chasm`, `mineral-line-harass`), and selective per-player
  upgrades/burrow/cloak. Use whenever the user asks to add an arena scenario, turn a match
  replay fight into an arena duel, test specific unit compositions or self-play matchups, or
  manage scenarios in the tactics arena.
---

# Add or Edit a Mothman Tactics Arena 3.0 Scenario

This skill makes it fast and safe to add, inspect, validate, and run real-`SC2_x64` combat scenarios in Mothman's **Tactics Arena 3.0** (`213` validated scenarios across `16` tactical categories, `3` tiers, `3` scoring modes, `5` real SC2 terrain modes, selective per-player upgrades, pre-loaded transports/Nydus/Stasis Traps, and Mothman-vs-Mothman self-play) and immediately preview them in **real 3D StarCraft II H.264 `.mp4` video** with the live SC2 Replay-Viewer Top HUD + Peak-Clash `960×720` PNG.

## Architecture

- **Scenario catalog (human-editable JSON):** `tools/arena-scenarios.json` (`schema_version: 3`, `213` scenarios, `66` `fast_core` flagships)
  - **Tiers (`tier`):** `canonical` (`156`) | `econ-harass` (`52`: `26` `worker-runby` + `26` `mineral-defense`) | `regression` (`5`)
  - **Scoring Modes (`scoring_mode`):**
    - `combat` (`161`): Full-duration/KO/Points trade evaluation (`>= 1.25×` Points Win, `<= 0.80×` Points Loss, `0.80–1.25×` Draw), plus `pf_destroyed`, `detectors_destroyed`, and `enemy_workers_killed` telemetry.
    - `mineral-defense` (`26`, `use_main_base: true`): P1 actively mines at its real main TownHall + mineral line while defending vs P2 harass; grades `net_econ_score = minerals_gathered + enemy_killed_val - 50 * workers_lost >= pass_net_econ_min`.
    - `worker-runby` (`26`, `use_p2_main_base: true`): Symmetric mirror — P1 raids P2's actively mining main mineral line (+ realistic light home defense); grades `enemy_workers_killed >= pass_workers_killed_min` and `runby_score = workers_killed * 100 - 0.5 * our_lost_val + 0.5 * enemy_combat_killed_val > 0`, while reporting `enemy_minerals_denied`.
  - **16 Tactical Categories (`category`):** `detection-snipe` (`20`), `stalker-blink` (`12`), `runby-offense` (`26`), `runby-defense` (`26`), `stasis-ward` (`8`), `yamato-jump` (`10`), `transport-nydus` (`14`), `burrow-micro` (`14`), `spellcasters` (`20`), `kiting-concave` (`20`), `flank-surround` (`6`), `high-ground-ramp` (`7`), `air-superiority` (`9`), `early-rush-defense` (`10`), `capital-endgame` (`6`), `regression` (`5`).
- **Arena 3.0 runner & 3D renderer:** `tools/sc2-tactics-arena.py`
  - **Suite & category selection:**
    - `--suite core` (default when unfiltered): runs the `66` `fast_core: true` flagship scenarios covering **every** category for crisp inner loops.
    - `--suite all`: runs all `213` scenarios (bounded monotonic upgrade-chain batches, max `10` scenarios/container).
    - `--category <cat[,cat2]>` (e.g. `--category detection-snipe` or `--category runby-offense,runby-defense`): targeted micro sweep in ~20–40s.
    - `--list` and `--validate`: list matching scenarios with category/tier/race counts and validate the entire catalog offline (no SC2 required).
  - Supports `--opponent dummy` (default focus-firing MicroDummy with transport drop, Widow Mine burrow, Oracle Pulsar Beam, Liberator AG, and static defense targeting) and **`--opponent self`** (live Mothman-vs-Mothman self-play matching both `our_race` and `enemy_race`).
  - Supports filters: `--suite`, `--category`, `--race`, `--enemy-race`, `--scenario <substring>`, `--terrain <mode>`, `--source <tag>`, `--tier <tier>`.
- **Helper CLI:** [add_scenario.py](./scripts/add_scenario.py) (includes `--from-replay <path.SC2Replay>` peak-clash extractor)
- **Supported SC2 units, terrains & upgrades:** [unit-catalog.md](./references/unit-catalog.md)

## Pre-Loaded Transports, Stasis Wards, Nydus & Static Detectors

Arena 3.0 natively supports Blizzard 4.10 (`Base75689`) special entities and pre-fight setup:
- **Pre-loaded transports (`p1_loaded_transports` / `p2_loaded_transports`):**
  ```json
  "p1_loaded_transports": [
    {"transport": "medivac", "dx": 9.0, "dy": 0.0, "cargo": [["widow-mine", 2]]}
  ]
  ```
  Supported transports: `medivac` (`54`), `warp-prism` (`81`), `overlord-transport` / `dropperlord` (`893`), `nydus-canal` / `nydus-worm` (`142`), `nydus-network` (`95`), `bunker` (`24`). Units are loaded cleanly in an isolated `preload_spawn` → `preload_wait` phase before enemies spawn, and passenger values/capabilities are tracked in all combat & KO checks.
- **Pre-placed Stasis Traps:** `"oracle-stasis-trap"` / `"stasis-trap"` (`732`) for Stasis defuse drills.
- **Static Detectors & Defenses:** `"missile-turret"` (`23`), `"photon-cannon"` (`66`, auto-paired with a powering `"pylon"` `60`), `"spore-crawler"` (`99`), `"spine-crawler"` (`98`), `"planetary-fortress"` (`130`).
- **Additional LotV Upgrades:** `OverlordSpeed` (`1223`, aliased as `PneumatizedCarapace`/`VentralSacks`), `AnabolicSynthesis` (`263`), `GraviticDrive` (`1094`), `GraviticBoosters` (`1093`), `HyperflightRotors` (`799`), plus all existing Zerg/Protoss/Terran combat upgrades (`InfernalPreigniter`, `DrillingClaws`, `ShadowStride`, `WeaponRefit`, `Burrow`, `TunnelingClaws`, `LurkerRange`, `AdaptiveTalons`, `NeuralParasite`, `ChitinousPlating`, `Blink`, `ResonatingGlaives`, `Charge`, `ThermalLance`, `PsiStorm`, `Stim`, `CombatShield`, `ConcussiveShells`, `BansheeCloak`, `PersonalCloaking`, etc.).

## Workflow

### 1. List & Validate the Catalog (Offline, Instant)

```bash
python3 tools/sc2-tactics-arena.py --list --validate
python3 tools/sc2-tactics-arena.py --list --suite core
python3 tools/sc2-tactics-arena.py --list --category detection-snipe
```

### 2. Author or Extract a New Scenario

**Option A — Extract from a real `.SC2Replay` match fight (`--from-replay`):**
```bash
python3 .agents/skills/add-arena-scenario/scripts/add_scenario.py \
  --from-replay /path/to/match.SC2Replay \
  --slug match-peak-clash \
  --terrain open \
  --opponent self \
  --dry-run
```

**Option B — Add directly to `tools/arena-scenarios.json` (`schema_version: 3`):**
Specify `id`, `our_race`, `enemy_race`, `tier`, `category`, `fast_core`, `terrain`, `scoring_mode`, `description`, `p1_units`, `p2_units` (and optional `p1_loaded_transports` / `p2_loaded_transports`, `p1_upgrades` / `p2_upgrades`, `p1_pre_cloaked` / `p2_pre_cloaked`, `use_main_base` / `use_p2_main_base`, `pass_net_econ_min` / `pass_workers_killed_min`, `patterns`).

### 3. Run Real-SC2 Skirmishes & Render 3D H.264 `.mp4` Videos

Run the `66`-scenario flagship `--suite core`, a single `--category`, or `--suite all` (`213` scenarios), against MicroDummy (`--opponent dummy`) or Mothman-vs-Mothman Self-Play (`--opponent self`):
```bash
# Targeted category sweep (~20-40s) with 3D MP4 rendering:
python3 tools/sc2-tactics-arena.py \
  --mode duel \
  --opponent dummy \
  --category detection-snipe \
  --render-dir /tmp/arena_detection_snipe \
  --out /tmp/arena_detection_snipe/result.json

# Core flagship suite (~66 scenarios across all 16 categories):
python3 tools/sc2-tactics-arena.py \
  --mode duel --opponent self --suite core \
  --render-dir /tmp/arena_core_self \
  --out /tmp/arena_core_self/result.json

# Full 213-scenario sweep:
python3 tools/sc2-tactics-arena.py \
  --mode duel --opponent dummy --suite all \
  --out /tmp/arena_all_213.json
```

Verify from `result.json`:
- `p1_start_cnt` / `p2_start_cnt`, `applied_p1_upgrade_ids` / `applied_p2_upgrade_ids`, `pf_destroyed`, `detectors_destroyed`, `enemy_workers_killed`, and `runby_score` / `net_econ_score` (for econ-harass scenarios).
- **Zero** stray containers (`pgrep -cf '[p]odman' == 0`) or stray `SC2_x64` processes (`pgrep -cf '[S]C2_x64' == 0`).

### 4. Validate & Finalize

1. Inspect `/tmp/arena_.../<scenario-id>.png` with `read_file` to verify real-3D framing, live SC2 Replay-Viewer Top HUD, terrain, and combat flow.
2. Validate syntax and catalog integrity:
   ```bash
   python3 -m py_compile tools/sc2-tactics-arena.py && python3 tools/sc2-tactics-arena.py --list --validate
   ```
3. Describe and push cleanly following the repo's `jj` workflow.
