# Supported StarCraft II Units, Terrains, Categories & Upgrades (Tactics Arena 3.0)

All canonical unit keys, categories, terrain modes, scoring modes, and selective upgrades below are supported in `tools/arena-scenarios.json` (`schema_version: 3`, `213` scenarios / `66` `fast_core`), `scripts/add_scenario.py`, and `tools/sc2-tactics-arena.py` (Blizzard 4.10 `Base75689`). Value formula = `minerals + 1.5 * gas`.

## 3-Tier & 16-Category Architecture (`--suite`, `--tier`, `--category`, `--scoring-mode`)

- **Suites (`--suite`):**
  - `core` (default when unfiltered): `66` `fast_core: true` flagship scenarios covering **all 16 categories** for crisp inner-loop validation.
  - `all`: all `213` scenarios (bounded monotonic upgrade-chain batches, max `10` scenarios/container).
- **Tiers (`tier`):**
  - `canonical` (`156`): Core apples-to-apples micro suite across 13 combat categories.
  - `econ-harass` (`52`): `26` `runby-defense` (`scoring_mode: "mineral-defense"`, `use_main_base: true`) + `26` `runby-offense` (`scoring_mode: "worker-runby"`, `use_p2_main_base: true`).
  - `regression` (`5`): Replay-extracted production/benchmark failure scenarios (`r01, r02, r03, r05, r06`).
- **16 Tactical Categories (`--category`):**
  `detection-snipe` (`20`), `stalker-blink` (`12`), `runby-offense` (`26`), `runby-defense` (`26`), `stasis-ward` (`8`), `yamato-jump` (`10`), `transport-nydus` (`14`), `burrow-micro` (`14`), `spellcasters` (`20`), `kiting-concave` (`20`), `flank-surround` (`6`), `high-ground-ramp` (`7`), `air-superiority` (`9`), `early-rush-defense` (`10`), `capital-endgame` (`6`), `regression` (`5`).
- **Scoring Modes (`scoring_mode`):**
  - `combat`: KO / Points (`>= 1.25×` Win, `<= 0.80×` Loss, `0.80–1.25×` Draw) + `pf_destroyed`, `detectors_destroyed`, `enemy_workers_killed`.
  - `mineral-defense`: Active P1 main-base mining defense (`net_econ_score = minerals_gathered + enemy_killed_val - 50 * workers_lost >= pass_net_econ_min`).
  - `worker-runby`: Active P1 raid against P2's mining main mineral line (`enemy_workers_killed >= pass_workers_killed_min` and `runby_score = workers_killed * 100 - 0.5 * our_lost_val + 0.5 * enemy_combat_killed_val > 0`, plus `enemy_minerals_denied`).

## Terrain Modes (`--terrain`)

| Terrain | Real SC2 Map Geometry Used | Best For |
| --- | --- | --- |
| `open` | Central flat `16x10` pathable clearing | Standard micro, Blink-Back/Forward, Detection-Snipe, Burrow, Spellcasters |
| `high-ground-ramp` | Walkable elevation ramp (`terrain_height` diff `>= 12`, `--high-ground-side p1\|p2`) | TvT Tank/Viking siege lines, Lurker ramp holds, uphill Blink/Ravager breaks |
| `flank-surround` | Expanded `20x16` open clearing | 2-prong pincer surrounds (`@dx,dy` on opposite flanks) |
| `cliff-air-chasm` | Pathable ground cliff edge bordering unpathable deadspace/chasm | Yamato/Jump BCs, Phoenix/Muta, Capital Air (`Tempest`/`Carrier`/`BroodLord`) |
| `mineral-line-harass` | Real main (`use_main_base` / `use_p2_main_base`) or expansion mineral line | `worker-runby`, `mineral-defense`, Stasis mineral harass, early 12-Pool holds |

## Selective Per-Player Upgrades (`--upgrades`, `--p1-upgrades`, `--p2-upgrades`)

- **Zerg:** `Burrow`, `TunnelingClaws`, `GlialReconstitution`, `MetabolicBoost`, `AdrenalGlands`, `CentrifugalHooks`, `LurkerRange`, `AdaptiveTalons`, `GroovedSpines`, `MuscularAugments`, `ChitinousPlating`, `AnabolicSynthesis`, `NeuralParasite`, `OverlordSpeed` (`PneumatizedCarapace`/`VentralSacks` alias)
- **Protoss:** `Blink`, `Charge`, `ResonatingGlaives`, `ThermalLance`, `GraviticDrive`, `GraviticBoosters`, `PsiStorm`, `ShadowStride`, `ProtossGroundWeapons1`, `ProtossGroundWeapons2`, `ProtossGroundWeapons3`
- **Terran:** `Stim`, `CombatShield`, `ConcussiveShells`, `DrillingClaws`, `SmartServos`, `InfernalPreigniter` (`BlueFlame` alias), `BansheeCloak`, `HyperflightRotors`, `PersonalCloaking`, `AdvancedBallistics`, `WeaponRefit`, `Cloak` (shorthand for `BansheeCloak` + `PersonalCloaking`)
- **Pre-Cloak Flags:** `p1_pre_cloaked: true` / `p2_pre_cloaked: true` automatically cloak spawned Banshees/Ghosts at fight start.
- **Pre-Loaded Transports (`p1_loaded_transports` / `p2_loaded_transports`):** `medivac` (`54`), `warp-prism` (`81`), `overlord-transport`/`dropperlord` (`893`), `nydus-canal`/`nydus-worm` (`142`), `nydus-network` (`95`), `bunker` (`24`).

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
| `warp-prism` | 81 | air-transport (rear) | 250.0 |
| `probe` | 84 | worker | 50.0 |
| `photon-cannon` | 66 | static-detector (2x2 G+A, auto-powered by Pylon) | 150.0 |
| `pylon` | 60 | static-power (2x2 unarmed) | 100.0 |
| `shield-battery` | 1910 | static-support (2x2 unarmed) | 100.0 |
| `oracle-stasis-trap` / `stasis-trap` | 732 | static-stasis-ward trap | 50.0 |

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
| `medivac` | 54 | air-transport (rear) | 250.0 |
| `viking-fighter` | 35 | air (mid-rear) | 262.5 |
| `viking-assault` | 34 | ranged (mid) | 262.5 |
| `banshee` | 55 | air-cloak (rear) | 300.0 |
| `raven` | 56 | air-caster-detector (rear) | 400.0 |
| `liberator` | 689 | air-siege (rear) | 375.0 |
| `liberator-ag` | 734 | air-siege (rear) | 375.0 |
| `battlecruiser` | 57 | air-capital (far-rear) | 850.0 |
| `scv` | 45 | worker | 50.0 |
| `planetary-fortress` | 130 | static-fortress (5x5 ground splash) | 775.0 |
| `missile-turret` | 23 | static-detector (2x2 air-only) | 100.0 |
| `bunker` | 24 | static-transport (3x3) | 100.0 |

## Zerg Units (Including Burrowed Variants, Transports & Structures)

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
| `overlord` | 106 | air-supply (rear) | 100.0 |
| `overlord-transport` / `dropperlord` | 893 | air-transport (rear) | 150.0 |
| `spore-crawler` | 99 | static-detector (2x2 air-only) | 125.0 |
| `spine-crawler` | 98 | static-defense (2x2 ground-only) | 150.0 |
| `nydus-canal` / `nydus-worm` | 142 | static-nydus-exit (3x3 transport) | 100.0 |
| `nydus-network` | 95 | static-nydus-network (3x3 transport) | 450.0 |
| `creep-tumor-burrowed` | 137 | creep-source (unarmed) | 0.0 |
| `drone` / `drone-burrowed` | 104 / 116 | worker | 50.0 |
