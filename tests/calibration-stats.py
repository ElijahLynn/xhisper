#!/usr/bin/env python3
"""Pure-statistics tests; no compositor, network, or clipboard access."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch
from wayland_session import require_private_session


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location(
    "calibrate_perf", Path(__file__).with_name("calibrate-perf.py"))
calibration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calibration)


class CalibrationTests(unittest.TestCase):
    def test_statistics_use_nearest_rank_tail(self):
        stats = calibration.describe(list(range(1, 21)))
        self.assertEqual(stats["median_ms"], 10.5)
        self.assertEqual(stats["p95_ms"], 19)

    def test_budget_ignores_current_and_rejected_samples(self):
        baseline = [dict(path="x11", version="baseline", valid=True, dispatch_ms=200)
                    for _ in range(40)]
        ignored = [
            dict(path="x11", version="current", valid=True, dispatch_ms=9999),
            dict(path="x11", version="baseline", valid=False, dispatch_ms=9999),
        ]
        budgets = calibration.derive_budgets(baseline + ignored)
        self.assertEqual(budgets["x11"]["median_ms"], 200)
        self.assertEqual(budgets["x11"]["p95_ms"], 200)
        self.assertIsNone(budgets["wayland"])

    def test_insufficient_data_never_sets_budget(self):
        self.assertEqual(calibration.derive_budgets([]), {"x11": None, "wayland": None})

    def test_frozen_candidate_matches_baseline_evidence(self):
        root = Path(__file__).parent
        frozen = json.loads((root / "perf-budget.json").read_text())
        for path in ("x11", "wayland"):
            evidence = json.loads((root / f"perf-calibration-{path}.json").read_text())
            for version in ("baseline", "current"):
                for round_number in (1, 2):
                    self.assertEqual(sum(
                        sample["version"] == version and sample["round"] == round_number
                        and sample["path"] == path and sample["valid"]
                        for sample in evidence["samples"]), 20)
            self.assertTrue(all(sample["valid"] and sample["restored"]
                                for sample in evidence["samples"]))
            derived = calibration.derive_budgets(evidence["samples"])
            self.assertEqual(frozen["baseline_commit"], evidence["baseline_commit"])
            for metric in ("median_ms", "p95_ms"):
                self.assertEqual(frozen["budgets"][path][metric], derived[path][metric])
            if path == "wayland":
                self.assertTrue(all(sample["delivered"] for sample in evidence["samples"]))

    def test_gate_checks_both_metrics_and_requires_data(self):
        limits = dict(median_ms=200, p95_ms=300)
        self.assertTrue(calibration.within_budget(limits, limits))
        self.assertFalse(calibration.within_budget(dict(median_ms=201, p95_ms=250), limits))
        self.assertFalse(calibration.within_budget(dict(median_ms=190, p95_ms=301), limits))
        self.assertFalse(calibration.within_budget(None, limits))
        self.assertFalse(calibration.within_budget(limits, None))

    def test_native_guard_rejects_host_even_with_nested_flag(self):
        with patch.dict("os.environ", {"XHISPER_NESTED": "1"}, clear=True):
            with self.assertRaises(RuntimeError):
                require_private_session()

    def test_calibration_refuses_host_wayland_before_clipboard_access(self):
        result = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("calibrate-perf.py")),
             "--paths", "wayland", "--output", "/nonexistent/xhisper-must-not-write.json"],
            env={key: value for key, value in os.environ.items() if key != "XHISPER_NESTED"},
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("desktop access is forbidden", result.stderr)


if __name__ == "__main__":
    unittest.main()
