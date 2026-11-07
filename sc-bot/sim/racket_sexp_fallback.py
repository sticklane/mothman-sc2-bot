#!/usr/bin/env python3
"""
sim/racket_sexp_fallback.py

Cross-platform S-Expression IPC fallback for #lang sc-bot (Mothman).
Used ONLY when neither the bundled Linux x86_64 portable Racket runtime
(`racket_runtime/bin/racket`) nor a system `racket` binary is executable
(for example, on Windows or macOS without Racket installed).
Speaks the exact same line-oriented S-expression stdin/stdout protocol as
`sim/racket_sc2_ipc_bot.rkt`.
"""

import argparse
import re
import sys


def parse_obs_sexp(line: str) -> dict:
    def _num(key: str, default: int = 0) -> int:
        m = re.search(rf"#:{key}\s+(-?\d+)", line)
        return int(m.group(1)) if m else default

    m_race = re.search(r"#:race\s+([A-Za-z-]+)", line)
    race = m_race.group(1).lower() if m_race else "zerg"
    m_eb = re.search(r"#:enemy-base\s+\(([0-9.]+)\s+([0-9.]+)\)", line)
    eb_x, eb_y = (float(m_eb.group(1)), float(m_eb.group(2))) if m_eb else (48.0, 48.0)
    m_sp = re.search(r"#:start-pos\s+\(([0-9.]+)\s+([0-9.]+)\)", line)
    sp_x, sp_y = (float(m_sp.group(1)), float(m_sp.group(2))) if m_sp else (16.0, 16.0)

    enemy_units = re.findall(r"\(\d+\s+([a-z0-9-]+)\s+[0-9.]+\s+[0-9.]+\s+[0-9.]+\)", line.split("#:enemy-units")[-1].split("#:enemy-buildings")[0]) if "#:enemy-units" in line else []
    return {
        "frame": _num("frame", 0),
        "race": race,
        "minerals": _num("minerals", 50),
        "gas": _num("gas", 0),
        "supply_used": _num("supply-used", 12),
        "supply_cap": _num("supply-cap", 14),
        "supply_left": _num("supply-left", 2),
        "start_pos": (sp_x, sp_y),
        "enemy_base": (eb_x, eb_y),
        "enemy_units": enemy_units,
    }


def step_fallback(obs: dict, current_posture: str) -> tuple[str, str]:
    race = obs["race"]
    frame = obs["frame"]
    mins = obs["minerals"]
    sup_left = obs["supply_left"]
    eu = obs["enemy_units"]

    cmds = []
    # 1. Mirror-Mind Foosball-Tournament Depth-Probed Prediction
    inferred_depth = 0 if (frame < 2016 and len(eu) >= 6) else (2 if frame > 3500 else 1)
    active_depth = min(3, inferred_depth + 1)
    hyp = "opponent-committed-early-all-in" if len(eu) >= 6 and frame < 2016 else "standard-rational-macro"
    target = "natural-choke-defense" if hyp == "opponent-committed-early-all-in" else "center-map-staging"
    pred_enemy = eu[0] if eu else "marine"
    preempt = {"zerg": "roach", "terran": "siege-tank", "protoss": "immortal"}.get(race, "roach")
    cmds.append(
        f"(mirror-prediction {active_depth} {hyp} {target} {pred_enemy} {preempt} 75 "
        f"level{active_depth}-probed-counter {inferred_depth} 20 tactical-tiebreaker-and-hedge)"
    )

    # 2. Posture transition
    next_posture = current_posture
    if current_posture in ("RandomRollOpening", "balanced-opening"):
        next_posture = {"zerg": "Macro12Hatch", "terran": "OneRaxFE", "protoss": "ForgeFastExpand"}.get(race, "Macro12Hatch")
    if next_posture != current_posture:
        cmds.append(f"(posture-transition {current_posture} {next_posture})")

    # 3. Core economy & unit training commands
    worker = {"zerg": "drone", "terran": "scv", "protoss": "probe"}.get(race, "drone")
    supply_bldg = {"zerg": "overlord", "terran": "supply-depot", "protoss": "pylon"}.get(race, "overlord")
    if sup_left <= 3:
        if race == "zerg":
            cmds.append("(train overlord)")
        else:
            sx, sy = obs["start_pos"]
            cmds.append(f"(build {supply_bldg} {sx + 4.0:.1f} {sy + 4.0:.1f})")
    if mins >= 50:
        cmds.append(f"(train {worker})")
    if mins >= 150:
        cmds.append(f"(train {preempt})")

    return "(" + " ".join(cmds) + ")", next_posture


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bot", type=str, default="bots/Mothman-R.rkt")
    parser.add_argument("--race", type=str, default="random")
    parser.add_argument("--posture", type=str, default="balanced-opening")
    args, _ = parser.parse_known_args()

    posture = args.posture
    for raw in sys.stdin:
        line = raw.strip()
        if not line or line == "(quit)":
            break
        try:
            obs = parse_obs_sexp(line)
            out, posture = step_fallback(obs, posture)
            sys.stdout.write(out + "\n")
            sys.stdout.flush()
        except Exception:
            sys.stdout.write("()\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
