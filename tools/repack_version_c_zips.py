#!/usr/bin/env python3
"""Zero-bloat Version C ("C is for Cheese") BotZip repacker (`tools/repack_version_c_zips.py`).

Repacks existing standalone ELF archives `ladder/Mothman-{Z,T,P,X}.zip` into
`/tmp/vc_zips/Mothman-{ZC,TC,PC,XC}.zip` (outside the repository so no extra
~36 MB zips are ever committed) by rewriting only:
  1. Root executable filename: `Mothman-{Z,T,P,X}` -> `Mothman-{ZC,TC,PC,XC}`
  2. `config.json` & `bot_config.json`: `"BotName"`, `"CheeseMode": true`, `"CheeseProfile"`
  3. `run.py`: adds the Version C executable name to the fallback launcher tuple
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SRC_DIR = REPO_ROOT / "ladder"
DEFAULT_OUT_DIR = Path("/tmp/vc_zips")

RACE_TO_NAMES: dict[str, tuple[str, str]] = {
    "Z": ("Mothman-Z", "Mothman-ZC"),
    "T": ("Mothman-T", "Mothman-TC"),
    "P": ("Mothman-P", "Mothman-PC"),
    "X": ("Mothman-X", "Mothman-XC"),
}


def repack_version_c_zip(
    src_zip: Path,
    base_name: str,
    vc_name: str,
    out_zip: Path,
    cheese_profile: str = "auto",
) -> Path:
    """Repack a Main Mothman BotZip into a Version C Cheese BotZip."""
    src_zip = Path(src_zip)
    out_zip = Path(out_zip)
    if not src_zip.is_file():
        raise FileNotFoundError(f"Source BotZip not found: {src_zip}")
    out_zip.parent.mkdir(parents=True, exist_ok=True)

    found_exe = False
    with zipfile.ZipFile(src_zip, "r") as zin, zipfile.ZipFile(
        out_zip, "w", compression=zipfile.ZIP_DEFLATED
    ) as zout:
        for info in zin.infolist():
            data = zin.read(info.filename)
            new_name = vc_name if info.filename == base_name else info.filename
            if info.filename == base_name:
                found_exe = True
            if new_name in ("config.json", "bot_config.json"):
                cfg = json.loads(data.decode("utf-8"))
                cfg["BotName"] = vc_name
                cfg["CheeseMode"] = True
                cfg["CheeseProfile"] = cheese_profile
                data = (json.dumps(cfg, indent=2) + "\n").encode("utf-8")
            elif new_name == "run.py":
                txt = data.decode("utf-8")
                old_tuple = '("Mothman", "Mothman-X", "Mothman-Z", "Mothman-T", "Mothman-P", "Mothman-R")'
                if old_tuple in txt:
                    txt = txt.replace(
                        old_tuple,
                        f'("{vc_name}", "Mothman", "Mothman-X", "Mothman-Z", "Mothman-T", "Mothman-P", "Mothman-R")',
                    )
                data = txt.encode("utf-8")

            zi = zipfile.ZipInfo(new_name, date_time=info.date_time)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.create_system = 3
            zi.external_attr = info.external_attr
            zout.writestr(zi, data)

    if not found_exe:
        raise RuntimeError(f"Source zip {src_zip} did not contain expected root executable '{base_name}'")
    return out_zip


def verify_repacked_zip_dry_run(out_zip: Path, vc_name: str, timeout_sec: int = 30) -> dict[str, Any]:
    """Extract `out_zip` to a temp dir and verify `[vc_name, '--dry-run']` prints DRY_RUN_OK."""
    with tempfile.TemporaryDirectory(prefix=f"vc_dryrun_{vc_name}_") as td:
        with zipfile.ZipFile(out_zip, "r") as zf:
            for info in zf.infolist():
                zf.extract(info, td)
                mode = (info.external_attr >> 16) & 0o777
                if mode:
                    os.chmod(os.path.join(td, info.filename), mode)
        exe = os.path.join(td, vc_name)
        if not os.path.isfile(exe):
            raise RuntimeError(f"Repacked zip {out_zip} missing root executable '{vc_name}'")
        res = subprocess.run([exe, "--dry-run"], cwd=td, capture_output=True, text=True, timeout=timeout_sec)
        if res.returncode != 0 or "DRY_RUN_OK" not in res.stdout:
            raise RuntimeError(
                f"Dry-run failed for {vc_name} ({out_zip}): rc={res.returncode} "
                f"stdout={res.stdout[:300]!r} stderr={res.stderr[:300]!r}"
            )
        parsed: dict[str, Any] = {"bot_name": vc_name, "stdout": res.stdout.strip()}
        for line in res.stdout.splitlines():
            s = line.strip()
            if s.startswith("{") and s.endswith("}"):
                try:
                    parsed["json"] = json.loads(s)
                    break
                except Exception:
                    pass
        return parsed


def parse_races(raw: str) -> list[str]:
    out: list[str] = []
    for tok in (raw or "").split(","):
        k = tok.strip().upper()
        if not k:
            continue
        if k == "R":
            k = "X"
        if k not in RACE_TO_NAMES:
            raise ValueError(f"Unsupported race code {tok!r}; expected subset of Z,T,P,X")
        if k not in out:
            out.append(k)
    if not out:
        raise ValueError("No races specified")
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Repack Mothman-{Z,T,P,X}.zip into Version C Mothman-{ZC,TC,PC,XC}.zip")
    parser.add_argument("--src-dir", type=Path, default=DEFAULT_SRC_DIR,
                        help=f"Directory containing source Mothman-{{Z,T,P,X}}.zip (default: {DEFAULT_SRC_DIR})")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR,
                        help=f"Output directory for Version C zips (default: {DEFAULT_OUT_DIR}; kept outside repo)")
    parser.add_argument("--races", default="Z,T,P,X",
                        help="Comma-separated race codes to repack (default: Z,T,P,X)")
    parser.add_argument("--cheese-profile", default="auto",
                        help="CheeseProfile value stamped into config.json (default: auto)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Extract each repacked zip and run `<vc_exe> --dry-run` to verify DRY_RUN_OK")
    args = parser.parse_args(argv)

    races = parse_races(args.races)
    out_dir = args.out_dir.resolve()
    src_dir = args.src_dir.resolve()

    for rc in races:
        base_name, vc_name = RACE_TO_NAMES[rc]
        src_zip = src_dir / f"{base_name}.zip"
        out_zip = out_dir / f"{vc_name}.zip"
        repack_version_c_zip(src_zip, base_name, vc_name, out_zip, cheese_profile=args.cheese_profile)
        size_mb = out_zip.stat().st_size / (1024 * 1024)
        msg = f"[VC-REPACK] {vc_name}.zip <- {src_zip.name} ({size_mb:.2f} MB, profile={args.cheese_profile}) -> {out_zip}"
        if args.dry_run:
            info = verify_repacked_zip_dry_run(out_zip, vc_name)
            msg += f" | DRY_RUN_OK"
            if "json" in info:
                j = info["json"]
                msg += f" (cheese_mode={j.get('cheese_mode')}, cheese_profile={j.get('cheese_profile')})"
        print(msg, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
