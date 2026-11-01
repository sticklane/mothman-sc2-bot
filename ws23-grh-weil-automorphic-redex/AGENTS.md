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
