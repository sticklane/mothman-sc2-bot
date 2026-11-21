#!/usr/bin/env python3
"""Publish Mothman SC2 Bot visual campaign & forensic reports to GitHub Pages
using per-iteration GitHub Releases as a 3D WebP/PNG media CDN.

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
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

DEFAULT_REPO_SLUG = "sticklane/mothman-sc2-bot"
DEFAULT_REPO_DIR = Path("/home/sjaconette/repos/mothman-sc2-bot")
DEFAULT_BRAIN_DIR = Path(
    "/home/sjaconette/.gemini/antigravity/brain/d28d22f4-2d13-41e2-9b7b-32757f58523b"
)
DEFAULT_ANALYZER_DIR = Path(
    "/home/sjaconette/.gemini/antigravity/brain/eb240772-dbd0-4a1b-8238-2de323cd12a8"
)
DEFAULT_CACHE_MAP = Path("/home/sjaconette/sc2-local-arena/gh_pages_media_map.json")
DEFAULT_OUT_DIR = Path("/tmp/mothman-gh-pages-site")


@dataclass(frozen=True)
class ReportSpec:
    slug: str
    out_file: str
    title: str
    short_title: str
    category: str
    badge: str
    summary: str
    source_candidates: Tuple[Path, ...]
    required: bool = True


def build_report_specs(brain_dir: Path, analyzer_dir: Path) -> List[ReportSpec]:
    return [
        ReportSpec(
            slug="loops-29-plus",
            out_file="loops-29-plus.html",
            title="Loops 29–36+ Real-3D Visual Campaign Report (Phase 2)",
            short_title="Loops 29–36+",
            category="Visual Campaign Reports",
            badge="LIVE PHASE 2",
            summary=(
                "Living real-SC2 3D visual campaign report covering Honest 960-Loop Arena 2.1, "
                "Full-Match Self-Play, Ship-Gate H2H vs Shipped BotZips, Unseen-12 Anti-Overfitting, "
                "and Live AI Arena Competition #38 deployments (Loops 29–36+)."
            ),
            source_candidates=(brain_dir / "loops_29_plus_visual_campaign_report.md",),
            required=True,
        ),
        ReportSpec(
            slug="loops-19-28",
            out_file="loops-19-28.html",
            title="Loops 19–28 Real-3D Visual Campaign Report (Phase 1 Archive)",
            short_title="Loops 19–28",
            category="Visual Campaign Reports",
            badge="PHASE 1 COMPLETE",
            summary=(
                "Complete 10-loop Phase 1 real-SC2 3D visual campaign archive from Loop 19 through "
                "the 54-match Loop 28 Grand Finale shipped live to AI Arena Competition #38."
            ),
            source_candidates=(brain_dir / "loops_19_28_visual_campaign_report.md",),
            required=True,
        ),
        ReportSpec(
            slug="3d-rendering-proof",
            out_file="3d-rendering-proof.html",
            title="Real SC2 3D Rendering Proof (Host Radeon OpenGL/EGL)",
            short_title="3D Render Proof",
            category="Visual Campaign Reports",
            badge="ENGINE PROOF",
            summary=(
                "Technical proof of real StarCraft II (SC2_x64 Base75689) headless 3D battlefield "
                "capture via Radeon OpenGL/EGL (Mesa 25.0.7) with crisp animated WebP and PNG keyframes."
            ),
            source_candidates=(brain_dir / "real_sc2_3d_rendering_proof.md",),
            required=True,
        ),
        ReportSpec(
            slug="prod-audit",
            out_file="prod-audit.html",
            title="Live Production AI Arena Forensic Audit (Run 44840087005)",
            short_title="Prod Ladder Audit",
            category="Forensic & Empirical Audits",
            badge="80 PROD MATCHES",
            summary=(
                "Deep forensic audit of 80 live AI Arena Competition #38 ladder matches across "
                "deployed builds (bf1043b7 → L28 73c70041 → L34 1d211c83), matchup cliffs, "
                "mutually-exclusive loss taxonomy, and prod-vs-local coverage gaps."
            ),
            source_candidates=(
                brain_dir / "prod_aiarena_run44840087005_audit.md",
                analyzer_dir / "prod_aiarena_run44840087005_audit.md",
            ),
            required=True,
        ),
        ReportSpec(
            slug="mirror-brain-audit",
            out_file="mirror-brain-audit.html",
            title="Empirical Audit of Both Mirror Brains (Strategic & Tactical)",
            short_title="Mirror-Brain Audit",
            category="Forensic & Empirical Audits",
            badge="30 REPLAYS + 36 ARENA",
            summary=(
                "Code + empirical replay audit of Strategic Mirror-Mind (mirror-mind-predictor.rkt) "
                "and Tactical Mirror Brain (arena-minimax.rkt) — exposing the anti-depth curve, "
                "defend-All-In base bug, T/P tbrain bypass, and (take 3) order-flip chaos."
            ),
            source_candidates=(
                brain_dir / "mirror_brain_empirical_audit.md",
                analyzer_dir / "mirror_brain_empirical_audit.md",
            ),
            required=True,
        ),
        ReportSpec(
            slug="north-vs-south-audit",
            out_file="north-vs-south-audit.html",
            title="North-vs-South Spawn-Position Cliff Audit (1,914 Replays)",
            short_title="Spawn-Bias Audit",
            category="Forensic & Empirical Audits",
            badge="1,914 REPLAYS",
            summary=(
                "SQLite statistical + code audit of North-vs-South spawn bias across 1,914 replays, "
                "proving the LeyLines NE fix in Loop 34 and isolating remaining hardcoded (+X,±Y) "
                "Depot/Pylon/Spine directional bugs for Loop 37."
            ),
            source_candidates=(
                analyzer_dir / "north_vs_south_spawn_audit.md",
                brain_dir / "north_vs_south_spawn_audit.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="loop36-forensics",
            out_file="loop36-forensics.html",
            title="Loop 36 Forensics (90/90 Matches) & Loop 37 Top-3 Blueprint",
            short_title="L36 Forensics",
            category="Forensic & Empirical Audits",
            badge="LOOP 37 SPEC",
            summary=(
                "Deep forensic breakdown of Loop 36's 90-match ship-gate run isolating the "
                "bot-runtime.rkt:19776 Siege Tank starvation bug, ZvT mobile AA/Baneling gaps, "
                "and merged Loop 37 4-corner symmetry + 40-scenario Arena blueprint."
            ),
            source_candidates=(
                analyzer_dir / "loop36_forensics_loop37_blueprint.md",
                brain_dir / "loop36_forensics_loop37_blueprint.md",
            ),
            required=False,
        ),
        ReportSpec(
            slug="belief-engine-plan",
            out_file="belief-engine-plan.html",
            title="Post-Deploy Loss Forensics & Belief Engine Architecture Plan",
            short_title="Belief Engine Plan",
            category="Architecture & Design",
            badge="ARCHITECTURE",
            summary=(
                "Foundational post-deploy loss forensics and Opponent-World-Model / Belief Engine "
                "design driving Mothman's fog-of-war inference, scout reactivity, and threat guards."
            ),
            source_candidates=(
                brain_dir / "post_deploy_loss_forensics_and_belief_engine_plan.md",
            ),
            required=True,
        ),
        ReportSpec(
            slug="pro-macro-design",
            out_file="pro-macro-design.html",
            title="Pro Macro Prioritization Analysis & Design",
            short_title="Pro Macro Design",
            category="Architecture & Design",
            badge="ARCHITECTURE",
            summary=(
                "Analysis of pro SC2 replay macro checkpoints and design of Mothman's utility-based "
                "Priority Macro Brain (lib/priority-macro-brain.rkt) with zero-starvation guarantees."
            ),
            source_candidates=(
                brain_dir / "pro_macro_prioritization_analysis_and_design.md",
            ),
            required=True,
        ),
        ReportSpec(
            slug="phase-reports",
            out_file="phase-reports.html",
            title="Complete Autonomous Campaign Phase-by-Phase Telemetry Log",
            short_title="Phase Telemetry Log",
            category="Campaign Logs",
            badge="FULL LOG",
            summary=(
                "Chronological, append-only engineering & benchmark telemetry log across every "
                "autonomous iteration loop, verification gate, Tactics Arena sweep, and live deploy."
            ),
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
    # GitHub Releases normalizes spaces and special chars into '.'
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


def discover_media_to_upload(
    resolved_reports: List[Tuple[ReportSpec, Path]],
    brain_dir: Path,
    include_unreferenced: bool = False,
) -> Dict[str, List[Path]]:
    """Map release_tag -> sorted list of local media Paths."""
    tag_files: Dict[str, Dict[str, Path]] = {}

    def add_file(tag: str, p: Path) -> None:
        if p.is_file() and p.stat().st_size > 0:
            tag_files.setdefault(tag, {})[p.name] = p

    # 1. Scan every referenced image & media link across all published reports.
    img_re = re.compile(r"!\[[^\]]*\]\(([^)]+)\)")
    file_link_re = re.compile(r"(?<!!)\[[^\]]*\]\(file://([^)#]+)(?:#[^)]+)?\)")
    cm_pat = re.compile(r"/campaign_media/(iter\d+)/([^/\s)]+)$")

    for _, md_path in resolved_reports:
        txt = md_path.read_text(encoding="utf-8", errors="replace")
        candidates = img_re.findall(txt) + file_link_re.findall(txt)
        for raw in candidates:
            clean = raw.strip()
            if clean.startswith("file://"):
                clean = clean[len("file://") :]
            if not clean.lower().endswith((".webp", ".png", ".jpg", ".jpeg", ".gif", ".svg")):
                continue
            p = Path(clean)
            if not p.is_file():
                continue
            m = cm_pat.search(clean)
            if m:
                iter_name = m.group(1)
                add_file(f"media-{iter_name}", p)
            else:
                add_file("media-proof", p)

    # 2. Optionally include ALL campaign_media/iter* files (even unreferenced ones).
    cm_root = brain_dir / "campaign_media"
    if include_unreferenced and cm_root.is_dir():
        for iter_dir in sorted(cm_root.iterdir()):
            if iter_dir.is_dir() and re.fullmatch(r"iter\d+", iter_dir.name):
                tag = f"media-{iter_dir.name}"
                for f in sorted(iter_dir.iterdir()):
                    if f.is_file() and f.suffix.lower() in (".webp", ".png", ".jpg", ".jpeg", ".gif"):
                        add_file(tag, f)

    # Sort tags newest-first (media-iter36 -> media-iter19, then media-proof).
    def tag_sort_key(tag: str) -> Tuple[int, int, str]:
        m = re.fullmatch(r"media-iter(\d+)", tag)
        if m:
            return (0, -int(m.group(1)), tag)
        return (1, 0, tag)

    ordered: Dict[str, List[Path]] = {}
    for tag in sorted(tag_files.keys(), key=tag_sort_key):
        ordered[tag] = sorted(tag_files[tag].values(), key=lambda x: x.name)
    return ordered


def fetch_release_assets(repo_slug: str, tag: str) -> Optional[Dict[str, str]]:
    """Return {asset_name: browser_download_url} if release exists, else None."""
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
    files: List[Path],
    batch_size: int = 12,
) -> Tuple[str, Dict[str, str], int]:
    """Ensure GitHub Release exists, upload missing assets, return exact {orig_name: url}."""
    existing = fetch_release_assets(repo_slug, tag)
    if existing is None:
        m = re.fullmatch(r"media-iter(\d+)", tag)
        if m:
            loop_num = m.group(1)
            title = f"Campaign 3D Media — Loop {loop_num}"
            notes = (
                f"Real StarCraft II 3D animated WebP and Peak-Clash PNG clips for "
                f"Loop {loop_num} of the Mothman SC2 Bot Visual Campaign Report."
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
            # Maybe created concurrently or transient error
            existing = fetch_release_assets(repo_slug, tag)
            if existing is not None:
                break
            time.sleep(2.0 * (attempt + 1))
        else:
            raise RuntimeError(f"Failed creating release {tag}: {proc.stderr}")
        if existing is None:
            existing = fetch_release_assets(repo_slug, tag) or {}

    missing: List[Path] = []
    for p in files:
        norm = gh_asset_normalized_name(p.name)
        if p.name not in existing and norm not in existing:
            missing.append(p)

    uploaded_count = 0
    for i in range(0, len(missing), batch_size):
        batch = missing[i : i + batch_size]
        cmd = ["gh", "release", "upload", tag, "-R", repo_slug, "--clobber"] + [
            str(p) for p in batch
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

    # Refresh exact asset map from GitHub API so URLs match 100% verbatim.
    final_assets = fetch_release_assets(repo_slug, tag)
    if final_assets is None:
        raise RuntimeError(f"Could not inspect release {tag} after upload")

    resolved_map: Dict[str, str] = {}
    for p in files:
        url = final_assets.get(p.name) or final_assets.get(gh_asset_normalized_name(p.name))
        if not url:
            raise RuntimeError(f"Asset {p.name} missing from release {tag} after upload!")
        resolved_map[p.name] = url

    return tag, resolved_map, uploaded_count


def sync_release_media(
    repo_slug: str,
    tag_files: Dict[str, List[Path]],
    cache_map_path: Path,
    skip_media: bool,
    max_workers: int,
) -> Dict[str, Dict[str, str]]:
    """Return {tag: {orig_filename: browser_download_url}}."""
    cache_data: Dict[str, Dict[str, str]] = {}
    if cache_map_path.is_file():
        try:
            raw = json.loads(cache_map_path.read_text(encoding="utf-8"))
            cache_data = raw.get("by_tag", {})
        except Exception:
            cache_data = {}

    if skip_media:
        # Verify cache covers all required files; if anything missing, query GitHub read-only.
        for tag, files in tag_files.items():
            cached_tag = cache_data.get(tag, {})
            if any(p.name not in cached_tag for p in files):
                fetched = fetch_release_assets(repo_slug, tag)
                if fetched:
                    mapped = {}
                    for p in files:
                        u = fetched.get(p.name) or fetched.get(gh_asset_normalized_name(p.name))
                        if u:
                            mapped[p.name] = u
                    cache_data.setdefault(tag, {}).update(mapped)
        return cache_data

    total_files = sum(len(v) for v in tag_files.values())
    total_mb = sum(p.stat().st_size for v in tag_files.values() for p in v) / 1e6
    print(
        f"[Step A] Syncing {len(tag_files)} GitHub Releases "
        f"({total_files} media assets, {total_mb:.1f} MB) with max_workers={max_workers}..."
    )

    t0 = time.time()
    total_uploaded = 0
    # Bound concurrency across releases to stay polite with GitHub API limits.
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, max_workers)) as pool:
        futs = {
            pool.submit(ensure_release_and_upload_tag, repo_slug, tag, files): (tag, len(files))
            for tag, files in tag_files.items()
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
            # Save incremental progress atomically
            save_media_cache(cache_map_path, repo_slug, cache_data, tag_files)

    elapsed = time.time() - t0
    print(
        f"[Step A] Complete in {elapsed:.1f}s — {total_files} assets ready "
        f"({total_uploaded} uploaded this run)."
    )
    return cache_data


def save_media_cache(
    cache_map_path: Path,
    repo_slug: str,
    by_tag: Dict[str, Dict[str, str]],
    tag_files: Dict[str, List[Path]],
) -> None:
    by_abs: Dict[str, str] = {}
    for tag, files in tag_files.items():
        tmap = by_tag.get(tag, {})
        for p in files:
            if p.name in tmap:
                by_abs[str(p)] = tmap[p.name]
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


# ---------------------------------------------------------------------------
# Path Rewriter (Guarantees ZERO /home/sjaconette/ or file:/// leaks)
# ---------------------------------------------------------------------------


def make_path_rewriter(
    repo_slug: str,
    repo_dir: Path,
    brain_dir: Path,
    analyzer_dir: Path,
    media_by_tag: Dict[str, Dict[str, str]],
    report_filename_to_html: Dict[str, str],
):
    repo_prefix = str(repo_dir).rstrip("/") + "/"
    cm_pat = re.compile(r"/campaign_media/(iter\d+)/([^/\s)]+)$")
    vis_rep_pat = re.compile(r"/scratch/loop/visual_report_(iter\d+)\.md$")

    def lookup_media_url(path_str: str) -> Optional[str]:
        m = cm_pat.search(path_str)
        if m:
            tag = f"media-{m.group(1)}"
            fname = m.group(2)
            return media_by_tag.get(tag, {}).get(fname)
        base = os.path.basename(path_str)
        return media_by_tag.get("media-proof", {}).get(base)

    def rewrite_target_url(raw_url: str) -> Optional[str]:
        """Rewrite a local path or file:// URL to a public web URL.
        Returns None if the target is a local-only artifact (convert to code label).
        """
        u = raw_url.strip()
        if u.startswith(("http://", "https://", "mailto:", "#")):
            return u

        is_file_scheme = u.startswith("file://")
        clean = u[len("file://") :] if is_file_scheme else u

        # Split optional fragment (#L123-L145 or #section)
        frag = ""
        if "#" in clean:
            clean, frag = clean.split("#", 1)
            frag = "#" + frag

        # 1. Media assets -> GitHub Release CDN
        if clean.lower().endswith((".webp", ".png", ".jpg", ".jpeg", ".gif", ".svg")):
            murl = lookup_media_url(clean)
            if murl:
                return murl

        # 2. Cross-report markdown links -> ./slug.html
        base = os.path.basename(clean)
        if base in report_filename_to_html:
            return f"./{report_filename_to_html[base]}{frag}"

        # 3. Per-loop visual_report_iterNN.md -> GitHub Release media-iterNN page
        mv = vis_rep_pat.search(clean)
        if mv:
            iter_name = mv.group(1)
            return f"https://github.com/{repo_slug}/releases/tag/media-{iter_name}"

        # 4. Repo source files -> GitHub blob/tree on main
        if clean.startswith(repo_prefix):
            rel = clean[len(repo_prefix) :]
            local_p = repo_dir / rel
            kind = "tree" if local_p.is_dir() else "blob"
            return f"https://github.com/{repo_slug}/{kind}/main/{rel}{frag}"

        # 5. Any other /home/sjaconette/... local-only path -> non-linkable
        if clean.startswith("/home/sjaconette"):
            return None

        return raw_url

    def rewrite_markdown_text(md_text: str) -> str:
        # A. Rewrite image embeds: ![alt](target)
        def repl_img(m: re.Match) -> str:
            alt, target = m.group(1), m.group(2)
            new_url = rewrite_target_url(target)
            if new_url is None:
                raise RuntimeError(f"Unresolved local image embed: {target}")
            return f"![{alt}]({new_url})"

        text = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", repl_img, md_text)

        # B. Rewrite standard markdown links: [label](target)
        def repl_link(m: re.Match) -> str:
            label, target = m.group(1), m.group(2)
            new_url = rewrite_target_url(target)
            if new_url is None:
                # Local-only scratch/DB/replay file -> render cleanly as inline code badge
                clean_label = label.strip("`")
                return f"`{clean_label}`"
            return f"[{label}]({new_url})"

        text = re.sub(r"(?<!!)\[([^\]]+)\]\(([^)]+)\)", repl_link, text)

        # C. Sanitize any bare /home/sjaconette/... prose/code mentions
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
# Pure-Python GFM + Carousel + Alerts + Tables + Mermaid -> HTML Renderer
# ---------------------------------------------------------------------------


class MarkdownRenderer:
    ALERT_META = {
        "NOTE": ("note", "Note", "ℹ"),
        "TIP": ("tip", "Tip", "✦"),
        "IMPORTANT": ("important", "Important", "★"),
        "WARNING": ("warning", "Warning", "▲"),
        "CAUTION": ("caution", "Caution", "✖"),
    }

    def __init__(self) -> None:
        self.toc: List[Tuple[int, str, str]] = []
        self._slug_counts: Dict[str, int] = {}
        self.has_mermaid: bool = False
        self.img_count: int = 0

    def _make_slug(self, raw_text: str) -> str:
        plain = re.sub(r"<[^>]+>", "", raw_text)
        plain = re.sub(r"[`*_~]", "", plain)
        slug = re.sub(r"[^a-zA-Z0-9\s-]", "", plain).strip().lower()
        slug = re.sub(r"[\s-]+", "-", slug) or "section"
        n = self._slug_counts.get(slug, 0)
        self._slug_counts[slug] = n + 1
        return slug if n == 0 else f"{slug}-{n}"

    def render_inline(self, text: str) -> str:
        # Protect inline code spans first so inner markdown chars aren't touched.
        code_slots: List[str] = []

        def save_code(m: re.Match) -> str:
            idx = len(code_slots)
            code_slots.append(f"<code>{html.escape(m.group(1))}</code>")
            return f"\x00CODE{idx}\x00"

        s = re.sub(r"`([^`\n]+)`", save_code, text)

        # Protect images ![alt](url)
        img_slots: List[str] = []

        def save_img(m: re.Match) -> str:
            idx = len(img_slots)
            alt = html.escape(m.group(1), quote=True)
            url = html.escape(m.group(2).strip(), quote=True)
            self.img_count += 1
            img_slots.append(
                f'<figure class="clip-figure">'
                f'<img src="{url}" alt="{alt}" loading="lazy" decoding="async" '
                f'class="clip-img" data-lightbox-src="{url}" data-lightbox-alt="{alt}" />'
                f'<figcaption>{alt}</figcaption>'
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
            # Restore code placeholders inside link labels
            inner_html = re.sub(
                r"\x00CODE(\d+)\x00", lambda cm: code_slots[int(cm.group(1))], inner_html
            )
            esc_url = html.escape(url, quote=True)
            ext_attr = (
                ' target="_blank" rel="noopener noreferrer"'
                if url.startswith(("http://", "https://"))
                else ""
            )
            cls = ' class="png-btn"' if url.lower().endswith(".png") else ""
            link_slots.append(f'<a href="{esc_url}"{cls}{ext_attr}>{inner_html}</a>')
            return f"\x00LINK{idx}\x00"

        s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", save_link, s)

        # Escape remaining HTML
        s = html.escape(s)

        # Auto-link bare https:// URLs
        s = re.sub(
            r"(?<!['\"=])(https?://[^\s<>()]+)",
            lambda m: (
                f'<a href="{m.group(1)}" target="_blank" rel="noopener noreferrer">'
                f"{m.group(1)}</a>"
            ),
            s,
        )

        # Bold, italic, strikethrough
        s = self._format_emphasis(s)

        # Restore slots
        s = re.sub(r"\x00LINK(\d+)\x00", lambda m: link_slots[int(m.group(1))], s)
        s = re.sub(r"\x00IMG(\d+)\x00", lambda m: img_slots[int(m.group(1))], s)
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
        # Split on unescaped '|'
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
            if not re.fullmatch(r":?-{2,}:?", c):
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
                    i += 1  # consume closing ````
                out.append(self._render_carousel("\n".join(body_lines)))
                continue

            # 2. Standard fenced code block (``` or ````)
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
                    lang_badge = f'<span class="code-lang">{html.escape(lang)}</span>' if lang else ""
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
                slug = self._make_slug(rendered_h)
                if record_toc and lvl in (2, 3):
                    plain_label = re.sub(r"<[^>]+>", "", rendered_h)
                    self.toc.append((lvl, slug, plain_label))
                out.append(
                    f'<h{lvl} id="{slug}">{rendered_h}'
                    f' <a class="anchor" href="#{slug}" aria-label="Link to section">¶</a></h{lvl}>'
                )
                i += 1
                continue

            # 5. Blockquote & GFM Alerts (> [!NOTE], > [!TIP], ...)
            if stripped.startswith(">"):
                q_lines: List[str] = []
                while i < n and lines[i].strip().startswith(">"):
                    q = re.sub(r"^\s*>\s?", "", lines[i])
                    q_lines.append(q)
                    i += 1
                first_m = re.match(r"^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$", q_lines[0].strip()) if q_lines else None
                if first_m:
                    kind = first_m.group(1)
                    cls, label, icon = self.ALERT_META[kind]
                    inner = self.render_blocks("\n".join(q_lines[1:]), record_toc=False)
                    out.append(
                        f'<div class="alert alert-{cls}">'
                        f'<div class="alert-title"><span class="alert-icon">{icon}</span> {label}</div>'
                        f'<div class="alert-body">{inner}</div></div>'
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

            # 7. Unordered / Ordered Lists (with nested indentation support)
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

            # 8. Raw HTML block pass-through (<details>, </details>, <summary>, etc.)
            if re.match(r"^</?(?:details|summary|div|br)\b", stripped, re.I):
                out.append(stripped)
                i += 1
                continue

            # 9. Paragraph
            p_lines: List[str] = []
            while i < n:
                cur = lines[i]
                st = cur.strip()
                if (
                    not st
                    or st.startswith(("````", "```", "~~~", ">", "#"))
                    or re.fullmatch(r"([-*_])(\s*\1){2,}", st)
                    or re.match(r"^\s*(?:[-*+]|\d+\.)\s+", cur)
                    or ("|" in cur and i + 1 < n and self._is_table_sep(lines[i + 1]) is not None)
                ):
                    break
                p_lines.append(cur.strip())
                i += 1
            if p_lines:
                rendered_p = self.render_inline(" ".join(p_lines))
                # If paragraph is solely a figure, don't wrap <figure> inside <p>
                if rendered_p.startswith('<figure class="clip-figure">') and rendered_p.endswith("</figure>"):
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
            parts.append(f'<th style="text-align:{aligns[idx]}">{self.render_inline(h_txt)}</th>')
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
        # Build nested <ul>/<ol> structure based on leading indent
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
                f'<div class="clip-card-badge">Clip {idx} / {total}</div>'
                f'<div class="clip-card-body">{slide_html}</div>'
                f"</article>"
            )
        return (
            f'<section class="clip-gallery" data-slide-count="{total}">'
            f'<div class="clip-gallery-grid">{"".join(cards)}</div>'
            f"</section>"
        )


# ---------------------------------------------------------------------------
# HTML Layout, Dark Theme CSS, Interactive Lightbox & Dashboard Builder
# ---------------------------------------------------------------------------

SITE_CSS = """
:root {
  --bg: #0b0f17;
  --surface: #121826;
  --surface-2: #182134;
  --border: #26324a;
  --text: #e6edf7;
  --muted: #93a4c0;
  --accent: #58a6ff;
  --accent-2: #7ee787;
  --warn: #f0b429;
  --danger: #f85149;
  --purple: #bc8cff;
  --code-bg: #0d1320;
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Inter, "Helvetica Neue", Arial, sans-serif;
  line-height: 1.62;
  font-size: 15px;
}
a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }

/* Top Navbar */
.topnav {
  position: sticky;
  top: 0;
  z-index: 100;
  background: rgba(11, 15, 23, 0.92);
  backdrop-filter: blur(10px);
  border-bottom: 1px solid var(--border);
}
.topnav-inner {
  max-width: 1440px;
  margin: 0 auto;
  padding: 0.65rem 1.25rem;
  display: flex;
  align-items: center;
  gap: 0.6rem;
  flex-wrap: wrap;
}
.brand {
  font-weight: 800;
  font-size: 1.02rem;
  color: #fff;
  letter-spacing: 0.02em;
  margin-right: 0.6rem;
  display: inline-flex;
  align-items: center;
  gap: 0.45rem;
}
.brand-dot {
  width: 9px; height: 9px; border-radius: 50%;
  background: var(--accent-2);
  box-shadow: 0 0 10px var(--accent-2);
}
.nav-links { display: flex; flex-wrap: wrap; gap: 0.35rem; align-items: center; flex: 1; }
.nav-link {
  padding: 0.3rem 0.65rem;
  border-radius: 6px;
  font-size: 0.86rem;
  color: var(--muted);
  transition: background 0.15s, color 0.15s;
}
.nav-link:hover { background: var(--surface-2); color: #fff; text-decoration: none; }
.nav-link.active { background: rgba(88,166,255,0.16); color: var(--accent); font-weight: 600; }
.nav-ext {
  padding: 0.3rem 0.7rem;
  border-radius: 6px;
  border: 1px solid var(--border);
  font-size: 0.82rem;
  color: var(--text);
}
.nav-ext:hover { border-color: var(--accent); text-decoration: none; }

/* Page Layout */
.layout {
  max-width: 1440px;
  margin: 0 auto;
  padding: 1.5rem 1.25rem 4rem;
  display: grid;
  grid-template-columns: 260px minmax(0, 1fr);
  gap: 1.75rem;
}
.layout.no-toc { grid-template-columns: minmax(0, 1fr); max-width: 1280px; }

/* Sidebar TOC */
.toc-sidebar {
  position: sticky;
  top: 66px;
  max-height: calc(100vh - 82px);
  overflow-y: auto;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 0.9rem 1rem;
  font-size: 0.82rem;
}
.toc-title {
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--muted);
  font-size: 0.73rem;
  margin-bottom: 0.55rem;
}
.toc-list { list-style: none; padding: 0; margin: 0; }
.toc-list li { margin: 0.28rem 0; }
.toc-list li.toc-h3 { padding-left: 0.8rem; font-size: 0.78rem; }
.toc-list a { color: var(--muted); display: block; padding: 0.12rem 0.25rem; border-radius: 4px; }
.toc-list a:hover { color: #fff; background: var(--surface-2); text-decoration: none; }

/* Article Typography */
.content { min-width: 0; }
h1, h2, h3, h4 { color: #f4f8ff; line-height: 1.3; scroll-margin-top: 74px; }
h1 { font-size: 1.85rem; margin-top: 0; border-bottom: 1px solid var(--border); padding-bottom: 0.55rem; }
h2 { font-size: 1.4rem; margin-top: 2.2rem; border-bottom: 1px solid var(--border); padding-bottom: 0.35rem; }
h3 { font-size: 1.12rem; margin-top: 1.5rem; color: #c9dfff; }
h4 { font-size: 0.98rem; margin: 0 0 0.55rem; color: #dceaff; }
.anchor { opacity: 0.22; font-size: 0.8em; margin-left: 0.25rem; }
h1:hover .anchor, h2:hover .anchor, h3:hover .anchor, h4:hover .anchor { opacity: 0.9; }
hr { border: 0; border-top: 1px solid var(--border); margin: 1.8rem 0; }
code {
  background: var(--code-bg);
  border: 1px solid rgba(255,255,255,0.07);
  padding: 0.1rem 0.35rem;
  border-radius: 4px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  font-size: 0.87em;
  color: #a5d6ff;
}
.code-block {
  position: relative;
  background: var(--code-bg);
  border: 1px solid var(--border);
  border-radius: 8px;
  margin: 1rem 0;
  overflow-x: auto;
}
.code-block pre { margin: 0; padding: 0.9rem 1rem; }
.code-block code { background: none; border: 0; padding: 0; color: #d8e6ff; font-size: 0.84rem; }
.code-lang {
  position: absolute; top: 6px; right: 10px;
  font-size: 0.7rem; text-transform: uppercase; color: var(--muted);
}
.mermaid-wrap {
  background: #0f1624;
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem;
  margin: 1rem 0;
  overflow-x: auto;
}

/* Alerts */
.alert {
  border-radius: 8px;
  border: 1px solid var(--border);
  border-left-width: 4px;
  padding: 0.8rem 1rem;
  margin: 1rem 0;
  background: var(--surface);
}
.alert-title { font-weight: 700; font-size: 0.9rem; margin-bottom: 0.35rem; display: flex; align-items: center; gap: 0.4rem; }
.alert-body > p:first-child { margin-top: 0; }
.alert-body > p:last-child { margin-bottom: 0; }
.alert-note { border-left-color: var(--accent); background: rgba(88,166,255,0.07); }
.alert-note .alert-title { color: var(--accent); }
.alert-tip { border-left-color: var(--accent-2); background: rgba(126,231,135,0.07); }
.alert-tip .alert-title { color: var(--accent-2); }
.alert-important { border-left-color: var(--purple); background: rgba(188,140,255,0.08); }
.alert-important .alert-title { color: var(--purple); }
.alert-warning { border-left-color: var(--warn); background: rgba(240,180,41,0.08); }
.alert-warning .alert-title { color: var(--warn); }
.alert-caution { border-left-color: var(--danger); background: rgba(248,81,73,0.08); }
.alert-caution .alert-title { color: var(--danger); }

blockquote {
  margin: 1rem 0;
  padding: 0.5rem 1rem;
  border-left: 3px solid var(--border);
  color: var(--muted);
  background: rgba(255,255,255,0.02);
  border-radius: 0 6px 6px 0;
}

/* Tables */
.table-wrap {
  width: 100%;
  overflow-x: auto;
  margin: 1rem 0;
  border: 1px solid var(--border);
  border-radius: 8px;
  background: var(--surface);
}
table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
th, td { padding: 0.5rem 0.68rem; border-bottom: 1px solid rgba(38,50,74,0.75); vertical-align: top; }
thead th { background: var(--surface-2); color: #f0f6ff; font-weight: 700; white-space: nowrap; }
tbody tr:nth-child(even) { background: rgba(255,255,255,0.018); }
tbody tr:hover { background: rgba(88,166,255,0.06); }

/* 3D Clip Gallery / Carousel Cards */
.clip-gallery { margin: 1.2rem 0 1.8rem; }
.clip-gallery-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1.15rem;
}
.clip-card {
  position: relative;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 0.95rem 1rem 0.85rem;
  display: flex;
  flex-direction: column;
  transition: border-color 0.15s, transform 0.15s;
}
.clip-card:hover { border-color: rgba(88,166,255,0.55); }
.clip-card-badge {
  position: absolute;
  top: 0.7rem;
  right: 0.85rem;
  font-size: 0.7rem;
  font-weight: 700;
  letter-spacing: 0.04em;
  color: var(--muted);
  background: var(--surface-2);
  border: 1px solid var(--border);
  border-radius: 999px;
  padding: 0.12rem 0.5rem;
}
.clip-card-body h4 { padding-right: 4.8rem; }
.clip-figure { margin: 0.5rem 0 0.7rem; }
.clip-img {
  width: 100%;
  height: auto;
  display: block;
  border-radius: 7px;
  border: 1px solid var(--border);
  background: #06080d;
  cursor: zoom-in;
  min-height: 160px;
}
.clip-figure figcaption {
  font-size: 0.76rem;
  color: var(--muted);
  margin-top: 0.35rem;
}
.png-btn {
  display: inline-block;
  padding: 0.12rem 0.45rem;
  border-radius: 5px;
  background: rgba(88,166,255,0.12);
  border: 1px solid rgba(88,166,255,0.3);
  font-size: 0.82rem;
}
.png-btn:hover { background: rgba(88,166,255,0.22); text-decoration: none; }

/* Landing Dashboard */
.hero {
  background: linear-gradient(135deg, #121c2f 0%, #0e1422 55%, #16182c 100%);
  border: 1px solid var(--border);
  border-radius: 14px;
  padding: 1.75rem 2rem;
  margin-bottom: 1.75rem;
}
.hero h1 { border: 0; padding: 0; margin: 0 0 0.5rem; font-size: 2rem; }
.hero-sub { color: var(--muted); margin: 0 0 1.2rem; max-width: 820px; }
.kpi-strip {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(175px, 1fr));
  gap: 0.8rem;
  margin-top: 1rem;
}
.kpi-box {
  background: rgba(11,15,23,0.65);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 0.75rem 0.95rem;
}
.kpi-val { font-size: 1.35rem; font-weight: 800; color: #fff; }
.kpi-val.green { color: var(--accent-2); }
.kpi-val.blue { color: var(--accent); }
.kpi-val.purple { color: var(--purple); }
.kpi-lbl { font-size: 0.75rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; }
.card-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
  gap: 1rem;
  margin: 0.85rem 0 1.75rem;
}
.report-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 11px;
  padding: 1.05rem 1.15rem;
  display: flex;
  flex-direction: column;
  gap: 0.45rem;
  color: var(--text);
  transition: border-color 0.15s, transform 0.15s, background 0.15s;
}
.report-card:hover {
  border-color: var(--accent);
  background: var(--surface-2);
  transform: translateY(-2px);
  text-decoration: none;
}
.report-card-top { display: flex; justify-content: space-between; align-items: center; gap: 0.5rem; }
.pill {
  font-size: 0.69rem; font-weight: 700; letter-spacing: 0.05em;
  padding: 0.14rem 0.5rem; border-radius: 999px;
  background: rgba(88,166,255,0.16); color: var(--accent);
  border: 1px solid rgba(88,166,255,0.3);
}
.pill.live { background: rgba(126,231,135,0.15); color: var(--accent-2); border-color: rgba(126,231,135,0.35); }
.report-card h3 { margin: 0.1rem 0; font-size: 1.02rem; color: #fff; }
.report-card p { margin: 0; font-size: 0.85rem; color: var(--muted); flex: 1; }
.report-card-meta { font-size: 0.76rem; color: #7f94b6; margin-top: 0.3rem; }

/* Lightbox Modal */
.lightbox {
  position: fixed; inset: 0; z-index: 1000;
  background: rgba(5, 8, 14, 0.93);
  display: none; align-items: center; justify-content: center; flex-direction: column;
  padding: 1.25rem;
}
.lightbox.open { display: flex; }
.lightbox img {
  max-width: 94vw; max-height: 82vh;
  border-radius: 8px; border: 1px solid var(--border);
  box-shadow: 0 20px 60px rgba(0,0,0,0.7);
}
.lightbox-caption { color: #dbe7fa; margin-top: 0.75rem; font-size: 0.9rem; text-align: center; max-width: 900px; }
.lightbox-controls {
  position: fixed; top: 1rem; right: 1.25rem; display: flex; gap: 0.5rem;
}
.lb-btn {
  background: var(--surface-2); color: #fff; border: 1px solid var(--border);
  border-radius: 8px; padding: 0.45rem 0.8rem; cursor: pointer; font-size: 0.9rem;
}
.lb-btn:hover { border-color: var(--accent); }

.footer {
  max-width: 1440px; margin: 0 auto; padding: 1.2rem 1.25rem 2.5rem;
  border-top: 1px solid var(--border); color: var(--muted); font-size: 0.8rem;
  display: flex; justify-content: space-between; flex-wrap: wrap; gap: 0.6rem;
}

@media (max-width: 1040px) {
  .layout { grid-template-columns: minmax(0, 1fr); }
  .toc-sidebar { position: static; max-height: none; }
}
@media (max-width: 780px) {
  .clip-gallery-grid { grid-template-columns: minmax(0, 1fr); }
  .hero { padding: 1.25rem; }
}
"""

LIGHTBOX_JS = """
<script>
(function() {
  const imgs = Array.from(document.querySelectorAll('img.clip-img'));
  if (!imgs.length) return;
  const lb = document.createElement('div');
  lb.className = 'lightbox';
  lb.innerHTML =
    '<div class="lightbox-controls">' +
      '<button class="lb-btn" id="lb-prev" title="Previous (Left Arrow)">← Prev</button>' +
      '<button class="lb-btn" id="lb-next" title="Next (Right Arrow)">Next →</button>' +
      '<a class="lb-btn" id="lb-raw" target="_blank" rel="noopener noreferrer">Open Raw ↗</a>' +
      '<button class="lb-btn" id="lb-close" title="Close (Esc)">✕ Close</button>' +
    '</div>' +
    '<img id="lb-img" alt="" />' +
    '<div class="lightbox-caption" id="lb-cap"></div>';
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
    lbCap.textContent = (cur + 1) + ' / ' + imgs.length + ' — ' + alt;
    lb.classList.add('open');
  }
  function close() { lb.classList.remove('open'); }
  imgs.forEach((im, idx) => im.addEventListener('click', () => show(idx)));
  document.getElementById('lb-prev').addEventListener('click', (e) => { e.stopPropagation(); show(cur - 1); });
  document.getElementById('lb-next').addEventListener('click', (e) => { e.stopPropagation(); show(cur + 1); });
  document.getElementById('lb-close').addEventListener('click', (e) => { e.stopPropagation(); close(); });
  lb.addEventListener('click', (e) => { if (e.target === lb) close(); });
  document.addEventListener('keydown', (e) => {
    if (!lb.classList.contains('open')) return;
    if (e.key === 'Escape') close();
    else if (e.key === 'ArrowRight') show(cur + 1);
    else if (e.key === 'ArrowLeft') show(cur - 1);
  });
})();
</script>
"""

MERMAID_JS = """
<script type="module">
  import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
  mermaid.initialize({ startOnLoad: true, theme: 'dark', securityLevel: 'loose' });
</script>
"""


def build_navbar(
    repo_slug: str, active_slug: str, published_specs: List[ReportSpec]
) -> str:
    nav_slugs = [
        ("index", "Dashboard", "./index.html"),
    ]
    preferred = [
        "loops-29-plus",
        "loops-19-28",
        "prod-audit",
        "mirror-brain-audit",
        "north-vs-south-audit",
        "phase-reports",
    ]
    spec_by_slug = {s.slug: s for s in published_specs}
    for sl in preferred:
        if sl in spec_by_slug:
            sp = spec_by_slug[sl]
            nav_slugs.append((sp.slug, sp.short_title, f"./{sp.out_file}"))

    links_html = []
    for sl, lbl, href in nav_slugs:
        cls = "nav-link active" if sl == active_slug else "nav-link"
        links_html.append(f'<a class="{cls}" href="{href}">{html.escape(lbl)}</a>')

    return (
        '<header class="topnav"><div class="topnav-inner">'
        '<a class="brand" href="./index.html"><span class="brand-dot"></span>Mothman SC2 Bot</a>'
        f'<nav class="nav-links">{"".join(links_html)}</nav>'
        f'<a class="nav-ext" href="https://github.com/{repo_slug}" target="_blank" rel="noopener noreferrer">GitHub ↗</a>'
        f'<a class="nav-ext" href="https://github.com/{repo_slug}/actions/workflows/deploy-aiarena.yml" target="_blank" rel="noopener noreferrer">AI Arena Deploys ↗</a>'
        "</div></header>"
    )


def render_page_shell(
    *,
    repo_slug: str,
    title: str,
    active_slug: str,
    published_specs: List[ReportSpec],
    body_html: str,
    toc: Optional[List[Tuple[int, str, str]]] = None,
    include_mermaid: bool = False,
    built_utc: str,
) -> str:
    nav = build_navbar(repo_slug, active_slug, published_specs)
    toc_html = ""
    layout_cls = "layout no-toc"
    if toc:
        layout_cls = "layout"
        items = []
        for lvl, slug, lbl in toc:
            cls = "toc-h3" if lvl >= 3 else "toc-h2"
            short = lbl if len(lbl) <= 64 else lbl[:61] + "…"
            items.append(
                f'<li class="{cls}"><a href="#{slug}">{html.escape(short)}</a></li>'
            )
        toc_html = (
            '<aside class="toc-sidebar">'
            '<div class="toc-title">On This Page</div>'
            f'<ul class="toc-list">{"".join(items)}</ul>'
            "</aside>"
        )

    mermaid_script = MERMAID_JS if include_mermaid else ""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{html.escape(title)} — Mothman SC2 Bot</title>
  <style>{SITE_CSS}</style>
</head>
<body>
{nav}
<div class="{layout_cls}">
  {toc_html}
  <main class="content">
    {body_html}
  </main>
</div>
<footer class="footer">
  <div>Mothman SC2 Bot — Autonomous Real-SC2 Visual Campaign &amp; Forensic Reports</div>
  <div>Published {html.escape(built_utc)} · 3D Media hosted on <a href="https://github.com/{repo_slug}/releases" target="_blank" rel="noopener noreferrer">GitHub Releases CDN</a></div>
</footer>
{LIGHTBOX_JS}
{mermaid_script}
</body>
</html>
"""


def build_index_page(
    *,
    repo_slug: str,
    repo_dir: Path,
    published_specs: List[ReportSpec],
    page_stats: Dict[str, Dict[str, object]],
    media_by_tag: Dict[str, Dict[str, str]],
    built_utc: str,
) -> str:
    total_assets = sum(len(v) for v in media_by_tag.values())
    total_releases = len(media_by_tag)
    total_embedded_clips = sum(int(s.get("img_count", 0)) for s in page_stats.values())

    # Parse loop_ledger.json for KPI progression table
    ledger_path = repo_dir / "tools/iteration-loop/loop_ledger.json"
    ledger_rows_html = ""
    latest_loop_id = "iter36_wave36_full"
    total_iters = 0
    if ledger_path.is_file():
        ld = json.loads(ledger_path.read_text(encoding="utf-8"))
        iters = ld.get("iterations", [])
        total_iters = len(iters)
        if iters:
            latest_loop_id = str(iters[-1].get("id", latest_loop_id))
        recent = list(reversed(iters[-14:]))
        rows = []
        for it in recent:
            it_id = html.escape(str(it.get("id", "")))
            rev = html.escape(str(it.get("rev", "")).split()[0] if it.get("rev") else "")
            clean_n = html.escape(str(it.get("clean_n", "")))
            rec_raw = str(it.get("record_clean", ""))
            # Keep concise record prefix before long parenthetical if huge
            rec_short = rec_raw if len(rec_raw) <= 88 else rec_raw[:85] + "…"
            tr = it.get("trade_agg")
            tr_s = f"{tr:.2f}x" if isinstance(tr, (int, float)) else "—"
            sb = it.get("sup_blk_pct")
            sb_s = f"{sb:.1f}%" if isinstance(sb, (int, float)) else "—"
            pka = it.get("pk_army_avg")
            pka_s = f"{pka:,.0f}" if isinstance(pka, (int, float)) else "—"
            gates_raw = str(it.get("promotion_gates_passed", ""))
            m_g = re.match(r"^(\d+/\d+\s+PASS)", gates_raw)
            gates_s = m_g.group(1) if m_g else (gates_raw[:32] + "…" if len(gates_raw) > 32 else gates_raw)
            # Extract media release link if iterNN exists
            m_it = re.match(r"(iter\d+)", str(it.get("id", "")))
            rel_cell = "—"
            if m_it and f"media-{m_it.group(1)}" in media_by_tag:
                tag = f"media-{m_it.group(1)}"
                rel_cell = (
                    f'<a href="https://github.com/{repo_slug}/releases/tag/{tag}" '
                    f'target="_blank" rel="noopener noreferrer">{tag} ↗</a>'
                )
            rows.append(
                f"<tr><td><strong>{it_id}</strong></td><td><code>{rev}</code></td>"
                f'<td style="text-align:right">{clean_n}</td>'
                f"<td>{html.escape(rec_short)}</td>"
                f'<td style="text-align:right"><strong>{tr_s}</strong></td>'
                f'<td style="text-align:right">{sb_s}</td>'
                f'<td style="text-align:right">{pka_s}</td>'
                f"<td>{html.escape(gates_s)}</td>"
                f"<td>{rel_cell}</td></tr>"
            )
        ledger_rows_html = (
            '<h2>Recent Autonomous Loop Progression (<code>loop_ledger.json</code>)</h2>'
            '<div class="table-wrap"><table><thead><tr>'
            '<th>Iteration</th><th>Rev</th><th style="text-align:right">N</th>'
            '<th>Clean Record</th><th style="text-align:right">Trade</th>'
            '<th style="text-align:right">SupBlk</th><th style="text-align:right">PkArmy</th>'
            "<th>Gates</th><th>3D Media</th>"
            f'</tr></thead><tbody>{"".join(rows)}</tbody></table></div>'
        )

    # Categorized report cards
    categories: List[str] = []
    for sp in published_specs:
        if sp.category not in categories:
            categories.append(sp.category)

    cards_sections: List[str] = []
    for cat in categories:
        cat_cards = []
        for sp in published_specs:
            if sp.category != cat:
                continue
            st = page_stats.get(sp.slug, {})
            ic = int(st.get("img_count", 0))
            kb = float(st.get("src_kb", 0.0))
            mtime = str(st.get("mtime", ""))
            pill_cls = "pill live" if "LIVE" in sp.badge else "pill"
            meta_bits = [f"{kb:.0f} KB Markdown"]
            if ic > 0:
                meta_bits.append(f"{ic} Real-3D Clips")
            if mtime:
                meta_bits.append(f"Updated {mtime}")
            cat_cards.append(
                f'<a class="report-card" href="./{sp.out_file}">'
                f'<div class="report-card-top"><span class="{pill_cls}">{html.escape(sp.badge)}</span>'
                f'<span style="font-size:0.75rem;color:var(--accent)">Read →</span></div>'
                f"<h3>{html.escape(sp.title)}</h3>"
                f"<p>{html.escape(sp.summary)}</p>"
                f'<div class="report-card-meta">{" · ".join(meta_bits)}</div>'
                f"</a>"
            )
        cards_sections.append(
            f"<h2>{html.escape(cat)}</h2>"
            f'<div class="card-grid">{"".join(cat_cards)}</div>'
        )

    body = f"""
<section class="hero">
  <h1>Mothman SC2 Bot — Autonomous Campaign Dashboard</h1>
  <p class="hero-sub">
    Real-3D StarCraft II visual campaign reports, live AI Arena Competition #38 ladder forensics,
    Honest 960-Loop Tactics Arena benchmarks, and empirical Mirror-Brain audits — published with
    lazy-loaded 3D WebP/PNG clips served from GitHub Releases CDN.
  </p>
  <div style="display:flex;gap:0.6rem;flex-wrap:wrap;">
    <a class="png-btn" href="./loops-29-plus.html" style="padding:0.42rem 0.9rem;font-weight:700;">▶ Open Phase 2 Visual Report (Loops 29–36+)</a>
    <a class="png-btn" href="./prod-audit.html" style="padding:0.42rem 0.9rem;">Live AI Arena Prod Audit</a>
    <a class="png-btn" href="./mirror-brain-audit.html" style="padding:0.42rem 0.9rem;">Mirror-Brain Empirical Audit</a>
    <a class="png-btn" href="https://github.com/{repo_slug}/releases" target="_blank" rel="noopener noreferrer" style="padding:0.42rem 0.9rem;">Browse All {total_releases} 3D Media Releases ↗</a>
  </div>
  <div class="kpi-strip">
    <div class="kpi-box"><div class="kpi-val green">{html.escape(latest_loop_id)}</div><div class="kpi-lbl">Latest Ledger Loop ({total_iters} Total)</div></div>
    <div class="kpi-box"><div class="kpi-val blue">{total_embedded_clips}</div><div class="kpi-lbl">Embedded Real-3D WebP Clips</div></div>
    <div class="kpi-box"><div class="kpi-val purple">{total_assets}</div><div class="kpi-lbl">CDN Assets Across {total_releases} Releases</div></div>
    <div class="kpi-box"><div class="kpi-val">{len(published_specs)}</div><div class="kpi-lbl">Published Campaign &amp; Audit Reports</div></div>
  </div>
</section>
{"".join(cards_sections)}
{ledger_rows_html}
"""
    return render_page_shell(
        repo_slug=repo_slug,
        title="Campaign Dashboard",
        active_slug="index",
        published_specs=published_specs,
        body_html=body,
        toc=None,
        include_mermaid=False,
        built_utc=built_utc,
    )


def build_static_site(
    *,
    repo_slug: str,
    repo_dir: Path,
    brain_dir: Path,
    analyzer_dir: Path,
    out_dir: Path,
    resolved_reports: List[Tuple[ReportSpec, Path]],
    media_by_tag: Dict[str, Dict[str, str]],
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

    rewrite_md = make_path_rewriter(
        repo_slug=repo_slug,
        repo_dir=repo_dir,
        brain_dir=brain_dir,
        analyzer_dir=analyzer_dir,
        media_by_tag=media_by_tag,
        report_filename_to_html=report_filename_to_html,
    )

    page_stats: Dict[str, Dict[str, object]] = {}
    for sp, src_path in resolved_reports:
        raw_md = src_path.read_text(encoding="utf-8")
        rewritten_md = rewrite_md(raw_md)
        renderer = MarkdownRenderer()
        body_html = renderer.render_blocks(rewritten_md, record_toc=True)
        full_html = render_page_shell(
            repo_slug=repo_slug,
            title=sp.title,
            active_slug=sp.slug,
            published_specs=published_specs,
            body_html=body_html,
            toc=renderer.toc if len(renderer.toc) >= 3 else None,
            include_mermaid=renderer.has_mermaid,
            built_utc=built_utc,
        )
        # Hard check: ZERO unrewritten local home paths or file:// links!
        if "/home/sjaconette/" in full_html or "file:///" in full_html:
            leaks = re.findall(r"(?:file://)?/home/sjaconette[^\s\"'<>]{0,80}", full_html)
            raise RuntimeError(
                f"Unrewritten local path leak in {sp.out_file}: {leaks[:5]}"
            )
        (out_dir / sp.out_file).write_text(full_html, encoding="utf-8")
        mtime_s = datetime.fromtimestamp(src_path.stat().st_mtime, tz=timezone.utc).strftime(
            "%Y-%m-%d"
        )
        page_stats[sp.slug] = {
            "out_file": sp.out_file,
            "img_count": renderer.img_count,
            "src_kb": src_path.stat().st_size / 1024.0,
            "html_kb": (out_dir / sp.out_file).stat().st_size / 1024.0,
            "mtime": mtime_s,
        }
        print(
            f"  ✓ Built {sp.out_file:28s} ({page_stats[sp.slug]['html_kb']:6.1f} KB, "
            f"{renderer.img_count:3d} lazy 3D clips, mermaid={renderer.has_mermaid})"
        )

    index_html = build_index_page(
        repo_slug=repo_slug,
        repo_dir=repo_dir,
        published_specs=published_specs,
        page_stats=page_stats,
        media_by_tag=media_by_tag,
        built_utc=built_utc,
    )
    if "/home/sjaconette/" in index_html or "file:///" in index_html:
        raise RuntimeError("Unrewritten local path leak in index.html!")
    (out_dir / "index.html").write_text(index_html, encoding="utf-8")

    site_bytes = sum(p.stat().st_size for p in out_dir.rglob("*") if p.is_file())
    print(
        f"[Step B] Static site built in {out_dir} "
        f"({len(published_specs) + 1} HTML pages, {site_bytes / 1024:.1f} KB total, 0 path leaks)."
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
    # Use gh's credential helper without ever printing or persisting tokens on disk.
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
    run_cmd(
        ["git", "push", "--force", remote_url, "HEAD:gh-pages"],
        cwd=out_dir,
        env=env,
    )
    print(f"[Step C] Pushed orphan gh-pages branch to {remote_url}.")

    # Ensure GitHub Pages is enabled on gh-pages root (idempotent; handles 409 race cleanly).
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
        if enable_proc.returncode != 0 and "409" not in enable_proc.stderr and "already enabled" not in enable_proc.stderr.lower():
            raise RuntimeError(f"Failed enabling GitHub Pages: {enable_proc.stderr}")
        print("[Step C] GitHub Pages enabled (source: gh-pages /).")
        check_pages = run_cmd(["gh", "api", f"repos/{repo_slug}/pages"], check=True)
    else:
        print("[Step C] GitHub Pages already enabled.")

    pages_info = json.loads(check_pages.stdout)
    site_url = pages_info.get("html_url", f"https://{repo_slug.split('/')[0]}.github.io/{repo_slug.split('/')[1]}/")
    if not site_url.endswith("/"):
        site_url += "/"

    # Poll latest Pages build briefly until built (max ~90s).
    print(f"[Step C] Waiting for GitHub Pages build at {site_url}...")
    deadline = time.time() + 120.0
    last_status = "unknown"
    while time.time() < deadline:
        bp = run_cmd(["gh", "api", f"repos/{repo_slug}/pages/builds/latest"], check=False)
        if bp.returncode == 0:
            bdata = json.loads(bp.stdout)
            last_status = str(bdata.get("status", "unknown"))
            if last_status == "built":
                # Also check HTTP 200 on live index
                code = http_head_status(site_url)
                if code == 200:
                    print(f"[Step C] Pages build status=built & live HTTP {code}!")
                    break
            elif last_status == "errored":
                raise RuntimeError(f"GitHub Pages build errored: {bdata.get('error')}")
        time.sleep(4.0)
    else:
        print(f"[Step C] Note: Pages build poll reached timeout (last status={last_status}).")

    return site_url


def http_head_status(url: str) -> int:
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "mothman-pages-check/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return int(resp.status)
    except urllib.error.HTTPError as e:
        if e.code == 405:
            # Fallback GET range 0-0
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


def verify_live_site(site_url: str, media_by_tag: Dict[str, Dict[str, str]]) -> None:
    check_urls = [
        site_url,
        site_url + "loops-29-plus.html",
        site_url + "loops-19-28.html",
        site_url + "prod-audit.html",
        site_url + "mirror-brain-audit.html",
    ]
    # Add sample .webp and .png release CDN URLs
    sample_webp = None
    sample_png = None
    for tag in sorted(media_by_tag.keys(), reverse=True):
        for fname, u in media_by_tag[tag].items():
            if not sample_webp and fname.endswith(".webp"):
                sample_webp = u
            if not sample_png and fname.endswith(".png"):
                sample_png = u
            if sample_webp and sample_png:
                break
        if sample_webp and sample_png:
            break
    if sample_webp:
        check_urls.append(sample_webp)
    if sample_png:
        check_urls.append(sample_png)

    print("[Verify] Live HTTP checks:")
    failures = []
    for u in check_urls:
        status = http_head_status(u)
        ok = status in (200, 206)
        mark = "✓" if ok else "✗"
        print(f"  {mark} HTTP {status} — {u}")
        if not ok:
            failures.append((status, u))
    if failures:
        raise RuntimeError(f"Live verification failed for {len(failures)} URL(s): {failures}")


def main() -> int:
    ap = argparse.ArgumentParser(description="Publish Mothman SC2 Bot reports to GitHub Pages.")
    ap.add_argument("--repo-slug", default=DEFAULT_REPO_SLUG)
    ap.add_argument("--repo-dir", type=Path, default=DEFAULT_REPO_DIR)
    ap.add_argument("--brain-dir", type=Path, default=DEFAULT_BRAIN_DIR)
    ap.add_argument("--analyzer-brain-dir", type=Path, default=DEFAULT_ANALYZER_DIR)
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

    tag_files = discover_media_to_upload(
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
        out_dir=args.out_dir,
        resolved_reports=resolved,
        media_by_tag=media_by_tag,
    )

    if args.skip_push:
        print("[Done] --skip-push set; local build verified clean.")
        return 0

    site_url = push_gh_pages_and_enable(args.repo_slug, args.out_dir)
    verify_live_site(site_url, media_by_tag)
    print(f"\n🚀 LIVE SITE VERIFIED: {site_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
