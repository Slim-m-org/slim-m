# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A run that exercised nothing must not read as a pass."""
import contextlib
import io
import unittest
from unittest import mock

import e2e_parallel as par
import e2e_run
from e2e_skip import Skip


def _ok():
    pass


def _skip():
    raise Skip


def _boom():
    raise RuntimeError("broken")


def _run(scenarios, only=(), exact=None):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return e2e_run.run_selected(scenarios, list(only), exact, lambda: None)


class Verdict(unittest.TestCase):
    def test_a_filter_that_matches_nothing_fails(self):
        results = _run([("chat send", _ok)], only=["typo"])
        self.assertEqual(results, [])
        self.assertEqual(e2e_run.verdict(results)[0], 1)

    def test_an_exact_list_that_matches_nothing_fails(self):
        results = _run([("chat send", _ok)], exact={"renamed"})
        self.assertEqual(e2e_run.verdict(results)[0], 1)

    def test_a_skipped_scenario_is_not_counted_as_passed(self):
        results = _run([("a", _ok), ("b opt in", _skip)])
        self.assertEqual([r["ok"] for r in results], [True, None])
        self.assertEqual(e2e_run.verdict(results)[0], 0)

    def test_a_run_of_only_skips_fails(self):
        self.assertEqual(e2e_run.verdict(_run([("b opt in", _skip)]))[0], 1)

    def test_a_failure_still_fails_and_is_named(self):
        code, message = e2e_run.verdict(_run([("a", _ok), ("b", _boom)]))
        self.assertEqual(code, 1)
        self.assertIn("  - b", message)


class ParallelRun(unittest.TestCase):
    def test_an_empty_plan_returns_two_before_dealing(self):
        with mock.patch.object(par.e2e_run, "scenario_names", return_value=["chat send"]), \
                mock.patch.dict(par.os.environ, {"E2E_ONLY": "typo"}), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(par.main(["--plan"]), 2)

    def test_merge_drops_skipped_rows(self):
        env = {"E2E_RESULTS": "x"}
        rows = [{"name": "a", "ok": True, "seconds": 1.0},
                {"name": "b", "ok": None, "skipped": True, "seconds": 0.0}]
        with mock.patch.object(par, "read_results", return_value=rows):
            merged = par.merge([(env, ["a", "b"])], ["a", "b"])
        self.assertEqual([r[0] for r in merged], ["a"])


if __name__ == "__main__":
    unittest.main()
