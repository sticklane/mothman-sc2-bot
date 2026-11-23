#!/usr/bin/env bash
# Per-lane isolated Racket compile + test wrapper.
#
# Usage:
#   tools/racket-lane-test.sh <lane-name> --compile <src1.rkt> [src2.rkt ...] -- <test1.rkt> [test2.rkt ...]
#   tools/racket-lane-test.sh <lane-name> -- <test1.rkt> [test2.rkt ...]
#   tools/racket-lane-test.sh <lane-name> <test1.rkt> [test2.rkt ...]
#
# Compiles ONLY the listed files into an isolated /tmp/zo-<lane>-<pid> root using
# PLTCOMPILEDROOTS="${ZO_DIR}:", reading untouched repo compiled/*.zo files without
# ever writing .zo files into the repository or colliding with parallel lanes.

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  tools/racket-lane-test.sh <lane-name> --compile <src1.rkt> [src2.rkt ...] -- <test1.rkt> [test2.rkt ...]
  tools/racket-lane-test.sh <lane-name> -- <test1.rkt> [test2.rkt ...]
  tools/racket-lane-test.sh <lane-name> <test1.rkt> [test2.rkt ...]
EOF
}

if [[ $# -lt 1 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  usage
  exit 2
fi

LANE="$1"
shift

SAFE_LANE="$(printf '%s' "$LANE" | tr -cs 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//')"
if [[ -z "$SAFE_LANE" ]]; then
  SAFE_LANE="lane"
fi

COMPILE_FILES=()
TEST_FILES=()
MODE="tests"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compile)
      MODE="compile"
      shift
      ;;
    --)
      MODE="tests"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ "$MODE" == "compile" ]]; then
        COMPILE_FILES+=("$1")
      else
        TEST_FILES+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
  echo "[racket-lane-test] ERROR: at least one test .rkt file is required." >&2
  usage
  exit 2
fi

for f in "${COMPILE_FILES[@]}" "${TEST_FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "[racket-lane-test] ERROR: file not found: $f" >&2
    exit 2
  fi
done

if ! command -v raco >/dev/null 2>&1 || ! command -v racket >/dev/null 2>&1; then
  echo "[racket-lane-test] ERROR: raco and racket must be installed in PATH." >&2
  exit 127
fi

now_ms() {
  date +%s%3N
}

fmt_sec() {
  local ms="$1"
  printf '%d.%02ds' $((ms / 1000)) $(((ms % 1000) / 10))
}

ZO_DIR="/tmp/zo-${SAFE_LANE}-$$"
trap 'rm -rf "$ZO_DIR"' EXIT
mkdir -p "$ZO_DIR"

TOTAL_T0="$(now_ms)"
MAKE_TARGETS=()
if [[ ${#COMPILE_FILES[@]} -gt 0 ]]; then
  MAKE_TARGETS+=("${COMPILE_FILES[@]}")
fi
MAKE_TARGETS+=("${TEST_FILES[@]}")

COMPILE_T0="$(now_ms)"
env PLTCOMPILEDROOTS="${ZO_DIR}:" raco make "${MAKE_TARGETS[@]}"
COMPILE_MS=$(( $(now_ms) - COMPILE_T0 ))
echo "[racket-lane-test] lane=${SAFE_LANE} compiled=${#MAKE_TARGETS[@]} files in $(fmt_sec "$COMPILE_MS") (isolated=${ZO_DIR})"

for test_file in "${TEST_FILES[@]}"; do
  TEST_T0="$(now_ms)"
  env PLTCOMPILEDROOTS="${ZO_DIR}:" racket "$test_file"
  TEST_MS=$(( $(now_ms) - TEST_T0 ))
  echo "[racket-lane-test] PASS ${test_file} ($(fmt_sec "$TEST_MS"))"
done

TOTAL_MS=$(( $(now_ms) - TOTAL_T0 ))
echo "[racket-lane-test] lane=${SAFE_LANE} ALL ${#TEST_FILES[@]} tests PASSED in $(fmt_sec "$TOTAL_MS")"
