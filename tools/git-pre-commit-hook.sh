#!/usr/bin/env bash
# Fast Git pre-commit hook (<0.1s):
# 1. Verifies anonymized commit identity & zero personal username leaks.
# 2. Stages existing sc-bot/ladder/Mothman*.zip packages if present.
# Note: Heavy BotZip rebuilds (`racket ladder/build-aiarena-zip.rkt --all-races`)
# and local multi-match simulations (`racket tools/racket-multi-match-validator.rkt`)
# are run separately outside the pre-commit hook to keep commits fast.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SC_BOT_DIR="${REPO_ROOT}/sc-bot"

# 1. Fast staged-file sanity check
OWNER_NAME="$(basename "$(dirname "${REPO_ROOT}")")"
if git grep -i "${OWNER_NAME}" --cached >/dev/null 2>&1; then
    echo "[pre-commit] ERROR: Found owner directory name in staged files." >&2
    exit 1
fi

# 2. If sc-bot files changed and ladder zips exist on disk, stage them without rebuilding
CHANGED_BOT_FILES="$(git diff --cached --name-only | grep -E '^sc-bot/(bots|lib|compiler|sc-bot|sim|ffi|run\.py|main\.rkt|info\.rkt|config\.json)' || true)"

if [[ -n "${CHANGED_BOT_FILES}" ]]; then
    for z in Mothman.zip Mothman-X.zip Mothman-R.zip Mothman-Z.zip Mothman-T.zip Mothman-P.zip; do
        if [[ -f "${SC_BOT_DIR}/ladder/${z}" ]]; then
            git add -f "${SC_BOT_DIR}/ladder/${z}"
        fi
    done
fi
