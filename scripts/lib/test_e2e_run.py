# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for the order and naming of e2e_run's scenarios.

The scenarios run in one browser session against one deployment, so their
order is part of what they mean. Names are what a failure reports and what
E2E_ONLY matches, so two scenarios sharing one would make a red run ambiguous.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_run  # noqa: E402


def _names():
    return [name for name, _ in e2e_run.scenarios(
        None, None, None, None, "room", "http://localhost:0", "secret")]


class ScenarioRegistryTest(unittest.TestCase):
    def test_names_are_unique_and_every_scenario_is_callable(self):
        scenarios = e2e_run.scenarios(
            None, None, None, None, "room", "http://localhost:0", "secret")
        names = [name for name, _ in scenarios]
        self.assertEqual(len(names), len(set(names)))
        self.assertTrue(all(callable(run) for _, run in scenarios))

    def test_the_week_s_features_each_have_a_scenario(self):
        names = " | ".join(_names())
        for fragment in (
            "holding a reaction lists who left it",
            "message menu opens on quick reactions",
            "a thread stays off the ordinary channel list",
            "Tab and Shift+Tab move a list item",
            "a typed :shortcode: becomes its emoji",
            "cannot take a standard shortcode's name",
            "renaming a member shows the nickname",
            "push preview is one choice across devices",
            "usernames ignore case",
        ):
            self.assertIn(fragment, names)

    def test_the_scenario_that_wipes_bobs_storage_runs_last(self):
        self.assertIn("usernames ignore case", _names()[-1])


class FailedScenarioTest(unittest.TestCase):
    """A browser stranded by the last scenario must fail the next one, not the run."""

    def run_main(self, go_home_error):
        with tempfile.TemporaryDirectory() as tmp:
            results = os.path.join(tmp, "results.json")
            env = {"E2E_RESULTS": results, "E2E_SHOTS": tmp, "E2E_ONLY": ""}
            fake = [("first", lambda: None), ("second", lambda: None)]
            with mock.patch.dict(os.environ, env), \
                    mock.patch.object(sys, "argv", ["e2e_run.py", "http://x", "room", "pw"]), \
                    mock.patch.object(e2e_run, "Client"), mock.patch.object(e2e_run, "Api"), \
                    mock.patch.object(e2e_run, "sign_in"), \
                    mock.patch.object(e2e_run, "scenarios", return_value=fake), \
                    mock.patch.object(e2e_run, "go_home", side_effect=go_home_error), \
                    mock.patch.object(e2e_run.e2e_coverage, "report"), \
                    contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as raised:
                    e2e_run.main()
            with open(results, encoding="utf-8") as fh:
                return raised.exception.code, json.load(fh)

    def test_a_go_home_that_raises_on_the_first_scenario_is_recorded_as_a_failure(self):
        code, rows = self.run_main(TimeoutError("cdp"))
        self.assertEqual(code, 1)
        self.assertEqual([(r["name"], r["ok"]) for r in rows],
                         [("first", False), ("second", False)])

    def test_a_failed_row_times_its_own_scenario_not_the_previous_one(self):
        _, rows = self.run_main([None, None, TimeoutError("cdp")])
        self.assertEqual([r["ok"] for r in rows], [True, False])
        self.assertLess(rows[1]["seconds"], 5)


if __name__ == "__main__":
    unittest.main()
