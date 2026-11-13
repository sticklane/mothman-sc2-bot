# Wave 6 Ladder Forensics & Gameplay Fix Specification

**Status:** Drafted (Spec Only — No Code Changes Applied)  
**Target Branch:** `main` (`mothman-sc2-bot`)  
**Source Batch:** AI Arena Validation Matches `#5122401`–`#5122408` (Map Pool `#18`, Pure-Racket `lib/bot-runtime.rkt` + `lib/sc2-protobuf-ws.rkt`)

---

## 1. Executive Summary & Batch Baseline (`#5122401`–`#5122408`)

Wave 5 (`206bf04`) confirmed runtime stability across all 7 completed matches in the batch (`0` crashes, `0` action errors, `0` stderr exceptions, and `max_escrow_age_frames` strictly bounded at `184–221` frames). However, all 7 completed matches were losses (`0W - 7L - 0T`), with `#5122406` (`Mothman-T` vs `titania`) still in progress at spec time:

| Match | Bot | Opponent | Map | Result | Key Forensic Signal |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `#5122401` | `Mothman-Z` | `Creepy_strategies` (P) | Ley Lines AIE | Loss (186.1s) | Lost 14 Drones + 2 Lings vs 0 opp losses to Probe rush; `max_escrow_age=220` |
| `#5122402` | `Mothman-T` | `Thssprtssbt` (P) | — | Loss | Completed, no replay file uploaded by AI Arena |
| `#5122403` | `Mothman-P` | `sludgement2-revived` (Z) | Pylon AIE | Loss (523.9s) | Even early (16 vs 15W), lost Min 6–7 to Roach/Ling swarm (1575 vs 2575 army) |
| `#5122404` | `Mothman-X` (P) | `mini-puck` (P) | Pylon AIE | Loss (515.4s) | `gateway@469.0` delayed ~560f; `saving_for=immortal` in 46 snapshots with 0 Robo until Min 7; lost to 47 Stalkers vs 14 |
| `#5122405` | `Mothman-Z` | `oberon` (T) | Persephone AIE | Loss (816.7s) | 4 Hatcheries, stalled at 35 Drones (`drone@4.9`), `SUPPLY_BLOCKED` 21/116 snapshots |
| `#5122406` | `Mothman-T` | `titania` (Z) | — | In Progress | Still queued/running on AI Arena at spec time |
| `#5122407` | `Mothman-P` | `who` (P) | Torches AIE | Loss (247.2s) | Lost 24 Probes at Min 2 to Probe+Zealot rush (0 opp losses) |
| `#5122408` | `Mothman-X` (P) | `Creepy_strategies` (P) | Ultralove AIE | Loss (209.1s) | `gateway@469.0` delayed; lost all 16 Probes at Min 1 to Probe rush (0 opp losses) |

This specification defines **4 gameplay fix tracks** plus **repo housekeeping / follow-up items**.

---

## 2. Fix Track 1: Early Worker-Rush & Mixed Probe+Zealot Defense Micro (`#5122401`, `#5122407`, `#5122408`)

### Root Causes
1. **Tight leash snap-back (`lib/bot-runtime.rkt:1630–1656, 1966–1977`)**: When `heavy-worker-allin-no-army?` is `#t`, `rush-th-pull-rad` (`7.0`) and `rush-chase-leash-rad` (`8.5`) cause `worker-rush-engage-enemies` to empty whenever `Creepy_strategies` kites bruised Probes slightly past `7.0` tiles, immediately snapping defenders back to `harvest-mineral` (`L1976`) while enemy Probes re-engage exposed miners.
2. **Late disengage & long re-disengage lockout (`lib/bot-runtime.rkt:1661–1693`)**: `eff-disengage-hp` (`14` when `>= 11` enemy workers) triggers only after a Probe/Drone is 2–3 hits from death, slides for `24` frames (`1.1s`), and locks out further disengagement for `92` frames (`prev-cd-until = (+ frame 92)`), causing bruised workers to re-enter melee at `10–14` HP and die.
3. **Pass-2 blind Attack-Move (`lib/bot-runtime.rkt:1914–1942`)**: In `>= 6`-worker brawls (`L1920`), `local-cands` is forced to `'()`, sending all non-melee defenders to `(0, focus-amove-x, focus-amove-y)` (blind Attack-Move). Defenders spread damage across full-HP enemy Probes while the opponent focus-fires single targets and mineral-walks bruised Probes away.
4. **Mixed Worker + Zealot rushes (`#5122407`)**: `worker-rush-active?` only tracks pure worker rushes; against mixed Probe+Zealot rushes (`who`), pulled Probes trade into Zealots (`16` dmg/hit, `150` HP) instead of kiting/evacuating around friendly combat units.

### Proposed Changes
1. **Tune bruised-worker disengage & cooldown (`lib/bot-runtime.rkt:1661–1693`)**:
   - Raise `eff-disengage-hp` to `<= 20` total HP+shield (or `shield <= 2` and `hp < 20` for Probes) when `worker-rush-active?` is `#t` so Probes disengage while they still have 3–4 hits of buffer and can regenerate shields.
   - Reduce `prev-cd-until` from `+92` frames to `+45` frames, and allow an immediate re-disengage override if `whp <= 10` (`<= 2` hits from death).
2. **Replace Pass-2 blind Attack-Move with targeted focus-fire (`lib/bot-runtime.rkt:1914–1942`)**:
   - Remove the `(if (and live-obs-harvesters? (>= e-cnt 6)) '() ...)` short-circuit so workers within `4.5–6.0` tiles pick the lowest `(hp + shield)` non-retreating enemy worker (capped at `effective-chaser-cap`) via unit-targeted `pull-workers-attack` instead of spreading damage with `(0, focus-amove-x, focus-amove-y)`.
   - Add a brief hysteresis (`12–16` frames) before snapping defenders back to `harvest-mineral` (`L1966–1977`) when enemy workers step just outside `7.0` tiles so defenders don't ping-pong between mining and fighting.
3. **Mixed Worker+Combat defense (`lib/bot-runtime.rkt`)**:
   - When enemy combat units (e.g., Zealots, Zerglings) accompany enemy workers near the main mineral line, keep Probes from fighting enemy Zealots unless cornered; prioritize pulling Probes onto enemy *workers* or mineral-walking away while friendly Zealots/Stalkers/Queens tank and focus-fire.

### Acceptance Criteria
- Against simulated 12-Probe rush (`Creepy_strategies` pattern) and mixed Probe+Zealot rush (`who` pattern), defender kill ratio improves from `0` enemy kills to positive/even trades with `>= 50%` fewer worker losses.

---

## 3. Fix Track 2: Early Protoss Gateway Placement Delay (`#5122404`, `#5122408`)

### Root Causes
1. **Anchor overwrite in `lib/sc2-protobuf-ws.rkt:8022–8046`**: `(pylon-power-anchor req-x req-y)` overwrites `wall-slot-1` `(req-x, req-y)` with the Pylon's `(px, py)` before calling `find-verified-building-placement`. Consequently, `matched-wall-slot` (`L5441–5448`) checks distance `<= 3.0` from the Pylon instead of `wall-slot-1`, failing to strip the `wall-slot` / `doorway-corridor` AABBs in `step-reserved-aabbs` (`lib/bot-runtime.rkt:3753`).
2. **Silent failure + 56-frame lockout (`lib/bot-runtime.rkt:4019–4037, 6220–6225` & `lib/sc2-protobuf-ws.rkt:5387`)**: `emit-build-verified! 'gateway` immediately locks `build-issue-blocked? 'gateway 56` even when `find-verified-building-placement` returns `#f` (cached for `32` frames), giving `bot-runtime.rkt` no feedback to fall back to `inmain-powered-gx/gy`.
3. **Distance mismatch on `first-ready-pylon` (`lib/bot-runtime.rkt:6174–6185, 6207–6212`)**: During `worker-rush-active?` or `in-base-proxy-detected?`, `first-ready-pylon` rejects Pylons `> 7.5` tiles from the Nexus, whereas `priority-macro-brain.rkt:2282` sees `ready-bldg-counts['pylon] >= 1` and keeps `gateway@469.0` scheduled while `bot-runtime.rkt:6208` waits ~403+ frames for a new in-main Pylon.
4. **Late emergency Pylon & 250M Gateway deadlock (`lib/bot-runtime.rkt:3590–3602, 3897–3909, 6212`)**: `protoss-emergency-pylon?` waits until `supply-used >= 14` (vs Terran's `>= 13` or `minerals >= 100`), and `hard-supply-lockout-reserve-min` (`100M`) forces `minerals >= 250` for the 1st Gateway, at which point `need-supply?` (`L3774`) spends `100M` on a Pylon first and drops minerals back to `150M`.

### Proposed Changes
1. **Preserve `(req-x, req-y)` as primary anchor (`lib/sc2-protobuf-ws.rkt:8022–8033`)**: Pass `(cons req-x req-y)` first in `#:anchor-points` when `(req-x, req-y)` is powered, falling back to `(pylon-power-anchor ...)` only if the exact wall slot fails.
2. **Shorten lockout & fall back on placement failure (`lib/bot-runtime.rkt:3753, 4019–4037, 6220–6225`)**: When `power-placement-failed?` is `#t` or `oledger` shows no active worker build order after `16` frames, clear the `56`-frame `build-issue-blocked?` lock and retry at `inmain-powered-gx/gy` with `#:exact-wall-slot? #f`.
3. **Align `first-ready-pylon` (`lib/bot-runtime.rkt:6174–6185`)**: If any ready Pylon exists and `frame > 500`, allow placing the 1st Gateway in its power field (`inmain-powered-gx/gy`) rather than stalling behind a 403-frame replacement Pylon.
4. **Earlier 1st Pylon (`lib/bot-runtime.rkt:3590–3602`)**: Match `terran-emergency-depot?` (`(>= supply-used 13)` or `(and live-game-obs? (>= minerals 100) (< frame 3000))`) so supply is already open when `gateway@469.0` becomes affordable.

### Acceptance Criteria
- `gateway@469.0` transitions from `scheduled` to placed within `<= 48` frames of `minerals >= 150` and `pylon` completion (eliminating the `~560`-frame float to `305M`).

---

## 4. Fix Track 3: Protoss Escrow Priority vs. Robo/Production Scaling (`#5122403`, `#5122404`)

### Root Causes
1. **Unbuilt-prerequisite `saving_for=immortal` (`lib/econ-ledger.rkt:3047, 3084, 3354, 3379, 3490–3534` & `lib/priority-macro-brain.rkt:2484–2487`)**: At `supply-used >= 34`, `evaluate-build-order-next-step` selects `(pro-bo-goal 'train 'immortal 1 34 'robotics-facility)` as `active-head`, so `saving_for` logs `immortal` (with `floor=0M/0G`) in 46 snapshots while `robotics-facility` is `0` and never escrowed.
2. **Robo blocked from escrowing gas under threat (`lib/priority-macro-brain.rkt:375, 1129, 1160–1163, 2203–2209`)**: `tech-under-attack-escrow-ok?` (`L2203–2209`) returns `#f` for `robotics-facility` when `requires-detection?` is `#f`, setting `blocking-allowed? = #f`. Meanwhile `stalker` (`125M/50G`) drains gas every time gas reaches `50G`.
3. **Runtime bypass & surcharges (`lib/bot-runtime.rkt:4525–4558, 4699–4703, 6347–6356, 6418–6429`)**:
   - `can-spend-by-priority?` (`L4699–4703`) bypasses `macro-brain-can-spend?` whenever `> live-enemy-threat-supply 0`, letting `stalker`, `stargate`, and `forge` spend gas freely.
   - `aa-stargate-min-ok?` / `aa-stargate-gas-ok?` (`L6347–6356, 6426–6427`) and `core-progression-exempt-from-surcharge?` (`L4527`) effectively raise the 1st `robotics-facility` cost to `275M/150G`–`300M/200G` under attack.

### Proposed Changes
1. **Resolve missing prerequisites in BO/Escrow (`lib/econ-ledger.rkt:3529–3534` & `lib/priority-macro-brain.rkt:2484–2487`)**: When `active-head` is a `train` goal whose structure prerequisite (`robotics-facility`) has `total-bldg-counts == 0`, resolve `saving_for` / `bo-goal-sym` to `'robotics-facility` so `150M/100G` is actually escrowed.
2. **Exempt 1st `robotics-facility` under pressure (`lib/priority-macro-brain.rkt:2203–2209` & `lib/bot-runtime.rkt:4525–4531`)**:
   - In `tech-under-attack-escrow-ok?`, allow `blocking-allowed? = #t` for `robotics-facility` when `(= (bldg-count-equivalent total-bldg-counts 'robotics-facility) 0)`, `ready-bldg-counts['cybernetics-core] > 0`, and `workers >= 20`.
   - In `core-progression-exempt-from-surcharge?`, exempt the 1st `robotics-facility` when `supply-used >= 30`, and do not apply `aa-stargate-gas-ok?` against the 1st `robotics-facility` unless an enemy air threat is actually present.
3. **Reserve gas for pending Robo & scale midgame Gateways (`lib/bot-runtime.rkt:4700–4703, 7034–7075`)**: When `cur-robo-cnt == 0`, `cybernetics-core` is ready, `supply-used >= 34`, and `ally-combat-units >= 4`, reserve `100G` before training `stalker`s so `robotics-facility` builds on time instead of stalling until Min 7.

### Acceptance Criteria
- `saving_for=immortal` never appears with `0` `robotics-facility` in `[SCBOT_PRIORITY]`.
- 1st `robotics-facility` starts before `4:30` in PvP/PvZ when `cybernetics-core` is ready and `workers >= 20`.

---

## 5. Fix Track 4: Zerg Worker Cap (35 Drones) & Supply Blocks (`#5122405`)

### Root Causes (35-Drone Cap)
1. **34-worker curve cliff + mineral drain catch-22 (`lib/sc2-game-constants.rkt:1571–1579`, `lib/econ-ledger.rkt:2176–2179, 2249–2254`, `lib/priority-macro-brain.rkt:1788–1795`, `lib/bot-runtime.rkt:4654–4666`)**: At `34` workers, `required-army-supply-for-worker-growth` jumps from `4.0` to `14.0`. On 4 Hatcheries, Queens (`150M`), Hydralisks (`100M/50G`), Overseers (`50M/50G`), and Overlords (`100M`) keep minerals `< 150M`, breaking the `minerals >= 150` bypass and clamping `drone` to `<= 105.0` (`blocking-allowed? = #f`).
2. **Utility collapse to `drone@4.9` (`lib/econ-ledger.rkt:1690–1693, 2026–2029` & `lib/priority-macro-brain.rkt:1797–1801, 2036–2072`)**: Whenever `enemy-threat-supply > 0`, `compute-candidate-marginal-utility` drops `+35.0` and scales by `1 / (1 + 1.8 * threat-pressure)` (producing `drone@4.9`), while `need-worker-saturation?` drops the `430.0` boost.
3. **6-Queen & `6 * hatcheries` army gate (`lib/priority-macro-brain.rkt:413–414, 1107–1108, 2258–2261` & `lib/bot-runtime.rkt:5763–5781`)**: `desired-zerg-queen-count` targets `6` Queens (`440.0–495.0`) on 4 Hatcheries, and `zerg-drone-priority?` requires `live-army-supply >= 24` (`6 * 4`) under any enemy threat before prioritizing Drones.

### Root Causes (Supply Blocks — 21/116 Snapshots)
1. **Full `+8` immediate credit for morphing Overlords (`lib/econ-ledger.rkt:1656–1672` & `lib/bot-runtime.rkt:3543–3544`)**: A newly started Overlord (~400 frames morph time) immediately adds `+8` to `eff-supply` and zeros `supply-hazard` (`econ-ledger.rkt:1664`), preventing a 2nd/3rd Overlord from morphing until the 4-Hatchery larva wave hits a supply block.
2. **Single-Overlord-per-frame emission & late mineral hold (`lib/bot-runtime.rkt:3493–3501, 3774–3785, 3915–3923`)**: `max-pending-supply` is capped at `2` for `supply-cap < 66` regardless of Hatchery count, and `zerg-hold-overlord-min?` only holds `100M` when `eff-pending-supply <= 0` and `supply-left <= 4`.

### Proposed Changes
1. **Relax Zerg worker saturation gates (`lib/sc2-game-constants.rkt`, `lib/econ-ledger.rkt`, `lib/priority-macro-brain.rkt`, `lib/bot-runtime.rkt`)**:
   - Floor `worker` utility above passive filler (e.g., `>= 60.0`) when `workers < min(66, 16 * active-bases)` and `(not under-attack?)` instead of collapsing to `drone@4.9` on passive `enemy-threat-supply`.
   - Allow interleaved droning (e.g., 1 Drone per 1–2 combat units) when `active-bases >= 3` and `workers < 55`, rather than hard-locking at `34` until `army >= 14` or `24`.
   - Once `cur-queens >= active-bases` (4 Queens on 4 Hatcheries), drop extra Queen utility below `drone` saturation while `workers < min(60, 16 * active-bases)`.
2. **Discount pending Overlords & scale with Hatcheries (`lib/econ-ledger.rkt:1656–1672`, `lib/bot-runtime.rkt:3446–3501, 3543–3544, 3915–3923`)**:
   - Credit at most `+2` to `+4` effective supply per newly started Overlord (instead of `+8`), and do not zero `supply-hazard` when `pending-supply == 1` on `>= 3` Hatcheries.
   - Allow `max-pending-supply >= 3` when `active-bases >= 3` (even if `supply-cap < 66`), and trigger `zerg-hold-overlord-min?` at `supply-threshold` (including holding for a 2nd Overlord when `pending-supply == 1` and `supply-left <= 4` on `>= 3` bases).

### Acceptance Criteria
- In a 4-Hatchery Zerg macro game vs Bio-Marauder (`oberon` pattern), `Mothman-Z` reaches `>= 50–60` Drones by Min 7 with `<= 3` `SUPPLY_BLOCKED` snapshots.

---

## 6. Additional Known Repo Items & Follow-Ups

1. **Match `#5122406` & `#5122402` Follow-Up**:
   - Re-check `#5122406` (`Mothman-T` vs `titania`) once AI Arena completes it, and check why `#5122402` (`Mothman-T` vs `Thssprtssbt`) had no replay uploaded.
2. **Retire Legacy `Mothman-R` (`#1457`) & `Mothman.zip` Build Targets**:
   - `.github/workflows/deploy-aiarena.yml` already excludes `Mothman-R`. Clean up remaining build/reference entries in `ladder/build-aiarena-zip.rkt` (`lines 12, 71, 235, 270`) and `tools/aiarena-api-client.rkt` (`line 265`).
3. **Pure-Racket Tooling Cleanup (`AGENTS.md` Compliance)**:
   - Archive or remove legacy Python scripts (`tools/*.py`, `sc-bot/tools/*.py`, `sc-bot/ladder/build_aiarena_zip.py`, `sc-bot/sim/sc2_burny_bridge.py`) once confirmed unused, keeping 100% Pure-Racket tooling per `AGENTS.md`.
4. **Test & Push Guardrails (`AGENTS.md` `RC-001` / `BUG-016`)**:
   - Any regression tests added for Fix Tracks 1–4 in `tests/run-all-tests.rkt` must keep default fast execution `< 5s` (gating heavy sims behind `full-test-mode?`) and use `./scripts/atomic-test-and-push.sh`.
