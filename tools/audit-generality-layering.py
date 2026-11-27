#!/usr/bin/env python3
"""Permanent Generality, Pro-Data & Clean-Layering Audit Gate (Loop 88+).

Fast (< 2s), stdlib-only automated gate run on `jj diff` and the repository tree
before Gate 1 on every iteration loop. Enforces six permanent architectural
invariants plus ABI & hygiene checks:

  1. GENERALITY_HITS = 0:
     Zero opponent bot names or map-specific names in executable production
     code (`lib/`, `sim/`, `bots/`), and zero newly added opponent/map hacks in
     the active diff (including comments outside `lib/build-orders/*.rkt`).
  2. HARDCODED_APM_TIERS = 0:
     Zero hardcoded static APM tier ceiling / percentage tables
     (`tier-headroom-floor`, `tier-token-floor`, static `0.78/0.76/0.74/0.90`
     or `390/450` ceiling literals) in `lib/sc2-protobuf-ws.rkt`.
  3. Pro-Data / Physics Backing Check (diff-level on `lib/**/*.rkt`):
     Flags newly added non-comment raw frame cutoffs (>= 672), mineral/gas bank
     cutoffs (>= 100), or static worker/supply caps (>= 16) outside canonical
     Pro-data / constants modules (`lib/plan/pro-curves.rkt`,
     `lib/sc2-game-constants.rkt`, `lib/build-orders/*.rkt`) unless derived
     from Pro curves / physics / single governor parameters (or annotated with
     `; pro-data:`, `; physics:`, or `; governor-param:`).
  4. Single-Authority Layering Ratchet (diff-level hard fail on `lib/**/*.rkt`):
     Hard FAIL on any newly added:
       - `#:bypass-escrow?` (outside Version C cheese code)
       - `*-ignores-*-escrow?` overrides
       - `*-post?` duplicate post-escrow override definitions in Brain
       - duplicate Runtime escrow predicates (`l2-non-combat-*`,
         `l2-holding-for-*`, `l2-can-spend-by-priority?`,
         `l2-saving-for-expansion-now?`, `l2-protoss-colossus-escrow-ok?`)
       - duplicate gas-pull valve outside `lib/plan/worker-saturation-policy.rkt`
         (`wd-gas-mode`, `terran-midgame-gas-pull-due?`, `gas-pull-to-zero-now?`)
       - ad-hoc Layer 3/4 hold booleans (`l34-.*hold?`, `l88-.*hold?`,
         `combat-suppress-attack?` definitions) outside
         `lib/tactics/operation-controller.rkt`.
     Also reports legacy deletion progress (how many legacy violations were
     removed in the diff).
  5. 7-Dim OWM End-to-End Wiring Check (full-tree across Layer 2 & Layer 4):
     Verifies all 7 calibrated OWM dimensions (bases, gases, workers,
     income/unaccounted bank, production/imminent supply, army/threat, upgrades)
     have >= 1 non-logging control-loop consumer across Layer 2 (`lib/plan/`,
     `lib/econ/`, `lib/priority-macro-brain.rkt`, `lib/bot-runtime.rkt`) and/or
     Layer 4 (`lib/tactics/`).
  6. Complexity & Deletion Budget + Hygiene & ABI:
     - Tracks LOC, `define` count, and `Loop/L##` patch comment count (total +
       net diff delta) on `lib/bot-runtime.rkt`, `lib/priority-macro-brain.rkt`,
       and `lib/sc2-protobuf-ws.rkt`.
     - Enforces `EM_DASH_HITS = 0` & `EN_DASH_HITS = 0` on added Racket/Python
       lines (excluding site copy generators), `STRAY_ZO = 0`, and exact ABI
       struct field arities (`live-bot-runtime=19`, `opponent-world-summary=35`,
       `bot-mind-log-snapshot=14`, `cheese-build-spec=15`).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


REPO_ROOT_DEFAULT = Path(__file__).resolve().parent.parent

# Canonical production Racket roots (exclude tests/ and tools/)
PROD_RKT_ROOTS = ("lib", "sim", "bots")

# Monoliths tracked for complexity & deletion budget
MONOLITH_PATHS = (
    "lib/bot-runtime.rkt",
    "lib/priority-macro-brain.rkt",
    "lib/sc2-protobuf-ws.rkt",
)

# Expected ABI struct field arities
EXPECTED_STRUCT_ARITIES: Dict[str, Tuple[str, int]] = {
    "live-bot-runtime": ("lib/bot-runtime.rkt", 19),
    "opponent-world-summary": ("lib/opponent-world-model.rkt", 35),
    "bot-mind-log-snapshot": ("lib/sc2-logging.rkt", 14),
    "cheese-build-spec": ("lib/build-orders/cheese.rkt", 15),
}

# Opponent bot names (distinctive tokens safe for full-code + diff-comment scans)
OPPONENT_BOT_TOKENS = (
    "12poolbot",
    "axefighter",
    "clicadinha",
    "creepy_strategies",
    "cryptbotrevival",
    "modbotnewbuilds",
    "mulebot",
    "polymorph",
    "queenbot",
    "rustynikolaj",
    "smoothbrain",
    "thessaloniki",
    "thssprtssbt",
    "veterran",
    "mini-puck",
    "monsterbot",
    "sc2ai_protoss",
    "sludgement2",
    "titania",
    "zig-reapers",
    "oberon",
    "onlyfans",
)

# Short/ambiguous bot handles checked only in executable string/symbol literals
AMBIGUOUS_BOT_TOKENS = (
    "norman",
    "puck",
)

# Map names (must never be hardcoded in production strategy/placement logic)
MAP_NAME_TOKENS = (
    "incorporeal",
    "leylines",
    "ley lines",
    "magannatha",
    "persephone",
    "pylonaie",
    "torchesaie",
    "ultralove",
    "aie_v",
)

OPPONENT_RE = re.compile(
    r"(?<![A-Za-z0-9_-])("
    + "|".join(re.escape(tok) for tok in OPPONENT_BOT_TOKENS)
    + r")(?![A-Za-z0-9_-])",
    re.IGNORECASE,
)

AMBIGUOUS_BOT_RE = re.compile(
    r"""(?:"|')("""
    + "|".join(re.escape(tok) for tok in AMBIGUOUS_BOT_TOKENS)
    + r""")(?:"|'|(?=\s|\)))""",
    re.IGNORECASE,
)

MAP_NAME_RE = re.compile(
    r"(?<![A-Za-z0-9_-])("
    + "|".join(re.escape(tok) for tok in MAP_NAME_TOKENS)
    + r")(?![A-Za-z0-9_-])",
    re.IGNORECASE,
)

# APM hardcoded tier patterns in lib/sc2-protobuf-ws.rkt
APM_HARDCODED_DEF_RE = re.compile(
    r"\(\s*define\s+\(\s*(tier-headroom-floor|tier-token-floor)\b"
)
APM_HARDCODED_CEILING_RE = re.compile(
    r"\b(tier-headroom-floor|tier-token-floor|p2-rolling-ceiling|p1-rolling-ceiling)\b"
)
APM_STATIC_RATIO_RE = re.compile(
    r"\(\s*\*\s+(?:hard-cap|eff-cap|cap-apm|rolling-cap)\s+(?:0\.74|0\.76|0\.78|0\.90)\b"
)
APM_STATIC_LITERAL_RE = re.compile(
    r"(?:tier-ceiling|rolling-ceiling|p2-cap|p1-cap)\s+(?:390(?:\.0)?|450(?:\.0)?)\b"
)

# Layering ratchet patterns (hard FAIL when newly added to lib/**/*.rkt)
RATCHET_RULES: Tuple[Tuple[str, re.Pattern[str], Tuple[str, ...]], ...] = (
    (
        "bypass-escrow-flag",
        re.compile(r"#:bypass-escrow\?\s+#t"),
        ("lib/build-orders/cheese.rkt",),
    ),
    (
        "ignores-escrow-override",
        re.compile(r"\(\s*define\s+\(?[A-Za-z0-9_-]*-ignores-[A-Za-z0-9_-]*escrow\?"),
        (),
    ),
    (
        "post-escrow-override",
        re.compile(r"\(\s*define\s+\(?[A-Za-z0-9_-]+-post\?(?:\s|\))"),
        (),
    ),
    (
        "duplicate-runtime-escrow",
        re.compile(
            r"\(\s*define\s+\(\s*(?:l2-non-combat-|l2-holding-for-|l2-can-spend-by-priority\?|"
            r"l2-saving-for-expansion-now\?|l2-protoss-colossus-escrow-ok\?|l2-terran-need-factory1-now\?)"
        ),
        (),
    ),
    (
        "duplicate-gas-valve",
        re.compile(
            r"\b(?:wd-gas-mode|terran-midgame-gas-pull-due\?|gas-pull-to-zero-now\?|"
            r"terran-midgame-gas-resat-hold\?)\b"
        ),
        ("lib/plan/worker-saturation-policy.rkt",),
    ),
    (
        "adhoc-l34-hold-boolean",
        re.compile(
            r"\(\s*define\s+\(?(?:l34-[A-Za-z0-9_-]*hold[A-Za-z0-9_-]*\?|"
            r"l8[89]-[A-Za-z0-9_-]*hold[A-Za-z0-9_-]*\?|"
            r"combat-suppress-attack\?)(?:\s|\))"
        ),
        ("lib/tactics/operation-controller.rkt",),
    ),
)

# Pro-data / physics backing patterns for newly added lines in lib/**/*.rkt
PRO_DATA_EXEMPT_PREFIXES = (
    "lib/plan/pro-curves.rkt",
    "lib/sc2-game-constants.rkt",
    "lib/build-orders/",
)
PRO_DATA_ANNOTATION_RE = re.compile(
    r";\s*(?:pro-data|physics|governor-param|sc2-constant|pro-curve)\b",
    re.IGNORECASE,
)
RAW_FRAME_CUTOFF_RE = re.compile(
    r"\(\s*(?:fl)?(?:>=|<=|>|<)\s+(?:frame|cur-frame|game-loop|cur-loop)\s+(\d+(?:\.\d+)?)\s*\)"
)
RAW_BANK_CUTOFF_RE = re.compile(
    r"\(\s*(?:fl)?(?:>=|<=|>|<)\s+"
    r"(?:cur-min|cur-gas|min-bank|gas-bank|minerals|gas|\(l2-ctx-minerals\s+ctx\)|\(l2-ctx-gas\s+ctx\))\s+"
    r"(\d+(?:\.\d+)?)\s*\)"
)
RAW_WORKER_SUPPLY_CAP_RE = re.compile(
    r"\(\s*(?:fl)?(?:>=|<=|>|<)\s+"
    r"(?:workers|worker-cnt|w-cnt|supply-used|cur-workers|live-workers)\s+"
    r"(\d+(?:\.\d+)?)\s*\)"
)

# 7 calibrated OWM dimensions & their non-logging control-loop consumer tokens
OWM_DIMENSIONS: Tuple[Tuple[str, Tuple[str, ...]], ...] = (
    (
        "dim1_bases",
        (
            "opponent-world-summary-confirmed-bases",
            "opponent-world-summary-happy-expected-bases",
            "owm-estimated-enemy-bases",
            "owm-control-signals-est-bases",
            "owm-control-signals-happy-bases",
            "enemy-confirmed-bases",
        ),
    ),
    (
        "dim2_gases",
        (
            "opponent-world-summary-confirmed-geysers",
            "owm-estimated-enemy-gases",
            "owm-enemy-1base-double-gas?",
            "owm-control-signals-est-gases",
            "owm-control-signals-confirmed-geysers",
        ),
    ),
    (
        "dim3_workers",
        (
            "opponent-world-summary-estimated-workers",
            "opponent-world-summary-workers-killed",
            "owm-control-signals-est-workers",
            "owm-control-signals-workers-killed",
            "est-enemy-workers",
        ),
    ),
    (
        "dim4_income_and_unaccounted",
        (
            "owm-estimated-min-rate",
            "owm-estimated-gas-rate",
            "opponent-world-summary-unaccounted-minerals",
            "opponent-world-summary-unaccounted-gas",
            "opponent-world-summary-hidden-gas-tech-risk?",
            "owm-control-signals-est-min-rate",
            "owm-control-signals-est-gas-rate",
            "owm-control-signals-unaccounted-min",
            "owm-control-signals-unaccounted-gas",
            "owm-control-signals-hidden-gas-tech-risk?",
        ),
    ),
    (
        "dim5_production_and_imminent_supply",
        (
            "opponent-world-summary-production-facility-count",
            "opponent-world-summary-imminent-reachable-supply",
            "opponent-world-summary-known-bldg-counts",
            "owm-home-prod-count",
            "owm-control-signals-prod-facility-count",
            "owm-control-signals-imminent-supply",
        ),
    ),
    (
        "dim6_army_and_threat",
        (
            "opponent-world-summary-believed-total-army-value",
            "opponent-world-summary-believed-total-army-supply",
            "opponent-world-summary-known-unit-counts",
            "opponent-world-summary-enemy-siege-or-turtle-count",
            "opponent-world-summary-requires-anti-air?",
            "opponent-world-summary-requires-detection?",
            "owm-control-signals-believed-army-val",
            "owm-control-signals-believed-army-sup",
        ),
    ),
    (
        "dim7_upgrades",
        (
            "opponent-world-model-observed-upgrades-set",
            "collect-owm-upgrade-symbols",
            "infer-owm-telemetry-upgrades",
            "mirror-enemy-upgrade-advantage",
            "enemy-upgrade-advantage",
            "owm-upgrade-delta",
            "owm-enemy-upgrade-delta",
            "owm-control-signals-upgrade-delta",
            "enemy-upgrades-believed",
            "owm-believed-upgrades",
        ),
    ),
)

OWM_LOGGING_LINE_RE = re.compile(
    r"\b(?:fprintf|printf|format|log-bot-mind|SCBOT_OWM|SCBOT_STATE|bot-mind-log-snapshot|"
    r"write-string|owm-log-|emit-owm-telemetry)\b"
)

DEFINE_LINE_RE = re.compile(r"^\s*\(define(?:-[A-Za-z0-9_-]+)?[\s(]")
LOOP_COMMENT_RE = re.compile(r"\b(?:Loop\s*\d+[A-Z]?|L\d{2}[A-Z]?|W\d{1,2}-P\d)\b")

# Prose/code hygiene: files allowed to contain typographic en-dashes for site copy
EN_DASH_EXEMPT_FILES = (
    "tools/publish-gh-pages.py",
    "tools/site_report_sections.py",
    "tools/iteration-loop/CARBON_REPORT_GUIDE.md",
)


@dataclass
class DiffFileChange:
    path: str
    added: List[Tuple[int, str]] = field(default_factory=list)
    removed: List[Tuple[int, str]] = field(default_factory=list)


def strip_racket_comment(line: str) -> Tuple[str, str]:
    """Split a Racket source line into (code_part, comment_part) respecting strings."""
    if ";" not in line:
        return line, ""
    if '"' not in line:
        idx = line.find(";")
        return line[:idx], line[idx:]
    in_str = False
    escaped = False
    for idx, ch in enumerate(line):
        if escaped:
            escaped = False
            continue
        if in_str:
            if ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == ";":
            return line[:idx], line[idx:]
    return line, ""


def parse_unified_diff(diff_text: str) -> Dict[str, DiffFileChange]:
    """Parse git-style unified diff (`jj diff --git` or `git diff`) into per-file changes."""
    changes: Dict[str, DiffFileChange] = {}
    cur_file: Optional[DiffFileChange] = None
    old_ln = 0
    new_ln = 0
    hunk_re = re.compile(r"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@")

    for raw_line in diff_text.splitlines():
        if raw_line.startswith("diff --git "):
            parts = raw_line.split()
            if len(parts) >= 4:
                b_path = parts[3]
                if b_path.startswith("b/"):
                    b_path = b_path[2:]
                cur_file = changes.setdefault(b_path, DiffFileChange(path=b_path))
            else:
                cur_file = None
            continue
        if raw_line.startswith("+++ "):
            p = raw_line[4:].strip()
            if p == "/dev/null":
                cur_file = None
            else:
                if p.startswith("b/"):
                    p = p[2:]
                cur_file = changes.setdefault(p, DiffFileChange(path=p))
            continue
        if raw_line.startswith("--- "):
            continue
        hm = hunk_re.match(raw_line)
        if hm:
            old_ln = int(hm.group(1))
            new_ln = int(hm.group(2))
            continue
        if cur_file is None:
            continue
        if raw_line.startswith("+") and not raw_line.startswith("+++"):
            cur_file.added.append((new_ln, raw_line[1:]))
            new_ln += 1
        elif raw_line.startswith("-") and not raw_line.startswith("---"):
            cur_file.removed.append((old_ln, raw_line[1:]))
            old_ln += 1
        elif raw_line.startswith(" "):
            old_ln += 1
            new_ln += 1
    return changes


def get_jj_diff(repo_root: Path, revset: str) -> str:
    """Run `jj diff --git -r <revset>` cleanly (read-only)."""
    proc = subprocess.run(
        ["jj", "diff", "--git", "-r", revset],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"jj diff failed (rc={proc.returncode}): {proc.stderr.strip()}")
    return proc.stdout


def iter_prod_rkt_files(repo_root: Path) -> List[Tuple[str, Path]]:
    """Collect all production `.rkt` files under `lib/`, `sim/`, `bots/`."""
    out: List[Tuple[str, Path]] = []
    for root_name in PROD_RKT_ROOTS:
        root_dir = repo_root / root_name
        if not root_dir.exists():
            continue
        for p in sorted(root_dir.rglob("*.rkt")):
            if "compiled" in p.parts:
                continue
            rel = p.relative_to(repo_root).as_posix()
            out.append((rel, p))
    return out


def is_prod_rkt(rel_path: str) -> bool:
    return rel_path.endswith(".rkt") and any(
        rel_path.startswith(root + "/") for root in PROD_RKT_ROOTS
    )


def audit_generality(
    repo_root: Path,
    prod_files: Sequence[Tuple[str, Path]],
    diff_changes: Dict[str, DiffFileChange],
) -> List[Dict[str, object]]:
    """Check 1: Zero opponent/map hacks in executable prod code & newly added diff lines."""
    hits: List[Dict[str, object]] = []
    seen: set[Tuple[str, int, str]] = set()

    # 1a. Full-tree executable code scan (non-comment parts of all prod .rkt files)
    for rel, path in prod_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            code_part, _ = strip_racket_comment(line)
            if not code_part.strip():
                continue
            for kind, pat in (
                ("opponent-in-code", OPPONENT_RE),
                ("opponent-literal-in-code", AMBIGUOUS_BOT_RE),
                ("map-in-code", MAP_NAME_RE),
            ):
                m = pat.search(code_part)
                if m:
                    key = (rel, lineno, m.group(1).lower())
                    if key not in seen:
                        seen.add(key)
                        hits.append(
                            {
                                "scope": "full-tree",
                                "kind": kind,
                                "file": rel,
                                "line": lineno,
                                "match": m.group(1),
                                "snippet": line.strip()[:140],
                            }
                        )

    # 1b. Diff scan: newly added lines in prod .rkt (including comments outside build-orders)
    for rel, ch in sorted(diff_changes.items()):
        if not is_prod_rkt(rel):
            continue
        allow_pro_exemplar_comment = rel.startswith("lib/build-orders/")
        for lineno, line in ch.added:
            code_part, comment_part = strip_racket_comment(line)
            scan_targets: List[Tuple[str, str]] = [("code", code_part)]
            if comment_part and not allow_pro_exemplar_comment:
                scan_targets.append(("comment", comment_part))
            for part_kind, txt in scan_targets:
                if not txt.strip():
                    continue
                patterns: List[Tuple[str, re.Pattern[str]]] = [
                    (f"opponent-in-diff-{part_kind}", OPPONENT_RE),
                    (f"map-in-diff-{part_kind}", MAP_NAME_RE),
                ]
                if part_kind == "code":
                    patterns.append(("opponent-literal-in-diff-code", AMBIGUOUS_BOT_RE))
                for kind, pat in patterns:
                    m = pat.search(txt)
                    if m:
                        key = (rel, lineno, m.group(1).lower())
                        if key not in seen:
                            seen.add(key)
                            hits.append(
                                {
                                    "scope": "diff",
                                    "kind": kind,
                                    "file": rel,
                                    "line": lineno,
                                    "match": m.group(1),
                                    "snippet": line.strip()[:140],
                                }
                            )
    return hits


def audit_apm_hardcoded_tiers(
    repo_root: Path,
    diff_changes: Dict[str, DiffFileChange],
    check_full_tree: bool = True,
) -> List[Dict[str, object]]:
    """Check 2: Zero hardcoded static APM tier ceilings/percentage ladders."""
    hits: List[Dict[str, object]] = []
    target_rel = "lib/sc2-protobuf-ws.rkt"
    seen: set[Tuple[int, str]] = set()

    def scan_lines(scope: str, lines: Iterable[Tuple[int, str]]) -> None:
        for lineno, line in lines:
            code_part, _ = strip_racket_comment(line)
            if not code_part.strip():
                continue
            for kind, pat in (
                ("hardcoded-apm-tier-def", APM_HARDCODED_DEF_RE),
                ("hardcoded-apm-tier-ref", APM_HARDCODED_CEILING_RE),
                ("hardcoded-apm-static-ratio", APM_STATIC_RATIO_RE),
                ("hardcoded-apm-static-ceiling", APM_STATIC_LITERAL_RE),
            ):
                m = pat.search(code_part)
                if m:
                    key = (lineno, m.group(0))
                    if key not in seen:
                        seen.add(key)
                        hits.append(
                            {
                                "scope": scope,
                                "kind": kind,
                                "file": target_rel,
                                "line": lineno,
                                "match": m.group(0),
                                "snippet": line.strip()[:140],
                            }
                        )
                    break

    if target_rel in diff_changes:
        scan_lines("diff", diff_changes[target_rel].added)

    if check_full_tree:
        ws_path = repo_root / target_rel
        if ws_path.exists():
            text = ws_path.read_text(encoding="utf-8", errors="replace")
            scan_lines("full-tree", enumerate(text.splitlines(), 1))

    return hits


def audit_pro_data_constants(
    diff_changes: Dict[str, DiffFileChange],
) -> List[Dict[str, object]]:
    """Check 3: Flag newly added raw frame/bank/worker/supply magic constants in lib/."""
    flags: List[Dict[str, object]] = []
    for rel, ch in sorted(diff_changes.items()):
        if not (rel.startswith("lib/") and rel.endswith(".rkt")):
            continue
        if any(rel.startswith(p) for p in PRO_DATA_EXEMPT_PREFIXES):
            continue
        for lineno, line in ch.added:
            code_part, comment_part = strip_racket_comment(line)
            if not code_part.strip():
                continue
            if comment_part and PRO_DATA_ANNOTATION_RE.search(comment_part):
                continue
            # Skip lines referencing pro curves or canonical SC2 constants
            if re.search(r"\b(?:pro-curve|pro-target|SC2-[A-Z0-9_-]+|pro-bo-)\b", code_part):
                continue
            # 3a. Raw frame cutoffs >= 672 (30s)
            for m in RAW_FRAME_CUTOFF_RE.finditer(code_part):
                val = float(m.group(1))
                if val >= 672.0:
                    flags.append(
                        {
                            "kind": "raw-frame-cutoff",
                            "file": rel,
                            "line": lineno,
                            "value": val,
                            "snippet": line.strip()[:140],
                        }
                    )
            # 3b. Raw mineral/gas bank cutoffs >= 100
            for m in RAW_BANK_CUTOFF_RE.finditer(code_part):
                val = float(m.group(1))
                if val >= 100.0:
                    flags.append(
                        {
                            "kind": "raw-bank-cutoff",
                            "file": rel,
                            "line": lineno,
                            "value": val,
                            "snippet": line.strip()[:140],
                        }
                    )
            # 3c. Raw static worker/supply caps >= 16 (unless derived from 16*bases)
            if "bases" not in code_part and "townhall" not in code_part:
                for m in RAW_WORKER_SUPPLY_CAP_RE.finditer(code_part):
                    val = float(m.group(1))
                    if val >= 16.0:
                        flags.append(
                            {
                                "kind": "raw-worker-or-supply-cap",
                                "file": rel,
                                "line": lineno,
                                "value": val,
                                "snippet": line.strip()[:140],
                            }
                        )
    return flags


def audit_layering_ratchet(
    diff_changes: Dict[str, DiffFileChange],
) -> Tuple[List[Dict[str, object]], Dict[str, int]]:
    """Check 4: Single-Authority Layering Ratchet (hard fail on additions, count deletions)."""
    violations: List[Dict[str, object]] = []
    removed_counts: Dict[str, int] = {name: 0 for name, _, _ in RATCHET_RULES}

    for rel, ch in sorted(diff_changes.items()):
        if not (rel.startswith("lib/") and rel.endswith(".rkt")):
            continue
        for rule_name, pat, exempt_files in RATCHET_RULES:
            if rel in exempt_files:
                continue
            for lineno, line in ch.added:
                code_part, _ = strip_racket_comment(line)
                if not code_part.strip():
                    continue
                # Allow Version C cheese-specific bypasses only when explicitly gated by cheese
                if rule_name == "bypass-escrow-flag" and "cheese" in line.lower():
                    continue
                m = pat.search(code_part)
                if m:
                    violations.append(
                        {
                            "rule": rule_name,
                            "file": rel,
                            "line": lineno,
                            "match": m.group(0),
                            "snippet": line.strip()[:140],
                        }
                    )
            for _lineno, line in ch.removed:
                code_part, _ = strip_racket_comment(line)
                if code_part.strip() and pat.search(code_part):
                    removed_counts[rule_name] += 1

    return violations, removed_counts


def audit_owm_7dim_wiring(
    repo_root: Path,
    prod_files: Sequence[Tuple[str, Path]],
) -> Dict[str, Dict[str, object]]:
    """Check 5: Verify all 7 calibrated OWM dimensions have control-loop consumers."""
    l2_prefixes = (
        "lib/plan/",
        "lib/econ/",
        "lib/priority-macro-brain.rkt",
        "lib/bot-runtime.rkt",
    )
    l4_prefixes = ("lib/tactics/",)

    results: Dict[str, Dict[str, object]] = {}
    for dim_name, _tokens in OWM_DIMENSIONS:
        results[dim_name] = {
            "l2_consumers": set(),
            "l4_consumers": set(),
            "l2_hits": 0,
            "l4_hits": 0,
        }

    for rel, path in prod_files:
        in_l2 = any(rel == p or rel.startswith(p) for p in l2_prefixes)
        in_l4 = any(rel == p or rel.startswith(p) for p in l4_prefixes)
        if not (in_l2 or in_l4):
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            code_part, _ = strip_racket_comment(line)
            if not code_part.strip():
                continue
            if OWM_LOGGING_LINE_RE.search(code_part):
                continue
            # Ignore pure `provide` or `(define (accessor ...` declarations
            stripped = code_part.lstrip()
            if stripped.startswith("(provide") or stripped.startswith("(struct "):
                continue
            for dim_name, tokens in OWM_DIMENSIONS:
                if any(tok in code_part for tok in tokens):
                    entry = results[dim_name]
                    if in_l2:
                        entry["l2_consumers"].add(rel)
                        entry["l2_hits"] += 1
                    if in_l4:
                        entry["l4_consumers"].add(rel)
                        entry["l4_hits"] += 1

    # Convert sets to sorted lists & compute wired? flag
    out: Dict[str, Dict[str, object]] = {}
    for dim_name, entry in results.items():
        l2_list = sorted(entry["l2_consumers"])
        l4_list = sorted(entry["l4_consumers"])
        wired = (entry["l2_hits"] + entry["l4_hits"]) > 0
        out[dim_name] = {
            "wired": wired,
            "l2_hits": entry["l2_hits"],
            "l4_hits": entry["l4_hits"],
            "l2_files": l2_list,
            "l4_files": l4_list,
        }
    return out


def audit_complexity_budget(
    repo_root: Path,
    diff_changes: Dict[str, DiffFileChange],
) -> Dict[str, Dict[str, int]]:
    """Check 6a: LOC, define-count, and Loop/L## comment counts + net deltas on monoliths."""
    budget: Dict[str, Dict[str, int]] = {}
    for rel in MONOLITH_PATHS:
        p = repo_root / rel
        if not p.exists():
            budget[rel] = {
                "loc": 0,
                "defines": 0,
                "loop_comments": 0,
                "loc_delta": 0,
                "defines_delta": 0,
                "loop_comments_delta": 0,
            }
            continue
        lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        loc = len(lines)
        defs = 0
        loop_cmts = 0
        for line in lines:
            code_part, comment_part = strip_racket_comment(line)
            if DEFINE_LINE_RE.match(code_part):
                defs += 1
            if comment_part and LOOP_COMMENT_RE.search(comment_part):
                loop_cmts += 1

        ch = diff_changes.get(rel)
        loc_delta = 0
        def_delta = 0
        cmt_delta = 0
        if ch is not None:
            loc_delta = len(ch.added) - len(ch.removed)
            for _ln, line in ch.added:
                cp, cmt = strip_racket_comment(line)
                if DEFINE_LINE_RE.match(cp):
                    def_delta += 1
                if cmt and LOOP_COMMENT_RE.search(cmt):
                    cmt_delta += 1
            for _ln, line in ch.removed:
                cp, cmt = strip_racket_comment(line)
                if DEFINE_LINE_RE.match(cp):
                    def_delta -= 1
                if cmt and LOOP_COMMENT_RE.search(cmt):
                    cmt_delta -= 1

        budget[rel] = {
            "loc": loc,
            "defines": defs,
            "loop_comments": loop_cmts,
            "loc_delta": loc_delta,
            "defines_delta": def_delta,
            "loop_comments_delta": cmt_delta,
        }
    return budget


def parse_racket_struct_arity(path: Path, struct_name: str) -> Optional[int]:
    """Count fields in `(struct <struct_name> (f1 f2 ...))` cleanly."""
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    pat = re.compile(rf"^[ \t]*\(\s*struct\s+{re.escape(struct_name)}\b", re.MULTILINE)
    m = pat.search(text)
    if not m:
        return None
    # Walk from match end to find the field list `(...)` skipping optional super-struct id
    pos = m.end()
    n = len(text)
    while pos < n:
        ch = text[pos]
        if ch.isspace():
            pos += 1
        elif ch == ";":
            nl = text.find("\n", pos)
            pos = n if nl == -1 else nl + 1
        elif ch == "(":
            break
        elif ch == ")":
            return None
        else:
            # super-struct identifier token
            while pos < n and not text[pos].isspace() and text[pos] not in "();":
                pos += 1
    if pos >= n or text[pos] != "(":
        return None
    # Collect top-level entries inside this `(...)`
    pos += 1
    depth = 1
    fields = 0
    in_token = False
    while pos < n and depth > 0:
        ch = text[pos]
        if ch == ";":
            if in_token and depth == 1:
                fields += 1
                in_token = False
            nl = text.find("\n", pos)
            pos = n if nl == -1 else nl + 1
            continue
        if ch == "(":
            if in_token and depth == 1:
                fields += 1
                in_token = False
            if depth == 1:
                # Field with options like `[x #:mutable]` or `(x #:auto)`
                fields += 1
            depth += 1
            pos += 1
            continue
        if ch == "[":
            if in_token and depth == 1:
                fields += 1
                in_token = False
            if depth == 1:
                fields += 1
            depth += 1
            pos += 1
            continue
        if ch in (")", "]"):
            if in_token and depth == 1:
                fields += 1
                in_token = False
            depth -= 1
            pos += 1
            continue
        if ch.isspace():
            if in_token and depth == 1:
                fields += 1
                in_token = False
            pos += 1
            continue
        if depth == 1:
            in_token = True
        pos += 1
    return fields


def audit_hygiene_and_abi(
    repo_root: Path,
    diff_changes: Dict[str, DiffFileChange],
) -> Dict[str, object]:
    """Check 6b: EM/EN dash hygiene on diff, stray .zo check, and ABI struct arities."""
    em_dash_hits: List[Dict[str, object]] = []
    en_dash_hits: List[Dict[str, object]] = []

    for rel, ch in sorted(diff_changes.items()):
        if not rel.endswith((".rkt", ".py", ".md")):
            continue
        en_exempt = rel in EN_DASH_EXEMPT_FILES
        for lineno, line in ch.added:
            if "\u2014" in line:
                em_dash_hits.append({"file": rel, "line": lineno, "snippet": line.strip()[:120]})
            if not en_exempt and "\u2013" in line:
                en_dash_hits.append({"file": rel, "line": lineno, "snippet": line.strip()[:120]})

    # Stray .zo outside `compiled/` directories (pruned walk over Racket source trees + root)
    stray_zo: List[str] = []
    for p in repo_root.glob("*.zo"):
        stray_zo.append(p.relative_to(repo_root).as_posix())
    zo_roots = ("lib", "sim", "bots", "tests", "tools", "specs")
    for rname in zo_roots:
        rdir = repo_root / rname
        if not rdir.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(rdir):
            dirnames[:] = [d for d in dirnames if d not in ("compiled", "__pycache__")]
            for fn in filenames:
                if fn.endswith(".zo"):
                    rel = (Path(dirpath) / fn).relative_to(repo_root).as_posix()
                    stray_zo.append(rel)

    # Struct ABI arities
    abi_results: Dict[str, Dict[str, object]] = {}
    abi_mismatches = 0
    for sname, (rel, expected) in EXPECTED_STRUCT_ARITIES.items():
        actual = parse_racket_struct_arity(repo_root / rel, sname)
        ok = actual == expected
        if not ok:
            abi_mismatches += 1
        abi_results[sname] = {
            "file": rel,
            "expected": expected,
            "actual": actual,
            "ok": ok,
        }

    return {
        "em_dash_hits": em_dash_hits,
        "en_dash_hits": en_dash_hits,
        "stray_zo": sorted(stray_zo),
        "abi": abi_results,
        "abi_mismatches": abi_mismatches,
    }


def run_audit(
    repo_root: Path,
    diff_text: str,
    *,
    check_apm_full: bool = True,
    strict_pro_constants: bool = False,
    require_all_owm_dims: bool = False,
) -> Dict[str, object]:
    """Execute the full 6-part Generality, Pro-Data & Clean-Layering audit."""
    t0 = time.monotonic()
    diff_changes = parse_unified_diff(diff_text)
    prod_files = iter_prod_rkt_files(repo_root)

    generality_hits = audit_generality(repo_root, prod_files, diff_changes)
    apm_hits = audit_apm_hardcoded_tiers(repo_root, diff_changes, check_full_tree=check_apm_full)
    pro_flags = audit_pro_data_constants(diff_changes)
    ratchet_violations, ratchet_removed = audit_layering_ratchet(diff_changes)
    owm_wiring = audit_owm_7dim_wiring(repo_root, prod_files)
    complexity = audit_complexity_budget(repo_root, diff_changes)
    hygiene = audit_hygiene_and_abi(repo_root, diff_changes)

    owm_unwired = [dim for dim, info in owm_wiring.items() if not info["wired"]]

    hard_failures: List[str] = []
    if generality_hits:
        hard_failures.append(f"GENERALITY_HITS={len(generality_hits)}")
    if apm_hits:
        hard_failures.append(f"HARDCODED_APM_TIERS={len(apm_hits)}")
    if ratchet_violations:
        hard_failures.append(f"LAYERING_RATCHET_VIOLATIONS={len(ratchet_violations)}")
    if hygiene["em_dash_hits"]:
        hard_failures.append(f"ADDED_EM_DASH={len(hygiene['em_dash_hits'])}")
    if hygiene["en_dash_hits"]:
        hard_failures.append(f"ADDED_EN_DASH={len(hygiene['en_dash_hits'])}")
    if hygiene["stray_zo"]:
        hard_failures.append(f"STRAY_ZO={len(hygiene['stray_zo'])}")
    if hygiene["abi_mismatches"] > 0:
        hard_failures.append(f"ABI_MISMATCHES={hygiene['abi_mismatches']}")
    if strict_pro_constants and pro_flags:
        hard_failures.append(f"PRO_DATA_CONSTANT_FLAGS={len(pro_flags)}")
    if require_all_owm_dims and owm_unwired:
        hard_failures.append(f"OWM_UNWIRED_DIMS={len(owm_unwired)} ({','.join(owm_unwired)})")

    elapsed_ms = round((time.monotonic() - t0) * 1000.0, 1)
    return {
        "passed": len(hard_failures) == 0,
        "hard_failures": hard_failures,
        "elapsed_ms": elapsed_ms,
        "diff_file_count": len(diff_changes),
        "prod_rkt_count": len(prod_files),
        "generality_hits": generality_hits,
        "apm_hardcoded_hits": apm_hits,
        "pro_data_flags": pro_flags,
        "layering_ratchet": {
            "violations": ratchet_violations,
            "removed_counts": ratchet_removed,
        },
        "owm_7dim_wiring": owm_wiring,
        "owm_wired_count": len(OWM_DIMENSIONS) - len(owm_unwired),
        "owm_total_dims": len(OWM_DIMENSIONS),
        "owm_unwired_dims": owm_unwired,
        "complexity_budget": complexity,
        "hygiene_and_abi": hygiene,
    }


def format_report(report: Dict[str, object]) -> str:
    """Format a compact, scannable Gate 0.5 / Gate 1.5 CLI summary."""
    lines: List[str] = []
    status = "PASS" if report["passed"] else "FAIL"
    lines.append(
        f"=== GENERALITY, PRO-DATA & CLEAN-LAYERING AUDIT: {status} "
        f"({report['elapsed_ms']} ms, prod_rkt={report['prod_rkt_count']}, diff_files={report['diff_file_count']}) ==="
    )

    # Key one-line verifier tokens
    h = report["hygiene_and_abi"]
    abi_str = "/".join(
        str(h["abi"][k]["actual"])
        for k in ("live-bot-runtime", "opponent-world-summary", "bot-mind-log-snapshot", "cheese-build-spec")
    )
    lines.append(
        f"GENERALITY_HITS={len(report['generality_hits'])} | "
        f"HARDCODED_APM_TIERS={len(report['apm_hardcoded_hits'])} | "
        f"LAYERING_VIOLATIONS={len(report['layering_ratchet']['violations'])} | "
        f"PRO_CONST_FLAGS={len(report['pro_data_flags'])} | "
        f"OWM_WIRED={report['owm_wired_count']}/{report['owm_total_dims']} | "
        f"EM_DASH={len(h['em_dash_hits'])} EN_DASH={len(h['en_dash_hits'])} | "
        f"STRAY_ZO={len(h['stray_zo'])} | ABI={abi_str}"
    )

    if report["generality_hits"]:
        lines.append("\n[FAIL] Generality Violations:")
        for item in report["generality_hits"][:15]:
            lines.append(f"  - {item['file']}:{item['line']} [{item['kind']}] match={item['match']!r} :: {item['snippet']}")

    if report["apm_hardcoded_hits"]:
        lines.append("\n[FAIL] Hardcoded APM Tier Violations:")
        for item in report["apm_hardcoded_hits"][:15]:
            lines.append(f"  - {item['file']}:{item['line']} [{item['kind']}] :: {item['snippet']}")

    if report["layering_ratchet"]["violations"]:
        lines.append("\n[FAIL] Single-Authority Layering Ratchet Violations:")
        for item in report["layering_ratchet"]["violations"][:15]:
            lines.append(f"  - {item['file']}:{item['line']} [{item['rule']}] :: {item['snippet']}")

    removed_nonzero = {k: v for k, v in report["layering_ratchet"]["removed_counts"].items() if v > 0}
    if removed_nonzero:
        rem_txt = ", ".join(f"{k}:-{v}" for k, v in sorted(removed_nonzero.items()))
        lines.append(f"Layering Deletions in Diff: {rem_txt}")

    if report["pro_data_flags"]:
        lines.append(f"\n[ADVISORY] Pro-Data / Physics Constant Flags ({len(report['pro_data_flags'])}):")
        for item in report["pro_data_flags"][:15]:
            lines.append(f"  - {item['file']}:{item['line']} [{item['kind']}={item['value']:g}] :: {item['snippet']}")

    lines.append("\n7-Dim OWM End-to-End Control-Loop Wiring:")
    for dim_name, info in report["owm_7dim_wiring"].items():
        tag = "OK" if info["wired"] else "UNWIRED"
        lines.append(
            f"  - {dim_name:36s}: {tag:7s} (L2={info['l2_hits']} in {len(info['l2_files'])}f, "
            f"L4={info['l4_hits']} in {len(info['l4_files'])}f)"
        )

    lines.append("\nMonolith Complexity & Deletion Budget:")
    for rel, stats in report["complexity_budget"].items():
        lines.append(
            f"  - {rel:30s}: LOC={stats['loc']:5d} ({stats['loc_delta']:+d}) | "
            f"defs={stats['defines']:4d} ({stats['defines_delta']:+d}) | "
            f"loop_cmts={stats['loop_comments']:3d} ({stats['loop_comments_delta']:+d})"
        )

    if h["abi_mismatches"] > 0:
        lines.append("\n[FAIL] ABI Struct Arity Mismatches:")
        for sname, ainfo in h["abi"].items():
            if not ainfo["ok"]:
                lines.append(
                    f"  - {sname} ({ainfo['file']}): expected={ainfo['expected']} actual={ainfo['actual']}"
                )

    if report["hard_failures"]:
        lines.append("\nHard Failures: " + ", ".join(report["hard_failures"]))

    return "\n".join(lines)


def build_arg_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="Permanent Generality, Pro-Data & Clean-Layering Audit Gate for Mothman SC2."
    )
    ap.add_argument(
        "--repo-root",
        type=Path,
        default=REPO_ROOT_DEFAULT,
        help="Path to mothman-sc2-bot repository root.",
    )
    ap.add_argument(
        "--revset",
        default="@",
        help="Jujutsu revset passed to `jj diff --git -r <revset>` (default: @).",
    )
    ap.add_argument(
        "--diff-file",
        type=Path,
        default=None,
        help="Read unified diff from file instead of invoking `jj diff`.",
    )
    ap.add_argument(
        "--no-diff",
        action="store_true",
        help="Skip diff checks and run full-tree checks only.",
    )
    ap.add_argument(
        "--skip-apm-full-tree",
        action="store_true",
        help="Check hardcoded APM tiers on diff only (useful for baseline scans prior to Loop 88A Track 1).",
    )
    ap.add_argument(
        "--strict-pro-constants",
        action="store_true",
        help="Treat newly added unannotated magic frame/bank/worker constants as hard FAIL.",
    )
    ap.add_argument(
        "--require-all-owm-dims",
        action="store_true",
        help="Treat any unwired OWM dimension (0 control-loop consumers) as hard FAIL.",
    )
    ap.add_argument(
        "--json-out",
        type=Path,
        default=None,
        help="Write structured JSON audit report to this path.",
    )
    return ap


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_arg_parser().parse_args(argv)
    repo_root = args.repo_root.resolve()

    if args.no_diff:
        diff_text = ""
    elif args.diff_file is not None:
        diff_text = args.diff_file.read_text(encoding="utf-8", errors="replace")
    else:
        diff_text = get_jj_diff(repo_root, args.revset)

    report = run_audit(
        repo_root,
        diff_text,
        check_apm_full=not args.skip_apm_full_tree,
        strict_pro_constants=args.strict_pro_constants,
        require_all_owm_dims=args.require_all_owm_dims,
    )
    print(format_report(report))

    if args.json_out is not None:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
