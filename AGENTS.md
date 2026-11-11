# AI Agent Instructions: Persistence, Workspace Layout, and Avoiding `/tmp`

> **CRITICAL RULE FOR ALL AI AGENTS & SUBAGENTS**:
> **NEVER store project repositories, formal models, test suites, reproducers, or build artifacts exclusively in `/tmp`, `/var/tmp`, or `/dev/shm`.**
> Ephemeral VM environments wipe `/tmp` across container/VM restarts, preemptions, and session resumptions.

---

## 1. Why `/tmp` Must Be Avoided

1. **VM Restarts & Preemptions Wipe `/tmp`**:
   - In cloud/remote agent VMs, `/tmp` is backed by `tmpfs` (RAM) or an ephemeral root overlay that is destroyed whenever the VM restarts or suspends.
   - Any repository cloned only into `/tmp/<repo>` that has uncommitted files, unpushed branches, or local package links (`raco pkg`, `cargo`, `lake`, `coqc`) pointing into `/tmp/<repo>` will **break or vanish** after a restart.
2. **Broken Tooling Symlinks**:
   - Package managers (such as `raco pkg install --link`, `cargo` path dependencies, or `elan`/`lake` overrides) record absolute paths in `~/.racket/` or `~/.cargo/`. If those paths point into `/tmp/...`, the toolchain itself fails on startup after a reboot.

---

## 2. What to Do Instead (Mandatory 4-Step Protocol)

### Rule 1: Clone and Work Under the Persistent Workspace Root (`/home/antigravity/<workspace-parent>/`)
Always place all sibling repositories under the persistent parent directory of the mounted workspace (e.g., `/home/antigravity/<owner>/` or directly inside a subdirectory of the primary mounted repository):
- Primary mounted workspace: `/home/antigravity/<owner>/decompose-plug`
- Sibling persistent clones:
  - `/home/antigravity/<owner>/rust-redex`
  - `/home/antigravity/<owner>/redex`
  - `/home/antigravity/<owner>/lean4`
  - `/home/antigravity/<owner>/lean4lean`
  - `/home/antigravity/<owner>/redex2coq`

```bash
# BAD — disappears on VM restart:
git clone https://github.com/<owner>/<repo>.git /tmp/<repo>

# GOOD — persists on the workspace disk:
WORKSPACE_PARENT="$(dirname "$(pwd)")"
git clone https://github.com/<owner>/<repo>.git "${WORKSPACE_PARENT}/<repo>"
```

### Rule 2: Mirror Multi-Repo Deliverables Inside the Primary Mounted Repository
Whenever a task creates or extends a companion repository (such as `rust-redex`), **also maintain a tracked mirror directory inside the primary mounted repository** (e.g., `decompose-plug/rust-redex/`):
```bash
rm -rf /home/antigravity/<owner>/decompose-plug/rust-redex
cp -a /home/antigravity/<owner>/rust-redex /home/antigravity/<owner>/decompose-plug/rust-redex
rm -rf /home/antigravity/<owner>/decompose-plug/rust-redex/.git
```
This guarantees that even if external sibling directories outside the primary mount are not snapshotted by the host platform, **100% of the code lives inside the primary mounted repository**.

### Rule 3: Link Local Packages Only to Persistent Paths
When linking local packages into a language toolchain (e.g., Racket's `raco pkg`), always link to the persistent directory, never `/tmp`:
```bash
# BAD:
raco pkg install --link /tmp/plt-redex/redex-lib

# GOOD:
raco pkg install --installation --link --no-setup \
  "${WORKSPACE_PARENT}/redex/redex-lib" \
  "${WORKSPACE_PARENT}/redex/redex-test"
```

### Rule 4: Commit and Push Immediately After Every Verified Milestone (With Anonymized Git Identity)
Never leave verified work uncommitted or unpushed on the local VM disk:
1. Configure anonymized git identity in every repository before committing:
   ```bash
   git config user.name "anonymous"
   git config user.email "anonymous@noreply.localhost"
   ```
2. Verify that no personal usernames or tokens appear in tracked files:
   ```bash
   ! git grep -i "<owner-username>"
   ```
3. Push to all target branches on `origin` immediately after tests pass:
   ```bash
   git push origin HEAD:main HEAD:master
   ```
4. Pass explicit persistent working directories (`Cwd: "/home/antigravity/<owner>/<repo>"`) when invoking subagents so subagents never default to `/tmp`.

---

## 3. Mandatory Antigravity `<10s` Anti-Hang & Atomic Commit/Push Protocol (`RC-001` / `BUG-016` Guardrails)

> **CRITICAL ANTI-HANG RULE FOR ALL AI AGENTS & SUBAGENTS**:
> In Antigravity remote uVMs, any `run_command` tool call that exceeds `WaitMsBeforeAsync` (maximum `10000` ms / `10 seconds`) is detached into a background task (`task-<N>.log`) and forces the LLM turn to exit while waiting for an asynchronous completion wakeup (`RC-001A`). If that wakeup notification is dropped by the platform router, **the conversation hangs indefinitely (`Thinking` / `Generating...`)**, and if `git push` was deferred to the next LLM turn, all local commits/edits are lost when the uVM is eventually reaped (`RC-001C`).

To prevent conversation hangs and unpushed work loss while `RC-001` remains open on the platform, **ALWAYS follow these 5 repository rules**:

### Rule 5: Keep Default `tests/run-all-tests.rkt` Execution Strictly Under `< 5 Seconds` (`< 5,000 ms`)
- Always set `WaitMsBeforeAsync: 10000` on every `run_command` call.
- Before running `racket tests/run-all-tests.rkt` after editing any `.rkt` file, compile incremental bytecode first with `raco make -j 4 tests/run-all-tests.rkt` so Racket never JIT-compiles from cold source during test execution.
- `tests/run-all-tests.rkt` runs in **`FAST-<5s` mode by default** (`full-test-mode? = #f`) and prints per-suite elapsed milliseconds (`OK (<N> ms)`).
- **Never add multi-second loops, `>5,000`-frame simulations, or subprocess spawns (`57 MB` `mothman_standalone_elf`) to the default fast path of `tests/run-all-tests.rkt`.** Gate heavy stress tests, `1,000`-frame fuzzers, or `400,000`-frame Chaos Monkey sweeps behind `(when full-test-mode? ...)` (`--full` or `SC_BOT_FULL_TEST=1`) or place them in standalone `tools/*.rkt` scripts.

### Rule 6: Use `./scripts/atomic-test-and-push.sh` (Never Split `test` and `git push` Across Separate Turns)
- **NEVER** run `racket tests/run-all-tests.rkt` in one `run_command` step and wait for the next LLM turn to run `git commit` and `git push`.
- Instead, always chain test verification, anonymized commit, and dual-branch push inside a **single OS shell command** using `./scripts/atomic-test-and-push.sh`:
  ```bash
  ./scripts/atomic-test-and-push.sh "feat: concise description of verified milestone"
  ```
- Because `./scripts/atomic-test-and-push.sh` runs `raco make -j 4`, `racket tests/run-all-tests.rkt`, `git commit`, and `git push origin HEAD:main HEAD:master` inside a single Linux child process, **even if a command ever crosses `10,000 ms` and triggers `RC-001A` backgrounding, the Linux kernel still completes the `git commit` and `git push` to GitHub automatically!**

### Rule 7: Never Rebuild All 6 `18.5 MB` BotZips (`ladder/build-aiarena-zip.rkt --all-races`) on Routine Unit-Test Edits
- `racket ladder/build-aiarena-zip.rkt --all-races` links a `57 MB` embedded ELF binary and compresses `111 MB` across 6 `.zip` archives (`~8–14 seconds`).
- Only run `--all-races` when final BotZip deliverables need updating, and **always** run it via `./scripts/atomic-test-and-push.sh --rebuild-zips "feat: ..."` so the rebuilt archives are committed and pushed in the same shell invocation.

### Rule 8: Zero Python (`python3` / `*.py`) — Use Pure Racket Exclusively
- Use `view_file` and `replace_file_content` for file inspection/editing.
- Do not call `invoke_subagent` during core `lib/`/`sim/` code-edit/test/push cycles (`RC-001B` can stall the parent agent if a subagent hits an inner `600s` command timeout).

---

## 4. Mandatory 100% Pure-Racket Policy (Zero Python for Analysis, Replay Forensics, or Tooling)

> **CRITICAL REPOSITORY LANGUAGE RULE**:
> **ALL bot logic, `.SC2Replay` MPQ/S2Protocol parsing, `match_log.zip` telemetry analysis, AI Arena REST/GraphQL match operations, corpus audits, and local `SC2_x64` match harnesses MUST be written and executed in 100% Pure Racket (`#lang racket` / `#lang racket/base` / `#lang sc-bot`).**
> **NEVER write, modify, or invoke Python (`python3`, `*.py`, `pip`, `uv`) for analysis, replay inspection, or ad-hoc scratch scripts.**

### Canonical Pure-Racket Tooling (`tools/*.rkt` & `lib/*.rkt`)
Always use the repository's compiled Racket tools (`/home/antigravity/toolchains/racket_full/bin/racket`) instead of writing new scripts or running legacy `.py` files:
1. **AI Arena BotZip Sync, Match Requests & Live Status**:
   ```bash
   /home/antigravity/toolchains/racket_full/bin/racket tools/aiarena-api-client.rkt --status
   /home/antigravity/toolchains/racket_full/bin/racket tools/aiarena-api-client.rkt --sync-zips --request-matches 8 --status
   ```
2. **Pure-Racket AI Arena Replay MPQ + S2Protocol & `match_log.zip` Forensics**:
   - Library decoder: `lib/sc2-mpq-replay-parser.rkt` (pure-Racket Blizzard MPQ decryptor + `file/gunzip` inflate + S2Protocol `VersionedDecoder` for `replay.details` & `replay.tracker.events`).
   - CLI analyzer:
     ```bash
     /home/antigravity/toolchains/racket_full/bin/racket tools/analyze-aiarena-replays.rkt --fetch --since-match 5117325
     ```
3. **Real 2-Player Headless `SC2_x64` Match Harness & Priority Queue Auditor**:
   ```bash
   /home/antigravity/toolchains/racket_full/bin/racket tools/run-real-sc2-bot-match.rkt --bot Mothman-Z --opponent Creepy_strategies --max-loops 6720
   ```
4. **Pro-Replay Starvation Audit & Multi-Match Validator**:
   ```bash
   /home/antigravity/toolchains/racket_full/bin/racket tools/audit-pro-replay-starvation.rkt
   /home/antigravity/toolchains/racket_full/bin/racket tools/racket-multi-match-validator.rkt
   ```

### Enforcement
- `./scripts/atomic-test-and-push.sh` rejects newly added `.py` files in staging unless explicitly bypassed for frozen third-party opponent harnesses.
- Never create scratch `.py` scripts in `<appDataDir>/brain/.../scratch/`; if a one-off check is ever needed, either add a reusable flag to `tools/analyze-aiarena-replays.rkt` / `tools/aiarena-api-client.rkt` or use `racket -e '...'`.
