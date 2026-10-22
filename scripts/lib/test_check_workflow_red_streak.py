# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-workflow-red-streak.sh.

e2e.yml is advisory and does not gate a PR or a release, so a red run there
produced no signal anyone else would see - twice, for two days each time
(see PRs #379 and #550, both "e2e was red"). Failing this workflow's own
job again would repeat exactly that mistake, so the real output under test
is a GitHub issue: opened once a real streak crosses a threshold, closed
once main is green again, deduplicated by label so a run every hour cannot
open a second one.

The run-history decision is driven through `E2E_RUNS_JSON`, a file holding
the same shape `gh api .../actions/workflows/e2e.yml/runs --jq
'.workflow_runs'` answers (newest run first, per GitHub's own ordering), so
these tests need no real red workflow. Issue management is driven through
`gh issue`/`gh label` porcelain, faked on PATH the same way
test_verify_release_checks.py fakes `gh api`.

`REAL_INCIDENT_AT_THIRD_FAILURE` is the real run() list for scripts/e2e.sh
on 2026-08-09, newest first, as of the third consecutive completed
failure - roughly 1h20m after the streak began, not the two days it
actually took anyone to notice. Pulled from `gh api
repos/NC1107/slim-m/actions/workflows/e2e.yml/runs` and trimmed to this
window; every run id, sha and timestamp below is the real one.
"""
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-workflow-red-streak.sh"

FAKE_GH = r'''#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]

log = os.environ.get("FAKE_GH_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps(args) + "\n")

if args[:1] == ["api"]:
    run_id = args[1].split("/runs/")[1].split("/")[0]
    jobs = json.loads(os.environ.get("FAKE_JOBS_JSON", "{}"))
    names = jobs.get(run_id, ["e2e"])
    sys.stdout.write("".join(n + "\n" for n in names))
    sys.exit(0)

if args[:2] == ["issue", "list"]:
    sys.stdout.write(os.environ.get("FAKE_ISSUE_LIST_JSON", "[]"))
    sys.exit(0)

if args[:2] == ["issue", "create"]:
    sys.stdout.write("https://github.com/example/example/issues/999\n")
    sys.exit(0)

if args[:2] == ["issue", "close"]:
    sys.exit(0)

if args[:2] == ["label", "create"]:
    sys.exit(0)

sys.stderr.write("fake gh: unhandled call: %r\n" % (args,))
sys.exit(1)
'''


def _run_row(created_at, conclusion, sha, status="completed", n=1):
    return {
        "id": n,
        "status": status,
        "conclusion": conclusion,
        "html_url": f"https://github.com/NC1107/slim-m/actions/runs/{n}",
        "head_sha": sha,
        "created_at": created_at,
    }


# See the module docstring for what this is and where it came from.
REAL_INCIDENT_AT_THIRD_FAILURE = [
    _run_row("2026-08-09T05:49:14Z", "failure", "091dac0cb2", n=31297514499),
    _run_row("2026-08-09T05:38:58Z", "failure", "8c1ef35a94", n=31297142132),
    _run_row("2026-08-09T04:26:42Z", "failure", "0669245b4e", n=31294569044),
    _run_row("2026-08-09T04:24:31Z", "cancelled", "18d1c02b5b", n=31294496275),
    _run_row("2026-08-09T04:24:18Z", "success", "c7824d3088", n=31294489334),
    _run_row("2026-08-09T03:38:34Z", "success", "864fd5dd57", n=31292847117),
]


class CheckE2eRedStreakTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)

        fake = root / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)

        self.log_path = root / "gh.log"
        self.env = {
            "PATH": f"{fake.parent}:/usr/bin:/bin",
            "GITHUB_REPOSITORY": "NC1107/slim-m",
            "FAKE_GH_LOG": str(self.log_path),
        }

    def _runs_file(self, rows):
        p = Path(self._tmp.name) / "runs.json"
        p.write_text(json.dumps(rows))
        return str(p)

    def _run(self, rows, extra_env=None, threshold=None):
        env = dict(self.env)
        env["E2E_RUNS_JSON"] = self._runs_file(rows)
        if threshold is not None:
            env["FAILURE_THRESHOLD"] = str(threshold)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", str(SCRIPT)], env=env, capture_output=True, text=True)

    def _log(self):
        if not self.log_path.exists():
            return []
        calls = [json.loads(line) for line in self.log_path.read_text().splitlines()]
        return [c for c in calls if c[:1] != ["api"]]

    def test_all_green_does_nothing(self):
        rows = [
            _run_row("2026-08-01T00:00:00Z", "success", "aaa", n=1),
            _run_row("2026-07-31T00:00:00Z", "success", "bbb", n=2),
        ]
        result = self._run(rows)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self._log()
        self.assertFalse(any(c[:2] in (["issue", "create"], ["issue", "close"])
                              for c in calls))

    def test_a_single_flake_among_successes_does_not_fire(self):
        """The trap named in the brief: a fixture whose runs are all
        failures never exercises 'one flake does not fire'. This one is
        genuinely mixed - the most recent run failed, but the streak
        behind it is green, so it must not open an issue."""
        rows = [
            _run_row("2026-08-01T03:00:00Z", "failure", "ccc", n=3),
            _run_row("2026-08-01T02:00:00Z", "success", "bbb", n=2),
            _run_row("2026-08-01T01:00:00Z", "success", "aaa", n=1),
        ]
        result = self._run(rows, threshold=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._log(), [])
        self.assertIn("streak: 1 consecutive", result.stdout)

    def test_exactly_at_threshold_minus_one_does_not_fire(self):
        rows = [
            _run_row("2026-08-01T02:00:00Z", "failure", "bbb", n=2),
            _run_row("2026-08-01T01:00:00Z", "failure", "aaa", n=1),
            _run_row("2026-08-01T00:00:00Z", "success", "zzz", n=0),
        ]
        result = self._run(rows, threshold=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self._log(), [])

    def test_exactly_at_threshold_fires_and_opens_an_issue(self):
        rows = [
            _run_row("2026-08-01T03:00:00Z", "failure", "ccc", n=3),
            _run_row("2026-08-01T02:00:00Z", "failure", "bbb", n=2),
            _run_row("2026-08-01T01:00:00Z", "failure", "aaa", n=1),
            _run_row("2026-08-01T00:00:00Z", "success", "zzz", n=0),
        ]
        result = self._run(rows, extra_env={"FAKE_ISSUE_LIST_JSON": "[]"},
                            threshold=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::error::", result.stdout)
        self.assertIn("3 consecutive completed runs", result.stdout)
        self.assertIn("commit aaa", result.stdout)
        calls = self._log()
        self.assertTrue(any(c[:2] == ["issue", "create"] for c in calls))

    def test_a_second_watched_workflow_gets_its_own_issue_and_wording(self):
        """The knobs a second caller sets must reach the issue it opens.

        Without this the parameters would be untested and a second watched
        workflow could quietly open an issue titled for e2e, labelled for
        e2e, and deduplicated against e2e's own - which would mean one of
        the two never gets reported at all.
        """
        rows = [
            _run_row("2026-08-01T03:00:00Z", "failure", "ccc", n=3),
            _run_row("2026-08-01T02:00:00Z", "failure", "bbb", n=2),
            _run_row("2026-08-01T01:00:00Z", "failure", "aaa", n=1),
            _run_row("2026-08-01T00:00:00Z", "success", "zzz", n=0),
        ]
        result = self._run(rows, threshold=3, extra_env={
            "FAKE_ISSUE_LIST_JSON": "[]",
            "WATCHDOG_LABEL": "main-builds-red-streak",
            "WATCHDOG_SUBJECT": "main-builds",
            "WATCHDOG_WHY": "no build is reaching a phone while this is red.",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("main-builds has failed", result.stdout)

        create = [c for c in self._log() if c[:2] == ["issue", "create"]]
        self.assertEqual(len(create), 1)
        flat = " ".join(create[0])
        self.assertIn("main-builds is stuck red on main", flat)
        self.assertIn("main-builds-red-streak", flat)
        self.assertIn("no build is reaching a phone", flat)
        self.assertNotIn("scripts/e2e.sh", flat)

    def test_a_second_watched_workflow_reads_its_own_run_history(self):
        """Each caller must ask about its own workflow, not e2e's.

        The fixture path short-circuits the API, so this asserts on the URL
        the script would have built instead - the one thing that decides
        which history is read.
        """
        # Read the code, not the comments: a stale comment naming the wrong workflow must neither satisfy nor break this (the source-reading-gate rule).
        code = "\n".join(
            line
            for line in SCRIPT.read_text().splitlines()
            if not line.lstrip().startswith("#")
        )
        self.assertIn("actions/workflows/${WORKFLOW}/runs", code)
        self.assertNotIn("actions/workflows/e2e.yml/runs", code)

    def test_cancelled_runs_neither_count_nor_break_the_streak(self):
        rows = [
            _run_row("2026-08-01T04:00:00Z", "failure", "ddd", n=4),
            _run_row("2026-08-01T03:00:00Z", "cancelled", "ccc", n=3),
            _run_row("2026-08-01T02:00:00Z", "failure", "bbb", n=2),
            _run_row("2026-08-01T01:00:00Z", "failure", "aaa", n=1),
            _run_row("2026-08-01T00:00:00Z", "success", "zzz", n=0),
        ]
        result = self._run(rows, extra_env={"FAKE_ISSUE_LIST_JSON": "[]"},
                            threshold=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3 consecutive completed runs", result.stdout)

    def test_an_already_open_issue_is_not_duplicated(self):
        rows = [
            _run_row("2026-08-01T03:00:00Z", "failure", "ccc", n=3),
            _run_row("2026-08-01T02:00:00Z", "failure", "bbb", n=2),
            _run_row("2026-08-01T01:00:00Z", "failure", "aaa", n=1),
            _run_row("2026-08-01T00:00:00Z", "success", "zzz", n=0),
        ]
        result = self._run(
            rows, threshold=3,
            extra_env={"FAKE_ISSUE_LIST_JSON":
                       json.dumps([{"number": 42}])})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("issue #42 is already open", result.stdout)
        calls = self._log()
        self.assertFalse(any(c[:2] == ["issue", "create"] for c in calls))

    def test_recovery_closes_the_open_issue(self):
        rows = [
            _run_row("2026-08-01T04:00:00Z", "success", "ddd", n=4),
            _run_row("2026-08-01T03:00:00Z", "failure", "ccc", n=3),
            _run_row("2026-08-01T02:00:00Z", "failure", "bbb", n=2),
            _run_row("2026-08-01T01:00:00Z", "failure", "aaa", n=1),
        ]
        result = self._run(
            rows, threshold=3,
            extra_env={"FAKE_ISSUE_LIST_JSON":
                       json.dumps([{"number": 42}])})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("closed issue #42", result.stdout)
        calls = self._log()
        self.assertTrue(any(c[:2] == ["issue", "close"] for c in calls))
        close_call = next(c for c in calls if c[:2] == ["issue", "close"])
        self.assertIn("42", close_call)

    def test_recovery_with_no_open_issue_does_nothing(self):
        rows = [
            _run_row("2026-08-01T01:00:00Z", "success", "aaa", n=1),
        ]
        result = self._run(rows, extra_env={"FAKE_ISSUE_LIST_JSON": "[]"},
                            threshold=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self._log()
        self.assertFalse(any(c[:2] == ["issue", "close"] for c in calls))

    def test_a_run_that_built_nothing_neither_counts_nor_breaks_the_streak(self):
        rows = [
            _run_row("2026-08-01T04:00:00Z", "failure", "ddd", n=4),
            _run_row("2026-08-01T03:00:00Z", "success", "ccc", n=3),
            _run_row("2026-08-01T02:00:00Z", "failure", "bbb", n=2),
            _run_row("2026-08-01T01:00:00Z", "failure", "aaa", n=1),
            _run_row("2026-08-01T00:00:00Z", "success", "zzz", n=0),
        ]
        result = self._run(
            rows,
            extra_env={"FAKE_ISSUE_LIST_JSON": "[]",
                        "FAKE_JOBS_JSON": json.dumps({"3": ["changes"]})},
            threshold=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("3 consecutive completed runs", result.stdout)
        self.assertTrue(any(c[:2] == ["issue", "create"] for c in self._log()))

    def test_a_run_that_built_nothing_does_not_close_an_open_issue(self):
        rows = [_run_row("2026-08-01T01:00:00Z", "success", "aaa", n=1)]
        result = self._run(
            rows,
            extra_env={"FAKE_ISSUE_LIST_JSON": '[{"number": 42}]',
                        "FAKE_JOBS_JSON": json.dumps({"1": ["changes"]})},
            threshold=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[:2] == ["issue", "close"] for c in self._log()))

    def test_a_run_whose_jobs_built_something_still_closes_the_issue(self):
        rows = [_run_row("2026-08-01T01:00:00Z", "success", "aaa", n=1)]
        result = self._run(
            rows,
            extra_env={"FAKE_ISSUE_LIST_JSON": '[{"number": 42}]',
                        "FAKE_JOBS_JSON": json.dumps(
                            {"1": ["changes", "server-image"]})},
            threshold=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(c[:2] == ["issue", "close"] for c in self._log()))

    def test_the_real_2026_08_09_incident_would_have_fired_at_the_third_failure(
            self):
        """The acceptance test the brief asks for: replay the actual
        history as it stood at the third consecutive completed failure,
        roughly 1h20m after the streak began - not the two days it
        actually took anyone to notice."""
        result = self._run(REAL_INCIDENT_AT_THIRD_FAILURE,
                            extra_env={"FAKE_ISSUE_LIST_JSON": "[]"},
                            threshold=3)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("commit 0669245b4e", result.stdout)
        calls = self._log()
        self.assertTrue(any(c[:2] == ["issue", "create"] for c in calls))


if __name__ == "__main__":
    unittest.main()
