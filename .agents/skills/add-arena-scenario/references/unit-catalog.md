# Supported StarCraft II Units, Terrains & Upgrades (Tactics Arena 2.0)

All canonical unit keys, terrain modes, and selective upgrades below are supported in `tools/arena-scenarios.json`, `scripts/add_scenario.py`, and `tools/sc2-tactics-arena.py` (Blizzard 4.10 `Base75689`). Value formula = `minerals + 1.5 * gas`.

## 3-Tier Scenario Architecture (`--tier`) & Scoring Modes (`--scoring-mode`)

- **Tiers (`tier`):**
  - `canonical` (default): Core apples-to-apples micro suite (`48` scenarios) tracked across loops.
  - `econ-harass`: Active main mineral-line harass defense (`scoring_mode: "mineral-defense"`, `4` scenarios `e01..e04`). Spawns enemy harass outside P1's actual starting main TownHall + mineral patches with `12–16` actively mining workers and grades `net_econ_score = minerals_gathered + enemy_killed_val - 50 * workers_lost >= pass_net_econ_min` over `960` loops.
  - `regression`: Replay-extracted production/benchmark failure scenarios (`source: "replay-extract"`, `origin_match_id`, `3` scenarios `r01..r03`).

## Terrain Modes (`--terrain`)

| Terrain | Real SC2 Map Geometry Used | Best For |
| --- | --- | --- |
| `open` | Central flat `16x10` pathable clearing | Standard baseline micro, backward-compatible `01..07` core suite |
| `high-ground-ramp` | Walkable elevation ramp (`terrain_height` diff `>= 12`, `--high-ground-side p1\|p2`) | TvT Tank/Viking siege lines, Lurker ramp holds, uphill dives |
| `flank-surround` | Expanded `20x16` open clearing | 2-prong pincer surrounds (`@dx,dy` on opposite flanks) |
| `cliff-air-chasm` | Pathable ground cliff edge bordering unpathable deadspace/chasm | Capital air (`Tempest`/`Carrier`/`BroodLord`) vs `Corruptor`/`Viper`/`Viking`/`Thor` |
| `mineral-line-harass` | Unoccupied expansion mineral field cluster | Early 12-Pool worker+army holds, Mutalisk/Oracle/Banshee/DT mineral harass |

## Selective Per-Player Upgrades (`--upgrades`, `--p1-upgrades`, `--p2-upgrades`)

- **Zerg:** `Burrow`, `TunnelingClaws`, `GlialReconstitution`, `MetabolicBoost`, `AdrenalGlands`, `CentrifugalHooks`, `LurkerRange`, `AdaptiveTalons`, `GroovedSpines`, `MuscularAugments`, `ChitinousPlating`, `NeuralParasite`
- **Protoss:** `Blink`, `Charge`, `ResonatingGlaives`, `ThermalLance`, `PsiStorm`, `ShadowStride`, `ProtossGroundWeapons1`, `ProtossGroundWeapons2`, `ProtossGroundWeapons3`
- **Terran:** `Stim`, `CombatShield`, `ConcussiveShells`, `DrillingClaws`, `SmartServos`, `InfernalPreigniter`, `BansheeCloak`, `PersonalCloaking`, `AdvancedBallistics`, `Cloak` (shorthand for both `BansheeCloak` + `PersonalCloaking`)
- **Pre-Cloak Flags:** `p1_pre_cloaked: true` / `p2_pre_cloaked: true` automatically cloak spawned Banshees/Ghosts at fight start.

## Protoss Units

| Key | SC2 ID | Role (Default Formation Layer) | Value |
| --- | ---: | --- | ---: |
| `zealot` | 73 | melee (front) | 100.0 |
| `adept` | 311 | ranged (mid) | 137.5 |
| `stalker` | 74 | ranged (mid) | 200.0 |
| `sentry` | 77 | caster (mid-rear) | 200.0 |
| `immortal` | 83 | heavy-ranged (front-mid) | 425.0 |
| `archon` | 141 | melee-heavy (front) | 550.0 |
| `dark-templar` | 76 | melee-cloak (front) | 312.5 |
| `high-templar` | 75 | caster (rear) | 275.0 |
| `colossus` | 4 | siege (rear) | 600.0 |
| `disruptor` | 694 | siege (rear) | 375.0 |
| `phoenix` | 78 | air (mid-rear) | 300.0 |
| `oracle` | 495 | air-caster (rear) | 375.0 |
| `void-ray` | 80 | air (mid-rear) | 475.0 |
| `tempest` | 496 | air-siege (far-rear) | 512.5 |
| `carrier` | 79 | air-capital (far-rear) | 725.0 |
| `observer` | 82 | air-detector (rear) | 137.5 |
| `warp-prism` | 81 | air-support (rear) | 250.0 |
| `probe` | 84 | worker | 50.0 |

## Terran Units

| Key | SC2 ID | Role (Default Formation Layer) | Value |
| --- | ---: | --- | ---: |
| `hellbat` | 484 | melee (front) | 100.0 |
| `hellion` | 53 | ranged-fast (front-mid) | 100.0 |
| `marauder` | 51 | ranged-front (front-mid) | 137.5 |
| `marine` | 48 | ranged (mid) | 50.0 |
| `reaper` | 49 | ranged-fast (front-mid) | 125.0 |
| `cyclone` | 692 | ranged-kiter (mid) | 300.0 |
| `thor` | 52 | heavy-ranged (front-mid) | 600.0 |
| `ghost` | 50 | caster (rear) | 337.5 |
| `siege-tank` | 33 | siege (rear) | 337.5 |
| `siege-tank-sieged` | 32 | siege (far-rear) | 337.5 |
| `widow-mine` | 498 | trap (front-mid) | 112.5 |
| `widow-mine-burrowed` | 500 | trap-burrowed (front-mid) | 112.5 |
| `medivac` | 54 | air-support (rear) | 250.0 |
| `viking-fighter` | 35 | air (mid-rear) | 262.5 |
| `viking-assault` | 34 | ranged (mid) | 262.5 |
| `banshee` | 55 | air-cloak (rear) | 300.0 |
| `raven` | 56 | air-caster (rear) | 400.0 |
| `liberator` | 689 | air-siege (rear) | 375.0 |
| `liberator-ag` | 734 | air-siege (rear) | 375.0 |
| `battlecruiser` | 57 | air-capital (far-rear) | 850.0 |
| `scv` | 45 | worker | 50.0 |
| `planetary-fortress` | 130 | static-fortress (5x5 ground splash) | 775.0 |
| `missile-turret` | 23 | static-detector (2x2 air-only) | 100.0 |

## Zerg Units (Including Burrowed Variants)

| Key | SC2 ID | Role (Default Formation Layer) | Value |
| --- | ---: | --- | ---: |
| `zergling` / `zergling-burrowed` | 105 / 119 | melee (front) | 25.0 |
| `baneling` / `baneling-burrowed` | 9 / 115 | melee-splash (front) | 87.5 |
| `ultralisk` / `ultralisk-burrowed` | 109 / 131 | melee-heavy (front) | 575.0 |
| `roach` / `roach-burrowed` | 110 / 118 | ranged-front (front-mid) | 112.5 |
| `ravager` / `ravager-burrowed` | 688 / 690 | ranged-caster (mid) | 250.0 |
| `hydralisk` / `hydralisk-burrowed` | 107 / 117 | ranged (mid) | 175.0 |
| `queen` / `queen-burrowed` | 126 / 125 | caster (mid-rear) | 150.0 |
| `lurker-mp` / `lurker-mp-burrowed` | 502 / 503 | siege (mid-rear) | 375.0 |
| `infestor` / `infestor-burrowed` | 111 / 127 | caster (rear) | 325.0 |
| `swarm-host` / `swarm-host-burrowed` | 494 / 493 | siege (rear) | 212.5 |
| `mutalisk` | 108 | air (mid-rear) | 250.0 |
| `corruptor` | 112 | air (mid-rear) | 300.0 |
| `viper` | 499 | air-caster (rear) | 400.0 |
| `brood-lord` | 114 | air-capital (far-rear) | 675.0 |
| `overseer` | 129 | air-detector (rear) | 225.0 |
| `drone` / `drone-burrowed` | 104 / 116 | worker | 50.0 |
