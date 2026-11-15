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
  lib/tactics/disruptor-micro.rkt [TR] -> sc2-types, sc2-geometry, sc2-game-constants
  lib/tactics/pro-spellcaster-micro.rkt [TR] -> sc2-game-constants
  lib/tactics/unit-mode-micro.rkt [TR] -> sc2-types, sc2-geometry, sc2-game-constants
  lib/tactics/transport-drop-micro.rkt [TR] -> sc2-types, sc2-geometry, sc2-game-constants
  lib/tactics/multitask-harass-and-proxy.rkt [TR] -> sc2-types, sc2-geometry, sc2-game-constants
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
- Verification & audits: `lib/state-machine-verifier.rkt`, `lib/bot-crash-fuzzer.rkt` (including `step-sc2-mastermind!` and `fuzz-sc2-mastermind-suite!`), `lib/pro-replay-starvation-audit.rkt`, `lib/sc2-proto-wire-verifier.rkt`, `lib/sc2-mpq-replay-parser.rkt`, `lib/sc2-unit-tester-lotv.rkt` (deterministic `22.4` Hz `8`-scenario asymmetric micro/tactical unit tester).
- DSL compiler, tooling & ladder packaging: `compiler/syntax.rkt` (`#lang sc-bot` posture/state-machine/coeffect-grade syntax), `tools/*.rkt` (including `tools/analyze-aiarena-replays.rkt` with canonical 9-matchup `ZvZ`–`PvP` telemetry, `--matchup`, `--by-build-order`, & `--by-opponent-strategy`, and `tools/run-lotv-unit-tester.rkt` `--all`/`--scenario`/`--json`/`--verify`), `ladder/build-aiarena-zip.rkt` (builds only the 4 active ladder archives `ladder/Mothman-{X,Z,T,P}.zip` plus `ladder/.cache/mothman_standalone_elf`; legacy `Mothman.zip` and `Mothman-R.zip` are retired).

---

## 2. Typed Racket Boundaries & Interop Conventions

Mixing `#lang typed/racket/base` libraries with untyped `#lang racket/base` callers introduces specific contract boundary rules that the codebase handles uniformly:

1. **Untyped Observation/Unit Hash Access (`typed/racket/unsafe` + `dyn-hash-ops`)**:
   Typed Racket's `hash/c` contract cannot cleanly wrap arbitrary untyped mutable/immutable hashes when passing heterogeneous observation payloads across module boundaries. Typed modules (`lib/sc2-combat-eval.rkt`, `lib/tactics/zerg-burrow-micro.rkt`, `lib/tactics/stealth-shimmer-response.rkt`, `lib/tactics/disruptor-micro.rkt`, `lib/tactics/pro-spellcaster-micro.rkt`, `lib/tactics/unit-mode-micro.rkt`, `lib/tactics/transport-drop-micro.rkt`, and `lib/sc2-game-constants.rkt`) therefore isolate dynamic hash operations inside a local `(module dyn-hash-ops racket/base ...)` submodule (`dyn-hash-ref`, `dyn-hash-has-key?`, `dyn-hash-set!`) imported through `unsafe-require/typed` with total `Any` signatures. Callers still receive deterministic fallback coercion through `lib/sc2-types.rkt` helpers (`safe-real`, `safe-exact-int`, `safe-nonneg-int`).

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
   - **`lib/econ-ledger.rkt` (`evaluate-build-order-next-step`, `desired-zerg-queen-count`, `evaluate-build-order-tactical-plan`)**: activates canonical steps when `supply-used >= min-supply` OR (at `frame > 0` with `target-sec > 0.0`) `elapsed-sec >= target-sec`, appending `due-pro-upgrade-timings` and `due-pro-unit-timings` at `frame > 0`, injecting Zerg `'creeping-queen` / `'creep-tumor` goals until `(min 6 (* 2 hatch-count))`, and evaluating timing-attack disposition phases from `PRO-BO-TACTICAL-PHASE-PLANS`.
   - **`lib/priority-macro-brain.rkt` (`collect-due-bo-context`, `step-priority-macro-brain`, `creep-self-sustaining?`)**: combines supply-due and clock-due (`frame / 22.4`) steps with Track 2c timing urgency plans (`'timing-upgrade-plan` at utility `460.0` once `elapsed-sec >= start-sec` or `438.0` in 15s lookahead, damped by `under-sat-econ?` to `428.0`/`422.0` and `140.0` under non-defensive attack; `'timing-unit-plan` at `436.0` once `elapsed-sec >= target-sec` when saturated or `424.0` in lookahead / `under-sat-econ?`, `420.0` when non-peaceful, with `queen-sat-defer?` clamping excess Queens to `120.0` and `queen-defer?` to `80.0` across Track 2/2c), schedules `(list 'spawn-creep-tumor nat-x nat-y)` at utility `540.0` whenever `(not (creep-self-sustaining? active-creep-tumors active-bases))` and `cur-queen-total >= 1`, feeds all clock-due goals into `find-all-broken-tech-dependencies`, and preserves `pro-bo-goal-target-sec` via `lookup-timing-sec-for-sym`.

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
- **Ramp & Choke Wall Solvers**: `solve-terran-ramp-wall` / `solve-terran-ramp-wall-analytical`, `solve-protoss-matchup-wall` / `solve-protoss-matchup-wall-analytical` / `solve-protoss-wall-candidate-on-grids` / `solve-protoss-main-ramp-on-grids`, and Baba CSP `solve-choke-wall-in` with `wall-solution` gap/tightness validation. For natural chokes (`PvZ` or `#:force-natural-choke? #t`), solves a `2x 3x3` + `1x1` doorway wall (`'locus 'natural-choke`, `'slot-1`, `'slot-2`, rear `2x2` `'pylon`, `'door`, and `'slot-3 #f`) across `6..10`-tile chokes (Sub-passes 1a/1b/1c) and open-map synthetic fallbacks while preserving `'main-ramp` for `PvT`/`PvP`.
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
- `lib/tactics/arena-minimax.rkt`: single-linkage arena clustering (`cluster-tactical-arenas`), multi-depth mirrored kinematic rollout (`simulate-mirrored-arena-pair`), regret-hedged minimax & commitment lock hysteresis (`evaluate-arena-minimax-and-regret!`, `resolve-committed-micro-action!`, `step-tactical-mirror-brain!` forwarding `#:tactical-disposition`, `#:lanchester-ratio`, and `#:enemy-upgrades` into splash planning).
- `lib/tactics/zerg-burrow-micro.rkt`: Tunneling Claws Roach regen & escape (`execute-roach-tunneling-burrow-micro`), Infestor burrow-cast micro (`execute-infestor-burrow-cast-micro`), `lurker-burrow-action`, `drone-evade-burrow-action`, plus pro-corpus splash standoff/commit decision primitives: `disruptor-nova-catchable-range`, `should-commit-through-splash?`, and `plan-avoid-siege-tank-and-lurker-splash-zones` (`#:commit-through-splash?`, `#:enemy-upgrades`, `#:tactical-disposition`, `#:lanchester-ratio`).
- `lib/tactics/stealth-shimmer-response.rkt`: hidden/cloaked shimmer and burrow-ripple detection (`shimmer-target-unit?`, `mobile-or-static-detector-nearby?`, `execute-shimmer-and-burrow-ripple-response` emitting AoE skillshots or a single highest-energy Orbital Command `scanner-sweep`).
- `lib/tactics/terran-addon-swap.rkt`: lift-off & add-on swap planner (`plan-terran-addon-swap`) enforcing a `448`-frame relift cooldown, 1-to-1 claim lock, donor landing offset `(donor-x, donor-y + 4.0)`, and an `18.0`-tile enemy threat abort guard.
- `lib/tactics/disruptor-micro.rkt`: pure `#lang typed/racket/base` Protoss Disruptor (`694`) & Purification Nova (`733` / Ability `2346`) micro engine (`plan-disruptor-nova-casts` with `145 (+55 shield)` scoring, `2.0x` friendly-fire avoidance, `>= 4.0`-tile volley de-confliction; `steer-purification-novas` homing; weaponless `kite-disruptor-casters` standoff/retreat; re-exported `disruptor-nova-catchable-range` speed-aware `plan-anti-nova-scatter` pre-split & emergency Blink `< 2.75`; `evaluate-disruptor-snipe-and-cooldowns` `480`-frame tracker with `cooldown-dive-ok?` (`DISRUPTOR-COOLDOWN-DIVE-MIN-FRAMES` = `112`); unified `step-disruptor-tactical-micro!`).
- `lib/tactics/pro-spellcaster-micro.rkt`: pure `#lang typed/racket/base` all-race pro-calibrated (`#115` corpus) spellcaster planner (`plan-zerg-spellcaster-micro`, `plan-terran-spellcaster-micro`, `plan-protoss-spellcaster-micro`, `step-pro-spellcaster-micro!`) with `Δf = 0` spatial AoE and single-target reservations (`make-spell-claims`, `spell-claim-point?!`, `spell-claim-unit?!`), Disruptor volley stagger (`disruptor-nova-stagger-ready?` defaulting to `DISRUPTOR-NOVA-STAGGER-DEFAULT-FRAMES` = `31` within `28–32` frames), Ghost `34`-frame Snipe channel lockout (`snipe-channel-locked?`, `spellcaster-channel-protected?`, `SNIPE-DAMAGE` = `170.0`), Battlecruiser `ceil(hp / 240.0)` Yamato deduplication + low-HP Tactical Jump, Oracle `60`-frame (`111`-frame zero-target) Pulsar Beam dwell + Revelation/Stasis Ward, Sentry Guardian Shield + `27`-frame post-GS Force Field delay, High Templar Psi Storm + dry-HT Archon merge (`HT-POST-STORM-ARCHON-MERGE-WINDOW-FRAMES` = `33`), Queen Transfuse/Creep, Ravager Corrosive Bile (`0.75`-tile stagger, `157`-frame CD, Fungal->Bile combo & Force Field shatter), Infestor Fungal/Shroud, Viper Blinding Cloud/Abduct/Parasitic Bomb/Consume, and Corruptor Caustic Spray.
- `lib/tactics/unit-mode-micro.rkt`: pure `#lang typed/racket/base` Terran mode-switching & kiting engine (`plan-thor-modes`, `plan-hellion-modes`, `plan-viking-modes`, `plan-cyclone-micro`, `plan-marauder-concussive-targets`, `step-unit-mode-micro!`): Thor High-Impact <-> Explosive (`2362`/`2364`, `224`-frame dwell, `>= 3` Mutalisk threshold, `thor-morph-safe?` `0.35` HP & melee-swarm guards), Hellion <-> Hellbat (`1998`/`1978`, Armory pre-engagement `<= 18.0`, `96`-frame hysteresis, `176`-frame commit dwell, `22.0` unmorph clear radius), Viking Assault <-> Fighter (`403`/`405`, `135`-frame dwell, `64`-frame capital-air emergency liftoff within `15.0` tiles, `0.55` HP splash liftoff), Cyclone Lock On (`2350`, `6.5` cast range, `9.0–12.8` orbit tether kiting, `135`f CD / `315`f channel), and Marauder `32`-frame Concussive Shells target spreading with low-EHP lethal finish exception.
- `lib/tactics/transport-drop-micro.rkt`: pure `#lang typed/racket/base` cross-race transport micro planner (`evaluate-save-pickup`, `evaluate-transport-drop`, `evaluate-warp-prism-phasing`, `plan-overlord-transport-morphs`, `plan-transport-fleet-micro`, `step-transport-drop-micro!`) covering Medivac (`54`, `396` moving unload, Boost `2116` `16–36`f drop window), Warp Prism (`81`, `5.0` pickup range, `913` moving unload, `1528`/`1530` Phasing with `140`/`208`-frame dwells & `10.0`-tile threat unphase guard), and OverlordTransport (`2708` morph gated on Lair + `>= 16` combat supply, `1408` moving unload), enforcing `0.42`/`0.55` bruised/under-fire pickup HP ratios, `672`-frame stuck-cargo ceiling, and `0.25` emergency dump.
- `lib/tactics/multitask-harass-and-proxy.rkt`: pure `#lang typed/racket/base` multi-tasking harass, proxy all-in, air worker harass, anti-Baneling fan splits, and smart Baneling control (`plan-baneling-move-past-and-light-clump-detonate` — holds off Armored/Massive screens via `'baneling-hold-off-inefficient-armored`, rolls past front screens to rear Light clumps, caps detonations at exact-lethal `needed-banes` with surplus pullback `'baneling-reserve-no-overcommit`, and detonates `baneling-burrowed` `115` landmines only on clustered light/worker targets within `BANELING-LANDMINE-DETONATE-RADIUS` = `2.1`).
- `lib/tactics-sim.rkt`: unified `#lang racket/base` facade re-exporting `(except-in "sc2-geometry.rkt" aabb-overlaps?)`, `sc2-pathing.rkt`, `sc2-placement.rkt`, `sc2-combat-eval.rkt`, `situational-counter-planner.rkt`, and all `lib/tactics/*.rkt` submodules (`14` tactical submodules total, including `creep-and-changeling-tactics.rkt`, `wall-and-block-tactics.rkt`, `multitask-harass-and-proxy.rkt`, `map-elements-and-experiments.rkt`, and `static-defense-and-nydus-tactics.rkt`).
- **Live Runtime & Wire Integration (`lib/bot-runtime.rkt`, `lib/sc2-protobuf-ws.rkt`)**: `live-bot-runtime` tracks `rt-disruptor-tracker`, `rt-spell-claims`, `rt-unit-mode-tracker`, `rt-transport-tracker`, and `rt-splash-state`, resets Wave 3 trackers on frame rewinds via `reset-wave3-tactical-state!`, preserves tactical/spellcaster/mode/transport commands across `step-live-bot-runtime!` Step 5 filtering, and encodes moving self-drop unloads (`396`/`913`/`1408` on own `UnitTag` with `#f` target position), `archon` merges (`1766`), and `overlord-transport` morphs (`2708`) in `sc2-protobuf-ws.rkt`.

### Round 4 Macro & Combat Safeguards (`econ-ledger`, `priority-macro-brain`, `bot-runtime`, `sc2-protobuf-ws`)
- **Crisis Upgrade & Tech Deferral (`crisis-defense-tech-defer-active?`, `crisis-tech-upgrade-deferral?`)**: When `under-attack?` / `under-base-attack?` coincides with an army deficit or `< 30–32` workers, defers non-essential gas upgrades (`glial-reconstitution`, `centrifical-hooks`/`centrifugal-hooks`, `grooved-spines`, `muscular-augments`, `burrow`, `tunneling-claws`, `+1/+2/+3`, `psi-storm`, `extended-thermal-lance`, `banshee-cloak`, `personal-cloaking`) and higher tech (`lair`, `hive`, `infestation-pit`, `spire`, `templar-archive`, `fleet-beacon`, `fusion-core`, and `stargate` during Robo/ground defense) to prioritize immediate defenders (`roach`/`ravager`/`spine-crawler`, `immortal`/`stalker`/`zealot`/`shield-battery`, `siege-tank`/`marauder`/`bunker`).
- **Anti-Capital-Air Viking Tether & High-Impact `Thor`**: In `lib/bot-runtime.rkt`, `viking-fighter` tethers (`(kite ...)` back toward ground army centroid `(ground-army-cx, ground-army-cy)`) when pursuing `VIKING-TETHER-TARGET-SYMS` (`tempest`/`carrier`/`colossus`/`void-ray`/`brood-lord`) screened by `>= 3` `VIKING-SCREEN-AA-SYMS` ground anti-air units within `7.5` tiles while `> 4.5` tiles ahead of ground support; `terran-desired-thor-cap` / `bot-runtime.rkt` train `Thor` (`< 5` or `< 6` vs `>= 6` Stalkers/Hydralisks), switch idle Thors to High-Impact Payload (`morph-thor-high-impact`, Ability `2362` with wire alias `morph-thor-high-impact-mode`), and trigger `'terran-ship-weapons-1` once `terran-air-fleet-count >= 4`.

### Wave 2A Creep Macro, Far-Patch Worker Scouts & Timing-Attack Dispositions
- **Zerg Build-Order Creep Tumors & Dedicated Creeping Queens (`econ-ledger`, `priority-macro-brain`, `bot-runtime`)**: `desired-zerg-queen-count` / `zerg-queen-target` budget both Hatchery inject Queens and dedicated creep Queens (`2` on 1 base, `4` on 2 bases, `bases + 3` on `>= 3` bases, `+1` vs threat), `creep-self-sustaining?` evaluates `(>= tumors (min 6 (* 2 bases)))`, `evaluate-build-order-next-step` / `step-priority-macro-brain` emit `'creeping-queen` / `'spawn-creep-tumor` (`540.0` utility) until creep is self-sustaining, and `bot-runtime.rkt` (`dedicated-creeping-queen-ids`, `queen-dispatch-creep-tumor!`, `used-creep-tumors`) separates dedicated creeping Queens from Hatchery injectors while chaining mature `creep-tumor-burrowed` (`137`) spreads.
- **Far-Mineral-Patch Non-Carrying Scout Worker Selection (`bot-runtime`, `sc2-protobuf-ws`)**: `worker-carrying-minerals-or-gas?` / `select-far-mineral-patch-non-carrying-worker` (runtime worker hashes) and `worker-carrying-cargo?` / `pick-far-patch-scout-worker` (wire `sc2-unit` structs and hashes) reject workers carrying minerals/gas (`carrying-*` flags, carry buff IDs `271–276`, or `harvest-return` orders `3667`/`296`/`299`/`1184`) and score unburdened workers on outer mineral patches farthest from the base/nexus anchor.
- **Build-Order Tactical Execution & Timing-Attack Plans (`econ-ledger`, `priority-macro-brain`)**: `PRO-BO-TACTICAL-PHASE-PLANS`, `pro-tactical-phases-for-matchup` (all 9 canonical matchups `PvZ`–`ZvP`), and `evaluate-build-order-tactical-plan` (`bo-tactical-phase-plan` -> `bo-active-tactical-plan`) translate matchup timing windows (`window-start-sec`, `window-hit-sec`, `window-expire-sec`, `pre-position-lead-sec`), trigger units/upgrades, fortified-choke counts, and Lanchester ratios into concrete battlefield dispositions: `'accumulate-for-timing`, `'pre-position-march-out` (`in-progress-upgrade-progress >= 0.80` or within `pre-position-lead-sec` before `window-hit-sec`), `'execute-timing-attack-commit`, `'execute-timing-bypass-harass-fork` (fortified choke with vulnerable mineral lines), `'contain-and-deny-third`, and `'abort-timing-and-pivot-macro` (severe home attack `< 0.80`, expired window, or depleted army -> `post-window-transition`).

### Pro-Replay (`1,798` Replays) Splash Standoff vs Run-Through-Splash Commit (`zerg-burrow-micro`, `disruptor-micro`, `arena-minimax`, `bot-runtime`)
- **Commit Gating (`should-commit-through-splash?`)**: Mined from `1,798` pro replays to separate standoff attrition from decisive dives across all major splash sources using tactical disposition (`'commit` / `'execute-timing-attack-commit`), Lanchester/supply ratios, concave arc degree, and `#:has-detector?` vs burrowed Lurkers.
- **Per-Hazard Standoff & Run-Through Mechanics (`plan-avoid-siege-tank-and-lurker-splash-zones`, `disruptor-micro`, `arena-minimax`, `bot-runtime`)**:
  - **Disruptor & Nova**: `disruptor-nova-catchable-range` scales ready pre-split standoff dynamically by unit movement speed (`max(6.5, 14.25 - 1.85*v)` + `1.0`t clumped margin; `0.0` when `#:disruptor-ready? #f`); active Novas trigger `'dodge-active-disruptor-nova` with `>= 3.0`t flare spacing; committing emits `'commit-run-through-disruptor-split`; `evaluate-disruptor-snipe-and-cooldowns` sets 11th field `cooldown-dive-ok?` when `cd-rem >= DISRUPTOR-COOLDOWN-DIVE-MIN-FRAMES` (`112`) with `enemy-cd-frac >= 0.50` (or front `<= 7.5`t) and `supply-ratio >= 0.90`, driving `'attack-unit` dives in `step-disruptor-tactical-micro!`.
  - **Colossus**: Respects observed `'extended-thermal-lance` (`9.0`t -> `10.2`t `'avoid-colossus-sweep-standoff`) vs base (`7.0`t -> `8.5`t) standoff, switching to `'colossus-radial-split-dive` (`<= 3.5–5.0`t sweep-perpendicular arc) when committing.
  - **Siege Tank, Burrowed Lurker & Psi Storm**: Non-commit holds clean outer standoff (`13.8`t Tank, `9.5`t/`11.5`t Seismic Lurker); committing suppresses sideways-only Tank splits (`'commit-run-through-splash-concave` into `< 3.5`t deadzone), flips Lurker spine step scoring (`+20.0 * d_lurker` -> `-14.0 * d_lurker`) into diagonal-forward approach, steps `2.2`t forward-perpendicular through `1.5r` Psi Storm onto HTs/backline, and in `bot-runtime.rkt` (`l34-phase4a-hazards-wm!`) lets ready attackers shoot `'attack-unit` instead of fleeing when non-active hazards allow firing in range.

### SC2 LotV Unit Tester, `RequestDebug` Wire Bridge & Live AI Arena Fixes (`[REG-1]`, `[BUG-2]`–`[BUG-5]`)
- **Asymmetric LotV Unit Tester (`lib/sc2-unit-tester-lotv.rkt`, `tools/run-lotv-unit-tester.rkt`)**: Offline `22.4` Hz simulator pitting `'default-ai` (naive A-move, losing `8/8`) against real `'mothman-tactics` planners (winning `8/8` with strictly higher surviving value) across 8 canonical asymmetric micro scenarios (`baneling-move-past-marauder-screen`, `disruptor-nova-catchable-range-and-cooldown-dive`, `lurker-linear-spine-step-out-and-bile-concave`, `siege-tank-run-through-splash-and-deadzone-dive`, `colossus-thermal-lance-radial-split-dive`, `worker-rush-townhall-stack-mineral-drill`, `protoss-natural-wall-doorway-hold-vs-ling-flood`, `glaive-adept-shade-bypass-fortified-choke`), exposed via `run-lotv-unit-tester-scenario`, `run-all-lotv-unit-tester-scenarios`, and `--all`/`--scenario`/`--json`/`--verify`/`--list`.
- **Protobuf `RequestDebug` (`lib/sc2-protobuf-ws.rkt`)**: Pure-Racket encoders for `RequestDebug` (`field 20`: `encode-request-debug` / `make-request-debug`, `encode-debug-create-unit`, `encode-debug-kill-unit`, `encode-debug-test-process`) plus `[NOTE-R4-C]` / `[BUG-2]` wire guards.
- **Live AI Arena Safeguards (`[REG-1]`, `[BUG-2]`–`[BUG-5]`) & Strategy Forensics (`analyze-aiarena-replays.rkt`)**:
  - `[REG-1]` (`priority-macro-brain`, `bot-runtime`): Protects Zerg `16-Hatch` openings (`zerg-hatch-first-opening?`, `zerg-16-hatch-pending?`) from premature `SpawningPool`/`Extractor` mineral theft while aborting blind natural expansion on `forward-proxy-detected?` / `zerg-early-pool-rush?`.
  - `[BUG-2]` (`sc2-protobuf-ws`, `bot-runtime`): Preserves `(morph baneling)` (`80`) and active `'morph`/`'channel` units against Phase 6 `attack-pos` (`23`) overwrite via `used-producer-tags` / `commanded-combat-tags` exclusion and `fast-order-protection-class`, and orders `zergling-heavy-counter?` cap before mineral-overflow Zergling flood.
  - `[BUG-3 / NOTE-R4-C]` (`bot-runtime`, `sc2-protobuf-ws`): Enforces TownHall-breach / mineral-line stacked worker-rush guards (`<= 6.0`t breach) and converts `worker-drill-stack-attack` into `ATTACK` (`23`) instead of mineral-walk `3666`.
  - `[BUG-4]` (`econ-ledger`, `priority-macro-brain`, `bot-runtime`): Shifts Protoss vs Capital Air (`Battlecruiser`/`Tempest`/`Carrier`/`Mothership`) from `Phoenix` spam to multi-`Stargate`, `FleetBeacon`, `Tempest`, and `VoidRay`, and scales Terran multi-`Starport`, `StarportReactor`, `Thor`, `terran-ship-weapons-1`, and `VikingFighter`.
  - `[BUG-5]` (`econ-ledger`, `priority-macro-brain`, `bot-runtime`): Triggers Terran breakout Command Centers when contained on `<= 3` CCs with `>= 1500`M bank + `GhostAcademy` (`t3-ghost-counter`) vs Queen/Infestor/HT swarms at `>= 2` bases, throttles unfinished Protoss wire Pylons (`< 2`), and routes post-wall Protoss Pylons into safe interior main/natural anchors.
  - **Forensic Grouping (`tools/analyze-aiarena-replays.rkt`)**: `summarize-reports-by-build-order`, `summarize-reports-by-opponent-strategy`, and CLI `--by-build-order` / `--by-opponent-strategy` group live match win-rate and economy metrics by inferred build order and opponent strategy.

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
