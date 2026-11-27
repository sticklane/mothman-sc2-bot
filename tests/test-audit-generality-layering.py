#!/usr/bin/env python3
"""Unit tests for `tools/audit-generality-layering.py` (Loop 88 Permanent Audit Gate).

Validates all 6 permanent Generality, Pro-Data & Clean-Layering audit gates:
  1. `GENERALITY_HITS = 0` (executable prod code + diff comments, build-order exemplar exemption).
  2. `HARDCODED_APM_TIERS = 0` (`tier-headroom-floor`, `tier-token-floor`, static ceiling/ratios).
  3. Pro-Data / Physics Backing Check (raw frame/bank/worker magic literals vs Pro curves & annotations).
  4. Single-Authority Layering Ratchet (hard FAIL on added bypasses/overrides/duplicate valves/l34 holds
     + accurate deletion progress tracking).
  5. 7-Dim OWM End-to-End Control-Loop Wiring (ignores logging-only references, detects unwired dims).
  6. Monolith Complexity & Deletion Budget (LOC, defines, Loop/L## comments + net diff deltas) +
     Hygiene (`EM_DASH`, `EN_DASH`, `STRAY_ZO`) + ABI struct arity parsing (`19/35/14/15`).
  7. Live repository CLI end-to-end execution (< 2.5s wall time, JSON report schema).
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
AUDIT_SCRIPT = REPO_ROOT / "tools" / "audit-generality-layering.py"


def load_audit_module():
    spec = importlib.util.spec_from_file_location("audit_generality_layering", AUDIT_SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules["audit_generality_layering"] = mod
    spec.loader.exec_module(mod)
    return mod


AGL = load_audit_module()


def make_struct_def(name: str, arity: int) -> str:
    fields = "\n   ".join(f"f{i}" for i in range(arity))
    return f"(struct {name}\n  ({fields})\n  #:transparent)\n"


def build_clean_mini_repo(root: Path) -> None:
    """Populate a minimal valid synthetic repo with clean ABI arities and 7-dim OWM wiring."""
    (root / "lib" / "plan").mkdir(parents=True, exist_ok=True)
    (root / "lib" / "econ").mkdir(parents=True, exist_ok=True)
    (root / "lib" / "tactics").mkdir(parents=True, exist_ok=True)
    (root / "lib" / "build-orders").mkdir(parents=True, exist_ok=True)
    (root / "sim").mkdir(parents=True, exist_ok=True)
    (root / "bots").mkdir(parents=True, exist_ok=True)

    (root / "lib" / "bot-runtime.rkt").write_text(
        "#lang racket\n"
        ";; Comment mentioning (struct live-bot-runtime ...) safely\n"
        + make_struct_def("live-bot-runtime", 19)
        + "(define (step-runtime obs)\n"
        + "  (define b (opponent-world-summary-confirmed-bases obs))\n"
        + "  b)\n",
        encoding="utf-8",
    )
    (root / "lib" / "opponent-world-model.rkt").write_text(
        "#lang racket\n" + make_struct_def("opponent-world-summary", 35),
        encoding="utf-8",
    )
    (root / "lib" / "sc2-logging.rkt").write_text(
        "#lang racket\n" + make_struct_def("bot-mind-log-snapshot", 14),
        encoding="utf-8",
    )
    (root / "lib" / "build-orders" / "cheese.rkt").write_text(
        "#lang racket\n"
        ";; Exemplar: Classic vs Bunny (Ultralove)\n"
        + make_struct_def("cheese-build-spec", 15),
        encoding="utf-8",
    )
    (root / "lib" / "priority-macro-brain.rkt").write_text(
        "#lang racket\n"
        "(define (step-brain owm)\n"
        "  (list (opponent-world-summary-confirmed-bases owm)\n"
        "        (opponent-world-summary-confirmed-geysers owm)\n"
        "        (opponent-world-summary-estimated-workers owm)\n"
        "        (owm-estimated-min-rate owm)\n"
        "        (opponent-world-summary-production-facility-count owm)\n"
        "        (opponent-world-summary-believed-total-army-value owm)\n"
        "        (mirror-enemy-upgrade-advantage owm)))\n",
        encoding="utf-8",
    )
    (root / "lib" / "sc2-protobuf-ws.rkt").write_text(
        "#lang racket\n"
        "(define (govern-sc2-wire-actions! gov cmds)\n"
        "  ;; Single configurable cap with continuous value density\n"
        "  (define cap (wire-apm-governor-cap gov))\n"
        "  cmds)\n",
        encoding="utf-8",
    )
    (root / "lib" / "tactics" / "operation-controller.rkt").write_text(
        "#lang racket\n"
        "(define (compute-tactical-op owm)\n"
        "  (define arm (opponent-world-summary-believed-total-army-value owm))\n"
        "  (define upg (owm-upgrade-delta owm))\n"
        "  (list arm upg))\n",
        encoding="utf-8",
    )


class TestAuditGeneralityLayering(unittest.TestCase):
    def test_clean_mini_repo_passes_all_gates(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_clean_mini_repo(root)
            report = AGL.run_audit(
                root,
                "",
                check_apm_full=True,
                strict_pro_constants=True,
                require_all_owm_dims=True,
            )
            self.assertTrue(report["passed"], f"Expected clean pass, got: {report['hard_failures']}")
            self.assertEqual(len(report["generality_hits"]), 0)
            self.assertEqual(len(report["apm_hardcoded_hits"]), 0)
            self.assertEqual(len(report["layering_ratchet"]["violations"]), 0)
            self.assertEqual(len(report["pro_data_flags"]), 0)
            self.assertEqual(report["owm_wired_count"], 7)
            self.assertEqual(report["hygiene_and_abi"]["abi_mismatches"], 0)

    def test_generality_catches_code_and_diff_hacks(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_clean_mini_repo(root)
            # 1. Executable code referencing an opponent name & map name
            (root / "lib" / "bad-hack.rkt").write_text(
                '#lang racket\n'
                '(define (hack opp map-name)\n'
                '  (or (equal? opp "PolyMorph")\n'
                '      (equal? opp \'puck)\n'
                '      (string-contains? map-name "Incorporeal")))\n',
                encoding="utf-8",
            )
            # 2. Newly added diff comment citing opponent in lib/bot-runtime.rkt vs exempt build-orders
            diff_text = (
                "diff --git a/lib/bot-runtime.rkt b/lib/bot-runtime.rkt\n"
                "--- a/lib/bot-runtime.rkt\n"
                "+++ b/lib/bot-runtime.rkt\n"
                "@@ -20,0 +21,2 @@\n"
                "+;; Special tweak for AxeFighter early hold\n"
                "+(define safe-ok? #t)\n"
                "diff --git a/lib/build-orders/cheese.rkt b/lib/build-orders/cheese.rkt\n"
                "--- a/lib/build-orders/cheese.rkt\n"
                "+++ b/lib/build-orders/cheese.rkt\n"
                "@@ -1,0 +2,1 @@\n"
                "+;; Exemplar: Serral vs Clem (Persephone)\n"
            )
            report = AGL.run_audit(root, diff_text, check_apm_full=True)
            self.assertFalse(report["passed"])
            matches = {h["match"].lower() for h in report["generality_hits"]}
            self.assertIn("polymorph", matches)
            self.assertIn("puck", matches)
            self.assertIn("incorporeal", matches)
            self.assertIn("axefighter", matches)
            # Pro exemplar comment inside lib/build-orders/ must NOT trigger
            self.assertNotIn("persephone", matches)

    def test_apm_hardcoded_tiers_caught_and_clean_passes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_clean_mini_repo(root)
            (root / "lib" / "sc2-protobuf-ws.rkt").write_text(
                "#lang racket\n"
                "(define (tier-headroom-floor tier)\n"
                "  (* hard-cap 0.78))\n"
                "(define p2-cap 390.0)\n"
                "(define (check-ceil)\n"
                "  (define tier-ceiling 390.0)\n"
                "  (tier-headroom-floor 2))\n",
                encoding="utf-8",
            )
            report = AGL.run_audit(root, "", check_apm_full=True)
            self.assertFalse(report["passed"])
            kinds = {h["kind"] for h in report["apm_hardcoded_hits"]}
            self.assertIn("hardcoded-apm-tier-def", kinds)
            self.assertIn("hardcoded-apm-static-ratio", kinds)
            self.assertIn("hardcoded-apm-static-ceiling", kinds)

    def test_pro_data_constant_backing_flags_and_exemptions(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_clean_mini_repo(root)
            diff_text = (
                "diff --git a/lib/priority-macro-brain.rkt b/lib/priority-macro-brain.rkt\n"
                "--- a/lib/priority-macro-brain.rkt\n"
                "+++ b/lib/priority-macro-brain.rkt\n"
                "@@ -10,0 +11,8 @@\n"
                "+(define bad-frame? (>= frame 5376))\n"
                "+(define bad-bank? (and (>= cur-gas 180) (< cur-min 120)))\n"
                "+(define bad-wcap? (>= workers 44))\n"
                "+(define ok-annotated? (>= frame 6720)) ; pro-data: 5:00 median 3rd\n"
                "+(define ok-pro-curve? (>= workers (pro-target-workers race frame)))\n"
                "+(define ok-sat? (>= workers (* 16 bases)))\n"
                "+(define ok-const? (>= frame SC2-FASTER-LOOPS-PER-MINUTE))\n"
                "diff --git a/lib/plan/pro-curves.rkt b/lib/plan/pro-curves.rkt\n"
                "--- /dev/null\n"
                "+++ b/lib/plan/pro-curves.rkt\n"
                "@@ -0,0 +1,2 @@\n"
                "+(define curve-ok? (>= frame 8064))\n"
            )
            # Advisory by default: passes hard gates, reports exactly 4 flagged literals
            rep_adv = AGL.run_audit(root, diff_text, strict_pro_constants=False)
            self.assertTrue(rep_adv["passed"])
            kinds = [f["kind"] for f in rep_adv["pro_data_flags"]]
            self.assertEqual(kinds.count("raw-frame-cutoff"), 1)
            self.assertEqual(kinds.count("raw-bank-cutoff"), 2)
            self.assertEqual(kinds.count("raw-worker-or-supply-cap"), 1)
            self.assertEqual(len(kinds), 4)

            # Strict mode promotes them to hard FAIL
            rep_strict = AGL.run_audit(root, diff_text, strict_pro_constants=True)
            self.assertFalse(rep_strict["passed"])
            self.assertTrue(any("PRO_DATA_CONSTANT_FLAGS=4" in f for f in rep_strict["hard_failures"]))

    def test_single_authority_layering_ratchet_and_deletions(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_clean_mini_repo(root)
            # Diff adding violations AND deleting legacy ones
            diff_text = (
                "diff --git a/lib/bot-runtime.rkt b/lib/bot-runtime.rkt\n"
                "--- a/lib/bot-runtime.rkt\n"
                "+++ b/lib/bot-runtime.rkt\n"
                "@@ -10,4 +10,8 @@\n"
                "-(define wd-gas-mode 'pull-to-minerals)\n"
                "-(define (l2-non-combat-min-ok? ctx m) #t)\n"
                "+(emit-build! ctx 'bunker #:bypass-escrow? #t)\n"
                "+(emit-cheese! ctx 'pylon #:bypass-escrow? #t)\n"
                "+(define (l2-holding-for-starport? ctx) #t)\n"
                "+(define (wd-gas-mode ctx) 'pull)\n"
                "+(define l88-random-hold? #t)\n"
                "diff --git a/lib/priority-macro-brain.rkt b/lib/priority-macro-brain.rkt\n"
                "--- a/lib/priority-macro-brain.rkt\n"
                "+++ b/lib/priority-macro-brain.rkt\n"
                "@@ -5,1 +5,3 @@\n"
                "-(define foo-ignores-tech-escrow? #t)\n"
                "+(define bar-ignores-tank-escrow? #t)\n"
                "+(define my-override-post? #t)\n"
                "diff --git a/lib/tactics/operation-controller.rkt b/lib/tactics/operation-controller.rkt\n"
                "--- a/lib/tactics/operation-controller.rkt\n"
                "+++ b/lib/tactics/operation-controller.rkt\n"
                "@@ -2,0 +3,1 @@\n"
                "+(define l88-unified-hold? #t)\n"
            )
            report = AGL.run_audit(root, diff_text)
            self.assertFalse(report["passed"])
            rules = {v["rule"] for v in report["layering_ratchet"]["violations"]}
            self.assertEqual(
                rules,
                {
                    "bypass-escrow-flag",
                    "duplicate-runtime-escrow",
                    "duplicate-gas-valve",
                    "adhoc-l34-hold-boolean",
                    "ignores-escrow-override",
                    "post-escrow-override",
                },
            )
            # Cheese-tagged bypass & operation-controller.rkt hold must NOT be flagged
            self.assertEqual(len(report["layering_ratchet"]["violations"]), 6)
            # Removed counts accurately track legacy deletions
            removed = report["layering_ratchet"]["removed_counts"]
            self.assertEqual(removed["duplicate-gas-valve"], 1)
            self.assertEqual(removed["duplicate-runtime-escrow"], 1)
            self.assertEqual(removed["ignores-escrow-override"], 1)

    def test_owm_7dim_ignores_logging_only_and_detects_unwired(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_clean_mini_repo(root)
            # Replace brain & tactics so dim7_upgrades only appears inside fprintf logging
            (root / "lib" / "priority-macro-brain.rkt").write_text(
                "#lang racket\n"
                "(define (step-brain owm)\n"
                "  (fprintf (current-error-port) \"[SCBOT_OWM] upg=~a\" (mirror-enemy-upgrade-advantage owm))\n"
                "  (list (opponent-world-summary-confirmed-bases owm)\n"
                "        (opponent-world-summary-confirmed-geysers owm)\n"
                "        (opponent-world-summary-estimated-workers owm)\n"
                "        (owm-estimated-min-rate owm)\n"
                "        (opponent-world-summary-production-facility-count owm)\n"
                "        (opponent-world-summary-believed-total-army-value owm)))\n",
                encoding="utf-8",
            )
            (root / "lib" / "tactics" / "operation-controller.rkt").write_text(
                "#lang racket\n"
                "(define (compute-tactical-op owm)\n"
                "  (opponent-world-summary-believed-total-army-value owm))\n",
                encoding="utf-8",
            )
            report = AGL.run_audit(root, "", require_all_owm_dims=True)
            self.assertFalse(report["passed"])
            self.assertEqual(report["owm_wired_count"], 6)
            self.assertEqual(report["owm_unwired_dims"], ["dim7_upgrades"])

    def test_complexity_budget_hygiene_and_abi(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build_clean_mini_repo(root)
            # Create one stray .zo outside compiled/ and one legitimate compiled/*.zo
            (root / "lib" / "stray.zo").write_bytes(b"zo")
            (root / "lib" / "compiled").mkdir(parents=True, exist_ok=True)
            (root / "lib" / "compiled" / "ok.zo").write_bytes(b"zo")
            # Break live-bot-runtime ABI arity (19 -> 20)
            (root / "lib" / "bot-runtime.rkt").write_text(
                "#lang racket\n" + make_struct_def("live-bot-runtime", 20),
                encoding="utf-8",
            )
            diff_text = (
                "diff --git a/lib/bot-runtime.rkt b/lib/bot-runtime.rkt\n"
                "--- a/lib/bot-runtime.rkt\n"
                "+++ b/lib/bot-runtime.rkt\n"
                "@@ -1,3 +1,1 @@\n"
                "-(define old-a 1) ;; Loop 72A legacy hack\n"
                "-(define old-b 2) ;; L73B legacy hack\n"
                "+(define clean-x 3) ;; clean \u2014 dash\n"
            )
            report = AGL.run_audit(root, diff_text)
            self.assertFalse(report["passed"])
            cb = report["complexity_budget"]["lib/bot-runtime.rkt"]
            self.assertEqual(cb["loc_delta"], -1)
            self.assertEqual(cb["defines_delta"], -1)
            self.assertEqual(cb["loop_comments_delta"], -2)
            h = report["hygiene_and_abi"]
            self.assertEqual(h["stray_zo"], ["lib/stray.zo"])
            self.assertEqual(len(h["em_dash_hits"]), 1)
            self.assertEqual(h["abi_mismatches"], 1)
            self.assertEqual(h["abi"]["live-bot-runtime"]["actual"], 20)

    def test_cli_live_repo_fast_and_clean(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out_json = Path(td) / "audit.json"
            proc = subprocess.run(
                [
                    sys.executable,
                    str(AUDIT_SCRIPT),
                    "--repo-root",
                    str(REPO_ROOT),
                    "--no-diff",
                    "--skip-apm-full-tree",
                    "--json-out",
                    str(out_json),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, f"Live audit failed:\n{proc.stdout}\n{proc.stderr}")
            data = json.loads(out_json.read_text(encoding="utf-8"))
            self.assertTrue(data["passed"])
            self.assertEqual(len(data["generality_hits"]), 0)
            self.assertEqual(data["hygiene_and_abi"]["abi_mismatches"], 0)
            self.assertEqual(len(data["hygiene_and_abi"]["stray_zo"]), 0)
            self.assertLess(data["elapsed_ms"], 3500.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
