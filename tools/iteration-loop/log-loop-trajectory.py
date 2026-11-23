#!/usr/bin/env python3
"""
Mothman SC2 Autonomous Improvement Loop — Trajectory Logger (Flywheel Step 4C)

Streams real agent `transcript.jsonl` logs across the coordinator and all
discovered swarm workers, joins them with `tools/iteration-loop/loop_ledger.json`,
`tactics_sc2_*_iter*.json`, score JSONs, and read-only `arena_replays.sqlite`,
and upserts compact structured per-loop trajectory records into:
    tools/iteration-loop/loop_trajectory_log.jsonl

Zero hardcoded credentials or secrets. Safe to run while other agents work
(opens SQLite strictly read-only `?mode=ro` and never touches GPU/Podman).
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple


SCHEMA_VERSION = 1

# Well-known active swarm roles (auto-discovery also picks up any others cleanly)
KNOWN_ROLES = {
    "coordinator",
    "harness",
    "opponents",
    "analyzer",
    "verifier",
    "monitor-2",
    "monitor",
    "runtime-author",
    "wire-author",
    "belief-author",
    "tactics-tester",
    "loop-architect",
    "reporter",
}

OWNERSHIP_REQ_RE = re.compile(
    r"(ownership request|quick scope check|may i claim|ok for me to (update|edit|claim)|"
    r"can i (edit|claim|touch)|permission to (edit|update))",
    re.IGNORECASE,
)

CPU_CONTENTION_RE = re.compile(
    r"(loadavg|suite 28.*5ms|w5-p0-1a.*4\.5ms|micro-?bench.*spik|under.*renders|cpu contention)",
    re.IGNORECASE,
)

REVERT_FLIP_RE = re.compile(
    r"\b(revert(?:ed|ing)?|restore(?:d)?\s+l\d+|supersedes?\s+l\d+|back to\s+l\d+|"
    r"roll(?:ed)?\s*back|flip-?flop)\b",
    re.IGNORECASE,
)

CAP_MISMATCH_RE = re.compile(
    r"(brain.*runtime.*mismatch|cap mismatch|raw-desired-barracks|silently refused|"
    r"split-?brain|saving_for=.*prod_stall)",
    re.IGNORECASE,
)

WS_RENDER_ERR_RE = re.compile(
    r"(ConnectionClosedError|no close frame received|EOFError: unexpected end of stream)",
    re.IGNORECASE,
)

CMD_EXIT_FAIL_RE = re.compile(r"Command exited with code ([1-9]\d*)")
UUID_SENDER_RE = re.compile(r"sender=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")
ITER_ID_RE = re.compile(r"^iter(\d+)(?:[a-z])?_")


def parse_iso(ts: Optional[str]) -> Optional[datetime]:
    if not ts:
        return None
    s = ts.strip()
    if not s:
        return None
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc)
    except ValueError:
        return None


def unquote_arg(val: Any) -> str:
    """Transcript tool_call args sometimes store JSON-encoded strings with outer quotes."""
    if val is None:
        return ""
    s = str(val)
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        try:
            decoded = json.loads(s)
            if isinstance(decoded, str):
                return decoded
        except json.JSONDecodeError:
            return s[1:-1]
    return s


def fmt_iso(dt: Optional[datetime]) -> Optional[str]:
    if dt is None:
        return None
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_run_dir_ts(name: str) -> Optional[datetime]:
    m = re.match(r"^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})_", name)
    if not m:
        return None
    y, mo, d, h, mi, s = (int(x) for x in m.groups())
    return datetime(y, mo, d, h, mi, s, tzinfo=timezone.utc)


def default_brain_root() -> Path:
    env = os.environ.get("AGY_BRAIN_ROOT")
    if env:
        return Path(env)
    return Path.home() / ".gemini/antigravity/brain"


def auto_discover_coordinator_id(brain_root: Path) -> Optional[str]:
    if not brain_root.is_dir():
        return None
    candidates: List[Tuple[int, str]] = []
    for child in brain_root.iterdir():
        if not child.is_dir():
            continue
        tpath = child / ".system_generated/logs/transcript.jsonl"
        loop_dir = child / "scratch/loop"
        if tpath.is_file() and loop_dir.is_dir():
            # Prefer largest transcript with scratch/loop/ present
            candidates.append((tpath.stat().st_size, child.name))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    return candidates[0][1]


def identify_worker_role(transcript_path: Path) -> str:
    """Identify a worker's roster role from its opening brief in transcript.jsonl."""
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as f:
            for idx, line in enumerate(f):
                if idx > 12:
                    break
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                content = str(obj.get("content") or "")
                # Look for explicit "@role" assignment in initial system/user prompt
                for m in re.finditer(r"@([a-z][a-z0-9-]{1,24})\b", content):
                    cand = m.group(1)
                    if cand not in ("all", "coordinator"):
                        return cand
                # Or check "You are <role>"
                m2 = re.search(r"You are ([a-z][a-z0-9-]{1,24}),", content)
                if m2:
                    return m2.group(1)
    except OSError:
        pass
    return f"worker-{transcript_path.parent.parent.parent.name[:8]}"


def discover_swarm_transcripts(
    brain_root: Path,
    coordinator_id: Optional[str],
    explicit_agents: Optional[Dict[str, str]] = None,
) -> Dict[str, Path]:
    """Return mapping {role_name: transcript_path} for coordinator + discovered workers."""
    found: Dict[str, Path] = {}
    if explicit_agents:
        for role, cid in explicit_agents.items():
            p = brain_root / cid / ".system_generated/logs/transcript.jsonl"
            if p.is_file():
                found[role] = p
        if found:
            return found

    cid = coordinator_id or auto_discover_coordinator_id(brain_root)
    if not cid:
        return found

    coord_t = brain_root / cid / ".system_generated/logs/transcript.jsonl"
    if not coord_t.is_file():
        return found
    found["coordinator"] = coord_t

    sender_uuids = set()
    try:
        with open(coord_t, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if "sender=" not in line:
                    continue
                for m in UUID_SENDER_RE.finditer(line):
                    u = m.group(1)
                    if u != cid:
                        sender_uuids.add(u)
    except OSError:
        pass

    role_sizes: Dict[str, Tuple[int, Path]] = {}
    for u in sorted(sender_uuids):
        wp = brain_root / u / ".system_generated/logs/transcript.jsonl"
        if not wp.is_file():
            continue
        role = identify_worker_role(wp)
        sz = wp.stat().st_size
        # If multiple UUIDs claim the same role, keep the larger transcript as canonical
        # and suffix the smaller legacy one if meaningful (>50KB).
        if role not in role_sizes:
            role_sizes[role] = (sz, wp)
        else:
            prev_sz, prev_p = role_sizes[role]
            if sz > prev_sz:
                if prev_sz > 50_000:
                    role_sizes[f"{role}-legacy-{prev_p.parent.parent.parent.name[:6]}"] = (prev_sz, prev_p)
                role_sizes[role] = (sz, wp)
            elif sz > 50_000:
                role_sizes[f"{role}-legacy-{u[:6]}"] = (sz, wp)

    for role, (_, p) in role_sizes.items():
        if role not in found:
            found[role] = p
    return found


def load_sqlite_runs(db_path: Path) -> Dict[str, Dict[str, Any]]:
    if not db_path.is_file():
        return {}
    runs: Dict[str, Dict[str, Any]] = {}
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5.0)
        cur = con.execute(
            "SELECT run_id, started_at, wall_elapsed_sec, total_replays, git_rev, mothman_mode FROM runs"
        )
        for r in cur.fetchall():
            runs[str(r[0])] = {
                "run_id": str(r[0]),
                "started_at": r[1],
                "wall_elapsed_sec": float(r[2]) if r[2] is not None else None,
                "total_replays": int(r[3]) if r[3] is not None else None,
                "git_rev": r[4],
                "mothman_mode": r[5],
            }
        con.close()
    except sqlite3.Error:
        pass
    return runs


def classify_ship_verdict(loop_id: int, entry: Dict[str, Any]) -> Tuple[str, Optional[int]]:
    status = str(entry.get("status") or "")
    spec = str(entry.get("spec_summary") or "")
    gates = str(entry.get("promotion_gates_passed") or "")
    combined = f"{status} {spec} {gates}"

    if "HOLD_ZIP" in status.upper() or "HOLD-ZIP" in combined.upper():
        return "HOLD-ZIP", None

    # Explicit live ships (L34 Ship #1, L36 Ship #2, L37 Ship #3, L40 Ship #4, L42 Ship #5, L45 Ship #6, ...)
    m_ship = re.search(r"LIVE[ _]SHIP[ _#]*(\d+)|SHIP[ _#]+(\d+)\b", combined, re.IGNORECASE)
    ship_num = int(m_ship.group(1) or m_ship.group(2)) if m_ship else None

    if loop_id >= 34:
        if (
            "UNCONDITIONAL_LIVE_SHIP" in status.upper()
            or "SHIP_GATE_GREEN" in status.upper()
            or ("SHIP #" in combined.upper() and "COMBINE" not in status.upper() and "HOLD" not in status.upper())
        ):
            if ship_num is None:
                # Known early ships L34 (#1), L36 (#2), L37 (#3)
                ship_map = {34: 1, 36: 2, 37: 3}
                ship_num = ship_map.get(loop_id)
            return "SHIP-ZIP", ship_num
        return "HOLD-ZIP", None

    # Pre-Ship-Gate loops (Loops 19–33)
    if "SHIP" in status.upper() or "HWM" in status.upper() or "GRAND_FINALE" in status.upper():
        return "CHECKPOINT", None
    return "CHECKPOINT", None


def parse_wlt(text: str) -> Optional[Tuple[int, int, int]]:
    m = re.search(r"(\d+)W-(\d+)L-(\d+)T", text)
    if m:
        return int(m.group(1)), int(m.group(2)), int(m.group(3))
    m2 = re.search(r"(\d+)-(\d+)-(\d+)", text)
    if m2:
        return int(m2.group(1)), int(m2.group(2)), int(m2.group(3))
    return None


def summarize_score_json(path_str: Optional[str]) -> Dict[str, Any]:
    if not path_str:
        return {}
    p = Path(path_str)
    if not p.is_file():
        return {}
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    ms = d.get("matches") or []
    if not ms:
        return {}
    core14 = {
        "12PoolBot", "Chance", "Creepy_strategies", "RustyNikolaj", "SmoothBrain",
        "Thssprtssbt", "mini-puck", "monsterbot", "oberon", "onlyfans", "puck",
        "sludgement2-revived", "titania", "who",
    }

    def agg(arr: List[Dict[str, Any]]) -> Dict[str, Any]:
        if not arr:
            return {"n": 0, "w": 0, "l": 0, "t": 0, "wr_pct": 0.0, "trade_agg": 0.0}
        w = sum(1 for m in arr if m.get("result") == "win")
        l = sum(1 for m in arr if m.get("result") == "loss")
        t = sum(1 for m in arr if m.get("result") == "tie")
        kv = sum(float(m.get("killed_val") or 0) for m in arr)
        lv = sum(float(m.get("lost_val") or 0) for m in arr)
        sb_vals = [
            float(m["supply_block_pct"])
            for m in arr
            if m.get("supply_block_pct") is not None
        ]
        tr_vals = sorted(float(m.get("trade_ratio") or 0) for m in arr)
        return {
            "n": len(arr),
            "w": w,
            "l": l,
            "t": t,
            "wr_pct": round(100.0 * w / len(arr), 1),
            "trade_agg": round(kv / max(1.0, lv), 2),
            "trade_med": round(tr_vals[len(tr_vals) // 2], 2) if tr_vals else 0.0,
            "sb_pct": round(sum(sb_vals) / len(sb_vals), 1) if sb_vals else None,
        }

    ext = [m for m in ms if not str(m.get("opp_bot") or "").startswith("Mothman") and not m.get("opp_early_crash")]
    core = [m for m in ext if m.get("opp_bot") in core14]
    unseen = [m for m in ext if m.get("opp_bot") not in core14]
    by_race = {}
    for race in ("Protoss", "Terran", "Zerg"):
        rm = [m for m in ms if m.get("our_race") == race]
        if rm:
            by_race[race] = agg(rm)
    return {
        "all": agg(ms),
        "ext": agg(ext),
        "core14": agg(core),
        "unseen12": agg(unseen),
        "by_race": by_race,
    }


def summarize_tactics_json(path_str: Optional[str]) -> Dict[str, Any]:
    if not path_str:
        return {}
    p = Path(path_str)
    if not p.is_file():
        return {}
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    s = d.get("summary") or {}
    scens = d.get("scenarios") or []
    wall_ms = d.get("total_wall_ms") or d.get("sc2_duel_wall_ms") or s.get("total_wall_ms")
    by_tier = s.get("by_tier") or {}
    econ = by_tier.get("econ-harass") or {}

    tr_vals = sorted(
        float(sc.get("trade_ratio"))
        for sc in scens
        if isinstance(sc, dict) and sc.get("trade_ratio") is not None
    )
    if s.get("median_trade_ratio") is not None:
        trade_med: Optional[float] = round(float(s["median_trade_ratio"]), 2)
    elif tr_vals:
        mid = len(tr_vals) // 2
        med = tr_vals[mid] if len(tr_vals) % 2 == 1 else (tr_vals[mid - 1] + tr_vals[mid]) / 2.0
        trade_med = round(med, 2)
    else:
        trade_med = None

    spell_expected_scens = [
        sc
        for sc in scens
        if isinstance(sc, dict)
        and (bool(sc.get("expected_abilities")) or sc.get("spell_verified") is not None)
    ]
    if s.get("spell_expected_count") is not None:
        spell_expected: Optional[int] = int(s["spell_expected_count"])
    elif spell_expected_scens:
        spell_expected = len(spell_expected_scens)
    else:
        spell_expected = None

    if s.get("spell_verified_count") is not None:
        spell_verified: Optional[int] = int(s["spell_verified_count"])
    elif spell_expected_scens:
        spell_verified = sum(1 for sc in spell_expected_scens if sc.get("spell_verified") is True)
    else:
        spell_verified = None

    out: Dict[str, Any] = {
        "total": int(s.get("total") or len(scens)),
        "w": int(s.get("mothman_wins") if s.get("mothman_wins") is not None else s.get("wins") or 0),
        "l": int(s.get("p2_wins") if s.get("p2_wins") is not None else s.get("losses") or 0),
        "d": int(s.get("draws") or 0),
        "trade_agg": round(float(s.get("agg_trade_ratio") or 0.0), 2),
        "am_ratio": round(float(s.get("am_ratio") or 0.0), 2) if s.get("am_ratio") is not None else None,
        "runby_wkills": int(econ.get("total_enemy_workers_killed") or s.get("total_enemy_workers_killed") or 0),
        "wall_sec": round(float(wall_ms) / 1000.0, 1) if wall_ms is not None else None,
        "record_str": s.get("record_str"),
    }
    if trade_med is not None:
        out["trade_med"] = trade_med
    if spell_expected is not None:
        out["spell_expected"] = spell_expected
        out["spell_verified"] = spell_verified if spell_verified is not None else 0
    if s.get("total_spell_unit_cmds") is not None:
        out["spell_unit_cmds"] = int(s["total_spell_unit_cmds"])
    return out


def _load_tactics_scenarios(path_str: Optional[str]) -> Dict[str, Dict[str, Any]]:
    """Load per-scenario outcomes indexed by scenario id for pass-to-pass diffing."""
    if not path_str:
        return {}
    p = Path(path_str)
    if not p.is_file():
        return {}
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    out: Dict[str, Dict[str, Any]] = {}
    for sc in d.get("scenarios") or []:
        if isinstance(sc, dict) and sc.get("id"):
            out[str(sc["id"])] = sc
    return out


def _arena_winner_rank(sc: Dict[str, Any]) -> Optional[int]:
    """Map scenario outcome to ordered rank: win=2, draw=1, loss=0."""
    w = str(sc.get("winner") or "").strip().lower()
    if w in ("mothman", "p1", "win", "player1"):
        return 2
    if w in ("draw", "tie", "timeout"):
        return 1
    if w in ("p2", "opponent", "dummy", "loss", "player2"):
        return 0
    if sc.get("passed") is True:
        return 2
    if sc.get("passed") is False:
        return 0
    return None


def _compare_arena_scenarios(
    base_scens: Dict[str, Dict[str, Any]],
    cur_scens: Dict[str, Dict[str, Any]],
) -> Dict[str, List[str]]:
    """Compare overlapping scenario IDs across two Arena passes."""
    improved: List[str] = []
    regressed: List[str] = []
    spell_gained: List[str] = []
    spell_lost: List[str] = []
    for sid in sorted(set(base_scens.keys()) & set(cur_scens.keys())):
        b_sc = base_scens[sid]
        c_sc = cur_scens[sid]
        b_rank = _arena_winner_rank(b_sc)
        c_rank = _arena_winner_rank(c_sc)
        if b_rank is not None and c_rank is not None:
            if c_rank > b_rank:
                improved.append(sid)
            elif c_rank < b_rank:
                regressed.append(sid)
        b_sv = b_sc.get("spell_verified")
        c_sv = c_sc.get("spell_verified")
        if b_sv is False and c_sv is True:
            spell_gained.append(sid)
        elif b_sv is True and c_sv is False:
            spell_lost.append(sid)
    return {
        "improved_ids": improved,
        "regressed_ids": regressed,
        "spell_gained_ids": spell_gained,
        "spell_lost_ids": spell_lost,
    }


def summarize_arena_passes(raw_passes: Optional[List[Dict[str, Any]]]) -> List[Dict[str, Any]]:
    """
    Normalize optional inner Tactics Arena pass entries (`pass0 -> pass1 -> ...`)
    from loop_ledger.json into compact trajectory records with pass-over-pass and
    cumulative vs-pass0 deltas per `(opponent, suite, category)` track.
    """
    if not raw_passes or not isinstance(raw_passes, list):
        return []

    out: List[Dict[str, Any]] = []
    track_pass0: Dict[Tuple[str, str, str], Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]] = {}
    track_prev: Dict[Tuple[str, str, str], Tuple[Dict[str, Any], Dict[str, Dict[str, Any]]]] = {}

    for idx, raw in enumerate(raw_passes):
        if not isinstance(raw, dict):
            continue
        pass_id = str(raw.get("pass_id") or f"pass{idx}")
        opponent = str(raw.get("opponent") or "dummy")
        suite = str(raw.get("suite") or "core")
        category = str(raw.get("category") or "")

        primary_path = raw.get("result_json") or raw.get("dummy_json")
        primary = summarize_tactics_json(primary_path)
        ability = summarize_tactics_json(raw.get("ability_json"))
        selfplay = summarize_tactics_json(raw.get("selfplay_json"))
        primary_scens = _load_tactics_scenarios(primary_path)

        # Merge inline fallback fields when JSON file is omitted or synthetic
        total = primary.get("total") if primary else raw.get("total")
        w = primary.get("w") if primary else raw.get("w")
        l = primary.get("l") if primary else raw.get("l")
        d = primary.get("d") if primary else raw.get("d")
        trade_agg = primary.get("trade_agg") if primary else raw.get("trade_agg")
        trade_med = primary.get("trade_med") if primary and "trade_med" in primary else raw.get("trade_med")
        spell_verified = (
            primary.get("spell_verified")
            if primary and "spell_verified" in primary
            else raw.get("spell_verified")
        )
        spell_expected = (
            primary.get("spell_expected")
            if primary and "spell_expected" in primary
            else raw.get("spell_expected")
        )
        wall_sec = primary.get("wall_sec") if primary and primary.get("wall_sec") is not None else raw.get("wall_sec")
        if wall_sec is None:
            ws_sum = sum(
                float(x["wall_sec"])
                for x in (primary, ability, selfplay)
                if x and x.get("wall_sec") is not None
            )
            if ws_sum > 0:
                wall_sec = round(ws_sum, 1)

        rec: Dict[str, Any] = {
            "pass_id": pass_id,
            "opponent": opponent,
            "suite": suite,
        }
        if category:
            rec["category"] = category
        if raw.get("label"):
            rec["label"] = str(raw["label"])
        if total is not None:
            rec["total"] = int(total)
        if w is not None:
            rec["w"] = int(w)
        if l is not None:
            rec["l"] = int(l)
        if d is not None:
            rec["d"] = int(d)
        if total and w is not None:
            rec["wr_pct"] = round(100.0 * int(w) / max(1, int(total)), 1)
        if trade_agg is not None:
            rec["trade_agg"] = round(float(trade_agg), 2)
        if trade_med is not None:
            rec["trade_med"] = round(float(trade_med), 2)
        if spell_expected is not None:
            rec["spell_expected"] = int(spell_expected)
            rec["spell_verified"] = int(spell_verified or 0)
        elif spell_verified is not None:
            rec["spell_verified"] = int(spell_verified)
        if wall_sec is not None:
            rec["wall_sec"] = round(float(wall_sec), 1)
        if primary and primary.get("record_str"):
            rec["record_str"] = primary["record_str"]
        elif raw.get("record_str"):
            rec["record_str"] = str(raw["record_str"])
        if ability:
            rec["ability"] = ability
        if selfplay:
            rec["selfplay"] = selfplay
        if raw.get("notes"):
            rec["notes"] = str(raw["notes"])[:240]

        track = (opponent, suite, category)
        if track not in track_pass0:
            track_pass0[track] = (rec, primary_scens)
            rec["delta_w_vs_prev"] = None
            rec["delta_trade_vs_prev"] = None
            rec["delta_w_vs_pass0"] = 0 if "w" in rec else None
            rec["delta_trade_vs_pass0"] = 0.0 if "trade_agg" in rec else None
            if "spell_verified" in rec:
                rec["delta_spell_verified_vs_prev"] = None
                rec["delta_spell_verified_vs_pass0"] = 0
        else:
            p0_rec, p0_scens = track_pass0[track]
            pv_rec, pv_scens = track_prev[track]
            rec["delta_w_vs_prev"] = (
                (rec["w"] - pv_rec["w"]) if ("w" in rec and "w" in pv_rec) else None
            )
            rec["delta_trade_vs_prev"] = (
                round(rec["trade_agg"] - pv_rec["trade_agg"], 2)
                if ("trade_agg" in rec and "trade_agg" in pv_rec)
                else None
            )
            rec["delta_w_vs_pass0"] = (
                (rec["w"] - p0_rec["w"]) if ("w" in rec and "w" in p0_rec) else None
            )
            rec["delta_trade_vs_pass0"] = (
                round(rec["trade_agg"] - p0_rec["trade_agg"], 2)
                if ("trade_agg" in rec and "trade_agg" in p0_rec)
                else None
            )
            if "spell_verified" in rec:
                rec["delta_spell_verified_vs_prev"] = (
                    (rec["spell_verified"] - pv_rec["spell_verified"])
                    if "spell_verified" in pv_rec
                    else None
                )
                rec["delta_spell_verified_vs_pass0"] = (
                    (rec["spell_verified"] - p0_rec["spell_verified"])
                    if "spell_verified" in p0_rec
                    else None
                )

            # Scenario-level improvement/regression tracking (file-backed or inline)
            if pv_scens and primary_scens:
                diff_prev = _compare_arena_scenarios(pv_scens, primary_scens)
                rec["improved_ids"] = diff_prev["improved_ids"]
                rec["regressed_ids"] = diff_prev["regressed_ids"]
                if diff_prev["spell_gained_ids"] or diff_prev["spell_lost_ids"]:
                    rec["spell_gained_ids"] = diff_prev["spell_gained_ids"]
                    rec["spell_lost_ids"] = diff_prev["spell_lost_ids"]
            else:
                if raw.get("improved_ids") is not None:
                    rec["improved_ids"] = list(raw["improved_ids"])
                if raw.get("regressed_ids") is not None:
                    rec["regressed_ids"] = list(raw["regressed_ids"])
                if raw.get("spell_gained_ids") is not None:
                    rec["spell_gained_ids"] = list(raw["spell_gained_ids"])
                if raw.get("spell_lost_ids") is not None:
                    rec["spell_lost_ids"] = list(raw["spell_lost_ids"])

            if p0_scens and primary_scens:
                diff_p0 = _compare_arena_scenarios(p0_scens, primary_scens)
                rec["regressed_vs_pass0_ids"] = diff_p0["regressed_ids"]
                rec["regression_count_vs_pass0"] = len(diff_p0["regressed_ids"])
            elif raw.get("regressed_vs_pass0_ids") is not None:
                rec["regressed_vs_pass0_ids"] = list(raw["regressed_vs_pass0_ids"])
                rec["regression_count_vs_pass0"] = len(rec["regressed_vs_pass0_ids"])

            if "regressed_ids" in rec:
                rec["regression_count"] = len(rec["regressed_ids"])

        track_prev[track] = (rec, primary_scens)
        out.append(rec)

    return out


def classify_tool_error(err_text: str) -> str:
    low = err_text.lower()
    if "target content not found" in low or "exact string" in low:
        return "edit_target_mismatch"
    if "no such file" in low or "file not found" in low or "does not exist" in low:
        return "file_not_found"
    if "timeout" in low or "timed out" in low:
        return "timeout"
    if "connectionclosed" in low or "unexpected end of stream" in low:
        return "ws_connection_closed"
    if "sqlite" in low or "database is locked" in low:
        return "sqlite_error"
    if "permission" in low:
        return "permission_error"
    return "other"


def extract_board_events(transcripts: Dict[str, Path]) -> List[Dict[str, Any]]:
    """Extract all post_message events across coordinator + workers with timestamps."""
    events: List[Dict[str, Any]] = []
    for role, path in transcripts.items():
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    if '"post_message"' not in line:
                        continue
                    try:
                        o = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    dt = parse_iso(o.get("created_at"))
                    if dt is None:
                        continue
                    for tc in o.get("tool_calls") or []:
                        if tc.get("name") == "post_message":
                            txt = unquote_arg((tc.get("args") or {}).get("text"))
                            events.append(
                                {
                                    "ts": dt,
                                    "agent": role,
                                    "text": txt,
                                    "head": txt[:260].replace("\n", " "),
                                }
                            )
        except OSError:
            continue
    events.sort(key=lambda e: e["ts"])
    return events


def find_loop_windows(
    ledger_entries: List[Tuple[int, Dict[str, Any]]],
    sqlite_runs: Dict[str, Dict[str, Any]],
    board_events: List[Dict[str, Any]],
) -> List[Dict[str, Any]]:
    """Determine accurate [started_at, ended_at] & phase timestamps for each loop."""
    # Pre-index coordinator/loop-architect launch posts per loop_id
    launch_ts_by_loop: Dict[int, datetime] = {}
    for ev in board_events:
        if ev["agent"] not in ("coordinator", "loop-architect"):
            continue
        txt = ev["text"]
        # Match explicit launch directives for Loop N / Wave N
        for pat in (
            r"LAUNCHING LOOP\s+(\d+)\b",
            r"Kick(?:ing)? off (?:Loop|Wave)\s+(\d+)\b",
            r"Loop\s+(\d+)(?:\s+Wave\s+\d+)?\s+Kickoff\b",
            r"Loop\s+(\d+)(?:\s*\([^)]*\))?(?:\s+Wave\s+\d+)?\s*[—–-]+\s*APPROVED\s+GO\b",
            r"GO!\s+Loop\s+(\d+)\b",
            r"Fresh Loop\s+(\d+)\s+working copy\b",
            r"Wave[- ](\d+)\s+Spec\b",
            r"Loop\s+(\d+)\s+Implementation\b",
            r"Loop\s+(\d+)\s+Disjoint",
        ):
            m = re.search(pat, txt, re.IGNORECASE)
            if m:
                lid = int(m.group(1))
                if lid not in launch_ts_by_loop:
                    launch_ts_by_loop[lid] = ev["ts"]
                break

    # Build base run1/h2h anchors for every ledger loop
    items: List[Dict[str, Any]] = []
    for lid, entry in ledger_entries:
        r1_name = Path(entry.get("run_dir") or "").name
        r2_name = Path(entry.get("baseline_h2h_run_dir") or "").name
        if not r2_name:
            # Fallback: match SQLite run_id containing iter{lid}_baseline_h2h
            pat = f"iter{lid}_baseline_h2h"
            for rk in sqlite_runs:
                if pat in rk:
                    r2_name = rk
                    break
        r1 = sqlite_runs.get(r1_name) or {}
        r2 = sqlite_runs.get(r2_name) or {}
        r1_start = parse_iso(r1.get("started_at")) or parse_run_dir_ts(r1_name)
        r2_start = parse_iso(r2.get("started_at")) or parse_run_dir_ts(r2_name)
        r1_wall = r1.get("wall_elapsed_sec")
        r2_wall = r2.get("wall_elapsed_sec")
        items.append(
            {
                "loop_id": lid,
                "entry": entry,
                "r1_name": r1_name,
                "r2_name": r2_name,
                "r1_start": r1_start,
                "r2_start": r2_start,
                "r1_wall": r1_wall,
                "r2_wall": r2_wall,
                "launch_ts": launch_ts_by_loop.get(lid),
            }
        )

    # Resolve started_at and ended_at monotonically without overlap
    for i, it in enumerate(items):
        lid = it["loop_id"]
        r1_start = it["r1_start"]
        # Anchor start time
        start = it["launch_ts"]
        if start is not None and r1_start is not None:
            # Sanity check: launch should precede run1 by 1m..10h (allows multi-pass inner Arena sprints)
            delta = (r1_start - start).total_seconds()
            if not (60 <= delta <= 36000):
                start = None
        if start is None:
            if i > 0 and items[i - 1].get("ended_at") is not None:
                start = items[i - 1]["ended_at"]
            elif r1_start is not None:
                start = r1_start - timedelta(minutes=25)
            else:
                start = datetime(2026, 11, 20, 0, 0, tzinfo=timezone.utc)
        # Ensure non-overlapping monotonicity
        if i > 0 and items[i - 1].get("ended_at") is not None and start < items[i - 1]["ended_at"]:
            start = items[i - 1]["ended_at"]
        it["started_at"] = start

        # Tentatively compute ended_at from next loop's launch OR post-benchmark completion
        next_launch = None
        if i + 1 < len(items):
            nxt = items[i + 1]
            nl = nxt["launch_ts"]
            if nl is not None and nxt["r1_start"] is not None:
                d_nl = (nxt["r1_start"] - nl).total_seconds()
                if 60 <= d_nl <= 36000 and nl > start:
                    next_launch = nl
            if next_launch is None and nxt["r1_start"] is not None:
                # Find last archival/forensics post between benchmark end and next run1 start
                end_cands = []
                if r1_start:
                    end_cands.append(r1_start + timedelta(seconds=it["r1_wall"] or 900))
                if it["r2_start"]:
                    end_cands.append(it["r2_start"] + timedelta(seconds=it["r2_wall"] or 120))
                bench_end = max(end_cands) if end_cands else (start + timedelta(minutes=30))
                # Look for analyzer/loop-architect/reporter completion post after bench_end
                cand_ends = [
                    ev["ts"]
                    for ev in board_events
                    if bench_end <= ev["ts"] < nxt["r1_start"]
                    and ev["agent"] in ("analyzer", "loop-architect", "coordinator")
                    and (
                        f"Loop {lid}" in ev["text"]
                        or f"Wave {lid}" in ev["text"]
                        or f"iter{lid}" in ev["text"]
                    )
                ]
                if cand_ends:
                    next_launch = max(cand_ends) + timedelta(seconds=5)
                else:
                    next_launch = min(bench_end + timedelta(minutes=12), nxt["r1_start"] - timedelta(minutes=15))
        if next_launch is None:
            # Last loop in sequence (e.g. Loop 47 -> Loop 48 launch if present!)
            l_next = launch_ts_by_loop.get(lid + 1)
            if l_next is not None and l_next > start:
                next_launch = l_next
            else:
                end_cands = []
                if r1_start:
                    end_cands.append(r1_start + timedelta(seconds=it["r1_wall"] or 1800))
                if it["r2_start"]:
                    end_cands.append(it["r2_start"] + timedelta(seconds=it["r2_wall"] or 120))
                bench_end = max(end_cands) if end_cands else (start + timedelta(minutes=45))
                cand_ends = [
                    ev["ts"]
                    for ev in board_events
                    if bench_end <= ev["ts"] <= bench_end + timedelta(minutes=45)
                    and ev["agent"] in ("loop-architect", "analyzer", "reporter", "coordinator")
                ]
                next_launch = (max(cand_ends) + timedelta(seconds=5)) if cand_ends else (bench_end + timedelta(minutes=10))

        if next_launch <= start:
            next_launch = start + timedelta(minutes=30)
        it["ended_at"] = next_launch

    return items


def compute_phase_durations(
    item: Dict[str, Any],
    loop_events: List[Dict[str, Any]],
    all_events: List[Dict[str, Any]],
    tactics_d: Dict[str, Any],
    tactics_sp: Dict[str, Any],
) -> Dict[str, float]:
    """Compute per-phase wall-clock durations (seconds) from real timestamps + artifacts."""
    lid = item["loop_id"]
    start = item["started_at"]
    end = item["ended_at"]
    total_wall = max(1.0, (end - start).total_seconds())
    loop_tag_re = re.compile(rf"\b(Loop\s+{lid}|Wave\s+{lid}|iter{lid})\b", re.IGNORECASE)

    def first_ts(pred, events=loop_events) -> Optional[datetime]:
        for e in events:
            if pred(e):
                return e["ts"]
        return None

    def last_ts(pred, events=loop_events) -> Optional[datetime]:
        res = None
        for e in events:
            if pred(e):
                res = e["ts"]
        return res

    # Gate 1 verify
    v_dispatch = first_ts(
        lambda e: e["agent"] == "coordinator"
        and "@verifier" in e["text"]
        and ("Gate 1" in e["text"] or "Verification" in e["text"] or f"Loop {lid}" in e["text"])
    )
    v_done = first_ts(
        lambda e: e["agent"] == "verifier"
        and ("GO" in e["text"] or "PASS" in e["text"])
        and (v_dispatch is None or e["ts"] >= v_dispatch)
    )

    # Tactics Arena
    t_dispatch = first_ts(lambda e: e["agent"] == "coordinator" and "@tactics-tester" in e["text"])
    t_done = first_ts(
        lambda e: e["agent"] == "tactics-tester"
        and ("COMPLETE" in e["text"] or "PASS" in e["text"] or "RUNWAY CLEAR" in e["text"])
        and (t_dispatch is None or e["ts"] >= t_dispatch)
    )

    # Benchmark 84 / gauntlet + H2H
    bench_sec = float(item["r1_wall"] or 0.0)
    h2h_sec = float(item["r2_wall"] or 0.0)
    h_done = last_ts(lambda e: e["agent"] == "harness")

    # Forensics, archival, and publish may legitimately overlap into Loop N+1's coding window!
    bench_end_cands = []
    if item["r1_start"] is not None:
        bench_end_cands.append(item["r1_start"] + timedelta(seconds=bench_sec or 900.0))
    if item["r2_start"] is not None:
        bench_end_cands.append(item["r2_start"] + timedelta(seconds=h2h_sec or 110.0))
    bench_end_est = max(bench_end_cands) if bench_end_cands else None
    if h_done is not None and (bench_end_est is None or h_done > bench_end_est):
        bench_end_est = h_done

    post_win_end = (bench_end_est or end) + timedelta(minutes=45)
    post_events = [
        e for e in all_events
        if (bench_end_est is None or e["ts"] >= bench_end_est - timedelta(seconds=90))
        and e["ts"] <= post_win_end
    ]

    an_dispatch = first_ts(
        lambda e: e["agent"] == "coordinator"
        and "@analyzer" in e["text"]
        and loop_tag_re.search(e["text"]),
        post_events,
    ) or first_ts(
        lambda e: e["agent"] == "coordinator" and "@analyzer" in e["text"],
        [e for e in post_events if e["ts"] < end],
    )
    an_done = first_ts(
        lambda e: e["agent"] == "analyzer"
        and an_dispatch is not None
        and e["ts"] >= an_dispatch
        and (loop_tag_re.search(e["text"]) or "SQLite" in e["text"] or "SQLITE" in e["text"]),
        post_events,
    )

    la_dispatch = first_ts(
        lambda e: e["agent"] == "coordinator"
        and "@loop-architect" in e["text"]
        and loop_tag_re.search(e["text"]),
        post_events,
    ) or first_ts(
        lambda e: e["agent"] == "coordinator" and "@loop-architect" in e["text"],
        [e for e in post_events if e["ts"] < end],
    )
    la_done = first_ts(
        lambda e: e["agent"] == "loop-architect"
        and la_dispatch is not None
        and e["ts"] >= la_dispatch
        and (loop_tag_re.search(e["text"]) or "COMPLETE" in e["text"]),
        post_events,
    )

    rep_dispatch = first_ts(
        lambda e: e["agent"] == "coordinator"
        and "@reporter" in e["text"]
        and loop_tag_re.search(e["text"])
        and ("publish" in e["text"].lower() or "SHIP #" in e["text"].upper() or "Pages" in e["text"] or "report" in e["text"].lower()),
        post_events,
    )
    rep_done = first_ts(
        lambda e: e["agent"] == "reporter"
        and rep_dispatch is not None
        and e["ts"] >= rep_dispatch
        and (loop_tag_re.search(e["text"]) or "COMPLETE" in e["text"]),
        post_events,
    )

    # Compute individual phase spans cleanly
    coding_end = v_dispatch or first_ts(lambda e: e["agent"] == "verifier") or item["r1_start"]
    coding_sec = max(0.0, (coding_end - start).total_seconds()) if coding_end and coding_end > start else 0.0
    if v_dispatch is None and t_dispatch is not None and t_dispatch > start:
        coding_sec = max(0.0, (t_dispatch - start).total_seconds())

    gate1_sec = max(0.0, (v_done - v_dispatch).total_seconds()) if (v_dispatch and v_done and v_done >= v_dispatch) else 0.0

    tactics_sec = 0.0
    if t_dispatch and t_done and t_done >= t_dispatch:
        tactics_sec = (t_done - t_dispatch).total_seconds()
    else:
        tactics_sec = float(tactics_d.get("wall_sec") or 0.0) + float(tactics_sp.get("wall_sec") or 0.0)

    forensics_sec = (
        max(0.0, (an_done - an_dispatch).total_seconds())
        if (an_dispatch and an_done and an_done >= an_dispatch)
        else 0.0
    )
    archival_sec = (
        max(0.0, (la_done - la_dispatch).total_seconds())
        if (la_dispatch and la_done and la_done >= la_dispatch)
        else 0.0
    )
    publish_sec = (
        max(0.0, (rep_done - rep_dispatch).total_seconds())
        if (rep_dispatch and rep_done and rep_done >= rep_dispatch)
        else 0.0
    )

    # Track how much of post-bench archival/publish ran overlapped past Loop N+1 launch
    overlapped_sec = 0.0
    for done_ts in (an_done, la_done, rep_done):
        if done_ts is not None and done_ts > end:
            overlapped_sec = max(overlapped_sec, (done_ts - end).total_seconds())

    # Serial portion inside [start, end]
    in_window_post = 0.0
    for disp_ts, done_ts in ((an_dispatch, an_done), (la_dispatch, la_done), (rep_dispatch, rep_done)):
        if disp_ts is not None and done_ts is not None and disp_ts < end:
            in_window_post = max(in_window_post, (min(done_ts, end) - disp_ts).total_seconds())

    active_serial_sum = coding_sec + gate1_sec + tactics_sec + bench_sec + h2h_sec + in_window_post
    idle_gaps_sec = max(0.0, total_wall - active_serial_sum)
    gpu_active_sec = tactics_sec + bench_sec + h2h_sec + min(archival_sec, 780.0)

    return {
        "coding": round(coding_sec, 1),
        "gate1_verify": round(gate1_sec, 1),
        "tactics_arena": round(tactics_sec, 1),
        "benchmark_84": round(bench_sec, 1),
        "baseline_h2h": round(h2h_sec, 1),
        "forensics": round(forensics_sec, 1),
        "archival_render": round(archival_sec, 1),
        "publish": round(publish_sec, 1),
        "overlapped_post_bench_sec": round(overlapped_sec, 1),
        "idle_gaps_sec": round(idle_gaps_sec, 1),
        "gpu_active_sec": round(min(total_wall + overlapped_sec, gpu_active_sec), 1),
    }


def stream_agent_trajectories(
    transcripts: Dict[str, Path],
    loop_items: List[Dict[str, Any]],
) -> Tuple[Dict[int, Dict[str, Dict[str, Any]]], Dict[int, List[Dict[str, Any]]]]:
    """
    Single-pass streaming scan over all transcript.jsonl files.
    Returns:
      - per_loop_agents[loop_id][role] = agent telemetry dict
      - per_loop_raw_frictions[loop_id] = list of detected transcript friction events
    """
    starts = [it["started_at"] for it in loop_items]
    ends = [it["ended_at"] for it in loop_items]
    lids = [it["loop_id"] for it in loop_items]

    per_loop_agents: Dict[int, Dict[str, Dict[str, Any]]] = {lid: {} for lid in lids}
    per_loop_frictions: Dict[int, List[Dict[str, Any]]] = {lid: [] for lid in lids}

    if not starts:
        return per_loop_agents, per_loop_frictions

    min_ts = starts[0]
    max_ts = ends[-1]

    for role, tpath in sorted(transcripts.items()):
        # Per-loop accumulators for this agent
        acc: Dict[int, Dict[str, Any]] = {}
        last_dt_by_loop: Dict[int, datetime] = {}

        def get_acc(lid: int) -> Dict[str, Any]:
            if lid not in acc:
                acc[lid] = {
                    "steps": 0,
                    "planner_turns": 0,
                    "tool_calls_total": 0,
                    "tool_calls_by_name": Counter(),
                    "tool_errors": 0,
                    "error_categories": Counter(),
                    "command_failures": 0,
                    "file_edits": 0,
                    "edited_files": set(),
                    "board_posts": 0,
                    "ownership_requests": 0,
                    "raco_make_calls": 0,
                    "full_test_calls": 0,
                    "monolith_reads": Counter(),
                    "truncations": 0,
                    "compactions": 0,
                    "input_tokens": 0,
                    "cache_read_tokens": 0,
                    "output_tokens": 0,
                    "wall_sec": 0.0,
                }
            return acc[lid]

        try:
            with open(tpath, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    try:
                        o = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    dt = parse_iso(o.get("created_at"))
                    if dt is None or dt < min_ts or dt >= max_ts:
                        continue

                    idx = bisect.bisect_right(starts, dt) - 1
                    if idx < 0 or idx >= len(lids) or dt >= ends[idx]:
                        continue
                    lid = lids[idx]
                    a = get_acc(lid)
                    a["steps"] += 1

                    # Active wall time (sum step deltas <= 300s to ignore sleep periods)
                    prev_dt = last_dt_by_loop.get(lid)
                    if prev_dt is not None:
                        delta = (dt - prev_dt).total_seconds()
                        if 0.0 <= delta <= 300.0:
                            a["wall_sec"] += delta
                    last_dt_by_loop[lid] = dt

                    stype = o.get("type")
                    if stype == "PLANNER_RESPONSE":
                        a["planner_turns"] += 1
                        a["input_tokens"] += int(o.get("input_tokens") or 0)
                        a["cache_read_tokens"] += int(o.get("cache_read_tokens") or 0)
                        a["output_tokens"] += int(o.get("output_tokens") or 0)
                    elif stype == "CHECKPOINT":
                        a["compactions"] += 1

                    if o.get("truncated_fields"):
                        a["truncations"] += 1

                    err = o.get("error")
                    if o.get("status") == "ERROR" or err:
                        a["tool_errors"] += 1
                        a["error_categories"][classify_tool_error(str(err or o.get("content") or ""))] += 1

                    content = str(o.get("content") or "")
                    if CMD_EXIT_FAIL_RE.search(content):
                        a["command_failures"] += 1
                        if WS_RENDER_ERR_RE.search(content):
                            per_loop_frictions[lid].append(
                                {
                                    "kind": "transient_renderer_retry",
                                    "agent": role,
                                    "ts": fmt_iso(dt),
                                    "detail": "SC2_x64 WebSocket ConnectionClosedError during 3D clip render",
                                }
                            )

                    for tc in o.get("tool_calls") or []:
                        nm = str(tc.get("name") or "unknown")
                        args = tc.get("args") or {}
                        a["tool_calls_total"] += 1
                        a["tool_calls_by_name"][nm] += 1
                        if nm == "run_command":
                            cmd_s = unquote_arg(args.get("CommandLine"))
                            if "raco make" in cmd_s:
                                a["raco_make_calls"] += 1
                            if "run-all-tests.rkt" in cmd_s:
                                a["full_test_calls"] += 1
                        elif nm == "read_file":
                            rp_arg = unquote_arg(args.get("Path"))
                            for mono in ("bot-runtime.rkt", "priority-macro-brain.rkt", "sc2-protobuf-ws.rkt"):
                                if rp_arg.endswith(mono):
                                    a["monolith_reads"][mono] += 1
                                    break
                        elif nm in ("edit_file", "write_file"):
                            a["file_edits"] += 1
                            p_str = unquote_arg(args.get("Path"))
                            if p_str:
                                # Keep relative/basename only (no home directory path leakage)
                                if "mothman-sc2-bot/" in p_str:
                                    p_str = p_str.split("mothman-sc2-bot/", 1)[1]
                                else:
                                    p_str = Path(p_str).name
                                a["edited_files"].add(p_str)
                        elif nm == "post_message":
                            a["board_posts"] += 1
                            txt = unquote_arg(args.get("text"))
                            if role != "coordinator" and OWNERSHIP_REQ_RE.search(txt):
                                a["ownership_requests"] += 1
                                per_loop_frictions[lid].append(
                                    {
                                        "kind": "ownership_ping_pong",
                                        "agent": role,
                                        "ts": fmt_iso(dt),
                                        "detail": txt[:140].replace("\n", " "),
                                    }
                                )
                            if CPU_CONTENTION_RE.search(txt):
                                per_loop_frictions[lid].append(
                                    {
                                        "kind": "cpu_contention_false_fail",
                                        "agent": role,
                                        "ts": fmt_iso(dt),
                                        "detail": txt[:140].replace("\n", " "),
                                    }
                                )
                            if CAP_MISMATCH_RE.search(txt):
                                per_loop_frictions[lid].append(
                                    {
                                        "kind": "brain_runtime_cap_mismatch",
                                        "agent": role,
                                        "ts": fmt_iso(dt),
                                        "detail": txt[:140].replace("\n", " "),
                                    }
                                )
                            if role in ("runtime-author", "belief-author", "wire-author", "analyzer", "coordinator") and REVERT_FLIP_RE.search(txt):
                                per_loop_frictions[lid].append(
                                    {
                                        "kind": "reverted_or_flipflop_rule",
                                        "agent": role,
                                        "ts": fmt_iso(dt),
                                        "detail": txt[:140].replace("\n", " "),
                                    }
                                )
        except OSError:
            continue

        # Finalize compact per-loop dicts for this role
        for lid, a in acc.items():
            edit_mismatch = a["error_categories"].get("edit_target_mismatch", 0)
            if edit_mismatch >= 3:
                per_loop_frictions[lid].append(
                    {
                        "kind": "edit_target_mismatch_churn",
                        "agent": role,
                        "ts": fmt_iso(last_dt_by_loop.get(lid)),
                        "detail": f"{edit_mismatch} edit_file target-mismatch errors in Loop {lid}",
                    }
                )
            if a["command_failures"] >= 5:
                per_loop_frictions[lid].append(
                    {
                        "kind": "high_command_failure_rate",
                        "agent": role,
                        "ts": fmt_iso(last_dt_by_loop.get(lid)),
                        "detail": f"{a['command_failures']} nonzero command exits in Loop {lid}",
                    }
                )

            per_loop_agents[lid][role] = {
                "steps": a["steps"],
                "planner_turns": a["planner_turns"],
                "tool_calls_total": a["tool_calls_total"],
                "tool_calls_by_name": dict(a["tool_calls_by_name"].most_common()),
                "tool_errors": a["tool_errors"],
                "error_categories": dict(a["error_categories"]),
                "command_failures": a["command_failures"],
                "file_edits": a["file_edits"],
                "edited_files": sorted(a["edited_files"]),
                "board_posts": a["board_posts"],
                "ownership_requests": a["ownership_requests"],
                "raco_make_calls": a["raco_make_calls"],
                "full_test_calls": a["full_test_calls"],
                "monolith_reads": dict(a["monolith_reads"]),
                "truncations": a["truncations"],
                "compactions": a["compactions"],
                "tokens": {
                    "input": a["input_tokens"],
                    "cache_read": a["cache_read_tokens"],
                    "output": a["output_tokens"],
                },
                "wall_sec": round(a["wall_sec"], 1),
            }

    return per_loop_agents, per_loop_frictions


def deduplicate_frictions(frictions: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    seen = set()
    out = []
    for fr in frictions:
        key = (fr.get("kind"), fr.get("agent"), str(fr.get("detail") or "")[:60])
        if key in seen:
            continue
        seen.add(key)
        out.append(fr)
    return out


def build_trajectory_records(
    ledger_path: Path,
    brain_root: Path,
    coordinator_id: Optional[str],
    db_path: Path,
    from_loop: int,
    to_loop: Optional[int],
    explicit_agents: Optional[Dict[str, str]] = None,
) -> List[Dict[str, Any]]:
    ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
    iterations = ledger.get("iterations") or []

    # Map loop_id -> latest ledger entry for that loop_id
    by_loop: Dict[int, Dict[str, Any]] = {}
    for it in iterations:
        m = ITER_ID_RE.match(str(it.get("id") or ""))
        if not m:
            continue
        lid = int(m.group(1))
        if lid < from_loop:
            continue
        if to_loop is not None and lid > to_loop:
            continue
        by_loop[lid] = it

    ordered_entries = sorted(by_loop.items(), key=lambda kv: kv[0])
    if not ordered_entries:
        return []

    transcripts = discover_swarm_transcripts(brain_root, coordinator_id, explicit_agents)
    sqlite_runs = load_sqlite_runs(db_path)
    board_events = extract_board_events(transcripts)
    loop_items = find_loop_windows(ordered_entries, sqlite_runs, board_events)
    per_loop_agents, per_loop_frictions = stream_agent_trajectories(transcripts, loop_items)

    records: List[Dict[str, Any]] = []
    prev_ext_w: Optional[int] = None
    prev_ext_trade: Optional[float] = None
    prev_core_w: Optional[int] = None

    for item in loop_items:
        lid = item["loop_id"]
        entry = item["entry"]
        start = item["started_at"]
        end = item["ended_at"]
        total_wall = round(max(1.0, (end - start).total_seconds()), 1)

        loop_evs = [e for e in board_events if start <= e["ts"] < end]
        verdict, ship_num = classify_ship_verdict(lid, entry)

        sc_main = summarize_score_json(entry.get("score_json"))
        sc_h2h = summarize_score_json(entry.get("baseline_h2h_score_json"))
        tac_d = summarize_tactics_json(entry.get("tactics_json"))
        tac_sp = summarize_tactics_json(entry.get("tactics_selfplay_json"))
        arena_passes = summarize_arena_passes(entry.get("arena_passes"))

        phases = compute_phase_durations(item, loop_evs, board_events, tac_d, tac_sp)
        if phases.get("tactics_arena", 0.0) == 0.0 and arena_passes:
            ap_wall = sum(float(ap.get("wall_sec") or 0.0) for ap in arena_passes)
            if ap_wall > 0.0:
                phases["tactics_arena"] = round(ap_wall, 1)

        # Fallback ext metrics from ledger when score_json isn't present (e.g., synthetic tests)
        ext_summary = sc_main.get("ext") or {}
        if not ext_summary and entry.get("clean_n"):
            wlt = parse_wlt(str(entry.get("record_clean") or "")) or (0, 0, 0)
            ext_summary = {
                "n": int(entry.get("clean_n") or 0),
                "w": wlt[0],
                "l": wlt[1],
                "t": wlt[2],
                "wr_pct": float(entry.get("win_rate_pct") or 0.0),
                "trade_agg": float(entry.get("trade_agg") or 0.0),
                "trade_med": float(entry.get("trade_med") or 0.0),
                "sb_pct": float(entry.get("sup_blk_pct") or 0.0),
            }

        core_summary = sc_main.get("core14") or {}
        unseen_summary = sc_main.get("unseen12") or {}
        h2h_summary = sc_h2h.get("all") or {}
        if h2h_summary and sc_h2h.get("by_race"):
            h2h_summary["by_race"] = {
                r: {"w": v["w"], "l": v["l"], "t": v["t"], "trade_agg": v["trade_agg"]}
                for r, v in sc_h2h["by_race"].items()
            }

        ext_w = ext_summary.get("w")
        ext_trade = ext_summary.get("trade_agg")
        core_w = core_summary.get("w")

        if ext_summary:
            ext_summary["delta_w_vs_prev"] = (ext_w - prev_ext_w) if (ext_w is not None and prev_ext_w is not None) else None
            ext_summary["delta_trade_vs_prev"] = (
                round(ext_trade - prev_ext_trade, 2)
                if (ext_trade is not None and prev_ext_trade is not None)
                else None
            )
        if core_summary:
            core_summary["delta_w_vs_prev"] = (core_w - prev_core_w) if (core_w is not None and prev_core_w is not None) else None

        if ext_w is not None:
            prev_ext_w = ext_w
        if ext_trade is not None:
            prev_ext_trade = ext_trade
        if core_w is not None:
            prev_core_w = core_w

        anomalies = {
            "siege0dps": entry.get("siege_range_zero_dps_losses"),
            "cloak_loss": entry.get("cloaked_unit_damage_losses"),
            "gas_rich": entry.get("gas_rich_min_starved_matches"),
            "one_base_lock": entry.get("one_base_lockout_matches"),
            "t111_stall": entry.get("terran_111_opening_stall_matches"),
            "prod_stall": entry.get("prod_placement_stall_matches"),
            "zero_kill": entry.get("zero_kill_collapse_matches"),
            "drip_feed": entry.get("drip_feed_collapse_matches"),
            "gas_zero": entry.get("gas_zero_harvest_freeze_matches"),
            "spire_drop": entry.get("spire_sched_drop_matches"),
            "wall_ties": entry.get("wall_timeout_ties"),
        }

        # Synthetic/structural friction events from metrics + phases
        frictions = list(per_loop_frictions.get(lid) or [])
        h2h_after_bench = (
            item["r1_start"] is None
            or item["r2_start"] is None
            or item["r2_start"] >= item["r1_start"]
        )
        if verdict == "HOLD-ZIP" and phases["benchmark_84"] >= 600 and h2h_summary and h2h_after_bench:
            h2h_w = h2h_summary.get("w", 0)
            h2h_l = h2h_summary.get("l", 0)
            p_h2h = (h2h_summary.get("by_race") or {}).get("Protoss") or {}
            t_h2h = (h2h_summary.get("by_race") or {}).get("Terran") or {}
            if h2h_w <= 3 or (p_h2h.get("l", 0) >= 2) or (t_h2h.get("l", 0) >= 1 and h2h_w <= 4):
                frictions.append(
                    {
                        "kind": "late_h2h_caught_regression",
                        "agent": "harness",
                        "ts": fmt_iso(item["r2_start"]),
                        "detail": (
                            f"H2H finished {h2h_w}W-{h2h_l}L AFTER running {phases['benchmark_84']/60.0:.1f}m "
                            f"full 84-match roster first"
                        ),
                        "wasted_bench_sec": phases["benchmark_84"],
                    }
                )

        # Arena early-end drop check (e.g., Arena 3.0 core expects 66, Arena 2.0 expects 58/57/36)
        if tac_d and tac_sp and tac_d.get("total", 0) > 0 and tac_sp.get("total", 0) < tac_d.get("total", 0):
            frictions.append(
                {
                    "kind": "arena_early_end_drop",
                    "agent": "tactics-tester",
                    "ts": fmt_iso(end),
                    "detail": f"Self-Play recorded {tac_sp['total']}/{tac_d['total']} scenarios (early batch end)",
                }
            )

        if (anomalies.get("prod_stall") or 0) >= 2 and lid >= 46:
            frictions.append(
                {
                    "kind": "brain_runtime_cap_mismatch",
                    "agent": "belief-author",
                    "ts": fmt_iso(end),
                    "detail": f"prod_placement_stall={anomalies['prod_stall']} (macro brain vs runtime/placement cap)",
                }
            )

        # Inner Arena pass regression check: flag if any track's final pass still has regressions vs pass0
        if arena_passes:
            last_by_track: Dict[Tuple[str, str, str], Dict[str, Any]] = {}
            for ap in arena_passes:
                tk = (str(ap.get("opponent") or "dummy"), str(ap.get("suite") or "core"), str(ap.get("category") or ""))
                last_by_track[tk] = ap
            for tk, ap in last_by_track.items():
                reg_p0 = ap.get("regressed_vs_pass0_ids") or []
                if reg_p0:
                    frictions.append(
                        {
                            "kind": "arena_pass_regression",
                            "agent": "tactics-tester",
                            "ts": fmt_iso(end),
                            "detail": (
                                f"Arena pass {ap.get('pass_id')} ({tk[0]}/{tk[1]}) ended with "
                                f"{len(reg_p0)} regression(s) vs pass0: {', '.join(reg_p0[:5])}"
                            ),
                        }
                    )

        agents_map = per_loop_agents.get(lid) or {}
        totals = {
            "active_agents": len(agents_map),
            "steps": sum(a["steps"] for a in agents_map.values()),
            "planner_turns": sum(a["planner_turns"] for a in agents_map.values()),
            "tool_calls": sum(a["tool_calls_total"] for a in agents_map.values()),
            "tool_errors": sum(a["tool_errors"] for a in agents_map.values()),
            "command_failures": sum(a["command_failures"] for a in agents_map.values()),
            "file_edits": sum(a["file_edits"] for a in agents_map.values()),
            "board_posts": sum(a["board_posts"] for a in agents_map.values()),
            "ownership_requests": sum(a["ownership_requests"] for a in agents_map.values()),
            "raco_make_calls": sum(a["raco_make_calls"] for a in agents_map.values()),
            "full_test_calls": sum(a["full_test_calls"] for a in agents_map.values()),
            "monolith_reads": sum(sum(a["monolith_reads"].values()) for a in agents_map.values()),
            "truncations": sum(a["truncations"] for a in agents_map.values()),
            "compactions": sum(a["compactions"] for a in agents_map.values()),
            "input_tokens": sum(a["tokens"]["input"] for a in agents_map.values()),
            "cache_read_tokens": sum(a["tokens"]["cache_read"] for a in agents_map.values()),
            "output_tokens": sum(a["tokens"]["output"] for a in agents_map.values()),
        }

        bot_deltas: Dict[str, Any] = {
            "core14": core_summary,
            "ext78": ext_summary,
            "unseen12": unseen_summary,
            "h2h": h2h_summary,
            "arena_dummy": tac_d,
            "arena_selfplay": tac_sp,
            "anomalies": anomalies,
        }
        if arena_passes:
            bot_deltas["arena_passes"] = arena_passes

        records.append(
            {
                "schema_version": SCHEMA_VERSION,
                "loop_id": lid,
                "wave_id": entry.get("id"),
                "rev": entry.get("rev"),
                "started_at": fmt_iso(start),
                "ended_at": fmt_iso(end),
                "total_wall_sec": total_wall,
                "ship_verdict": verdict,
                "ship_number": ship_num,
                "bot_deltas": bot_deltas,
                "phase_durations_sec": phases,
                "totals": totals,
                "agent_trajectories": agents_map,
                "friction_events": deduplicate_frictions(frictions),
                "spec_excerpt": str(entry.get("spec_summary") or "")[:320],
            }
        )

    return records


def upsert_jsonl(out_path: Path, new_records: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    existing: Dict[int, Dict[str, Any]] = {}
    if out_path.is_file():
        for line in out_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if "loop_id" in obj:
                    existing[int(obj["loop_id"])] = obj
            except (json.JSONDecodeError, ValueError):
                continue

    for rec in new_records:
        existing[int(rec["loop_id"])] = rec

    merged = [existing[k] for k in sorted(existing.keys())]
    prev_ext_w: Optional[int] = None
    prev_ext_trade: Optional[float] = None
    prev_core_w: Optional[int] = None
    for rec in merged:
        bd = rec.get("bot_deltas") or {}
        ext = bd.get("ext78") or {}
        core = bd.get("core14") or {}
        if ext:
            ew = ext.get("w")
            et = ext.get("trade_agg")
            if ext.get("delta_w_vs_prev") is None and ew is not None and prev_ext_w is not None:
                ext["delta_w_vs_prev"] = ew - prev_ext_w
            if ext.get("delta_trade_vs_prev") is None and et is not None and prev_ext_trade is not None:
                ext["delta_trade_vs_prev"] = round(et - prev_ext_trade, 2)
            if ew is not None:
                prev_ext_w = ew
            if et is not None:
                prev_ext_trade = et
        if core:
            cw = core.get("w")
            if core.get("delta_w_vs_prev") is None and cw is not None and prev_core_w is not None:
                core["delta_w_vs_prev"] = cw - prev_core_w
            if cw is not None:
                prev_core_w = cw
    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        for rec in merged:
            f.write(json.dumps(rec, separators=(",", ":"), sort_keys=False) + "\n")
    tmp.replace(out_path)
    return merged


def main(argv: Optional[List[str]] = None) -> int:
    repo_default = Path(__file__).resolve().parents[2]
    ap = argparse.ArgumentParser(
        description="Stream swarm transcripts + ledger + SQLite into loop_trajectory_log.jsonl."
    )
    ap.add_argument("--repo-root", type=Path, default=repo_default)
    ap.add_argument("--brain-root", type=Path, default=default_brain_root())
    ap.add_argument("--coordinator-id", type=str, default=None)
    ap.add_argument("--ledger", type=Path, default=None)
    ap.add_argument("--replay-db", type=Path, default=Path.home() / "sc2-local-arena/arena_replays.sqlite")
    ap.add_argument("--out-jsonl", type=Path, default=None)
    ap.add_argument("--loop", type=int, default=None, help="Log a single loop ID (upserts cleanly)")
    ap.add_argument("--from-loop", type=int, default=19)
    ap.add_argument("--to-loop", type=int, default=None)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    ledger_path = args.ledger or (args.repo_root / "tools/iteration-loop/loop_ledger.json")
    out_jsonl = args.out_jsonl or (args.repo_root / "tools/iteration-loop/loop_trajectory_log.jsonl")

    from_loop = args.loop if args.loop is not None else args.from_loop
    to_loop = args.loop if args.loop is not None else args.to_loop

    records = build_trajectory_records(
        ledger_path=ledger_path,
        brain_root=args.brain_root,
        coordinator_id=args.coordinator_id,
        db_path=args.replay_db,
        from_loop=from_loop,
        to_loop=to_loop,
    )

    if args.dry_run:
        print(f"DRY_RUN: built {len(records)} trajectory records (Loops {records[0]['loop_id']}..{records[-1]['loop_id']})" if records else "DRY_RUN: 0 records")
        return 0

    merged = upsert_jsonl(out_jsonl, records)
    total_steps = sum(r["totals"]["steps"] for r in records)
    total_frictions = sum(len(r["friction_events"]) for r in records)
    verdicts = Counter(r["ship_verdict"] for r in records)
    print(
        f"TRAJECTORY_LOG_OK: upserted={len(records)} total_in_log={len(merged)} "
        f"steps_scanned={total_steps:,} friction_events={total_frictions} "
        f"verdicts={dict(verdicts)} -> {out_jsonl}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
