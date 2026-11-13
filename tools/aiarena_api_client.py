#!/usr/bin/env python3
"""
tools/aiarena_api_client.py

AI Arena REST & GraphQL API Client & Live Ladder Monitor for Mothman:
  - Lists all bots owned by user `Mothman` (`user_id = 3871`) and their active
    competition registrations (`Sc2 AI Arena 2026 Season 2`, `competition_id = 38`).
  - Uploads new bots (`uploadBot` GraphQL mutation in `cpplinux` mode) and updates
    existing bot zips/data (`PATCH /api/bots/<id>/`).
  - Registers bots in open competitions (`updateCompetitionParticipation` GraphQL mutation).
  - Monitors live & completed matches (`GET /api/match-participations/?bot=<id>`),
    resolving opponent names, maps, ELO deltas, step times, tags, and replay URLs.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
from pathlib import Path

DEFAULT_TOKEN = os.environ.get("AIARENA_API_TOKEN", "")
USER_ID = 3871
COMPETITION_ID = 38  # Sc2 AI Arena 2026 Season 2


def api_get(endpoint_or_url: str, token: str = DEFAULT_TOKEN) -> dict:
    url = endpoint_or_url if endpoint_or_url.startswith("http") else f"https://aiarena.net/api/{endpoint_or_url.lstrip('/')}"
    p = subprocess.run(
        ["curl", "-sL", "-H", f"Authorization: Token {token}", url],
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(p.stdout)
    except Exception:
        return {"raw": p.stdout}


def patch_bot_zip(bot_id: int, zip_path: str, token: str = DEFAULT_TOKEN) -> dict:
    p = subprocess.run(
        [
            "curl",
            "-sL",
            "-X",
            "PATCH",
            "-H",
            f"Authorization: Token {token}",
            "-F",
            f"bot_zip=@{zip_path}",
            "-F",
            "bot_data_enabled=true",
            f"https://aiarena.net/api/bots/{bot_id}/",
        ],
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(p.stdout)
    except Exception:
        return {"raw": p.stdout}


def set_competition_active(bot_id: int, competition_id: int = COMPETITION_ID, active: bool = True, token: str = DEFAULT_TOKEN) -> dict:
    bot_gql = base64.b64encode(f"BotType:{bot_id}".encode()).decode()
    comp_gql = base64.b64encode(f"CompetitionType:{competition_id}".encode()).decode()
    q = {
        "query": "mutation($input: UpdateCompetitionParticipationInput!) { updateCompetitionParticipation(input: $input) { errors { field messages } } }",
        "variables": {"input": {"bot": bot_gql, "competition": comp_gql, "active": active}},
    }
    p = subprocess.run(
        [
            "curl",
            "-sL",
            "-X",
            "POST",
            "-H",
            f"Authorization: Token {token}",
            "-H",
            "Content-Type: application/json",
            "-d",
            json.dumps(q),
            "https://aiarena.net/graphql/",
        ],
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(p.stdout)
    except Exception:
        return {"raw": p.stdout}


def get_status_report(token: str = DEFAULT_TOKEN) -> dict:
    bots_resp = api_get(f"bots/?user={USER_ID}", token=token)
    bots = bots_resp.get("results", [])

    bot_name_cache: dict[int, str] = {b["id"]: b["name"] for b in bots}
    map_name_cache: dict[int, str] = {}

    def resolve_bot_name(bid: int) -> str:
        if bid not in bot_name_cache:
            info = api_get(f"bots/{bid}/", token=token)
            bot_name_cache[bid] = info.get("name", f"Bot#{bid}")
        return bot_name_cache[bid]

    def resolve_map_name(mid: int) -> str:
        if mid not in map_name_cache:
            info = api_get(f"maps/{mid}/", token=token)
            map_name_cache[mid] = info.get("name", f"Map#{mid}")
        return map_name_cache[mid]

    report_bots = []
    for b in bots:
        bid = b["id"]
        cp = api_get(f"competition-participations/?bot={bid}", token=token).get("results", [])
        mp = api_get(f"match-participations/?bot={bid}&ordering=-match", token=token).get("results", [])

        recent_matches = []
        for part in mp[:10]:
            mid = part["match"]
            m_info = api_get(f"matches/{mid}/", token=token)
            all_parts = api_get(f"match-participations/?match={mid}", token=token).get("results", [])
            opp_part = next((x for x in all_parts if x["bot"] != bid), None)
            opp_name = resolve_bot_name(opp_part["bot"]) if opp_part else "Unknown"
            res_list = api_get(f"results/?match={mid}", token=token).get("results", [])
            res_obj = res_list[0] if res_list else None

            status_str = "Queued"
            if res_obj:
                status_str = f"Finished ({part.get('result') or res_obj.get('type')} / {part.get('result_cause')})"
            elif m_info.get("started"):
                status_str = f"LIVE IN PROGRESS (started {m_info['started']}, ArenaClient #{m_info.get('assigned_to')})"

            recent_matches.append(
                {
                    "match_id": mid,
                    "opponent": opp_name,
                    "opponent_id": opp_part["bot"] if opp_part else None,
                    "map": resolve_map_name(m_info["map"]) if m_info.get("map") else None,
                    "status": status_str,
                    "result": part.get("result"),
                    "result_cause": part.get("result_cause"),
                    "elo_change": part.get("elo_change"),
                    "avg_step_time_ms": round(part["avg_step_time"] * 1000, 2) if part.get("avg_step_time") else None,
                    "game_steps": res_obj.get("game_steps") if res_obj else None,
                    "replay_file": res_obj.get("replay_file") if res_obj else None,
                }
            )

        report_bots.append(
            {
                "id": bid,
                "name": b["name"],
                "race": b["plays_race"]["label"],
                "type": b["type"],
                "bot_zip_updated": b["bot_zip_updated"],
                "bot_zip_md5hash": b["bot_zip_md5hash"],
                "bot_data_enabled": b["bot_data_enabled"],
                "competitions": [
                    {
                        "participation_id": c["id"],
                        "competition_id": c["competition"],
                        "active": c["active"],
                        "elo": c["elo"],
                        "match_count": c["match_count"],
                        "win_count": c["win_count"],
                        "win_perc": round(c["win_perc"], 1),
                        "division_num": c["division_num"],
                        "in_placements": c["in_placements"],
                    }
                    for c in cp
                ],
                "total_matches_queued_or_played": len(mp),
                "recent_matches": recent_matches,
            }
        )

    return {
        "user_id": USER_ID,
        "username": "Mothman",
        "competition_id": COMPETITION_ID,
        "competition_name": "Sc2 AI Arena 2026 Season 2",
        "bots": report_bots,
    }


def main():
    parser = argparse.ArgumentParser(description="AI Arena API Client & Live Monitor for Mothman")
    parser.add_argument("--status", action="store_true", help="Fetch live status of all Mothman bots and matches")
    parser.add_argument("--sync-zips", action="store_true", help="Upload latest ladder/*.zip to all 4 Mothman bots")
    args = parser.parse_args()

    if args.sync_zips:
        root = Path(__file__).resolve().parent.parent
        # Ensure legacy python Mothman-R (#1457) stays paused
        set_competition_active(1457, COMPETITION_ID, False)
        mapping = [
            (1461, root / "ladder" / "Mothman-X.zip"),  # Mothman-X (cpplinux Random)
            (1458, root / "ladder" / "Mothman-Z.zip"),
            (1459, root / "ladder" / "Mothman-T.zip"),
            (1460, root / "ladder" / "Mothman-P.zip"),
        ]
        for bid, zpath in mapping:
            if zpath.exists():
                patch_bot_zip(bid, str(zpath))
                set_competition_active(bid, COMPETITION_ID, True)

    print(json.dumps(get_status_report(), indent=2))


if __name__ == "__main__":
    main()
