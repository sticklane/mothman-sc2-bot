# Mothman SC2 Bot & S2Protocol Sidecar (`#lang sc-bot`)

**Mothman SC2 Bot** (`sticklane/mothman-sc2-bot`) is a pure-Racket StarCraft II ladder bot suite built on `#lang sc-bot`, paired with a high-performance Rust **`s2protocol-sidecar`** (`crates/s2protocol-sidecar/`) for live `.SC2Replay` telemetry, minimap playback, and AI Arena diagnostics.

---

## Architecture Overview

### 1. `#lang sc-bot` Compiler & Race Bots
- **Language & Syntax (`info.rkt`, `main.rkt`, `compiler/syntax.rkt`)**: Coeffect/capability-graded DSL compiling bot definitions, build orders, and capability checks in pure Racket.
- **Ladder Entrypoints (`bots/`, `ladder/`)** (see [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full 5-layer DAG):
  - Active ladder variants built by [`ladder/build-aiarena-zip.rkt`](ladder/build-aiarena-zip.rkt): **`Mothman-X`** (Random, [`bots/Mothman-R.rkt`](bots/Mothman-R.rkt)), **`Mothman-Z`** (Zerg, [`bots/Mothman-Z.rkt`](bots/Mothman-Z.rkt)), **`Mothman-T`** (Terran, [`bots/Mothman-T.rkt`](bots/Mothman-T.rkt)), and **`Mothman-P`** (Protoss, [`bots/Mothman-P.rkt`](bots/Mothman-P.rkt)), plus [`bots/Mothman.rkt`](bots/Mothman.rkt) re-exporting `Mothman-R.rkt`.

### 2. Core Racket Engine (`lib/`)
- **Typed Domain Foundations, Bayesian Inference & Build Orders (Layers 0–1)**:
  - [`lib/sc2-types.rkt`](lib/sc2-types.rkt), [`lib/sc2-common.rkt`](lib/sc2-common.rkt), [`lib/sc2-game-constants.rkt`](lib/sc2-game-constants.rkt), [`lib/sc2-typed-commands.rkt`](lib/sc2-typed-commands.rkt) — `#lang typed/racket/base` canonical race/matchup/geometry structs, safe coercions, LotV constants, and typed wire witnesses.
  - [`lib/sc2-bayesian.rkt`](lib/sc2-bayesian.rkt) — Typed likelihood-ratio updating, categorical normalization, Hellinger divergence, and FoW diffusion.
  - [`lib/build-orders.rkt`](lib/build-orders.rkt) & `lib/build-orders/*.rkt` — Typed matchup build-order specs (`9` matchups) with replay-mined step `target-sec`, `pro-unit-timing`, and `pro-upgrade-timing` clock targets alongside supply curves and race tech-progression DAGs (`Zerg`, `Terran`, `Protoss`).
  - [`lib/sc2-logging.rkt`](lib/sc2-logging.rkt) — Typed structured `[SCBOT_STATE]` mind/goal/tactics step snapshots (`should-emit-step-log?`, `format-bot-step-log-line`).
- **Macro, Economy & Combat Evaluation**:
  - [`lib/priority-macro-brain.rkt`](lib/priority-macro-brain.rkt) — Priority/Braun-heap scheduler with facility-slot escrow, saving-for locks, and 8-stream resource bank allocation.
  - [`lib/econ-ledger.rkt`](lib/econ-ledger.rkt) — Symbiotic resource reservation, preemption ledger, worker saturation, and late-game supply management.
  - [`lib/sc2-combat-eval.rkt`](lib/sc2-combat-eval.rkt) & [`lib/mirror-mind-predictor.rkt`](lib/mirror-mind-predictor.rkt) — `#lang typed/racket/base` Lanchester snowball evaluation (`1.7` exponent), personality doctrines, counter trees, double-reaction mastermind loop, FAP combat simulation, and $k$-level opponent modeling.
- **Spatial Stack, Tactical Submodules & Door Management (Layers 1–4)**:
  - [`lib/sc2-geometry.rkt`](lib/sc2-geometry.rkt), [`lib/sc2-pathing.rkt`](lib/sc2-pathing.rkt), [`lib/sc2-placement.rkt`](lib/sc2-placement.rkt) — Typed 2D primitives & footprint overlaps, Huet choke zippers, BFS/flow fields & flanking arcs, plus Baba CSP/terrain-grid ramp wall solvers (`solve-terran-ramp-wall`, `solve-protoss-matchup-wall`) and uncamped expansion selection.
  - [`lib/perception-grid.rkt`](lib/perception-grid.rkt) — Pure `#lang typed/racket/base` spatial/temporal memory: Morton 2D crit-bit tries, Hinze-Paterson 2–3 combat finger trees (`split-by-dps`), choke zippers, threat Braun PQ, SBRL frame history, and FoW sector diffusion.
  - [`lib/tactics-sim.rkt`](lib/tactics-sim.rkt) & `lib/tactics/*.rkt` — Facade unifying geometry, pathing, placement, combat evaluation, and 5 tactical submodules: [`lib/tactics/order-ledger.rkt`](lib/tactics/order-ledger.rkt), [`lib/tactics/arena-minimax.rkt`](lib/tactics/arena-minimax.rkt), [`lib/tactics/zerg-burrow-micro.rkt`](lib/tactics/zerg-burrow-micro.rkt), [`lib/tactics/stealth-shimmer-response.rkt`](lib/tactics/stealth-shimmer-response.rkt), and [`lib/tactics/terran-addon-swap.rkt`](lib/tactics/terran-addon-swap.rkt).
  - [`lib/bot-runtime.rkt`](lib/bot-runtime.rkt) — 5-layer live step loop (`step-live-bot-runtime!`), `[SCBOT_STATE]` structured telemetry emission, Protoss `HoldPosition` wall door-guard state machine (`open`/`closed` transit & trapped-unit unstick), and Terran Supply Depot front-door state tracking & unstick pathing.
- **Human-Cortex Camera Framing & APM Discipline**:
  - [`lib/human-cortex.rkt`](lib/human-cortex.rkt) — Fitts' law saccades, viewport gating (`action-requires-camera-focus`), control-group recall safety, and selection compiler (`compile-optimal-unit-selection!`).
- **Pure-Racket SC2 Protobuf WebSocket Wire Layer**:
  - [`lib/sc2-protobuf-ws.rkt`](lib/sc2-protobuf-ws.rkt), [`lib/sc2-typed-commands.rkt`](lib/sc2-typed-commands.rkt), [`lib/sc2-proto-wire-verifier.rkt`](lib/sc2-proto-wire-verifier.rkt), [`lib/sc2-common.rkt`](lib/sc2-common.rkt), [`lib/sc2-game-constants.rkt`](lib/sc2-game-constants.rkt) — Direct s2clientprotocol Protobuf/RFC 6455 WebSocket actuator, Terran depot `556`/`558` P0 raise/lower hysteresis with footprint/transit guards, un-control-grouped camera framing (`Tier 1`, `6`-loop large-jump cooldown), and rolling-window APM wire governor (`govern-sc2-wire-actions!`).
- **Replay Forensics & Verification**:
  - [`lib/sc2-mpq-replay-parser.rkt`](lib/sc2-mpq-replay-parser.rkt), [`lib/state-machine-verifier.rkt`](lib/state-machine-verifier.rkt), [`lib/bot-crash-fuzzer.rkt`](lib/bot-crash-fuzzer.rkt), [`lib/pro-replay-starvation-audit.rkt`](lib/pro-replay-starvation-audit.rkt).

### 3. Rust `s2protocol-sidecar` (`crates/s2protocol-sidecar/`)
Live HTTP/SSE server (`http://127.0.0.1:4322/`) and CLI analyzer powered by `s2protocol = "5.1.0"`:
- **Interactive Telemetry UI ([`crates/s2protocol-sidecar/sidecar-ui.html`](crates/s2protocol-sidecar/sidecar-ui.html))**:
  - HiDPI canvas minimap with cached static terrain/heatmap layers, camera viewport overlays (`P1 CAM`/`P2 CAM`, `cameras: true` by default), raised vs. lowered `SupplyDepot` indicators, combat vectors, win-probability timeline, and filter/search catalog controls.
  - **Native SC2 Observer Leader Panel** synced frame-by-frame during playback with dropdown/pills & keyboard hotkeys:
    - **`D`** Production (constructing buildings, Warp Gate warp-ins, training/morphing units, research progress bars)
    - **`U`** Active Units (workers + combat supply grouped by unit type)
    - **`G`** Upgrades & Research (completed upgrades, `+1/+2/+3` levels, active research)
    - **`V`** APM / EPM (rolling 22s current APM, average APM, average EPM)
    - **`L`** Units Lost (cumulative losses by type and mineral/vespene cost)
    - **`N`** Collapse Leader Panel
- **Server & CLI Modes ([`crates/s2protocol-sidecar/src/main.rs`](crates/s2protocol-sidecar/src/main.rs))**:
  - Endpoints: `GET /`, `GET /api/status`, `GET /api/catalog`, `GET /api/replay/<id>`, `POST /api/analyze-bytes`, `GET /api/events` (SSE).
  - CLI modes: `--serve --port 4322`, `--analyze <file.SC2Replay>`, `--batch-dir <dir>`, `--export-ui-bundle <out.json>`.

---

## How the Bot Works: 5-Layer Per-Step Runtime Pipeline

On every StarCraft II game step (driven natively by [`sim/racket-sc2-ladder-main.rkt`](sim/racket-sc2-ladder-main.rkt)), observations flow from Blizzard's Protobuf WebSocket API through the 5-layer Racket cognitive pipeline (`step-live-bot-runtime!`) and back out through the priority-tiered wire governor:

```mermaid
flowchart LR
    WS_IN["1. SC2 WebSocket Ingress (sc2-protobuf-ws.rkt: decode-sc2-response, unit tag index)"] --> L1["2. Spatial Perception (perception-grid.rkt, sc2-geometry/pathing/bayesian.rkt: crit-bit tries, zippers, FoW)"]
    L1 --> L2["3. Macro, Build Orders & Combat Eval (priority-macro-brain.rkt, econ-ledger.rkt, build-orders.rkt, sc2-combat-eval.rkt)"]
    L2 --> L34["4. Tactics, Walls & Doors (tactics-sim.rkt, lib/tactics/*.rkt, sc2-placement.rkt, bot-runtime.rkt)"]
    L34 --> L5["5. Human Cortex, Logging & Wire Governor (human-cortex.rkt, sc2-logging.rkt, govern-sc2-wire-actions!)"]
    L5 --> WS_OUT["6. SC2 Wire Egress (sc2-protobuf-ws.rkt: 556/558 P0 doors, P1 framing cams, encode-sc2-action)"]
```

1. **Wire Ingress & Tactical Translation (`lib/sc2-protobuf-ws.rkt`)**:
   - `decode-sc2-response` unpacks raw protobuf `ResponseObservation` frames (game loop, units, orders, upgrades, power sources, active camera position, dead tags) into `sc2-observation`, while `sc2-observation->runtime-obs-hash` normalizes worker/facility counts, live unit-tag lookups, and base anchors for the runtime layers.
   - On egress, `translate-bot-actions->sc2-raw-commands` validates typed actions against live unit tags, evaluates Terran Supply Depot auto-raise (`558`) and auto-lower (`556`) hysteresis (`<= 10.0` raise vs. `> 14.5` or transit lower) guarded by `friendly-unit-on-depot-footprint?` and `friendly-unit-requesting-depot-transit?` with both promoted to `P0` in `wire-cmd-priority-tier`, and tracks `SC2-CONTROL-GROUPED-TAGS` (`0–7`) so commands targeting un-control-grouped units outside the viewport prepend a `Tier 1` framing `sc2-raw-camera-move`.
2. **Spatial Perception, Pathing & Bayesian FoW (`lib/perception-grid.rkt`, `lib/sc2-geometry.rkt`, `lib/sc2-pathing.rkt`, `lib/sc2-bayesian.rkt`)**:
   - `step-layer1-perception!` ingests allied and enemy unit snapshots via `perception-grid-ingest-frame!` into Morton 2D Z-order crit-bit spatial tries (`perception-grid-query-box`), 2–3 monoidal combat finger trees (`split-by-dps`), and persistent skew-binary frame histories.
   - `lakefill-choke-decomposition` and `huet-zipper` (`lib/sc2-pathing.rkt`) model base/natural/third ramp chokes with $O(1)$ rollback, while `fow-ghost-step-diffusion!` (`lib/sc2-bayesian.rkt`) and `best-retreat-sector` track sector threat weights and FoW persistence.
3. **Priority Macro, Build Orders, Combat Eval & Escrow Economy (`lib/priority-macro-brain.rkt`, `lib/econ-ledger.rkt`, `lib/build-orders.rkt`, `lib/sc2-combat-eval.rkt`)**:
   - `step-layer1b-mastermind!`, `step-layer1c-mirror-mind!`, and `step-layer2-economy!` evaluate double-reaction counter trees (`step-double-reaction!` in `sc2-combat-eval.rkt`), mirror predictions (`mirror-mind-predictor.rkt`), and typed matchup specs (`lib/build-orders/*.rkt`, combining supply gating with replay-mined `pro-unit-timing`, `pro-upgrade-timing`, and step `target-sec` clock schedules), then build a decoupled `macro-world-state` via `obs-hash->macro-world-state` and run `step-priority-macro-brain` over `SC2-TECH-GRAPH` (checking prerequisites via `resolve-missing-prereq-chain`).
   - Pointerless Braun priority queues (`braun-insert`) rank competing spending goals alongside symbiotic escrow reservations (`make-symbiotic-ledger`, `ledger-reserve!`, `ledger-preempt-for-crisis!`) and `macro-brain-can-spend?` locks, while `evaluate-coupled-macro-governor` balances expansion timing, worker saturation (`22`/base), and multi-stream mineral/gas/supply budgets.
4. **Tactics, Ramp Walling & Front-Door Guards (`lib/tactics-sim.rkt`, `lib/tactics/*.rkt`, `lib/sc2-placement.rkt`, `lib/bot-runtime.rkt`)**:
   - `step-layer3-and-4-tactics!` runs Baba CSP and terrain-grid wall solvers (`solve-terran-ramp-wall`, `solve-protoss-matchup-wall` in `lib/sc2-placement.rkt`) verified against ramp pathing/placement/height grids, `fap-posture-with-hysteresis` & `purplewave-traffic-retreat` (`lib/sc2-combat-eval.rkt`), and modular micro engines under `lib/tactics/` (`order-ledger.rkt`, `arena-minimax.rkt`, `zerg-burrow-micro.rkt`, `stealth-shimmer-response.rkt`, `terran-addon-swap.rkt`).
   - Protoss `HoldPosition` doorway micro (`rt-door-state`: `'open`/`'closed`) parts its Zealot/Stalker wall guard for transiting workers or `>= 1` trapped combat unit when enemies are `> 6.5` tiles away, nudges idle trapped units across the opening, and re-seals immediately; Terran doorway tracking (`rt-door-state`) monitors `supply-depot`/`supply-depot-lowered` transitions and emits unstick `move` pathing after `>= 2` trapped frames.
5. **Human-Cortex Framing, Structured Telemetry & Wire APM Governor (`lib/human-cortex.rkt`, `lib/sc2-logging.rkt`, `govern-sc2-wire-actions!`)**:
   - `step-layer5-human-cortex!` models human attention with `fitts-saccade-ms` camera fixations and `in-camera-viewport?` gating: `action-requires-camera-focus` emits `(move-camera fx fy)` immediately before spatial builds or un-control-grouped unit commands outside the current viewport, while `compile-optimal-unit-selection!` only recalls a control group when all desired unit IDs belong to it.
   - `step-live-bot-runtime!` attaches structured `'state-log` snapshots (`lib/sc2-logging.rkt`) on every step and emits `[SCBOT_STATE]` telemetry lines via `should-emit-step-log?` (`sim/racket-sc2-ladder-main.rkt`), while `govern-sc2-wire-actions!` enforces the rolling 60-second replay APM/token cap (`target-apm`/`hard-cap-apm`), preserves `P0` depot/survival actions and `Tier 1` camera-before-command ordering, and transmits wire bytes via `encode-sc2-action`.

---

## Pure-Racket Tooling Policy (`AGENTS.md`)

All bot logic, MPQ/`.SC2Replay` analysis, AI Arena API tools, and test scripts in this repository follow a **strict 100% Pure-Racket policy** (no `python3` or new `*.py` scripts for analysis or tooling). Canonical CLI tools live in [`tools/`](tools/):
- [`tools/aiarena-api-client.rkt`](tools/aiarena-api-client.rkt) — AI Arena BotZip sync, match requests, and status polling
- [`tools/analyze-aiarena-replays.rkt`](tools/analyze-aiarena-replays.rkt) — AI Arena replay & match telemetry forensics
- [`tools/run-real-sc2-bot-match.rkt`](tools/run-real-sc2-bot-match.rkt) — Headless `SC2_x64` match harness
- [`tools/audit-pro-replay-starvation.rkt`](tools/audit-pro-replay-starvation.rkt) & [`tools/racket-multi-match-validator.rkt`](tools/racket-multi-match-validator.rkt) — Starvation & multi-match validation
- [`tools/fuzz-sc2-protobuf-output.rkt`](tools/fuzz-sc2-protobuf-output.rkt) — Protobuf differential schema fuzzer

Default test execution in [`tests/run-all-tests.rkt`](tests/run-all-tests.rkt) is kept strictly under `< 5,000 ms` (`FAST-<5s` mode; compile first with `raco make -j 4`).

---

## Build & Test Commands

```bash
# 1. Compile and run the full #lang sc-bot verification suite (< 5s fast mode)
raco make -j 4 tests/run-all-tests.rkt && racket tests/run-all-tests.rkt

# 2. Run the pure-Racket Protobuf + RFC 6455 WebSocket suite
raco make -j 4 tests/sc2-protobuf-ws-test.rkt && racket tests/sc2-protobuf-ws-test.rkt

# 3. Run the Rust s2protocol-sidecar test suite
cargo test --manifest-path crates/s2protocol-sidecar/Cargo.toml

# 4. Run the live sidecar daemon at http://127.0.0.1:4322/
cargo run --release --manifest-path crates/s2protocol-sidecar/Cargo.toml -- --serve --port 4322
```
