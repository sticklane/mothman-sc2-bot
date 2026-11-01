#!/usr/bin/env bash
# ==============================================================================
# build_and_run_mac.sh — Build & Run the 13-Pillar UDIE Engine + Ollama Server
#                        Locally on macOS (Apple Silicon M1/M2/M3/M4 or Intel)
#                        or Linux
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p engine/bin ollama_mac

ARCH="$(uname -m)"
OS="$(uname -s)"
CC_BIN="${CC:-cc}"

if [ "$OS" = "Darwin" ]; then
    LINK_STRIP="-Wl,-S"
else
    LINK_STRIP="-Wl,--strip-all"
fi

PARENT_DIR="$(dirname "$ROOT_DIR")"

if [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
    SIMD_FLAGS="-O3 -g0 $LINK_STRIP -ffile-prefix-map=$ROOT_DIR=. -ffile-prefix-map=$PARENT_DIR=. -std=c11 -Wall -Wextra"
    echo "[UDIE-Mac] Detected Apple Silicon / ARM64 ($OS/$ARCH) -> Enabling ARM64 NEON vqtbl1q_s8 + vpadalq_s16 kernels"
else
    SIMD_FLAGS="-O3 -g0 $LINK_STRIP -ffile-prefix-map=$ROOT_DIR=. -ffile-prefix-map=$PARENT_DIR=. -mavx2 -mfma -mbmi -mbmi2 -mpopcnt -std=c11 -Wall -Wextra"
    echo "[UDIE-Mac] Detected x86_64 ($OS/$ARCH) -> Enabling AVX2 vpshufb + POPCNT kernels"
fi

echo "[1/3] Compiling standalone 13-Pillar C Engine (engine/bin/udie_engine)..."
$CC_BIN $SIMD_FLAGS -Iengine/include \
    engine/src/udie_math.c \
    engine/src/udie_kv_ssm.c \
    engine/src/udie_transport.c \
    engine/src/udie_cli_main.c \
    -o engine/bin/udie_engine -lm -lpthread

echo "[2/3] Compiling Ollama-Compatible Local Server & CLI (engine/bin/udie_ollama_server)..."
$CC_BIN $SIMD_FLAGS -Iengine/include \
    engine/src/udie_math.c \
    engine/src/udie_kv_ssm.c \
    engine/src/udie_transport.c \
    engine/src/udie_ollama_server.c \
    -o engine/bin/udie_ollama_server -lm -lpthread

echo "[3/3] Running Self-Test &Generating Ollama Modelfiles + GGUF Bundle..."
./engine/bin/udie_ollama_server test-api ollama_mac/udie_ollama_mac_verification_report.json
python3 ollama_mac/export_udie_to_ollama_gguf.py

echo ""
echo "================================================================================"
echo "READY TO RUN ON YOUR MAC:"
echo "  Option A (Native C 13-Pillar UDIE CLI):"
echo "    ./engine/bin/udie_ollama_server run smollm2-1.7b-udie \"Explain quantum KP-Tree routing\""
echo "    ./engine/bin/udie_ollama_server run olmoe-1b-7b-udie \"Solve step by step...\""
echo ""
echo "  Option B (Drop-In Ollama HTTP Server on port 11434):"
echo "    ./engine/bin/udie_ollama_server serve 11434"
echo ""
echo "  Option C (Import directly into macOS Ollama.app):"
echo "    ollama create smollm2-135m-udie -f ollama_mac/Modelfile.smollm2-135m-udie"
echo "    ollama create smollm2-1.7b-udie -f ollama_mac/Modelfile.smollm2-1.7b-udie"
echo "    ollama create olmoe-1b-7b-udie  -f ollama_mac/Modelfile.olmoe-1b-7b-udie"
echo "    ollama run smollm2-1.7b-udie"
echo "================================================================================"
