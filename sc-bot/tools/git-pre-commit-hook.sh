#!/usr/bin/env bash
# Git pre-commit hook: Rebuilds AI Arena bot .zip packages and stages them
# whenever sc-bot code or bot-building scripts are modified in the commit.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SC_BOT_DIR="${REPO_ROOT}/sc-bot"
BUILD_SCRIPT="${SC_BOT_DIR}/ladder/build_aiarena_zip.py"

if [[ ! -f "${BUILD_SCRIPT}" ]]; then
    exit 0
fi

# Check if any staged files touch sc-bot source, runtime, bridge, or zip builder
CHANGED_BOT_FILES="$(git diff --cached --name-only | grep -E '^sc-bot/(bots|lib|compiler|sc-bot|sim|ffi|run\.py|main\.rkt|info\.rkt|config\.json|ladder/build_aiarena_zip\.py)' || true)"

if [[ -n "${CHANGED_BOT_FILES}" ]]; then
    echo "[pre-commit] Detected changes in sc-bot code or builder:"
    echo "${CHANGED_BOT_FILES}" | sed 's/^/  - /'
    echo "[pre-commit] Rebuilding AI Arena .zip packages (Mothman, Mothman-R, Mothman-Z, Mothman-T, Mothman-P)..."
    python3 "${BUILD_SCRIPT}" --all-races >/dev/null
    git add -f \
        "${SC_BOT_DIR}/ladder/Mothman.zip" \
        "${SC_BOT_DIR}/ladder/Mothman-R.zip" \
        "${SC_BOT_DIR}/ladder/Mothman-Z.zip" \
        "${SC_BOT_DIR}/ladder/Mothman-T.zip" \
        "${SC_BOT_DIR}/ladder/Mothman-P.zip"
    echo "[pre-commit] Staged updated sc-bot/ladder/*.zip archives into commit."
fi
