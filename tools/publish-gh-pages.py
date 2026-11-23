#!/usr/bin/env python3
"""Publish Mothman SC2 Bot campaign reports, replay browser, and technical notes
to GitHub Pages using per-iteration GitHub Releases as a 3D MP4/WebP/PNG media CDN.

Usage:
    python3 tools/publish-gh-pages.py                  # Full media sync + build + gh-pages push + verify
    python3 tools/publish-gh-pages.py --skip-media     # Fast HTML rebuild/push using cached Release URLs
    python3 tools/publish-gh-pages.py --skip-push      # Build & verify locally in /tmp/mothman-gh-pages-site
    python3 tools/publish-gh-pages.py --include-unreferenced  # Also upload non-embedded campaign_media files
"""

from __future__ import annotations

import argparse
import concurrent.futures
import html
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

_TOOLS_DIR = str(Path(__file__).resolve().parent)
if _TOOLS_DIR not in sys.path:
    sys.path.insert(0, _TOOLS_DIR)

from site_report_sections import (  # noqa: E402
    INTERACTIVE_SECTIONS_CSS,
    INTERACTIVE_SECTIONS_JS,
    load_rich_report_telemetry,
    render_architecture_section,
    render_historical_faults_details,
    render_issues_fixed_section,
    render_loop_diagram_section,
    render_matchup_evaluation_section,
    render_tactics_explorer_section,
    render_video_element,
    stage_ios_playable_mp4s,
)

DEFAULT_REPO_SLUG = "sticklane/mothman-sc2-bot"
DEFAULT_REPO_DIR = Path("/home/sjaconette/repos/mothman-sc2-bot")
DEFAULT_BRAIN_DIR = Path(
    "/home/sjaconette/.gemini/antigravity/brain/d28d22f4-2d13-41e2-9b7b-32757f58523b"
)
DEFAULT_ANALYZER_DIR = Path(
    "/home/sjaconette/.gemini/antigravity/brain/eb240772-dbd0-4a1b-8238-2de323cd12a8"
)
DEFAULT_SQLITE_DB = Path("/home/sjaconette/sc2-local-arena/arena_replays.sqlite")
DEFAULT_CACHE_MAP = Path("/home/sjaconette/sc2-local-arena/gh_pages_media_map.json")
DEFAULT_OUT_DIR = Path("/tmp/mothman-gh-pages-site")

MEDIA_EXTS = (".webp", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".mp4")


@dataclass(frozen=True)
class ReportSpec:
    slug: str
    out_file: str
    title: str
    short_title: str
    section: str  # "Progress & Replays" | "Technical Notes"
    summary: str
    source_candidates: Tuple[Path, ...]
    required: bool = True


def build_report_specs(brain_dir: Path, analyzer_dir: Path) -> List[ReportSpec]:
    return [
        ReportSpec(
            slug="loops-29-plus",
            out_file="loops-29-plus.html",
            title="Campaign Updates (Loops 29–51)",
            short_title="Updates",
            section="Progress & Replays",
            summary="Build summaries, live releases, and playable 3D match clips from recent test runs.",
            source_candidates=(brain_dir / "loops_29_plus_visual_campaign_report.md",),
            required=True,
        ),
        ReportSpec(
            slug="loops-19-28",
            out_file="loops-19-28.html",
            title="Earlier Updates (Loops 19–28)",
            short_title="Earlier Updates",
            section="Progress & Replays",
            summary="Earlier test runs leading up to our first solid AI Arena release.",
            source_candidates=(brain_dir / "loops_19_28_visual_campaign_report.md",),
            required=True,
        ),
        ReportSpec(
            slug="loop-flywheel-retro",
            out_file="loop-flywheel-retro.html",
            title="Speeding Up the Test & Release Cycle",
            short_title="Timing Review",
            section="Technical Notes",
            summary="Where time went across 41 runs, why we moved the 2-minute head-to-head check first, and which rules kept flip-flopping.",
            source_candidates=(brain_dir / "scratch/loop/loop_flywheel_retro.md",),
            required=False,
        ),
        ReportSpec(
            slug="loop47-forensics",
            out_file="loop47-forensics.html",
            title="Loop 47 & Live Build 45 Notes",
            short_title="Loop 47 Notes",
            section="Technical Notes",
            summary="Build 45 ladder check (13–10), combat drill results (34–25–7), and the Barracks-cap bug that held Loop 47 back.",
            source_candidates=(
                analyzer_dir / "loop47_forensics_prod_l45_audit.md",
                brain_dir / "loop47_forensics_prod_l45_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="loop45-forensics",
            out_file="loop45-forensics.html",
            title="Loop 45 Release #6 Notes",
            short_title="Loop 45 Notes",
            section="Technical Notes",
            summary="Loops 43–45 release check: 25 external wins, 50% on historical 12-bot set, and 3–0 mirror head-to-head sweep.",
            source_candidates=(
                analyzer_dir / "loop45_ship6_signoff_prod_l42_audit.md",
                brain_dir / "loop45_ship6_signoff_prod_l42_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="loop42-forensics",
            out_file="loop42-forensics.html",
            title="Loop 42 Release & Live Build 40 Notes",
            short_title="Loop 42 Notes",
            section="Technical Notes",
            summary="Head-to-head results before shipping Build 42, live Build 40 ladder update, and the Loop 43 plan.",
            source_candidates=(
                analyzer_dir / "loop42_ship5_signoff_prod_l40_audit.md",
                brain_dir / "loop42_ship5_signoff_prod_l40_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="loop41-forensics",
            out_file="loop41-forensics.html",
            title="Loop 41 & Live Build 40 Notes",
            short_title="Loop 41 Notes",
            section="Technical Notes",
            summary="First live ladder games for Build 40, local holdout gains, and what went into Loop 42.",
            source_candidates=(
                analyzer_dir / "loop41_forensics_prod_l40_audit.md",
                brain_dir / "loop41_forensics_prod_l40_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="loop40-forensics",
            out_file="loop40-forensics.html",
            title="Loop 40 Release Notes",
            short_title="Loop 40 Notes",
            section="Technical Notes",
            summary="Head-to-head results before shipping Build 40, plus Build 37's final ladder tally.",
            source_candidates=(
                analyzer_dir / "loop40_ship4_signoff_prod_l37_audit.md",
                brain_dir / "loop40_ship4_signoff_prod_l37_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="loop39-forensics",
            out_file="loop39-forensics.html",
            title="Loop 39 Notes",
            short_title="Loop 39 Notes",
            section="Technical Notes",
            summary="Why we held Build 39 back after head-to-head tests caught an over-aggressive army bug.",
            source_candidates=(
                analyzer_dir / "loop39_forensics_prod_l37_audit.md",
                brain_dir / "loop39_forensics_prod_l37_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="loop38-forensics",
            out_file="loop38-forensics.html",
            title="Loop 38 Notes",
            short_title="Loop 38 Notes",
            section="Technical Notes",
            summary="First run of the expanded combat and worker-defense tests, plus early Build 37 ladder games.",
            source_candidates=(
                analyzer_dir / "loop38_forensics_prod_l37_audit.md",
                brain_dir / "loop38_forensics_prod_l37_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="loop37-forensics",
            out_file="loop37-forensics.html",
            title="Loop 37 Notes",
            short_title="Loop 37 Notes",
            section="Technical Notes",
            summary="Checking our four-corner building placement fixes before shipping Build 37.",
            source_candidates=(
                analyzer_dir / "loop37_forensics_prod_l36_audit.md",
                brain_dir / "loop37_forensics_prod_l36_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="loop36-forensics",
            out_file="loop36-forensics.html",
            title="Loop 36 Notes",
            short_title="Loop 36 Notes",
            section="Technical Notes",
            summary="Fixing late Terran Siege Tanks and missing Zerg anti-air against Banshees.",
            source_candidates=(
                analyzer_dir / "loop36_forensics_loop37_blueprint.md",
                brain_dir / "loop36_forensics_loop37_blueprint.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="prod-audit",
            out_file="prod-audit.html",
            title="First 80 AI Arena Matches",
            short_title="First 80 Matches",
            section="Technical Notes",
            summary="Which ladder opponents beat our early builds and what they exposed.",
            source_candidates=(
                brain_dir / "prod_aiarena_run44840087005_audit.md",
                analyzer_dir / "prod_aiarena_run44840087005_audit.md",
            ),
            required=True,
        ),
        ReportSpec(
            slug="mirror-brain-audit",
            out_file="mirror-brain-audit.html",
            title="Testing Our Opponent-Prediction Code",
            short_title="Scouting Check",
            section="Technical Notes",
            summary="Replay check showing simple observation beat multi-step lookahead, and which scouting signals actually helped.",
            source_candidates=(
                brain_dir / "mirror_brain_empirical_audit.md",
                analyzer_dir / "mirror_brain_empirical_audit.md",
            ),
            required=True,
        ),
        ReportSpec(
            slug="north-vs-south-audit",
            out_file="north-vs-south-audit.html",
            title="Why North Spawns Lost More Often",
            short_title="Spawn Bias Study",
            section="Technical Notes",
            summary="Tracking a 16-point win-rate drop on Ley Lines back to directional building and scouting offsets.",
            source_candidates=(
                analyzer_dir / "north_vs_south_spawn_audit.md",
                brain_dir / "north_vs_south_spawn_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="belief-engine-plan",
            out_file="belief-engine-plan.html",
            title="Scouting & Hidden-Tech Clues",
            short_title="Scouting Model",
            section="Technical Notes",
            summary="How early scouting sightings trigger detection and rush defense.",
            source_candidates=(
                brain_dir / "post_deploy_loss_forensics_and_belief_engine_plan.md",
            ),
            required=True,
        ),
        ReportSpec(
            slug="pro-macro-design",
            out_file="pro-macro-design.html",
            title="Economy & Build Priorities",
            short_title="Economy Design",
            section="Technical Notes",
            summary="How the bot balances workers, bases, and army spending against Grandmaster replay curves.",
            source_candidates=(
                brain_dir / "pro_macro_prioritization_analysis_and_design.md",
            ),
            required=True,
        ),
        ReportSpec(
            slug="3d-rendering-proof",
            out_file="3d-rendering-proof.html",
            title="Recording Match & Drill Videos",
            short_title="Video Capture",
            section="Technical Notes",
            summary="How we capture H.264 MP4 clips directly from the StarCraft II engine.",
            source_candidates=(brain_dir / "real_sc2_3d_rendering_proof.md",),
            required=True,
        ),
        ReportSpec(
            slug="phase-reports",
            out_file="phase-reports.html",
            title="Raw Test Run Log",
            short_title="Raw Log",
            section="Technical Notes",
            summary="Full unfiltered log of every test batch, benchmark, and deployment.",
            source_candidates=(brain_dir / "scratch/loop/phase_reports.md",),
            required=False,
        ),
    ]


def resolve_spec_path(spec: ReportSpec) -> Optional[Path]:
    for p in spec.source_candidates:
        if p.is_file():
            return p
    return None


def gh_asset_normalized_name(filename: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]", ".", filename)


def run_cmd(
    cmd: Sequence[str],
    *,
    cwd: Optional[Path] = None,
    check: bool = True,
    capture: bool = True,
    env: Optional[Dict[str, str]] = None,
) -> subprocess.CompletedProcess:
    return subprocess.run(
        list(cmd),
        cwd=str(cwd) if cwd else None,
        check=check,
        text=True,
        capture_output=capture,
        env=env,
    )


def _is_placeholder_arena_clip(p: Path, clip_meta: Optional[Dict[str, Any]] = None) -> bool:
    """Strictly block unrendered/red-box placeholder or corrupt stub clips from staging & site cards."""
    s_low = str(p).lower()
    if "probe_iter51_w2_5014" in s_low and "sp07" in p.name.lower():
        return True
    if clip_meta:
        for flag in ("placeholder", "is_placeholder", "red_placeholder", "render_failed"):
            if clip_meta.get(flag):
                return True
    if p.suffix.lower() == ".mp4" and p.is_file():
        try:
            if p.stat().st_size < 25_000:
                return True
        except OSError:
            return True
    return False


def classify_media_path(p: Path) -> Tuple[str, str]:
    """Return (release_tag, asset_name) for a local media file.

    Keeps /campaign_media/iter<N>/<name> 100% compatible with existing Releases,
    shards full-match .mp4 manifests to media-iter<N>-matches to stay far under
    GitHub's 1,000-assets/release cap, and prefixes visuals_iter<N>/{arena,selfplay,replays}
    to eliminate basename collisions.
    """
    s = str(p)
    m_cm = re.search(r"/campaign_media/(iter\d+)/([^/\s)]+)$", s)
    if m_cm:
        return f"media-{m_cm.group(1)}", m_cm.group(2)

    m_fm = re.search(r"/visuals_(iter\d+)/(?:replays/)?full_matches/([^/\s)]+)$", s)
    if m_fm:
        return f"media-{m_fm.group(1)}-matches", m_fm.group(2)

    m_ia = re.search(r"/(iter\d+)_arena/(?:[^/]+/)*([^/\s)]+)$", s)
    if m_ia:
        iter_name, fname = m_ia.group(1), m_ia.group(2)
        asset_name = fname if fname.startswith("arena_") else f"arena_{fname}"
        return f"media-{iter_name}", asset_name

    m_vis = re.search(r"/(?:visuals|probe)_(iter\d+)(?:_[A-Za-z0-9_]+)?/(?:persephone_v4/)?(arena|selfplay|replays)/([^/\s)]+)$", s)
    if m_vis:
        iter_name, sub, fname = m_vis.group(1), m_vis.group(2), m_vis.group(3)
        if sub == "replays" and (
            "full_match" in fname.lower()
            or re.match(r"^(?:m|match|h2h)\d+_", fname.lower())
        ):
            return f"media-{iter_name}-matches", fname
        prefix = {"arena": "arena_", "selfplay": "selfplay_", "replays": "rep_"}[sub]
        asset_name = fname if fname.startswith(prefix) else f"{prefix}{fname}"
        return f"media-{iter_name}", asset_name

    m_vis_flat = re.search(r"/visuals_(iter\d+)/([^/\s)]+)$", s)
    if m_vis_flat:
        return f"media-{m_vis_flat.group(1)}", m_vis_flat.group(2)

    return "media-proof", p.name


def _extract_video_attr_paths(text: str) -> List[str]:
    paths: List[str] = []
    for tag_m in re.finditer(r"<video\b[^>]*>", text, re.I):
        tag = tag_m.group(0)
        for attr in ("src", "poster"):
            am = re.search(rf'\b{attr}\s*=\s*(["\'])([^"\']+)\1', tag, re.I)
            if am:
                paths.append(am.group(2).strip())
    return paths


def _iter_manifest_files(brain_dir: Path) -> Tuple[List[Tuple[int, Path]], List[Tuple[int, str, Path]]]:
    """Discover Loop 42+ full_matches_manifest.json and arena/selfplay manifest.json files."""
    full_match_manifests: List[Tuple[int, Path]] = []
    arena_manifests: List[Tuple[int, str, Path]] = []
    loop_dir = brain_dir / "scratch" / "loop"
    if not loop_dir.is_dir():
        return full_match_manifests, arena_manifests

    for vis_dir in sorted(loop_dir.iterdir()):
        if not vis_dir.is_dir():
            continue
        m = re.fullmatch(r"visuals_iter(\d+)", vis_dir.name)
        if not m:
            continue
        loop_num = int(m.group(1))
        for cand in (
            vis_dir / "full_matches" / "full_matches_manifest.json",
            vis_dir / "replays" / "full_matches_manifest.json",
            vis_dir / "full_matches_manifest.json",
        ):
            if cand.is_file():
                full_match_manifests.append((loop_num, cand))
                break
        for mode in ("arena", "selfplay"):
            for am_name in ("arena_manifest.json", "manifest.json"):
                am = vis_dir / mode / am_name
                if am.is_file():
                    arena_manifests.append((loop_num, mode, am))
                    break
    return full_match_manifests, arena_manifests


def discover_media_to_upload(
    resolved_reports: List[Tuple[ReportSpec, Path]],
    brain_dir: Path,
    include_unreferenced: bool = False,
) -> Tuple[Dict[str, Dict[str, Path]], Dict[str, Tuple[str, str]]]:
    """Return:
      - tag_files: {release_tag: {asset_name: local_Path}}
      - abs_to_asset: {abs_path_str: (release_tag, asset_name)}
    """
    tag_files: Dict[str, Dict[str, Path]] = {}
    abs_to_asset: Dict[str, Tuple[str, str]] = {}

    def register(p: Path, force_tag: Optional[str] = None, force_name: Optional[str] = None) -> None:
        if not p.is_file() or p.stat().st_size <= 0:
            return
        if p.suffix.lower() not in MEDIA_EXTS:
            return
        tag, asset_name = classify_media_path(p)
        if force_tag:
            tag = force_tag
        if force_name:
            asset_name = force_name
        tag_files.setdefault(tag, {})[asset_name] = p
        abs_to_asset[str(p)] = (tag, asset_name)

    img_re = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")
    file_link_re = re.compile(r"(?<!!)\[[^\]]*\]\(([^)#]+)(?:#[^)]+)?\)")

    # 1. Scan every referenced image, video, and media link across all published reports.
    for _, md_path in resolved_reports:
        txt = md_path.read_text(encoding="utf-8", errors="replace")
        candidates = (
            img_re.findall(txt)
            + file_link_re.findall(txt)
            + _extract_video_attr_paths(txt)
        )
        for raw in candidates:
            clean = raw.strip()
            if clean.startswith(("http://", "https://", "#", "mailto:")):
                continue
            if clean.startswith("file://"):
                clean = clean[len("file://") :]
            if not clean.lower().endswith(MEDIA_EXTS):
                continue
            p = Path(clean)
            if p.is_file():
                register(p)

    # 2. Scan Loop 42+ full_matches_manifest.json and .mp4 arena/selfplay manifests.
    full_manifests, arena_manifests = _iter_manifest_files(brain_dir)
    for loop_num, mpath in full_manifests:
        try:
            data = json.loads(mpath.read_text(encoding="utf-8"))
        except Exception:
            continue
        entries = data.get("matches", data.get("clips", [])) if isinstance(data, dict) else []
        match_tag = f"media-iter{loop_num}-matches"
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            for key in ("mp4", "video", "png", "webp"):
                val = entry.get(key)
                if not val or not isinstance(val, str):
                    continue
                p = Path(val)
                if not p.is_absolute():
                    p = (mpath.parent / p).resolve()
                if p.is_file():
                    register(p, force_tag=match_tag, force_name=p.name)

    for loop_num, mode, mpath in arena_manifests:
        try:
            data = json.loads(mpath.read_text(encoding="utf-8"))
        except Exception:
            continue
        clips = data.get("clips", []) if isinstance(data, dict) else []
        # Auto-upload manifest clips only when MP4 videos are present (Loop 42+)
        has_mp4 = any(
            isinstance(c, dict)
            and (
                str(c.get("mp4", "")).lower().endswith(".mp4")
                or str(c.get("video", "")).lower().endswith(".mp4")
                or c.get("video_format") == "mp4"
            )
            for c in clips
        )
        if not has_mp4:
            continue
        arena_tag = f"media-iter{loop_num}"
        prefix = "arena_" if mode == "arena" else "selfplay_"
        for clip in clips:
            if not isinstance(clip, dict):
                continue
            for key in ("mp4", "video", "png"):
                val = clip.get(key)
                if not val or not isinstance(val, str):
                    continue
                p = Path(val)
                if not p.is_absolute():
                    p = (mpath.parent / p).resolve()
                if p.is_file():
                    aname = p.name if p.name.startswith(prefix) else f"{prefix}{p.name}"
                    register(p, force_tag=arena_tag, force_name=aname)

    # 2B. Register verified Loop 50 probe clips (d10, r15, t12, t14, s04, s05) under media-iter50.
    l50_probe_dir = brain_dir / "scratch" / "loop" / "visuals_iter50_w3_probe" / "arena"
    if l50_probe_dir.is_dir():
        for sid in (
            "sc2-det-d10-t-cloaked-banshee-viking-vs-observers-stalker",
            "sc2-reg-r15-tvp-full-lifecycle-vs-15-kiting-probes",
            "sc2-real-t12-banshee-raven-marine-vs-dt-stalker-observer",
            "sc2-real-t14-raven-imatrix-aam-bio-vs-colossus",
            "sc2-sta-s04-pvz-oracle-stasis-choke-split",
            "sc2-sta-s05-zvp-stasis-ward-defuse-ling-sac",
        ):
            for ext in (".mp4", ".png"):
                p = l50_probe_dir / f"{sid}{ext}"
                if p.is_file():
                    register(p, force_tag="media-iter50", force_name=f"arena_{p.name}")

    # 2C. Register verified Loop 51 clips (t14 PersephoneAIE_v4 3.75x KO, d10 1.75x KO; exclude sp07 placeholder).
    l51_root = brain_dir / "scratch" / "loop" / "probe_iter51_w2_5014"
    for rel_sub, sid in (
        ("persephone_v4/arena", "sc2-real-t14-raven-imatrix-aam-bio-vs-colossus"),
        ("arena", "sc2-det-d10-t-cloaked-banshee-viking-vs-observers-stalker"),
    ):
        for ext in (".mp4", ".png"):
            p = l51_root / rel_sub / f"{sid}{ext}"
            if p.is_file() and not _is_placeholder_arena_clip(p):
                register(p, force_tag="media-iter51", force_name=f"arena_{p.name}")

    # 2D. Auto-register verified Loop 58+ iter*_arena/pass* renders (core + ability-mastery + non-combat), skipping placeholders.
    loop_scratch_dir = brain_dir / "scratch" / "loop"
    if loop_scratch_dir.is_dir():
        for adir in sorted(loop_scratch_dir.glob("iter*_arena")):
            m_it = re.search(r"iter(\d+)_arena$", adir.name)
            if not m_it or not adir.is_dir():
                continue
            tag_name = f"media-iter{m_it.group(1)}"
            # Sort ascending by (pass_num, mtime) so the highest pass wins in tag_files / abs_to_asset
            rdirs_asc = sorted(
                (d for d in adir.iterdir() if d.is_dir() and "render" in d.name.lower()),
                key=lambda p: (
                    999 if "final" in p.name.lower() else (
                        int(re.search(r"pass(\d+)", p.name.lower()).group(1))
                        if re.search(r"pass(\d+)", p.name.lower())
                        else 0
                    ),
                    p.stat().st_mtime,
                ),
            )
            for rdir in rdirs_asc:
                for mp4_p in sorted(rdir.rglob("*.mp4")):
                    if _is_placeholder_arena_clip(mp4_p):
                        continue
                    register(mp4_p, force_tag=tag_name, force_name=f"arena_{mp4_p.name}")
                    png_p = mp4_p.with_suffix(".png")
                    if png_p.is_file():
                        register(png_p, force_tag=tag_name, force_name=f"arena_{png_p.name}")

    # 3. Optionally include ALL campaign_media/iter* files.
    cm_root = brain_dir / "campaign_media"
    if include_unreferenced and cm_root.is_dir():
        for iter_dir in sorted(cm_root.iterdir()):
            if iter_dir.is_dir() and re.fullmatch(r"iter\d+", iter_dir.name):
                for f in sorted(iter_dir.iterdir()):
                    if f.is_file() and f.suffix.lower() in MEDIA_EXTS:
                        register(f)

    def tag_sort_key(tag: str) -> Tuple[int, int, int, str]:
        m = re.fullmatch(r"media-iter(\d+)(-matches)?", tag)
        if m:
            return (0, -int(m.group(1)), 1 if m.group(2) else 0, tag)
        return (1, 0, 0, tag)

    ordered: Dict[str, Dict[str, Path]] = {}
    for tag in sorted(tag_files.keys(), key=tag_sort_key):
        ordered[tag] = dict(sorted(tag_files[tag].items()))
    return ordered, abs_to_asset


def fetch_release_assets(repo_slug: str, tag: str) -> Optional[Dict[str, str]]:
    proc = run_cmd(
        ["gh", "release", "view", tag, "-R", repo_slug, "--json", "assets"],
        check=False,
    )
    if proc.returncode != 0:
        return None
    data = json.loads(proc.stdout)
    assets: Dict[str, str] = {}
    for a in data.get("assets", []):
        name = a.get("name")
        url = a.get("url")
        if name and url:
            assets[name] = url
    return assets


def ensure_release_and_upload_tag(
    repo_slug: str,
    tag: str,
    files_by_name: Dict[str, Path],
    batch_size: int = 12,
) -> Tuple[str, Dict[str, str], int]:
    """Ensure GitHub Release exists, upload missing assets, return {asset_name: url}."""
    existing = fetch_release_assets(repo_slug, tag)
    if existing is None:
        m = re.fullmatch(r"media-iter(\d+)(-matches)?", tag)
        if m:
            loop_num = m.group(1)
            if m.group(2):
                title = f"Campaign Full-Match Videos — Loop {loop_num}"
                notes = (
                    f"Real StarCraft II 3D H.264 MP4 full-match videos and poster frames "
                    f"for Loop {loop_num} of the Mothman SC2 Bot campaign."
                )
            else:
                title = f"Campaign 3D Media — Loop {loop_num}"
                notes = (
                    f"Real StarCraft II 3D MP4/WebP clips and keyframe PNGs for "
                    f"Loop {loop_num} of the Mothman SC2 Bot campaign."
                )
        else:
            title = f"Campaign 3D Media — {tag}"
            notes = "Real StarCraft II 3D proof renders and supporting media assets."
        for attempt in range(4):
            proc = run_cmd(
                [
                    "gh",
                    "release",
                    "create",
                    tag,
                    "-R",
                    repo_slug,
                    "--prerelease",
                    "--title",
                    title,
                    "--notes",
                    notes,
                    "--target",
                    "main",
                ],
                check=False,
            )
            if proc.returncode == 0:
                break
            existing = fetch_release_assets(repo_slug, tag)
            if existing is not None:
                break
            time.sleep(2.0 * (attempt + 1))
        else:
            raise RuntimeError(f"Failed creating release {tag}: {proc.stderr}")
        if existing is None:
            existing = fetch_release_assets(repo_slug, tag) or {}

    missing: List[Tuple[str, Path]] = []
    for asset_name, p in files_by_name.items():
        norm = gh_asset_normalized_name(asset_name)
        if asset_name not in existing and norm not in existing:
            missing.append((asset_name, p))

    uploaded_count = 0
    if missing:
        with tempfile.TemporaryDirectory(prefix="mothman_gh_upload_") as stage_dir:
            stage_root = Path(stage_dir)
            upload_paths: List[Path] = []
            for asset_name, p in missing:
                if p.name == asset_name:
                    upload_paths.append(p)
                else:
                    link = stage_root / asset_name
                    os.symlink(p, link)
                    upload_paths.append(link)

            for i in range(0, len(upload_paths), batch_size):
                batch = upload_paths[i : i + batch_size]
                cmd = ["gh", "release", "upload", tag, "-R", repo_slug, "--clobber"] + [
                    str(bp) for bp in batch
                ]
                for attempt in range(4):
                    proc = run_cmd(cmd, check=False)
                    if proc.returncode == 0:
                        uploaded_count += len(batch)
                        break
                    wait_s = 3.0 * (attempt + 1)
                    print(
                        f"  [retry {attempt+1}] {tag} batch {i//batch_size+1} failed: "
                        f"{proc.stderr.strip()[:160]} — sleeping {wait_s:.0f}s",
                        file=sys.stderr,
                    )
                    time.sleep(wait_s)
                else:
                    raise RuntimeError(f"Failed uploading batch to {tag}: {proc.stderr}")

    final_assets = fetch_release_assets(repo_slug, tag)
    if final_assets is None:
        raise RuntimeError(f"Could not inspect release {tag} after upload")

    resolved_map: Dict[str, str] = {}
    for asset_name in files_by_name:
        url = final_assets.get(asset_name) or final_assets.get(
            gh_asset_normalized_name(asset_name)
        )
        if not url:
            raise RuntimeError(f"Asset {asset_name} missing from release {tag} after upload!")
        resolved_map[asset_name] = url

    return tag, resolved_map, uploaded_count


def save_media_cache(
    cache_map_path: Path,
    repo_slug: str,
    by_tag: Dict[str, Dict[str, str]],
    tag_files: Dict[str, Dict[str, Path]],
) -> None:
    by_abs: Dict[str, str] = {}
    for tag, files_by_name in tag_files.items():
        tmap = by_tag.get(tag, {})
        for asset_name, p in files_by_name.items():
            if asset_name in tmap:
                by_abs[str(p)] = tmap[asset_name]
    payload = {
        "repo": repo_slug,
        "updated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "by_tag": by_tag,
        "by_abs_path": by_abs,
    }
    cache_map_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = cache_map_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    tmp.replace(cache_map_path)


def sync_release_media(
    repo_slug: str,
    tag_files: Dict[str, Dict[str, Path]],
    cache_map_path: Path,
    skip_media: bool,
    max_workers: int,
) -> Dict[str, Dict[str, str]]:
    """Return {tag: {asset_name: browser_download_url}}."""
    cache_data: Dict[str, Dict[str, str]] = {}
    if cache_map_path.is_file():
        try:
            raw = json.loads(cache_map_path.read_text(encoding="utf-8"))
            cache_data = raw.get("by_tag", {})
        except Exception:
            cache_data = {}

    if skip_media:
        for tag, files_by_name in tag_files.items():
            cached_tag = cache_data.get(tag, {})
            if any(name not in cached_tag for name in files_by_name):
                fetched = fetch_release_assets(repo_slug, tag)
                mapped = {}
                for name in files_by_name:
                    norm = gh_asset_normalized_name(name)
                    u = (fetched.get(name) or fetched.get(norm)) if fetched else None
                    if not u and name not in cached_tag:
                        # Local preview fallback when release has not been uploaded yet
                        u = f"https://github.com/{repo_slug}/releases/download/{tag}/{norm}"
                    if u:
                        mapped[name] = u
                cache_data.setdefault(tag, {}).update(mapped)
        return cache_data

    total_files = sum(len(v) for v in tag_files.values())
    total_mb = (
        sum(p.stat().st_size for v in tag_files.values() for p in v.values()) / 1e6
    )
    print(
        f"[Step A] Syncing {len(tag_files)} GitHub Releases "
        f"({total_files} media assets, {total_mb:.1f} MB) with max_workers={max_workers}..."
    )

    t0 = time.time()
    total_uploaded = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, max_workers)) as pool:
        futs = {
            pool.submit(
                ensure_release_and_upload_tag, repo_slug, tag, files_by_name
            ): (tag, len(files_by_name))
            for tag, files_by_name in tag_files.items()
        }
        for fut in concurrent.futures.as_completed(futs):
            tag, count = futs[fut]
            t_name, url_map, uploaded = fut.result()
            cache_data[t_name] = url_map
            total_uploaded += uploaded
            print(
                f"  ✓ {t_name}: {count} assets verified "
                f"({uploaded} newly uploaded, {count - uploaded} cached)"
            )
            save_media_cache(cache_map_path, repo_slug, cache_data, tag_files)

    elapsed = time.time() - t0
    print(
        f"[Step A] Complete in {elapsed:.1f}s — {total_files} assets ready "
        f"({total_uploaded} uploaded this run)."
    )
    return cache_data


# ---------------------------------------------------------------------------
# Path Rewriter (Guarantees ZERO /home/sjaconette/ or file:/// leaks)
# ---------------------------------------------------------------------------


def make_path_rewriter(
    repo_slug: str,
    repo_dir: Path,
    brain_dir: Path,
    analyzer_dir: Path,
    media_by_tag: Dict[str, Dict[str, str]],
    abs_to_asset: Dict[str, Tuple[str, str]],
    report_filename_to_html: Dict[str, str],
):
    repo_prefix = str(repo_dir).rstrip("/") + "/"
    vis_rep_pat = re.compile(r"/scratch/loop/visual_report_(iter\d+)\.md$")

    def lookup_media_url(path_str: str) -> Optional[str]:
        if path_str in abs_to_asset:
            tag, asset_name = abs_to_asset[path_str]
            u = media_by_tag.get(tag, {}).get(asset_name)
            if u:
                return u
        tag, asset_name = classify_media_path(Path(path_str))
        u = media_by_tag.get(tag, {}).get(asset_name)
        if u:
            return u
        # Fallback: direct basename lookup inside matching tag
        base = os.path.basename(path_str)
        u = media_by_tag.get(tag, {}).get(base)
        if u:
            return u
        return media_by_tag.get("media-proof", {}).get(base)

    def rewrite_target_url(raw_url: str) -> Optional[str]:
        u = raw_url.strip()
        if u.startswith(("http://", "https://", "mailto:", "#", "./")):
            return u

        is_file_scheme = u.startswith("file://")
        clean = u[len("file://") :] if is_file_scheme else u

        frag = ""
        if "#" in clean:
            clean, frag = clean.split("#", 1)
            frag = "#" + frag

        if clean.lower().endswith(MEDIA_EXTS):
            murl = lookup_media_url(clean)
            if murl:
                return murl

        base = os.path.basename(clean)
        if base in report_filename_to_html:
            return f"./{report_filename_to_html[base]}{frag}"

        mv = vis_rep_pat.search(clean)
        if mv:
            iter_name = mv.group(1)
            return f"https://github.com/{repo_slug}/releases/tag/media-{iter_name}"

        if clean.startswith(repo_prefix):
            rel = clean[len(repo_prefix) :]
            local_p = repo_dir / rel
            kind = "tree" if local_p.is_dir() else "blob"
            return f"https://github.com/{repo_slug}/{kind}/main/{rel}{frag}"

        if clean.startswith(("/home/sjaconette", "/tmp/")):
            return None

        return raw_url

    def rewrite_video_tag(m: re.Match) -> str:
        tag = m.group(0)

        def repl_attr(am: re.Match) -> str:
            attr_name, quote, val = am.group(1), am.group(2), am.group(3)
            new_url = rewrite_target_url(val)
            if new_url is None:
                raise RuntimeError(f"Unresolved local <video {attr_name}> path: {val}")
            return f'{attr_name}={quote}{new_url}{quote}'

        return re.sub(
            r'\b(src|poster)\s*=\s*(["\'])([^"\']+)\2',
            repl_attr,
            tag,
            flags=re.I,
        )

    def rewrite_markdown_text(md_text: str) -> str:
        # 0. Rewrite <video ... src="..." poster="..."> attributes
        text = re.sub(r"<video\b[^>]*>", rewrite_video_tag, md_text, flags=re.I)

        # A. Rewrite image / video embeds: ![alt](target)
        def repl_img(m: re.Match) -> str:
            alt, target = m.group(1), m.group(2)
            new_url = rewrite_target_url(target)
            if new_url is None:
                raise RuntimeError(f"Unresolved local media embed: {target}")
            return f"![{alt}]({new_url})"

        text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", repl_img, text)

        # B. Rewrite standard markdown links: [label](target)
        def repl_link(m: re.Match) -> str:
            label, target = m.group(1), m.group(2)
            new_url = rewrite_target_url(target)
            if new_url is None:
                clean_label = label.strip("`")
                return f"`{clean_label}`"
            return f"[{label}]({new_url})"

        text = re.sub(r"(?<!!)\[([^\]]+)\]\(([^)]+)\)", repl_link, text)

        # C. Sanitize any bare local prose/code mentions
        text = text.replace(f"file://{repo_prefix}", f"https://github.com/{repo_slug}/blob/main/")
        text = text.replace(repo_prefix, "")
        text = text.replace(str(brain_dir).rstrip("/") + "/", "artifacts/")
        text = text.replace(str(analyzer_dir).rstrip("/") + "/", "artifacts/")
        text = text.replace("/home/sjaconette/sc2-local-arena/", "sc2-local-arena/")
        text = text.replace("file:///home/sjaconette/", "~/")
        text = text.replace("/home/sjaconette/", "~/")
        return text

    return rewrite_markdown_text


# ---------------------------------------------------------------------------
# Pure-Python GFM + Video + Carousel + Alerts + Tables + Mermaid -> HTML
# ---------------------------------------------------------------------------


class MarkdownRenderer:
    ALERT_META = {
        "NOTE": ("note", "Note"),
        "TIP": ("tip", "Highlight"),
        "IMPORTANT": ("important", "Key Takeaway"),
        "WARNING": ("warning", "Watch Item"),
        "CAUTION": ("caution", "Caution"),
    }

    def __init__(
        self,
        poster_lookup: Optional[Dict[str, str]] = None,
        staged_mp4_map: Optional[Dict[str, str]] = None,
        staged_poster_map: Optional[Dict[str, str]] = None,
    ) -> None:
        self.toc: List[Tuple[int, str, str]] = []
        self._slug_counts: Dict[str, int] = {}
        self.has_mermaid: bool = False
        self.img_count: int = 0
        self.video_count: int = 0
        self.poster_lookup: Dict[str, str] = poster_lookup or {}
        self.staged_mp4_map: Dict[str, str] = staged_mp4_map or {}
        self.staged_poster_map: Dict[str, str] = staged_poster_map or {}

    def _make_slug(self, raw_text: str) -> str:
        plain = re.sub(r"<[^>]+>", "", raw_text)
        plain = re.sub(r"[`*_~]", "", plain)
        slug = re.sub(r"[^a-zA-Z0-9\s-]", "", plain).strip().lower()
        slug = re.sub(r"[\s-]+", "-", slug) or "section"
        n = self._slug_counts.get(slug, 0)
        self._slug_counts[slug] = n + 1
        return slug if n == 0 else f"{slug}-{n}"

    def _infer_poster_url(self, mp4_url: str) -> Optional[str]:
        if mp4_url in self.staged_poster_map:
            return self.staged_poster_map[mp4_url]
        if mp4_url in self.poster_lookup:
            return self.poster_lookup[mp4_url]
        cand = re.sub(r"\.mp4$", ".png", mp4_url, flags=re.I)
        if cand in self.poster_lookup.values():
            return cand
        return None

    def _resolve_video_urls(self, src_url: str, poster_url: str) -> Tuple[str, str, str, bool]:
        """Return (play_src, poster_src, download_url, is_ios_playable)."""
        if src_url.startswith("./media/"):
            p = self.staged_poster_map.get(src_url) or poster_url
            return src_url, p, src_url, True
        staged = self.staged_mp4_map.get(src_url)
        staged_p = self.staged_poster_map.get(src_url) or poster_url or self._infer_poster_url(src_url) or ""
        if staged:
            return staged, staged_p, src_url, True
        return src_url, staged_p, src_url, False

    def _wrap_raw_video(self, video_html: str) -> str:
        self.video_count += 1
        src_m = re.search(r'\bsrc\s*=\s*["\']([^"\']+)["\']', video_html, re.I)
        poster_m = re.search(r'\bposter\s*=\s*["\']([^"\']+)["\']', video_html, re.I)
        src_url = src_m.group(1) if src_m else ""
        poster_url = poster_m.group(1) if poster_m else ""
        play_src, final_poster, dl_url, playable = self._resolve_video_urls(src_url, poster_url)
        inner = render_video_element(
            src=play_src,
            poster=final_poster,
            title="Match replay",
            download_url=dl_url,
            playable_mp4=playable,
        )
        return f'<figure class="clip-figure clip-video-figure">{inner}</figure>'

    def render_inline(self, text: str) -> str:
        code_slots: List[str] = []

        def save_code(m: re.Match) -> str:
            idx = len(code_slots)
            code_slots.append(f"<code>{html.escape(m.group(1))}</code>")
            return f"\x00CODE{idx}\x00"

        s = re.sub(r"`([^`\n]+)`", save_code, text)

        # Protect inline <video ...>...</video> tags
        vid_slots: List[str] = []

        def save_vid(m: re.Match) -> str:
            idx = len(vid_slots)
            vid_slots.append(self._wrap_raw_video(m.group(0)))
            return f"\x00VID{idx}\x00"

        s = re.sub(r"<video\b[^>]*>.*?</video>", save_vid, s, flags=re.I | re.S)

        # Protect media embeds ![alt](url) — supports both images AND .mp4 videos!
        img_slots: List[str] = []

        def save_img(m: re.Match) -> str:
            idx = len(img_slots)
            raw_alt = m.group(1)
            alt = html.escape(raw_alt, quote=True)
            url = m.group(2).strip()
            esc_url = html.escape(url, quote=True)
            if url.lower().endswith(".mp4"):
                self.video_count += 1
                play_src, final_poster, dl_url, playable = self._resolve_video_urls(url, "")
                inner = render_video_element(
                    src=play_src,
                    poster=final_poster,
                    title=raw_alt or "Match replay",
                    download_url=dl_url,
                    playable_mp4=playable,
                )
                img_slots.append(
                    f'<figure class="clip-figure clip-video-figure">'
                    f"{inner}"
                    f"<figcaption>{alt}</figcaption>"
                    f"</figure>"
                )
            else:
                self.img_count += 1
                img_slots.append(
                    f'<figure class="clip-figure">'
                    f'<img src="{esc_url}" alt="{alt}" loading="lazy" decoding="async" '
                    f'class="clip-img" data-lightbox-src="{esc_url}" data-lightbox-alt="{alt}" />'
                    f"<figcaption>{alt}</figcaption>"
                    f"</figure>"
                )
            return f"\x00IMG{idx}\x00"

        s = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", save_img, s)

        # Protect links [label](url)
        link_slots: List[str] = []

        def save_link(m: re.Match) -> str:
            idx = len(link_slots)
            raw_label = m.group(1)
            url = m.group(2).strip()
            inner_html = self._format_emphasis(html.escape(raw_label))
            inner_html = re.sub(
                r"\x00CODE(\d+)\x00", lambda cm: code_slots[int(cm.group(1))], inner_html
            )
            esc_url = html.escape(url, quote=True)
            ext_attr = (
                ' target="_blank" rel="noopener noreferrer"'
                if url.startswith(("http://", "https://"))
                else ""
            )
            low = url.lower()
            if low.endswith(".mp4"):
                cls = ' class="media-link mp4-link"'
            elif low.endswith(".png"):
                cls = ' class="media-link png-link"'
            else:
                cls = ""
            link_slots.append(f'<a href="{esc_url}"{cls}{ext_attr}>{inner_html}</a>')
            return f"\x00LINK{idx}\x00"

        s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", save_link, s)

        s = html.escape(s)

        s = re.sub(
            r"(?<!['\"=])(https?://[^\s<>()\*`\"']+[A-Za-z0-9/_-])",
            lambda m: (
                f'<a href="{m.group(1)}" target="_blank" rel="noopener noreferrer">'
                f"{m.group(1)}</a>"
            ),
            s,
        )

        s = self._format_emphasis(s)

        s = re.sub(r"\x00LINK(\d+)\x00", lambda m: link_slots[int(m.group(1))], s)
        s = re.sub(r"\x00IMG(\d+)\x00", lambda m: img_slots[int(m.group(1))], s)
        s = re.sub(r"\x00VID(\d+)\x00", lambda m: vid_slots[int(m.group(1))], s)
        s = re.sub(r"\x00CODE(\d+)\x00", lambda m: code_slots[int(m.group(1))], s)
        return s

    @staticmethod
    def _format_emphasis(s: str) -> str:
        s = re.sub(r"\*\*\*([^\*\n]+?)\*\*\*", r"<strong><em>\1</em></strong>", s)
        s = re.sub(r"\*\*([^\*\n]+?)\*\*", r"<strong>\1</strong>", s)
        s = re.sub(r"~~([^~\n]+?)~~", r"<del>\1</del>", s)
        s = re.sub(r"(?<!\*)\*([^\*\n]+?)\*(?!\*)", r"<em>\1</em>", s)
        return s

    @staticmethod
    def _split_table_row(line: str) -> List[str]:
        s = line.strip()
        if s.startswith("|"):
            s = s[1:]
        if s.endswith("|"):
            s = s[:-1]
        cells: List[str] = []
        cur: List[str] = []
        i = 0
        while i < len(s):
            if s[i] == "\\" and i + 1 < len(s) and s[i + 1] == "|":
                cur.append("|")
                i += 2
            elif s[i] == "|":
                cells.append("".join(cur).strip())
                cur = []
                i += 1
            else:
                cur.append(s[i])
                i += 1
        cells.append("".join(cur).strip())
        return cells

    @classmethod
    def _is_table_sep(cls, line: str) -> Optional[List[str]]:
        if "|" not in line:
            return None
        cells = cls._split_table_row(line)
        if not cells:
            return None
        aligns: List[str] = []
        for c in cells:
            if not re.fullmatch(r":?-{1,}:?", c):
                return None
            if c.startswith(":") and c.endswith(":"):
                aligns.append("center")
            elif c.endswith(":"):
                aligns.append("right")
            else:
                aligns.append("left")
        return aligns

    def render_blocks(self, md_text: str, record_toc: bool = True) -> str:
        lines = md_text.replace("\r\n", "\n").split("\n")
        out: List[str] = []
        i = 0
        n = len(lines)

        while i < n:
            line = lines[i]
            stripped = line.strip()

            if not stripped:
                i += 1
                continue

            # 1. Carousel fenced block: ````carousel ... ````
            if stripped.startswith("````carousel"):
                i += 1
                body_lines: List[str] = []
                while i < n and lines[i].strip() != "````":
                    body_lines.append(lines[i])
                    i += 1
                if i < n:
                    i += 1
                out.append(self._render_carousel("\n".join(body_lines)))
                continue

            # 2. Standard fenced code block
            fence_m = re.match(r"^(`{3,}|~{3,})([a-zA-Z0-9_+-]*)\s*$", stripped)
            if fence_m:
                fence_char = fence_m.group(1)[0]
                fence_len = len(fence_m.group(1))
                lang = fence_m.group(2).strip().lower()
                i += 1
                code_lines: List[str] = []
                while i < n:
                    st = lines[i].strip()
                    if st.startswith(fence_char * fence_len) and set(st) == {fence_char}:
                        i += 1
                        break
                    code_lines.append(lines[i])
                    i += 1
                raw_code = "\n".join(code_lines)
                if lang == "mermaid":
                    self.has_mermaid = True
                    out.append(
                        f'<div class="mermaid-wrap"><pre class="mermaid">'
                        f"{html.escape(raw_code)}</pre></div>"
                    )
                else:
                    lang_badge = (
                        f'<span class="code-lang">{html.escape(lang)}</span>' if lang else ""
                    )
                    out.append(
                        f'<div class="code-block">{lang_badge}'
                        f"<pre><code>{html.escape(raw_code)}</code></pre></div>"
                    )
                continue

            # 3. Horizontal rule
            if re.fullmatch(r"([-*_])(\s*\1){2,}", stripped):
                out.append("<hr />")
                i += 1
                continue

            # 4. Headings (# .. ######)
            h_m = re.match(r"^(#{1,6})\s+(.*)$", line)
            if h_m:
                lvl = len(h_m.group(1))
                raw_h = h_m.group(2).strip()
                rendered_h = self.render_inline(raw_h)
                plain_label = html.unescape(re.sub(r"<[^>]+>", "", rendered_h))
                # Apply calm loop titles to body <h2> headings too (not just sidebar TOC)
                if lvl == 2:
                    m_lp_h = re.match(r"^Loop\s+(\d+)\b", plain_label)
                    if m_lp_h and int(m_lp_h.group(1)) in _CALM_LOOP_TITLES:
                        lnum_h = int(m_lp_h.group(1))
                        calm_txt = f"Loop {lnum_h}: {_CALM_LOOP_TITLES[lnum_h]}"
                        rendered_h = html.escape(calm_txt)
                        plain_label = calm_txt
                slug = self._make_slug(rendered_h)
                if record_toc and lvl == 2:
                    self.toc.append((lvl, slug, plain_label))
                out.append(
                    f'<h{lvl} id="{slug}">{rendered_h}'
                    f' <a class="anchor" href="#{slug}" aria-label="Link to section">#</a></h{lvl}>'
                )
                i += 1
                continue

            # 5. Blockquote & GFM Alerts
            if stripped.startswith(">"):
                q_lines: List[str] = []
                while i < n and lines[i].strip().startswith(">"):
                    q = re.sub(r"^\s*>\s?", "", lines[i])
                    q_lines.append(q)
                    i += 1
                first_m = (
                    re.match(
                        r"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$",
                        q_lines[0].strip(),
                    )
                    if q_lines
                    else None
                )
                if first_m:
                    kind = first_m.group(1)
                    cls, label = self.ALERT_META[kind]
                    inner = self.render_blocks("\n".join(q_lines[1:]), record_toc=False)
                    out.append(
                        f'<div class="callout callout-{cls}">'
                        f'<div class="callout-label">{label}</div>'
                        f'<div class="callout-body">{inner}</div></div>'
                    )
                else:
                    inner = self.render_blocks("\n".join(q_lines), record_toc=False)
                    out.append(f"<blockquote>{inner}</blockquote>")
                continue

            # 6. GFM Table
            if "|" in line and i + 1 < n:
                aligns = self._is_table_sep(lines[i + 1])
                if aligns is not None:
                    headers = self._split_table_row(line)
                    i += 2
                    rows: List[List[str]] = []
                    while i < n and lines[i].strip() and "|" in lines[i]:
                        rows.append(self._split_table_row(lines[i]))
                        i += 1
                    out.append(self._render_table(headers, aligns, rows))
                    continue

            # 7. Unordered / Ordered Lists
            if re.match(r"^\s*(?:[-*+]|\d+\.)\s+", line):
                list_lines: List[str] = []
                while i < n:
                    cur = lines[i]
                    if re.match(r"^\s*(?:[-*+]|\d+\.)\s+", cur):
                        list_lines.append(cur)
                        i += 1
                    elif cur.startswith(("  ", "\t")) and cur.strip():
                        list_lines.append(cur)
                        i += 1
                    else:
                        break
                out.append(self._render_list(list_lines))
                continue

            # 8. Standalone <video ...>...</video> block
            if re.match(r"^<video\b", stripped, re.I):
                v_lines = [stripped]
                i += 1
                while i < n and "</video>" not in v_lines[-1].lower():
                    v_lines.append(lines[i].strip())
                    i += 1
                out.append(self._wrap_raw_video(" ".join(v_lines)))
                continue

            # 9. Raw HTML block pass-through (<details>, </details>, <summary>, etc.)
            if re.match(r"^</?(?:details|summary|div|br)\b", stripped, re.I):
                out.append(stripped)
                i += 1
                continue

            # 10. Paragraph
            p_lines: List[str] = []
            while i < n:
                cur = lines[i]
                st = cur.strip()
                if (
                    not st
                    or st.startswith(("````", "```", "~~~", ">", "#"))
                    or re.fullmatch(r"([-*_])(\s*\1){2,}", st)
                    or re.match(r"^\s*(?:[-*+]|\d+\.)\s+", cur)
                    or re.match(r"^</?(?:details|summary|div|br|video)\b", st, re.I)
                    or ("|" in cur and i + 1 < n and self._is_table_sep(lines[i + 1]) is not None)
                ):
                    break
                p_lines.append(cur.strip())
                i += 1
            if p_lines:
                rendered_p = self.render_inline(" ".join(p_lines))
                if rendered_p.startswith("<figure ") and rendered_p.endswith("</figure>"):
                    out.append(rendered_p)
                else:
                    out.append(f"<p>{rendered_p}</p>")

        return "\n".join(out)

    def _render_table(
        self, headers: List[str], aligns: List[str], rows: List[List[str]]
    ) -> str:
        ncols = max(len(headers), len(aligns))
        aligns = aligns + ["left"] * (ncols - len(aligns))
        parts = ['<div class="table-wrap"><table><thead><tr>']
        for idx in range(ncols):
            h_txt = headers[idx] if idx < len(headers) else ""
            parts.append(
                f'<th style="text-align:{aligns[idx]}">{self.render_inline(h_txt)}</th>'
            )
        parts.append("</tr></thead><tbody>")
        for row in rows:
            parts.append("<tr>")
            for idx in range(ncols):
                c_txt = row[idx] if idx < len(row) else ""
                parts.append(
                    f'<td style="text-align:{aligns[idx]}">{self.render_inline(c_txt)}</td>'
                )
            parts.append("</tr>")
        parts.append("</tbody></table></div>")
        return "".join(parts)

    def _render_list(self, list_lines: List[str]) -> str:
        items: List[Tuple[int, bool, str]] = []
        for raw in list_lines:
            expanded = raw.replace("\t", "  ")
            m = re.match(r"^(\s*)(?:([-*+])|(\d+)\.)\s+(.*)$", expanded)
            if m:
                indent = len(m.group(1))
                is_ol = m.group(3) is not None
                items.append((indent, is_ol, m.group(4).strip()))
            elif items:
                prev_ind, prev_ol, prev_txt = items[-1]
                items[-1] = (prev_ind, prev_ol, prev_txt + " " + expanded.strip())

        def build(idx: int, base_indent: int) -> Tuple[str, int]:
            if idx >= len(items):
                return "", idx
            tag = "ol" if items[idx][1] else "ul"
            buf = [f"<{tag}>"]
            while idx < len(items) and items[idx][0] >= base_indent:
                ind, _, txt = items[idx]
                if ind > base_indent:
                    sub_html, idx = build(idx, ind)
                    if len(buf) > 1 and buf[-1].endswith("</li>"):
                        buf[-1] = buf[-1][:-5] + sub_html + "</li>"
                    else:
                        buf.append(f"<li>{sub_html}</li>")
                    continue
                buf.append(f"<li>{self.render_inline(txt)}</li>")
                idx += 1
            buf.append(f"</{tag}>")
            return "".join(buf), idx

        html_out, _ = build(0, items[0][0] if items else 0)
        return html_out

    def _render_carousel(self, body: str) -> str:
        slides = [s.strip() for s in re.split(r"<!--\s*slide\s*-->", body) if s.strip()]
        total = len(slides)
        cards: List[str] = []
        for idx, slide_md in enumerate(slides, 1):
            slide_html = self.render_blocks(slide_md, record_toc=False)
            cards.append(
                f'<article class="clip-card">'
                f'<div class="clip-index">{idx} of {total}</div>'
                f'<div class="clip-card-body">{slide_html}</div>'
                f"</article>"
            )
        return (
            f'<section class="clip-gallery" data-slide-count="{total}">'
            f'<div class="clip-gallery-grid">{"".join(cards)}</div>'
            f"</section>"
        )


# ---------------------------------------------------------------------------
# Dynamic Dashboard Telemetry Loader (Read-Only SQLite + loop_ledger.json)
# ---------------------------------------------------------------------------

DEPLOY_LABELS: Dict[str, str] = {
    "deploy:2c96a08d": "Early",
    "deploy:77352e02": "Deploy 2",
    "deploy:ba89bfdb": "Deploy 3",
    "deploy:49e1457a": "Deploy 4",
    "deploy:32ab101a": "Deploy 5",
    "deploy:b1fecacb": "Deploy 6",
    "deploy:bf1043b7": "Deploy 7",
    "deploy:73c70041": "Loop 28",
    "deploy:1d211c83": "Loop 34",
    "mqklxqnz_1cd044c1": "Loop 36",
    "ltxmxpzu_e45b61eb": "Loop 37",
    "mwskxoml_ffb8aaf1": "Loop 40",
    "womqlpsp_6917245e": "Loop 42",
    "qpqqolmk_3b21fe7a": "Loop 45",
    "oyzplryr_dc3a33b6": "Loop 48",
    "mmmkputx_6c3f9529": "Loop 50",
    "nkxlrsuk_4e7c6f39": "Loop 51",
    "tppnrnpo_22f810ed": "Loop 57",
    "wywkqtpl_668f47f8": "Loop 59C",
}

BOT_META: Dict[str, Dict[str, str]] = {
    "Mothman-P": {
        "race": "Protoss",
        "highlight": "Strong in PvT and Disruptor mid-game fights.",
    },
    "Mothman-T": {
        "race": "Terran",
        "highlight": "Highest v1 rating, backed by Bio-Tank-Medivac macro.",
    },
    "Mothman-Z": {
        "race": "Zerg",
        "highlight": "Undefeated in recent live ZvZ mirrors.",
    },
    "Mothman-X": {
        "race": "Random",
        "highlight": "Rotates Protoss, Terran, and Zerg on ladder.",
    },
    "Mothman-P2": {
        "race": "Protoss",
        "highlight": "Testing against stronger macro and proxy builds.",
    },
    "Mothman-T2": {
        "race": "Terran",
        "highlight": "Testing live Interference Matrix and 1-1-1 openings.",
    },
    "Mothman-Z2": {
        "race": "Zerg",
        "highlight": "Facing tighter timing pushes and Skytoss.",
    },
    "Mothman-X2": {
        "race": "Random",
        "highlight": "Includes a live win over 1624-Elo Enyo.",
    },
}

DEPLOY_ORDER: Dict[str, int] = {k: idx for idx, k in enumerate(DEPLOY_LABELS.keys())}


def load_aiarena_live_summary(brain_dir: Path, sqlite_path: Path) -> Dict[str, Any]:
    """Load live v1 (Div 9) + v2 (Div 5) AI Arena standings and opponent-Elo context."""
    race_names = {"P": "Protoss", "T": "Terran", "Z": "Zerg", "R": "Random"}
    result: Dict[str, Any] = {
        "available": False,
        "v2_bots": [],
        "v1_bots": [],
        "v2_opp_elo_avg": 0.0,
        "v2_opp_elo_min": 0,
        "v2_opp_elo_max": 0,
        "v2_nonmirror": {"w": 0, "l": 0, "t": 0},
        "v1_opp_elo_avg": 0.0,
        "v1_opp_elo_min": 0,
        "v1_opp_elo_max": 0,
        "v1_nonmirror": {"w": 0, "l": 0, "t": 0},
    }
    fetch_dirs = [
        Path("/tmp/aiarena_v1_v2_fetch"),
        brain_dir / "scratch" / "loop" / "aiarena_v1_v2_fetch",
    ]
    ai_dir = next((d for d in fetch_dirs if (d / "all_bots_summary.json").is_file()), None)
    if not ai_dir:
        return result

    try:
        summary = json.loads((ai_dir / "all_bots_summary.json").read_text(encoding="utf-8"))
    except Exception:
        return result

    # Aggregate non-mirror match metadata (*_meta.json) for avg opponent Elo & per-bot non-mirror records
    by_bot_nm: Dict[str, Dict[str, Any]] = {}
    v1_elos: List[int] = []
    v2_elos: List[int] = []
    for mf in sorted(ai_dir.glob("*_meta.json")):
        try:
            m = json.loads(mf.read_text(encoding="utf-8"))
        except Exception:
            continue
        if m.get("both_ours"):
            continue
        coh = str(m.get("our_bot_cohort") or "")
        bname = str(m.get("our_bot_name") or "")
        oelo = m.get("opp_elo_before")
        res = str(m.get("result") or "").lower()
        ent = by_bot_nm.setdefault(bname, {"w": 0, "l": 0, "t": 0, "elos": []})
        if res == "win":
            ent["w"] += 1
        elif res == "loss":
            ent["l"] += 1
        elif res:
            ent["t"] += 1
        if isinstance(oelo, (int, float)) and oelo > 0:
            ent["elos"].append(int(oelo))
            if coh == "v2":
                v2_elos.append(int(oelo))
            elif coh == "v1":
                v1_elos.append(int(oelo))
        if coh == "v2":
            if res == "win":
                result["v2_nonmirror"]["w"] += 1
            elif res == "loss":
                result["v2_nonmirror"]["l"] += 1
            elif res:
                result["v2_nonmirror"]["t"] += 1
        elif coh == "v1":
            if res == "win":
                result["v1_nonmirror"]["w"] += 1
            elif res == "loss":
                result["v1_nonmirror"]["l"] += 1
            elif res:
                result["v1_nonmirror"]["t"] += 1

    if v2_elos:
        result["v2_opp_elo_avg"] = round(sum(v2_elos) / len(v2_elos), 1)
        result["v2_opp_elo_min"] = min(v2_elos)
        result["v2_opp_elo_max"] = max(v2_elos)
    if v1_elos:
        result["v1_opp_elo_avg"] = round(sum(v1_elos) / len(v1_elos), 1)
        result["v1_opp_elo_min"] = min(v1_elos)
        result["v1_opp_elo_max"] = max(v1_elos)

    # Pull recent SQLite trade ratios for v1 bots so v1 rows include trade efficiency
    v1_trade_by_bot: Dict[str, Tuple[int, int, float]] = {}
    if sqlite_path.is_file():
        try:
            con = sqlite3.connect(f"file:{sqlite_path}?mode=ro", uri=True)
            for bname, bw, bl, btr in con.execute(
                """
                SELECT bot,
                       SUM(CASE WHEN LOWER(result)='win' THEN 1 ELSE 0 END),
                       SUM(CASE WHEN LOWER(result)='loss' THEN 1 ELSE 0 END),
                       ROUND(SUM(killed_val)*1.0/NULLIF(SUM(lost_val),0), 2)
                FROM matches
                WHERE source_type='prod_aiarena' AND COALESCE(is_selfplay,0)=0
                  AND bot_build_version IN ('womqlpsp_6917245e', 'qpqqolmk_3b21fe7a', 'oyzplryr_dc3a33b6', 'mmmkputx_6c3f9529', 'nkxlrsuk_4e7c6f39', 'tppnrnpo_22f810ed')
                GROUP BY bot
                """
            ).fetchall():
                v1_trade_by_bot[str(bname)] = (int(bw or 0), int(bl or 0), float(btr or 0.0))
            con.close()
        except Exception:
            pass

    bots_by_name = {str(b.get("name") or ""): b for b in summary.get("bots", []) if isinstance(b, dict)}
    for cohort_key, names in (
        ("v2_bots", ("Mothman-P2", "Mothman-T2", "Mothman-Z2", "Mothman-X2")),
        ("v1_bots", ("Mothman-P", "Mothman-T", "Mothman-Z", "Mothman-X")),
    ):
        rows = []
        for bname in names:
            b = bots_by_name.get(bname)
            if not b:
                continue
            cp = b.get("competition_participation") or {}
            if not cp.get("active"):
                continue
            rlabel = str((b.get("plays_race") or {}).get("label") or "")
            race = race_names.get(rlabel, BOT_META.get(bname, {}).get("race", rlabel))
            nm = by_bot_nm.get(bname, {"w": 0, "l": 0, "t": 0, "elos": []})
            opp_avg = round(sum(nm["elos"]) / len(nm["elos"])) if nm["elos"] else 0
            rec_w, rec_l, rec_tr = v1_trade_by_bot.get(bname, (0, 0, 0.0))
            rows.append(
                {
                    "bot": bname,
                    "race": race,
                    "division": int(cp.get("division_num") or 0),
                    "elo": int(cp.get("elo") or 1600),
                    "w": int(cp.get("win_count") or 0),
                    "l": int(cp.get("loss_count") or 0),
                    "t": int(cp.get("tie_count") or 0),
                    "win_perc": round(float(cp.get("win_perc") or 0.0), 1),
                    "crashes": int(cp.get("crash_count") or 0),
                    "nm_w": nm["w"],
                    "nm_l": nm["l"],
                    "nm_t": nm["t"],
                    "opp_elo_avg": opp_avg,
                    "recent_w": rec_w,
                    "recent_l": rec_l,
                    "recent_trade": rec_tr,
                    "highlight": BOT_META.get(bname, {}).get("highlight", ""),
                }
            )
        result[cohort_key] = rows

    result["available"] = bool(result["v2_bots"] or result["v1_bots"])
    return result


def load_dashboard_telemetry(sqlite_path: Path) -> Dict[str, Any]:
    """Read live AI Arena & map-symmetry telemetry read-only from SQLite with clean fallbacks."""
    data: Dict[str, Any] = {
        "bots": [
            {"bot": "Mothman-P", "race": "Protoss", "elo": 1286, "w": 6, "l": 5, "trade": 0.59, "sb": 4.6, "highlight": BOT_META["Mothman-P"]["highlight"]},
            {"bot": "Mothman-T", "race": "Terran", "elo": 1267, "w": 7, "l": 3, "trade": 1.39, "sb": 1.5, "highlight": BOT_META["Mothman-T"]["highlight"]},
            {"bot": "Mothman-Z", "race": "Zerg", "elo": 1239, "w": 6, "l": 5, "trade": 0.60, "sb": 4.7, "highlight": BOT_META["Mothman-Z"]["highlight"]},
            {"bot": "Mothman-X", "race": "Random", "elo": 1277, "w": 10, "l": 7, "trade": 0.61, "sb": 4.2, "highlight": BOT_META["Mothman-X"]["highlight"]},
        ],
        "latest_build_label": "Loop 40",
        "latest_build_n": 16,
        "latest_build_w": 6,
        "latest_build_l": 9,
        "latest_build_trade": 0.55,
        "prev_build_label": "Loop 37",
        "prev_build_n": 34,
        "prev_build_w": 23,
        "prev_build_l": 11,
        "prev_build_trade": 0.82,
        "prod_series": [
            {"label": "Early", "n": 10, "wr": 0.0, "trade": 0.14},
            {"label": "Deploy 2", "n": 71, "wr": 12.7, "trade": 0.32},
            {"label": "Deploy 4", "n": 36, "wr": 13.9, "trade": 0.36},
            {"label": "Deploy 6", "n": 33, "wr": 33.3, "trade": 0.39},
            {"label": "Deploy 7", "n": 33, "wr": 42.4, "trade": 0.58},
            {"label": "Loop 28", "n": 50, "wr": 54.0, "trade": 0.51},
            {"label": "Loop 34", "n": 9, "wr": 44.4, "trade": 0.56},
            {"label": "Loop 36", "n": 12, "wr": 41.7, "trade": 0.57},
            {"label": "Loop 37", "n": 34, "wr": 67.6, "trade": 0.82},
            {"label": "Loop 40", "n": 9, "wr": 55.6, "trade": 1.33},
        ],
        "symmetry": {
            "all_before_n": 28.0,
            "all_before_s": 32.7,
            "all_after_n": 29.4,
            "all_after_s": 26.4,
            "ley_before_ne": 21.7,
            "ley_before_sw": 37.8,
            "ley_after_ne": 32.1,
            "ley_after_sw": 25.0,
            "post_n": 426,
        },
        "total_replays": 2666,
    }
    if not sqlite_path.is_file():
        return data

    try:
        con = sqlite3.connect(f"file:{sqlite_path}?mode=ro", uri=True)
        cur = con.cursor()
        total_replays = cur.execute("SELECT COUNT(*) FROM matches").fetchone()[0]
        if total_replays:
            data["total_replays"] = int(total_replays)

        # Build chronological prod series (only builds with >= 8 matches)
        # NOTE: AI Arena match IDs reflect queue creation, NOT chronological play order,
        # so sort explicitly by DEPLOY_ORDER first and MAX(aiarena_match_id) for new builds.
        rows = cur.execute(
            """
            SELECT COALESCE(bot_build_version, 'unknown') AS bv,
                   COUNT(*) AS n,
                   SUM(CASE WHEN LOWER(result)='win' THEN 1 ELSE 0 END) AS w,
                   SUM(CASE WHEN LOWER(result)='loss' THEN 1 ELSE 0 END) AS l,
                   ROUND(SUM(killed_val)*1.0 / NULLIF(SUM(lost_val),0), 2) AS tr,
                   MAX(COALESCE(aiarena_match_id, replay_id)) AS last_id
            FROM matches
            WHERE source_type='prod_aiarena' AND COALESCE(is_selfplay,0)=0
            GROUP BY bv
            HAVING COUNT(*) >= 8
            """
        ).fetchall()
        rows.sort(key=lambda r: (DEPLOY_ORDER.get(r[0], 10_000), int(r[5] or 0)))
        if len(rows) >= 4:
            # Keep major milestones (up to 10 points for clean SVG readability)
            keep_rows = [r for r in rows if r[0] in DEPLOY_LABELS or not r[0].startswith("deploy:")]
            if len(keep_rows) > 10:
                keep_rows = [keep_rows[0]] + keep_rows[-9:]
            series = []
            for bv, n, w, l, tr, _ in keep_rows:
                lbl = DEPLOY_LABELS.get(bv, bv[:8])
                series.append(
                    {
                        "bv": bv,
                        "label": lbl,
                        "n": int(n),
                        "w": int(w),
                        "l": int(l),
                        "wr": round(100.0 * w / n, 1) if n else 0.0,
                        "trade": float(tr) if tr is not None else 0.0,
                    }
                )
            if series:
                data["prod_series"] = series
                latest = series[-1]
                data["latest_build_label"] = latest["label"]
                data["latest_build_n"] = latest["n"]
                data["latest_build_w"] = latest["w"]
                data["latest_build_l"] = latest["l"]
                data["latest_build_trade"] = latest["trade"]
                if len(series) >= 2:
                    prev = series[-2]
                    data["prev_build_label"] = prev["label"]
                    data["prev_build_n"] = prev["n"]
                    data["prev_build_w"] = prev["w"]
                    data["prev_build_l"] = prev["l"]
                    data["prev_build_trade"] = prev["trade"]

                recent_bvs = [s["bv"] for s in series[-2:] if "bv" in s]
                if recent_bvs:
                    placeholders = ",".join("?" for _ in recent_bvs)
                    bot_rows = cur.execute(
                        f"""
                        SELECT bot,
                               SUM(CASE WHEN LOWER(result)='win' THEN 1 ELSE 0 END) AS w,
                               SUM(CASE WHEN LOWER(result)='loss' THEN 1 ELSE 0 END) AS l,
                               ROUND(SUM(killed_val)*1.0 / NULLIF(SUM(lost_val),0), 2) AS tr,
                               ROUND(AVG(sup_blk_pct), 1) AS sb,
                               MAX(aiarena_bot_elo) AS elo
                        FROM matches
                        WHERE source_type='prod_aiarena' AND COALESCE(is_selfplay,0)=0
                          AND bot_build_version IN ({placeholders})
                        GROUP BY bot
                        ORDER BY bot
                        """,
                        recent_bvs,
                    ).fetchall()
                    by_bot = {r[0]: r for r in bot_rows}
                    updated_bots = []
                    for bname in ("Mothman-P", "Mothman-T", "Mothman-Z", "Mothman-X"):
                        meta = BOT_META[bname]
                        if bname in by_bot:
                            _, bw, bl, btr, bsb, belo = by_bot[bname]
                            updated_bots.append(
                                {
                                    "bot": bname,
                                    "race": meta["race"],
                                    "elo": int(belo) if belo else 1600,
                                    "w": int(bw or 0),
                                    "l": int(bl or 0),
                                    "trade": float(btr or 0.0),
                                    "sb": float(bsb or 0.0),
                                    "highlight": meta["highlight"],
                                }
                            )
                    if len(updated_bots) == 4:
                        data["bots"] = updated_bots

        # North vs South symmetry comparison
        def query_ns(cond: str, map_like: Optional[str] = None) -> Dict[str, Tuple[int, float]]:
            extra = "AND m.map_name LIKE ?" if map_like else ""
            params = (map_like,) if map_like else ()
            q = f"""
                SELECT CASE WHEN m.our_spawn_corner IN ('NW','NE') THEN 'N' ELSE 'S' END AS side,
                       COUNT(*),
                       ROUND(100.0*SUM(CASE WHEN LOWER(m.result)='win' THEN 1 ELSE 0 END)/COUNT(*), 1)
                FROM matches m
                WHERE m.source_type='local_arena' AND COALESCE(m.is_selfplay,0)=0
                  AND m.run_id NOT LIKE '%h2h%' AND m.run_id NOT LIKE '%smoke%'
                  AND m.our_spawn_corner IN ('NW','NE','SW','SE')
                  AND ({cond})
                  {extra}
                GROUP BY side
            """
            out_d: Dict[str, Tuple[int, float]] = {}
            for side, cnt, wr in cur.execute(q, params).fetchall():
                out_d[side] = (int(cnt), float(wr or 0.0))
            return out_d

        pre_cond = (
            "m.run_id LIKE '%iter1%' OR m.run_id LIKE '%iter2%' "
            "OR m.run_id LIKE '%iter30%' OR m.run_id LIKE '%iter31%' "
            "OR m.run_id LIKE '%iter32%' OR m.run_id LIKE '%iter33%'"
        )
        post_cond = (
            "m.run_id LIKE '%iter37%' OR m.run_id LIKE '%iter38%' "
            "OR m.run_id LIKE '%iter39%' OR m.run_id LIKE '%iter4%'"
        )
        all_pre = query_ns(pre_cond)
        all_post = query_ns(post_cond)
        ley_pre = query_ns(pre_cond, "%Ley%")
        ley_post = query_ns(post_cond, "%Ley%")
        if all_pre.get("N") and all_pre.get("S") and all_post.get("N") and all_post.get("S"):
            data["symmetry"]["all_before_n"] = all_pre["N"][1]
            data["symmetry"]["all_before_s"] = all_pre["S"][1]
            data["symmetry"]["all_after_n"] = all_post["N"][1]
            data["symmetry"]["all_after_s"] = all_post["S"][1]
            data["symmetry"]["post_n"] = all_post["N"][0] + all_post["S"][0]
        if ley_pre.get("N") and ley_pre.get("S") and ley_post.get("N") and ley_post.get("S"):
            data["symmetry"]["ley_before_ne"] = ley_pre["N"][1]
            data["symmetry"]["ley_before_sw"] = ley_pre["S"][1]
            data["symmetry"]["ley_after_ne"] = ley_post["N"][1]
            data["symmetry"]["ley_after_sw"] = ley_post["S"][1]
        con.close()
    except Exception as exc:
        print(f"  [note] SQLite dashboard telemetry fallback ({exc})", file=sys.stderr)
    return data


# ---------------------------------------------------------------------------
# Calm Inline Editorial SVG Charts (Zero JS Dependencies)
# ---------------------------------------------------------------------------


def render_live_progress_svg(series: List[Dict[str, Any]]) -> str:
    w, h = 560, 290
    pl, pr, pt, pb = 42, 46, 40, 44
    cw = w - pl - pr
    ch = h - pt - pb
    n = max(1, len(series))
    tr_vals = [float(s["trade"]) for s in series if s.get("trade") is not None]
    max_tr = max(1.4, max(tr_vals, default=1.0) + 0.15)
    max_tr = 1.6 if max_tr > 1.25 else 1.2

    def x_at(idx: int) -> float:
        return pl + (cw * idx / max(1, n - 1)) if n > 1 else pl + cw / 2.0

    def y_wr(val: float) -> float:
        return pt + ch - (max(0.0, min(80.0, val)) / 80.0) * ch

    def y_tr(val: float) -> float:
        return pt + ch - (max(0.0, min(max_tr, val)) / max_tr) * ch

    parts = [
        f'<svg viewBox="0 0 {w} {h}" class="chart-svg" role="img" '
        f'aria-label="Live AI Arena win rate and trade ratio across builds">',
    ]
    # Horizontal gridlines (0%, 20%, 40%, 60%, 80% WR)
    for pct in (0, 20, 40, 60, 80):
        yy = y_wr(pct)
        parts.append(
            f'<line x1="{pl}" y1="{yy:.1f}" x2="{w-pr}" y2="{yy:.1f}" '
            f'stroke="#E3E0D6" stroke-width="1" />'
        )
        parts.append(
            f'<text x="{pl-8}" y="{yy+3.5:.1f}" text-anchor="end" '
            f'fill="#7A7870" font-size="10.5">{pct}%</text>'
        )
    # Right-axis trade ratio labels
    tr_ticks = (0.0, 0.5, 1.0, 1.5) if max_tr > 1.25 else (0.0, 0.4, 0.8, 1.2)
    for tr_v in tr_ticks:
        yy = y_tr(tr_v)
        parts.append(
            f'<text x="{w-pr+8}" y="{yy+3.5:.1f}" text-anchor="start" '
            f'fill="#4A6B82" font-size="10.5">{tr_v:.1f}×</text>'
        )
    # Subtle 1.0x break-even reference line with direct label
    y_even = y_tr(1.0)
    parts.append(
        f'<line x1="{pl}" y1="{y_even:.1f}" x2="{w-pr}" y2="{y_even:.1f}" '
        f'stroke="#C9C5B8" stroke-width="1" stroke-dasharray="3,3" />'
        f'<text x="{pl+4}" y="{y_even-5:.1f}" fill="#7A7870" font-size="9.5">1.0× even trade</text>'
    )

    wr_pts = " ".join(f"{x_at(i):.1f},{y_wr(s['wr']):.1f}" for i, s in enumerate(series))
    tr_pairs = [(i, float(s["trade"])) for i, s in enumerate(series) if s.get("trade") is not None]
    tr_pts = " ".join(f"{x_at(i):.1f},{y_tr(v):.1f}" for i, v in tr_pairs)

    parts.append(
        f'<polyline fill="none" stroke="#C4633E" stroke-width="2.4" '
        f'stroke-linejoin="round" stroke-linecap="round" points="{wr_pts}" />'
    )
    if len(tr_pairs) >= 2:
        parts.append(
            f'<polyline fill="none" stroke="#4A6B82" stroke-width="2" '
            f'stroke-dasharray="5,3" stroke-linejoin="round" stroke-linecap="round" points="{tr_pts}" />'
        )

    # Select well-spaced x-axis tick indices so labels never touch
    tick_indices = {0, n - 1}
    if n >= 3:
        tick_indices.add(n - 2)
    if n >= 6:
        tick_indices.add(n // 2)
    if n >= 8:
        tick_indices.add(2)

    for i, s in enumerate(series):
        xx = x_at(i)
        yw = y_wr(s["wr"])
        tr_v = s.get("trade")
        lbl = html.escape(str(s["label"]))
        if tr_v is not None:
            tip = f"{lbl}: {s['wr']:.1f}% wins, {float(tr_v):.2f}× trade (n={s['n']})"
        else:
            tip = f"{lbl}: {s['wr']:.1f}% wins (n={s['n']})"
        parts.append(
            f'<circle cx="{xx:.1f}" cy="{yw:.1f}" r="3.6" fill="#C4633E" stroke="#F4F2EA" stroke-width="1.2">'
            f"<title>{tip}</title></circle>"
        )
        if tr_v is not None:
            yt = y_tr(float(tr_v))
            parts.append(
                f'<circle cx="{xx:.1f}" cy="{yt:.1f}" r="3.3" fill="#4A6B82" stroke="#F4F2EA" stroke-width="1.2">'
                f"<title>{tip}</title></circle>"
            )
        if i in tick_indices:
            short_lbl = re.sub(r"^Loop\s+", "L", lbl) if i >= n - 2 else lbl
            parts.append(
                f'<text x="{xx:.1f}" y="{h-pb+17}" text-anchor="middle" '
                f'fill="#5E5D59" font-size="10">{short_lbl}</text>'
            )

    # Direct peak & latest labels (strictly inside plot bounds, collision-free)
    if len(series) >= 2:
        peak_idx = max(range(len(series)), key=lambda idx: series[idx]["wr"])
        peak = series[peak_idx]
        px = x_at(peak_idx)
        py = y_wr(peak["wr"])
        anchor = "end" if peak_idx >= n - 2 else "middle"
        dx = -7 if peak_idx >= n - 2 else 0
        parts.append(
            f'<text x="{px+dx:.1f}" y="{max(pt+10, py-9):.1f}" '
            f'text-anchor="{anchor}" fill="#C4633E" font-size="10.5" font-weight="600">'
            f'{peak["wr"]:.1f}%</text>'
        )
        if peak_idx != n - 1:
            last = series[-1]
            lx = x_at(n - 1)
            ly_wr = y_wr(last["wr"])
            parts.append(
                f'<text x="{lx - 2.0:.1f}" y="{max(pt+10, ly_wr - 9.0):.1f}" '
                f'text-anchor="end" fill="#C4633E" font-size="10.5" font-weight="600">'
                f'{last["wr"]:.1f}%</text>'
            )
        if tr_pairs:
            last_tr_idx, last_tr_val = tr_pairs[-1]
            lx_tr = x_at(last_tr_idx)
            ly_tr = y_tr(last_tr_val)
            tr_y = min(h - pb - 4.0, ly_tr + 17.0)
            tr_anchor = "end" if last_tr_idx >= n - 1 else "middle"
            parts.append(
                f'<text x="{lx_tr + (2.0 if tr_anchor == "end" else 0.0):.1f}" y="{tr_y:.1f}" '
                f'text-anchor="{tr_anchor}" fill="#4A6B82" font-size="10.5" font-weight="600">'
                f"{last_tr_val:.2f}×</text>"
            )

    # Inline legend top-left
    parts.append(
        f'<line x1="{pl}" y1="14" x2="{pl+18}" y2="14" stroke="#C4633E" stroke-width="2.4" />'
        f'<text x="{pl+23}" y="17.5" fill="#141413" font-size="11" font-weight="500">Win rate (%)</text>'
        f'<line x1="{pl+112}" y1="14" x2="{pl+130}" y2="14" stroke="#4A6B82" stroke-width="2" stroke-dasharray="4,2" />'
        f'<text x="{pl+135}" y="17.5" fill="#141413" font-size="11" font-weight="500">Trade ratio (×)</text>'
    )
    parts.append("</svg>")
    return "".join(parts)


def render_symmetry_svg(sym: Dict[str, Any]) -> str:
    w, h = 560, 272
    pl, pr, pt, pb = 112, 42, 36, 34
    cw = w - pl - pr
    max_val = 45.0

    groups = [
        ("Ley Lines", "Before fix", sym["ley_before_ne"], sym["ley_before_sw"]),
        ("Ley Lines", "After fix", sym["ley_after_ne"], sym["ley_after_sw"]),
        ("All 7 maps", "Before fix", sym["all_before_n"], sym["all_before_s"]),
        ("All 7 maps", "After fix", sym["all_after_n"], sym["all_after_s"]),
    ]

    def x_val(v: float) -> float:
        return pl + (max(0.0, min(max_val, v)) / max_val) * cw

    parts = [
        f'<svg viewBox="0 0 {w} {h}" class="chart-svg" role="img" '
        f'aria-label="North versus South spawn win rate before and after map symmetry fix">',
    ]
    # Vertical gridlines
    for pct in (0, 10, 20, 30, 40):
        xx = x_val(pct)
        parts.append(
            f'<line x1="{xx:.1f}" y1="{pt-4}" x2="{xx:.1f}" y2="{h-pb}" '
            f'stroke="#E3E0D6" stroke-width="1" />'
        )
        parts.append(
            f'<text x="{xx:.1f}" y="{h-pb+16}" text-anchor="middle" '
            f'fill="#7A7870" font-size="10.5">{pct}%</text>'
        )

    # Legend top-left
    parts.append(
        f'<rect x="{pl}" y="8" width="11" height="11" rx="2" fill="#C4633E" />'
        f'<text x="{pl+16}" y="17" fill="#141413" font-size="11" font-weight="500">North spawn</text>'
        f'<rect x="{pl+108}" y="8" width="11" height="11" rx="2" fill="#A6A195" />'
        f'<text x="{pl+124}" y="17" fill="#141413" font-size="11" font-weight="500">South spawn</text>'
    )

    row_step = (h - pt - pb) / len(groups)
    bar_h = 14
    for idx, (mname, phase, north_wr, south_wr) in enumerate(groups):
        y0 = pt + idx * row_step + 4
        if idx == 2:
            parts.append(
                f'<line x1="12" y1="{y0-6:.1f}" x2="{w-pr}" y2="{y0-6:.1f}" '
                f'stroke="#DFDCD1" stroke-width="1" />'
            )
        parts.append(
            f'<text x="{pl-10}" y="{y0+12:.1f}" text-anchor="end" '
            f'fill="#141413" font-size="11.5" font-weight="600">{mname}</text>'
        )
        parts.append(
            f'<text x="{pl-10}" y="{y0+25:.1f}" text-anchor="end" '
            f'fill="#7A7870" font-size="10">{phase}</text>'
        )
        wn = max(2.0, x_val(north_wr) - pl)
        ws = max(2.0, x_val(south_wr) - pl)
        parts.append(
            f'<rect x="{pl}" y="{y0:.1f}" width="{wn:.1f}" height="{bar_h}" rx="2.5" fill="#C4633E">'
            f"<title>{mname} ({phase}) North: {north_wr:.1f}%</title></rect>"
        )
        parts.append(
            f'<text x="{pl+wn+6:.1f}" y="{y0+11:.1f}" fill="#A34E2E" font-size="10.5" font-weight="600">'
            f"{north_wr:.1f}%</text>"
        )
        parts.append(
            f'<rect x="{pl}" y="{y0+bar_h+3:.1f}" width="{ws:.1f}" height="{bar_h}" rx="2.5" fill="#A6A195">'
            f"<title>{mname} ({phase}) South: {south_wr:.1f}%</title></rect>"
        )
        parts.append(
            f'<text x="{pl+ws+6:.1f}" y="{y0+bar_h+14:.1f}" fill="#5E5D59" font-size="10.5">'
            f"{south_wr:.1f}%</text>"
        )

    parts.append("</svg>")
    return "".join(parts)


# ---------------------------------------------------------------------------
# Video Gallery & Featured Clips Discovery (Loop 42+ MP4 + Latest WebP Clips)
# ---------------------------------------------------------------------------


def _race_full(code: str) -> str:
    c = (code or "").strip().lower()
    if c.startswith("p") or "mothman-p" in c:
        return "Protoss"
    if c.startswith("t") or "mothman-t" in c:
        return "Terran"
    if c.startswith("z") or "mothman-z" in c:
        return "Zerg"
    if c.startswith("x") or "random" in c:
        return "Random"
    return "Other"


def _outcome_norm(res: str) -> str:
    r = (res or "").strip().lower()
    if r in ("win", "pass", "p1_win", "ko_win"):
        return "win"
    if r in ("loss", "fail", "p2_win", "ko_loss"):
        return "loss"
    return "tie"


_DRILL_WORD_MAP: Dict[str, str] = {
    "vs": "vs.",
    "dt": "DT",
    "pf": "PF",
    "bc": "BC",
    "bcs": "BCs",
    "scv": "SCV",
    "scvs": "SCVs",
    "hp": "HP",
    "aa": "AA",
    "emp": "EMP",
    "aam": "AAM",
    "ht": "HT",
    "hts": "HTs",
    "obs": "Observer",
    "pvp": "PvP",
    "pvt": "PvT",
    "pvz": "PvZ",
    "tvp": "TvP",
    "tvt": "TvT",
    "tvz": "TvZ",
    "zvp": "ZvP",
    "zvt": "ZvT",
    "zvz": "ZvZ",
    "bio": "Bio",
    "muta": "Mutalisks",
    "mutas": "Mutalisks",
    "ling": "Zerglings",
    "lings": "Zerglings",
    "lingbane": "Ling-Bane",
    "6ling": "6-Zergling",
    "kd8": "KD8",
    "blindingcloud": "Blinding Cloud",
    "pbomb": "Parasitic Bomb",
    "blueflame": "Blue-Flame",
    "magicbox": "Magic-Box",
    "planetary": "Planetary Fortress",
    "dropperlord": "Dropperlord",
    "widowmines": "Widow Mines",
    "voidray": "Void Ray",
    "voidrays": "Void Rays",
    "sac": "Sacrifice",
    "15probe": "15-Probe",
    "12pool": "12-Pool",
    "3adept": "3-Adept",
    "nonblink": "Non-Blink",
    "lowhp": "Low-HP",
    "warpprism": "Warp Prism",
    "warpin": "Warp-In",
    "widowmine": "Widow Mine",
    "highground": "High-Ground",
    "imatrix": "Interference Matrix",
    "halluc": "Hallucinated",
    "robo": "Robotics",
    "dts": "Dark Templars",
    "leylines": "Ley Lines",
}

_DRILL_TITLE_OVERRIDES: Dict[str, str] = {
    "sc2-reg-r03-iter37-m42-pvz-ramp-hold-vs-ling-flood": "High-Ground Ramp Hold vs. Zergling Flood",
    "sc2-reg-r15-tvp-full-lifecycle-vs-15-kiting-probes": "SCV Hold vs. 15 Kiting Probes",
}


def _format_drill_title(sid: str) -> str:
    """Turn scenario IDs like sc2-det-d10-t-cloaked-banshee-... into clean English titles."""
    sid_clean = sid.strip()
    if sid_clean in _DRILL_TITLE_OVERRIDES:
        return _DRILL_TITLE_OVERRIDES[sid_clean]
    s = re.sub(
        r"^sc2-(?:ab|air|blk|brw|cap|def|det|econ|flk|kit|nc|real|reg|rmp|rsh|runby|spl|sta|trn|yam)-",
        "",
        sid_clean,
        flags=re.I,
    )
    # Strip short scenario code prefix (e.g. d10-, p15-, 01-, ro01-, rd03-, r14-, b01-, y01-, prod5140013-)
    s = re.sub(r"^(?:[a-z]{0,3}\d{1,2})-", "", s, flags=re.I)
    s = re.sub(r"^prod\d+-", "", s, flags=re.I)
    s = re.sub(r"^iter\d+-m\d+-", "", s, flags=re.I)
    # Strip leading single race letter or matchup token when followed by descriptive words
    s = re.sub(r"^(?:p|t|z|pvp|pvt|pvz|tvp|tvt|tvz|zvp|zvt|zvz)-", "", s, flags=re.I)
    # Keep compound hyphenated unit/ability pairs intact before tokenizing
    s = re.sub(r"\bling-bane\b", "lingbane", s, flags=re.I)
    s = re.sub(r"\bwarp-in\b", "warpin", s, flags=re.I)
    tokens = [tok for tok in re.split(r"[-_\s]+", s) if tok]
    out: List[str] = []
    for idx, tok in enumerate(tokens):
        low = tok.lower()
        if low == "5014":
            continue
        if low in _DRILL_WORD_MAP:
            out.append(_DRILL_WORD_MAP[low])
        elif 0 < idx < len(tokens) - 1 and low in ("and", "or", "in", "on", "to", "of", "the", "with", "into", "from", "then", "for"):
            out.append(low)
        else:
            out.append(tok.capitalize())
    return " ".join(out) if out else sid


def _format_trade_label(tr: Any, outcome: str) -> str:
    """Format trade ratio cleanly, hiding the 99.00x zero-death sentinel on losses."""
    if not isinstance(tr, (int, float)):
        return ""
    val = float(tr)
    if val >= 90.0:
        return "0 units lost" if outcome == "win" else ""
    return f"{val:.2f}× trade"


def _clean_drill_caption(desc: str) -> str:
    """Strip scenario metadata prefixes and internal tags without mid-phrase slicing."""
    s = str(desc or "").strip()
    s = re.sub(
        r"^(?:Ability-Mastery|Non-Combat|Real SC2|Pro-DB|Match-forensics|Replay Regression|Econ-Harass)[^:]{0,84}:\s*",
        "",
        s,
        flags=re.I,
    )
    if ":" in s:
        head, tail = s.split(":", 1)
        if len(head.strip()) <= 76 and len(tail.strip()) >= 24:
            s = tail.strip()
    s = s.replace("`", "")
    s = re.sub(r"\bW\d+-(?:TAC|EARLY|LOOP)-\d+[a-z]?(?:/\d+)?\s*", "", s)
    s = re.sub(r"\s*\(guards\s+[^)]+\)", "", s, flags=re.I)
    s = re.sub(r",?\s*\bguards\s+arena-minimax\s+retreat\b", "", s, flags=re.I)
    # Strip raw SC2 numeric Ability IDs while keeping human-readable labels inside parens
    s = re.sub(r"\(\d{3,4}\s+([^()]+)\)", r"(\1)", s)
    s = re.sub(r"\(\d{3,4},\s*([^()]+)\)", r"(\1)", s)
    s = re.sub(r"\s*\(\d{2,4}(?:/\d{2,4})*\)", "", s)
    # Rewrite raw SC2 map-unit CamelCase names and shorthand abbreviations
    s = s.replace("MineralField450 (5M)", "5-mineral")
    s = s.replace("RichMineralField (7M)", "7-mineral rich")
    s = s.replace("BattleStationMineralField750 (150M)", "150-mineral")
    s = s.replace("(no IM)", "(no Interference Matrix)")
    s = re.sub(r"\bcasting AAM\b", "casting Anti-Armor Missile", s)
    s = s.replace("(0 AA)", "(no anti-air)")
    s = s.replace("(100e, 0 Obs)", "(100e, no Observers)")
    s = s.replace("(100e, 0 flyers)", "(100e, no flyers)")
    s = s.replace("(0 flyers)", "(no flyers)")
    s = re.sub(r"\bP2\s+active\b", "enemy", s)
    s = re.sub(r"\bP2\s+base\b", "enemy base", s)
    s = re.sub(r"\bBOTH\b", "both", s)
    s = re.sub(r"\bFIRST\b", "first", s)
    s = s.replace("DrillingClaws", "Drilling Claws")
    s = s.replace(
        "measures mined minerals + kills - 50*workers_lost over 960 loops",
        "measures mined minerals and kills minus worker losses",
    )
    s = s.replace(" — ", ": ")
    s = re.sub(r"\(\s*\)", "", s)
    s = re.sub(r"\(\s+", "(", s)
    s = re.sub(r"\s+\)", ")", s)
    s = re.sub(r"\s+", " ", s).strip()
    if len(s) <= 280:
        return s
    m_sent = re.match(r"^(.{60,280}?[.!?])(?:\s|$)", s)
    if m_sent:
        return m_sent.group(1)
    m_paren = re.match(r"^(.{60,280}?)\s*\(", s)
    if m_paren:
        return m_paren.group(1).rstrip(" ,;:-") + "."
    return s


def _format_ledger_record(rec_raw: str) -> str:
    """Extract concise W-L-T (WR% win, NL% win+tie) from raw loop_ledger record strings."""
    s = str(rec_raw or "").strip()
    m = re.search(r"(\d+)\s*W\s*[-–]\s*(\d+)\s*L(?:\s*[-–]\s*(\d+)\s*T)?", s, flags=re.I)
    if not m:
        return s if len(s) <= 44 else s[:41].rsplit(" ", 1)[0] + "…"
    w = int(m.group(1))
    l = int(m.group(2))
    t = int(m.group(3) or 0)
    tot = w + l + t
    rec = f"{w}–{l}–{t}" if t else f"{w}–{l}"
    if tot <= 0:
        return rec
    wr = 100.0 * w / tot
    nl = 100.0 * (w + t) / tot
    if t:
        return f"{rec} ({wr:.1f}% win, {nl:.1f}% win+tie)"
    return f"{rec} ({wr:.1f}% win)"


def discover_gallery_items(
    brain_dir: Path,
    media_by_tag: Dict[str, Dict[str, str]],
    abs_to_asset: Dict[str, Tuple[str, str]],
) -> List[Dict[str, Any]]:
    """Build unified item list for video-gallery.html & front-page featured clips.
    Automatically includes Loop 42+ full_matches_manifest.json (90/90) and
    arena/selfplay .mp4 manifests (116/116), plus curated latest-loop highlights.
    """
    items: List[Dict[str, Any]] = []

    def resolve_cdn(raw_path: Optional[str], base_dir: Path) -> Optional[str]:
        if not raw_path:
            return None
        p = Path(raw_path)
        if not p.is_absolute():
            p = (base_dir / p).resolve()
        s = str(p)
        if s in abs_to_asset:
            tag, aname = abs_to_asset[s]
            return media_by_tag.get(tag, {}).get(aname)
        tag, aname = classify_media_path(p)
        return media_by_tag.get(tag, {}).get(aname) or media_by_tag.get(tag, {}).get(p.name)

    full_manifests, arena_manifests = _iter_manifest_files(brain_dir)

    # 1. Loop 42+ Full-Length Match Videos (full_matches_manifest.json)
    for loop_num, mpath in sorted(full_manifests, reverse=True):
        try:
            data = json.loads(mpath.read_text(encoding="utf-8"))
        except Exception:
            continue
        for entry in data.get("matches", data.get("clips", [])):
            if not isinstance(entry, dict):
                continue
            raw_mp4_val = entry.get("mp4") or entry.get("video")
            mp4_local_p = None
            if raw_mp4_val and isinstance(raw_mp4_val, str):
                cand_p = Path(raw_mp4_val)
                if not cand_p.is_absolute():
                    cand_p = (mpath.parent / cand_p).resolve()
                if cand_p.is_file():
                    mp4_local_p = cand_p
            mp4_url = resolve_cdn(raw_mp4_val, mpath.parent)
            if not mp4_url and not mp4_local_p:
                continue
            png_url = resolve_cdn(entry.get("png"), mpath.parent) or ""
            our_bot = str(entry.get("our_bot") or "Mothman")
            opp_bot = str(entry.get("opp_bot") or "Opponent")
            mu = str(entry.get("matchup") or "")
            map_raw = str(entry.get("map_canon") or entry.get("map") or "")
            map_name = re.sub(r"(?:AIE_v\d+)?(?:\.SC2Map)?$", "", map_raw)
            result_raw = str(entry.get("result") or "")
            outcome = _outcome_norm(result_raw)
            tr = entry.get("trade_ratio")
            dur = entry.get("duration_sec")
            sb = entry.get("supply_blocked_pct")
            cohort = str(entry.get("cohort") or "match")
            mid = entry.get("match_id", "")
            meta_bits = []
            if mu:
                meta_bits.append(mu)
            if map_name:
                meta_bits.append(map_name)
            if isinstance(dur, (int, float)) and dur > 0:
                mins, secs = divmod(int(dur), 60)
                meta_bits.append(f"{mins}:{secs:02d}")
            tr_lbl = _format_trade_label(tr, outcome)
            if tr_lbl:
                meta_bits.append(tr_lbl)
            if isinstance(sb, (int, float)):
                meta_bits.append(f"{sb:.1f}% supply-blocked")
            items.append(
                {
                    "loop": f"Loop {loop_num}",
                    "loop_num": loop_num,
                    "category": "Full Matches",
                    "cohort": cohort,
                    "race": _race_full(str(entry.get("our_race") or our_bot)),
                    "outcome": outcome,
                    "result_label": result_raw.title() if result_raw else outcome.title(),
                    "title": f"#{mid} {our_bot} vs. {opp_bot}" if mid != "" else f"{our_bot} vs. {opp_bot}",
                    "subtitle": " · ".join(meta_bits),
                    "media_type": "mp4",
                    "playable_mp4": False,
                    "src": mp4_url or "",
                    "download_url": mp4_url or "",
                    "poster": png_url,
                    "_local_mp4": str(mp4_local_p) if mp4_local_p else "",
                    "_safe_name": f"l{loop_num}_match_{mp4_local_p.name}" if mp4_local_p else "",
                    "search": f"loop {loop_num} {mid} {our_bot} {opp_bot} {mu} {map_name} {cohort} {result_raw}".lower(),
                }
            )

    # 2. Loop 42+ Arena & Self-Play Drill MP4 Videos
    for loop_num, mode, mpath in sorted(arena_manifests, reverse=True):
        try:
            data = json.loads(mpath.read_text(encoding="utf-8"))
        except Exception:
            continue
        # Optionally enrich with tactics_sc2_{duel,selfplay}_iter<N>.json
        tactics_by_id: Dict[str, Dict[str, Any]] = {}
        t_name = f"tactics_sc2_{'duel' if mode == 'arena' else 'selfplay'}_iter{loop_num}.json"
        t_path = brain_dir / "scratch" / "loop" / t_name
        if t_path.is_file():
            try:
                tdata = json.loads(t_path.read_text(encoding="utf-8"))
                for sc in tdata.get("scenarios", tdata.get("results", [])):
                    if isinstance(sc, dict) and sc.get("id"):
                        tactics_by_id[str(sc["id"])] = sc
            except Exception:
                pass

        cat_label = "Tactics Drills" if mode == "arena" else "Self-Play Drills"
        for clip in data.get("clips", []):
            if not isinstance(clip, dict):
                continue
            mp4_raw = clip.get("mp4") or (
                clip.get("video") if str(clip.get("video", "")).lower().endswith(".mp4") else None
            )
            mp4_local_p = None
            if mp4_raw and isinstance(mp4_raw, str):
                cand_p = Path(mp4_raw)
                if not cand_p.is_absolute():
                    cand_p = (mpath.parent / cand_p).resolve()
                if cand_p.is_file() and not _is_placeholder_arena_clip(cand_p, clip):
                    mp4_local_p = cand_p
            if mp4_local_p is None and mp4_raw and "sp07" in str(mp4_raw).lower() and "probe_iter51_w2_5014" in str(mpath).lower():
                continue
            mp4_url = resolve_cdn(mp4_raw, mpath.parent)
            if not mp4_url and not mp4_local_p:
                continue
            png_url = resolve_cdn(clip.get("png"), mpath.parent) or ""
            sid = str(clip.get("scenario_id") or clip.get("id") or Path(str(mp4_raw)).stem)
            tinfo = tactics_by_id.get(sid, {})
            race_guess = str(tinfo.get("p1_race") or clip.get("race") or "")
            if not race_guess:
                if "-p" in sid or "_p" in sid:
                    race_guess = "Protoss"
                elif "-t" in sid or "_t" in sid:
                    race_guess = "Terran"
                elif "-z" in sid or "_z" in sid:
                    race_guess = "Zerg"
            winner_raw = str(clip.get("winner") or tinfo.get("winner") or "").strip().lower()
            win_type = str(clip.get("win_type") or tinfo.get("win_type") or "").strip().lower()
            if winner_raw in ("mothman", "mothman-p1", "p1"):
                outcome = "win"
                res_label = "Pass" if "econ" in win_type else "Win"
            elif winner_raw in ("microdummy", "mothman-p2", "p2"):
                outcome = "loss"
                res_label = "Fail" if "econ" in win_type else "Loss"
            elif winner_raw in ("draw", "tie"):
                outcome = "tie"
                res_label = "Draw"
            else:
                res_raw = str(tinfo.get("outcome") or tinfo.get("result") or clip.get("result") or "")
                outcome = _outcome_norm(res_raw) if res_raw else "win"
                res_label = res_raw.replace("_", " ").title() if res_raw else "Drill"
            tr = clip.get("trade_ratio") if clip.get("trade_ratio") is not None else tinfo.get("trade_ratio")
            tier_val = clip.get("tier") or tinfo.get("tier")
            clean_title = _format_drill_title(sid)
            bits = [cat_label]
            tr_lbl = _format_trade_label(tr, outcome)
            if tr_lbl:
                bits.append(tr_lbl)
            if tier_val:
                bits.append(str(tier_val))
            items.append(
                {
                    "loop": f"Loop {loop_num}",
                    "loop_num": loop_num,
                    "category": cat_label,
                    "cohort": str(tier_val or mode),
                    "race": _race_full(race_guess),
                    "outcome": outcome,
                    "result_label": res_label,
                    "trade_ratio": tr,
                    "title": clean_title,
                    "subtitle": " · ".join(bits),
                    "media_type": "mp4",
                    "playable_mp4": False,
                    "src": mp4_url or "",
                    "download_url": mp4_url or "",
                    "poster": png_url,
                    "_local_mp4": str(mp4_local_p) if mp4_local_p else "",
                    "_safe_name": f"l{loop_num}_{mode}_{mp4_local_p.name}" if mp4_local_p else "",
                    "search": f"loop {loop_num} {sid} {clean_title} {cat_label} {race_guess} {res_label} {tier_val or ''}".lower(),
                }
            )

    # 2B. Loop 50 Probe Drill MP4 Clips (d10 1.66x KO, r15 5.00x Pass, t12 1.78x KO, s04 1.39x KO, s05 3.51x KO)
    l50_probe_dir = brain_dir / "scratch" / "loop" / "visuals_iter50_w3_probe" / "arena"
    if l50_probe_dir.is_dir():
        l50_tactics: Dict[str, Dict[str, Any]] = {}
        for jname in ("tactics_probe_iter50_w3_dummy.json", "tactics_probe_iter50_w3_extra_dummy.json"):
            jp = brain_dir / "scratch" / "loop" / jname
            if jp.is_file():
                try:
                    jd = json.loads(jp.read_text(encoding="utf-8"))
                    for sc in jd.get("results", jd.get("scenarios", [])):
                        if isinstance(sc, dict) and sc.get("id"):
                            l50_tactics[str(sc["id"])] = sc
                except Exception:
                    pass
        for sid in (
            "sc2-det-d10-t-cloaked-banshee-viking-vs-observers-stalker",
            "sc2-reg-r15-tvp-full-lifecycle-vs-15-kiting-probes",
            "sc2-real-t12-banshee-raven-marine-vs-dt-stalker-observer",
            "sc2-sta-s04-pvz-oracle-stasis-choke-split",
            "sc2-sta-s05-zvp-stasis-ward-defuse-ling-sac",
            "sc2-real-t14-raven-imatrix-aam-bio-vs-colossus",
        ):
            mp4_p = l50_probe_dir / f"{sid}.mp4"
            if not mp4_p.is_file():
                continue
            png_p = l50_probe_dir / f"{sid}.png"
            mp4_url = resolve_cdn(str(mp4_p), l50_probe_dir)
            png_url = resolve_cdn(str(png_p), l50_probe_dir) if png_p.is_file() else ""
            tinfo = l50_tactics.get(sid, {})
            race_guess = str(tinfo.get("p1_race") or tinfo.get("race") or "")
            if not race_guess:
                race_guess = "Terran" if ("-t-" in sid or "-tvp-" in sid or "-t1" in sid) else ("Protoss" if "-p" in sid else "Zerg")
            winner_raw = str(tinfo.get("winner") or "").strip().lower()
            win_type = str(tinfo.get("win_type") or "").strip().lower()
            if winner_raw in ("mothman", "mothman-p1", "p1"):
                outcome = "win"
                res_label = "Pass" if "econ" in win_type else "Win"
            elif winner_raw in ("draw", "tie"):
                outcome = "tie"
                res_label = "Draw"
            else:
                outcome = "loss"
                res_label = "Fail" if "econ" in win_type else "Loss"
            tr = tinfo.get("trade_ratio")
            tier_val = tinfo.get("tier") or "canonical"
            clean_title = _format_drill_title(sid)
            bits = ["Tactics Drills"]
            tr_lbl = _format_trade_label(tr, outcome)
            if tr_lbl:
                bits.append(tr_lbl)
            if tier_val:
                bits.append(str(tier_val))
            items.append(
                {
                    "loop": "Loop 50",
                    "loop_num": 50,
                    "category": "Tactics Drills",
                    "cohort": str(tier_val),
                    "race": _race_full(race_guess),
                    "outcome": outcome,
                    "result_label": res_label,
                    "trade_ratio": tr,
                    "title": clean_title,
                    "subtitle": " · ".join(bits),
                    "media_type": "mp4",
                    "playable_mp4": False,
                    "src": mp4_url or "",
                    "download_url": mp4_url or "",
                    "poster": png_url,
                    "_local_mp4": str(mp4_p),
                    "_safe_name": f"l50_arena_{mp4_p.name}",
                    "search": f"loop 50 {sid} {clean_title} tactics drills {race_guess} {res_label} {tier_val}".lower(),
                }
            )

    # 2C. Loop 51 Verified Probe Clips (t14 PersephoneAIE_v4 3.75x KO, d10 1.75x KO; exclude sp07 placeholder)
    l51_root = brain_dir / "scratch" / "loop" / "probe_iter51_w2_5014"
    l51_specs = [
        (
            l51_root / "persephone_v4" / "arena",
            "sc2-real-t14-raven-imatrix-aam-bio-vs-colossus",
            "Terran",
            "win",
            "Win",
            3.75,
        ),
        (
            l51_root / "arena",
            "sc2-det-d10-t-cloaked-banshee-viking-vs-observers-stalker",
            "Terran",
            "win",
            "Win",
            1.75,
        ),
    ]
    for pdir, sid, race_val, outcome, res_label, tr in l51_specs:
        mp4_p = pdir / f"{sid}.mp4"
        if not mp4_p.is_file():
            continue
        png_p = pdir / f"{sid}.png"
        mp4_url = resolve_cdn(str(mp4_p), pdir)
        png_url = resolve_cdn(str(png_p), pdir) if png_p.is_file() else ""
        clean_title = _format_drill_title(sid)
        bits = ["Tactics Drills", _format_trade_label(tr, outcome), "canonical"]
        items.append(
            {
                "loop": "Loop 51",
                "loop_num": 51,
                "category": "Tactics Drills",
                "cohort": "canonical",
                "race": _race_full(race_val),
                "outcome": outcome,
                "result_label": res_label,
                "trade_ratio": tr,
                "title": clean_title,
                "subtitle": " · ".join(b for b in bits if b),
                "media_type": "mp4",
                "playable_mp4": False,
                "src": mp4_url or "",
                "download_url": mp4_url or "",
                "poster": png_url,
                "_local_mp4": str(mp4_p),
                "_safe_name": f"l51_arena_{mp4_p.name}",
                "search": f"loop 51 {sid} {clean_title} tactics drills {race_val} {res_label} canonical".lower(),
            }
        )

    # 2D. Auto-discover Loop 58+ iter*_arena/pass* renders (core + ability-mastery + non-combat), skipping placeholders
    loop_scratch_dir = brain_dir / "scratch" / "loop"
    if loop_scratch_dir.is_dir():
        def _pass_rank(name: str) -> int:
            low = name.lower()
            if "final" in low:
                return 999
            if "sanity" in low:
                return 500
            if low.startswith("recheck_"):
                return -1
            m_p = re.search(r"pass(\d+)", low)
            return int(m_p.group(1)) if m_p else 0

        for adir in sorted(loop_scratch_dir.glob("iter*_arena"), reverse=True):
            m_it = re.search(r"iter(\d+)_arena$", adir.name)
            if not m_it or not adir.is_dir():
                continue
            alnum = int(m_it.group(1))
            # Merge pass JSON metadata (highest pass number wins per scenario ID)
            pass_tactics: Dict[str, Dict[str, Any]] = {}
            pass_jsons = sorted(
                adir.glob("*.json"),
                key=lambda p: (_pass_rank(p.name), p.stat().st_mtime),
            )
            for pf in pass_jsons:
                if "selfplay" in pf.name.lower():
                    continue
                try:
                    pdata = json.loads(pf.read_text(encoding="utf-8"))
                except Exception:
                    continue
                for sc in pdata.get("scenarios", pdata.get("results", [])):
                    if isinstance(sc, dict) and sc.get("id"):
                        pass_tactics[str(sc["id"])] = sc

            # Scan render dirs highest-pass first, keeping latest verified render per scenario ID
            render_dirs = sorted(
                (d for d in adir.iterdir() if d.is_dir() and "render" in d.name.lower()),
                key=lambda p: (_pass_rank(p.name), p.stat().st_mtime),
                reverse=True,
            )
            seen_sids_in_iter: set[str] = set()
            for rdir in render_dirs:
                rdir_pnum = _pass_rank(rdir.name)
                for mp4_p in sorted(rdir.rglob("*.mp4")):
                    sid = mp4_p.stem
                    if sid in seen_sids_in_iter:
                        continue
                    tinfo = pass_tactics.get(sid, {})
                    if _is_placeholder_arena_clip(mp4_p, tinfo):
                        continue
                    seen_sids_in_iter.add(sid)
                    png_p = mp4_p.with_suffix(".png")
                    mp4_url = resolve_cdn(str(mp4_p), mp4_p.parent)
                    png_url = resolve_cdn(str(png_p), png_p.parent) if png_p.is_file() else ""
                    race_guess = str(tinfo.get("p1_race") or tinfo.get("our_race") or tinfo.get("race") or "")
                    if not race_guess:
                        low_sid = sid.lower()
                        if any(k in low_sid for k in ("protoss", "probe", "oracle", "stalker", "zealot")):
                            race_guess = "Protoss"
                        elif any(k in low_sid for k in ("terran", "scv", "depot", "marine", "raven")):
                            race_guess = "Terran"
                        elif any(k in low_sid for k in ("zerg", "drone", "queen", "roach")):
                            race_guess = "Zerg"
                        elif "-p" in low_sid or "_p" in low_sid:
                            race_guess = "Protoss"
                        elif "-t" in low_sid or "_t" in low_sid:
                            race_guess = "Terran"
                        elif "-z" in low_sid or "_z" in low_sid:
                            race_guess = "Zerg"
                    winner_raw = str(tinfo.get("winner") or "").strip().lower()
                    win_type = str(tinfo.get("win_type") or "").strip().lower()
                    scoring_mode = str(tinfo.get("scoring_mode") or "").strip().lower()
                    nc_score_raw = tinfo.get("non_combat_score")
                    nc_score = float(nc_score_raw) if isinstance(nc_score_raw, (int, float)) else None
                    is_nc = (scoring_mode == "non-combat") or (nc_score is not None) or ("non_combat" in win_type) or sid.startswith("sc2-nc-")
                    is_pass_fail = is_nc or ("econ" in win_type) or ("runby" in win_type)
                    if winner_raw in ("mothman", "mothman-p1", "p1") or win_type == "non_combat_pass":
                        outcome = "win"
                        res_label = "Pass" if is_pass_fail else "Win"
                    elif winner_raw in ("microdummy", "mothman-p2", "p2") or win_type == "non_combat_fail":
                        outcome = "loss"
                        res_label = "Fail" if is_pass_fail else "Loss"
                    elif winner_raw in ("draw", "tie"):
                        outcome = "tie"
                        res_label = "Draw"
                    else:
                        outcome = "win"
                        res_label = "Drill"
                    tr = None if is_nc else tinfo.get("trade_ratio")
                    sv = tinfo.get("spell_verified")
                    clean_title = _format_drill_title(sid)
                    bits = ["Tactics Drills"]
                    if is_nc:
                        if nc_score is not None:
                            bits.append(f"Score {nc_score:.0f}/100")
                    else:
                        tr_lbl = _format_trade_label(tr, outcome)
                        if tr_lbl:
                            bits.append(tr_lbl)
                    if sv is True:
                        bits.append("Spell verified")
                    elif sv is False:
                        bits.append("Spell uncast")
                    items.append(
                        {
                            "loop": f"Loop {alnum}",
                            "loop_num": alnum,
                            "pass_num": rdir_pnum,
                            "category": "Tactics Drills",
                            "cohort": str(tinfo.get("category") or ("non-combat" if is_nc else "arena")),
                            "race": _race_full(race_guess),
                            "outcome": outcome,
                            "result_label": res_label,
                            "trade_ratio": tr,
                            "scoring_mode": "non-combat" if is_nc else scoring_mode,
                            "non_combat_score": nc_score,
                            "spell_verified": sv,
                            "p1_ability_accepted": tinfo.get("p1_ability_accepted"),
                            "p1_ability_rejected": tinfo.get("p1_ability_rejected"),
                            "title": clean_title,
                            "subtitle": " · ".join(bits),
                            "media_type": "mp4",
                            "playable_mp4": False,
                            "src": mp4_url or "",
                            "download_url": mp4_url or "",
                            "poster": png_url,
                            "_local_mp4": str(mp4_p),
                            "_safe_name": f"l{alnum}_arena_{mp4_p.name}",
                            "search": f"loop {alnum} {sid} {clean_title} tactics drills {race_guess} {res_label}".lower(),
                        }
                    )

    # 3. Curated Recent Highlights (with clear plain-English captions for what to watch)
    curated_specs = [
        ("media-iter41", "arena_sc2-econ-e02-reaper-harass-mineral-defense.webp", "Loop 41", "Tactics Drills", "Zerg", "win", "Queen and Drones stop an early Reaper raid", "The Queen intercepts both raiding Reapers while the Drones keep mining at 97% uptime (+785 minerals net)."),
        ("media-iter41", "rep_clip01_m57_Mothman-P_vs_Mulebot_first-ever.webp", "Loop 41", "Featured Clips", "Protoss", "win", "Protoss breaks through against Mulebot (9.6× trade)", "First Protoss win against held-out opponent Mulebot: Stalkers and Immortals clear the front and force a lifted base."),
        ("media-iter41", "rep_clip06_h2h5_Mothman-P_vs_Mothman-Z-Base_h2h.webp", "Loop 41", "Featured Clips", "Protoss", "win", "Colossus and Immortals clear a Zerg base (4.5×)", "Head-to-head test against our live build: Colossus splash clears 27 Drones in six seconds with zero Protoss losses."),
        ("media-iter41", "rep_clip02_m55_Mothman-Z_vs_Mulebot_showcase.webp", "Loop 41", "Featured Clips", "Zerg", "win", "Drones and early Zerglings turn back an SCV rush (7.8×)", "When Mulebot pulls its workers across the map, Zerg pulls just enough Drones to trap them at the ramp."),
        ("media-iter41", "arena_sc2-real-p15-dt-blink-snipe-planetary.webp", "Loop 41", "Tactics Drills", "Protoss", "win", "Dark Templars blink into a Planetary Fortress", "Group blink destroys the Planetary Fortress; next we are changing this tactic to clear Missile Turrets first so the Dark Templars stay cloaked."),
        ("media-iter41", "rep_clip04_m66_Mothman-P_vs_Clicadinha_first-ever.webp", "Loop 41", "Featured Clips", "Protoss", "win", "Protoss vs. Clicadinha (4.9× trade)", "First Protoss win against held-out opponent Clicadinha with Charge Zealots, Colossus, and Disruptors."),
        ("media-iter41", "rep_clip05_m23_Mothman-T_vs_CryptBotRevival_showcase.webp", "Loop 41", "Featured Clips", "Terran", "win", "Terran vs. CryptBotRevival (11.0×, zero losses)", "Clean early Terran push closed out a 2–1 series against a held-out bot without losing a single unit."),
        ("media-iter41", "arena_sc2-real-p08-stalker-phoenix-zealot-vs-bio-tank-cyclone.webp", "Loop 41", "Tactics Drills", "Protoss", "win", "Phoenixes lift Tanks for Blink Stalkers (4.4×)", "Phoenix Graviton Beams pick up the Siege Tanks while Zealots and Stalkers close the gap underneath."),
        ("media-iter41", "selfplay_sc2-econ-e03-3adept-scv-mineral-defense.webp", "Loop 41", "Self-Play Drills", "Terran", "win", "SCVs hold a three-Adept mineral raid", "93% mining uptime with only one SCV lost against three raiding Adepts."),
        ("media-iter41", "rep_clip08_m62_Mothman-T_vs_SmoothBrain_tvt0tank.webp", "Loop 41", "Featured Clips", "Terran", "loss", "Where Terran fell behind vs. SmoothBrain", "Overbuilding early Vikings drained the gas needed for Siege Tanks (fixed in the next build)."),
        ("media-iter40", "rep_clip01_m59_Mothman-T_vs_Creepy_strategies_first-ever.webp", "Loop 40", "Featured Clips", "Terran", "win", "Terran completes a 3–0 sweep of Creepy_strategies (3.6×)", "First Terran win against Creepy_strategies, finishing a clean sweep across all three races."),
        ("media-iter40", "selfplay_sc2-real-t15-bc-yamato-jump-vs-corruptor-viper.webp", "Loop 40", "Self-Play Drills", "Terran", "win", "Battlecruisers Yamato and Tactical Jump (1.3×)", "Three Yamato shots followed by Tactical Jumps out of Corruptor focus fire turn the air fight around."),
    ]
    for tag, fname, loop_lbl, cat, race, outcome, title, sub in curated_specs:
        url = media_by_tag.get(tag, {}).get(fname)
        if not url:
            continue
        png_name = re.sub(r"\.webp$", ".png", fname)
        png_url = media_by_tag.get(tag, {}).get(png_name, "")
        items.append(
            {
                "loop": loop_lbl,
                "category": cat,
                "cohort": "curated",
                "race": race,
                "outcome": outcome,
                "result_label": "Win" if outcome == "win" else ("Loss" if outcome == "loss" else "Tie"),
                "title": title,
                "subtitle": sub,
                "media_type": "webp",
                "src": url,
                "poster": png_url,
                "search": f"{loop_lbl} {cat} {race} {outcome} {title} {sub}".lower(),
            }
        )

    return items


# ---------------------------------------------------------------------------
# Warm Editorial CSS (Anthropic-Inspired Ivory / Sand / Terracotta)
# ---------------------------------------------------------------------------

SITE_CSS = """
:root {
  --bg: #FAF9F5;
  --surface: #F4F2EA;
  --surface-alt: #EFECE3;
  --surface-input: #FFFFFF;
  --border: #E5E2D8;
  --border-strong: #262522;
  --ink: #141413;
  --ink-2: #4A4945;
  --muted: #7A7870;
  --accent: #C4633E;
  --accent-hover: #A34E2E;
  --slate: #4A6B82;
  --win: #2F6B48;
  --loss: #A83E32;
  --warn: #A35B1F;
  --serif: Georgia, "Iowan Old Style", "Palatino Linotype", "Book Antiqua", Palatino, serif;
  --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
}

* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: var(--sans);
  font-size: 16.5px;
  line-height: 1.7;
  -webkit-font-smoothing: antialiased;
}
a {
  color: var(--accent);
  text-decoration: underline;
  text-decoration-color: rgba(196, 99, 62, 0.32);
  text-underline-offset: 3px;
}
a:hover {
  color: var(--accent-hover);
  text-decoration-color: var(--accent-hover);
}
.num, table { font-variant-numeric: tabular-nums; }

/* Header — static document flow, minimal, never blocks mobile viewport */
.site-header {
  background: var(--bg);
  border-bottom: 1px solid var(--border);
}
.header-inner {
  max-width: 980px;
  margin: 0 auto;
  padding: 0 1.25rem;
  height: 54px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 1rem;
}
.wordmark {
  font-family: var(--serif);
  font-size: 1.18rem;
  font-weight: 600;
  color: var(--ink);
  letter-spacing: -0.015em;
  white-space: nowrap;
  text-decoration: none;
}
.wordmark:hover { color: var(--ink); text-decoration: none; }

.nav-links {
  display: flex;
  align-items: center;
  gap: 1.4rem;
}
.nav-link {
  font-size: 0.9rem;
  color: var(--ink-2);
  white-space: nowrap;
  padding: 0.2rem 0;
  border-bottom: 2px solid transparent;
  text-decoration: none;
}
.nav-link:hover { color: var(--ink); text-decoration: none; }
.nav-link.active {
  color: var(--ink);
  font-weight: 600;
  border-bottom-color: var(--accent);
}

.nav-toggle {
  display: none;
  background: transparent;
  border: 0;
  color: var(--ink-2);
  font-family: var(--sans);
  font-size: 0.9rem;
  font-weight: 500;
  padding: 0.35rem 0.25rem;
  cursor: pointer;
}
.nav-toggle:hover { color: var(--ink); }

.mobile-drawer {
  display: none;
  border-top: 1px solid var(--border);
  background: var(--surface);
  padding: 0.4rem 1.25rem 0.8rem;
}
.mobile-drawer.open { display: block; }
.mobile-drawer a {
  display: block;
  padding: 0.6rem 0;
  color: var(--ink);
  font-size: 0.96rem;
  border-bottom: 1px solid var(--border);
  text-decoration: none;
}
.mobile-drawer a:last-child { border-bottom: 0; }
.mobile-drawer a.active { color: var(--accent); font-weight: 600; }

/* Page containers — centered editorial essay column with wider figure breakouts */
.page-wrap {
  max-width: 980px;
  margin: 0 auto;
  padding: 2.5rem 1.25rem 4.75rem;
}
.page-grid {
  max-width: 1120px;
  margin: 0 auto;
  padding: 2.25rem 1.25rem 4.75rem;
  display: grid;
  grid-template-columns: 215px minmax(0, 1fr);
  gap: 2.75rem;
}
.content { min-width: 0; }
.prose-col {
  max-width: 680px;
  margin-left: auto;
  margin-right: auto;
}
.wide-col {
  max-width: 940px;
  margin-left: auto;
  margin-right: auto;
}
.prose { max-width: 680px; }

/* Sidebar TOC (Desktop) + Collapsible TOC (Mobile) */
.toc-sidebar {
  position: sticky;
  top: 1.5rem;
  align-self: start;
  max-height: calc(100vh - 3rem);
  overflow-y: auto;
  padding-right: 0.85rem;
  border-right: 1px solid var(--border);
  font-size: 0.84rem;
}
.toc-heading {
  font-size: 0.72rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--muted);
  margin: 0 0 0.65rem;
}
.toc-list { list-style: none; padding: 0; margin: 0; }
.toc-list li { margin: 0.44rem 0; line-height: 1.38; }
.toc-list a { color: var(--ink-2); text-decoration: none; }
.toc-list a:hover { color: var(--accent); }
.toc-latest {
  display: block;
  font-weight: 600;
  color: var(--accent);
  padding-bottom: 0.6rem;
  margin-bottom: 0.65rem;
  border-bottom: 1px solid var(--border);
  text-decoration: none;
}
.latest-jump-bar {
  font-size: 0.9rem;
  margin: -0.2rem 0 1.25rem;
}
.toc-mobile { display: none; margin-bottom: 1.5rem; }

/* Typography */
h1, h2, h3 {
  font-family: var(--serif);
  color: var(--ink);
  font-weight: 500;
  line-height: 1.22;
  letter-spacing: -0.02em;
}
h1 {
  font-size: 2.3rem;
  margin: 0 0 0.7rem;
}
h2 {
  font-size: 1.5rem;
  margin: 3.1rem 0 0.85rem;
}
.page-grid h2 {
  padding-bottom: 0.4rem;
  border-bottom: 1px solid var(--border);
}
h3 {
  font-size: 1.16rem;
  margin: 2rem 0 0.55rem;
  font-weight: 600;
}
h4 {
  font-family: var(--sans);
  font-size: 0.98rem;
  font-weight: 600;
  margin: 0 0 0.45rem;
  line-height: 1.38;
  color: var(--ink);
}
p { margin: 0 0 1.1rem; color: var(--ink-2); }
strong { color: var(--ink); font-weight: 600; }
ul, ol { margin: 0.5rem 0 1.15rem; padding-left: 1.3rem; color: var(--ink-2); }
li { margin: 0.4rem 0; }
.content > p, .content > ul, .content > ol, .content > blockquote { max-width: 680px; }
.anchor {
  color: var(--muted);
  opacity: 0;
  font-family: var(--sans);
  font-size: 0.76em;
  margin-left: 0.3rem;
  font-weight: 400;
  text-decoration: none;
}
h1:hover .anchor, h2:hover .anchor, h3:hover .anchor { opacity: 0.65; }
hr { border: 0; border-top: 1px solid var(--border); margin: 2.5rem 0; }

/* Editorial Opening (Front Page & Subpages) */
.eyebrow {
  font-size: 0.78rem;
  font-weight: 500;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--muted);
  margin: 0 0 0.5rem;
}
.masthead {
  margin-bottom: 2.2rem;
}
.masthead h1 {
  font-size: 2.55rem;
  margin: 0 0 0.65rem;
}
.lead {
  color: var(--ink-2);
  font-size: 1.08rem;
  line-height: 1.62;
  margin: 0;
}
.section-rule {
  border-top: 1px solid var(--border);
  padding-top: 2.4rem;
  margin-top: 2.8rem;
}
.section-kicker {
  font-family: var(--serif);
  font-size: 1.48rem;
  font-weight: 500;
  letter-spacing: -0.015em;
  color: var(--ink);
  margin: 0 0 0.75rem;
}

/* Inline code & code blocks */
code {
  font-family: var(--mono);
  font-size: 0.85em;
  background: var(--surface);
  padding: 0.1rem 0.35rem;
  border-radius: 3px;
  color: var(--ink);
}
.callout code, .clip-card code, details code {
  background: #EAE6DA;
  padding: 0.08rem 0.3rem;
  box-shadow: inset 0 0 0 1px rgba(38, 37, 34, 0.11);
}
.code-block {
  position: relative;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 6px;
  margin: 1.1rem 0;
  overflow-x: auto;
}
.code-block pre { margin: 0; padding: 0.95rem 1.1rem; }
.code-block code { background: none; padding: 0; box-shadow: none; font-size: 0.84rem; }
.code-lang {
  position: absolute; top: 6px; right: 10px;
  font-size: 0.7rem; text-transform: uppercase; color: var(--muted);
}
.mermaid-wrap {
  background: var(--surface);
  border-radius: 8px;
  padding: 1.1rem;
  margin: 1.25rem 0;
  overflow-x: auto;
}

/* Editorial Callouts */
.callout {
  border-left: 3px solid var(--accent);
  background: var(--surface);
  border-radius: 0 6px 6px 0;
  padding: 0.95rem 1.2rem;
  margin: 1.35rem 0;
  max-width: 680px;
}
.callout-label {
  font-size: 0.74rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--accent);
  margin-bottom: 0.3rem;
}
.callout-warning, .callout-caution { border-left-color: var(--warn); }
.callout-warning .callout-label, .callout-caution .callout-label { color: var(--warn); }
.callout-body > p:first-child { margin-top: 0; }
.callout-body > p:last-child { margin-bottom: 0; }

blockquote {
  margin: 1.25rem 0;
  padding: 0.25rem 0 0.25rem 1.15rem;
  border-left: 2px solid var(--accent);
  color: var(--ink-2);
}

/* Collapsible Sections (<details>) */
details {
  margin: 1.4rem 0;
  border-top: 1px solid var(--border);
  border-bottom: 1px solid var(--border);
  padding: 0.75rem 0;
}
summary {
  cursor: pointer;
  font-weight: 500;
  color: var(--ink);
  font-size: 0.95rem;
  list-style: none;
  display: flex;
  align-items: center;
  gap: 0.55rem;
}
summary::-webkit-details-marker { display: none; }
summary::before {
  content: "+";
  display: inline-block;
  width: 1rem;
  color: var(--muted);
  font-family: var(--mono);
  font-weight: 400;
}
details[open] > summary::before { content: "−"; }
details[open] > summary { margin-bottom: 0.85rem; }

/* Tufte Horizontal-Rule Tables */
.table-wrap {
  width: 100%;
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
  margin: 0.9rem 0 1.1rem;
}
table {
  width: 100%;
  border-collapse: collapse;
  font-size: 0.9rem;
  border-top: 1.5px solid var(--border-strong);
  border-bottom: 1.5px solid var(--border-strong);
}
thead th {
  text-align: left;
  font-weight: 600;
  color: var(--ink);
  padding: 0.65rem 0.7rem;
  border-bottom: 1px solid var(--border-strong);
  white-space: nowrap;
  background: transparent;
}
td {
  padding: 0.68rem 0.7rem;
  border-bottom: 1px solid var(--border);
  vertical-align: top;
  color: var(--ink-2);
}
tbody tr:last-child td { border-bottom: 0; }
.table-note {
  font-size: 0.87rem;
  color: var(--muted);
  margin: 0.6rem 0 0;
  line-height: 1.55;
}
.t-win { color: var(--win); font-weight: 600; }
.t-loss { color: var(--loss); font-weight: 600; }
.t-muted { color: var(--muted); }
.nw { white-space: nowrap; }
.table-flywheel table { font-size: 0.75rem; }
.table-flywheel thead th {
  font-size: 0.72rem;
  line-height: 1.2;
  padding: 0.36rem 0.26rem;
  white-space: normal;
  vertical-align: bottom;
}
.table-flywheel td {
  padding: 0.36rem 0.26rem;
  font-variant-numeric: tabular-nums;
  line-height: 1.36;
}
.table-flywheel td:first-child { white-space: nowrap; }

/* Responsive Stacked Mobile Standings (< 700px) */
.standings-mobile {
  display: none;
  border-top: 1.5px solid var(--border-strong);
  border-bottom: 1.5px solid var(--border-strong);
  margin: 0.75rem 0 0.85rem;
}
.standing-row { padding: 0.78rem 0; border-bottom: 1px solid var(--border); }
.standing-row:last-child { border-bottom: 0; }
.standing-top { display: flex; justify-content: space-between; align-items: baseline; gap: 0.75rem; }
.standing-bot { font-weight: 600; color: var(--ink); font-size: 0.98rem; }
.standing-race { color: var(--muted); font-weight: 400; font-size: 0.88rem; }
.standing-elo { font-weight: 600; font-size: 1rem; font-variant-numeric: tabular-nums; color: var(--ink); }
.standing-stats { font-size: 0.87rem; color: var(--ink-2); margin-top: 0.16rem; font-variant-numeric: tabular-nums; }
.standing-note { font-size: 0.87rem; color: var(--muted); margin: 0.28rem 0 0; line-height: 1.46; }

/* Anthropic-Style Warm Sand Figures */
.figure-block {
  background: var(--surface);
  border-radius: 10px;
  padding: 1.35rem 1.45rem 1.15rem;
  margin: 1.5rem auto 1.75rem;
  max-width: 780px;
}
.figure-label {
  font-size: 0.76rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--muted);
  margin: 0 0 0.25rem;
}
.figure-title {
  font-family: var(--serif);
  font-size: 1.1rem;
  font-weight: 500;
  margin: 0 0 0.75rem;
  color: var(--ink);
}
.chart-svg { width: 100%; height: auto; display: block; }
.figure-caption {
  font-size: 0.86rem;
  color: var(--ink-2);
  margin: 0.75rem 0 0;
  line-height: 1.52;
}

/* Clean Typographic Reading Lists */
.doc-list {
  list-style: none;
  padding: 0;
  margin: 0.65rem 0 1.85rem;
  border-top: 1px solid var(--border);
}
.doc-item {
  display: grid;
  grid-template-columns: 240px minmax(0, 1fr);
  gap: 0.25rem 1.75rem;
  align-items: baseline;
  padding: 0.85rem 0;
  border-bottom: 1px solid var(--border);
  margin: 0;
}
.doc-item-title {
  font-family: var(--serif);
  font-size: 1.02rem;
  font-weight: 500;
  display: inline-block;
}
.doc-item-desc {
  margin: 0;
  font-size: 0.92rem;
  color: var(--ink-2);
  line-height: 1.52;
}

/* Replays & Video Figures */
.clip-gallery { margin: 1.25rem 0 2rem; }
.clip-gallery-grid, .featured-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1.35rem;
}
.clip-card {
  background: var(--surface);
  border-radius: 10px;
  padding: 1rem 1.05rem;
  display: flex;
  flex-direction: column;
}
.clip-index {
  font-size: 0.75rem;
  color: var(--muted);
  margin-bottom: 0.3rem;
  font-variant-numeric: tabular-nums;
}
.clip-figure { margin: 0.4rem 0 0; }
.clip-img, .clip-video {
  width: 100%;
  height: auto;
  display: block;
  border-radius: 6px;
  background: #141413;
}
.clip-img { cursor: zoom-in; min-height: 150px; }
.clip-figure figcaption {
  font-size: 0.85rem;
  color: var(--ink-2);
  margin-top: 0.55rem;
  line-height: 1.48;
}
.video-bar {
  display: flex;
  gap: 1rem;
  align-items: center;
  margin-top: 0.5rem;
  font-size: 0.84rem;
}
.text-btn {
  background: none;
  border: 0;
  padding: 0;
  color: var(--accent);
  font-family: var(--sans);
  font-size: 0.84rem;
  cursor: pointer;
  text-decoration: underline;
  text-decoration-color: rgba(196, 99, 62, 0.32);
  text-underline-offset: 2px;
}
.text-btn:hover { color: var(--accent-hover); text-decoration-color: var(--accent-hover); }
.media-link {
  font-size: 0.86rem;
  font-weight: 500;
  white-space: nowrap;
}

/* Video Gallery Filter Controls */
.gallery-controls {
  display: flex;
  flex-wrap: wrap;
  gap: 0.75rem 1rem;
  align-items: flex-end;
  padding: 1rem 0 1.25rem;
  border-top: 1px solid var(--border);
  border-bottom: 1px solid var(--border);
  margin: 1.25rem 0 1.5rem;
}
.filter-group {
  display: flex;
  flex-direction: column;
  gap: 0.25rem;
}
.filter-group label {
  font-size: 0.74rem;
  color: var(--muted);
  text-transform: uppercase;
  letter-spacing: 0.06em;
}
.filter-select, .filter-input {
  font-family: var(--sans);
  font-size: 0.9rem;
  color: var(--ink);
  background: var(--surface-input);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 0.44rem 0.65rem;
  min-width: 135px;
}
.filter-input { min-width: 210px; }
.gallery-count {
  font-size: 0.88rem;
  color: var(--muted);
  margin: 0 0 1rem;
}
.gallery-meta-row {
  display: flex;
  justify-content: space-between;
  gap: 0.5rem;
  font-size: 0.78rem;
  color: var(--muted);
  margin-bottom: 0.3rem;
}
.show-more-wrap { text-align: center; margin-top: 1.75rem; }
.editorial-btn {
  background: var(--surface);
  color: var(--ink);
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 0.55rem 1.2rem;
  font-family: var(--sans);
  font-size: 0.9rem;
  cursor: pointer;
}
.editorial-btn:hover { background: var(--surface-alt); }

/* Lightbox & Video Theater Modals */
.modal-overlay {
  position: fixed;
  inset: 0;
  z-index: 1000;
  background: rgba(20, 20, 19, 0.92);
  display: none;
  align-items: center;
  justify-content: center;
  flex-direction: column;
  padding: 1.25rem;
}
.modal-overlay.open { display: flex; }
.modal-overlay img, .modal-overlay video {
  max-width: 94vw;
  max-height: 80vh;
  border-radius: 6px;
  background: #000;
}
.modal-caption {
  color: #F4F2EA;
  margin-top: 0.75rem;
  font-size: 0.9rem;
  text-align: center;
  max-width: 820px;
}
.modal-controls {
  position: fixed;
  top: 1rem;
  right: 1.25rem;
  display: flex;
  gap: 0.5rem;
}
.modal-btn {
  background: #262522;
  color: #FAF9F5;
  border: 1px solid #44423C;
  border-radius: 6px;
  padding: 0.4rem 0.78rem;
  cursor: pointer;
  font-size: 0.86rem;
  text-decoration: none;
}
.modal-btn:hover { background: #3B3934; color: #FFFFFF; text-decoration: none; }

/* Footer */
.site-footer {
  max-width: 980px;
  margin: 0 auto;
  padding: 1.6rem 1.25rem 3.25rem;
  border-top: 1px solid var(--border);
  color: var(--muted);
  font-size: 0.84rem;
  display: flex;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 0.5rem 1.25rem;
}

@media (max-width: 1020px) {
  .page-grid { grid-template-columns: minmax(0, 1fr); gap: 1rem; }
  .toc-sidebar { display: none; }
  .toc-mobile { display: block; }
}
@media (max-width: 820px) {
  .clip-gallery-grid, .featured-grid { grid-template-columns: minmax(0, 1fr); }
}
@media (max-width: 799px) {
  body { font-size: 15.5px; }
  .header-inner { height: 50px; }
  .nav-links { display: none; }
  .nav-toggle { display: inline-block; }
  .page-wrap, .page-grid { padding: 1.35rem 1rem 3.5rem; }
  .masthead { margin-bottom: 1.45rem; }
  .masthead h1 { font-size: 1.85rem; margin-bottom: 0.45rem; }
  .lead { font-size: 0.98rem; line-height: 1.56; }
  h1 { font-size: 1.7rem; }
  h2, .section-kicker { font-size: 1.3rem; }
  .section-rule { padding-top: 1.85rem; margin-top: 2.1rem; }
  .figure-block { padding: 1.05rem 0.95rem 0.95rem; border-radius: 8px; }
  .doc-item { grid-template-columns: minmax(0, 1fr); gap: 0.2rem; }
  .filter-input { min-width: 0; width: 100%; }
  .filter-group { flex: 1 1 140px; }
}
@media (max-width: 699px) {
  .standings-desktop { display: none; }
  .standings-mobile { display: block; }
}
"""

INTERACTIVE_JS = """
<script>
(function() {
  // 1. Mobile menu toggle
  const toggle = document.getElementById('nav-toggle');
  const drawer = document.getElementById('mobile-drawer');
  if (toggle && drawer) {
    toggle.addEventListener('click', function() {
      const open = drawer.classList.toggle('open');
      toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      toggle.textContent = open ? 'Close' : 'Menu';
    });
  }

  // 2. Auto-pause other videos when one starts playing
  document.addEventListener('play', function(e) {
    if (e.target && e.target.tagName === 'VIDEO') {
      document.querySelectorAll('video').forEach(function(v) {
        if (v !== e.target && !v.paused) v.pause();
      });
    }
  }, true);

  // 3. Image Lightbox Modal
  const imgs = Array.from(document.querySelectorAll('img.clip-img'));
  if (imgs.length) {
    const lb = document.createElement('div');
    lb.className = 'modal-overlay';
    lb.innerHTML =
      '<div class="modal-controls">' +
        '<button class="modal-btn" id="lb-prev">Prev</button>' +
        '<button class="modal-btn" id="lb-next">Next</button>' +
        '<a class="modal-btn" id="lb-raw" target="_blank" rel="noopener noreferrer">Open file</a>' +
        '<button class="modal-btn" id="lb-close">Close</button>' +
      '</div>' +
      '<img id="lb-img" alt="" />' +
      '<div class="modal-caption" id="lb-cap"></div>';
    document.body.appendChild(lb);
    const lbImg = document.getElementById('lb-img');
    const lbCap = document.getElementById('lb-cap');
    const lbRaw = document.getElementById('lb-raw');
    let cur = 0;
    function show(i) {
      cur = (i + imgs.length) % imgs.length;
      const src = imgs[cur].getAttribute('data-lightbox-src') || imgs[cur].src;
      const alt = imgs[cur].getAttribute('data-lightbox-alt') || imgs[cur].alt || '';
      lbImg.src = src;
      lbImg.alt = alt;
      lbRaw.href = src;
      lbCap.textContent = (cur + 1) + ' of ' + imgs.length + (alt ? ' — ' + alt : '');
      lb.classList.add('open');
    }
    function closeLb() { lb.classList.remove('open'); }
    imgs.forEach(function(im, idx) { im.addEventListener('click', function() { show(idx); }); });
    document.getElementById('lb-prev').addEventListener('click', function(e) { e.stopPropagation(); show(cur - 1); });
    document.getElementById('lb-next').addEventListener('click', function(e) { e.stopPropagation(); show(cur + 1); });
    document.getElementById('lb-close').addEventListener('click', function(e) { e.stopPropagation(); closeLb(); });
    lb.addEventListener('click', function(e) { if (e.target === lb) closeLb(); });
    document.addEventListener('keydown', function(e) {
      if (!lb.classList.contains('open')) return;
      if (e.key === 'Escape') closeLb();
      else if (e.key === 'ArrowRight') show(cur + 1);
      else if (e.key === 'ArrowLeft') show(cur - 1);
    });
  }

  // 4. Video Theater Modal (delegated for both report videos and dynamic gallery cards)
  const vm = document.createElement('div');
  vm.className = 'modal-overlay';
  vm.innerHTML =
    '<div class="modal-controls">' +
      '<a class="modal-btn" id="vm-raw" target="_blank" rel="noopener noreferrer">Download MP4</a>' +
      '<button class="modal-btn" id="vm-close">Close</button>' +
    '</div>' +
    '<video id="vm-video" controls playsinline webkit-playsinline preload="metadata"></video>' +
    '<div class="modal-caption" id="vm-cap"></div>';
  document.body.appendChild(vm);
  const vmVideo = document.getElementById('vm-video');
  const vmCap = document.getElementById('vm-cap');
  const vmRaw = document.getElementById('vm-raw');
  function closeVm() {
    vmVideo.pause();
    vmVideo.innerHTML = '';
    vmVideo.removeAttribute('src');
    vmVideo.load();
    vm.classList.remove('open');
  }
  document.addEventListener('click', function(e) {
    const btn = e.target.closest('.video-theater-btn');
    if (!btn) return;
    const src = btn.getAttribute('data-video-src') || '';
    const poster = btn.getAttribute('data-video-poster') || '';
    const title = btn.getAttribute('data-video-title') || '';
    if (!src) return;
    document.querySelectorAll('video').forEach(function(v) { if (!v.paused) v.pause(); });
    vmVideo.innerHTML = '';
    const sourceEl = document.createElement('source');
    sourceEl.src = src;
    sourceEl.type = 'video/mp4';
    vmVideo.appendChild(sourceEl);
    if (poster) vmVideo.poster = poster; else vmVideo.removeAttribute('poster');
    vmVideo.load();
    vmRaw.href = src;
    vmCap.textContent = title;
    vm.classList.add('open');
    vmVideo.play().catch(function() {});
  });
  document.getElementById('vm-close').addEventListener('click', function(e) { e.stopPropagation(); closeVm(); });
  vm.addEventListener('click', function(e) { if (e.target === vm) closeVm(); });
  document.addEventListener('keydown', function(e) {
    if (vm.classList.contains('open') && e.key === 'Escape') closeVm();
  });

  // 5. Open ancestor <details> when jumping to an in-page hash anchor (e.g. archived Loops 29-40)
  function openDetailsForHash(hash) {
    if (!hash || hash.length < 2) return;
    const el = document.getElementById(decodeURIComponent(hash.slice(1)));
    if (!el) return;
    let p = el.parentElement;
    while (p) {
      if (p.tagName === 'DETAILS') p.open = true;
      p = p.parentElement;
    }
  }
  window.addEventListener('hashchange', function() { openDetailsForHash(window.location.hash); });
  if (window.location.hash) openDetailsForHash(window.location.hash);
  document.addEventListener('click', function(e) {
    const a = e.target.closest('a[href^="#"]');
    if (a) openDetailsForHash(a.getAttribute('href'));
  });
})();
</script>
"""

MERMAID_JS = """
<script type="module">
  import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
  mermaid.initialize({ startOnLoad: true, theme: 'neutral', securityLevel: 'loose' });
</script>
"""


def build_header(repo_slug: str, active_slug: str) -> str:
    nav_items = [
        ("index", "Current State", "./index.html", False),
        ("history", "History & Fixes", "./history.html", False),
        ("video-gallery", "Replays", "./video-gallery.html", False),
        ("github", "GitHub", f"https://github.com/{repo_slug}", True),
    ]
    desktop_links = []
    mobile_links = []
    for sl, lbl, href, is_ext in nav_items:
        is_active = sl == active_slug or (
            sl == "history"
            and active_slug not in ("index", "video-gallery")
        )
        cls = "nav-link active" if is_active else "nav-link"
        mcls = "active" if is_active else ""
        ext = ' target="_blank" rel="noopener noreferrer"' if is_ext else ""
        desktop_links.append(f'<a class="{cls}" href="{href}"{ext}>{html.escape(lbl)}</a>')
        mobile_links.append(f'<a class="{mcls}" href="{href}"{ext}>{html.escape(lbl)}</a>')

    return (
        '<header class="site-header">'
        '<div class="header-inner">'
        '<a class="wordmark" href="./index.html">Mothman</a>'
        f'<nav class="nav-links" aria-label="Primary">{"".join(desktop_links)}</nav>'
        '<button type="button" class="nav-toggle" id="nav-toggle" '
        'aria-expanded="false" aria-controls="mobile-drawer">Menu</button>'
        "</div>"
        f'<nav class="mobile-drawer" id="mobile-drawer" aria-label="Mobile menu">'
        f'{"".join(mobile_links)}</nav>'
        "</header>"
    )


_CALM_LOOP_TITLES: Dict[int, str] = {
    29: "Longer combat drills & self-play",
    30: "Zero-tie benchmark",
    31: "Head-to-head milestone",
    32: "Held-out practice bots",
    33: "Terran macro gains",
    34: "Live release #1",
    35: "Core benchmark milestone",
    36: "Live release #2",
    37: "Live release #3 (map symmetry)",
    38: "Expanded drills & parity",
    39: "Retreat check (held)",
    40: "Live release #4",
    41: "Held-out gains & DT blink",
    42: "Live release #5",
    43: "213 combat drills & Terran fixes (held)",
    44: "Detection & drop fixes (held)",
    45: "Live release #6",
    46: "Zerg core high & p15 win (held)",
    47: "Zero cloak losses & drill peak (held)",
    48: "Live release #7 (50% core benchmark)",
    49: "Banelings, base layouts & stall checks (held)",
    50: "Live release #8 (Zerg breakthrough & SC2 4.10 fixes)",
    51: "Live release #9 (54.8% core benchmark & SC2 5.0.14 fixes)",
    57: "Live release #10 (8-bot v1 & v2 ladder rollout)",
    58: "Ability mastery & non-combat drills (held)",
    59: "Live release #11 (Pro-matched EPM/SPM & 9–3 H2H)",
}


def render_page_shell(
    *,
    repo_slug: str,
    title: str,
    active_slug: str,
    body_html: str,
    toc: Optional[List[Tuple[int, str, str]]] = None,
    include_mermaid: bool = False,
    extra_scripts: str = "",
    built_utc: str,
) -> str:
    header = build_header(repo_slug, active_slug)
    if toc:
        # Detect latest Loop <N> heading so collaborators can jump straight to the newest entry
        latest_loop: Optional[Tuple[int, str]] = None
        for _, slug, lbl in toc:
            lm = re.match(r"^Loop\s+(\d+)\b", lbl)
            if lm:
                lnum = int(lm.group(1))
                if latest_loop is None or lnum >= latest_loop[0]:
                    latest_loop = (lnum, slug)

        latest_toc_html = ""
        latest_top_html = ""
        if latest_loop is not None:
            lnum, lslug = latest_loop
            latest_toc_html = f'<a class="toc-latest" href="#{lslug}">Latest: Loop {lnum} ↓</a>'
            latest_top_html = (
                f'<div class="latest-jump-bar">'
                f'<a href="#{lslug}">Jump to Loop {lnum} ↓</a>'
                f"</div>"
            )

        items = []
        for _, slug, lbl in toc:
            m_lp = re.match(r"^Loop\s+(\d+)\b(?:\s*(?:[—–-]\s*)?(.+))?$", lbl)
            if m_lp:
                lnum = int(m_lp.group(1))
                if lnum in _CALM_LOOP_TITLES:
                    display_lbl = f"Loop {lnum}: {_CALM_LOOP_TITLES[lnum]}"
                else:
                    rest = re.sub(r"[^\w\s.,×%/#&()-]+", "", m_lp.group(2) or "").strip()
                    short_rest = rest if len(rest) <= 28 else rest[:25].rstrip(" ,;:-") + "…"
                    display_lbl = f"Loop {lnum}: {short_rest}" if short_rest else f"Loop {lnum}"
            else:
                clean_lbl = re.sub(r"[^\w\s.,×%/#&()'–—-]+", "", lbl).strip()
                display_lbl = clean_lbl if len(clean_lbl) <= 40 else clean_lbl[:37].rstrip(" ,;:-") + "…"
            items.append(
                f'<li><a href="#{slug}">{html.escape(display_lbl)}</a></li>'
            )
        list_html = f'<ul class="toc-list">{"".join(items)}</ul>'
        main_section = (
            '<div class="page-grid">'
            '<aside class="toc-sidebar" aria-label="Table of contents">'
            '<div class="toc-heading">Contents</div>'
            f"{latest_toc_html}{list_html}</aside>"
            '<main class="content">'
            f"{latest_top_html}"
            '<details class="toc-mobile"><summary>Contents</summary>'
            f"{latest_toc_html}{list_html}</details>"
            f"{body_html}</main></div>"
        )
    else:
        main_section = f'<div class="page-wrap"><main class="content">{body_html}</main></div>'

    mermaid_script = MERMAID_JS if include_mermaid else ""
    page_title = "Mothman — StarCraft II Bots" if active_slug == "index" else f"{title} — Mothman"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{html.escape(page_title)}</title>
  <style>{SITE_CSS}{INTERACTIVE_SECTIONS_CSS}</style>
</head>
<body>
{header}
{main_section}
<footer class="site-footer">
  <div>Mothman · StarCraft II bots on AI Arena</div>
  <div>Updated {html.escape(built_utc)} · <a href="https://github.com/{repo_slug}/releases" target="_blank" rel="noopener noreferrer">Replay Archives</a></div>
</footer>
{INTERACTIVE_JS}
{extra_scripts}
{mermaid_script}
</body>
</html>
"""


def build_video_gallery_page(
    *,
    repo_slug: str,
    gallery_items: List[Dict[str, Any]],
    built_utc: str,
) -> str:
    mp4_count = sum(1 for it in gallery_items if it["media_type"] == "mp4")
    playable_count = sum(1 for it in gallery_items if it.get("playable_mp4"))
    webp_count = sum(1 for it in gallery_items if it["media_type"] != "mp4")
    loops = sorted({it["loop"] for it in gallery_items}, reverse=True)
    categories = ["Full Matches", "Tactics Drills", "Self-Play Drills", "Featured Clips"]
    present_cats = [c for c in categories if any(it["category"] == c for it in gallery_items)]

    loop_opts = ['<option value="all">All loops</option>'] + [
        f'<option value="{html.escape(lp)}">{html.escape(lp)}</option>' for lp in loops
    ]
    cat_opts = ['<option value="all">All categories</option>'] + [
        f'<option value="{html.escape(c)}">{html.escape(c)}</option>' for c in present_cats
    ]

    if mp4_count > 0:
        intro_note = (
            f"{playable_count} in-browser MP4 recordings (H.264 Main Profile, mobile-ready)"
            + (f", plus {mp4_count - playable_count} archived downloads" if mp4_count > playable_count else "")
            + (f" and {webp_count} short highlights" if webp_count else "")
            + ". Filter by loop, race, opponent, or outcome below."
        )
    else:
        intro_note = (
            "Recent match highlights and combat tests. Filter by race, opponent, or result below."
        )

    items_json = json.dumps(gallery_items, ensure_ascii=False).replace("</", "<\\/")

    body = f"""
<section class="masthead" style="padding-bottom:1.1rem;margin-bottom:1.25rem;">
  <h1>Replays</h1>
  <p class="lead" style="margin-bottom:0;">{html.escape(intro_note)}</p>
</section>

<div class="gallery-controls" aria-label="Filter replays">
  <div class="filter-group">
    <label for="f-loop">Loop</label>
    <select id="f-loop" class="filter-select">{"".join(loop_opts)}</select>
  </div>
  <div class="filter-group">
    <label for="f-cat">Category</label>
    <select id="f-cat" class="filter-select">{"".join(cat_opts)}</select>
  </div>
  <div class="filter-group">
    <label for="f-race">Race</label>
    <select id="f-race" class="filter-select">
      <option value="all">All races</option>
      <option value="Protoss">Protoss</option>
      <option value="Terran">Terran</option>
      <option value="Zerg">Zerg</option>
      <option value="Random">Random</option>
    </select>
  </div>
  <div class="filter-group">
    <label for="f-out">Outcome</label>
    <select id="f-out" class="filter-select">
      <option value="all">All outcomes</option>
      <option value="win">Win / Pass</option>
      <option value="loss">Loss / Watch</option>
      <option value="tie">Tie / Draw</option>
    </select>
  </div>
  <div class="filter-group" style="flex:1 1 200px;">
    <label for="f-search">Search</label>
    <input id="f-search" type="search" class="filter-input" placeholder="Opponent, map, or drill…" />
  </div>
</div>

<p class="gallery-count" id="gallery-count"></p>
<div class="clip-gallery-grid" id="gallery-grid"></div>
<div class="show-more-wrap" id="show-more-wrap" style="display:none;">
  <button type="button" class="editorial-btn" id="show-more-btn">Show more replays</button>
</div>
"""

    gallery_js = f"""
<script>
(function() {{
  const ITEMS = {items_json};
  const grid = document.getElementById('gallery-grid');
  const countEl = document.getElementById('gallery-count');
  const moreWrap = document.getElementById('show-more-wrap');
  const moreBtn = document.getElementById('show-more-btn');
  const fLoop = document.getElementById('f-loop');
  const fCat = document.getElementById('f-cat');
  const fRace = document.getElementById('f-race');
  const fOut = document.getElementById('f-out');
  const fSearch = document.getElementById('f-search');
  const PAGE_SIZE = 24;
  let visibleLimit = PAGE_SIZE;

  function esc(s) {{
    return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
  }}

  function cardHtml(it) {{
    const resCls = it.outcome === 'win' ? 't-win' : (it.outcome === 'loss' ? 't-loss' : 't-muted');
    const dlUrl = it.download_url || it.src;
    let media = '';
    if (it.media_type === 'mp4' && it.playable_mp4) {{
      const pAttr = it.poster ? ' poster="' + esc(it.poster) + '"' : '';
      media =
        '<div class="clip-video-wrap">' +
          '<video class="clip-video" controls playsinline webkit-playsinline preload="metadata"' + pAttr + '>' +
            '<source src="' + esc(it.src) + '" type="video/mp4" />' +
          '</video>' +
        '</div>' +
        '<div class="video-bar">' +
          '<button type="button" class="text-btn video-theater-btn" data-video-src="' + esc(it.src) + '" data-video-poster="' + esc(it.poster) + '" data-video-title="' + esc(it.title) + '">Expand</button>' +
          '<a class="text-btn" href="' + esc(dlUrl) + '" target="_blank" rel="noopener noreferrer">Download MP4</a>' +
        '</div>';
    }} else if (it.media_type === 'mp4') {{
      media =
        (it.poster
          ? '<a href="' + esc(dlUrl) + '" target="_blank" rel="noopener noreferrer">' +
              '<img class="clip-img" loading="lazy" decoding="async" src="' + esc(it.poster) + '" alt="' + esc(it.title) + '" />' +
            '</a>'
          : '') +
        '<div class="video-bar">' +
          '<a class="text-btn" href="' + esc(dlUrl) + '" target="_blank" rel="noopener noreferrer">Download archived MP4</a>' +
          (it.poster ? '<a class="text-btn" href="' + esc(it.poster) + '" target="_blank" rel="noopener noreferrer">Still frame</a>' : '') +
        '</div>';
    }} else {{
      media =
        '<a href="' + esc(it.src) + '" target="_blank" rel="noopener noreferrer">' +
          '<img class="clip-img" loading="lazy" decoding="async" src="' + esc(it.src) + '" alt="' + esc(it.title) + '" />' +
        '</a>' +
        (it.poster ? '<div class="video-bar"><a class="text-btn" href="' + esc(it.poster) + '" target="_blank" rel="noopener noreferrer">High-res still frame</a></div>' : '');
    }}
    return (
      '<article class="clip-card">' +
        '<div class="gallery-meta-row">' +
          '<span>' + esc(it.loop) + ' · ' + esc(it.category) + ' · ' + esc(it.race) + '</span>' +
          '<span class="' + resCls + '">' + esc(it.result_label) + '</span>' +
        '</div>' +
        '<h4>' + esc(it.title) + '</h4>' +
        '<figure class="clip-figure">' + media + '<figcaption>' + esc(it.subtitle) + '</figcaption></figure>' +
      '</article>'
    );
  }}

  function render() {{
    const lp = fLoop.value;
    const cat = fCat.value;
    const race = fRace.value;
    const out = fOut.value;
    const q = (fSearch.value || '').trim().toLowerCase();
    const filtered = ITEMS.filter(function(it) {{
      if (lp !== 'all' && it.loop !== lp) return false;
      if (cat !== 'all' && it.category !== cat) return false;
      if (race !== 'all' && it.race !== race) return false;
      if (out !== 'all' && it.outcome !== out) return false;
      if (q && it.search.indexOf(q) === -1) return false;
      return true;
    }});
    const shown = filtered.slice(0, visibleLimit);
    countEl.textContent = 'Showing ' + shown.length + ' of ' + filtered.length + ' replay' + (filtered.length === 1 ? '' : 's') + '.';
    grid.innerHTML = shown.length
      ? shown.map(cardHtml).join('')
      : '<p class="t-muted">No replays match those filters.</p>';
    moreWrap.style.display = filtered.length > visibleLimit ? 'block' : 'none';
  }}

  [fLoop, fCat, fRace, fOut].forEach(function(el) {{
    el.addEventListener('change', function() {{ visibleLimit = PAGE_SIZE; render(); }});
  }});
  fSearch.addEventListener('input', function() {{ visibleLimit = PAGE_SIZE; render(); }});
  moreBtn.addEventListener('click', function() {{ visibleLimit += PAGE_SIZE; render(); }});
  render();
}})();
</script>
"""

    return render_page_shell(
        repo_slug=repo_slug,
        title="Replays & Drills",
        active_slug="video-gallery",
        body_html=body,
        toc=None,
        include_mermaid=False,
        extra_scripts=gallery_js,
        built_utc=built_utc,
    )


def _build_showcase_card(
    *,
    meta_left: str,
    title: str,
    caption: str,
    src: str,
    poster: str,
    download_url: str,
    playable_mp4: bool,
    title_html: Optional[str] = None,
    caption_html: Optional[str] = None,
) -> str:
    media_html = render_video_element(
        src=src,
        poster=poster,
        title=title,
        download_url=download_url,
        playable_mp4=playable_mp4,
    )
    t_out = title_html if title_html is not None else html.escape(title)
    c_out = caption_html if caption_html is not None else html.escape(caption)
    return (
        f'<article class="clip-card">'
        f'<div class="gallery-meta-row"><span>{html.escape(meta_left)}</span></div>'
        f"<h4>{t_out}</h4>"
        f'<figure class="clip-figure">{media_html}<figcaption>{c_out}</figcaption></figure>'
        f"</article>"
    )


def _render_standings_tables(
    ai_live: Dict[str, Any],
    dash_bots: List[Dict[str, Any]],
    recent_note_builds: str,
) -> str:
    """Render live AI Arena standings for BOTH v2 (Division 5) and v1 (Division 9), with mobile cards."""
    blocks: List[str] = []

    if ai_live.get("available"):
        # 1. v2 Cohort — Division 5 (~1600+ Elo meta)
        v2_bots = ai_live.get("v2_bots") or []
        if v2_bots:
            v2_rows = []
            v2_mob = []
            for b in v2_bots:
                rec = f"{b['w']}–{b['l']}" + (f"–{b['t']}" if b.get("t") else "")
                wr_s = f"{rec} ({b['win_perc']:.0f}%)" if (b["w"] + b["l"] + b["t"]) else "—"
                opp_s = f"{b['opp_elo_avg']}" if b.get("opp_elo_avg") else "—"
                v2_rows.append(
                    f"<tr>"
                    f'<td class="nw"><strong>{html.escape(b["bot"])}</strong></td>'
                    f'<td class="nw">{html.escape(b["race"])}</td>'
                    f'<td class="nw" style="text-align:right">Div {b["division"]}</td>'
                    f'<td class="nw" style="text-align:right"><strong>{b["elo"]}</strong></td>'
                    f'<td class="nw" style="text-align:right">{wr_s}</td>'
                    f'<td class="nw" style="text-align:right">{opp_s}</td>'
                    f'<td class="nw" style="text-align:right">{b["crashes"]}</td>'
                    f"<td>{html.escape(b['highlight'])}</td>"
                    f"</tr>"
                )
                v2_mob.append(
                    f'<div class="standing-row">'
                    f'<div class="standing-top">'
                    f'<span class="standing-bot">{html.escape(b["bot"])} '
                    f'<span class="standing-race">· {html.escape(b["race"])} · Div {b["division"]}</span></span>'
                    f'<span class="standing-elo">{b["elo"]}</span>'
                    f"</div>"
                    f'<div class="standing-stats">{wr_s} · Opp avg {opp_s} · {b["crashes"]} crashes</div>'
                    f'<p class="standing-note">{html.escape(b["highlight"])}</p>'
                    f"</div>"
                )
            v2_tag = (
                f"Division 5 · avg opponent Elo {ai_live['v2_opp_elo_avg']:.0f} ({ai_live['v2_opp_elo_min']}–{ai_live['v2_opp_elo_max']})"
                if ai_live.get("v2_opp_elo_avg")
                else "Division 5"
            )
            blocks.append(f"""
  <div class="cohort-heading">
    <h3>v2 Cohort (Division 5)</h3>
    <span class="cohort-tag">{html.escape(v2_tag)}</span>
  </div>
  <div class="table-wrap standings-desktop">
    <table>
      <thead>
        <tr>
          <th>Bot</th>
          <th>Race</th>
          <th style="text-align:right">Div</th>
          <th style="text-align:right">Rating</th>
          <th style="text-align:right">Season</th>
          <th style="text-align:right">Opp Elo</th>
          <th style="text-align:right">Crashes</th>
          <th>Notes</th>
        </tr>
      </thead>
      <tbody>{"".join(v2_rows)}</tbody>
    </table>
  </div>
  <div class="standings-mobile" aria-label="Live AI Arena v2 Division 5 standings">
    {"".join(v2_mob)}
  </div>
""")

        # 2. v1 Cohort — Division 9 (~1350 Elo meta)
        v1_bots = ai_live.get("v1_bots") or []
        if v1_bots:
            v1_rows = []
            v1_mob = []
            for b in v1_bots:
                rec = f"{b['w']}–{b['l']}" + (f"–{b['t']}" if b.get("t") else "")
                wr_s = f"{rec} ({b['win_perc']:.1f}%)" if (b["w"] + b["l"] + b["t"]) else "—"
                opp_s = f"{b['opp_elo_avg']}" if b.get("opp_elo_avg") else "—"
                tr_v = float(b.get("recent_trade") or 0.0)
                tr_cls = "t-win" if tr_v >= 1.0 else ""
                tr_s = f"{tr_v:.2f}×" if tr_v > 0 else "—"
                v1_rows.append(
                    f"<tr>"
                    f'<td class="nw"><strong>{html.escape(b["bot"])}</strong></td>'
                    f'<td class="nw">{html.escape(b["race"])}</td>'
                    f'<td class="nw" style="text-align:right">Div {b["division"]}</td>'
                    f'<td class="nw" style="text-align:right"><strong>{b["elo"]}</strong></td>'
                    f'<td class="nw" style="text-align:right">{wr_s}</td>'
                    f'<td class="nw {tr_cls}" style="text-align:right">{tr_s}</td>'
                    f'<td class="nw" style="text-align:right">{opp_s}</td>'
                    f"<td>{html.escape(b['highlight'])}</td>"
                    f"</tr>"
                )
                v1_mob.append(
                    f'<div class="standing-row">'
                    f'<div class="standing-top">'
                    f'<span class="standing-bot">{html.escape(b["bot"])} '
                    f'<span class="standing-race">· {html.escape(b["race"])} · Div {b["division"]}</span></span>'
                    f'<span class="standing-elo">{b["elo"]}</span>'
                    f"</div>"
                    f'<div class="standing-stats">{wr_s} · <span class="{tr_cls}">{tr_s} recent trade</span> · Opp avg {opp_s}</div>'
                    f'<p class="standing-note">{html.escape(b["highlight"])}</p>'
                    f"</div>"
                )
            v1_tag = (
                f"Division 9 · avg opponent Elo {ai_live['v1_opp_elo_avg']:.0f} ({ai_live['v1_opp_elo_min']}–{ai_live['v1_opp_elo_max']})"
                if ai_live.get("v1_opp_elo_avg")
                else "Division 9"
            )
            blocks.append(f"""
  <div class="cohort-heading">
    <h3>v1 Cohort (Division 9)</h3>
    <span class="cohort-tag">{html.escape(v1_tag)}</span>
  </div>
  <div class="table-wrap standings-desktop">
    <table>
      <thead>
        <tr>
          <th>Bot</th>
          <th>Race</th>
          <th style="text-align:right">Div</th>
          <th style="text-align:right">Rating</th>
          <th style="text-align:right">Season</th>
          <th style="text-align:right">Recent Trade</th>
          <th style="text-align:right">Opp Elo</th>
          <th>Notes</th>
        </tr>
      </thead>
      <tbody>{"".join(v1_rows)}</tbody>
    </table>
  </div>
  <div class="standings-mobile" aria-label="Live AI Arena v1 Division 9 standings">
    {"".join(v1_mob)}
  </div>
""")

        note_html = (
            '<p class="table-note">'
            "AI Arena ratings start at 1600. The v2 accounts play Division 5 (~1600+ Elo) opponents and recorded zero crashes "
            "(the fetched standings above reflect games played prior to the latest rollout), while the older v1 "
            "accounts play Division 9 (~1350 Elo), where Release #9 went 19–9–3 (61.3% wins, 71.0% win-or-tie) across ranked games. "
            'All eight bots now run <strong>Release #11</strong> (Build 59C, Competition #38, '
            '<a href="https://github.com/sticklane/mothman-sc2-bot/actions/runs/45108531214" target="_blank" rel="noopener noreferrer">deploy run 45108531214</a>, '
            "8/8 verified active). Trade ratio divides enemy army and worker value destroyed by our own value lost."
            "</p>"
        )
        return "".join(blocks) + note_html

    # Fallback when live AI Arena JSON snapshot is unavailable (SQLite v1 table only)
    bot_rows = []
    mobile_rows = []
    for b in dash_bots:
        tot = b["w"] + b["l"]
        wr_s = f"{b['w']}–{b['l']} ({round(100.0 * b['w'] / tot)}%)" if tot else "—"
        tr_cls = "t-win" if b["trade"] >= 1.0 else ""
        bot_rows.append(
            f"<tr>"
            f'<td class="nw"><strong>{html.escape(b["bot"])}</strong></td>'
            f'<td class="nw">{html.escape(b["race"])}</td>'
            f'<td class="nw" style="text-align:right"><strong>{b["elo"]}</strong></td>'
            f'<td class="nw" style="text-align:right">{wr_s}</td>'
            f'<td class="nw {tr_cls}" style="text-align:right">{b["trade"]:.2f}×</td>'
            f"<td>{html.escape(b['highlight'])}</td>"
            f"</tr>"
        )
        mobile_rows.append(
            f'<div class="standing-row">'
            f'<div class="standing-top">'
            f'<span class="standing-bot">{html.escape(b["bot"])} '
            f'<span class="standing-race">· {html.escape(b["race"])}</span></span>'
            f'<span class="standing-elo">{b["elo"]}</span>'
            f"</div>"
            f'<div class="standing-stats">{wr_s} · '
            f'<span class="{tr_cls}">{b["trade"]:.2f}× trade</span></div>'
            f'<p class="standing-note">{html.escape(b["highlight"])}</p>'
            f"</div>"
        )
    return f"""
  <div class="table-wrap standings-desktop">
    <table>
      <thead>
        <tr>
          <th>Bot</th>
          <th>Race</th>
          <th style="text-align:right">Rating</th>
          <th style="text-align:right">Recent</th>
          <th style="text-align:right">Trade</th>
          <th>Notes</th>
        </tr>
      </thead>
      <tbody>{"".join(bot_rows)}</tbody>
    </table>
  </div>
  <div class="standings-mobile" aria-label="Live AI Arena standings">
    {"".join(mobile_rows)}
  </div>
  <p class="table-note">
    AI Arena ratings start at 1600. Recent records combine {html.escape(recent_note_builds)}.
    Trade ratio divides enemy army and worker value destroyed by our own value lost, so 1.0× is an even trade.
  </p>
"""


def build_index_page(
    *,
    repo_slug: str,
    repo_dir: Path,
    brain_dir: Path,
    sqlite_path: Path,
    published_specs: List[ReportSpec],
    gallery_items: List[Dict[str, Any]],
    media_by_tag: Dict[str, Dict[str, str]],
    staged_mp4_map: Dict[str, str],
    staged_poster_map: Dict[str, str],
    built_utc: str,
    dash: Optional[Dict[str, Any]] = None,
    rich: Optional[Dict[str, Any]] = None,
) -> str:
    """Build index.html focused strictly on Current State + Complete Tactics Arena Gallery."""
    dash = dash or load_dashboard_telemetry(sqlite_path)
    rich = rich or load_rich_report_telemetry(
        sqlite_path=sqlite_path, repo_dir=repo_dir, brain_dir=brain_dir
    )
    ai_live = load_aiarena_live_summary(brain_dir, sqlite_path)
    cb = rich.get("current_build") or {}
    live_loop_num = int(cb.get("live_loop_num") or 57)
    live_ship_num = int(cb.get("live_ship_num") or 10)
    b_tag = cb.get("build_tag") or cb.get("loop_num") or live_loop_num

    latest_lbl = dash["latest_build_label"]
    latest_w = dash["latest_build_w"]
    latest_l = dash["latest_build_l"]
    prev_lbl = dash["prev_build_label"]
    prev_w = dash["prev_build_w"]
    prev_l = dash["prev_build_l"]
    comb_w = prev_w + latest_w
    comb_l = prev_l + latest_l
    latest_num_m = re.search(r"(\d+)", latest_lbl)
    prev_num_m = re.search(r"(\d+)", prev_lbl)
    latest_b_num = int(latest_num_m.group(1)) if latest_num_m else 45
    prev_b_num = int(prev_num_m.group(1)) if prev_num_m else 42
    if cb.get("is_shipped") and cb.get("ship_num"):
        eyebrow_txt = f"AI Arena Ladder · Live Release #{cb['ship_num']} (Build {b_tag})"
    else:
        eyebrow_txt = f"AI Arena Ladder · Live Release #{live_ship_num} (Build {live_loop_num}) · Local Benchmark: Build {b_tag}"
    recent_note_builds = f"Builds {prev_b_num} and {latest_b_num} ({comb_w} wins, {comb_l} losses across completed v1 games)"

    # 1. Build Per-Category Playable Tactics Arena Video Clips (EVERY verified scenario we run — NO [:4] cap!)
    clips_by_cat: Dict[str, List[Dict[str, Any]]] = {}
    scen_meta_by_id: Dict[str, Dict[str, Any]] = {}
    scen_json_p = repo_dir / "tools/arena-scenarios.json"
    if scen_json_p.is_file():
        try:
            for sc in json.loads(scen_json_p.read_text(encoding="utf-8")).get("scenarios", []):
                if sc.get("id"):
                    scen_meta_by_id[str(sc["id"])] = sc
        except Exception:
            pass
    arena_res_by_id: Dict[str, Dict[str, Any]] = dict(rich["arena3"].get("scenario_results") or {})
    arena_loop_num = int(rich["arena3"].get("loop_num") or 48)
    duel_json_p = brain_dir / "scratch" / "loop" / f"tactics_sc2_duel_iter{arena_loop_num}.json"
    if duel_json_p.is_file():
        try:
            for sc in json.loads(duel_json_p.read_text(encoding="utf-8")).get("scenarios", []):
                if sc.get("id") and str(sc["id"]) not in arena_res_by_id:
                    arena_res_by_id[str(sc["id"])] = sc
        except Exception:
            pass

    arena_gallery = [
        it for it in gallery_items
        if it.get("playable_mp4") and it.get("category") == "Tactics Drills"
    ]
    arena_gallery.sort(
        key=lambda x: (
            -int(x.get("loop_num") or 0),
            -int(x.get("pass_num") or 0),
            0 if x.get("outcome") == "win" else 1,
        )
    )
    seen_clip_sid: set[str] = set()
    for it in arena_gallery:
        src_name = Path(str(it.get("src") or "")).stem
        m_sid = re.search(r"(sc2-[a-z0-9-]+)$", src_name)
        sid = m_sid.group(1) if m_sid else ""
        if not sid or sid in seen_clip_sid:
            continue
        if sid not in scen_meta_by_id and not it.get("cohort"):
            continue
        seen_clip_sid.add(sid)
        smeta = scen_meta_by_id.get(sid, {})
        sres = arena_res_by_id.get(sid, {})
        cat = str(smeta.get("category") or sres.get("category") or it.get("cohort") or "other")
        if sid == "sc2-det-d10-t-cloaked-banshee-viking-vs-observers-stalker" and int(it.get("loop_num") or 0) >= 51:
            desc = (
                "Vikings clear both Observers so Cloaked Banshees stay invisible, then land on the remaining "
                "Stalkers while the Raven casts Anti-Armor Missile and Auto-Turret and survives."
            )
        elif sid == "sc2-real-t14-raven-imatrix-aam-bio-vs-colossus" and int(it.get("loop_num") or 0) >= 51:
            desc = (
                "Both Ravens open with Interference Matrix to shut down both enemy Colossi before they fire, "
                "follow with Anti-Armor Missile on the Stalkers, and land Vikings to finish the sweep with zero Ravens or Medivacs lost."
            )
        else:
            desc = _clean_drill_caption(str(smeta.get("description") or it.get("subtitle") or ""))
        outcome_val = str(it.get("outcome") or "win")
        scoring_mode = str(it.get("scoring_mode") or sres.get("scoring_mode") or smeta.get("scoring_mode") or "").lower()
        nc_raw = it.get("non_combat_score") if it.get("non_combat_score") is not None else sres.get("non_combat_score")
        nc_score = float(nc_raw) if isinstance(nc_raw, (int, float)) else None
        is_nc = (scoring_mode == "non-combat") or (cat == "non-combat") or (nc_score is not None)
        if is_nc:
            tr_str = ""
        else:
            tr = it.get("trade_ratio") if it.get("trade_ratio") is not None else sres.get("trade_ratio")
            tr_lbl = _format_trade_label(tr, outcome_val)
            tr_str = f" · {tr_lbl}" if tr_lbl else ""
        sv = it.get("spell_verified")
        if sv is None and "spell_verified" in sres:
            sv = sres.get("spell_verified")
        race_val = str(it.get("race") or _race_full(str(smeta.get("our_race") or smeta.get("p1_race") or smeta.get("race") or "")))
        res_lbl = str(it.get("result_label") or "Drill")
        if is_nc and res_lbl in ("Win", "Loss"):
            res_lbl = "Pass" if outcome_val == "win" else "Fail"
        clips_by_cat.setdefault(cat, []).append(
            {
                "id": sid,
                "race": race_val,
                "meta": f"{it.get('loop', f'Loop {arena_loop_num}')} · {race_val}{tr_str}",
                "outcome": outcome_val,
                "result_label": res_lbl,
                "non_combat_score": nc_score,
                "scoring_mode": "non-combat" if is_nc else scoring_mode,
                "spell_verified": sv,
                "title": it.get("title", _format_drill_title(sid)),
                "caption": desc,
                "src": it["src"],
                "poster": it.get("poster", ""),
                "download_url": it.get("download_url") or it["src"],
                "playable_mp4": True,
            }
        )
    for cat_clips in clips_by_cat.values():
        cat_clips.sort(
            key=lambda cl: (
                0 if cl.get("spell_verified") is True else (1 if cl.get("outcome") == "win" else 2),
                str(cl.get("id") or ""),
            )
        )

    # 2. Compact Full-Match Featured Replays strip (4 playable in-browser replays)
    match_flagships = [
        (
            "showcase:h2h003",
            "Protoss · Head-to-Head",
            "Mothman-P vs. Previous Live Build (PvP · 3.40×)",
            "Protoss mirror win with Blink Stalkers, Immortals, and Colossi.",
            None,
            None,
        ),
        (
            "showcase:h2h006",
            "Terran · Head-to-Head",
            "Mothman-T vs. Previous Live Build (TvZ · 6.32×)",
            "Infantry, Siege Tank, and Medivac push breaks Zerg expansions.",
            None,
            None,
        ),
        (
            "showcase:m074",
            "Terran · Held-Out Bot",
            "Mothman-T vs. who (TvP · 23.75×)",
            "Terran win against held-out bot who, finished under nine minutes with 1.8% supply-blocked time.",
            "Mothman-T vs. <code>who</code> (TvP · 23.75×)",
            "Terran win against held-out bot <code>who</code>, finished under nine minutes with 1.8% supply-blocked time.",
        ),
        (
            "showcase:h2h002",
            "Terran · Head-to-Head",
            "Mothman-T vs. Previous Live Build (TvT · 2.18×)",
            "Terran mirror win behind earlier Siege Tanks and faster second-base timing.",
            None,
            None,
        ),
    ]
    featured_cards: List[str] = []
    for key, meta_l, title, cap, title_h, cap_h in match_flagships:
        if key in staged_mp4_map:
            featured_cards.append(
                _build_showcase_card(
                    meta_left=meta_l,
                    title=title,
                    caption=cap,
                    src=staged_mp4_map[key],
                    poster=staged_poster_map.get(key, ""),
                    download_url=staged_mp4_map[key],
                    playable_mp4=True,
                    title_html=title_h,
                    caption_html=cap_h,
                )
            )

    standings_html = _render_standings_tables(ai_live, dash["bots"], recent_note_builds)
    sec_matchups = render_matchup_evaluation_section(rich, section_num="Section 2")
    sec_tactics = render_tactics_explorer_section(rich, clips_by_cat, section_num="Section 3")
    sec_arch = render_architecture_section(rich, section_num="Section 4", include_history_details=False)

    replays_strip = ""
    if featured_cards:
        replays_strip = f"""
<section class="section-rule wide-col" aria-labelledby="replays-heading">
  <div class="section-head">
    <h2 id="replays-heading" class="section-kicker">Selected Full-Match Replays</h2>
    <p class="section-intro">
      Full-length games playable directly in your browser.
      <a href="./video-gallery.html">Browse all {len(gallery_items):,} recorded matches and combat drills →</a>
    </p>
  </div>
  <div class="featured-grid">{"".join(featured_cards)}</div>
</section>
"""

    body = f"""
<header class="masthead wide-col">
  <p class="eyebrow">{html.escape(eyebrow_txt)}</p>
  <h1>Mothman StarCraft II Bots</h1>
  <p class="lead" style="max-width:740px;">
    Eight StarCraft II bots written in Racket play Protoss, Terran, Zerg, and Random across AI Arena's
    Division 5 (v2) and Division 9 (v1) ladders. This page covers where the live build stands right now;
    past releases, bug write-ups, and iteration history live on <a href="./history.html">History &amp; Fixes</a>.
  </p>
  <nav class="jump-bar" aria-label="Current state sections">
    <a href="#standings-heading">1. Live AI Arena</a>
    <a href="#matchups-section">2. Local Benchmark</a>
    <a href="#tactics-section">3. Tactics Arena</a>
    <a href="#architecture-section">4. How It Plays</a>
    <a href="./history.html">History &amp; Fixes →</a>
  </nav>
</header>

<section class="wide-col" aria-labelledby="standings-heading">
  <div class="section-head">
    <p class="section-num">Section 1</p>
    <h2 id="standings-heading" class="section-kicker">Live AI Arena Standings (v2 &amp; v1)</h2>
  </div>
  {standings_html}
  <details style="margin-top:0.75rem;">
    <summary>StarCraft II and benchmark terms used on this page</summary>
    <ul class="compact-list" style="margin-top:0.5rem;">
      <li><strong>Supply-blocked:</strong> Share of match time the bot could not train units because it hit its current supply cap (Pylons, Supply Depots, or Overlords). Lower is better; under 4% is solid.</li>
      <li><strong>Natural expansion:</strong> The second base site just outside a player's starting main base.</li>
      <li><strong>Bio / 1-1-1 / 12-Pool:</strong> <em>Bio</em> is Terran infantry (Marines, Marauders, Medivacs). <em>1-1-1</em> is opening one Barracks, one Factory, and one Starport. <em>12-Pool</em> is an immediate Zergling rush started at 12 workers.</li>
      <li><strong>14 Core Bots vs. All 26 Local Bots:</strong> Locally we test against 14 regular practice bots (<em>Core-14</em>) plus 12 held-out bots (<em>Unseen-12</em>) that we never tune against directly, so we can tell whether a change generalizes. Matches hitting the 30-minute time limit count as ties.</li>
    </ul>
  </details>
</section>

{sec_matchups}
{sec_tactics}
{replays_strip}
{sec_arch}

<section class="section-rule wide-col">
  <div class="history-cta">
    <p><strong>Looking for older builds, past bugs we fixed, or the full iteration log?</strong> Ladder history charts, release notes, and technical deep dives live on the companion history page.</p>
    <a href="./history.html">Open History &amp; Fixes →</a>
  </div>
</section>
"""
    return render_page_shell(
        repo_slug=repo_slug,
        title="Mothman — StarCraft II Bots (Current State)",
        active_slug="index",
        body_html=body,
        toc=None,
        include_mermaid=False,
        extra_scripts=INTERACTIVE_SECTIONS_JS,
        built_utc=built_utc,
    )


def build_history_page(
    *,
    repo_slug: str,
    repo_dir: Path,
    brain_dir: Path,
    sqlite_path: Path,
    published_specs: List[ReportSpec],
    media_by_tag: Dict[str, Dict[str, str]],
    built_utc: str,
    dash: Optional[Dict[str, Any]] = None,
    rich: Optional[Dict[str, Any]] = None,
) -> str:
    """Build history.html housing ladder progression, testing workflow, bugs fixed, release log, and notes."""
    dash = dash or load_dashboard_telemetry(sqlite_path)
    rich = rich or load_rich_report_telemetry(
        sqlite_path=sqlite_path, repo_dir=repo_dir, brain_dir=brain_dir
    )
    sym = dash["symmetry"]
    latest_lbl = dash["latest_build_label"]
    latest_w = dash["latest_build_w"]
    latest_l = dash["latest_build_l"]
    latest_n = dash.get("latest_build_n", latest_w + latest_l)
    latest_tr = dash["latest_build_trade"]
    prev_lbl = dash["prev_build_label"]
    prev_w = dash["prev_build_w"]
    prev_l = dash["prev_build_l"]
    prev_n_val = dash.get("prev_build_n", prev_w + prev_l)
    latest_ties = max(0, latest_n - latest_w - latest_l)
    prev_ties = max(0, prev_n_val - prev_w - prev_l)
    latest_rec_str = f"{latest_w}–{latest_l}" + (f"–{latest_ties}" if latest_ties else "")
    prev_rec_str = f"{prev_w}–{prev_l}" + (f"–{prev_ties}" if prev_ties else "")
    latest_num_m = re.search(r"(\d+)", latest_lbl)
    prev_num_m = re.search(r"(\d+)", prev_lbl)
    latest_b_num = int(latest_num_m.group(1)) if latest_num_m else 45
    prev_b_num = int(prev_num_m.group(1)) if prev_num_m else 42

    prod_series = [dict(s) for s in dash["prod_series"]]
    has_l51 = any(
        str(s.get("label") or "").strip().lower() in ("loop 51", "build 51", "l51")
        or str(s.get("bv") or "") == "nkxlrsuk_4e7c6f39"
        for s in prod_series
    )
    if not has_l51 and prod_series:
        prod_series.append(
            {
                "bv": "nkxlrsuk_4e7c6f39",
                "label": "Loop 51",
                "n": 31,
                "w": 19,
                "l": 9,
                "wr": 61.3,
                "trade": None,
            }
        )

    chart_live_svg = render_live_progress_svg(prod_series)
    chart_sym_svg = render_symmetry_svg(sym)
    live_caption = (
        f"The first deployed build went 0–10 on AI Arena. Recent v1 builds win roughly 55–61% of their games: "
        f"Build {prev_b_num} went {prev_rec_str}, Build {latest_b_num} went {latest_rec_str} ({latest_tr:.2f}× trade), "
        f"and Release #9 (Build 51) climbed to 19–9–3 (61.3% wins) before Release #10 (Build 57) and Release #11 "
        f'(Build 59C, <a href="https://github.com/sticklane/mothman-sc2-bot/actions/runs/45108531214" target="_blank" rel="noopener noreferrer">deploy run 45108531214</a>) '
        f"rolled out to all 8 ladder bots."
    )

    sec_loop = render_loop_diagram_section(rich, section_num="Section 2")
    sec_issues = render_issues_fixed_section(chart_sym_svg, sym, rich, section_num="Section 3")
    hist_faults = render_historical_faults_details(rich)

    # Reading lists (Campaign Updates & Technical Notes)
    progress_items = [
        '<li class="doc-item">'
        '<a class="doc-item-title" href="./video-gallery.html">Replay library</a>'
        '<p class="doc-item-desc">Filterable recordings of full matches and combat drills across past loops, races, and opponents.</p>'
        "</li>"
    ]
    evergreen_order = (
        "loop-flywheel-retro",
        "north-vs-south-audit",
        "mirror-brain-audit",
        "pro-macro-design",
        "belief-engine-plan",
        "prod-audit",
        "3d-rendering-proof",
    )
    evergreen_by_slug: Dict[str, str] = {}
    per_loop_items: List[str] = []
    for sp in published_specs:
        li = (
            f'<li class="doc-item">'
            f'<a class="doc-item-title" href="./{sp.out_file}">{html.escape(sp.title)}</a>'
            f'<p class="doc-item-desc">{html.escape(sp.summary)}</p>'
            f"</li>"
        )
        if sp.section in ("Progress & Replays", "Write-ups"):
            progress_items.append(li)
        elif sp.slug in evergreen_order:
            evergreen_by_slug[sp.slug] = li
        else:
            per_loop_items.append(li)
    evergreen_items = [evergreen_by_slug[sl] for sl in evergreen_order if sl in evergreen_by_slug]
    per_loop_archive_html = (
        '<details style="margin-top:0.85rem;">'
        "<summary>Per-loop forensic notes &amp; raw run log (Loops 36–47)</summary>"
        f'<ul class="doc-list" style="margin-top:0.65rem;">{"".join(per_loop_items)}</ul>'
        "</details>"
        if per_loop_items
        else ""
    )

    # Shipped Releases Table + Collapsible Benchmark Ledger from loop_ledger.json
    _SHIP_RELEASE_NUMS: Dict[str, int] = {
        "iter34_wave34_full": 1,
        "iter36_wave36_full": 2,
        "iter37_wave37_full": 3,
        "iter40_wave40_full": 4,
        "iter42_wave42_full": 5,
        "iter45_wave45_full": 6,
        "iter48_wave48_full": 7,
        "iter50_w3_full": 8,
        "iter51_ship9_full": 9,
        "iter57_ship10_full": 10,
        "iter59c_ship11_full": 11,
    }

    def _format_run_label(run_id: str, status_raw: str = "") -> str:
        rid = str(run_id or "").strip()
        st_u = str(status_raw or "").upper()
        is_shipped = "SHIP" in st_u and "HOLD" not in st_u and "FAIL" not in st_u
        m_iter = re.match(r"^iter(\d+[a-z]?)(?=_|$|-)", rid, flags=re.I)
        btag = m_iter.group(1).upper() if m_iter else ""
        if rid in _SHIP_RELEASE_NUMS and (is_shipped or not st_u):
            rel_n = _SHIP_RELEASE_NUMS[rid]
            return f"Release #{rel_n} (Build {btag})" if btag else f"Release #{rel_n}"
        if is_shipped:
            m_sh = re.search(r"ship(\d+)", rid, flags=re.I) or re.search(r"SHIP_(\d+)", st_u)
            if m_sh and btag:
                return f"Release #{int(m_sh.group(1))} (Build {btag})"
        if btag:
            return f"Build {btag}"
        return rid

    shipped_table_html = ""
    ledger_section = ""
    ledger_path = repo_dir / "tools/iteration-loop/loop_ledger.json"
    if ledger_path.is_file():
        try:
            ld = json.loads(ledger_path.read_text(encoding="utf-8"))
            iters = ld.get("iterations", [])
            shipped_rows = []
            for it in reversed(iters):
                st = str(it.get("status") or "").upper()
                if "SHIP" not in st or "HOLD" in st or "FAIL" in st:
                    continue
                cn = int(it.get("clean_n") or 0)
                if cn < 70:
                    continue
                raw_id = str(it.get("id", ""))
                it_id = html.escape(_format_run_label(raw_id, st))
                rec_short = _format_ledger_record(str(it.get("record_clean", "")))
                c14 = it.get("core14_wr_pct")
                c14_s = f"{float(c14):.1f}%" if isinstance(c14, (int, float)) else "—"
                u12 = it.get("unseen12_wins")
                u12_s = f"{int(u12)} wins" if isinstance(u12, (int, float)) else "—"
                tr = it.get("trade_agg")
                tr_s = f"{tr:.2f}×" if isinstance(tr, (int, float)) else "—"
                sb = it.get("sup_blk_pct")
                sb_s = f"{sb:.1f}%" if isinstance(sb, (int, float)) else "—"
                shipped_rows.append(
                    f"<tr>"
                    f'<td class="nw"><strong>{it_id}</strong></td>'
                    f"<td>{html.escape(rec_short)}</td>"
                    f'<td style="text-align:right">{c14_s}</td>'
                    f'<td style="text-align:right">{u12_s}</td>'
                    f'<td style="text-align:right">{tr_s}</td>'
                    f'<td style="text-align:right">{sb_s}</td>'
                    f"</tr>"
                )
            if shipped_rows:
                shipped_table_html = f"""
  <div class="table-wrap" style="margin-bottom:1.1rem;">
    <table>
      <thead>
        <tr>
          <th>Shipped Release Run</th>
          <th>External Benchmark Record</th>
          <th style="text-align:right">14 Core WR</th>
          <th style="text-align:right">12 Held-Out</th>
          <th style="text-align:right">Trade</th>
          <th style="text-align:right">Supply-Blocked</th>
        </tr>
      </thead>
      <tbody>{"".join(shipped_rows[:12])}</tbody>
    </table>
  </div>
"""
            recent = list(reversed(iters[-18:]))
            lrows = []
            cur_b = (rich or {}).get("current_build") or {}
            cur_tag = str(cur_b.get("build_tag") or "").upper()
            cur_ext = (cur_b.get("cohorts") or {}).get("ext") or {}
            already_has_cur = bool(
                cur_tag
                and any(
                    re.match(rf"^iter{re.escape(cur_tag)}(?=_|$|-)", str(it.get("id") or ""), flags=re.I)
                    for it in recent
                )
            )
            if cur_tag and cur_ext.get("n") and not already_has_cur:
                cw, cl, ct = int(cur_ext.get("w", 0)), int(cur_ext.get("l", 0)), int(cur_ext.get("t", 0))
                cn_cur = int(cur_ext.get("n", cw + cl + ct))
                rec_cur = _format_ledger_record(f"{cw}W-{cl}L-{ct}T" if ct else f"{cw}W-{cl}L")
                tr_cur = f"{float(cur_ext['tr']):.2f}×" if isinstance(cur_ext.get("tr"), (int, float)) else "—"
                sb_cur = f"{float(cur_ext['sb']):.1f}%" if isinstance(cur_ext.get("sb"), (int, float)) else "—"
                lrows.append(
                    f'<tr><td class="nw"><strong>Build {html.escape(cur_tag)}</strong></td>'
                    f"<td>Latest Benchmark</td>"
                    f'<td style="text-align:right">{cn_cur}</td>'
                    f"<td>{html.escape(rec_cur)}</td>"
                    f'<td style="text-align:right">{tr_cur}</td>'
                    f'<td style="text-align:right">{sb_cur}</td>'
                    f"<td>—</td></tr>"
                )
            for it in recent:
                raw_id = str(it.get("id", ""))
                st_raw = str(it.get("status") or "")
                it_id = html.escape(_format_run_label(raw_id, st_raw))
                clean_n = html.escape(str(it.get("clean_n", "")))
                rec_short = _format_ledger_record(str(it.get("record_clean", "")))
                tr = it.get("trade_agg")
                tr_s = f"{tr:.2f}×" if isinstance(tr, (int, float)) else "—"
                sb = it.get("sup_blk_pct")
                sb_s = f"{sb:.1f}%" if isinstance(sb, (int, float)) else "—"
                st_lbl = "Shipped" if ("SHIP" in st_raw.upper() and "HOLD" not in st_raw.upper()) else ("Held" if "HOLD" in st_raw.upper() else st_raw[:18])
                m_it = re.match(r"iter(\d+)", raw_id)
                rel_cell = "—"
                if m_it:
                    lnum_it = int(m_it.group(1))
                    tag = f"media-iter{lnum_it}"
                    tag_map = media_by_tag.get(tag) or {}
                    has_live_gh_release = any(
                        str(u).startswith("https://github.com/") for u in tag_map.values()
                    ) and lnum_it <= 51
                    if has_live_gh_release:
                        rel_cell = (
                            f'<a href="https://github.com/{repo_slug}/releases/tag/{tag}" '
                            f'target="_blank" rel="noopener noreferrer">{tag}</a>'
                        )
                    elif lnum_it == 59:
                        rel_cell = '<a href="./index.html#tactics-section">278 arena clips</a>'
                lrows.append(
                    f'<tr><td class="nw">{it_id}</td>'
                    f"<td>{html.escape(st_lbl)}</td>"
                    f'<td style="text-align:right">{clean_n}</td>'
                    f"<td>{html.escape(rec_short)}</td>"
                    f'<td style="text-align:right">{tr_s}</td>'
                    f'<td style="text-align:right">{sb_s}</td>'
                    f"<td>{rel_cell}</td></tr>"
                )
            ledger_section = (
                "<details>"
                f"<summary>Full practice benchmark ledger (last {len(lrows)} runs)</summary>"
                '<div class="table-wrap"><table><thead><tr>'
                '<th>Run</th><th>Outcome</th><th style="text-align:right">Matches</th>'
                '<th>Record</th><th style="text-align:right">Trade</th>'
                '<th style="text-align:right">Supply-Blocked</th><th>Media</th>'
                f'</tr></thead><tbody>{"".join(lrows)}</tbody></table></div>'
                "</details>"
            )
        except Exception:
            pass

    body = f"""
<header class="masthead wide-col">
  <p class="eyebrow">Campaign Archive · Releases &amp; Bug Fixes</p>
  <h1>History &amp; Fixes</h1>
  <p class="lead" style="max-width:740px;">
    How Mothman progressed across live ladder builds, what bugs we caught in replays and combat drills,
    and our complete release and benchmark history. For where the bots stand right now, see
    <a href="./index.html">Current State</a>.
  </p>
  <nav class="jump-bar" aria-label="History sections">
    <a href="#ladder-history">1. Ladder History</a>
    <a href="#loop-section">2. Testing Loop</a>
    <a href="#issues-section">3. Bugs Fixed</a>
    <a href="#releases-section">4. Releases &amp; Runs</a>
    <a href="#technical-notes">5. Archive &amp; Notes</a>
  </nav>
</header>

<section class="wide-col" id="ladder-history">
  <div class="section-head">
    <p class="section-num">Section 1</p>
    <h2 class="section-kicker">Live Ladder Progression</h2>
    <p class="section-intro">
      Win rate and trade ratio across live AI Arena builds from the initial release through our recent v1 deployments.
    </p>
  </div>
  <figure class="figure-block" style="margin-top:0.5rem;">
    <div class="figure-label">Figure 1 · Ladder History</div>
    <div class="figure-title">Win rate and trade ratio across live AI Arena builds</div>
    {chart_live_svg}
    <figcaption class="figure-caption">{live_caption}</figcaption>
  </figure>
</section>

{sec_loop}
{sec_issues}

<section class="section-rule wide-col" id="releases-section">
  <div class="section-head">
    <p class="section-num">Section 4</p>
    <h2 class="section-kicker">Shipped Releases &amp; Practice Runs</h2>
    <p class="section-intro">
      Every shipped release passed our head-to-head gate, full local benchmark, and standalone 4-race package check before going live.
    </p>
  </div>
  {shipped_table_html}
  {ledger_section}
  {hist_faults}
</section>

<section class="section-rule prose-col" id="technical-notes">
  <div class="section-head">
    <p class="section-num">Section 5</p>
    <h2 class="section-kicker">Campaign Logs &amp; Technical Notes</h2>
  </div>
  <h3 style="margin:0.25rem 0 0.6rem;font-size:1.06rem;">Campaign Updates</h3>
  <ul class="doc-list">{"".join(progress_items)}</ul>

  <h3 style="margin:2rem 0 0.5rem;font-size:1.06rem;">Technical Notes</h3>
  <p class="prose-tight">
    Deep dives into map symmetry, scouting accuracy, economy priorities, and testing workflow, followed by per-loop notes.
  </p>
  <ul class="doc-list">{"".join(evergreen_items)}</ul>
  {per_loop_archive_html}
</section>
"""
    return render_page_shell(
        repo_slug=repo_slug,
        title="History & Fixes",
        active_slug="history",
        body_html=body,
        toc=None,
        include_mermaid=False,
        extra_scripts=INTERACTIVE_SECTIONS_JS,
        built_utc=built_utc,
    )


def _sanitize_flywheel_retro_md(md: str) -> str:
    """Turn auto-generated loop_flywheel_retro.md into clean cold-reader prose without touching the generator."""
    # 1. Strip internal '- **Files:** ...' lines (removes file paths and extra sub-bullets in Section 5)
    lines = [
        ln for ln in md.splitlines()
        if not re.match(r"^\s*-\s+\*\*Files:\*\*", ln)
    ]
    text = "\n".join(lines)

    # 2. Strip internal *(Owner: @...)* suffixes on Section 5 items
    text = re.sub(r"\s*\*\(Owner:[^)]+\)\*", "", text)

    # 3. Clean ISO timestamp & Section 2 compact headers
    text = re.sub(
        r"`(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}):\d{2}Z`",
        r"\1 \2 UTC",
        text,
    )
    text = text.replace(
        "| Agent | Runs | Steps | Tool Calls | Tool Errs (%) | Edit Misses | Cmd Fails | `raco make` | `run-all-tests` | Monolith Reads | Own Reqs | Compactions | Cache Hit |",
        "| Role | Runs | Steps | Tool Calls | Tool Errs | Edit Miss | Cmd Fail | Builds | Test Runs | Large Reads | Handoffs | Compacts | Cache |",
    )
    text = text.replace("| 84m Bench Min |", "| Bench Min |")

    # 4. Map internal snake_case phase keys, root causes, and agent handles to plain English
    replacements: List[Tuple[str, str]] = [
        # Phase keys (Section 1 + prose)
        ("`benchmark_84`", "84-match benchmark"),
        ("`coding`", "Engineering changes"),
        ("`idle_gaps_sec`", "Idle gaps between phases"),
        ("`forensics`", "Replay forensics"),
        ("`tactics_arena`", "Combat drills"),
        ("`publish`", "Site & release publishing"),
        ("`archival_render`", "Video rendering"),
        ("`gate1_verify`", "Build & test verification"),
        ("`baseline_h2h`", "Head-to-head gate"),
        # Agent roles (Section 2)
        ("`runtime-author`", "Runtime micro"),
        ("`belief-author`", "Macro & scouting"),
        ("`monitor-2`", "Watchdog monitor"),
        ("`coordinator`", "Coordinator"),
        ("`analyzer`", "Replay analyzer"),
        ("`wire-author`", "SC2 protocol wire"),
        ("`loop-architect`", "Process review"),
        ("`reporter`", "Report publisher"),
        ("`harness`", "Match harness"),
        ("`tactics-tester`", "Combat drill runner"),
        ("`verifier`", "Test verifier"),
        ("`opponents`", "Opponent setup"),
        # Root causes (Section 3a)
        ("`sibling_matchup_h2h_regression`", "Head-to-head regression"),
        ("`macro_and_micro_side_effect`", "Macro/micro interaction"),
        ("`runtime_heuristic_regression`", "Global micro heuristic"),
        ("`brain_runtime_split_brain`", "Planner vs. runtime cap mismatch"),
        ("`watchdog_escrow_and_tvp_regression`", "Expansion escrow & TvP stall"),
        # Section 3a summaries
        ("External/Arena improved but H2H mirror/cross-race regressed against live Ship baseline",
         "External and drill scores improved, while head-to-head against the live build regressed"),
        ("Protoss macro/micro interaction (Blink-Forward into Tanks, Gateway overbuild, or 0-Colossus / PvP exclusion)",
         "Protoss macro/micro interaction (Blink into Tanks, Gateway overbuild, or missing Colossi)"),
        ("Global runtime heuristic (light-harass split) lacked posture/main-army parity guard -> Terran TvP 0-8",
         "Global light-harass split lacked a main-army strength guard (Terran TvP 0–8)"),
        ("Macro-brain vs runtime cap/urgency mismatch (Barracks 2*CC cap & Phoenix@860 > Colossus@760)",
         "Macro planner vs. runtime cap mismatch (Barracks 2× Command Center cap and Phoenix priority above Colossus)"),
        ("Expansion escrow flush & Starport gas-yield guard stalled Terran 1-1-1 / TvP (fixed in Loop 50)",
         "Expansion savings and Starport gas-yield guard stalled Terran 1-1-1 openings in TvP (fixed in Loop 50)"),
        # Section 3b fault codes & ability IDs
        ("(`<= 3`-Loop Clusters)", "(3-Loop Clusters)"),
        ("(ProdStall)", "(production stall)"),
        ("(1BaseLock)", "(1-base lock)"),
        ("(PvPNatDelay)", "(PvP natural expansion delay)"),
        ("RoboticsBay", "Robotics Bay"),
        ("(p15 / 1766 / 3757)", "(Dark Templar Blink raid)"),
        ("(b06/b07 / Siege0DPS)", "(Blink-forward into Siege Tanks)"),
        ("(e01 sticky disengage / 3666)", "(worker mineral-walk disengage)"),
        ("(z16 / HOLD_POSITION 18)", "(Mutalisk spread & Hold Position)"),
        ("(r02/r05/r06)", "(worker-rush drills)"),
        ("25-second `--scenario` A/B pass", "25-second targeted drill A/B pass"),
        # Section 4 process table
        ("H2H-First Fail-Fast Gate (2m H2H before 30m 84-Match Roster)",
         "Head-to-head gate before 84-match roster"),
        ("Brain <-> Runtime Cap & Urgency Contract Lint + Macro Trace (<3s Gate 1)",
         "Planner vs. runtime cap contract check (<3s)"),
        ("Targeted 25s --category / --scenario Combat Drill Pre-Check",
         "Targeted 25s combat drill pre-check"),
        ("Author --skip-perf Validation + Solo Verifier Perf Gate",
         "Fast unit validation + solo timing gate"),
        ("Pre-Granted Track Test Ownership in Kickoff Briefs",
         "Pre-assigned test file ownership"),
        # Section 5 prose cleanups
        ("requires a 25s `--scenario` A/B pass before Gate 2.",
         "requires a 25-second targeted drill A/B pass before the full benchmark."),
        ("Pre-Granted Track Test Ownership and `--skip-perf` Author Mode",
         "Pre-Assigned Test Ownership and Fast Unit-Test Mode"),
        ("Authors edit their own track tests directly; @verifier owns wall-clock timing checks on an idle CPU.",
         "Authors edit their own track tests directly; the verifier owns wall-clock timing checks on an idle CPU."),
        ("Each run appends to loop_trajectory_log.jsonl and produces Replay + Video trade review packs.",
         "Each run appends to the run timing log and produces replay and video trade review packs."),
        ("-> ", "→ "),
        (" <= ", " ≤ "),
        (" >= ", " ≥ "),
    ]
    for old, new in replacements:
        text = text.replace(old, new)

    # 5. Unwrap backtick pills around plain numbers, percentages, durations, ranges, records, and IF-* tags
    text = re.sub(
        r"`((?:n=)?\d[\d.,]*\s*(?:%|min|m|h|hours|x|×)?|L\d+[–-](?:L)?\d+|\d+W[-–]\d+L|IF-\d+)`",
        r"\1",
        text,
    )
    text = re.sub(
        r"\(monitor-2 logged ([\d,]+) steps / (\d+) posts?\)",
        lambda m: f"(watchdog polling previously logged {m.group(1)} steps for {m.group(2)} {'alert' if m.group(2) == '1' else 'alerts'})",
        text,
    )
    # Normalize lowercase 'x' multipliers like 1.30x -> 1.30× and W-L records in Table 3a
    text = re.sub(r"(\d+\.\d+)x\b", r"\1×", text)
    text = re.sub(r"\b(\d+)W-(\d+)L\b", r"\1–\2", text)
    text = re.sub(r"\bL(\d+)[–-]L(\d+)\b", r"Loops \1–\2", text)
    text = re.sub(r"Across (Loops \d+–\d+), Engineering changes", r"Across \1, engineering changes", text)
    return text


def _assert_no_local_leaks(html_text: str, page_name: str) -> None:
    if "/home/sjaconette/" in html_text or "file:///" in html_text:
        leaks = re.findall(r"(?:file://)?/home/sjaconette[^\s\"'<>]{0,80}", html_text)
        raise RuntimeError(f"Unrewritten local path leak in {page_name}: {leaks[:5]}")


def build_static_site(
    *,
    repo_slug: str,
    repo_dir: Path,
    brain_dir: Path,
    analyzer_dir: Path,
    sqlite_path: Path,
    out_dir: Path,
    resolved_reports: List[Tuple[ReportSpec, Path]],
    media_by_tag: Dict[str, Dict[str, str]],
    abs_to_asset: Dict[str, Tuple[str, str]],
) -> Dict[str, Dict[str, object]]:
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / ".nojekyll").write_text("", encoding="utf-8")

    built_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    published_specs = [sp for sp, _ in resolved_reports]
    report_filename_to_html: Dict[str, str] = {}
    for sp, src_p in resolved_reports:
        report_filename_to_html[src_p.name] = sp.out_file
        for cand in sp.source_candidates:
            report_filename_to_html[cand.name] = sp.out_file

    # Map mp4 CDN URL -> sibling png poster CDN URL if present in the same release
    poster_lookup: Dict[str, str] = {}
    for tag, amap in media_by_tag.items():
        for fname, u in amap.items():
            if fname.lower().endswith(".mp4"):
                png_name = re.sub(r"\.mp4$", ".png", fname, flags=re.I)
                if png_name in amap:
                    poster_lookup[u] = amap[png_name]

    # Build prioritized same-origin iOS-playable MP4 staging list (H.264 Main L3.1 + JPG posters)
    # Priority order:
    # Deduplicated same-origin MP4 priority queue:
    #   Tier 1: 1 latest verified non-placeholder clip per unique Tactics Arena scenario ID (guarantees 100% Arena coverage!)
    #   Tier 2: Featured showcase full-match replays
    #   Tier 3: Embedded MP4s referenced inside markdown reports
    #   Tier 4: Latest full matches & non-duplicate self-play clips (never bloating gh-pages with older duplicate Arena loops!)
    gallery_items = discover_gallery_items(brain_dir, media_by_tag, abs_to_asset)
    priority_entries: List[Tuple[str, Path, str]] = []

    # Map CDN URL -> local Path for every discovered MP4 so report embeds & gallery items can stage cleanly
    cdn_to_local_mp4: Dict[str, Path] = {}
    for abs_s, (tag, aname) in abs_to_asset.items():
        if abs_s.lower().endswith(".mp4"):
            u = media_by_tag.get(tag, {}).get(aname)
            lp = Path(abs_s)
            if u and lp.is_file() and not _is_placeholder_arena_clip(lp):
                cdn_to_local_mp4[u] = lp

    # Tier 1: Deduplicated unique Tactics Arena scenario clips (latest verified non-placeholder per scenario ID)
    staged_arena_sids: set[str] = set()
    arena_only = [
        it for it in gallery_items
        if it.get("media_type") == "mp4" and it.get("category") == "Tactics Drills"
    ]
    arena_only.sort(
        key=lambda x: (
            -int(x.get("loop_num") or 0),
            -int(x.get("pass_num") or 0),
            0 if x.get("outcome") == "win" else 1,
        )
    )
    for it in arena_only:
        lp_s = it.get("_local_mp4") or ""
        lp = Path(lp_s) if lp_s else cdn_to_local_mp4.get(it.get("src", ""))
        if not lp or not lp.is_file() or _is_placeholder_arena_clip(lp, it):
            continue
        m_sid = re.search(r"(sc2-[a-z0-9-]+)$", lp.stem)
        sid = m_sid.group(1) if m_sid else lp.stem
        if sid in staged_arena_sids:
            continue
        staged_arena_sids.add(sid)
        key = it.get("src") or f"gal:{it.get('_safe_name') or lp.name}"
        sname = it.get("_safe_name") or lp.name
        priority_entries.append((key, lp, sname))

    # Tier 2: Featured full-match replays
    loop_root = brain_dir / "scratch" / "loop"
    flagship_specs = [
        ("showcase:h2h003", loop_root / "visuals_iter45/full_matches/full_h2h003_Mothman-P_vs_Mothman-P-Base.mp4", "feat_l45_h2h003_pvp.mp4"),
        ("showcase:h2h006", loop_root / "visuals_iter45/full_matches/full_h2h006_Mothman-T_vs_Mothman-Z-Base.mp4", "feat_l45_h2h006_tvz.mp4"),
        ("showcase:m074", loop_root / "visuals_iter45/full_matches/full_m074_Mothman-T_vs_who.mp4", "feat_l45_m074_tvt_who.mp4"),
        ("showcase:h2h002", loop_root / "visuals_iter45/full_matches/full_h2h002_Mothman-T_vs_Mothman-T-Base.mp4", "feat_l45_h2h002_tvt.mp4"),
    ]
    for fkey, fp, fname in flagship_specs:
        if fp.is_file() and not _is_placeholder_arena_clip(fp):
            priority_entries.append((fkey, fp, fname))

    # Tier 3: Scan markdown reports for embedded MP4 URLs
    rewrite_md = make_path_rewriter(
        repo_slug=repo_slug,
        repo_dir=repo_dir,
        brain_dir=brain_dir,
        analyzer_dir=analyzer_dir,
        media_by_tag=media_by_tag,
        abs_to_asset=abs_to_asset,
        report_filename_to_html=report_filename_to_html,
    )
    rewritten_reports: List[Tuple[ReportSpec, str]] = []
    for sp, src_path in resolved_reports:
        raw_md = src_path.read_text(encoding="utf-8")
        rew = rewrite_md(raw_md)
        rewritten_reports.append((sp, rew))
        for m_url in re.findall(r"https://[^\s\"'<>)]+\.mp4", rew, flags=re.I):
            lp = cdn_to_local_mp4.get(m_url)
            if lp and lp.is_file() and not _is_placeholder_arena_clip(lp):
                tag, aname = classify_media_path(lp)
                priority_entries.append((m_url, lp, f"{tag}_{aname}"))

    # Tier 4: Latest full matches + 1 latest Self-Play clip per unique scenario ID (capped cleanly; skip duplicate older Arena loops!)
    staged_sp_sids: set[str] = set()
    other_gallery = [
        it for it in gallery_items
        if it.get("media_type") == "mp4" and it.get("category") != "Tactics Drills"
    ]
    def _other_stage_key(it: Dict[str, Any]) -> Tuple[int, int, int]:
        lnum = int(it.get("loop_num") or 0)
        cat = str(it.get("category") or "")
        is_h2h = 0 if "h2h" in str(it.get("cohort") or "").lower() or "h2h" in str(it.get("title") or "").lower() else 1
        cat_rank = 0 if cat == "Full Matches" else 1
        out_rank = 0 if it.get("outcome") == "win" else 1
        return (-lnum, cat_rank, is_h2h * 2 + out_rank)

    full_match_staged_cnt = 0
    for it in sorted(other_gallery, key=_other_stage_key):
        lp_s = it.get("_local_mp4") or ""
        lp = Path(lp_s) if lp_s else cdn_to_local_mp4.get(it.get("src", ""))
        if not lp or not lp.is_file() or _is_placeholder_arena_clip(lp, it):
            continue
        if it.get("category") == "Self-Play Drills":
            m_sid = re.search(r"(sc2-[a-z0-9-]+)$", lp.stem)
            sid = m_sid.group(1) if m_sid else lp.stem
            if sid in staged_sp_sids:
                continue
            staged_sp_sids.add(sid)
        elif it.get("category") == "Full Matches":
            if full_match_staged_cnt >= 32:
                continue
            full_match_staged_cnt += 1
        key = it.get("src") or f"gal:{it.get('_safe_name') or lp.name}"
        sname = it.get("_safe_name") or lp.name
        priority_entries.append((key, lp, sname))

    staged_mp4_map, staged_poster_map = stage_ios_playable_mp4s(
        brain_dir=brain_dir,
        out_dir=out_dir,
        priority_entries=priority_entries,
        max_total_mb=220.0,
        max_workers=4,
    )

    # Also copy rendered 3D Base & Ramp-Wall Layout photos (~740 KB) + Pro vs Mothman Blueprints (~730 KB) into out_dir/media/
    base_layout_src = brain_dir / "scratch" / "base_layouts"
    if base_layout_src.is_dir():
        (out_dir / "media").mkdir(parents=True, exist_ok=True)
        for bf in sorted(base_layout_src.glob("base_layout_*.jpg")):
            shutil.copy2(bf, out_dir / "media" / bf.name)
        for pf in sorted(base_layout_src.glob("pro_vs_mothman_*.png")):
            shutil.copy2(pf, out_dir / "media" / pf.name)

    # Rewrite gallery items to use same-origin playable MP4s & JPG posters, stripping private local keys
    # Never emit links to unpublished GitHub Release tags (> media-iter51 when self-hosted via --skip-media).
    def _is_unpublished_release_url(url: str) -> bool:
        m_rel = re.search(r"/releases/download/media-iter(\d+)\b", str(url or ""))
        return bool(m_rel and int(m_rel.group(1)) > 51)

    clean_gallery_items: List[Dict[str, Any]] = []
    for it in gallery_items:
        item = {k: v for k, v in it.items() if not k.startswith("_")}
        if item.get("media_type") == "mp4":
            orig_src = item.get("src", "")
            key = orig_src or f"gal:{it.get('_safe_name', '')}"
            if key in staged_mp4_map:
                item["src"] = staged_mp4_map[key]
                item["playable_mp4"] = True
                if not item.get("download_url") or _is_unpublished_release_url(str(item.get("download_url"))):
                    item["download_url"] = staged_mp4_map[key]
            else:
                if _is_unpublished_release_url(orig_src):
                    continue
                item["playable_mp4"] = False
                if _is_unpublished_release_url(str(item.get("download_url") or "")):
                    item["download_url"] = item.get("src", "")
            if key in staged_poster_map:
                item["poster"] = staged_poster_map[key]
            elif _is_unpublished_release_url(str(item.get("poster") or "")):
                item["poster"] = ""
        elif _is_unpublished_release_url(str(item.get("src") or "")):
            continue
        clean_gallery_items.append(item)

    # Sort gallery so playable in-browser videos surface cleanly first within each loop
    clean_gallery_items.sort(
        key=lambda x: (
            -int(x.get("loop_num") or 0),
            0 if x.get("playable_mp4") else 1,
            0 if x.get("outcome") == "win" else 1,
        )
    )

    page_stats: Dict[str, Dict[str, object]] = {}
    for sp, rewritten_md in rewritten_reports:
        if sp.slug == "loop-flywheel-retro":
            rewritten_md = _sanitize_flywheel_retro_md(rewritten_md)
        renderer = MarkdownRenderer(
            poster_lookup=poster_lookup,
            staged_mp4_map=staged_mp4_map,
            staged_poster_map=staged_poster_map,
        )
        body_html = renderer.render_blocks(rewritten_md, record_toc=True)
        if sp.slug == "loop-flywheel-retro":
            body_html = body_html.replace('<div class="table-wrap">', '<div class="table-wrap table-flywheel">')
        _EVERGREEN_NOTE_BANNERS: Dict[str, str] = {
            "north-vs-south-audit": "Historical engineering note recorded during Loop 37 while investigating map spawn symmetry.",
            "mirror-brain-audit": "Historical engineering note recorded during Loop 34 evaluating replay prediction accuracy.",
            "pro-macro-design": "Historical design note recorded during early economy tuning against Grandmaster replay curves.",
            "belief-engine-plan": "Historical design note recorded after our first live ladder runs, detailing how scouting sightings trigger detection and defense.",
            "prod-audit": "Historical match review recorded during Loop 36 covering our first 80 public AI Arena games.",
            "3d-rendering-proof": "Engineering note documenting how we capture H.264 MP4 match and combat drill videos directly from the StarCraft II engine.",
        }
        m_foren = re.match(r"^loop(\d+)-forensics$", sp.slug)
        if m_foren:
            lnum_f = m_foren.group(1)
            banner = (
                '<div class="callout callout-note">'
                '<div class="callout-label">Note</div>'
                f'<div class="callout-body"><p>Internal engineering notes and task breakdown recorded during Loop {lnum_f}.</p></div>'
                "</div>\n"
            )
            body_html = banner + body_html
        elif sp.slug in _EVERGREEN_NOTE_BANNERS:
            calm_h1 = f"<h1>{html.escape(sp.title)}</h1>"
            note_banner = (
                '\n<div class="callout callout-note">'
                '<div class="callout-label">Note</div>'
                f'<div class="callout-body"><p>{html.escape(_EVERGREEN_NOTE_BANNERS[sp.slug])}</p></div>'
                "</div>\n"
            )
            if re.search(r"<h1\b[^>]*>.*?</h1>", body_html, flags=re.S):
                body_html = re.sub(
                    r"<h1\b[^>]*>.*?</h1>",
                    lambda _m: calm_h1 + note_banner,
                    body_html,
                    count=1,
                    flags=re.S,
                )
            else:
                body_html = calm_h1 + note_banner + body_html
        full_html = render_page_shell(
            repo_slug=repo_slug,
            title=sp.title,
            active_slug=sp.slug,
            body_html=body_html,
            toc=renderer.toc if len(renderer.toc) >= 3 else None,
            include_mermaid=renderer.has_mermaid,
            built_utc=built_utc,
        )
        _assert_no_local_leaks(full_html, sp.out_file)
        (out_dir / sp.out_file).write_text(full_html, encoding="utf-8")
        page_stats[sp.slug] = {
            "out_file": sp.out_file,
            "img_count": renderer.img_count,
            "video_count": renderer.video_count,
            "html_kb": (out_dir / sp.out_file).stat().st_size / 1024.0,
        }
        print(
            f"  ✓ Built {sp.out_file:28s} ({page_stats[sp.slug]['html_kb']:6.1f} KB, "
            f"{renderer.img_count:3d} clips, {renderer.video_count:2d} videos, mermaid={renderer.has_mermaid})"
        )

    # Build interactive video-gallery.html
    gallery_html = build_video_gallery_page(
        repo_slug=repo_slug,
        gallery_items=clean_gallery_items,
        built_utc=built_utc,
    )
    _assert_no_local_leaks(gallery_html, "video-gallery.html")
    (out_dir / "video-gallery.html").write_text(gallery_html, encoding="utf-8")
    print(
        f"  ✓ Built {'video-gallery.html':28s} "
        f"({(out_dir / 'video-gallery.html').stat().st_size / 1024.0:6.1f} KB, "
        f"{len(clean_gallery_items)} gallery items, "
        f"{sum(1 for x in clean_gallery_items if x.get('playable_mp4'))} iOS-playable MP4s)"
    )

    # Load shared dashboard & rich telemetry once for BOTH index.html (Current State) and history.html (History & Fixes)
    shared_dash = load_dashboard_telemetry(sqlite_path)
    shared_rich = load_rich_report_telemetry(
        sqlite_path=sqlite_path, repo_dir=repo_dir, brain_dir=brain_dir
    )

    # Build Current State index.html
    index_html = build_index_page(
        repo_slug=repo_slug,
        repo_dir=repo_dir,
        brain_dir=brain_dir,
        sqlite_path=sqlite_path,
        published_specs=published_specs,
        gallery_items=clean_gallery_items,
        media_by_tag=media_by_tag,
        staged_mp4_map=staged_mp4_map,
        staged_poster_map=staged_poster_map,
        built_utc=built_utc,
        dash=shared_dash,
        rich=shared_rich,
    )
    _assert_no_local_leaks(index_html, "index.html")
    (out_dir / "index.html").write_text(index_html, encoding="utf-8")
    print(f"  ✓ Built {'index.html':28s} ({(out_dir / 'index.html').stat().st_size / 1024.0:6.1f} KB, Current State)")

    # Build History & Fixes history.html
    history_html = build_history_page(
        repo_slug=repo_slug,
        repo_dir=repo_dir,
        brain_dir=brain_dir,
        sqlite_path=sqlite_path,
        published_specs=published_specs,
        media_by_tag=media_by_tag,
        built_utc=built_utc,
        dash=shared_dash,
        rich=shared_rich,
    )
    _assert_no_local_leaks(history_html, "history.html")
    (out_dir / "history.html").write_text(history_html, encoding="utf-8")
    print(f"  ✓ Built {'history.html':28s} ({(out_dir / 'history.html').stat().st_size / 1024.0:6.1f} KB, History & Fixes)")

    site_bytes = sum(p.stat().st_size for p in out_dir.rglob("*") if p.is_file())
    print(
        f"[Step B] Static site built in {out_dir} "
        f"({len(published_specs) + 3} HTML pages, {site_bytes / (1024 * 1024):.1f} MB total, 0 path leaks)."
    )
    return page_stats


def push_gh_pages_and_enable(repo_slug: str, out_dir: Path) -> str:
    """Safely push isolated orphan gh-pages repo from out_dir (NEVER touching main repo)."""
    remote_url = f"https://github.com/{repo_slug}.git"
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"

    run_cmd(["git", "init", "-b", "gh-pages"], cwd=out_dir, env=env)
    run_cmd(["git", "config", "user.name", "mothman-bot-publisher"], cwd=out_dir, env=env)
    run_cmd(
        ["git", "config", "user.email", "mothman-bot@users.noreply.github.com"],
        cwd=out_dir,
        env=env,
    )
    run_cmd(
        ["git", "config", "credential.helper", "!gh auth git-credential"],
        cwd=out_dir,
        env=env,
    )
    run_cmd(["git", "add", "-A"], cwd=out_dir, env=env)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    run_cmd(
        ["git", "commit", "-m", f"Publish Mothman visual & audit reports ({stamp})"],
        cwd=out_dir,
        env=env,
    )
    pushed_sha = run_cmd(["git", "rev-parse", "HEAD"], cwd=out_dir, env=env).stdout.strip()
    run_cmd(
        ["git", "-c", "http.postBuffer=524288000", "push", "--force", remote_url, "HEAD:gh-pages"],
        cwd=out_dir,
        env=env,
    )
    print(f"[Step C] Pushed orphan gh-pages ({pushed_sha[:8]}) to {remote_url}.")

    check_pages = run_cmd(["gh", "api", f"repos/{repo_slug}/pages"], check=False)
    if check_pages.returncode != 0:
        enable_proc = run_cmd(
            [
                "gh",
                "api",
                "-X",
                "POST",
                f"repos/{repo_slug}/pages",
                "-f",
                "source[branch]=gh-pages",
                "-f",
                "source[path]=/",
            ],
            check=False,
        )
        if (
            enable_proc.returncode != 0
            and "409" not in enable_proc.stderr
            and "already enabled" not in enable_proc.stderr.lower()
        ):
            raise RuntimeError(f"Failed enabling GitHub Pages: {enable_proc.stderr}")
        print("[Step C] GitHub Pages enabled (source: gh-pages /).")
        check_pages = run_cmd(["gh", "api", f"repos/{repo_slug}/pages"], check=True)
    else:
        print("[Step C] GitHub Pages already enabled.")

    pages_info = json.loads(check_pages.stdout)
    site_url = pages_info.get(
        "html_url", f"https://{repo_slug.split('/')[0]}.github.io/{repo_slug.split('/')[1]}/"
    )
    if not site_url.endswith("/"):
        site_url += "/"

    print(f"[Step C] Waiting for GitHub Pages build at {site_url}...")
    deadline = time.time() + 120.0
    last_status = "unknown"
    while time.time() < deadline:
        bp = run_cmd(["gh", "api", f"repos/{repo_slug}/pages/builds/latest"], check=False)
        if bp.returncode == 0:
            bdata = json.loads(bp.stdout)
            last_status = str(bdata.get("status", "unknown"))
            built_sha = str(bdata.get("commit", ""))
            if last_status == "built" and built_sha == pushed_sha:
                code = http_head_status(site_url)
                if code == 200:
                    print(f"[Step C] Pages build {pushed_sha[:8]} status=built & live HTTP {code}!")
                    break
            elif last_status == "errored" and built_sha == pushed_sha:
                raise RuntimeError(f"GitHub Pages build errored: {bdata.get('error')}")
        time.sleep(4.0)
    else:
        print(f"[Step C] Note: Pages build poll reached timeout (last status={last_status}).")

    return site_url


def http_head_status(url: str) -> int:
    req = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": "mothman-pages-check/1.0"}
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return int(resp.status)
    except urllib.error.HTTPError as e:
        if e.code == 405:
            req2 = urllib.request.Request(
                url,
                method="GET",
                headers={"User-Agent": "mothman-pages-check/1.0", "Range": "bytes=0-0"},
            )
            with urllib.request.urlopen(req2, timeout=20) as r2:
                return int(r2.status)
        return int(e.code)
    except Exception:
        return 0


def verify_live_site(
    site_url: str,
    media_by_tag: Dict[str, Dict[str, str]],
    published_specs: List[ReportSpec],
    out_dir: Optional[Path] = None,
) -> None:
    check_urls = [
        site_url,
        site_url + "history.html",
        site_url + "loops-29-plus.html",
        site_url + "video-gallery.html",
        site_url + "loops-19-28.html",
        site_url + "prod-audit.html",
        site_url + "mirror-brain-audit.html",
    ]
    if any(sp.slug == "loop-flywheel-retro" for sp in published_specs):
        check_urls.append(site_url + "loop-flywheel-retro.html")

    # Verify same-origin iOS-playable MP4 serves as Content-Type: video/mp4 (NOT attachment/octet-stream!)
    staged_mp4_url = None
    if out_dir and (out_dir / "media").is_dir():
        mp4s = sorted((out_dir / "media").glob("*.mp4"))
        if mp4s:
            staged_mp4_url = site_url + "media/" + mp4s[0].name
            check_urls.append(staged_mp4_url)

    sample_webp = None
    sample_png = None
    for tag in sorted(media_by_tag.keys(), reverse=True):
        for fname, u in media_by_tag[tag].items():
            low = fname.lower()
            if not sample_webp and low.endswith(".webp"):
                sample_webp = u
            if not sample_png and low.endswith(".png"):
                sample_png = u
            if sample_webp and sample_png:
                break
        if sample_webp and sample_png:
            break
    for u in (sample_webp, sample_png):
        if u:
            check_urls.append(u)

    print("[Verify] Live HTTP checks:")
    failures = []
    for u in check_urls:
        status = http_head_status(u)
        ok = status in (200, 206)
        mark = "✓" if ok else "✗"
        print(f"  {mark} HTTP {status} — {u}")
        if not ok:
            failures.append((status, u))

    if staged_mp4_url:
        req = urllib.request.Request(
            staged_mp4_url, method="HEAD", headers={"User-Agent": "mothman-pages-check/1.0"}
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            ct = (resp.headers.get("Content-Type") or "").lower()
            cd = (resp.headers.get("Content-Disposition") or "").lower()
            ar = (resp.headers.get("Accept-Ranges") or "").lower()
            print(
                f"  ✓ iOS MP4 Headers — Content-Type={ct!r}, Accept-Ranges={ar!r}, Content-Disposition={cd!r}"
            )
            if "video/mp4" not in ct or "attachment" in cd:
                failures.append((f"bad-mp4-headers:{ct}/{cd}", staged_mp4_url))

    if failures:
        raise RuntimeError(f"Live verification failed for {len(failures)} URL(s): {failures}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Publish Mothman SC2 Bot reports to GitHub Pages.")
    ap.add_argument("--repo-slug", default=DEFAULT_REPO_SLUG)
    ap.add_argument("--repo-dir", type=Path, default=DEFAULT_REPO_DIR)
    ap.add_argument("--brain-dir", type=Path, default=DEFAULT_BRAIN_DIR)
    ap.add_argument("--analyzer-brain-dir", type=Path, default=DEFAULT_ANALYZER_DIR)
    ap.add_argument("--sqlite-db", type=Path, default=DEFAULT_SQLITE_DB)
    ap.add_argument("--cache-map", type=Path, default=DEFAULT_CACHE_MAP)
    ap.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    ap.add_argument("--skip-media", action="store_true", help="Skip GitHub Release uploads (use cache)")
    ap.add_argument("--skip-push", action="store_true", help="Build locally without pushing gh-pages")
    ap.add_argument(
        "--include-unreferenced",
        action="store_true",
        help="Upload all campaign_media/iter* files even if not referenced in reports",
    )
    ap.add_argument("--max-workers", type=int, default=4, help="Parallel release workers")
    args = ap.parse_args()

    specs = build_report_specs(args.brain_dir, args.analyzer_brain_dir)
    resolved: List[Tuple[ReportSpec, Path]] = []
    for sp in specs:
        p = resolve_spec_path(sp)
        if p is None:
            if sp.required:
                raise FileNotFoundError(f"Required report not found: {sp.source_candidates}")
            print(f"  [skip optional] {sp.slug} not found")
            continue
        resolved.append((sp, p))

    tag_files, abs_to_asset = discover_media_to_upload(
        resolved, args.brain_dir, include_unreferenced=args.include_unreferenced
    )
    media_by_tag = sync_release_media(
        repo_slug=args.repo_slug,
        tag_files=tag_files,
        cache_map_path=args.cache_map,
        skip_media=args.skip_media,
        max_workers=args.max_workers,
    )

    build_static_site(
        repo_slug=args.repo_slug,
        repo_dir=args.repo_dir,
        brain_dir=args.brain_dir,
        analyzer_dir=args.analyzer_brain_dir,
        sqlite_path=args.sqlite_db,
        out_dir=args.out_dir,
        resolved_reports=resolved,
        media_by_tag=media_by_tag,
        abs_to_asset=abs_to_asset,
    )

    if args.skip_push:
        print("[Done] --skip-push set; local build verified clean.")
        return 0

    site_url = push_gh_pages_and_enable(args.repo_slug, args.out_dir)
    verify_live_site(site_url, media_by_tag, [sp for sp, _ in resolved], out_dir=args.out_dir)
    print(f"\nLIVE SITE VERIFIED: {site_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
