#!/usr/bin/env python3
"""
In-Container 2-Player StarCraft II WebSocket Match Controller (`tools/sc2-match-proxy.py`)

Runs INSIDE `docker.io/aiarena/arenaclient-combined:v0.8.0` to orchestrate one isolated
2-player SC2 4.10 match with dedicated per-player proxy ports:
  - Player 1 connects to `ws://127.0.0.1:8081/sc2api` -> SC2_x64 #1 (`127.0.0.1:5001`)
  - Player 2 connects to `ws://127.0.0.1:8082/sc2api` -> SC2_x64 #2 (`127.0.0.1:5002`)

Why dedicated per-player ports (instead of v0.8.0's shared-port `/proc/net/tcp` lookup):
  - Eliminates the v0.8.0 `get_ipv4_port_for_pid` bug where multi-socket bots (e.g., Rust
    `faerie` bots like `mini-puck`, `oberon`, `titania`, `puck` that bind a local port
    before connecting) hang during game join.
  - Supports ALL AI Arena runtimes (`cpplinux`, `python`, `dotnetcore`, `java`, `nodejs`,
    and shell-wrapped source-mode runners) with ~1.5s match startup instead of ~8s.
  - Preserves exact AI Arena ladder semantics: `game_info` opponent race masking,
    `DISABLE_DEBUG`, `MAX_GAME_TIME` tie enforcement, step-time tracking, crash/timeout
    classification, `.SC2Replay` saving, and `results.json` emission.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import aiohttp
from aiohttp import web
from s2clientprotocol import common_pb2, sc2api_pb2


SC2_BASE_DIR = Path("/root/StarCraftII")
SC2_BIN = SC2_BASE_DIR / "Versions" / "Base75689" / "SC2_x64"
SC2_CWD = SC2_BASE_DIR / "Support64"
MAX_WS_MSG_SIZE = 128 * 1024 * 1024  # 128 MiB

SC2_PORT_1 = 5001
SC2_PORT_2 = 5002
PROXY_PORT_1 = 8081
PROXY_PORT_2 = 8082
MP_SHARED_PORT = 9100
MP_SERVER_GAME_PORT = 9101
MP_SERVER_BASE_PORT = 9102
MP_CLIENT_GAME_PORT = 9103
MP_CLIENT_BASE_PORT = 9104

RACE_TO_PROTO = {
    "T": common_pb2.Terran,
    "TERRAN": common_pb2.Terran,
    "Z": common_pb2.Zerg,
    "ZERG": common_pb2.Zerg,
    "P": common_pb2.Protoss,
    "PROTOSS": common_pb2.Protoss,
    "R": common_pb2.Random,
    "RANDOM": common_pb2.Random,
}


@dataclass
class BotCfg:
    player_num: int  # 1 or 2
    name: str
    race: str  # P, T, Z, R
    bot_type: str
    bot_dir: Path
    log_path: Path
    proxy_port: int
    sc2_port: int
    opponent_id: str


@dataclass
class PlayerOutcome:
    player_num: int
    result: str | None = None  # Victory, Defeat, Tie, Crash, Timeout, SC2Crash, InitError
    game_loops: int = 0
    step_times: list[float] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    connected: bool = False
    joined: bool = False
    crashed_before_end: bool = False
    timed_out_before_end: bool = False
    error_detail: str = ""

    @property
    def avg_step_time(self) -> float | None:
        if not self.step_times:
            return None
        return sum(self.step_times) / len(self.step_times)


def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S", time.gmtime())
    print(f"[MATCH-PROXY {ts}] {msg}", flush=True)


def build_bot_command(cfg: BotCfg, start_port: int = 8090) -> list[str]:
    bt = cfg.bot_type.lower()
    if bt == "python":
        cmd = ["python", "run.py"]
    elif bt == "cpplinux":
        exe = cfg.bot_dir / cfg.name
        if exe.is_file():
            exe.chmod(exe.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        cmd = [f"./{cfg.name}"]
    elif bt == "dotnetcore":
        cmd = ["dotnet", f"{cfg.name}.dll"]
    elif bt == "java":
        cmd = ["java", "-jar", f"{cfg.name}.jar"]
    elif bt == "nodejs":
        cmd = ["node", f"{cfg.name}.js"]
    elif bt == "cppwin32":
        cmd = ["wine", f"{cfg.name}.exe"]
    else:
        raise ValueError(f"Unsupported bot_type: {cfg.bot_type}")

    cmd.extend([
        "--GamePort", str(cfg.proxy_port),
        "--LadderServer", "127.0.0.1",
        "--StartPort", str(start_port),
        "--OpponentId", cfg.opponent_id,
    ])
    return cmd


async def wait_and_connect_sc2(
    session: aiohttp.ClientSession, port: int, timeout_sec: float = 35.0
) -> aiohttp.ClientWebSocketResponse:
    url = f"ws://127.0.0.1:{port}/sc2api"
    deadline = time.monotonic() + timeout_sec
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            ws = await session.ws_connect(
                url,
                max_msg_size=MAX_WS_MSG_SIZE,
                heartbeat=None,
                autoping=True,
                timeout=aiohttp.ClientWSTimeout(ws_close=10.0),
            )
            ping_req = sc2api_pb2.Request(ping=sc2api_pb2.RequestPing())
            await ws.send_bytes(ping_req.SerializeToString())
            msg = await asyncio.wait_for(ws.receive(), timeout=10.0)
            if msg.type == aiohttp.WSMsgType.BINARY:
                return ws
            await ws.close()
        except Exception as exc:
            last_err = exc
        await asyncio.sleep(0.25)
    raise RuntimeError(f"SC2 on port {port} failed to become ready within {timeout_sec}s: {last_err}")


async def sc2_rpc(
    sc2_ws: aiohttp.ClientWebSocketResponse,
    req: sc2api_pb2.Request,
    timeout_sec: float = 60.0,
) -> sc2api_pb2.Response:
    await sc2_ws.send_bytes(req.SerializeToString())
    msg = await asyncio.wait_for(sc2_ws.receive(), timeout=timeout_sec)
    if msg.type != aiohttp.WSMsgType.BINARY:
        raise RuntimeError(f"Unexpected SC2 WS message type={msg.type} data={msg.data!r}")
    resp = sc2api_pb2.Response()
    resp.ParseFromString(msg.data)
    return resp


def find_map_file(map_name: str) -> str:
    clean = map_name[:-7] if map_name.lower().endswith(".sc2map") else map_name
    maps_dir = SC2_BASE_DIR / "Maps"
    direct = maps_dir / f"{clean}.SC2Map"
    if direct.is_file():
        return f"{clean}.SC2Map"
    for p in maps_dir.rglob("*.SC2Map"):
        if p.stem.lower() == clean.lower():
            return str(p.relative_to(maps_dir))
    raise FileNotFoundError(f"Map {map_name!r} not found under {maps_dir}")


def rewrite_join_game(
    req: sc2api_pb2.Request, cfg: BotCfg, validate_race: bool
) -> sc2api_pb2.Request:
    out = sc2api_pb2.Request()
    out.CopyFrom(req)
    jg = out.join_game
    if validate_race and cfg.race.upper() in RACE_TO_PROTO:
        jg.race = RACE_TO_PROTO[cfg.race.upper()]
    jg.player_name = cfg.name
    jg.shared_port = MP_SHARED_PORT
    jg.server_ports.game_port = MP_SERVER_GAME_PORT
    jg.server_ports.base_port = MP_SERVER_BASE_PORT
    del jg.client_ports[:]
    cp = jg.client_ports.add()
    cp.game_port = MP_CLIENT_GAME_PORT
    cp.base_port = MP_CLIENT_BASE_PORT
    return out


def extract_chat_tags(req: sc2api_pb2.Request, tags_out: list[str]) -> None:
    if not req.HasField("action"):
        return
    for act in req.action.actions:
        if act.HasField("action_chat"):
            msg = act.action_chat.message.strip()
            if msg.lower().startswith("tag:"):
                tag = msg[4:].strip()
                if tag and tag not in tags_out:
                    tags_out.append(tag)


def combine_match_result(p1: PlayerOutcome, p2: PlayerOutcome, forced_tie: bool = False) -> str:
    if forced_tie:
        return "Tie"
    if p1.crashed_before_end and not p2.crashed_before_end:
        return "Player1Crash"
    if p2.crashed_before_end and not p1.crashed_before_end:
        return "Player2Crash"
    if p1.timed_out_before_end and not p2.timed_out_before_end:
        return "Player1TimeOut"
    if p2.timed_out_before_end and not p1.timed_out_before_end:
        return "Player2TimeOut"
    r1, r2 = p1.result, p2.result
    if r1 == "Victory" or r2 == "Defeat":
        return "Player1Win"
    if r2 == "Victory" or r1 == "Defeat":
        return "Player2Win"
    if r1 == "Tie" or r2 == "Tie":
        return "Tie"
    if r1 == "Crash":
        return "Player1Crash"
    if r2 == "Crash":
        return "Player2Crash"
    if r1 == "Timeout":
        return "Player1TimeOut"
    if r2 == "Timeout":
        return "Player2TimeOut"
    if r1 == "InitError" or r2 == "InitError":
        return "InitializationError"
    return "Error"


def terminate_process(proc: subprocess.Popen[Any] | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        proc.terminate()
        try:
            proc.wait(timeout=3.0)
            return
        except subprocess.TimeoutExpired:
            pass
        proc.kill()
        proc.wait(timeout=3.0)
    except Exception:
        pass


async def run_match(args: argparse.Namespace) -> int:
    map_rel = find_map_file(args.map)
    log_root = Path(args.log_root)
    log_root.mkdir(parents=True, exist_ok=True)
    replay_path = Path(args.replay_path)
    replay_path.parent.mkdir(parents=True, exist_ok=True)
    results_path = Path(args.results_path)
    results_path.parent.mkdir(parents=True, exist_ok=True)

    bots_root = Path(args.bots_root)
    cfg1 = BotCfg(
        player_num=1,
        name=args.bot1_name,
        race=args.bot1_race,
        bot_type=args.bot1_type,
        bot_dir=bots_root / args.bot1_name,
        log_path=log_root / args.bot1_name / "stderr.log",
        proxy_port=PROXY_PORT_1,
        sc2_port=SC2_PORT_1,
        opponent_id=args.bot2_id,
    )
    cfg2 = BotCfg(
        player_num=2,
        name=args.bot2_name,
        race=args.bot2_race,
        bot_type=args.bot2_type,
        bot_dir=bots_root / args.bot2_name,
        log_path=log_root / args.bot2_name / "stderr.log",
        proxy_port=PROXY_PORT_2,
        sc2_port=SC2_PORT_2,
        opponent_id=args.bot1_id,
    )
    for c in (cfg1, cfg2):
        c.log_path.parent.mkdir(parents=True, exist_ok=True)
        (c.bot_dir / "data").mkdir(parents=True, exist_ok=True)

    sc2_tmp1 = tempfile.mkdtemp(prefix="sc2_p1_")
    sc2_tmp2 = tempfile.mkdtemp(prefix="sc2_p2_")
    sc2_proc1: subprocess.Popen[Any] | None = None
    sc2_proc2: subprocess.Popen[Any] | None = None
    bot_proc1: subprocess.Popen[Any] | None = None
    bot_proc2: subprocess.Popen[Any] | None = None
    bot_log_f1 = None
    bot_log_f2 = None
    runners: list[web.AppRunner] = []

    outcomes = {1: PlayerOutcome(1), 2: PlayerOutcome(2)}
    replay_saved = False
    forced_tie_triggered = False
    replay_lock = asyncio.Lock()
    match_done_event = asyncio.Event()
    bot_connected_events = {1: asyncio.Event(), 2: asyncio.Event()}
    player_finished_events = {1: asyncio.Event(), 2: asyncio.Event()}

    live_stats: dict[int, dict[str, int]] = {1: {}, 2: {}}
    live_status_path = log_root / "live_match_status.json"
    last_live_write_loop = -999

    def write_live_status(status: str = "running", force: bool = False) -> None:
        nonlocal last_live_write_loop
        gl = max(outcomes[1].game_loops, outcomes[2].game_loops)
        if not force and (gl - last_live_write_loop) < 112:
            return
        last_live_write_loop = gl
        s1 = live_stats[1]
        s2 = live_stats[2]
        secs = int(round(gl / 22.4))
        payload = {
            "match_id": replay_path.stem.split("_")[0] if replay_path.stem else "",
            "mode": "full",
            "map": args.map,
            "our_bot": cfg1.name,
            "our_race": cfg1.race,
            "opp_bot": cfg2.name,
            "opp_race": cfg2.race,
            "status": status,
            "game_loop": gl,
            "game_time_str": f"{secs // 60:02d}:{secs % 60:02d}",
            "our_supply": s1.get("food_used"),
            "our_supply_cap": s1.get("food_cap"),
            "opp_supply": s2.get("food_used"),
            "our_workers": s1.get("food_workers"),
            "opp_workers": s2.get("food_workers"),
            "our_army_supply": s1.get("food_army"),
            "opp_army_supply": s2.get("food_army"),
            "updated_at_epoch_ms": int(time.time() * 1000),
        }
        try:
            tmp = live_status_path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(payload), encoding="utf-8")
            os.replace(tmp, live_status_path)
        except Exception:
            pass

    async def save_replay_once(sc2_ws: aiohttp.ClientWebSocketResponse) -> None:
        nonlocal replay_saved
        async with replay_lock:
            if replay_saved:
                return
            try:
                resp = await sc2_rpc(
                    sc2_ws,
                    sc2api_pb2.Request(save_replay=sc2api_pb2.RequestSaveReplay()),
                    timeout_sec=20.0,
                )
                if resp.HasField("save_replay") and resp.save_replay.data:
                    replay_path.write_bytes(resp.save_replay.data)
                    replay_saved = True
                    log(f"Replay saved -> {replay_path} ({len(resp.save_replay.data)} bytes)")
            except Exception as exc:
                log(f"SaveReplay attempt failed: {exc}")

    t0 = time.monotonic()
    try:
        log(f"Launching SC2_x64 x2 for {cfg1.name}({cfg1.race},{cfg1.bot_type}) vs {cfg2.name}({cfg2.race},{cfg2.bot_type}) on {map_rel}")
        sc2_cwd = str(SC2_CWD if SC2_CWD.is_dir() else SC2_BASE_DIR)
        sc2_proc1 = subprocess.Popen(
            [str(SC2_BIN), "-listen", "127.0.0.1", "-port", str(SC2_PORT_1),
             "-dataDir", str(SC2_BASE_DIR), "-displayMode", "0", "-tempDir", sc2_tmp1],
            cwd=sc2_cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        sc2_proc2 = subprocess.Popen(
            [str(SC2_BIN), "-listen", "127.0.0.1", "-port", str(SC2_PORT_2),
             "-dataDir", str(SC2_BASE_DIR), "-displayMode", "0", "-tempDir", sc2_tmp2],
            cwd=sc2_cwd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

        async with aiohttp.ClientSession() as session:
            sc2_ws1, sc2_ws2 = await asyncio.gather(
                wait_and_connect_sc2(session, SC2_PORT_1),
                wait_and_connect_sc2(session, SC2_PORT_2),
            )
            sc2_sockets = {1: sc2_ws1, 2: sc2_ws2}
            log("Both SC2_x64 instances ready; sending RequestCreateGame...")

            cg = sc2api_pb2.RequestCreateGame(
                local_map=sc2api_pb2.LocalMap(map_path=map_rel),
                realtime=args.realtime,
                disable_fog=False,
            )
            p1_setup = cg.player_setup.add()
            p1_setup.type = sc2api_pb2.Participant
            p2_setup = cg.player_setup.add()
            p2_setup.type = sc2api_pb2.Participant

            cg_resp = await sc2_rpc(sc2_ws1, sc2api_pb2.Request(create_game=cg), timeout_sec=30.0)
            if cg_resp.HasField("create_game") and cg_resp.create_game.HasField("error"):
                raise RuntimeError(
                    f"RequestCreateGame failed: {cg_resp.create_game.error} ({cg_resp.create_game.error_details})"
                )
            log(f"Game created on {map_rel}")

            def make_ws_handler(cfg: BotCfg, other_cfg: BotCfg):
                async def ws_handler(http_req: web.Request) -> web.WebSocketResponse:
                    nonlocal forced_tie_triggered
                    outcome = outcomes[cfg.player_num]
                    sc2_ws = sc2_sockets[cfg.player_num]
                    bot_ws = web.WebSocketResponse(
                        max_msg_size=MAX_WS_MSG_SIZE,
                        heartbeat=None,
                        autoping=True,
                    )
                    await bot_ws.prepare(http_req)
                    outcome.connected = True
                    bot_connected_events[cfg.player_num].set()
                    log(f"P{cfg.player_num} ({cfg.name}) connected on :{cfg.proxy_port}")

                    player_id: int | None = None
                    last_resp_sent_ts: float | None = None
                    req_timeout = args.bot_timeout_sec

                    try:
                        # Phase 1: Wait for RequestJoinGame (allowing Ping pre-join)
                        while True:
                            msg = await asyncio.wait_for(bot_ws.receive(), timeout=args.join_timeout_sec)
                            if msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSING, aiohttp.WSMsgType.CLOSED):
                                outcome.result = "Crash"
                                outcome.error_detail = "Closed before JoinGame"
                                return bot_ws
                            if msg.type != aiohttp.WSMsgType.BINARY:
                                outcome.result = "Crash"
                                outcome.error_detail = f"Non-binary WS msg before JoinGame: {msg.type}"
                                return bot_ws

                            req = sc2api_pb2.Request()
                            req.ParseFromString(msg.data)
                            if req.HasField("quit"):
                                outcome.result = "Defeat"
                                return bot_ws
                            if req.HasField("ping"):
                                resp = await sc2_rpc(sc2_ws, req, timeout_sec=30.0)
                                await bot_ws.send_bytes(resp.SerializeToString())
                                continue
                            if req.HasField("join_game"):
                                jg_req = rewrite_join_game(req, cfg, args.validate_race)
                                resp = await sc2_rpc(sc2_ws, jg_req, timeout_sec=60.0)
                                await bot_ws.send_bytes(resp.SerializeToString())
                                if resp.HasField("join_game") and resp.join_game.HasField("error"):
                                    outcome.result = "InitError"
                                    outcome.error_detail = f"JoinGame error: {resp.join_game.error_details}"
                                    return bot_ws
                                player_id = resp.join_game.player_id
                                outcome.joined = True
                                log(f"P{cfg.player_num} ({cfg.name}) joined game as player_id={player_id}")
                                break
                            # Forward other harmless pre-join queries (e.g., data/available_maps)
                            resp = await sc2_rpc(sc2_ws, req, timeout_sec=30.0)
                            await bot_ws.send_bytes(resp.SerializeToString())

                        # Phase 2: Main game proxy loop
                        while True:
                            msg = await asyncio.wait_for(bot_ws.receive(), timeout=req_timeout)
                            if msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.CLOSING, aiohttp.WSMsgType.CLOSED):
                                if outcome.result is None:
                                    other_res = outcomes[other_cfg.player_num].result
                                    if other_res in ("Victory", "Defeat", "Tie"):
                                        outcome.result = (
                                            "Defeat" if other_res == "Victory"
                                            else "Victory" if other_res == "Defeat"
                                            else "Tie"
                                        )
                                    else:
                                        outcome.crashed_before_end = True
                                        outcome.result = "Crash"
                                        outcome.error_detail = "Bot WS closed mid-game"
                                        await save_replay_once(sc2_ws)
                                        try:
                                            await sc2_rpc(sc2_ws, sc2api_pb2.Request(leave_game=sc2api_pb2.RequestLeaveGame()), timeout_sec=5.0)
                                        except Exception:
                                            pass
                                return bot_ws
                            if msg.type != aiohttp.WSMsgType.BINARY:
                                await save_replay_once(sc2_ws)
                                outcome.result = "Crash"
                                outcome.error_detail = f"Unexpected WS msg type {msg.type}"
                                return bot_ws

                            now = time.monotonic()
                            req = sc2api_pb2.Request()
                            req.ParseFromString(msg.data)

                            if last_resp_sent_ts is not None and (req.HasField("step") or req.HasField("action")):
                                outcome.step_times.append(now - last_resp_sent_ts)
                                last_resp_sent_ts = None

                            if args.disable_debug and req.HasField("debug"):
                                dresp = sc2api_pb2.Response(
                                    id=req.id,
                                    status=sc2api_pb2.in_game,
                                    debug=sc2api_pb2.ResponseDebug(),
                                )
                                await bot_ws.send_bytes(dresp.SerializeToString())
                                continue

                            extract_chat_tags(req, outcome.tags)

                            if req.HasField("leave_game") or req.HasField("quit"):
                                await save_replay_once(sc2_ws)
                                resp = await sc2_rpc(sc2_ws, req, timeout_sec=20.0)
                                await bot_ws.send_bytes(resp.SerializeToString())
                                if outcome.result is None:
                                    outcome.result = "Defeat"
                                return bot_ws

                            resp = await sc2_rpc(sc2_ws, req, timeout_sec=60.0)

                            if resp.HasField("game_info"):
                                for pi in resp.game_info.player_info:
                                    if player_id is not None and pi.player_id != player_id:
                                        pi.player_name = other_cfg.name
                                        pi.race_actual = pi.race_requested
                                    else:
                                        pi.player_name = cfg.name

                            await bot_ws.send_bytes(resp.SerializeToString())

                            if resp.HasField("observation"):
                                last_resp_sent_ts = time.monotonic()
                                obs = resp.observation
                                gl = obs.observation.game_loop
                                if gl > outcome.game_loops:
                                    outcome.game_loops = gl
                                pc = obs.observation.player_common
                                live_stats[cfg.player_num] = {
                                    "food_used": int(pc.food_used),
                                    "food_cap": int(pc.food_cap),
                                    "food_workers": int(pc.food_workers),
                                    "food_army": int(pc.food_army),
                                    "minerals": int(pc.minerals),
                                    "vespene": int(pc.vespene),
                                }
                                write_live_status("running")

                                if obs.player_result:
                                    res_enum = None
                                    for pr in obs.player_result:
                                        if pr.player_id == player_id:
                                            res_enum = pr.result
                                            break
                                    await save_replay_once(sc2_ws)
                                    if res_enum == sc2api_pb2.Victory:
                                        outcome.result = "Victory"
                                    elif res_enum == sc2api_pb2.Defeat:
                                        outcome.result = "Defeat"
                                    elif res_enum == sc2api_pb2.Tie:
                                        outcome.result = "Tie"
                                    else:
                                        outcome.result = "Tie"
                                    if cfg.player_num == 1:
                                        st = "win" if outcome.result == "Victory" else ("loss" if outcome.result == "Defeat" else "tie")
                                        write_live_status(st, force=True)
                                    return bot_ws

                                if args.max_game_time > 0 and outcome.game_loops >= args.max_game_time:
                                    forced_tie_triggered = True
                                    log(f"MAX_GAME_TIME ({args.max_game_time}) reached at loop {outcome.game_loops}")
                                    await save_replay_once(sc2_ws)
                                    outcome.result = "Tie"
                                    return bot_ws

                                if args.wall_timeout_sec > 0 and (time.monotonic() - t0) >= args.wall_timeout_sec:
                                    forced_tie_triggered = True
                                    log(f"Graceful wall timeout ({args.wall_timeout_sec}s) reached at loop {outcome.game_loops}")
                                    await save_replay_once(sc2_ws)
                                    outcome.result = "Tie"
                                    outcome.error_detail = f"WallTimeout({args.wall_timeout_sec}s)"
                                    return bot_ws

                    except asyncio.TimeoutError:
                        log(f"P{cfg.player_num} ({cfg.name}) timed out (joined={outcome.joined}, loop={outcome.game_loops})")
                        if outcome.result is None and outcomes[other_cfg.player_num].result is None:
                            outcome.timed_out_before_end = True
                            outcome.result = "Timeout" if outcome.joined else "InitError"
                        await save_replay_once(sc2_ws)
                        try:
                            await sc2_rpc(sc2_ws, sc2api_pb2.Request(leave_game=sc2api_pb2.RequestLeaveGame()), timeout_sec=5.0)
                        except Exception:
                            pass
                    except Exception as exc:
                        log(f"P{cfg.player_num} ({cfg.name}) proxy exception: {exc!r}")
                        if outcome.result is None and outcomes[other_cfg.player_num].result is None:
                            outcome.crashed_before_end = outcome.joined
                            outcome.result = "Crash" if outcome.joined else "InitError"
                        await save_replay_once(sc2_ws)
                        outcome.error_detail = repr(exc)
                    finally:
                        player_finished_events[cfg.player_num].set()
                        try:
                            await bot_ws.close()
                        except Exception:
                            pass
                    return bot_ws

                return ws_handler

            for cfg, other in ((cfg1, cfg2), (cfg2, cfg1)):
                app = web.Application()
                handler = make_ws_handler(cfg, other)
                app.router.add_get("/sc2api", handler)
                app.router.add_get("/", handler)
                runner = web.AppRunner(app, access_log=None)
                await runner.setup()
                site = web.TCPSite(runner, "127.0.0.1", cfg.proxy_port)
                await site.start()
                runners.append(runner)

            # Spawn both bots
            bot_log_f1 = cfg1.log_path.open("wb")
            bot_log_f2 = cfg2.log_path.open("wb")
            cmd1 = build_bot_command(cfg1)
            cmd2 = build_bot_command(cfg2)
            log(f"Spawning P1: {' '.join(cmd1)} (cwd={cfg1.bot_dir})")
            bot_proc1 = subprocess.Popen(cmd1, cwd=str(cfg1.bot_dir), stdout=bot_log_f1, stderr=subprocess.STDOUT)
            log(f"Spawning P2: {' '.join(cmd2)} (cwd={cfg2.bot_dir})")
            bot_proc2 = subprocess.Popen(cmd2, cwd=str(cfg2.bot_dir), stdout=bot_log_f2, stderr=subprocess.STDOUT)

            async def watch_bot_process(pnum: int, proc: subprocess.Popen[Any]) -> None:
                # Poll process exit without busy spinning so early startup crashes fail fast!
                while not player_finished_events[pnum].is_set():
                    rc = proc.poll()
                    if rc is not None:
                        await asyncio.sleep(0.5)
                        if not bot_connected_events[pnum].is_set() and outcomes[pnum].result is None:
                            outcomes[pnum].result = "Crash"
                            outcomes[pnum].error_detail = f"Exited before WS connect (rc={rc})"
                            log(f"P{pnum} exited before WS connect (rc={rc})")
                            player_finished_events[pnum].set()
                            return
                        if not player_finished_events[pnum].is_set():
                            # Give WS close a brief grace period to report
                            await asyncio.sleep(1.5)
                            if outcomes[pnum].result is None:
                                outcomes[pnum].result = "Crash"
                                outcomes[pnum].error_detail = f"Exited mid-match (rc={rc})"
                            player_finished_events[pnum].set()
                            return
                    await asyncio.sleep(0.25)

            async def watch_connect_timeout(pnum: int) -> None:
                try:
                    await asyncio.wait_for(bot_connected_events[pnum].wait(), timeout=args.join_timeout_sec)
                except asyncio.TimeoutError:
                    if outcomes[pnum].result is None:
                        outcomes[pnum].result = "Timeout"
                        outcomes[pnum].error_detail = f"Did not connect within {args.join_timeout_sec}s"
                        log(f"P{pnum} did not connect within {args.join_timeout_sec}s")
                        player_finished_events[pnum].set()

            watchers = [
                asyncio.create_task(watch_bot_process(1, bot_proc1)),
                asyncio.create_task(watch_bot_process(2, bot_proc2)),
                asyncio.create_task(watch_connect_timeout(1)),
                asyncio.create_task(watch_connect_timeout(2)),
            ]

            # Wait until EITHER both players finish OR one player hits a terminal result + short grace for the other
            wait1 = asyncio.create_task(player_finished_events[1].wait())
            wait2 = asyncio.create_task(player_finished_events[2].wait())
            done, pending = await asyncio.wait({wait1, wait2}, return_when=asyncio.FIRST_COMPLETED)
            if pending:
                # Allow the other player up to 6s to receive its final observation / flush JSON telemetry
                await asyncio.wait(pending, timeout=6.0)
                for p in pending:
                    if not p.done():
                        p.cancel()

            for w in watchers:
                if not w.done():
                    w.cancel()

            # Ensure replay saved from whichever SC2 instance is still responsive
            if not replay_saved:
                for pnum in (1, 2):
                    if not replay_saved:
                        await save_replay_once(sc2_sockets[pnum])

            # Give bots up to 2s to flush stdout/stderr telemetry before terminating
            for proc in (bot_proc1, bot_proc2):
                if proc is not None and proc.poll() is None:
                    try:
                        proc.wait(timeout=2.0)
                    except subprocess.TimeoutExpired:
                        pass

            for ws in (sc2_ws1, sc2_ws2):
                try:
                    await ws.close()
                except Exception:
                    pass

    finally:
        for r in runners:
            try:
                await r.cleanup()
            except Exception:
                pass
        terminate_process(bot_proc1)
        terminate_process(bot_proc2)
        terminate_process(sc2_proc1)
        terminate_process(sc2_proc2)
        for f in (bot_log_f1, bot_log_f2):
            if f is not None:
                try:
                    f.flush()
                    f.close()
                except Exception:
                    pass
        shutil.rmtree(sc2_tmp1, ignore_errors=True)
        shutil.rmtree(sc2_tmp2, ignore_errors=True)

    p1, p2 = outcomes[1], outcomes[2]
    final_result = combine_match_result(p1, p2, forced_tie=forced_tie_triggered)
    game_steps = max(p1.game_loops, p2.game_loops)
    wall = round(time.monotonic() - t0, 2)

    result_obj = {
        "results": [
            {
                "match": 1,
                "bot1_avg_step_time": p1.avg_step_time,
                "bot1_tags": p1.tags,
                "bot2_avg_step_time": p2.avg_step_time,
                "bot2_tags": p2.tags,
                "type": final_result,
                "game_steps": game_steps,
                "p1_detail": p1.result or "",
                "p2_detail": p2.result or "",
                "p1_error": p1.error_detail,
                "p2_error": p2.error_detail,
            }
        ]
    }
    results_path.write_text(json.dumps(result_obj, indent=2) + "\n", encoding="utf-8")
    log(
        f"Match finished in {wall}s | result={final_result} (P1={p1.result}, P2={p2.result}) | "
        f"game_steps={game_steps} | replay_saved={replay_saved}"
    )
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="In-container 2-player SC2 WebSocket match controller")
    ap.add_argument("--bot1-name", required=True)
    ap.add_argument("--bot1-race", required=True)
    ap.add_argument("--bot1-type", required=True)
    ap.add_argument("--bot1-id", default="1")
    ap.add_argument("--bot2-name", required=True)
    ap.add_argument("--bot2-race", required=True)
    ap.add_argument("--bot2-type", required=True)
    ap.add_argument("--bot2-id", default="2")
    ap.add_argument("--map", required=True)
    ap.add_argument("--bots-root", default="/bots")
    ap.add_argument("--log-root", default="/logs")
    ap.add_argument("--replay-path", default="/replays/match.SC2Replay")
    ap.add_argument("--results-path", default="/app/results.json")
    ap.add_argument("--max-game-time", type=int, default=60480)
    ap.add_argument("--wall-timeout-sec", type=float, default=0.0)
    ap.add_argument("--bot-timeout-sec", type=float, default=45.0)
    ap.add_argument("--join-timeout-sec", type=float, default=40.0)
    ap.add_argument("--realtime", action="store_true")
    ap.add_argument("--validate-race", action="store_true")
    ap.add_argument("--allow-debug", action="store_true")
    args = ap.parse_args()
    args.disable_debug = not args.allow_debug

    # Ensure clean exit on SIGTERM
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        return loop.run_until_complete(run_match(args))
    finally:
        loop.close()


if __name__ == "__main__":
    sys.exit(main())
