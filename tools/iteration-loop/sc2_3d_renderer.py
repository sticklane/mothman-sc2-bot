#!/usr/bin/env python3
"""
tools/iteration-loop/sc2_3d_renderer.py

Native host real-3D StarCraft II (`SC2_x64` Base75689 + OpenGL/EGL on AMD Radeon)
visuals engine producing crisp animated WebP battle clips + 960x720 Peak-Clash PNGs.

Exports:
  - render_replay_clip(...) / render_replay_clip_sync(...)
      Opens a full SC2 replay in real 3D Observer mode (`observed_player_id=0`,
      `disable_fog=True`), fast-forwards to the target battle window, smoothly
      EMA-tracks the active clash centroid with `ActionObserverCameraMove`,
      composites the real 3D viewport + bottom-left real SC2 minimap + minimal
      top-left single-line pill, and encodes an animated WebP + 960x720 Peak PNG.
  - render_arena_replays_parallel(race_specs, out_dir, ...)
      Renders ALL 21 tactics-arena duels across 3 parallel host SC2_x64 instances
      (one StartReplay per race, walking linearly through all 7 duels) and writes
      `<out_dir>/arena_manifest.json`.
"""

from __future__ import annotations

import asyncio
import concurrent.futures
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
IGNORE_IDS = {
    151, 103, 87, 137, 138, 801,  # Larva, Egg, CreepTumors, AdeptShade
    106, 129, 893,                # Overlords (avoid pulling camera away from ground fights)
}
STRUCTURE_IDS = {
    18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 46, 47, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70,
    71, 72, 86, 88, 89, 90, 91, 92, 93, 94, 96, 97, 98, 99, 100, 101, 102,
    130, 132, 133, 134, 504, 1910, 1949, 1955, 1956,
}

# -----------------------------------------------------------------------------
# Minimal Typography & Frame Composer
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


def compose_3d_frame(
    map_bytes: bytes,
    map_w: int,
    map_h: int,
    minimap_bytes: bytes | None,
    minimap_w: int,
    minimap_h: int,
    pill_text: str,
    accent_rgb: tuple[int, int, int] = (56, 189, 248),
    minimap_display_size: int = 160,
    include_minimap: bool = True,
) -> Image.Image:
    """Composite real 3D SC2_x64 viewport + bottom-left real minimap + subtle top-left pill."""
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

    # 2. Subtle translucent single-line top-left pill (keeps full 3D scene uncluttered!)
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
# Streaming ffmpeg Animated WebP Encoder (RGB24 rawvideo stdin pipe)
# -----------------------------------------------------------------------------
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
        self.out_webp = Path(out_webp)
        self.out_webp.parent.mkdir(parents=True, exist_ok=True)
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
            str(self.out_webp),
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
        rc = self._proc.wait(timeout=60)
        if rc != 0:
            raise RuntimeError(f"ffmpeg WebP encode failed (rc={rc}): {stderr.strip()}")
        return self.out_webp.stat().st_size if self.out_webp.exists() else 0


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
# Smart Combat Centroid & Peak-Clash Scoring from Raw Units
# -----------------------------------------------------------------------------
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
        # Subsample large armies cleanly for O(N) speed
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
        engaged_pts.append((dx, dy, 4.0))

    centroid: tuple[float, float] | None = None
    if engaged_pts:
        sw = sum(w for _, _, w in engaged_pts)
        centroid = (
            sum(x * w for x, _, w in engaged_pts) / sw,
            sum(y * w for _, y, w in engaged_pts) / sw,
        )
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
    elif p2_c:
        centroid = (sum(float(u.pos.x) for u in p2_c) / len(p2_c), sum(float(u.pos.y) for u in p2_c) / len(p2_c))

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
    # Try matching map name suffix inside replay filename (e.g., ..._PersephoneAIE_v4.SC2Replay)
    candidates = sorted(maps_dir.glob("*.SC2Map"), key=lambda p: -len(p.stem))
    for mp in candidates:
        if mp.stem.lower() in stem.lower():
            return mp
    raise FileNotFoundError(f"Could not find matching .SC2Map in {maps_dir} for replay {replay_path.name}")


# -----------------------------------------------------------------------------
# 1. FULL REPLAY 3D CLIP RENDERER
# -----------------------------------------------------------------------------
async def render_replay_clip(
    replay_path: str | Path,
    out_webp: str | Path,
    out_png: str | Path,
    start_loop: int,
    num_frames: int = 72,
    step: int = 2,
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
) -> dict[str, Any]:
    """Render one real-3D SC2 replay clip -> animated WebP + 960x720 Peak-Clash PNG."""
    from s2clientprotocol import common_pb2, sc2api_pb2

    t0 = time.monotonic()
    rep_p = Path(replay_path)
    mp_p = _find_map_path(rep_p, Path(maps_dir), Path(map_path) if map_path else None)
    ren_w, ren_h = render_size
    mm_w, mm_h = minimap_size

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

        # Fast-forward in one large step to just before the battle window
        ff_target = max(16, int(start_loop) - 8)
        if ff_target > 0:
            await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=ff_target)), timeout=120.0)

        obs_r = await sc2.rpc(sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation(disable_fog=True)))
        obs = obs_r.observation.observation
        cur_cam, _, prev_combat, _ = _extract_combat_state(obs, {}, focus_hint=focus_hint)
        if cur_cam is not None:
            await sc2.move_camera(cur_cam[0], cur_cam[1], distance=camera_distance)
        # Settle camera for 8 loops
        await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=8)))

        encoder = WebPStreamEncoder(
            Path(out_webp),
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

            centroid, intensity, prev_combat, counts = _extract_combat_state(obs, prev_combat, focus_hint=focus_hint)
            cur_cam = _smooth_camera_step(cur_cam, centroid, alpha=0.26, max_step_tiles=2.2)

            rd = obs.render_data
            if rd.map.data:
                parts = [p for p in (title or rep_p.stem, fmt_clock(gl), subtitle_metric) if p]
                pill = " · ".join(parts)
                frame_img = compose_3d_frame(
                    rd.map.data,
                    rd.map.size.x,
                    rd.map.size.y,
                    rd.minimap.data if rd.minimap.data else None,
                    rd.minimap.size.x,
                    rd.minimap.size.y,
                    pill_text=pill,
                    accent_rgb=accent_rgb,
                    minimap_display_size=160,
                    include_minimap=True,
                )
                encoder.write_frame(frame_img)
                frames_captured += 1

                if fallback_img is None:
                    fallback_img = frame_img
                # Prefer peak-clash PNG inside the heart of the clip (never let frame 0 lock peak_score!)
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
        webp_bytes = encoder.finish(hold_last_frames=8)

        out_png_p = Path(out_png)
        out_png_p.parent.mkdir(parents=True, exist_ok=True)
        final_png_img = peak_img if peak_img is not None else fallback_img
        if final_png_img is not None:
            final_png_img.save(str(out_png_p), format="PNG", optimize=True)
        png_bytes = out_png_p.stat().st_size if out_png_p.exists() else 0

        return {
            "replay": str(rep_p),
            "map": mp_p.name,
            "webp": str(Path(out_webp)),
            "png": str(out_png_p),
            "frames": frames_captured,
            "start_loop": first_loop,
            "end_loop": last_loop,
            "peak_loop": peak_loop,
            "peak_frame_idx": peak_idx,
            "clock_window": f"{fmt_clock(max(0, first_loop))}–{fmt_clock(max(0, last_loop))}",
            "webp_bytes": webp_bytes,
            "png_bytes": png_bytes,
            "render_fps": round(frames_captured / cap_sec, 1),
            "wall_sec": round(time.monotonic() - t0, 2),
        }


def render_replay_clip_sync(**kwargs: Any) -> dict[str, Any]:
    return asyncio.run(render_replay_clip(**kwargs))


# -----------------------------------------------------------------------------
# 2. ALL-21 TACTICS ARENA PARALLEL 3D RENDERER (3 Host SC2_x64 Instances)
# -----------------------------------------------------------------------------
async def _render_single_race_arena_replay(
    race_spec: dict[str, Any],
    out_dir: Path,
    step: int = 2,
    fps: int = 16,
    render_size: tuple[int, int] = (960, 720),
    minimap_size: tuple[int, int] = (180, 180),
    webp_size: tuple[int, int] = (800, 600),
    max_frames_per_duel: int = 96,
    sc2_host_dir: Path = DEFAULT_SC2_HOST_DIR,
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
            short_id = duel_id.replace("sc2-real-", "")
            s_loop = max(16, int(d.get("start_loop") or 16))
            e_loop = max(s_loop + 16, int(d.get("end_loop") or (s_loop + 160)))
            acx = float(d.get("arena_cx") or 88.0)
            acy = float(d.get("arena_cy") or 88.0)
            winner = str(d.get("winner") or "Timeout")
            trade = d.get("trade_ratio")
            trade_s = f"{float(trade):.2f}x" if trade is not None else "-"
            accent = (34, 197, 94) if winner == "Mothman" else ((239, 68, 68) if winner == "MicroDummy" else (245, 158, 11))

            # Fast-forward linearly to s_loop
            if s_loop > cur_loop:
                delta = s_loop - cur_loop
                step_r = await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=delta)), timeout=90.0)
                cur_loop += delta
                if step_r.status != sc2api_pb2.in_replay:
                    replay_alive = False
                    break

            # Snap camera cleanly onto arena center
            await sc2.move_camera(acx, acy, distance=0.0)
            # Advance 2 loops so camera settles cleanly on the newly spawned armies
            step_r = await sc2.rpc(sc2api_pb2.Request(step=sc2api_pb2.RequestStep(count=2)))
            cur_loop += 2
            if step_r.status != sc2api_pb2.in_replay:
                replay_alive = False
                break

            # Adaptive step if a duel ran very long (> max_frames_per_duel * step)
            span_loops = max(8, e_loop - cur_loop)
            duel_step = max(step, int(math.ceil(span_loops / max(1, max_frames_per_duel))))

            out_webp = out_dir / f"{duel_id}.webp"
            out_png = out_dir / f"{duel_id}.png"
            encoder = WebPStreamEncoder(
                out_webp,
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
            arena_bounds = (acx, acy, 26.0)
            fi = 0

            while cur_loop <= e_loop and frames_captured < max_frames_per_duel + 4:
                obs_r = await sc2.rpc(sc2api_pb2.Request(observation=sc2api_pb2.RequestObservation(disable_fog=True)))
                obs = obs_r.observation.observation
                cur_loop = int(obs.game_loop)

                centroid, intensity, prev_combat, counts = _extract_combat_state(
                    obs, prev_combat, focus_hint=(acx, acy), arena_bounds=arena_bounds
                )
                # Gentle tracking inside arena so fight stays dead-center
                cur_cam = _smooth_camera_step(cur_cam, centroid, alpha=0.20, max_step_tiles=1.5)

                rd = obs.render_data
                if rd.map.data:
                    rel_s = max(0.0, (cur_loop - s_loop) / 22.4)
                    pill = f"{short_id[:28]} · {rel_s:4.1f}s · {winner} {trade_s}"
                    frame_img = compose_3d_frame(
                        rd.map.data,
                        rd.map.size.x,
                        rd.map.size.y,
                        rd.minimap.data if rd.minimap.data else None,
                        rd.minimap.size.x,
                        rd.minimap.size.y,
                        pill_text=pill,
                        accent_rgb=accent,
                        minimap_display_size=148,
                        include_minimap=True,
                    )
                    encoder.write_frame(frame_img)
                    frames_captured += 1
                    # Favor active mid-combat frames with both armies alive
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

            webp_bytes = encoder.finish(hold_last_frames=8)
            if peak_img is not None:
                peak_img.save(str(out_png), format="PNG", optimize=True)
            png_bytes = out_png.stat().st_size if out_png.exists() else 0

            rendered.append({
                "id": duel_id,
                "race": race_spec.get("race") or d.get("race") or "",
                "bot": d.get("bot") or "",
                "enemy_race": d.get("enemy_race") or "",
                "winner": winner,
                "trade_ratio": trade,
                "description": d.get("description") or "",
                "context": d.get("context") or d.get("description") or "",
                "p1_spec": d.get("p1_spec") or "",
                "p2_spec": d.get("p2_spec") or "",
                "mothman_attack_unit_cmds": d.get("mothman_attack_unit_cmds"),
                "mothman_move_unit_cmds": d.get("mothman_move_unit_cmds"),
                "mothman_spell_unit_cmds": d.get("mothman_spell_unit_cmds"),
                "webp": str(out_webp),
                "png": str(out_png),
                "frames": frames_captured,
                "start_loop": s_loop,
                "end_loop": e_loop,
                "peak_loop": peak_loop,
                "peak_frame_idx": peak_idx,
                "webp_bytes": webp_bytes,
                "png_bytes": png_bytes,
                "wall_sec": round(time.monotonic() - t_d0, 2),
            })

    return rendered


def _race_worker_entry(args_tuple: tuple[Any, ...]) -> list[dict[str, Any]]:
    race_spec, out_dir_str, step, fps, render_size, minimap_size, webp_size, max_frames_per_duel, sc2_host_dir_str = args_tuple
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
    max_frames_per_duel: int = 96,
    workers: int = 3,
    sc2_host_dir: str | Path = DEFAULT_SC2_HOST_DIR,
) -> dict[str, Any]:
    """
    Render ALL tactics-arena race replays in parallel (up to 3 host SC2_x64 instances
    on Radeon 8060S), returning the complete manifest dict and writing `arena_manifest.json`.
    """
    t0 = time.monotonic()
    out_p = Path(out_dir)
    out_p.mkdir(parents=True, exist_ok=True)
    jobs = [
        (rs, str(out_p), step, fps, render_size, minimap_size, webp_size, max_frames_per_duel, str(sc2_host_dir))
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

    # Sort canonically by scenario id
    all_clips.sort(key=lambda c: c["id"])
    total_webp_bytes = sum(c.get("webp_bytes", 0) for c in all_clips)
    total_png_bytes = sum(c.get("png_bytes", 0) for c in all_clips)
    manifest = {
        "kind": "arena_3d_visuals",
        "render_size": list(render_size),
        "webp_size": list(webp_size),
        "fps": fps,
        "step": step,
        "clips_count": len(all_clips),
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
