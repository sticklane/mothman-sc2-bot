# Supported StarCraft II Units for Tactics Arena Scenarios

All canonical unit keys below are supported in `tools/arena-scenarios.json`, `scripts/add_scenario.py`, and `tools/sc2-tactics-arena.py` (Blizzard 4.10 `Base75689` `UnitTypeId`s). Value formula = `minerals + 1.5 * gas`.

## Protoss

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

## Terran

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
| `widow-mine-burrowed` | 500 | trap (front-mid) | 112.5 |
| `medivac` | 54 | air-support (rear) | 250.0 |
| `viking-fighter` | 35 | air (mid-rear) | 262.5 |
| `viking-assault` | 34 | ranged (mid) | 262.5 |
| `banshee` | 55 | air-cloak (rear) | 300.0 |
| `raven` | 56 | air-caster (rear) | 400.0 |
| `liberator` | 689 | air-siege (rear) | 375.0 |
| `liberator-ag` | 734 | air-siege (rear) | 375.0 |
| `battlecruiser` | 57 | air-capital (far-rear) | 850.0 |
| `scv` | 45 | worker | 50.0 |

## Zerg

| Key | SC2 ID | Role (Default Formation Layer) | Value |
| --- | ---: | --- | ---: |
| `zergling` | 105 | melee (front) | 25.0 |
| `baneling` | 9 | melee-splash (front) | 87.5 |
| `ultralisk` | 109 | melee-heavy (front) | 575.0 |
| `roach` | 110 | ranged-front (front-mid) | 112.5 |
| `ravager` | 688 | ranged-caster (mid) | 250.0 |
| `hydralisk` | 107 | ranged (mid) | 175.0 |
| `queen` | 126 | caster (mid-rear) | 150.0 |
| `lurker-mp` | 502 | siege (mid-rear) | 375.0 |
| `lurker-mp-burrowed` | 503 | siege (mid-rear) | 375.0 |
| `infestor` | 111 | caster (rear) | 325.0 |
| `swarm-host` | 494 | siege (rear) | 212.5 |
| `mutalisk` | 108 | air (mid-rear) | 250.0 |
| `corruptor` | 112 | air (mid-rear) | 300.0 |
| `viper` | 499 | air-caster (rear) | 400.0 |
| `brood-lord` | 114 | air-capital (far-rear) | 675.0 |
| `overseer` | 129 | air-detector (rear) | 225.0 |
| `drone` | 104 | worker | 50.0 |

## Formation Geometry Cheat Sheet

- P1 (Mothman) spawns on the **left** (`dx < 0`), P2 (MicroDummy) spawns on the **right** (`dx > 0`).
- Typical total separation between front lines:
  - **7–9 tiles**: standard bio/gateway/roach-ling engagements
  - **10–12 tiles**: Siege Tank / Colossus / Lurker / Disruptor setups
  - **13–15 tiles**: Capital air siege (Tempests, Carriers, Brood Lords)
- Use explicit `@dx,dy` in `add_scenario.py` (e.g. `tempest:1@7.5,-2.5,tempest:1@7.5,0,tempest:1@7.5,2.5`) when you want a concave or anti-splash spread.
