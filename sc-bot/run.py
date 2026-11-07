#!/usr/bin/env python3
"""
AI Arena & Local Headless Entrypoint for #lang sc-bot (Mothman / Z / T / P / R).
Supports both:
  1. AI Arena / LadderServer websocket client mode (--GamePort, --StartPort, --LadderServer)
  2. Local headless SC2_x64 execution against Built-in AI or external bots (--ComputerOpponent, --bot, --race)
"""

import argparse
import json
import os
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from sim.sc2_burny_bridge import (
    create_racket_sc2_agent,
    infer_bot_race_and_posture,
    run_live_headless_sc2_match,
)


def load_bot_config(variant_name: str = None) -> dict:
    cfg_path = ROOT_DIR / "config.json"
    if not cfg_path.exists():
        return {
            "BotName": variant_name or "Mothman",
            "BotRace": "Random",
            "BotPath": "bots/Mothman.rkt",
        }
    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    if variant_name and "Variants" in cfg and variant_name in cfg["Variants"]:
        return cfg["Variants"][variant_name]
    return cfg


def main():
    parser = argparse.ArgumentParser(description="Run #lang sc-bot (Mothman) on SC2_x64 or AI Arena Ladder")
    parser.add_argument("--GamePort", type=int, default=None, help="SC2 GamePort for AI Arena")
    parser.add_argument("--StartPort", type=int, default=None, help="SC2 StartPort for AI Arena")
    parser.add_argument("--LadderServer", type=str, default=None, help="AI Arena LadderServer host")
    parser.add_argument("--OpponentId", type=str, default="local_opponent", help="Opponent ID on AI Arena")
    parser.add_argument("--ComputerOpponent", action="store_true", help="Play against built-in SC2 Computer")
    parser.add_argument("--ComputerRace", type=str, default="Protoss", help="Built-in Computer Race")
    parser.add_argument("--ComputerDifficulty", type=str, default="VeryHard", help="Built-in Computer Difficulty")
    parser.add_argument("--BotName", type=str, default=None, help="Variant name (Mothman, Mothman-Z, Mothman-T, Mothman-P, Mothman-R)")
    parser.add_argument("--bot", type=str, default=None, help="Path to .rkt bot file")
    parser.add_argument("--race", type=str, default=None, help="Race override (Zerg, Terran, Protoss, Random)")
    parser.add_argument("--posture", type=str, default=None, help="Initial posture override")
    parser.add_argument("--Map", "--map", dest="map_name", type=str, default="Simple64", help="SC2 Map name")
    parser.add_argument("--max-loops", type=int, default=4032, help="Max game loops for local headless run")
    parser.add_argument("--save-replay", type=str, default=None, help="Optional path to save .SC2Replay")
    parser.add_argument("--RealTime", "--realtime", dest="realtime", action="store_true", help="Run in real-time mode")
    parser.add_argument("--dry-run", action="store_true", help="Verify configuration and bot resolution without launching SC2")

    args, _unknown = parser.parse_known_args()
    cfg = load_bot_config(args.BotName)

    bot_rel_path = args.bot or cfg.get("BotPath", "bots/Mothman.rkt")
    bot_rkt_path = str((ROOT_DIR / bot_rel_path).resolve()) if not os.path.isabs(bot_rel_path) else bot_rel_path
    race_str, posture_str = infer_bot_race_and_posture(bot_rkt_path)
    if cfg.get("BotRace") and not args.race:
        race_str = cfg["BotRace"]
    if args.race:
        race_str = args.race
    if args.posture:
        posture_str = args.posture

    if args.dry_run:
        print(
            json.dumps(
                {
                    "status": "DRY_RUN_OK",
                    "bot_name": cfg.get("BotName", "Mothman"),
                    "bot_rkt_path": bot_rkt_path,
                    "resolved_race": race_str,
                    "resolved_posture": posture_str,
                    "map": args.map_name,
                }
            )
        )
        return

    # AI Arena LadderServer mode
    if args.GamePort is not None:
        import asyncio
        import aiohttp
        import sc2.protocol
        from sc2.client import Client
        from sc2.data import Race
        from sc2.main import _play_game
        from sc2.player import Bot
        from sc2.portconfig import Portconfig

        race_enum = getattr(Race, race_str.capitalize(), Race.Random)
        agent = create_racket_sc2_agent(bot_rkt_path, race_override=race_str, posture_override=posture_str)
        agent.opponent_id = args.OpponentId
        bot_player = Bot(race_enum, agent, name=cfg.get("BotName", "Mothman"))

        host = args.LadderServer or "127.0.0.1"
        if args.StartPort is not None:
            ports = [args.StartPort + p for p in range(1, 6)]
            portconfig = Portconfig(server_ports=[ports[1], ports[2]], player_ports=[[ports[3], ports[4]]])
            portconfig.shared = ports[0]
        else:
            portconfig = None

        ConnClosed = getattr(
            sc2.protocol,
            "ConnectionAlreadyClosedError",
            getattr(sc2.protocol, "ConnectionAlreadyClosed", Exception),
        )

        async def _join_ladder_game():
            ws_url = f"ws://{host}:{args.GamePort}/sc2api"
            async with aiohttp.ClientSession() as session:
                ws_connection = await session.ws_connect(ws_url, timeout=120)
                client = Client(ws_connection)
                if getattr(bot_player.ai, "raw_affects_selection", None) is not None:
                    client.raw_affects_selection = bot_player.ai.raw_affects_selection
                try:
                    return await _play_game(bot_player, client, args.realtime, portconfig)
                except ConnClosed:
                    return None
                finally:
                    await ws_connection.close()

        asyncio.run(_join_ladder_game())
        return

    # Local headless match mode
    result = run_live_headless_sc2_match(
        bot_rkt_path=bot_rkt_path,
        opponent_race_str=args.ComputerRace,
        difficulty_str=args.ComputerDifficulty,
        map_name=args.map_name,
        max_game_loops=args.max_loops,
        save_replay_path=args.save_replay,
        race_override=race_str,
        posture_override=posture_str,
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
