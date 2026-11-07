#!/usr/bin/env python3
"""
Thin launcher for the Pure Racket `#lang sc-bot` Replay Corpus Evaluator.

Contains ZERO brain modeling or prediction logic in Python:
1. Unpacks binary `.SC2Replay` MPQ archives into raw S-expressions (`replays/corpus_checkpoints.sexp`)
   via `tools/unpack_sc2replay_mpq_to_sexp.py` if needed.
2. Executes the real Racket `#lang sc-bot` brain (`lib/mirror-mind-predictor.rkt`,
   `lib/econ-ledger.rkt`, `lib/bot-runtime.rkt`, `lib/zerospace-mastermind.rkt`) via
   `/home/antigravity/toolchains/racket/bin/racket tools/evaluate-replays-racket.rkt`.
"""

import os
import subprocess
import sys

RACKET_BIN = "/home/antigravity/toolchains/racket/bin/racket"


def main():
    if not os.path.exists("replays/corpus_checkpoints.sexp") or "--unpack" in sys.argv:
        subprocess.run([sys.executable, "tools/unpack_sc2replay_mpq_to_sexp.py"], check=True)
    subprocess.run([RACKET_BIN, "tools/evaluate-replays-racket.rkt"], check=True)


if __name__ == "__main__":
    main()
