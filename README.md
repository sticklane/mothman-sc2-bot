# Mothman SC2 Bot & S2Protocol Sidecar (`#lang sc-bot`)

**Mothman SC2 Bot** (`sticklane/mothman-sc2-bot`) is a pure-Racket StarCraft II ladder bot suite built on `#lang sc-bot`, paired with a high-performance Rust **`s2protocol-sidecar`** (`crates/s2protocol-sidecar/`) for live `.SC2Replay` telemetry, minimap playback, and AI Arena diagnostics.

---

## Architecture Overview

### 1. `#lang sc-bot` Compiler & Race Bots
- **Language & Syntax (`info.rkt`, `main.rkt`, `compiler/syntax.rkt`)**: Coeffect/capability-graded DSL compiling bot definitions, build orders, and capability checks in pure Racket.
- **Ladder Entrypoints (`bots/`, `examples/`, `ladder/`)**:
  - Active ladder variants built by [`ladder/build-aiarena-zip.rkt`](ladder/build-aiarena-zip.rkt): **`Mothman-X`** (Random), **`Mothman-Z`** (Zerg), **`Mothman-T`** (Terran), and **`Mothman-P`** (Protoss).
  - Archetype definitions live in [`examples/`](examples/) (`zerg-overmind-12hatch.rkt`, `terran-pluto-siege-ghost.rkt`, `protoss-stardust-ffe.rkt`, `random-chameleon-allrace.rkt`) with entry stubs in [`bots/`](bots/) and [`config.json`](config.json).

### 2. Core Racket Engine (`lib/`)
- **Macro, Economy & Priority Scheduling**:
  - [`lib/priority-macro-brain.rkt`](lib/priority-macro-brain.rkt) — Priority/Braun-heap scheduler with facility-slot escrow, saving-for locks, and 8-stream resource bank allocation.
  - [`lib/econ-ledger.rkt`](lib/econ-ledger.rkt) — Symbiotic resource reservation, preemption ledger, worker saturation, and late-game supply management.
  - [`lib/zerospace-mastermind.rkt`](lib/zerospace-mastermind.rkt) & [`lib/mirror-mind-predictor.rkt`](lib/mirror-mind-predictor.rkt) — Counter-tree planning, hidden-tech FoW inference, and $k$-level opponent modeling.
- **Tactical Simulation, Walling & Door Management**:
  - [`lib/tactics-sim.rkt`](lib/tactics-sim.rkt) — Baba CSP & terrain-grid ramp/choke wall solvers (`solve-terran-ramp-wall`, `solve-protoss-matchup-wall`), FAP combat evaluation + hysteresis, traffic-aware retreat, and in-progress order ledger.
  - [`lib/bot-runtime.rkt`](lib/bot-runtime.rkt) — 5-layer live step loop (`step-live-bot-runtime!`), Protoss `HoldPosition` wall door-guard state machine (`open`/`closed` transit & trapped-unit unstick), and Terran Supply Depot front-door state tracking & unstick pathing.
  - [`lib/perception-grid.rkt`](lib/perception-grid.rkt) & [`lib/okasaki-sc.rkt`](lib/okasaki-sc.rkt) — Spatial threat sectors, crit-bit tries, 2–3 finger trees, and choke zippers.
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
