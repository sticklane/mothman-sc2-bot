#!/usr/bin/env python3
"""
Builds AI Arena ladder-ready .zip archives for Mothman and its 4 race variants:
  - ladder/Mothman.zip
  - ladder/Mothman-Z.zip (Zerg)
  - ladder/Mothman-T.zip (Terran)
  - ladder/Mothman-P.zip (Protoss)
  - ladder/Mothman-R.zip (Random)

AI Arena Container Compatibility (`aiarena/arenaclient-bot-base`, Debian 12 Bookworm x86_64):
  1. Precompiles all `#lang sc-bot` and Racket runtime modules (`sc-bot/`, `compiler/`,
     `lib/`, `sim/`, `bots/`) to `.zo` bytecode via `(require compiler/cm)`.
  2. Bundles the self-contained Debian 12 x86_64 portable Racket runtime
     (`racket_runtime.tar.xz`, ~8.3 MB) so the AI Arena Docker container (which does not
     have `racket` pre-installed) executes the real Racket `#lang sc-bot` brain natively.
  3. Includes `sim/racket_sexp_fallback.py` as a cross-OS fallback for non-Linux hosts.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import zipfile
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
LADDER_DIR = ROOT_DIR / "ladder"
CACHE_DIR = LADDER_DIR / ".cache"
RACKET_ROOT = Path("/home/antigravity/toolchains/racket")
RACKET_BIN = RACKET_ROOT / "bin" / "racket"

INCLUDE_DIRS = [
    "sc-bot",
    "compiler",
    "lib",
    "sim",
    "bots",
    "ffi",
]

INCLUDE_TOP_FILES = [
    "run.py",
    "main.rkt",
    "info.rkt",
]

VARIANTS = [
    ("Mothman", "Random", "bots/Mothman.rkt"),
    ("Mothman-Z", "Zerg", "bots/Mothman-Z.rkt"),
    ("Mothman-T", "Terran", "bots/Mothman-T.rkt"),
    ("Mothman-P", "Protoss", "bots/Mothman-P.rkt"),
    ("Mothman-R", "Random", "bots/Mothman-R.rkt"),
]


def precompile_racket_zo() -> bool:
    """Precompile all .rkt modules to .zo bytecode for instant startup in AI Arena."""
    if not RACKET_BIN.exists():
        return False
    targets = [
        "main.rkt",
        "sim/racket_sc2_ipc_bot.rkt",
        "bots/Mothman.rkt",
        "bots/Mothman-Z.rkt",
        "bots/Mothman-T.rkt",
        "bots/Mothman-P.rkt",
        "bots/Mothman-R.rkt",
    ]
    existing = [t for t in targets if (ROOT_DIR / t).exists()]
    rkt_list = " ".join(f'"{t}"' for t in existing)
    expr = f"(require compiler/cm) (for-each managed-compile-zo (list {rkt_list}))"
    try:
        subprocess.run(
            [str(RACKET_BIN), "-e", expr],
            cwd=str(ROOT_DIR),
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except Exception:
        return False


def ensure_portable_racket_archive() -> Path | None:
    """
    Build or reuse cached `ladder/.cache/racket_runtime.tar.xz` (~8.3 MB) containing
    `racket_runtime/bin/racket` + the exact precompiled `.zo`/`.rktd` files needed by
    `sim/racket_sc2_ipc_bot.rkt` on Debian 12 Bookworm x86_64 (`aiarena-docker-base`).
    """
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    archive_path = CACHE_DIR / "racket_runtime.tar.xz"
    if archive_path.exists() and archive_path.stat().st_size > 1_000_000:
        return archive_path

    if not RACKET_BIN.exists() or not shutil.which("strace"):
        return None

    obs = (
        "(frame-state #:frame 224 #:race zerg #:minerals 300 #:gas 100 "
        "#:supply-used 18 #:supply-cap 22 #:supply-left 4 #:pending-supply 0 "
        "#:start-pos (16.0 16.0) #:enemy-base (48.0 48.0) "
        "#:my-units ((1 drone 16.0 16.0 40 0)) "
        "#:my-buildings ((10 hatchery 16.0 16.0 1.00 1.00 #f)) "
        "#:enemy-units () #:enemy-buildings () #:active-effects ())\n(quit)\n"
    )
    opened_files: set[Path] = set()
    for race in ("zerg", "terran", "protoss", "random"):
        proc = subprocess.run(
            [
                "strace",
                "-e",
                "trace=openat",
                str(RACKET_BIN),
                "sim/racket_sc2_ipc_bot.rkt",
                "--bot",
                "bots/Mothman-R.rkt",
                "--race",
                race,
                "--posture",
                "balanced-opening",
            ],
            input=obs,
            text=True,
            capture_output=True,
            cwd=str(ROOT_DIR),
        )
        for m in re.finditer(r'"(/home/antigravity/toolchains/racket/[^"]+)"', proc.stderr):
            fp = Path(m.group(1)).resolve()
            if fp.is_file() and str(fp).startswith(str(RACKET_ROOT)):
                opened_files.add(fp)

    if not opened_files:
        return None

    tmp_archive = CACHE_DIR / "racket_runtime.tar.xz.tmp"
    with tarfile.open(tmp_archive, "w:xz", preset=6) as tf:
        for fp in sorted(opened_files):
            rel = fp.relative_to(RACKET_ROOT).as_posix()
            if rel.startswith("collects/sc-bot"):
                continue
            tf.add(fp, arcname=f"racket_runtime/{rel}")
        # Also include sc-bot collection inside racket_runtime/collects/sc-bot
        sc_bot_dir = ROOT_DIR / "sc-bot"
        if sc_bot_dir.exists():
            for root, _dirs, files in os.walk(sc_bot_dir):
                for fname in sorted(files):
                    full_p = Path(root) / fname
                    rel_p = full_p.relative_to(ROOT_DIR).as_posix()
                    tf.add(full_p, arcname=f"racket_runtime/collects/{rel_p}")

    tmp_archive.replace(archive_path)
    return archive_path


def compile_cpplinux_binary(bot_name: str) -> Path | None:
    """
    Compile `ladder/cpplinux_launcher.cpp` into a stripped Linux x86_64 ELF binary
    for AI Arena `cpplinux` (`BinaryCpp`) mode.
    """
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cpp_src = LADDER_DIR / "cpplinux_launcher.cpp"
    out_bin = CACHE_DIR / f"{bot_name}_elf"
    cxx = shutil.which("g++") or shutil.which("clang++")
    if not cpp_src.exists() or not cxx:
        return None
    try:
        subprocess.run(
            [
                cxx,
                "-O2",
                "-s",
                "-std=c++17",
                f'-DBOT_VARIANT_NAME="{bot_name}"',
                str(cpp_src),
                "-o",
                str(out_bin),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        os.chmod(out_bin, 0o755)
        return out_bin
    except Exception:
        return None


def build_variant_zip(
    bot_name: str,
    bot_race: str,
    bot_path: str,
    portable_racket_archive: Path | None = None,
) -> dict:
    LADDER_DIR.mkdir(parents=True, exist_ok=True)
    zip_path = LADDER_DIR / f"{bot_name}.zip"

    variant_config = {
        "BotName": bot_name,
        "BotRace": bot_race,
        "BotPath": bot_path,
    }

    elf_bin = compile_cpplinux_binary(bot_name)

    files_added = 0
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        # 1. Write variant-specific config.json at root of zip
        zf.writestr("config.json", json.dumps(variant_config, indent=2))
        files_added += 1

        # 2. Write native Linux x86_64 ELF binary `<BotName>` at root of zip for AI Arena `cpplinux` mode
        if elf_bin is not None and elf_bin.exists():
            zi = zipfile.ZipInfo(bot_name)
            zi.compress_type = zipfile.ZIP_DEFLATED
            # rwxr-xr-x (0o100755) in upper 16 bits of external_attr
            zi.external_attr = 0o100755 << 16
            zf.writestr(zi, elf_bin.read_bytes())
            files_added += 1

        # 3. Seed initial ./data/mirror_mind_opponents.json for AI Arena persistent bot_data
        zf.writestr(
            "data/mirror_mind_opponents.json",
            json.dumps({"bot_name": bot_name, "opponents": {}}, indent=2),
        )
        files_added += 1

        # 4. Add top-level files (run.py, main.rkt, info.rkt)
        for top_file in INCLUDE_TOP_FILES:
            p = ROOT_DIR / top_file
            if p.exists():
                zf.write(p, arcname=top_file)
                files_added += 1

        # 5. Add bundled portable Racket runtime archive (ZIP_STORED since already .tar.xz)
        if portable_racket_archive is not None and portable_racket_archive.exists():
            zf.write(
                portable_racket_archive,
                arcname="racket_runtime.tar.xz",
                compress_type=zipfile.ZIP_STORED,
            )
            files_added += 1

        # 6. Add directories (including precompiled compiled/*.zo)
        for dname in INCLUDE_DIRS:
            dpath = ROOT_DIR / dname
            if not dpath.exists():
                continue
            for root, _dirs, files in os.walk(dpath):
                if "__pycache__" in root or ".git" in root:
                    continue
                for fname in sorted(files):
                    if fname.endswith((".pyc", ".o")):
                        continue
                    full_p = Path(root) / fname
                    rel_p = full_p.relative_to(ROOT_DIR).as_posix()
                    zf.write(full_p, arcname=rel_p)
                    files_added += 1

    raw_bytes = zip_path.read_bytes()
    size_bytes = len(raw_bytes)
    sha256_hex = hashlib.sha256(raw_bytes).hexdigest()
    md5_hex = hashlib.md5(raw_bytes).hexdigest()
    return {
        "bot_name": bot_name,
        "race": bot_race,
        "bot_path": bot_path,
        "zip_path": str(zip_path),
        "files_added": files_added,
        "size_bytes": size_bytes,
        "size_mb": round(size_bytes / (1024 * 1024), 2),
        "sha256": sha256_hex,
        "md5": md5_hex,
        "cpplinux_binary_included": elf_bin is not None and elf_bin.exists(),
        "bundled_portable_racket": portable_racket_archive is not None and portable_racket_archive.exists(),
    }


def main():
    parser = argparse.ArgumentParser(description="Build AI Arena zip packages for Mothman")
    parser.add_argument("--all-races", action="store_true", help="Build all 4 race-specific zips plus base Mothman.zip")
    parser.add_argument("--variant", type=str, default=None, help="Build specific variant only")
    parser.add_argument("--no-portable-racket", action="store_true", help="Omit bundled racket_runtime.tar.xz")
    args = parser.parse_args()

    zo_ok = precompile_racket_zo()
    portable_archive = None if args.no_portable_racket else ensure_portable_racket_archive()

    targets = VARIANTS
    if args.variant:
        targets = [v for v in VARIANTS if v[0] == args.variant]
        if not targets:
            targets = [(args.variant, "Random", f"bots/{args.variant}.rkt")]

    built = []
    for bot_name, bot_race, bot_path in targets:
        built.append(build_variant_zip(bot_name, bot_race, bot_path, portable_archive))

    race_zips = [b for b in built if b["bot_name"] in ("Mothman-Z", "Mothman-T", "Mothman-P", "Mothman-R")]
    summary = {
        "status": "AI_ARENA_MULTI_RACE_ZIPS_BUILT_OK",
        "precompiled_zo": zo_ok,
        "bundled_portable_racket": portable_archive is not None and portable_archive.exists(),
        "variants_built": len(race_zips) if args.all_races else len(built),
        "total_archives": len(built),
        "packages": built,
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
