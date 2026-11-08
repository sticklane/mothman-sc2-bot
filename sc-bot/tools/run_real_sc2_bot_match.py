#!/usr/bin/env python3
"""
Real 2-Player Headless SC2_x64 Match Harness (`run_real_sc2_bot_match.py`).

Runs our actual AI Arena `cpplinux` pure-Racket bot (`sim/racket-sc2-ladder-main.rkt`
or `./ladder/<BotName>`) against real downloaded AI Arena opponent bots
(`mini-puck`, `sludgement2-revived`, `onlyfans`, `CryptBotRevival`, `oberon`,
`titania`, `Tartarus`, `who`) inside two real `SC2_x64` processes communicating
over WebSocket + Protobuf (`s2clientprotocol`).

Saves a real `.SC2Replay` file and runs `analyze_replay()` from
`tools/analyze_aiarena_replays.py` to produce minute-by-minute forensic telemetry
identical to real AI Arena ladder matches.
"""
import argparse
import json
import os
import random
import signal
import socket
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
sys.path.insert(0, SCRIPT_DIR)

SC2_ROOT = os.environ.get("SC2PATH", "/home/antigravity/sc2_headless/StarCraftII")
SC2_BIN = os.path.join(SC2_ROOT, "Versions", "Base75689", "SC2_x64")
SC2_SUPPORT64 = os.path.join(SC2_ROOT, "Support64")
SC2_CWD = SC2_SUPPORT64 if os.path.isdir(SC2_SUPPORT64) else SC2_ROOT
DOWNLOADED_BOTS_DIR = os.path.join(REPO_ROOT, "downloaded_bots")
REPLAY_OUT_DIR = os.path.join(REPO_ROOT, "replays", "local_real_matches")

OPPONENT_SPEC: Dict[str, Dict[str, str]] = {
    "sludgement2-revived": {
        "race": "Zerg",
        "type": "cpplinux",
        "dir": os.path.join(DOWNLOADED_BOTS_DIR, "sludgement2-revived"),
        "exec": os.path.join(DOWNLOADED_BOTS_DIR, "sludgement2-revived", "sludgement2-revived"),
    },
    "mini-puck": {
        "race": "Protoss",
        "type": "cpplinux",
        "dir": os.path.join(DOWNLOADED_BOTS_DIR, "mini-puck"),
        "exec": os.path.join(DOWNLOADED_BOTS_DIR, "mini-puck", "mini-puck"),
    },
    "onlyfans": {
        "race": "Terran",
        "type": "cpplinux",
        "dir": os.path.join(DOWNLOADED_BOTS_DIR, "onlyfans"),
        "exec": os.path.join(DOWNLOADED_BOTS_DIR, "onlyfans", "onlyfans"),
    },
    "CryptBotRevival": {
        "race": "Protoss",
        "type": "cpplinux",
        "dir": os.path.join(DOWNLOADED_BOTS_DIR, "CryptBotRevival"),
        "exec": os.path.join(DOWNLOADED_BOTS_DIR, "CryptBotRevival", "CryptBotRevival"),
    },
    "oberon": {
        "race": "Terran",
        "type": "cpplinux",
        "dir": os.path.join(DOWNLOADED_BOTS_DIR, "oberon"),
        "exec": os.path.join(DOWNLOADED_BOTS_DIR, "oberon", "oberon"),
    },
    "titania": {
        "race": "Zerg",
        "type": "cpplinux",
        "dir": os.path.join(DOWNLOADED_BOTS_DIR, "titania"),
        "exec": os.path.join(DOWNLOADED_BOTS_DIR, "titania", "titania"),
    },
    "Tartarus": {
        "race": "Zerg",
        "type": "python",
        "dir": os.path.join(DOWNLOADED_BOTS_DIR, "Tartarus"),
        "exec": "run.py",
    },
    "who": {
        "race": "Random",
        "type": "python",
        "dir": os.path.join(DOWNLOADED_BOTS_DIR, "who"),
        "exec": "run.py",
    },
}


def pick_port_block() -> Tuple[int, int, int]:
    base = random.randint(18000, 26000)
    return base, base + 1, base + 10


def wait_for_port(host: str, port: int, timeout: float = 25.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.2)
    return False


def kill_proc_tree(p: Optional[subprocess.Popen]) -> None:
    if p is None:
        return
    try:
        if p.poll() is None:
            os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            try:
                p.wait(timeout=3.0)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except Exception:
        pass


def run_match(
    our_bot: str = "Mothman-Z",
    opponent: str = "sludgement2-revived",
    map_name: str = "AcropolisLE",
    max_loops: int = 13440,
    step_size: int = 4,
    timeout_sec: int = 360,
) -> Dict[str, Any]:
    if opponent not in OPPONENT_SPEC:
        raise ValueError(f"Unknown opponent {opponent}; choices: {list(OPPONENT_SPEC)}")
    opp_info = OPPONENT_SPEC[opponent]
    opp_race = opp_info["race"]

    os.makedirs(REPLAY_OUT_DIR, exist_ok=True)
    ts = int(time.time())
    replay_path = os.path.join(
        REPLAY_OUT_DIR, f"{ts}_{our_bot}_vs_{opponent}_{map_name}.SC2Replay"
    )
    our_stdout_path = os.path.join(
        REPLAY_OUT_DIR, f"{ts}_{our_bot}_vs_{opponent}_our_stdout.log"
    )
    our_stderr_path = os.path.join(
        REPLAY_OUT_DIR, f"{ts}_{our_bot}_vs_{opponent}_our_stderr.log"
    )
    opp_stdout_path = os.path.join(
        REPLAY_OUT_DIR, f"{ts}_{our_bot}_vs_{opponent}_opp_stdout.log"
    )
    opp_stderr_path = os.path.join(
        REPLAY_OUT_DIR, f"{ts}_{our_bot}_vs_{opponent}_opp_stderr.log"
    )

    game_port_1, game_port_2, start_port = pick_port_block()

    print(
        f"[REAL-SC2-MATCH] Starting {our_bot} vs {opponent} ({opp_race}) on {map_name} "
        f"(P1={game_port_1}, P2={game_port_2}, StartPort={start_port}, max_loops={max_loops})"
    )

    sc2_p1: Optional[subprocess.Popen] = None
    sc2_p2: Optional[subprocess.Popen] = None
    bot_p1: Optional[subprocess.Popen] = None
    bot_p2: Optional[subprocess.Popen] = None

    t0 = time.time()
    temp_dir_1 = os.path.join(REPLAY_OUT_DIR, f"tmp_sc2_p1_{ts}")
    temp_dir_2 = os.path.join(REPLAY_OUT_DIR, f"tmp_sc2_p2_{ts}")
    os.makedirs(temp_dir_1, exist_ok=True)
    os.makedirs(temp_dir_2, exist_ok=True)
    try:
        sc2_p1 = subprocess.Popen(
            [
                SC2_BIN,
                "-listen",
                "127.0.0.1",
                "-port",
                str(game_port_1),
                "-displayMode",
                "0",
                "-dataDir",
                SC2_ROOT,
                "-tempDir",
                temp_dir_1,
            ],
            cwd=SC2_CWD,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            preexec_fn=os.setsid,
        )
        sc2_p2 = subprocess.Popen(
            [
                SC2_BIN,
                "-listen",
                "127.0.0.1",
                "-port",
                str(game_port_2),
                "-displayMode",
                "0",
                "-dataDir",
                SC2_ROOT,
                "-tempDir",
                temp_dir_2,
            ],
            cwd=SC2_CWD,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            preexec_fn=os.setsid,
        )

        if not wait_for_port("127.0.0.1", game_port_1, timeout=25.0):
            raise RuntimeError(f"SC2_x64 #1 failed to listen on port {game_port_1}")
        if not wait_for_port("127.0.0.1", game_port_2, timeout=25.0):
            raise RuntimeError(f"SC2_x64 #2 failed to listen on port {game_port_2}")

        our_out_f = open(our_stdout_path, "w")
        our_err_f = open(our_stderr_path, "w")
        opp_out_f = open(opp_stdout_path, "w")
        opp_err_f = open(opp_stderr_path, "w")

        # Launch Player 1 (our pure-Racket bot, which sends RequestCreateGame on P1 then RequestJoinGame)
        racket_candidates = [
            "/home/antigravity/toolchains/racket/bin/racket",
            os.path.join(REPO_ROOT, "racket-runtime", "bin", "racket"),
        ]
        racket_bin = next((p for p in racket_candidates if os.path.exists(p)), "racket")
        our_cmd = [
            racket_bin,
            os.path.join(REPO_ROOT, "sim", "racket-sc2-ladder-main.rkt"),
            "--BotName",
            our_bot,
            "--GamePort",
            str(game_port_1),
            "--StartPort",
            str(start_port),
            "--LadderServer",
            "127.0.0.1",
            "--OpponentId",
            opponent,
            "--Host2POpponentRace",
            opp_race,
            "--Map",
            map_name,
            "--SaveReplay",
            replay_path,
            "--max-loops",
            str(max_loops),
            "--step-size",
            str(step_size),
        ]
        bot_p1 = subprocess.Popen(
            our_cmd,
            cwd=REPO_ROOT,
            stdout=our_out_f,
            stderr=our_err_f,
            preexec_fn=os.setsid,
        )

        # Wait for Player 1 to complete RequestCreateGame before Player 2 sends RequestJoinGame
        cg_deadline = time.time() + 25.0
        while time.time() < cg_deadline:
            if bot_p1.poll() is not None:
                break
            if os.path.exists(our_stderr_path):
                with open(our_stderr_path, "r") as ef:
                    if "[HOST-2P] RequestCreateGame completed" in ef.read():
                        break
            time.sleep(0.2)
        time.sleep(0.2)

        if opp_info["type"] == "cpplinux":
            opp_cmd = [
                opp_info["exec"],
                "--GamePort",
                str(game_port_2),
                "--StartPort",
                str(start_port),
                "--LadderServer",
                "127.0.0.1",
                "--OpponentId",
                our_bot,
            ]
        else:
            bundled_py = os.path.join(
                DOWNLOADED_BOTS_DIR, "sludgement2-revived", "python", "bin", "python3.8"
            )
            py_bin = bundled_py if os.path.exists(bundled_py) else sys.executable
            opp_cmd = [
                py_bin,
                opp_info["exec"],
                "--GamePort",
                str(game_port_2),
                "--StartPort",
                str(start_port),
                "--LadderServer",
                "127.0.0.1",
                "--OpponentId",
                our_bot,
            ]

        bot_p2 = subprocess.Popen(
            opp_cmd,
            cwd=opp_info["dir"],
            stdout=opp_out_f,
            stderr=opp_err_f,
            preexec_fn=os.setsid,
        )

        # Wait for Player 1 (our bot) to finish the match and save the replay
        deadline = time.time() + timeout_sec
        while time.time() < deadline:
            if bot_p1.poll() is not None:
                break
            time.sleep(0.5)
        else:
            print(f"[WARN] Match exceeded timeout ({timeout_sec}s); terminating.")

        our_out_f.close()
        our_err_f.close()
        opp_out_f.close()
        opp_err_f.close()

    finally:
        kill_proc_tree(bot_p1)
        kill_proc_tree(bot_p2)
        kill_proc_tree(sc2_p1)
        kill_proc_tree(sc2_p2)
        import shutil
        shutil.rmtree(temp_dir_1, ignore_errors=True)
        shutil.rmtree(temp_dir_2, ignore_errors=True)

    elapsed = round(time.time() - t0, 2)
    our_stdout = open(our_stdout_path).read().strip() if os.path.exists(our_stdout_path) else ""
    our_stderr = open(our_stderr_path).read().strip() if os.path.exists(our_stderr_path) else ""
    opp_stderr = open(opp_stderr_path).read().strip() if os.path.exists(opp_stderr_path) else ""

    bot_summary: Dict[str, Any] = {}
    for line in reversed(our_stdout.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                bot_summary = json.loads(line)
                break
            except Exception:
                pass

    print(f"[REAL-SC2-MATCH] Finished in {elapsed}s | Summary: {json.dumps(bot_summary)}")
    if our_stderr:
        print(f"[OUR STDERR]\n{our_stderr[:1000]}")
    if opp_stderr:
        print(f"[OPP STDERR]\n{opp_stderr[:1000]}")

    replay_analysis: Dict[str, Any] = {}
    if os.path.exists(replay_path) and os.path.getsize(replay_path) > 0:
        try:
            from analyze_aiarena_replays import analyze_replay

            replay_analysis = analyze_replay(replay_path)
        except Exception as e:
            print(f"[WARN] Could not parse replay {replay_path}: {e}")

    return {
        "elapsed_sec": elapsed,
        "bot_summary": bot_summary,
        "replay_path": replay_path if os.path.exists(replay_path) else None,
        "replay_analysis": replay_analysis,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bot", default="Mothman-Z", help="Our bot variant (Mothman-Z, Mothman-T, Mothman-P, Mothman-X)")
    parser.add_argument("--opponent", default="sludgement2-revived", help="Downloaded opponent bot name")
    parser.add_argument("--map", default="AcropolisLE", help="Map name in SC2 Maps directory")
    parser.add_argument("--max-loops", type=int, default=13440, help="Max game loops (13440 = 10 min)")
    parser.add_argument("--step-size", type=int, default=4, help="Step size per RequestStep")
    parser.add_argument("--timeout", type=int, default=360, help="Wall-clock timeout in seconds")
    args = parser.parse_args()

    run_match(
        our_bot=args.bot,
        opponent=args.opponent,
        map_name=args.map,
        max_loops=args.max_loops,
        step_size=args.step_size,
        timeout_sec=args.timeout,
    )


if __name__ == "__main__":
    main()
