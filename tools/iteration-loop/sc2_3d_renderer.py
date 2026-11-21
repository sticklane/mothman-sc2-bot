#!/usr/bin/env python3
"""
tools/iteration-loop/sc2_3d_renderer.py

Native host real-3D StarCraft II (`SC2_x64` Base75689 + OpenGL/EGL on AMD Radeon)
visuals engine producing crisp streaming H.264 `.mp4` (or animated WebP) battle
videos + 960x720 Peak-Clash PNG posters with a live SC2 Replay-Viewer Top HUD.

Exports:
  - compose_3d_frame(...)
      Composites real 3D SC2 viewport + bottom-left real SC2 minimap + live SC2
      Replay-Viewer Top HUD (P1 & P2 team-colored cards with names, race badges,
      live worker counts, live supply `used/cap` with supply-block highlight,
      and center clock / match pill).
  - extract_replay_players(replay_path_or_bytes)
      Extracts Player 1 & Player 2 names, races, and team colors from
      `replay.details` via s2protocol (`protocol75689`).
  - extract_frame_hud_stats(obs)
      Computes exact live worker counts and supply `used / cap` directly from
      `obs.raw_data.units` for both Player 1 and Player 2.
  - MP4StreamEncoder / WebPStreamEncoder
      Streaming RGB24 -> ffmpeg H.264 `.mp4` (`libx264 -crf 24 -movflags +faststart`)
      and animated WebP encoders.
  - render_replay_clip(...) / render_replay_clip_sync(...)
      Renders a key-moment highlight clip with pre-clash lead-in & live HUD.
  - render_full_match_video(...) / render_full_match_video_sync(...)
      Renders a complete `00:00 -> GG` observer-mode replay video (`step=20`,
      `fps=16`) with smart anti-whiplash camera director + Peak-Clash PNG poster.
  - render_arena_replays_parallel(race_specs, out_dir, ...)
      Renders ALL tactics-arena duels across parallel host SC2_x64 instances
      with zero-truncation (`max_frames_per_duel=480`), pre-spawn lead-in, live
      HUD, and H.264 `.mp4` output -> `<out_dir>/arena_manifest.json`.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import importlib.util
import io
import json
import math
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont

# Host persistent SC2 3D runtime & pylibs (append AFTER stdlib imports!)
DEFAULT_SC2_HOST_DIR = Path("/home/sjaconette/sc2-local-arena/sc2-host")
DEFAULT_PYLIBS_DIR = Path("/home/sjaconette/sc2-local-arena/pylibs")
DEFAULT_MAPS_DIR = Path("/home/sjaconette/sc2-local-arena/maps")
DEFAULT_EGL_PATH = "/usr/lib/x86_64-linux-gnu/libEGL.so.1"
DEFAULT_FFMPEG = shutil.which("ffmpeg") or "/usr/bin/ffmpeg"

DEFAULT_P1_COLOR: tuple[int, int, int] = (225, 55, 55)
DEFAULT_P2_COLOR: tuple[int, int, int] = (55, 145, 255)

if str(DEFAULT_PYLIBS_DIR) not in sys.path and DEFAULT_PYLIBS_DIR.is_dir():
    sys.path.append(str(DEFAULT_PYLIBS_DIR))

VARIABLES_TXT = (
    "GraphicsOptionOverallQualityVer7[5]=3\n"
    "GraphicsOptionEffectsDetail=2\n"
    "LightingDetail=2\n"
    "ModelDetail=2\n"
    "PostProcessing=2\n"
    "ShaderDetail=2\n"
    "ShadowQuality=2\n"
    "TerrainDetail=2\n"
    "TextureQuality[2]=2\n"
)

# Non-combat / worker / neutral / building IDs to ignore when computing battle centroid
WORKER_IDS = {45, 84, 104, 116, 268}  # SCV, Probe, Drone, DroneBurrowed, MULE
WORKER_COUNT_IDS = {45, 84, 104, 116}  # Real workers (excludes MULE)
TOWNHALL_IDS = {18, 36, 130, 132, 134, 59, 86, 100, 101}
IGNORE_IDS = {
    151, 103, 87, 137, 138, 801,  # Larva, Egg, CreepTumors, AdeptShade
    106, 129, 893, 82, 1911,      # Overlords, Observer (avoid pulling camera away from real army fights)
}
STRUCTURE_IDS = {
    5, 6, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 46, 47, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70,
    71, 72, 86, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102,
    130, 132, 133, 134, 139, 140, 142, 504, 894, 1910, 1943, 1949, 1955, 1956,
    1994, 1995,
}

# Exact SC2 LotV (Base75689) unit_type_id -> food_used
UNIT_FOOD_USED: dict[int, float] = {
    # Terran
    45: 1.0,    # SCV
    48: 1.0,    # Marine
    49: 1.0,    # Reaper
    51: 2.0,    # Marauder
    50: 2.0,    # Ghost
    53: 2.0,    # Hellion
    484: 2.0,   # Hellbat
    498: 2.0,   # WidowMine
    500: 2.0,   # WidowMineBurrowed
    33: 3.0,    # SiegeTank
    32: 3.0,    # SiegeTankSieged
    692: 3.0,   # Cyclone
    52: 6.0,    # Thor
    691: 6.0,   # ThorAP
    35: 2.0,    # VikingFighter
    34: 2.0,    # VikingAssault
    54: 2.0,    # Medivac
    689: 3.0,   # Liberator
    734: 3.0,   # LiberatorAG
    56: 2.0,    # Raven
    55: 3.0,    # Banshee
    57: 6.0,    # Battlecruiser
    # Protoss
    84: 1.0,    # Probe
    73: 2.0,    # Zealot
    74: 2.0,    # Stalker
    77: 2.0,    # Sentry
    311: 2.0,   # Adept
    75: 2.0,    # HighTemplar
    76: 2.0,    # DarkTemplar
    141: 4.0,   # Archon
    83: 4.0,    # Immortal
    82: 1.0,    # Observer
    1911: 1.0,  # ObserverSiegeMode
    81: 2.0,    # WarpPrism
    136: 2.0,   # WarpPrismPhasing
    4: 6.0,     # Colossus
    694: 3.0,   # Disruptor
    78: 2.0,    # Phoenix
    80: 4.0,    # VoidRay
    495: 3.0,   # Oracle
    79: 6.0,    # Carrier
    496: 5.0,   # Tempest
    10: 8.0,    # Mothership
    488: 2.0,   # MothershipCore
    # Zerg
    104: 1.0,   # Drone
    116: 1.0,   # DroneBurrowed
    105: 0.5,   # Zergling
    119: 0.5,   # ZerglingBurrowed
    8: 0.5,     # BanelingCocoon
    9: 0.5,     # Baneling
    115: 0.5,   # BanelingBurrowed
    110: 2.0,   # Roach
    118: 2.0,   # RoachBurrowed
    687: 3.0,   # RavagerCocoon
    688: 3.0,   # Ravager
    690: 3.0,   # RavagerBurrowed
    107: 2.0,   # Hydralisk
    117: 2.0,   # HydraliskBurrowed
    501: 3.0,   # LurkerMPEgg
    502: 3.0,   # LurkerMP
    503: 3.0,   # LurkerMPBurrowed
    108: 2.0,   # Mutalisk
    112: 2.0,   # Corruptor
    113: 4.0,   # BroodLordCocoon
    114: 4.0,   # BroodLord
    126: 2.0,   # Queen
    125: 2.0,   # QueenBurrowed
    111: 2.0,   # Infestor
    127: 2.0,   # InfestorBurrowed
    494: 3.0,   # SwarmHostMP
    493: 3.0,   # SwarmHostBurrowedMP
    109: 6.0,   # Ultralisk
    131: 6.0,   # UltraliskBurrowed
    499: 3.0,   # Viper
}

# Zerg Egg (103) morph ability_id -> food_used while morphing
ZERG_EGG_ABILITY_FOOD: dict[int, float] = {
    1342: 1.0,  # TrainDrone
    1343: 1.0,  # TrainZergling (pair = 2 x 0.5)
    1344: 0.0,  # TrainOverlord
    1345: 2.0,  # TrainHydralisk
    1346: 2.0,  # TrainMutalisk
    1348: 6.0,  # TrainUltralisk
    1351: 2.0,  # TrainRoach
    1352: 2.0,  # TrainInfestor
    1353: 2.0,  # TrainCorruptor
    1354: 3.0,  # TrainViper
    1356: 3.0,  # TrainSwarmHost
}

# Exact SC2 LotV supply providers (only counted when build_progress >= 1.0)
SUPPLY_PROVIDER_CAP: dict[int, int] = {
    18: 15,     # CommandCenter
    36: 15,     # CommandCenterFlying
    132: 15,    # OrbitalCommand
    134: 15,    # OrbitalCommandFlying
    130: 15,    # PlanetaryFortress
    19: 8,      # SupplyDepot
    47: 8,      # SupplyDepotLowered
    59: 15,     # Nexus
    60: 8,      # Pylon
    894: 8,     # PylonOvercharged
    86: 6,      # Hatchery
    100: 6,     # Lair
    101: 6,     # Hive
    106: 8,     # Overlord
    128: 8,     # OverlordCocoon
    892: 8,     # TransportOverlordCocoon
    893: 8,     # OverlordTransport
    129: 8,     # Overseer
    1912: 8,    # OverseerSiegeMode
}


# -----------------------------------------------------------------------------
# s2protocol Player Metadata Extraction (Names, Races, Team Colors)
# -----------------------------------------------------------------------------
_PROTO75689 = None


def _load_protocol75689():
    global _PROTO75689
    if _PROTO75689 is not None:
        return _PROTO75689
    proto_path = DEFAULT_PYLIBS_DIR / "s2protocol" / "versions" / "protocol75689.py"
    spec = importlib.util.spec_from_file_location("protocol75689", str(proto_path))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _PROTO75689 = mod
    return mod


def _decode_str(raw: Any) -> str:
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="ignore").strip()
    return str(raw or "").strip()


def _boost_team_rgb(rgb: tuple[int, int, int]) -> tuple[int, int, int]:
    """Keep exact SC2 team hue while ensuring dark blues/reds stay legible on dark HUD glass."""
    r, g, b = (max(0, min(255, int(c))) for c in rgb)
    lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    if lum < 72.0:
        # Lift luminance smoothly while preserving chroma
        boost = (78.0 - lum) / 255.0
        r = min(255, int(round(r + (255 - r) * boost * 0.65 + (40 if r >= max(g, b) else 0))))
        g = min(255, int(round(g + (255 - g) * boost * 0.65)))
        b = min(255, int(round(b + (255 - b) * boost * 0.75 + (40 if b >= max(r, g) else 0))))
    return (r, g, b)


def extract_replay_players(
    replay_source: str | Path | bytes,
    fallback_p1: tuple[str, str, tuple[int, int, int]] = ("Mothman", "", DEFAULT_P1_COLOR),
    fallback_p2: tuple[str, str, tuple[int, int, int]] = ("Opponent", "", DEFAULT_P2_COLOR),
) -> dict[int, dict[str, Any]]:
    """
    Extract Player 1 & Player 2 names, races, and team RGB colors from `replay.details`.
    Returns `{1: {"name", "race", "color"}, 2: {"name", "race", "color"}}`.
    """
    out: dict[int, dict[str, Any]] = {
        1: {"name": fallback_p1[0], "race": fallback_p1[1], "color": fallback_p1[2]},
        2: {"name": fallback_p2[0], "race": fallback_p2[1], "color": fallback_p2[2]},
    }
    try:
        import mpyq

        proto = _load_protocol75689()
        if isinstance(replay_source, (bytes, bytearray)):
            arc = mpyq.MPQArchive(io.BytesIO(replay_source))
        else:
            arc = mpyq.MPQArchive(str(replay_source))
        det_bytes = arc.read_file("replay.details")
        if not det_bytes:
            return out
        det = proto.decode_replay_details(det_bytes)
        plist = det.get("m_playerList") or []
        for idx, pid in enumerate((1, 2)):
            if idx >= len(plist):
                continue
            pl = plist[idx]
            name = _decode_str(pl.get("m_name")) or out[pid]["name"]
            race = _decode_str(pl.get("m_race")) or out[pid]["race"]
            col = pl.get("m_color") or {}
            if all(k in col for k in ("m_r", "m_g", "m_b")):
                rgb = _boost_team_rgb((int(col["m_r"]), int(col["m_g"]), int(col["m_b"])))
            else:
                rgb = out[pid]["color"]
            out[pid] = {"name": name, "race": race, "color": rgb}
    except Exception:
        pass
    return out


def extract_frame_hud_stats(obs: Any) -> dict[str, int]:
    """
    Compute live per-frame worker counts and supply `used / cap` directly from
    `obs.raw_data.units` (works identically for full matches AND Arena duels!).
    """
    workers = {1: 0, 2: 0}
    food_used = {1: 0.0, 2: 0.0}
    food_cap = {1: 0, 2: 0}

    for u in obs.raw_data.units:
        owner = int(u.owner)
        if owner not in (1, 2):
            continue
        if getattr(u, "is_hallucination", False):
            continue
        ut = int(u.unit_type)
        bp = float(getattr(u, "build_progress", 1.0))

        if ut in WORKER_COUNT_IDS and bp >= 1.0:
            workers[owner] += 1

        if ut == 103:  # Zerg Egg — inspect morph ability for exact supply
            if u.orders:
                ab = int(u.orders[0].ability_id)
                food_used[owner] += ZERG_EGG_ABILITY_FOOD.get(ab, 0.0)
        else:
            fu = UNIT_FOOD_USED.get(ut)
            if fu:
                food_used[owner] += fu

        if bp >= 1.0:
            fc = SUPPLY_PROVIDER_CAP.get(ut)
            if fc:
                food_cap[owner] += fc

    return {
        "p1_workers": workers[1],
        "p1_supply_used": int(math.floor(food_used[1] + 1e-6)),
        "p1_supply_cap": min(200, food_cap[1]),
        "p2_workers": workers[2],
        "p2_supply_used": int(math.floor(food_used[2] + 1e-6)),
        "p2_supply_cap": min(200, food_cap[2]),
    }


# -----------------------------------------------------------------------------
# Minimal Typography & SC2 Replay-Viewer Top HUD Frame Composer
# -----------------------------------------------------------------------------
_FONT_CACHE: dict[tuple[bool, int], ImageFont.FreeTypeFont | ImageFont.ImageFont] = {}


def _get_font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    key = (bold, size)
    if key in _FONT_CACHE:
        return _FONT_CACHE[key]
    candidates = (
        ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf")
        if bold
        else ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf")
    )
    for p in candidates:
        if os.path.exists(p):
            try:
                f = ImageFont.truetype(p, size)
                _FONT_CACHE[key] = f
                return f
            except Exception:
                pass
    f = ImageFont.load_default()
    _FONT_CACHE[key] = f
    return f


def fmt_clock(game_loop: int) -> str:
    sec = max(0, int(round(game_loop / 22.4)))
    return f"{sec // 60:02d}:{sec % 60:02d}"


def _race_short(race: str) -> str:
    r = (race or "").strip().lower()
    if r.startswith("p"):
        return "P"
    if r.startswith("t"):
        return "T"
    if r.startswith("z"):
        return "Z"
    if r.startswith("r"):
        return "R"
    return "?"


def _truncate_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    font: ImageFont.FreeTypeFont | ImageFont.ImageFont,
    max_w: int,
) -> str:
    if not text:
        return ""
    bbox = draw.textbbox((0, 0), text, font=font)
    if bbox[2] - bbox[0] <= max_w:
        return text
    s = text
    while len(s) > 3:
        s = s[:-1]
        cand = s + "…"
        bb = draw.textbbox((0, 0), cand, font=font)
        if bb[2] - bb[0] <= max_w:
            return cand
    return text[:3]


def _draw_player_card(
    ov: ImageDraw.ImageDraw,
    x0: int,
    y0: int,
    w: int,
    h: int,
    name: str,
    race: str,
    team_rgb: tuple[int, int, int],
    workers: int,
    supply_used: int,
    supply_cap: int,
    align_right: bool = False,
    is_arena: bool = False,
) -> None:
    """Render one sleek SC2 replay-viewer player card (team bar + name/race + workers + supply)."""
    f_name = _get_font(14, bold=True)
    f_badge = _get_font(11, bold=True)
    f_stat = _get_font(12, bold=True)
    f_lbl = _get_font(11, bold=False)

    # Glass backing with subtle team-colored border
    ov.rounded_rectangle(
        [x0, y0, x0 + w, y0 + h],
        radius=7,
        fill=(10, 15, 26, 206),
        outline=(*team_rgb, 185),
        width=1,
    )
    # Crisp 5px team-color accent bar on outer edge
    bar_w = 5
    if not align_right:
        ov.rounded_rectangle(
            [x0 + 1, y0 + 1, x0 + 1 + bar_w, y0 + h - 1],
            radius=3,
            fill=(*team_rgb, 255),
        )
    else:
        ov.rounded_rectangle(
            [x0 + w - 1 - bar_w, y0 + 1, x0 + w - 1, y0 + h - 1],
            radius=3,
            fill=(*team_rgb, 255),
        )

    r_tag = _race_short(race)
    badge_w, badge_h = 20, 17
    row1_cy = y0 + 14
    row2_cy = y0 + h - 12

    # Supply text + supply-block highlight
    if is_arena and (supply_cap == 0 or supply_used > supply_cap):
        sup_blocked = False
        sup_txt = f"Supply: {supply_used}"
    else:
        sup_blocked = (not is_arena) and (supply_cap > 0) and (supply_used >= supply_cap) and (supply_cap < 200)
        sup_txt = f"Supply: {supply_used}/{supply_cap}" + (" !" if sup_blocked else "")
    sup_col = (248, 113, 113, 255) if sup_blocked else (241, 245, 249, 255)
    wrk_txt = f"Workers: {workers}"

    inner_l = x0 + (bar_w + 9 if not align_right else 10)
    inner_r = x0 + w - (10 if not align_right else bar_w + 9)
    max_name_w = max(60, (inner_r - inner_l) - badge_w - 8)
    disp_name = _truncate_text(ov, name or "Player", f_name, max_name_w)

    if not align_right:
        # Row 1: [RaceBadge] Name
        bx0 = inner_l
        by0 = int(row1_cy - badge_h / 2)
        ov.rounded_rectangle(
            [bx0, by0, bx0 + badge_w, by0 + badge_h],
            radius=4,
            fill=(*team_rgb, 235),
        )
        ov.text((bx0 + badge_w / 2, row1_cy), r_tag, fill=(255, 255, 255, 255), font=f_badge, anchor="mm")
        ov.text((bx0 + badge_w + 7, row1_cy), disp_name, fill=(248, 250, 252, 255), font=f_name, anchor="lm")

        # Row 2: W: 42   |   86/94
        ov.text((inner_l, row2_cy), wrk_txt, fill=(148, 163, 184, 255), font=f_stat, anchor="lm")
        ov.text((inner_r, row2_cy), sup_txt, fill=sup_col, font=f_stat, anchor="rm")
        if sup_blocked:
            # Subtle amber-red warning badge glow behind supply
            bb = ov.textbbox((inner_r, row2_cy), sup_txt, font=f_stat, anchor="rm")
            ov.rounded_rectangle(
                [bb[0] - 5, bb[1] - 2, bb[2] + 5, bb[3] + 2],
                radius=4,
                fill=(220, 38, 38, 60),
                outline=(248, 113, 113, 180),
                width=1,
            )
            ov.text((inner_r, row2_cy), sup_txt, fill=(254, 202, 202, 255), font=f_stat, anchor="rm")
    else:
        # Row 1: Name [RaceBadge]
        bx0 = inner_r - badge_w
        by0 = int(row1_cy - badge_h / 2)
        ov.rounded_rectangle(
            [bx0, by0, bx0 + badge_w, by0 + badge_h],
            radius=4,
            fill=(*team_rgb, 235),
        )
        ov.text((bx0 + badge_w / 2, row1_cy), r_tag, fill=(255, 255, 255, 255), font=f_badge, anchor="mm")
        ov.text((bx0 - 7, row1_cy), disp_name, fill=(248, 250, 252, 255), font=f_name, anchor="rm")

        # Row 2: 74/86   |   W: 38
        ov.text((inner_r, row2_cy), wrk_txt, fill=(148, 163, 184, 255), font=f_stat, anchor="rm")
        if sup_blocked:
            bb = ov.textbbox((inner_l, row2_cy), sup_txt, font=f_stat, anchor="lm")
            ov.rounded_rectangle(
                [bb[0] - 5, bb[1] - 2, bb[2] + 5, bb[3] + 2],
                radius=4,
                fill=(220, 38, 38, 60),
                outline=(248, 113, 113, 180),
                width=1,
            )
            ov.text((inner_l, row2_cy), sup_txt, fill=(254, 202, 202, 255), font=f_stat, anchor="lm")
        else:
            ov.text((inner_l, row2_cy), sup_txt, fill=sup_col, font=f_stat, anchor="lm")
    _ = f_lbl  # reserved


def compose_3d_frame(
    map_bytes: bytes,
    map_w: int,
    map_h: int,
    minimap_bytes: bytes | None,
    minimap_w: int,
    minimap_h: int,
    pill_text: str = "",
    accent_rgb: tuple[int, int, int] = (56, 189, 248),
    minimap_display_size: int = 160,
    include_minimap: bool = True,
    hud: dict[str, Any] | None = None,
) -> Image.Image:
    """
    Composite real 3D SC2_x64 viewport + bottom-left real minimap + either:
      - Full SC2 Replay-Viewer Top HUD (`hud` dict provided: P1 card, center clock/match pill, P2 card), OR
      - Legacy single-line top-left pill (`hud is None` and `pill_text` provided).
    """
    img = Image.frombytes("RGB", (map_w, map_h), map_bytes)

    # 1. Bottom-left real SC2 minimap with crisp dark backing + 1px border
    if include_minimap and minimap_bytes and minimap_w > 0 and minimap_h > 0:
        mm = Image.frombytes("RGB", (minimap_w, minimap_h), minimap_bytes)
        if minimap_w != minimap_display_size or minimap_h != minimap_display_size:
            mm = mm.resize((minimap_display_size, minimap_display_size), Image.Resampling.BILINEAR)
        pad = 10
        mx0 = pad
        my0 = map_h - minimap_display_size - pad
        draw_base = ImageDraw.Draw(img)
        draw_base.rectangle(
            [mx0 - 2, my0 - 2, mx0 + minimap_display_size + 1, my0 + minimap_display_size + 1],
            fill=(10, 15, 26),
            outline=(148, 163, 184),
            width=1,
        )
        img.paste(mm, (mx0, my0))

    # 2. SC2 Replay-Viewer Top HUD (P1 card | Center Clock+Match pill | P2 card)
    if hud is not None:
        overlay = Image.new("RGBA", (map_w, map_h), (0, 0, 0, 0))
        ov = ImageDraw.Draw(overlay)
        top_y = 8
        card_h = 46
        side_pad = 10
        center_w = min(290, max(210, int(map_w * 0.28)))
        card_w = max(180, min(295, (map_w - 2 * side_pad - center_w - 20) // 2))
        is_arena = bool(hud.get("is_arena", False))

        _draw_player_card(
            ov,
            x0=side_pad,
            y0=top_y,
            w=card_w,
            h=card_h,
            name=str(hud.get("p1_name") or "Mothman"),
            race=str(hud.get("p1_race") or ""),
            team_rgb=tuple(hud.get("p1_color") or DEFAULT_P1_COLOR),
            workers=int(hud.get("p1_workers") or 0),
            supply_used=int(hud.get("p1_supply_used") or 0),
            supply_cap=int(hud.get("p1_supply_cap") or 0),
            align_right=False,
            is_arena=is_arena,
        )
        _draw_player_card(
            ov,
            x0=map_w - side_pad - card_w,
            y0=top_y,
            w=card_w,
            h=card_h,
            name=str(hud.get("p2_name") or "Opponent"),
            race=str(hud.get("p2_race") or ""),
            team_rgb=tuple(hud.get("p2_color") or DEFAULT_P2_COLOR),
            workers=int(hud.get("p2_workers") or 0),
            supply_used=int(hud.get("p2_supply_used") or 0),
            supply_cap=int(hud.get("p2_supply_cap") or 0),
            align_right=True,
            is_arena=is_arena,
        )

        # Center Clock & Match/Scenario Pill
        cx0 = (map_w - center_w) // 2
        ov.rounded_rectangle(
            [cx0, top_y, cx0 + center_w, top_y + card_h],
            radius=7,
            fill=(10, 15, 26, 212),
            outline=(*accent_rgb, 200),
            width=1,
        )
        # Accent top trim line
        ov.rounded_rectangle(
            [cx0 + 14, top_y + 1, cx0 + center_w - 14, top_y + 4],
            radius=2,
            fill=(*accent_rgb, 240),
        )
        f_clk = _get_font(16, bold=True)
        f_sub = _get_font(11, bold=True)
        clock_txt = str(hud.get("clock_text") or "00:00")
        center_lbl = _truncate_text(ov, str(hud.get("center_label") or ""), f_sub, center_w - 18)
        mid_x = map_w // 2
        if center_lbl:
            ov.text((mid_x, top_y + 17), clock_txt, fill=(248, 250, 252, 255), font=f_clk, anchor="mm")
            ov.text((mid_x, top_y + 35), center_lbl, fill=(*accent_rgb, 255), font=f_sub, anchor="mm")
        else:
            ov.text((mid_x, top_y + card_h // 2), clock_txt, fill=(248, 250, 252, 255), font=f_clk, anchor="mm")

        img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
        return img

    # 3. Legacy single-line top-left pill fallback
    if pill_text:
        font = _get_font(13, bold=True)
        overlay = Image.new("RGBA", (map_w, map_h), (0, 0, 0, 0))
        ov = ImageDraw.Draw(overlay)
        bbox = ov.textbbox((0, 0), pill_text, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        px0, py0 = 10, 10
        dot_space = 18
        pw = min(map_w - 24, tw + dot_space + 18)
        ph = max(26, th + 12)
        ov.rounded_rectangle(
            [px0, py0, px0 + pw, py0 + ph],
            radius=6,
            fill=(10, 15, 26, 178),
            outline=(*accent_rgb, 210),
            width=1,
        )
        cy = py0 + ph * 0.5
        ov.ellipse([px0 + 8, cy - 4, px0 + 16, cy + 4], fill=(*accent_rgb, 255))
        ov.text((px0 + dot_space + 4, cy), pill_text, fill=(241, 245, 249, 255), font=font, anchor="lm")
        img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")

    return img


# -----------------------------------------------------------------------------
# Streaming ffmpeg Video Encoders (H.264 MP4 + Animated WebP)
# -----------------------------------------------------------------------------
class MP4StreamEncoder:
    """Streaming RGB24 -> H.264 `.mp4` (`libx264 -preset veryfast -crf 24 -pix_fmt yuv420p -movflags +faststart`)."""

    def __init__(
        self,
        out_mp4: Path,
        in_w: int = 960,
        in_h: int = 720,
        out_w: int = 800,
        out_h: int = 600,
        fps: int = 16,
        crf: int = 24,
        preset: str = "veryfast",
    ) -> None:
        self.out_path = Path(out_mp4)
        self.out_mp4 = self.out_path
        self.out_path.parent.mkdir(parents=True, exist_ok=True)
        # Ensure even dimensions for yuv420p
        out_w = out_w - (out_w % 2)
        out_h = out_h - (out_h % 2)
        self.in_w = in_w
        self.in_h = in_h
        self.frame_count = 0
        self._last_raw: bytes | None = None

        cmd = [
            DEFAULT_FFMPEG,
            "-y",
            "-loglevel", "error",
            "-f", "rawvideo",
            "-pixel_format", "rgb24",
            "-video_size", f"{in_w}x{in_h}",
            "-framerate", str(fps),
            "-i", "pipe:0",
        ]
        if out_w != in_w or out_h != in_h:
            cmd += ["-vf", f"scale={out_w}:{out_h}:flags=lanczos"]
        cmd += [
            "-c:v", "libx264",
            "-preset", str(preset),
            "-crf", str(crf),
            "-pix_fmt", "yuv420p",
            "-movflags", "+faststart",
            "-an",
            str(self.out_path),
        ]
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )

    def write_frame(self, img: Image.Image) -> None:
        if img.mode != "RGB":
            img = img.convert("RGB")
        if img.size != (self.in_w, self.in_h):
            img = img.resize((self.in_w, self.in_h), Image.Resampling.BILINEAR)
        raw = img.tobytes()
        assert self._proc.stdin is not None
        self._proc.stdin.write(raw)
        self._last_raw = raw
        self.frame_count += 1

    def finish(self, hold_last_frames: int = 8) -> int:
        assert self._proc.stdin is not None
        try:
            if self._last_raw is not None and hold_last_frames > 0:
                for _ in range(hold_last_frames):
                    self._proc.stdin.write(self._last_raw)
        finally:
            self._proc.stdin.close()
        stderr = self._proc.stderr.read().decode("utf-8", errors="replace") if self._proc.stderr else ""
        rc = self._proc.wait(timeout=120)
        if rc != 0:
            raise RuntimeError(f"ffmpeg MP4 encode failed (rc={rc}): {stderr.strip()}")
        return self.out_path.stat().st_size if self.out_path.exists() else 0


class WebPStreamEncoder:
    def __init__(
        self,
        out_webp: Path,
        in_w: int = 960,
        in_h: int = 720,
        out_w: int = 800,
        out_h: int = 600,
        fps: int = 16,
        quality: int = 78,
        compression_level: int = 4,
    ) -> None:
        self.out_path = Path(out_webp)
        self.out_webp = self.out_path
        self.out_path.parent.mkdir(parents=True, exist_ok=True)
        self.in_w = in_w
        self.in_h = in_h
        self.frame_count = 0
        self._last_raw: bytes | None = None

        cmd = [
            DEFAULT_FFMPEG,
            "-y",
            "-loglevel", "error",
            "-f", "rawvideo",
            "-pixel_format", "rgb24",
            "-video_size", f"{in_w}x{in_h}",
            "-framerate", str(fps),
            "-i", "pipe:0",
        ]
        if out_w != in_w or out_h != in_h:
            cmd += ["-vf", f"scale={out_w}:{out_h}:flags=lanczos"]
        cmd += [
            "-vcodec", "libwebp",
            "-lossless", "0",
            "-compression_level", str(compression_level),
            "-q:v", str(quality),
            "-loop", "0",
            "-an",
            "-preset", "default",
            str(self.out_path),
        ]
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )

    def write_frame(self, img: Image.Image) -> None:
        if img.mode != "RGB":
            img = img.convert("RGB")
        if img.size != (self.in_w, self.in_h):
            img = img.resize((self.in_w, self.in_h), Image.Resampling.BILINEAR)
        raw = img.tobytes()
        assert self._proc.stdin is not None
        self._proc.stdin.write(raw)
        self._last_raw = raw
        self.frame_count += 1

    def finish(self, hold_last_frames: int = 8) -> int:
        assert self._proc.stdin is not None
        try:
            if self._last_raw is not None and hold_last_frames > 0:
                for _ in range(hold_last_frames):
                    self._proc.stdin.write(self._last_raw)
        finally:
            self._proc.stdin.close()
        stderr = self._proc.stderr.read().decode("utf-8", errors="replace") if self._proc.stderr else ""
        rc = self._proc.wait(timeout=90)
        if rc != 0:
            raise RuntimeError(f"ffmpeg WebP encode failed (rc={rc}): {stderr.strip()}")
        return self.out_path.stat().st_size if self.out_path.exists() else 0


def _make_stream_encoder(
    out_path: Path,
    video_format: str,
    in_w: int,
    in_h: int,
    out_w: int,
    out_h: int,
    fps: int,
    crf: int = 24,
) -> MP4StreamEncoder | WebPStreamEncoder:
    fmt = (video_format or "mp4").strip().lower()
    if fmt == "webp":
        return WebPStreamEncoder(out_path, in_w=in_w, in_h=in_h, out_w=out_w, out_h=out_h, fps=fps)
    return MP4StreamEncoder(out_path, in_w=in_w, in_h=in_h, out_w=out_w, out_h=out_h, fps=fps, crf=crf)


# -----------------------------------------------------------------------------
# Native Host SC2_x64 Instance Manager (Radeon EGL, bulletproof cleanup)
# -----------------------------------------------------------------------------
def _alloc_free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = int(s.getsockname()[1])
    s.close()
    return port


class HostSC2Session:
    """Async context manager launching one isolated native host SC2_x64 EGL instance."""

    def __init__(
        self,
        sc2_host_dir: Path = DEFAULT_SC2_HOST_DIR,
        egl_path: str = DEFAULT_EGL_PATH,
    ) -> None:
        self.sc2_host_dir = Path(sc2_host_dir)
        self.sc2_bin = self.sc2_host_dir / "Versions" / "Base75689" / "SC2_x64"
        self.egl_path = egl_path
        self.tmp_dir: Path | None = None
        self.proc: subprocess.Popen | None = None
        self.ws: Any = None
        self.port: int = 0

    async def __aenter__(self) -> "HostSC2Session":
        import websockets
        from s2clientprotocol import sc2api_pb2

        self.tmp_dir = Path(tempfile.mkdtemp(prefix="sc2_3d_render_"))
        for rel in ("Documents/StarCraft II", "StarCraftII"):
            d = self.tmp_dir / rel
            d.mkdir(parents=True, exist_ok=True)
            (d / "Variables.txt").write_text(VARIABLES_TXT, encoding="utf-8")
        sc2_tmp = self.tmp_dir / "sc2_tmp"
        sc2_tmp.mkdir(parents=True, exist_ok=True)

        self.port = _alloc_free_port()
        real_home = os.path.expanduser("~")
        env = os.environ.copy()
        env["HOME"] = str(self.tmp_dir)
        # Keep host Mesa shader cache warm across isolated SC2 launches!
        env.setdefault("XDG_CACHE_HOME", os.path.join(real_home, ".cache"))
        env.setdefault("MESA_SHADER_CACHE_DIR", os.path.join(real_home, ".cache", "mesa_shader_cache_db"))

        self.proc = subprocess.Popen(
            [
                str(self.sc2_bin),
                "-listen", "127.0.0.1",
                "-port", str(self.port),
                "-dataDir", str(self.sc2_host_dir),
                "-tempDir", str(sc2_tmp),
                "-eglpath", self.egl_path,
            ],
            cwd=str(self.sc2_host_dir),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        url = f"ws://127.0.0.1:{self.port}/sc2api"
        deadline = time.monotonic() + 30.0
        last_err: Exception | None = None
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"SC2_x64 exited early with code {self.proc.returncode}")
            try:
                self.ws = await websockets.connect(
                    url,
                    max_size=None,
                    ping_interval=None,
                    ping_timeout=None,
                )
                await self.rpc(sc2api_pb2.Request(ping=sc2api_pb2.RequestPing()))
                return self
            except Exception as exc:
                last_err = exc
                await asyncio.sleep(0.12)
        await self._cleanup()
        raise RuntimeError(f"SC2_x64 failed to accept WS on :{self.port}: {last_err}")

    async def rpc(self, req: Any, timeout: float = 60.0) -> Any:
        from s2clientprotocol import sc2api_pb2

        assert self.ws is not None
        await self.ws.send(req.SerializeToString())
        raw = await asyncio.wait_for(self.ws.recv(), timeout=timeout)
        resp = sc2api_pb2.Response()
        resp.ParseFromString(raw)
        return resp

    async def move_camera(self, x: float, y: float, distance: float = 0.0) -> None:
        from s2clientprotocol import common_pb2, sc2api_pb2

        await self.rpc(
            sc2api_pb2.Request(
                obs_action=sc2api_pb2.RequestObserverAction(
                    actions=[
                        sc2api_pb2.ObserverAction(
                            camera_move=sc2api_pb2.ActionObserverCameraMove(
                                world_pos=common_pb2.Point2D(x=float(x), y=float(y)),
                                distance=float(distance),
                            )
                        )
                    ]
                )
            )
        )

    async def _cleanup(self) -> None:
        from s2clientprotocol import sc2api_pb2

        if self.ws is not None:
            try:
                await asyncio.wait_for(
                    self.rpc(sc2api_pb2.Request(quit=sc2api_pb2.RequestQuit()), timeout=2.0),
                    timeout=2.5,
                )
            except Exception:
                pass
            try:
                await self.ws.close()
            except Exception:
                pass
            self.ws = None
        if self.proc is not None:
            try:
                if self.proc.poll() is None:
                    self.proc.terminate()
                    try:
                        self.proc.wait(timeout=3.0)
                    except subprocess.TimeoutExpired:
                        self.proc.kill()
                        self.proc.wait(timeout=3.0)
            except Exception:
                pass
            self.proc = None
        if self.tmp_dir is not None:
            shutil.rmtree(self.tmp_dir, ignore_errors=True)
            self.tmp_dir = None

    async def __aexit__(self, exc_type, exc, tb) -> None:
        await self._cleanup()


# -----------------------------------------------------------------------------
# Smart Combat Centroid, Spatial Clustering & Peak-Clash Scoring from Raw Units
# -----------------------------------------------------------------------------
def _best_spatial_centroid(
    pts: list[tuple[float, float, float]],
    radius: float = 20.0,
) -> tuple[tuple[float, float], float]:
    """
    Pick the highest-weight spatial cluster within `radius` tiles so split
    skirmishes on opposite sides of the map never average onto empty terrain.
    """
    r2 = radius * radius
    best_cluster = pts
    best_w = -1.0
    # Sample anchors cleanly when large
    anchors = pts if len(pts) <= 40 else pts[:: max(1, len(pts) // 40)]
    for ax, ay, _ in anchors:
        cl = [p for p in pts if (p[0] - ax) ** 2 + (p[1] - ay) ** 2 <= r2]
        cw = sum(p[2] for p in cl)
        if cw > best_w:
            best_w = cw
            best_cluster = cl
    sw = max(1e-6, sum(p[2] for p in best_cluster))
    cx = sum(p[0] * p[2] for p in best_cluster) / sw
    cy = sum(p[1] * p[2] for p in best_cluster) / sw
    return (cx, cy), best_w


def _extract_combat_state(
    obs: Any,
    prev_combat: dict[int, tuple[float, float, float]],
    focus_hint: tuple[float, float] | None = None,
    arena_bounds: tuple[float, float, float] | None = None,
) -> tuple[
    tuple[float, float] | None,
    float,
    dict[int, tuple[float, float, float]],
    dict[str, int],
]:
    """
    Inspect `obs.raw_data.units` (with observed_player_id=0, owner in {1, 2}):
      - Returns (battle_centroid, intensity_score, cur_combat_map, counts_dict).
      - If `arena_bounds=(cx, cy, radius)` is given, filters strictly to units inside
        the skirmish arena (ignoring home TownHalls in tactics duels!).
    """
    p1_c: list[Any] = []
    p2_c: list[Any] = []
    p1_all: list[Any] = []
    p2_all: list[Any] = []
    p1_th: list[Any] = []
    cur_combat: dict[int, tuple[float, float, float]] = {}

    for u in obs.raw_data.units:
        if u.owner not in (1, 2):
            continue
        ut = int(u.unit_type)
        if ut in IGNORE_IDS:
            continue
        ux, uy = float(u.pos.x), float(u.pos.y)
        if arena_bounds is not None:
            acx, acy, arad = arena_bounds
            if math.hypot(ux - acx, uy - acy) > arad:
                continue
        if u.owner == 1:
            p1_all.append(u)
            if ut in TOWNHALL_IDS:
                p1_th.append(u)
        else:
            p2_all.append(u)
        if ut in WORKER_IDS or ut in STRUCTURE_IDS:
            continue
        cur_combat[int(u.tag)] = (ux, uy, float(u.weapon_cooldown))
        if u.owner == 1:
            p1_c.append(u)
        else:
            p2_c.append(u)

    # Detect deaths and weapon fires since previous sampled frame
    deaths_pts: list[tuple[float, float]] = []
    firing_tags: set[int] = set()
    if prev_combat:
        for tag, (ox, oy, owcd) in prev_combat.items():
            if tag not in cur_combat:
                deaths_pts.append((ox, oy))
            else:
                if cur_combat[tag][2] > owcd + 1.2:
                    firing_tags.add(tag)

    # Active engaged pairs (units within 17 tiles of an enemy unit)
    engaged_pts: list[tuple[float, float, float]] = []
    p1_pool = p1_c if p1_c else p1_all
    p2_pool = p2_c if p2_c else p2_all

    if p1_pool and p2_pool:
        p1_s = p1_pool[:60]
        p2_s = p2_pool[:60]
        for u in p1_s:
            ux, uy = float(u.pos.x), float(u.pos.y)
            md = min(math.hypot(ux - float(e.pos.x), uy - float(e.pos.y)) for e in p2_s)
            if md <= 17.0:
                w = 3.0 if int(u.tag) in firing_tags else (2.2 if md <= 10.0 else 1.0)
                if focus_hint is not None and math.hypot(ux - focus_hint[0], uy - focus_hint[1]) <= 24.0:
                    w *= 3.0
                engaged_pts.append((ux, uy, w))
        for e in p2_s:
            ex, ey = float(e.pos.x), float(e.pos.y)
            md = min(math.hypot(ex - float(u.pos.x), ey - float(u.pos.y)) for u in p1_s)
            if md <= 17.0:
                w = 3.0 if int(e.tag) in firing_tags else (2.2 if md <= 10.0 else 1.0)
                if focus_hint is not None and math.hypot(ex - focus_hint[0], ey - focus_hint[1]) <= 24.0:
                    w *= 3.0
                engaged_pts.append((ex, ey, w))

    for dx, dy in deaths_pts:
        w = 4.0
        if focus_hint is not None and math.hypot(dx - focus_hint[0], dy - focus_hint[1]) <= 24.0:
            w *= 2.0
        engaged_pts.append((dx, dy, w))

    centroid: tuple[float, float] | None = None
    if engaged_pts:
        centroid, _ = _best_spatial_centroid(engaged_pts, radius=20.0)
    elif p1_c and p2_c:
        # Closest opposing pair midpoint
        best = min(
            ((math.hypot(float(u.pos.x) - float(e.pos.x), float(u.pos.y) - float(e.pos.y)), u, e)
             for u in p1_c[:30] for e in p2_c[:30]),
            key=lambda it: it[0],
        )
        centroid = (
            0.5 * (float(best[1].pos.x) + float(best[2].pos.x)),
            0.5 * (float(best[1].pos.y) + float(best[2].pos.y)),
        )
    elif focus_hint is not None:
        centroid = focus_hint
    elif p1_c:
        centroid = (sum(float(u.pos.x) for u in p1_c) / len(p1_c), sum(float(u.pos.y) for u in p1_c) / len(p1_c))
    elif p1_th:
        centroid = (float(p1_th[0].pos.x), float(p1_th[0].pos.y))
    elif p2_c:
        centroid = (sum(float(u.pos.x) for u in p2_c) / len(p2_c), sum(float(u.pos.y) for u in p2_c) / len(p2_c))
    elif p1_all:
        centroid = (sum(float(u.pos.x) for u in p1_all) / len(p1_all), sum(float(u.pos.y) for u in p1_all) / len(p1_all))

    intensity = (
        len(engaged_pts) * 1.5
        + len(firing_tags) * 3.0
        + len(deaths_pts) * 6.0
        + min(len(p1_c), len(p2_c)) * 0.4
    )
    counts = {
        "p1_combat": len(p1_c),
        "p2_combat": len(p2_c),
        "deaths": len(deaths_pts),
        "firing": len(firing_tags),
        "engaged": len(engaged_pts),
    }
    return centroid, intensity, cur_combat, counts


def _smooth_camera_step(
    cur_cam: tuple[float, float] | None,
    target: tuple[float, float] | None,
    alpha: float = 0.24,
    max_step_tiles: float = 2.0,
) -> tuple[float, float] | None:
    if target is None:
        return cur_cam
    if cur_cam is None:
        return target
    dx = (target[0] - cur_cam[0]) * alpha
    dy = (target[1] - cur_cam[1]) * alpha
    dist = math.hypot(dx, dy)
    if dist > max_step_tiles:
        s = max_step_tiles / dist
        dx *= s
        dy *= s
    return (cur_cam[0] + dx, cur_cam[1] + dy)


def _find_map_path(replay_path: Path, maps_dir: Path, explicit_map: Path | None = None) -> Path:
    if explicit_map is not None and explicit_map.exists():
        return explicit_map
    stem = replay_path.stem
    candidates = sorted(maps_dir.glob("*.SC2Map"), key=lambda p: -len(p.stem))
    for mp in candidates:
        if mp.stem.lower() in stem.lower():
            return mp
    raise FileNotFoundError(f"Could not find matching .SC2Map in {maps_dir} for replay {replay_path.name}")


# -----------------------------------------------------------------------------
# 1. KEY-MOMENT FULL REPLAY 3D HIGHLIGHT CLIP RENDERER
# -----------------------------------------------------------------------------
async def render_replay_clip(
    replay_path: str | Path,
    out_webp: str | Path | None = None,
    out_png: str | Path = "",
    start_loop: int = 32,
    num_frames: int = 160,
    step: int = 3,
    fps: int = 16,
    render_size: tuple[int, int] = (960, 720),
    minimap_size: tuple[int, int] = (180, 180),
    webp_size: tuple[int, int] = (800, 600),
    map_path: str | Path | None = None,
    maps_dir: str | Path = DEFAULT_MAPS_DIR,
    title: str = "",
    subtitle_metric: str = "",
    focus_hint: tuple[float, float] | None = None,
    accent_rgb: tuple[int, int, int] = (56, 189, 248),
    camera_distance: float = 0.0,
    sc2_host_dir: Path = DEFAULT_SC2_HOST_DIR,
    video_format: str = "mp4",
    out_video: str | Path | None = None,
    p1_name: str | None = None,
    p2_name: str | None = None,
    p1_race: str | None = None,
    p2_race: str | None = None,
    p1_color: tuple[int, int, int] | None = None,
    p2_color: tuple[int, int, int] | None = None,
) -> dict[str, Any]:
    """Render one real-3D SC2 key-moment highlight clip -> H.264 `.mp4` (or WebP) + 960x720 Peak-Clash PNG."""
    from s2clientprotocol import common_pb2, sc2api_pb2

    t0 = time.monotonic()
    rep_p = Path(replay_path)
    mp_p = _find_map_path(rep_p, Path(maps_dir), Path(map_path) if map_path else None)
    ren_w, ren_h = render_size
    mm_w, mm_h = minimap_size

    v_raw = out_video if out_video is not None else out_webp
    if v_raw is None:
        raise ValueError("Provide out_video or out_webp path")
    out_vid_p = Path(v_raw)
    vfmt = (video_format or ("webp" if out_vid_p.suffix.lower() == ".webp" else "mp4")).strip().lower()
    if vfmt == "mp4" and out_vid_p.suffix.lower() == ".webp":
        out_vid_p = out_vid_p.with_suffix(".mp4")

    players = extract_replay_players(rep_p)
    p1_meta = {
        "name": p1_name or players[1]["name"],
        "race": p1_race or players[1]["race"],
        "color": p1_color or players[1]["color"],
    }
    p2_meta = {
        "name": p2_name or players[2]["name"],
        "race": p2_race or players[2]["race"],
        "color": p2_color or players[2]["color"],
    }
    center_lbl = " · ".join(p for p in (title, subtitle_metric) if p)

    async with HostSC2Session(sc2_host_dir=sc2_host_dir) as sc2:
        opts = sc2api_pb2.InterfaceOptions(
            raw=True,
            score=True,
            show_cloaked=True,
            show_burrowed_shadows=True,
            show_placeholders=True,
            render=sc2api_pb2.SpatialCameraSetup(
                resolution=common_pb2.Size2DI(x=ren_w, y=ren_h),
                minimap_resolution=common_pb2.Size2DI(x=mm_w, y=mm_h),
            ),
        )
        sr = await sc2.rpc(
            sc2api_pb2.Request(
                start_replay=sc2api_pb2.RequestStartReplay(
                    replay_data=rep_p.read_bytes(),
                    map_data=mp_p.read_bytes(),
                    observed_player_id=0,
                    disable_fog=True,
                    options=opts,
                )
            ),
            timeout=90.0,
        )
        if sr.start_replay.error != 1:
            raise RuntimeError(
                f"StartReplay failed for {rep_p.name}: err={sr.start_replay.error} {sr.start_replay.error_details}"
            )

        # Fast-forward in bounded chunks so 30-minute replays never hit single-RPC timeout
        ff_rem = max(16, int(start_loop) - 8)
        while ff_rem > 0:
            chunk = min(4000, ff_rem)
            step_r = await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=chunk)), timeout=180.0)
            ff_rem -= chunk
            if step_r.status != sc2api_pb2.in_replay:
                break

        obs_r = await sc2.rpc(
            sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation(disable_fog=True)),
            timeout=180.0,
        )
        obs = obs_r.observation.observation
        cur_cam, _, prev_combat, _ = _extract_combat_state(obs, {}, focus_hint=focus_hint)
        if cur_cam is not None:
            await sc2.move_camera(cur_cam[0], cur_cam[1], distance=camera_distance)
        await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=8)))

        encoder = _make_stream_encoder(
            out_vid_p,
            video_format=vfmt,
            in_w=ren_w,
            in_h=ren_h,
            out_w=webp_size[0],
            out_h=webp_size[1],
            fps=fps,
        )

        peak_img: Image.Image | None = None
        fallback_img: Image.Image | None = None
        peak_score = -1.0
        peak_loop = int(start_loop)
        peak_idx = 0
        first_loop = -1
        last_loop = -1
        frames_captured = 0
        t_cap0 = time.monotonic()

        for fi in range(num_frames):
            obs_r = await sc2.rpc(sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation(disable_fog=True)))
            obs = obs_r.observation.observation
            gl = int(obs.game_loop)
            if first_loop < 0:
                first_loop = gl
            last_loop = gl

            centroid, intensity, prev_combat, _ = _extract_combat_state(obs, prev_combat, focus_hint=focus_hint)
            cur_cam = _smooth_camera_step(cur_cam, centroid, alpha=0.26, max_step_tiles=2.4)

            rd = obs.render_data
            if rd.map.data:
                hud_stats = extract_frame_hud_stats(obs)
                hud = {
                    "p1_name": p1_meta["name"],
                    "p1_race": p1_meta["race"],
                    "p1_color": p1_meta["color"],
                    "p2_name": p2_meta["name"],
                    "p2_race": p2_meta["race"],
                    "p2_color": p2_meta["color"],
                    "clock_text": fmt_clock(gl),
                    "center_label": center_lbl,
                    "is_arena": False,
                    **hud_stats,
                }
                frame_img = compose_3d_frame(
                    rd.map.data,
                    rd.map.size.x,
                    rd.map.size.y,
                    rd.minimap.data if rd.minimap.data else None,
                    rd.minimap.size.x,
                    rd.minimap.size.y,
                    accent_rgb=accent_rgb,
                    minimap_display_size=160,
                    include_minimap=True,
                    hud=hud,
                )
                encoder.write_frame(frame_img)
                frames_captured += 1

                if fallback_img is None:
                    fallback_img = frame_img
                is_mid = (fi >= 3 and fi <= max(3, num_frames - 4))
                if is_mid and intensity > peak_score:
                    peak_score = intensity
                    peak_img = frame_img
                    peak_loop = gl
                    peak_idx = fi

            if obs_r.status != sc2api_pb2.in_replay:
                break
            if cur_cam is not None:
                await sc2.move_camera(cur_cam[0], cur_cam[1], distance=camera_distance)
            step_r = await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=step)))
            if step_r.status != sc2api_pb2.in_replay:
                break

        cap_sec = max(0.001, time.monotonic() - t_cap0)
        video_bytes = encoder.finish(hold_last_frames=8)

        out_png_p = Path(out_png)
        out_png_p.parent.mkdir(parents=True, exist_ok=True)
        final_png_img = peak_img if peak_img is not None else fallback_img
        if final_png_img is not None:
            final_png_img.save(str(out_png_p), format="PNG", optimize=True)
        png_bytes = out_png_p.stat().st_size if out_png_p.exists() else 0

        return {
            "replay": str(rep_p),
            "map": mp_p.name,
            "video": str(out_vid_p),
            "video_format": vfmt,
            "mp4": str(out_vid_p) if vfmt == "mp4" else None,
            "webp": str(out_vid_p) if vfmt == "webp" else None,
            "png": str(out_png_p),
            "frames": frames_captured,
            "start_loop": first_loop,
            "end_loop": last_loop,
            "peak_loop": peak_loop,
            "peak_frame_idx": peak_idx,
            "clock_window": f"{fmt_clock(max(0, first_loop))}–{fmt_clock(max(0, last_loop))}",
            "video_bytes": video_bytes,
            "mp4_bytes": video_bytes if vfmt == "mp4" else 0,
            "webp_bytes": video_bytes if vfmt == "webp" else 0,
            "png_bytes": png_bytes,
            "p1_name": p1_meta["name"],
            "p1_race": p1_meta["race"],
            "p1_color": list(p1_meta["color"]),
            "p2_name": p2_meta["name"],
            "p2_race": p2_meta["race"],
            "p2_color": list(p2_meta["color"]),
            "render_fps": round(frames_captured / cap_sec, 1),
            "wall_sec": round(time.monotonic() - t0, 2),
        }


def render_replay_clip_sync(**kwargs: Any) -> dict[str, Any]:
    return asyncio.run(render_replay_clip(**kwargs))


# -----------------------------------------------------------------------------
# 2. FULL-LENGTH 00:00 -> GG MATCH VIDEO RENDERER (Smart Observer Camera)
# -----------------------------------------------------------------------------
async def render_full_match_video(
    replay_path: str | Path,
    out_mp4: str | Path,
    out_png: str | Path,
    step: int = 20,
    fps: int = 16,
    render_size: tuple[int, int] = (960, 720),
    minimap_size: tuple[int, int] = (180, 180),
    video_size: tuple[int, int] = (800, 600),
    map_path: str | Path | None = None,
    maps_dir: str | Path = DEFAULT_MAPS_DIR,
    title: str = "",
    subtitle_metric: str = "",
    accent_rgb: tuple[int, int, int] = (56, 189, 248),
    camera_distance: float = 0.0,
    max_frames: int = 2400,
    crf: int = 24,
    sc2_host_dir: Path = DEFAULT_SC2_HOST_DIR,
    p1_name: str | None = None,
    p2_name: str | None = None,
    p1_race: str | None = None,
    p2_race: str | None = None,
    p1_color: tuple[int, int, int] | None = None,
    p2_color: tuple[int, int, int] | None = None,
) -> dict[str, Any]:
    """
    Render an entire match from `00:00 -> GG` in real-3D observer mode (`step=20`,
    `fps=16` -> ~14.3x smooth observer timelapse, ~35–60s video, ~3–6 MB H.264 `.mp4`)
    with live SC2 Replay-Viewer Top HUD + Peak-Clash `960x720` `.png` poster.
    """
    from s2clientprotocol import common_pb2, sc2api_pb2

    t0 = time.monotonic()
    rep_p = Path(replay_path)
    mp_p = _find_map_path(rep_p, Path(maps_dir), Path(map_path) if map_path else None)
    ren_w, ren_h = render_size
    mm_w, mm_h = minimap_size
    out_vid_p = Path(out_mp4)
    out_png_p = Path(out_png)

    players = extract_replay_players(rep_p)
    p1_meta = {
        "name": p1_name or players[1]["name"],
        "race": p1_race or players[1]["race"],
        "color": p1_color or players[1]["color"],
    }
    p2_meta = {
        "name": p2_name or players[2]["name"],
        "race": p2_race or players[2]["race"],
        "color": p2_color or players[2]["color"],
    }
    center_lbl = " · ".join(p for p in (title, subtitle_metric) if p)

    async with HostSC2Session(sc2_host_dir=sc2_host_dir) as sc2:
        opts = sc2api_pb2.InterfaceOptions(
            raw=True,
            score=True,
            show_cloaked=True,
            show_burrowed_shadows=True,
            show_placeholders=True,
            render=sc2api_pb2.SpatialCameraSetup(
                resolution=common_pb2.Size2DI(x=ren_w, y=ren_h),
                minimap_resolution=common_pb2.Size2DI(x=mm_w, y=mm_h),
            ),
        )
        sr = await sc2.rpc(
            sc2api_pb2.Request(
                start_replay=sc2api_pb2.RequestStartReplay(
                    replay_data=rep_p.read_bytes(),
                    map_data=mp_p.read_bytes(),
                    observed_player_id=0,
                    disable_fog=True,
                    options=opts,
                )
            ),
            timeout=90.0,
        )
        if sr.start_replay.error != 1:
            raise RuntimeError(
                f"Full-match StartReplay failed for {rep_p.name}: err={sr.start_replay.error} {sr.start_replay.error_details}"
            )

        # Initial observation at loop 0 -> snap camera cleanly onto P1 main base
        obs_r = await sc2.rpc(sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation(disable_fog=True)))
        obs = obs_r.observation.observation
        cur_cam, _, prev_combat, _ = _extract_combat_state(obs, {})
        if cur_cam is not None:
            await sc2.move_camera(cur_cam[0], cur_cam[1], distance=camera_distance)
            await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=4)))

        encoder = MP4StreamEncoder(
            out_vid_p,
            in_w=ren_w,
            in_h=ren_h,
            out_w=video_size[0],
            out_h=video_size[1],
            fps=fps,
            crf=crf,
        )

        peak_img: Image.Image | None = None
        fallback_img: Image.Image | None = None
        peak_score = -1.0
        peak_loop = 0
        peak_idx = 0
        first_loop = -1
        last_loop = 0
        frames_captured = 0
        active_focus: tuple[float, float] | None = cur_cam
        focus_hold_frames = 0
        t_cap0 = time.monotonic()

        for fi in range(max_frames):
            obs_r = await sc2.rpc(sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation(disable_fog=True)))
            obs = obs_r.observation.observation
            gl = int(obs.game_loop)
            if first_loop < 0:
                first_loop = gl
            last_loop = gl

            centroid, intensity, prev_combat, counts = _extract_combat_state(obs, prev_combat)
            # Smart observer camera with anti-whiplash hysteresis
            if centroid is not None:
                if active_focus is None:
                    active_focus = centroid
                else:
                    jump_d = math.hypot(centroid[0] - active_focus[0], centroid[1] - active_focus[1])
                    if jump_d <= 22.0:
                        active_focus = centroid
                    elif counts["engaged"] >= 4 or counts["deaths"] >= 2 or focus_hold_frames >= 12:
                        active_focus = centroid
                        focus_hold_frames = 0
                    else:
                        focus_hold_frames += 1
            cur_cam = _smooth_camera_step(cur_cam, active_focus, alpha=0.30, max_step_tiles=4.8)

            rd = obs.render_data
            if rd.map.data:
                hud_stats = extract_frame_hud_stats(obs)
                hud = {
                    "p1_name": p1_meta["name"],
                    "p1_race": p1_meta["race"],
                    "p1_color": p1_meta["color"],
                    "p2_name": p2_meta["name"],
                    "p2_race": p2_meta["race"],
                    "p2_color": p2_meta["color"],
                    "clock_text": fmt_clock(gl),
                    "center_label": center_lbl,
                    "is_arena": False,
                    **hud_stats,
                }
                frame_img = compose_3d_frame(
                    rd.map.data,
                    rd.map.size.x,
                    rd.map.size.y,
                    rd.minimap.data if rd.minimap.data else None,
                    rd.minimap.size.x,
                    rd.minimap.size.y,
                    accent_rgb=accent_rgb,
                    minimap_display_size=160,
                    include_minimap=True,
                    hud=hud,
                )
                encoder.write_frame(frame_img)
                frames_captured += 1

                if fallback_img is None:
                    fallback_img = frame_img
                # Capture peak-clash poster after opening 30s
                if gl >= 672 and intensity > peak_score:
                    peak_score = intensity
                    peak_img = frame_img
                    peak_loop = gl
                    peak_idx = fi

            if obs_r.status != sc2api_pb2.in_replay:
                break
            if cur_cam is not None:
                await sc2.move_camera(cur_cam[0], cur_cam[1], distance=camera_distance)
            step_r = await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=step)))
            if step_r.status != sc2api_pb2.in_replay:
                break

        cap_sec = max(0.001, time.monotonic() - t_cap0)
        video_bytes = encoder.finish(hold_last_frames=12)

        out_png_p.parent.mkdir(parents=True, exist_ok=True)
        final_png_img = peak_img if peak_img is not None else fallback_img
        if final_png_img is not None:
            final_png_img.save(str(out_png_p), format="PNG", optimize=True)
        png_bytes = out_png_p.stat().st_size if out_png_p.exists() else 0

        return {
            "replay": str(rep_p),
            "map": mp_p.name,
            "video": str(out_vid_p),
            "video_format": "mp4",
            "mp4": str(out_vid_p),
            "webp": None,
            "png": str(out_png_p),
            "frames": frames_captured,
            "fps": fps,
            "step": step,
            "start_loop": max(0, first_loop),
            "end_loop": last_loop,
            "peak_loop": peak_loop,
            "peak_frame_idx": peak_idx,
            "clock_window": f"{fmt_clock(max(0, first_loop))}–{fmt_clock(max(0, last_loop))}",
            "video_bytes": video_bytes,
            "mp4_bytes": video_bytes,
            "webp_bytes": 0,
            "png_bytes": png_bytes,
            "p1_name": p1_meta["name"],
            "p1_race": p1_meta["race"],
            "p1_color": list(p1_meta["color"]),
            "p2_name": p2_meta["name"],
            "p2_race": p2_meta["race"],
            "p2_color": list(p2_meta["color"]),
            "render_fps": round(frames_captured / cap_sec, 1),
            "wall_sec": round(time.monotonic() - t0, 2),
        }


def render_full_match_video_sync(**kwargs: Any) -> dict[str, Any]:
    return asyncio.run(render_full_match_video(**kwargs))


# -----------------------------------------------------------------------------
# 3. ALL TACTICS ARENA PARALLEL 3D RENDERER (Full-Length Zero-Truncation MP4)
# -----------------------------------------------------------------------------
async def _render_single_race_arena_replay(
    race_spec: dict[str, Any],
    out_dir: Path,
    step: int = 2,
    fps: int = 16,
    render_size: tuple[int, int] = (960, 720),
    minimap_size: tuple[int, int] = (180, 180),
    webp_size: tuple[int, int] = (800, 600),
    max_frames_per_duel: int = 480,
    sc2_host_dir: Path = DEFAULT_SC2_HOST_DIR,
    video_format: str = "mp4",
    p1_name: str | None = None,
    p2_name: str | None = None,
    p1_color: tuple[int, int, int] = DEFAULT_P1_COLOR,
    p2_color: tuple[int, int, int] = DEFAULT_P2_COLOR,
) -> list[dict[str, Any]]:
    """Open ONE race's arena_<race>.SC2Replay and linearly render all its duels in 3D."""
    from s2clientprotocol import common_pb2, sc2api_pb2

    rep_path_raw = race_spec.get("replay_path")
    rep_bytes = race_spec.get("replay_bytes")
    if rep_bytes is None:
        rep_p = Path(rep_path_raw)
        rep_bytes = rep_p.read_bytes()
        rep_name = rep_p.name
    else:
        rep_name = Path(rep_path_raw).name if rep_path_raw else f"arena_{race_spec.get('race', 'x')}.SC2Replay"

    # Read actual in-game team colors from arena replay.details if present
    rep_players = extract_replay_players(
        rep_bytes,
        fallback_p1=(p1_name or "Mothman", "", p1_color),
        fallback_p2=(p2_name or "MicroDummy", "", p2_color),
    )

    raw_map = race_spec.get("map_path") or race_spec.get("map") or "AcropolisAIE.SC2Map"
    mp_p = Path(raw_map)
    if not mp_p.exists():
        mp_p = DEFAULT_MAPS_DIR / mp_p.name
    duels = sorted(
        race_spec.get("duels") or race_spec.get("scenarios") or [],
        key=lambda d: int(d.get("start_loop") or 0),
    )
    if not duels:
        return []

    vfmt = (video_format or "mp4").strip().lower()
    ext = ".webp" if vfmt == "webp" else ".mp4"
    ren_w, ren_h = render_size
    mm_w, mm_h = minimap_size
    out_dir.mkdir(parents=True, exist_ok=True)
    rendered: list[dict[str, Any]] = []

    async with HostSC2Session(sc2_host_dir=sc2_host_dir) as sc2:
        opts = sc2api_pb2.InterfaceOptions(
            raw=True,
            score=True,
            show_cloaked=True,
            show_burrowed_shadows=True,
            show_placeholders=True,
            render=sc2api_pb2.SpatialCameraSetup(
                resolution=common_pb2.Size2DI(x=ren_w, y=ren_h),
                minimap_resolution=common_pb2.Size2DI(x=mm_w, y=mm_h),
            ),
        )
        sr = await sc2.rpc(
            sc2api_pb2.Request(
                start_replay=sc2api_pb2.RequestStartReplay(
                    replay_data=rep_bytes,
                    map_data=mp_p.read_bytes(),
                    observed_player_id=0,
                    disable_fog=True,
                    options=opts,
                )
            ),
            timeout=90.0,
        )
        if sr.start_replay.error != 1:
            raise RuntimeError(
                f"Arena StartReplay failed for {rep_name}: err={sr.start_replay.error} {sr.start_replay.error_details}"
            )

        cur_loop = 0
        replay_alive = True

        for d in duels:
            if not replay_alive:
                break
            t_d0 = time.monotonic()
            duel_id = str(d["id"])
            short_id = duel_id.replace("sc2-real-", "").replace("sc2-econ-", "").replace("sc2-reg-", "")
            s_loop = max(16, int(d.get("start_loop") or 16))
            e_loop = max(s_loop + 16, int(d.get("end_loop") or (s_loop + 160)))
            acx = float(d.get("arena_cx") or 88.0)
            acy = float(d.get("arena_cy") or 88.0)
            winner = str(d.get("winner") or "Timeout")
            trade = d.get("trade_ratio")
            trade_s = f"{float(trade):.2f}x" if trade is not None else "-"
            accent = (
                (34, 197, 94)
                if winner in ("Mothman", "Mothman-P1")
                else ((239, 68, 68) if winner in ("MicroDummy", "Mothman-P2") else (245, 158, 11))
            )

            d_race = str(d.get("race") or str(race_spec.get("race") or "").split("_")[0] or rep_players[1]["race"])
            d_erace = str(d.get("enemy_race") or rep_players[2]["race"])
            opp_mode = str(d.get("opponent_mode") or "dummy")
            d_p1_name = str(d.get("p1_name") or d.get("bot") or p1_name or race_spec.get("p1_name") or f"Mothman-{_race_short(d_race)}")
            d_p2_name = str(
                d.get("p2_name")
                or d.get("p2_bot")
                or p2_name
                or race_spec.get("p2_name")
                or (f"Mothman-{_race_short(d_erace)}-SP" if opp_mode == "self" else "MicroDummy")
            )
            d_p1_col = tuple(d.get("p1_color") or race_spec.get("p1_color") or p1_color or rep_players[1]["color"])
            d_p2_col = tuple(d.get("p2_color") or race_spec.get("p2_color") or p2_color or rep_players[2]["color"])

            # Start slightly BEFORE s_loop (`s_loop - 8`) so viewer sees spawn & initial formation!
            target_start = max(cur_loop, max(0, s_loop - 8))
            if target_start > cur_loop:
                delta = target_start - cur_loop
                step_r = await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=delta)), timeout=90.0)
                cur_loop += delta
                if step_r.status != sc2api_pb2.in_replay:
                    replay_alive = False
                    break

            # Snap camera cleanly onto arena center
            await sc2.move_camera(acx, acy, distance=0.0)
            step_r = await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=2)))
            cur_loop += 2
            if step_r.status != sc2api_pb2.in_replay:
                replay_alive = False
                break

            # Zero-truncation full-duel pacing (max_frames_per_duel=480 covers full 960 loops @ step=2!)
            span_loops = max(8, e_loop - cur_loop)
            duel_step = max(step, int(math.ceil(span_loops / max(1, max_frames_per_duel))))

            out_vid = out_dir / f"{duel_id}{ext}"
            out_png = out_dir / f"{duel_id}.png"
            encoder = _make_stream_encoder(
                out_vid,
                video_format=vfmt,
                in_w=ren_w,
                in_h=ren_h,
                out_w=webp_size[0],
                out_h=webp_size[1],
                fps=fps,
            )

            cur_cam: tuple[float, float] | None = (acx, acy)
            prev_combat: dict[int, tuple[float, float, float]] = {}
            peak_img: Image.Image | None = None
            peak_score = -1.0
            peak_loop = cur_loop
            peak_idx = 0
            frames_captured = 0
            arena_bounds = (acx, acy, 34.0)
            fi = 0

            while cur_loop <= e_loop and frames_captured < max_frames_per_duel + 8:
                obs_r = await sc2.rpc(sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation(disable_fog=True)))
                obs = obs_r.observation.observation
                cur_loop = int(obs.game_loop)

                centroid, intensity, prev_combat, counts = _extract_combat_state(
                    obs, prev_combat, focus_hint=(acx, acy), arena_bounds=arena_bounds
                )
                cur_cam = _smooth_camera_step(cur_cam, centroid, alpha=0.20, max_step_tiles=1.5)

                rd = obs.render_data
                if rd.map.data:
                    rel_s = max(0.0, (cur_loop - s_loop) / 22.4)
                    hud_stats = extract_frame_hud_stats(obs)
                    hud = {
                        "p1_name": d_p1_name,
                        "p1_race": d_race,
                        "p1_color": d_p1_col,
                        "p2_name": d_p2_name,
                        "p2_race": d_erace,
                        "p2_color": d_p2_col,
                        "clock_text": f"{rel_s:4.1f}s",
                        "center_label": f"{short_id[:20]} · {winner} {trade_s}",
                        "is_arena": True,
                        **hud_stats,
                    }
                    frame_img = compose_3d_frame(
                        rd.map.data,
                        rd.map.size.x,
                        rd.map.size.y,
                        rd.minimap.data if rd.minimap.data else None,
                        rd.minimap.size.x,
                        rd.minimap.size.y,
                        accent_rgb=accent,
                        minimap_display_size=148,
                        include_minimap=True,
                        hud=hud,
                    )
                    encoder.write_frame(frame_img)
                    frames_captured += 1
                    both_alive = (counts["p1_combat"] > 0 and counts["p2_combat"] > 0)
                    eff_score = intensity + (25.0 if both_alive else 0.0)
                    if peak_img is None or (fi >= 2 and eff_score > peak_score):
                        peak_score = eff_score
                        peak_img = frame_img
                        peak_loop = cur_loop
                        peak_idx = fi

                fi += 1
                if obs_r.status != sc2api_pb2.in_replay or cur_loop >= e_loop:
                    if obs_r.status != sc2api_pb2.in_replay:
                        replay_alive = False
                    break

                if cur_cam is not None:
                    await sc2.move_camera(cur_cam[0], cur_cam[1], distance=0.0)
                next_step = min(duel_step, max(1, e_loop - cur_loop))
                step_r = await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=next_step)))
                cur_loop += next_step
                if step_r.status != sc2api_pb2.in_replay:
                    replay_alive = False
                    break

            video_bytes = encoder.finish(hold_last_frames=8)
            if peak_img is not None:
                peak_img.save(str(out_png), format="PNG", optimize=True)
            png_bytes = out_png.stat().st_size if out_png.exists() else 0

            rendered.append({
                "id": duel_id,
                "tier": d.get("tier") or "canonical",
                "scoring_mode": d.get("scoring_mode") or "combat",
                "race": d_race,
                "bot": d.get("bot") or d_p1_name,
                "p1_name": d_p1_name,
                "p2_bot": d.get("p2_bot") or d_p2_name,
                "p2_name": d_p2_name,
                "p1_color": list(d_p1_col),
                "p2_color": list(d_p2_col),
                "opponent_mode": opp_mode,
                "enemy_race": d_erace,
                "terrain": d.get("terrain") or "open",
                "source": d.get("source") or "core",
                "winner": winner,
                "win_type": d.get("win_type"),
                "trade_ratio": trade,
                "p2_trade_ratio": d.get("p2_trade_ratio"),
                "description": d.get("description") or "",
                "context": d.get("context") or d.get("description") or "",
                "p1_spec": d.get("p1_spec") or "",
                "p2_spec": d.get("p2_spec") or "",
                "mothman_attack_unit_cmds": d.get("mothman_attack_unit_cmds"),
                "mothman_move_unit_cmds": d.get("mothman_move_unit_cmds"),
                "mothman_spell_unit_cmds": d.get("mothman_spell_unit_cmds"),
                "p2_attack_unit_cmds": d.get("p2_attack_unit_cmds"),
                "p2_move_unit_cmds": d.get("p2_move_unit_cmds"),
                "p2_spell_unit_cmds": d.get("p2_spell_unit_cmds"),
                "applied_p1_upgrade_ids": d.get("applied_p1_upgrade_ids") or [],
                "applied_p2_upgrade_ids": d.get("applied_p2_upgrade_ids") or [],
                "video": str(out_vid),
                "video_format": vfmt,
                "mp4": str(out_vid) if vfmt == "mp4" else None,
                "webp": str(out_vid) if vfmt == "webp" else None,
                "png": str(out_png),
                "frames": frames_captured,
                "start_loop": s_loop,
                "end_loop": e_loop,
                "peak_loop": peak_loop,
                "peak_frame_idx": peak_idx,
                "video_bytes": video_bytes,
                "mp4_bytes": video_bytes if vfmt == "mp4" else 0,
                "webp_bytes": video_bytes if vfmt == "webp" else 0,
                "png_bytes": png_bytes,
                "wall_sec": round(time.monotonic() - t_d0, 2),
            })

    return rendered


def _race_worker_entry(args_tuple: tuple[Any, ...]) -> list[dict[str, Any]]:
    (
        race_spec,
        out_dir_str,
        step,
        fps,
        render_size,
        minimap_size,
        webp_size,
        max_frames_per_duel,
        sc2_host_dir_str,
        video_format,
        p1_name,
        p2_name,
        p1_color,
        p2_color,
    ) = args_tuple
    return asyncio.run(
        _render_single_race_arena_replay(
            race_spec=race_spec,
            out_dir=Path(out_dir_str),
            step=step,
            fps=fps,
            render_size=render_size,
            minimap_size=minimap_size,
            webp_size=webp_size,
            max_frames_per_duel=max_frames_per_duel,
            sc2_host_dir=Path(sc2_host_dir_str),
            video_format=video_format,
            p1_name=p1_name,
            p2_name=p2_name,
            p1_color=tuple(p1_color),
            p2_color=tuple(p2_color),
        )
    )


def render_arena_replays_parallel(
    race_specs: list[dict[str, Any]],
    out_dir: str | Path,
    step: int = 2,
    fps: int = 16,
    render_size: tuple[int, int] = (960, 720),
    minimap_size: tuple[int, int] = (180, 180),
    webp_size: tuple[int, int] = (800, 600),
    max_frames_per_duel: int = 480,
    workers: int = 3,
    sc2_host_dir: str | Path = DEFAULT_SC2_HOST_DIR,
    video_format: str = "mp4",
    p1_name: str | None = None,
    p2_name: str | None = None,
    p1_color: tuple[int, int, int] = DEFAULT_P1_COLOR,
    p2_color: tuple[int, int, int] = DEFAULT_P2_COLOR,
) -> dict[str, Any]:
    """
    Render ALL tactics-arena race replays in parallel (host SC2_x64 instances on
    Radeon 8060S), returning the complete manifest dict and writing `arena_manifest.json`.
    """
    t0 = time.monotonic()
    out_p = Path(out_dir)
    out_p.mkdir(parents=True, exist_ok=True)
    vfmt = (video_format or "mp4").strip().lower()
    jobs = [
        (
            rs,
            str(out_p),
            step,
            fps,
            render_size,
            minimap_size,
            webp_size,
            max_frames_per_duel,
            str(sc2_host_dir),
            vfmt,
            p1_name,
            p2_name,
            p1_color,
            p2_color,
        )
        for rs in race_specs
        if (rs.get("duels") or rs.get("scenarios")) and (rs.get("replay_path") or rs.get("replay_bytes"))
    ]
    all_clips: list[dict[str, Any]] = []
    if len(jobs) == 1 or workers <= 1:
        for j in jobs:
            all_clips.extend(_race_worker_entry(j))
    else:
        with concurrent.futures.ProcessPoolExecutor(max_workers=min(workers, len(jobs))) as ex:
            futs = [ex.submit(_race_worker_entry, j) for j in jobs]
            for f in futs:
                all_clips.extend(f.result())

    all_clips.sort(key=lambda c: c["id"])
    total_video_bytes = sum(c.get("video_bytes", 0) for c in all_clips)
    total_mp4_bytes = sum(c.get("mp4_bytes", 0) for c in all_clips)
    total_webp_bytes = sum(c.get("webp_bytes", 0) for c in all_clips)
    total_png_bytes = sum(c.get("png_bytes", 0) for c in all_clips)
    manifest = {
        "kind": "arena_3d_visuals",
        "video_format": vfmt,
        "render_size": list(render_size),
        "video_size": list(webp_size),
        "webp_size": list(webp_size),
        "fps": fps,
        "step": step,
        "max_frames_per_duel": max_frames_per_duel,
        "clips_count": len(all_clips),
        "total_video_bytes": total_video_bytes,
        "total_mp4_bytes": total_mp4_bytes,
        "total_webp_bytes": total_webp_bytes,
        "total_png_bytes": total_png_bytes,
        "wall_sec": round(time.monotonic() - t0, 2),
        "clips": all_clips,
    }
    manifest_path = out_p / "arena_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    print(
        f"sc2_3d_renderer.py OK | SC2_BIN={DEFAULT_SC2_HOST_DIR / 'Versions/Base75689/SC2_x64'} "
        f"| exists={(DEFAULT_SC2_HOST_DIR / 'Versions/Base75689/SC2_x64').exists()} | ffmpeg={DEFAULT_FFMPEG}"
    )
