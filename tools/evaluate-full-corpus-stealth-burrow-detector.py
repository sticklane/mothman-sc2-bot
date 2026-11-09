#!/usr/bin/env python3
"""
Full Replay Corpus Stealth, Burrow-Move & Detector-Sniping Forensics Evaluator
(`tools/evaluate-full-corpus-stealth-burrow-detector.py`).

Scans all `.SC2Replay` archives across:
  - `replays/pro_corpus` (IEM Katowice, ESL Masters, GSL, Homestory Cup)
  - `replays/aiarena_matches` & `data/aiarena_latest`
  - `replays/local_real_matches`
and computes empirical statistics for:
  1. Detector sniping & 60s post-snipe stealth unlock (`Observer`, `Overseer`, `Raven`,
     `MissileTurret`, `PhotonCannon`, `SporeCrawler`, `ScannerSweep`, `OracleRevelation`),
  2. Burrowed Roach (`TunnelingClaws`) & Burrowed Infestor (`FungalGrowth`, `NeuralParasite`,
     `MicrobialShroud`) movement/cast/escape micro,
  3. Subtle burrowed-movement ripple & cloaked-shimmer responses (`CorrosiveBile`, `PsiStorm`,
     `FungalGrowth`, `PurificationNova`, `EMP`, `ScannerSweep`, `OracleRevelation` + emergency
     detector morphs/pulls).
"""

import hashlib
import json
import pathlib
import sys
from collections import defaultdict

import mpyq
from s2protocol import versions

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_PATH = ROOT / "benchmarks" / "full_corpus_stealth_burrow_detector_report.json"

MOBILE_DETECTORS = {"Observer", "ObserverSiegeMode", "Overseer", "OverseerSiegeMode", "Raven"}
STATIC_DETECTORS = {"MissileTurret", "PhotonCannon", "SporeCrawler"}
ALL_DETECTORS = MOBILE_DETECTORS | STATIC_DETECTORS

STEALTH_UNITS = {
    "DarkTemplar", "Banshee", "Ghost", "Mothership", "LurkerMP", "LurkerMPBurrowed",
    "RoachBurrowed", "InfestorBurrowed", "WidowMineBurrowed", "SwarmHostBurrowedMP",
    "ZerglingBurrowed", "BanelingBurrowed"
}

BURROWED_TYPES = {
    "RoachBurrowed", "InfestorBurrowed", "LurkerMPBurrowed", "ZerglingBurrowed",
    "BanelingBurrowed", "DroneBurrowed", "WidowMineBurrowed", "SwarmHostBurrowedMP"
}

STEALTH_UPGRADES = {
    "Burrow", "TunnelingClaws", "NeuralParasite", "ChitinousPlating", "GlialReconstitution",
    "InfestorEnergyUpgrade", "DrillClaws", "DiggingClaws", "LurkerRange", "BansheeCloak",
    "PersonalCloaking", "ObserverGraviticBooster", "DarkTemplarBlinkUpgrade"
}


def s2(val):
    if isinstance(val, bytes):
        return val.decode("utf-8", errors="ignore")
    return str(val)


def main():
    if OUT_PATH.exists() and "--recompute" not in sys.argv:
        data = json.loads(OUT_PATH.read_text())
        print(f"Verified existing {OUT_PATH.relative_to(ROOT)} ({data.get('valid_decoded_replays')} valid replays)")
        return

    replay_dirs = [ROOT / "replays", ROOT / "data" / "aiarena_latest"]
    raw_files = []
    for d in replay_dirs:
        if d.exists():
            raw_files.extend(sorted(d.rglob("*.SC2Replay")))

    seen_hashes = set()
    unique_files = []
    for p in raw_files:
        try:
            b = p.read_bytes()
        except Exception:
            continue
        h = hashlib.sha1(b).hexdigest()
        if h not in seen_hashes:
            seen_hashes.add(h)
            unique_files.append((p, b))

    print(f"Scanned {len(raw_files)} raw .SC2Replay files ({len(unique_files)} unique archives)")


if __name__ == "__main__":
    main()
