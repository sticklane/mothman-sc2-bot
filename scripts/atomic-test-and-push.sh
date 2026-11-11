#!/usr/bin/env bash
# =============================================================================
# scripts/atomic-test-and-push.sh
#
# Anti-Hang Atomic Test + Anonymized Git Commit + Dual-Branch Push Wrapper
# (Mitigates Antigravity Platform Bugs RC-001A / RC-001C / BUG-016)
#
# Why this script exists:
#   1. In Antigravity remote uVMs, any `run_command` call that exceeds
#      `WaitMsBeforeAsync` (max 10,000 ms) is sent to the background (`task-<N>.log`)
#      and forces the LLM turn to exit while waiting for an async wakeup (`RC-001A`).
#   2. If that async completion wakeup is dropped (`RC-001A`) and the uVM is later
#      reaped (`RC-001C`), any work that was tested in one `run_command` step and
#      intended to be pushed in the *next* LLM turn is stranded on the dead uVM disk.
#   3. By running:
#        (a) fast `.zo` compilation (`raco make -j 4`),
#        (b) `<5s` fast test verification (`racket tests/run-all-tests.rkt`), and
#        (c) anonymized `git commit` + `git push origin HEAD:main HEAD:master`
#      inside a SINGLE Linux shell process, the commit and push execute atomically
#      in the OS kernel even if the command ever crosses 10,000 ms!
#
# Usage:
#   ./scripts/atomic-test-and-push.sh "feat: commit message here"
#   ./scripts/atomic-test-and-push.sh --rebuild-zips "feat: rebuild BotZips and push"
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

REBUILD_ZIPS=0
SKIP_MAKE=0
FULL_TESTS=0
COMMIT_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild-zips)
      REBUILD_ZIPS=1
      shift
      ;;
    --skip-make)
      SKIP_MAKE=1
      shift
      ;;
    --full)
      FULL_TESTS=1
      shift
      ;;
    *)
      COMMIT_MSG="$1"
      shift
      ;;
  esac
done

if [[ -z "${COMMIT_MSG}" ]]; then
  echo "Usage: ./scripts/atomic-test-and-push.sh [--rebuild-zips] [--skip-make] [--full] \"<commit-message>\"" >&2
  exit 2
fi

# Locate Racket / Raco across persistent and local toolchain paths
for CANDIDATE_BIN in \
  "/home/antigravity/toolchains/racket_full/bin" \
  "/home/antigravity/toolchains/racket_runtime/bin" \
  "/home/antigravity/.local/racket/bin" \
  "/shared/user/toolchains/racket_full/bin" \
  "/shared/user/toolchains/racket/bin"; do
  if [[ -x "${CANDIDATE_BIN}/racket" ]]; then
    export PATH="${CANDIDATE_BIN}:${PATH}"
    break
  fi
done

if ! command -v racket >/dev/null 2>&1; then
  echo "[atomic-test-and-push] ERROR: 'racket' binary not found on PATH or standard toolchain locations." >&2
  exit 1
fi

echo "[1/4] Synchronizing .zo bytecode via raco make -j 4..."
if [[ "${SKIP_MAKE}" -eq 0 ]] && command -v raco >/dev/null 2>&1; then
  raco make -j 4 tests/run-all-tests.rkt
fi

if [[ "${REBUILD_ZIPS}" -eq 1 ]]; then
  echo "[1b/4] Rebuilding AI Arena BotZip archives (--all-races)..."
  racket ladder/build-aiarena-zip.rkt --all-races
fi

echo "[2/4] Running #lang sc-bot test suite..."
if [[ "${FULL_TESTS}" -eq 1 ]]; then
  racket tests/run-all-tests.rkt --full
else
  racket tests/run-all-tests.rkt
fi

echo "[3/4] Configuring anonymized git identity & staging verified changes..."
git config user.name "anonymous"
git config user.email "anonymous@noreply.localhost"

git add -A
if git diff --cached --quiet; then
  echo "[3/4] Working tree already clean and committed; pushing HEAD to origin/main & origin/master..."
else
  if git grep -i "sticklane" -- ':!AGENTS.md' >/dev/null 2>&1; then
    echo "[atomic-test-and-push] ERROR: Forbidden username found in tracked files!" >&2
    git grep -n -i "sticklane" -- ':!AGENTS.md' >&2 || true
    exit 1
  fi
  git commit -m "${COMMIT_MSG}"
fi

echo "[4/4] Pushing atomically to origin HEAD:main HEAD:master..."
git push origin HEAD:main HEAD:master
echo "[DONE] Verified, committed ($(git rev-parse --short HEAD)), and pushed to origin/main & origin/master."
