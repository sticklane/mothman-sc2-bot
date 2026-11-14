# Mothman SC2 Bot — Module Architecture

This document describes the pure-Racket 5-layer module architecture, Typed Racket boundaries, build-order specifications, spatial/perception/placement stack, tactical micro engines, and structured `[SCBOT_STATE]` telemetry logging for Mothman.

---

## 1. 5-Layer Directed Acyclic Module Architecture

All runtime modules under `lib/`, `sim/`, and `bots/` form a strict Directed Acyclic Graph (DAG). Lower layers have zero dependencies on upper layers, and domain data/math/inference modules use `#lang typed/racket/base` while dynamic untyped orchestration layers use `#lang racket/base` (or `#lang racket` for legacy verifier/fuzzer scripts).

```
Layer 4 (Bot Runtime, Wire Protocol, Ladder & Bots)
  bots/Mothman*.rkt -> lib/bot-runtime.rkt, lib/econ-ledger.rkt, lib/sc2-combat-eval.rkt, compiler/syntax.rkt
  sim/racket-sc2-ladder-main.rkt -> lib/bot-runtime.rkt, lib/sc2-protobuf-ws.rkt, lib/sc2-common.rkt
  lib/bot-runtime.rkt -> sc2-types, sc2-common, sc2-bayesian, sc2-game-constants, sc2-geometry, sc2-pathing, sc2-placement, sc2-combat-eval, build-orders, sc2-logging, perception-grid, econ-ledger, tactics-sim, human-cortex, mirror-mind-predictor, priority-macro-brain, compiler/syntax
  lib/sc2-protobuf-ws.rkt -> lib/sc2-game-constants.rkt, lib/sc2-typed-commands.rkt
        ^
Layer 3 (Macro Economy, Opponent Modeling, Human Realism & Facade)
  lib/econ-ledger.rkt -> compiler/syntax.rkt, lib/sc2-common.rkt, lib/sc2-types.rkt, lib/sc2-game-constants.rkt, lib/build-orders.rkt
  lib/priority-macro-brain.rkt -> lib/sc2-common.rkt, lib/sc2-game-constants.rkt, lib/build-orders.rkt, lib/econ-ledger.rkt
  lib/mirror-mind-predictor.rkt -> lib/sc2-common.rkt, lib/sc2-types.rkt, lib/build-orders.rkt, lib/sc2-bayesian.rkt, lib/sc2-game-constants.rkt, lib/sc2-combat-eval.rkt
  lib/human-cortex.rkt -> lib/sc2-bayesian.rkt, lib/sc2-game-constants.rkt
  lib/tactics-sim.rkt (facade) -> sc2-geometry, sc2-pathing, sc2-placement, sc2-combat-eval, lib/tactics/*
        ^
Layer 2 (Perception Grid, Placement Solvers & Per-Tactic Modules)
  lib/perception-grid.rkt [TR] -> lib/sc2-types.rkt, lib/sc2-bayesian.rkt, lib/sc2-pathing.rkt
  lib/sc2-placement.rkt -> lib/sc2-types.rkt, lib/sc2-geometry.rkt, lib/sc2-pathing.rkt, lib/sc2-bayesian.rkt, lib/sc2-game-constants.rkt
  lib/tactics/order-ledger.rkt -> sc2-common, sc2-game-constants, sc2-geometry, sc2-combat-eval
  lib/tactics/arena-minimax.rkt -> sc2-common, sc2-game-constants, sc2-combat-eval, order-ledger
  lib/tactics/zerg-burrow-micro.rkt [TR] -> sc2-types, sc2-game-constants, sc2-combat-eval
  lib/tactics/stealth-shimmer-response.rkt [TR] -> sc2-types, sc2-game-constants
  lib/tactics/terran-addon-swap.rkt -> sc2-common, sc2-game-constants
        ^
Layer 1 (Typed Domain Libraries & Build Orders)
  lib/sc2-combat-eval.rkt [TR] -> sc2-types, sc2-game-constants, sc2-pathing (compute-concave-arc), perception-grid (combat-measure)
  lib/sc2-pathing.rkt [TR] -> lib/sc2-types.rkt, lib/sc2-geometry.rkt
  lib/sc2-geometry.rkt [TR] -> lib/sc2-types.rkt
  lib/sc2-bayesian.rkt [TR] -> lib/sc2-types.rkt
  lib/sc2-logging.rkt [TR] -> lib/sc2-types.rkt
  lib/build-orders.rkt [TR] -> lib/sc2-types.rkt, lib/build-orders/*.rkt
        ^
Layer 0 (Typed Domain Types, Wire Witnesses & LotV Game Constants)
  lib/sc2-game-constants.rkt [TR] -> lib/sc2-types.rkt
  lib/sc2-common.rkt [TR] -> lib/sc2-types.rkt
  lib/sc2-types.rkt [TR]
  lib/sc2-typed-commands.rkt [TR]
```

*Note on the `sc2-combat-eval.rkt` <-> `perception-grid.rkt` dependency:* `lib/sc2-combat-eval.rkt` imports only `combat-measure` (and its struct predicate/accessors) via `(only-in "perception-grid.rkt" ...)`, while `lib/perception-grid.rkt` depends only on `sc2-types.rkt`, `sc2-bayesian.rkt`, and `sc2-pathing.rkt`. The module graph remains strictly acyclic.

Supporting audit, verification, tooling, and packaging modules sit alongside Layers 3–4 without adding cycles into Layers 0–2:
- Verification & audits: `lib/state-machine-verifier.rkt`, `lib/bot-crash-fuzzer.rkt` (including `step-sc2-mastermind!` and `fuzz-sc2-mastermind-suite!`), `lib/pro-replay-starvation-audit.rkt`, `lib/sc2-proto-wire-verifier.rkt`, `lib/sc2-mpq-replay-parser.rkt`.
- DSL compiler, tooling & ladder packaging: `compiler/syntax.rkt` (`#lang sc-bot` posture/state-machine/coeffect-grade syntax), `tools/*.rkt`, `ladder/build-aiarena-zip.rkt` (builds only the 4 active ladder archives `ladder/Mothman-{X,Z,T,P}.zip` plus `ladder/.cache/mothman_standalone_elf`; legacy `Mothman.zip` and `Mothman-R.zip` are retired).

---

## 2. Typed Racket Boundaries & Interop Conventions

Mixing `#lang typed/racket/base` libraries with untyped `#lang racket/base` callers introduces specific contract boundary rules that the codebase handles uniformly:

1. **Untyped Observation/Unit Hash Access (`typed/racket/unsafe` + `dyn-hash-ops`)**:
   Typed Racket's `hash/c` contract cannot cleanly wrap arbitrary untyped mutable/immutable hashes when passing heterogeneous observation payloads across module boundaries. Typed modules (`lib/sc2-combat-eval.rkt`, `lib/tactics/zerg-burrow-micro.rkt`, `lib/tactics/stealth-shimmer-response.rkt`, and `lib/sc2-game-constants.rkt`) therefore isolate dynamic hash operations inside a local `(module dyn-hash-ops racket/base ...)` submodule (`dyn-hash-ref`, `dyn-hash-has-key?`, `dyn-hash-set!`) imported through `unsafe-require/typed` with total `Any` signatures. Callers still receive deterministic fallback coercion through `lib/sc2-types.rkt` helpers (`safe-real`, `safe-exact-int`, `safe-nonneg-int`).

2. **Higher-Order Callback & Grid Accessor Wrapping**:
   When untyped code passes procedures into Typed Racket (for example, map grid lookup callbacks or variable-arity frame hooks), exporting/importing raw `Any` function values can fail higher-order chaperone checks.
   - `lib/sc2-pathing.rkt` introduces `GridRef2` (`(U False (-> Integer Integer Any))`) and `LocalBfsCb` / `LocalBfsVal` via a local `unsafe-require/typed` shim (`grid-ref-ops`, `bfs-ops`) inside `extract-map-grid-accessors` and `make-local-4conn-bfs`.
   - `lib/sc2-game-constants.rkt` uses `(module dispatch-dyn racket/base ...)` (`call-1-or-2`, `call-2-or-3`) for `Cb12` / `Cb23` hook arity adaptation and wraps `set-mutable?`, `set-member?`, `set-add!` via `unsafe-require/typed racket/set`.

3. **`aabb-overlaps?` Disambiguation**:
   - `lib/sc2-game-constants.rkt` exports a 5-argument `aabb-overlaps?` operating on `reserved-aabb` and scalar center/half-extents.
   - `lib/sc2-geometry.rkt` exports a 2-argument `(-> aabb2d aabb2d Boolean)` `aabb-overlaps?` (alongside the unambiguous alias `aabb2d-overlaps?`).
   - Any module importing both (`lib/sc2-placement.rkt`, `lib/tactics-sim.rkt`, `tests/run-all-tests.rkt`) uses `(except-in "sc2-geometry.rkt" aabb-overlaps?)`.

4. **Strict Flonum vs. `Real` Boundaries**:
   - Transparent structs `point2d` and `aabb2d` in `lib/sc2-types.rkt` declare `Float` (`Flonum`) fields, so untyped callers constructing `(point2d x y)` or `(aabb2d cx cy hw hh)` must pass inexact floats (`10.0`, not exact `10`).
   - Functional APIs such as `dist-2d`, `dist-sq-2d`, `clamp-point-to-map`, `prob->odds`, and `fow-ghost-step-diffusion!` accept `Real` (or mutable `(Vectorof Float)` in the case of `fow-ghost-step-diffusion!`) and convert internally with `->float`.

---

## 3. Build-Orders Directory (`lib/build-orders/*.rkt`)

All build orders and opponent tech-progression trees live as standalone `#lang typed/racket/base` Racket modules under `lib/build-orders/`, each requiring `"../sc2-types.rkt"`. This replaces the legacy monolithic `data/pro_build_orders.sexp` file with statically typed, compile-time-checked definitions.

### Matchup Build Specifications (9 files)

Each matchup module exports a single 9-field `build-order-spec` struct (`matchup`, `race`, `name`, `archetype`, `description`, `steps` as `(Listof pro-bo-goal)`, 7-minute empirical `supply-curve` checkpoints as `(Listof SupplyCurvePoint)` where each entry is `(minute . (workers . army-supply))` supporting fractional `Real` checkpoints, `unit-timings` as `(Listof pro-unit-timing)`, and `upgrade-timings` as `(Listof pro-upgrade-timing)`):

| Matchup | File | Exported Binding | Build Steps | Unit Timings | Upgrade Timings |
| :--- | :--- | :--- | :---: | :---: | :---: |
| `ZvZ` | `lib/build-orders/zvz-16-hatch-pool-bane.rkt` | `ZvZ-BUILD-ORDER` | 19 | 9 | 6 |
| `ZvT` | `lib/build-orders/zvt-16-hatch-macro-roach-ravager.rkt` | `ZvT-BUILD-ORDER` | 22 | 9 | 6 |
| `ZvP` | `lib/build-orders/zvp-16-hatch-3-base-roach-hydra.rkt` | `ZvP-BUILD-ORDER` | 22 | 8 | 6 |
| `TvZ` | `lib/build-orders/tvz-reaper-fe-1-1-1-hellion-banshee.rkt` | `TvZ-BUILD-ORDER` | 24 | 8 | 6 |
| `TvT` | `lib/build-orders/tvt-reaper-fe-double-gas-raven-tank.rkt` | `TvT-BUILD-ORDER` | 26 | 9 | 4 |
| `TvP` | `lib/build-orders/tvp-reaper-fe-3-rax-stim-medivac.rkt` | `TvP-BUILD-ORDER` | 24 | 9 | 6 |
| `PvZ` | `lib/build-orders/pvz-1-gate-fe-stargate-oracle-archon.rkt` | `PvZ-BUILD-ORDER` | 22 | 8 | 6 |
| `PvT` | `lib/build-orders/pvt-1-gate-fe-blink-robo-colossus.rkt` | `PvT-BUILD-ORDER` | 22 | 8 | 6 |
| `PvP` | `lib/build-orders/pvp-2-gate-cyber-expand-blink-immortal.rkt` | `PvP-BUILD-ORDER` | 22 | 7 | 4 |

### Race Tech-Progression Trees (3 files)

Opponent scouting and `mirror-mind-predictor.rkt` tech inference use three DAGs of `build-order-tree-node` structs (`id`, `race`, `parent-id`, `children-ids`, `path-buildings`, `step-buildings`, `unlocked-units`, `unlocked-upgrades`, `archetype`, `min-frame`, `min-gas-bldgs`, `step-min-cost`, `step-gas-cost`, `step-build-frames`, `prior-weight`):

- `lib/build-orders/zerg-tech-tree.rkt` -> `ZERG-BUILD-ORDER-TREE` (13 nodes)
- `lib/build-orders/terran-tech-tree.rkt` -> `TERRAN-BUILD-ORDER-TREE` (12 nodes)
- `lib/build-orders/protoss-tech-tree.rkt` -> `PROTOSS-BUILD-ORDER-TREE` (10 nodes)

### How Engineers Review, Edit, and Access Builds

1. To modify an opening, timing benchmark, or supply curve, edit the corresponding file in `lib/build-orders/`:
   - `pro-bo-goal` uses 6 fields `(pro-bo-goal kind target-sym target-count min-supply prereq-ready-sym target-sec)` where `kind` is `'build`, `'expand`, `'morph`, `'train`, or `'research` and `target-sec` is the empirical LotV Faster-speed target clock time in seconds (`22.4` frames/sec; `make-pro-bo-goal` defaults `target-sec` to `0.0`).
   - `pro-unit-timing` uses `(pro-unit-timing unit-sym target-count min-supply target-sec prereq-ready-sym)` for cumulative unit count benchmarks.
   - `pro-upgrade-timing` uses `(pro-upgrade-timing upgrade-sym start-sec complete-sec min-supply prereq-ready-sym)` for research start/completion benchmarks (`lib/sc2-types.rkt` and `lib/sc2-common.rkt` both export `pro-unit-timing` and `pro-upgrade-timing`).
2. `lib/build-orders.rkt` aggregates all 9 specs into `ALL-BUILD-ORDER-SPECS` and exposes:
   - Typed lookup & step accessors: `lookup-build-order-for-matchup`, `pro-build-order-steps-for-matchup`, `pro-supply-curve-target`.
   - Typed timing helpers: `pro-unit-timings-for-matchup`, `pro-upgrade-timings-for-matchup`, `due-pro-unit-timings` (at `frame = 0` checks `supply-used >= min-supply`; at `frame > 0` activates within a `15.0`s lookahead or when `supply-used >= min-supply` within a `30.0`s lead window of `target-sec`, expiring after `target-sec + late-window-sec` [default `180.0`s] or past `target-sec + 60.0`s once `supply-used >= min-supply + 16`), `due-pro-upgrade-timings` (at `frame = 0` checks `supply-used >= min-supply`; at `frame > 0` activates within `15.0`s of `start-sec` or when `supply-used >= min-supply` within a `30.0`s lead window, expiring after `complete-sec + late-window-sec` [default `240.0`s]), `pro-unit-timing->bo-goal`, `pro-upgrade-timing->bo-goal`.
   - Indexed tech-tree lookups: `ZERG-BO-NODE-BY-ID`, `TERRAN-BO-NODE-BY-ID`, `PROTOSS-BO-NODE-BY-ID`, `lookup-race-build-order-tree`, `lookup-race-bo-node-by-id`.
   - Backward-compatible S-expression view: `PRO-BUILD-ORDER-DB`, `find-matchup-entry`, and `select-pro-build-order` synthesized directly from `ALL-BUILD-ORDER-SPECS` (including step `(sec ...)`, `(unit-timings ...)`, and `(upgrade-timings ...)`).
3. `lib/econ-ledger.rkt`, `lib/priority-macro-brain.rkt`, and `lib/mirror-mind-predictor.rkt` consume these single-source bindings (`lib/econ-ledger.rkt` re-exports `pro-bo-goal`, `make-pro-bo-goal`, `pro-unit-timing`, `pro-upgrade-timing`, and the `pro-*-timings*` helpers):
   - **`lib/econ-ledger.rkt` (`evaluate-build-order-next-step`)**: activates canonical steps when `supply-used >= min-supply` OR (at `frame > 0` with `target-sec > 0.0`) `elapsed-sec >= target-sec`, appending `due-pro-upgrade-timings` and `due-pro-unit-timings` at `frame > 0`.
   - **`lib/priority-macro-brain.rkt` (`collect-due-bo-context`, `step-priority-macro-brain`)**: combines supply-due and clock-due (`frame / 22.4`) steps with Track 2c timing urgency plans (`'timing-upgrade-plan` at utility `460.0` once `elapsed-sec >= start-sec` or `438.0` in 15s lookahead, damped by `under-sat-econ?` to `428.0`/`422.0` and `140.0` under non-defensive attack; `'timing-unit-plan` at `436.0` once `elapsed-sec >= target-sec` when saturated or `424.0` in lookahead / `under-sat-econ?`, `420.0` when non-peaceful, with `queen-sat-defer?` clamping excess Queens to `120.0` and `queen-defer?` to `80.0` across Track 2/2c), feeds all clock-due goals into `find-all-broken-tech-dependencies`, and preserves `pro-bo-goal-target-sec` via `lookup-timing-sec-for-sym`.

---

## 4. Spatial, Pathing, Placement & Perception Stack + Bayesian Inference

### `lib/sc2-types.rkt` & `lib/sc2-common.rkt` (Layer 0)
Defines canonical `Race`, `KnownRace`, `MatchupSym`, `SupplyCurvePoint`, `point2d`, `aabb2d`, 6-field `pro-bo-goal` (with `target-sec` + `make-pro-bo-goal`), `pro-unit-timing`, `pro-upgrade-timing`, 9-field `build-order-spec`, race/matchup normalizers (`normalize-race`, `normalize-known-race`, `resolve-matchup-symbol`), and total safe coercion helpers (`safe-real`, `safe-exact-int`, `safe-nonneg-int`, `clamp-prob`, `dist2d`). (`lib/sc2-common.rkt` re-exports the total helpers plus `pro-unit-timing` and `pro-upgrade-timing`.)

### `lib/sc2-bayesian.rkt` (Layer 1 — Bayesian Inference)
Single source of truth for all probabilistic updating and divergence calculations:
- Odds & log-odds transforms: `prob->odds`, `odds->prob`, `prob->log-odds`, `log-odds->prob`.
- Likelihood-ratio updating: `bayesian-posterior-from-likelihoods` (clamped `[0.01, 0.99]` posterior over active `(evidence? . lr)` pairs) and `bayesian-categorical-posterior` (Dirichlet-smoothed normalization).
- Divergence & FoW diffusion: `hellinger-distance` and `fow-ghost-step-diffusion!` (1D sector Markov diffusion conserving probability mass `1.0` while collapsing observed visible empty cells to `0.0`).
- Signal evaluators: `compute-bayesian-pad-camped-posterior`, `evaluate-bluff-posterior-from-signals`, `evaluate-strategic-posteriors-from-signals` -> `bayesian-strategic-priors`.

### `lib/sc2-geometry.rkt` (Layer 1 — 2D Spatial Primitives)
Typed 2D primitives re-exporting `point2d` and `aabb2d`:
- Distance & vector stepping: `dist-sq-2d`, `dist-2d`, `chebyshev-dist-2d`, `manhattan-dist-2d`, `point-lerp-2d`, `step-toward-2d`, `step-away-2d`, `clamp-point-to-map`, `point-to-segment-dist`, `point-in-circle?`, `centroid-2d`.
- Grid snapping & anchors: `quantize-cell-2.5`, `snap-2x2-coord` (integers `x.0, y.0`), `snap-3x3-coord` (half-integers `x.5, y.5`), `offset-defense-anchor`.
- Overlap geometry: `aabb-overlaps?`, `aabb2d-overlaps?`, `building-footprint-half-extent`, `footprint-overlaps?`, `footprints-disjoint?`, `footprints-share-edge?`, `footprints-touch-gap`.

### `lib/sc2-pathing.rkt` (Layer 1 — Chokes, Grids, Zippers, Flow Fields & Flanking)
- Choke representation & zipper: `(struct-out choke-point)` (`x`, `y`, `radius`, `terrain-advantage`), `DEFAULT-CHOKES` / `DEFAULT-CHOKE-POINTS`, `lakefill-choke-decomposition`, `morton-encode-2d`, `morton-decode-2d`, and persistent `huet-zipper` (`make-zipper`, `zipper-move-left`, `zipper-move-right`, `zipper-move-to-index`, `zipper-checkpoint`, `zipper-rollback`, `zipper-update`).
- Map grids & pathing: `extract-map-grid-accessors`, `footprint-buildable-at-height?`, `make-local-4conn-bfs`, `bfs-distance-grid` + `compute-bfs-distance-grid` + `bfs-distance-at`, `compute-flow-field-step`, `compute-concave-arc`, `compute-concave-surround-arc`, `compute-safe-flank-waypoints`.

### `lib/perception-grid.rkt` (Layer 2 — Persistent Typed Spatial/Temporal Memory)
Pure `#lang typed/racket/base` with zero dependency on any legacy Okasaki module:
- **Crit-Bit Trie over Morton 2D keys**: `perception-grid-ingest-frame!` indexes enemy units into persistent tries queried by `perception-grid-query-box`.
- **Hinze-Paterson 2-3 Monoidal Finger Tree**: `ft-empty`, `ft-from-list`, `ft-append`, `ft-to-list`, `ft-measure`, `split-by-dps` keyed by `combat-measure` (`count`, `dps`, `hp`, `cost`) for `O(log N)` vanguard/reserve splitting.
- **Huet Focus Zipper & Braun PQ & SBRL**: `perception-grid-get-choke-zipper`, internal threat Braun min-heap, Skew-Binary Random-Access List frame history (`perception-grid-snapshot-history`, `perception-grid-history->list`), `best-retreat-sector`, and re-exported `fow-ghost-step-diffusion!`.

### `lib/sc2-placement.rkt` (Layer 2 — Wall-In, Power, Creep & Expansion Solvers)
Pure `#lang racket/base` placement engine consuming `sc2-geometry`, `sc2-pathing`, `sc2-bayesian`, and `sc2-game-constants`:
- **Ramp & Choke Wall Solvers**: `solve-terran-ramp-wall` / `solve-terran-ramp-wall-analytical`, `solve-protoss-matchup-wall` / `solve-protoss-matchup-wall-analytical` / `solve-protoss-main-ramp-on-grids`, and Baba CSP `solve-choke-wall-in` with `wall-solution` gap/tightness validation.
- **Reservation & Spiral Search**: `terran-addon-pad-pos`, `terran-addon-pad-aabb`, `collect-placement-blocking-aabbs`, `make-wall-reserved-aabbs`, `placement-site-free?`, `solve-spiral-placement`.
- **Race Anchoring & Expansion Selection**: `pylon-powers-point?`, `find-unpowered-structures`, `select-pylon-power-anchor`, `next-creep-highway-target`, `safe-zerg-build-anchor`, `select-uncamped-expansion-pad` (using `compute-bayesian-pad-camped-posterior`).

---

## 5. Combat Evaluation & Per-Tactic Modules

### `lib/sc2-combat-eval.rkt` (Layer 1 — Strategic & Combat Evaluation)
Typed combat engine covering:
1. **Lanchester & Ledger**: `lanchester-snowball-advantage` (exponent `1.7`), `evaluate-compounding-ledger`.
2. **Personalities & Doctrines**: `MARV-MACRO-OPEN-PERSONALITY`, `SCARLETT-CREEP-SWARM-PERSONALITY`, `CLEM-TEMPO-MULTITASK-PERSONALITY`, `doctrine-loadout`, `step-doctrine-loadout!`.
3. **Counter Trees & Switching Cost**: `ZERG-COUNTER-TREE`, `PROTOSS-COUNTER-TREE`, `TERRAN-COUNTER-TREE`, `classify-enemy-archetype`, `compute-switching-cost`, `resolve-demand-pull`.
4. **Mastermind Loop, Limiter & PDA**: `step-double-reaction!`, refractory `ability-cast-limiter` (`throttle-ability-casts!`), `pda-trace` + `diagnose-bot-anomaly`.
5. **Typed FAP, Focus-Fire & Vectors**: `measure-combat-units`, `split-combat-units-by-dps`, `fap-unit`, `select-focus-fire-target`, `fap-simulate-combat`, `fap-evaluate-engagement`, `fap-posture-with-hysteresis`, `purplewave-traffic-retreat`, `compute-kite-vector`.

### Per-Tactic Submodules (`lib/tactics/*.rkt`) & Facade (`lib/tactics-sim.rkt`)
- `lib/tactics/order-ledger.rkt`: `in-progress-order-ledger`, command deduplication, `order-ledger-reconcile-observation!`, `order-ledger-record-issued!`, `order-ledger-facility-busy?`, `order-ledger-unit-in-attack-swing?`, `order-ledger-reserve-build-site!`, `order-ledger-resolve-build-coords!`.
- `lib/tactics/arena-minimax.rkt`: single-linkage arena clustering (`cluster-tactical-arenas`), multi-depth mirrored kinematic rollout (`simulate-mirrored-arena-pair`), regret-hedged minimax & commitment lock hysteresis (`evaluate-arena-minimax-and-regret!`, `resolve-committed-micro-action!`, `step-tactical-mirror-brain!`).
- `lib/tactics/zerg-burrow-micro.rkt`: Tunneling Claws Roach regen & escape (`execute-roach-tunneling-burrow-micro`), Infestor burrow-cast micro (`execute-infestor-burrow-cast-micro`), `lurker-burrow-action`, `drone-evade-burrow-action`.
- `lib/tactics/stealth-shimmer-response.rkt`: hidden/cloaked shimmer and burrow-ripple detection (`shimmer-target-unit?`, `mobile-or-static-detector-nearby?`, `execute-shimmer-and-burrow-ripple-response` emitting AoE skillshots or a single highest-energy Orbital Command `scanner-sweep`).
- `lib/tactics/terran-addon-swap.rkt`: lift-off & add-on swap planner (`plan-terran-addon-swap`) enforcing a `448`-frame relift cooldown, 1-to-1 claim lock, donor landing offset `(donor-x, donor-y + 4.0)`, and an `18.0`-tile enemy threat abort guard.
- `lib/tactics-sim.rkt`: unified `#lang racket/base` facade re-exporting `(except-in "sc2-geometry.rkt" aabb-overlaps?)`, `sc2-pathing.rkt`, `sc2-placement.rkt`, `sc2-combat-eval.rkt`, and all 5 `lib/tactics/*.rkt` modules.

---

## 6. Structured State Logging (`lib/sc2-logging.rkt`)

`lib/sc2-logging.rkt` provides typed structured observability over every decision step:
- **Snapshot Structs**:
  - `bot-mind-log-snapshot`: `frame`, `race`, `enemy-race`, `matchup`, `posture`, `personality`, `enemy-archetype`, `win-prob`, `confidence`, `bluff-posterior`, `rush-posterior`, `hidden-expand-posterior`, `tech-switch-posterior`, `pad-camped-posterior`.
  - `bot-goal-log-snapshot`: `active-bo-goal-sym`, `active-bo-goal-kind`, `active-bo-target-count`, `active-bo-target-sec` (`Float`), `reserved-minerals`, `reserved-gas`, `target-workers`, `target-army-supply`, `scheduled-ids`, `escrow-blocked-ids`.
  - `bot-tactics-log-snapshot`: `combat-posture`, `snowball-adv`, `retreat-sector`, `burrowed-count`, `shimmer-alerts`, `swapped-addons`, `issued-orders`.
  - `bot-step-log-record`: aggregates `(mind goals tactics)`.
- **Cadence, Extraction, Formatting & Serialization**:
  - `should-emit-step-log?` (`frame interval changed?` -> emits on frame `<= 1`, state change, or `(remainder frame interval) = 0`).
  - `extract-bot-step-log-record` safely coerces arbitrary mind/goal/tactics hashes or `pro-bo-eval-result` structs into a validated `bot-step-log-record` (extracting `pro-bo-goal-target-sec` into `active-bo-target-sec`).
  - `bot-step-log-record->hash` serializes nested `'frame`, `'matchup`, `'mind`, `'goals` (including `'active-bo-target-sec`), and `'tactics` hashes for telemetry streams.
  - `format-bot-step-log-line` emits canonical single-line `[SCBOT_STATE]` diagnostics (`goal=<kind>/<sym>@<sec>s(escrow=...)` when `active-bo-target-sec > 0.0`, or `goal=<kind>/<sym>(escrow=...)` when `<= 0.0`):
    ```text
    [SCBOT_STATE] f=672 matchup=TvP posture=timing-push pers=aggressive arch=stalker-colossus win=0.64 conf=0.81 bayesian=(bluff=0.12,rush=0.25,hexp=0.09,tsw=0.18,camp=0.04) goal=research/stimpack@308.0s(escrow=100M/100G,w=44,army=20) sched=() tactics=(pos=engage,adv=1.35,sec=4,orders=14)
    ```
- **Live Runtime & Ladder Wiring**:
  - `lib/bot-runtime.rkt` (`step-live-bot-runtime!`) extracts a `bot-step-log-record` on every step, attaches `'state-log` (`bot-step-log-record->hash`) in telemetry, and sets `'state-log-line` when `(should-emit-step-log? step-frame 22 state-changed?)` holds (`""` otherwise; no stdout prints).
  - `sim/racket-sc2-ladder-main.rkt` writes non-empty `[SCBOT_STATE]` lines to `current-error-port` with `step_ms` and records `'state_logs_emitted` and `'last_state_log` in the match summary telemetry.
