# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/verify-release-checks.sh.

Three distinct bugs reached production before anything tested this loop: a
cancelled check read as success (client 0.17.0 skipped its iOS build), the
release-please path verified `github.sha` instead of the commit it actually
released (server 0.23.0 shipped no artifacts), and a tag was passed to an
endpoint that only accepts a SHA (client 0.21.1, same failure). Each is
covered below by driving the real script through `bash` against a fake `gh`
on PATH, the same technique test_decide_latest_tag.py already uses.

The fake `gh` dispatches on the API path it was called with rather than on
call order, and every invocation is appended to a log file so a test can
assert what was actually requested - which is how the tag/SHA test below
catches a regression: it fails if the script ever queries
`actions/runs?head_sha=` with the raw ref instead of the commit it resolved.
"""
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "verify-release-checks.sh"

FAKE_GH = r'''#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
path = args[1] if len(args) > 1 else ""

log = os.environ.get("FAKE_GH_LOG")
if log:
    with open(log, "a") as f:
        f.write(json.dumps(args) + "\n")


def _next_call(name):
    counter_path = os.path.join(os.environ["FAKE_GH_STATE_DIR"], name)
    n = 1
    if os.path.exists(counter_path):
        n = int(open(counter_path).read().strip()) + 1
    with open(counter_path, "w") as f:
        f.write(str(n))
    return n


def _sequenced(env_var, call_n):
    seq_dir = os.environ.get(env_var)
    if not seq_dir:
        return None
    files = sorted(os.listdir(seq_dir), key=int)
    idx = min(call_n, len(files)) - 1
    return open(os.path.join(seq_dir, files[idx])).read()


if "/commits/" in path and "check-runs" not in path:
    code = int(os.environ.get("FAKE_RESOLVE_EXIT", "0"))
    if code != 0:
        sys.stderr.write(os.environ.get("FAKE_RESOLVE_STDERR", "gh: not found\n"))
        sys.exit(code)
    sys.stdout.write(os.environ["FAKE_RESOLVE_SHA"])
    sys.exit(0)

if "check-runs" in path:
    n = _next_call("checkruns")
    out = _sequenced("FAKE_CHECKRUNS_SEQ_DIR", n)
    sys.stdout.write(out or "")
    sys.exit(0)

if "actions/runs" in path and os.environ.get("FAKE_ACTIONSRUNS_JSON"):
    import subprocess
    expr = args[args.index("--jq") + 1]
    done = subprocess.run(
        ["jq", "-r", expr], input=os.environ["FAKE_ACTIONSRUNS_JSON"],
        capture_output=True, text=True, check=True)
    sys.stdout.write(done.stdout)
    sys.exit(0)

if "actions/runs" in path:
    n = _next_call("actionsruns")
    out = _sequenced("FAKE_ACTIONSRUNS_SEQ_DIR", n)
    if out is None:
        out = os.environ.get("FAKE_ACTIONSRUNS_COUNT", "0")
    sys.stdout.write(out.strip() + "\n")
    sys.exit(0)

sys.stderr.write("fake gh: unhandled call: %r\n" % (args,))
sys.exit(1)
'''


def _check_run(name, status, conclusion=None, started_at="2026-01-01T00:00:00Z", suite=None):
    run = {"name": name, "status": status, "started_at": started_at}
    if suite is not None:
        run["check_suite"] = {"id": suite}
    if conclusion is not None:
        run["conclusion"] = conclusion
    return run


class VerifyReleaseChecksTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)

        fake = root / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)

        self.state_dir = root / "state"
        self.state_dir.mkdir()
        self.log_path = root / "gh.log"
        self.fake_gh_dir = str(fake.parent)

        self.env = {
            "PATH": f"{self.fake_gh_dir}:/usr/bin:/bin",
            "GH_TOKEN": "fake-token",
            "GITHUB_REPOSITORY": "NC1107/slim-m",
            "REQUIRED_CHECKS": "build|test",
            "REF": "deadbeef",
            "FAKE_GH_STATE_DIR": str(self.state_dir),
            "FAKE_GH_LOG": str(self.log_path),
            "FAKE_RESOLVE_SHA": "deadbeef",
            "DEADLINE_SECONDS": "2",
            "CREATION_GRACE_SECONDS": "0",
            "POLL_INTERVAL_SECONDS": "0",
        }

    def _seq_dir(self, name, iterations):
        """Write each iteration's check-runs answer as `gh --jq
        '.check_runs[]'` would print it: one compact JSON object per line.
        """
        d = Path(self._tmp.name) / name
        d.mkdir()
        for i, runs in enumerate(iterations, start=1):
            text = "".join(json.dumps(r) + "\n" for r in runs)
            (d / str(i)).write_text(text)
        return str(d)

    def _plain_seq_dir(self, name, iterations):
        """Like `_seq_dir`, for an endpoint that answers a bare value (the
        actions/runs still-running count) rather than a JSON object per line.
        """
        d = Path(self._tmp.name) / name
        d.mkdir()
        for i, value in enumerate(iterations, start=1):
            (d / str(i)).write_text(value)
        return str(d)

    def _run(self, extra_env=None, required_checks=None):
        env = dict(self.env)
        if required_checks is not None:
            env["REQUIRED_CHECKS"] = required_checks
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["bash", str(SCRIPT)], env=env, capture_output=True, text=True)

    def _log(self):
        if not self.log_path.exists():
            return []
        return [json.loads(line) for line in self.log_path.read_text().splitlines()]

    def test_all_success_passes(self):
        seq = self._seq_dir("checkruns", [[
            _check_run("build", "completed", "success"),
            _check_run("test", "completed", "success"),
        ]])
        result = self._run({"FAKE_CHECKRUNS_SEQ_DIR": seq})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("required checks passed", result.stdout)

    def test_a_failure_fails(self):
        seq = self._seq_dir("checkruns", [[
            _check_run("build", "completed", "success"),
            _check_run("test", "completed", "failure"),
        ]])
        result = self._run({"FAKE_CHECKRUNS_SEQ_DIR": seq})
        self.assertEqual(result.returncode, 1)
        self.assertIn("required check(s) failed", result.stdout)
        self.assertIn("test:failure", result.stdout)

    def test_a_cancelled_check_is_pinned_as_a_failure(self):
        """Current, deliberate behaviour: a cancelled check is not a pass and
        is not merely "still pending" either. If this is ever changed to
        retry instead, this test should change with it on purpose.
        """
        seq = self._seq_dir("checkruns", [[
            _check_run("build", "completed", "success"),
            _check_run("test", "completed", "cancelled"),
        ]])
        result = self._run({"FAKE_CHECKRUNS_SEQ_DIR": seq})
        self.assertEqual(result.returncode, 1)
        self.assertIn("required check(s) failed", result.stdout)
        self.assertIn("test:cancelled", result.stdout)

    def test_a_pending_check_keeps_waiting_then_passes(self):
        seq = self._seq_dir("checkruns", [
            [
                _check_run("build", "completed", "success"),
                _check_run("test", "in_progress"),
            ],
            [
                _check_run("build", "completed", "success"),
                _check_run("test", "completed", "success"),
            ],
        ])
        result = self._run({"FAKE_CHECKRUNS_SEQ_DIR": seq})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("waiting on", result.stdout)
        self.assertIn("required checks passed", result.stdout)

    def test_a_genuinely_absent_check_fails_after_the_grace_period(self):
        seq = self._seq_dir("checkruns", [[
            _check_run("build", "completed", "success"),
        ]])
        result = self._run({
            "FAKE_CHECKRUNS_SEQ_DIR": seq,
            "FAKE_ACTIONSRUNS_COUNT": "0",
        })
        self.assertEqual(result.returncode, 1)
        self.assertIn("no check run named", result.stdout)
        self.assertIn("test", result.stdout)

    def test_the_release_run_itself_does_not_count_as_something_still_running(self):
        """This script runs inside the release run, which is in progress the
        whole time, so counting it would make a wrong required_checks name
        wait out the three hour deadline instead of failing at once."""
        seq = self._seq_dir("checkruns", [[
            _check_run("build", "completed", "success"),
        ]])
        result = self._run({
            "FAKE_CHECKRUNS_SEQ_DIR": seq,
            "GITHUB_RUN_ID": "100",
            "FAKE_ACTIONSRUNS_JSON": json.dumps({"workflow_runs": [
                {"id": 100, "status": "in_progress"},
                {"id": 99, "status": "completed"},
            ]}),
        }, required_checks="build|bogus-name")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no check run named bogus-name", result.stdout)
        self.assertNotIn("timed out", result.stdout)

    def test_another_workflow_still_running_on_the_commit_keeps_waiting(self):
        checkruns = self._seq_dir("checkruns", [
            [_check_run("build", "completed", "success")],
            [_check_run("build", "completed", "success")],
            [
                _check_run("build", "completed", "success"),
                _check_run("late", "completed", "success"),
            ],
        ])
        result = self._run({
            "FAKE_CHECKRUNS_SEQ_DIR": checkruns,
            "GITHUB_RUN_ID": "100",
            "FAKE_ACTIONSRUNS_JSON": json.dumps({"workflow_runs": [
                {"id": 100, "status": "in_progress"},
                {"id": 200, "status": "queued"},
            ]}),
        }, required_checks="build|late")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("required checks passed", result.stdout)

    def test_an_absent_check_with_a_run_still_queued_keeps_waiting(self):
        """The distinction bug 1's own gate exists for: absent-and-nothing-
        running is a typo, absent-while-something-is-still-running is a
        queue, and only the first may fail before the deadline.
        """
        checkruns = self._seq_dir("checkruns", [
            [_check_run("build", "completed", "success")],
            [
                _check_run("build", "completed", "success"),
                _check_run("test", "completed", "success"),
            ],
        ])
        actionsruns = self._plain_seq_dir("actionsruns", ["1"])
        result = self._run({
            "FAKE_CHECKRUNS_SEQ_DIR": checkruns,
            "FAKE_ACTIONSRUNS_SEQ_DIR": actionsruns,
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("required checks passed", result.stdout)

    def test_a_newer_green_run_of_the_same_name_from_another_workflow_does_not_mask_a_pending_one(self):
        """Two workflows both made a check named `check`; the newest one was read alone."""
        seq = self._seq_dir("checkruns", [[
            _check_run("check", "in_progress", started_at="2026-01-01T00:00:00Z", suite=1),
            _check_run("check", "completed", "success", started_at="2026-01-01T00:09:00Z", suite=2),
        ]])
        result = self._run({"FAKE_CHECKRUNS_SEQ_DIR": seq}, required_checks="check")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("timed out", result.stdout)
        self.assertNotIn("required checks passed", result.stdout)

    def test_a_newer_green_run_of_the_same_name_from_another_workflow_does_not_mask_a_failure(self):
        seq = self._seq_dir("checkruns", [[
            _check_run("check", "completed", "failure", started_at="2026-01-01T00:00:00Z", suite=1),
            _check_run("check", "completed", "success", started_at="2026-01-01T00:09:00Z", suite=2),
        ]])
        result = self._run({"FAKE_CHECKRUNS_SEQ_DIR": seq}, required_checks="check")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("check:failure", result.stdout)

    def test_a_rerun_in_the_same_suite_replaces_its_failed_attempt(self):
        seq = self._seq_dir("checkruns", [[
            _check_run("check", "completed", "failure", started_at="2026-01-01T00:00:00Z", suite=1),
            _check_run("check", "completed", "success", started_at="2026-01-01T00:09:00Z", suite=1),
        ]])
        result = self._run({"FAKE_CHECKRUNS_SEQ_DIR": seq}, required_checks="check")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_a_tag_works_wherever_a_ref_is_accepted(self):
        """Bug 3 exactly: `actions/runs?head_sha=` accepts a SHA only, so a
        tag passed as REF must be resolved to a SHA before either the
        check-runs read or the actions/runs read uses it.
        """
        seq = self._seq_dir("checkruns", [[
            _check_run("build", "completed", "success"),
        ]])
        result = self._run({
            "REF": "client-v0.21.1",
            "FAKE_RESOLVE_SHA": "resolved0sha",
            "FAKE_CHECKRUNS_SEQ_DIR": seq,
            "FAKE_ACTIONSRUNS_COUNT": "0",
        }, required_checks="build|test")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no check run named", result.stdout)

        calls = self._log()
        resolve_calls = [c for c in calls if "/commits/client-v0.21.1" in c[1]]
        self.assertEqual(len(resolve_calls), 1)

        for c in calls:
            path = c[1]
            if "check-runs" in path or "actions/runs" in path:
                self.assertIn("resolved0sha", path)
                self.assertNotIn("client-v0.21.1", path)

    def test_a_ref_that_does_not_resolve_fails_closed(self):
        result = self._run({
            "REF": "does-not-exist",
            "FAKE_RESOLVE_EXIT": "1",
            "FAKE_RESOLVE_STDERR": "gh: Not Found\n",
        })
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not resolve", result.stdout)

    def test_missing_check_before_the_grace_period_keeps_waiting(self):
        checkruns = self._seq_dir("checkruns", [
            [_check_run("build", "completed", "success")],
            [
                _check_run("build", "completed", "success"),
                _check_run("test", "completed", "success"),
            ],
        ])
        result = self._run({
            "FAKE_CHECKRUNS_SEQ_DIR": checkruns,
            "CREATION_GRACE_SECONDS": "9999",
            "DEADLINE_SECONDS": "9999",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("required checks passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
