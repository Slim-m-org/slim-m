# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/commit-perf-baseline.sh.

Drives the real script against a throwaway bare remote whose pre-receive hook
stands in for GitHub: it can refuse pushes to main the way a ruleset does
(GH013), or fail them the way a lost race does. `gh` is a recording fake.
"""
import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "commit-perf-baseline.sh"
PERF = ROOT / ".github" / "workflows" / "perf.yml"

RULESET_REFUSAL = "remote: error: GH013: Repository rule violations found for refs/heads/main."

FAKE_GH = """#!/usr/bin/env bash
echo "GH_TOKEN=$GH_TOKEN $*" >> "$FAKE_GH_LOG"
case "$1 $2" in
  "pr list") echo "${FAKE_OPEN_PRS:-0}" ;;
  "pr merge") [ -z "${FAKE_NO_AUTO_MERGE:-}" ] || { echo "auto merge is not allowed" >&2; exit 1; } ;;
esac
"""

# Refuses main while the counter file holds attempts left to refuse; the message is the test's choice.
HOOK = """#!/usr/bin/env bash
while read -r old new ref; do
  [ "$ref" = refs/heads/main ] || continue
  left="$(cat "$REFUSALS" 2>/dev/null || echo 0)"
  [ "$left" -gt 0 ] || continue
  echo $((left - 1)) > "$REFUSALS"
  echo "$REFUSAL_MESSAGE" >&2
  exit 1
done
"""


def run(*args, cwd, env=None):
    return subprocess.run(args, cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


class CommitPerfBaselineTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        self.remote, self.clone, self.bin = tmp / "remote.git", tmp / "clone", tmp / "bin"
        self.refusals = tmp / "refusals"
        self.gh_log = tmp / "gh.log"
        self.gh_log.touch()
        self.bin.mkdir()
        gh = self.bin / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)

        run("git", "init", "-q", "--bare", "-b", "main", str(self.remote), cwd=tmp)
        hook = self.remote / "hooks" / "pre-receive"
        hook.write_text(HOOK)
        hook.chmod(hook.stat().st_mode | stat.S_IEXEC)
        run("git", "clone", "-q", str(self.remote), str(self.clone), cwd=tmp)
        self._git("config", "user.name", "test")
        self._git("config", "user.email", "test@example.invalid")
        (self.clone / "perf" / "baselines").mkdir(parents=True)
        (self.clone / "perf" / "baselines" / "0.1.0.json").write_text("{}\n")
        self._git("add", "-A")
        self._git("commit", "-q", "-m", "seed")
        self._git("push", "-q", "origin", "HEAD:main")
        (self.clone / "baseline-0.2.0.json").write_text('{"version": "0.2.0"}\n')

    def _git(self, *args):
        return run("git", *args, cwd=self.clone)

    def _remote_ref(self, ref):
        result = subprocess.run(
            ["git", "rev-parse", "--verify", "-q", ref], cwd=self.remote, capture_output=True, text=True
        )
        return result.stdout.strip() or None

    def _run(self, refuse=0, message=RULESET_REFUSAL, **extra):
        self.refusals.write_text(str(refuse))
        env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FAKE_GH_LOG": str(self.gh_log),
            "REFUSALS": str(self.refusals),
            "REFUSAL_MESSAGE": message,
            "RETRY_SLEEP_UNIT": "0",
            "GH_TOKEN": "workflow-token",
            **extra,
        }
        return subprocess.run(
            ["bash", str(SCRIPT), "0.2.0", "baseline-0.2.0.json"],
            cwd=self.clone, env=env, capture_output=True, text=True,
        )

    def _gh_calls(self):
        return self.gh_log.read_text().splitlines()

    def _main_has_the_baseline(self):
        shown = subprocess.run(
            ["git", "show", "main:perf/baselines/0.2.0.json"], cwd=self.remote, capture_output=True, text=True
        )
        return shown.returncode == 0

    def test_an_open_main_gets_the_baseline_pushed_straight_to_it(self):
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self._main_has_the_baseline())
        self.assertEqual(self._gh_calls(), [])

    def test_a_baseline_already_on_main_is_left_alone(self):
        self._run()
        before = self._remote_ref("main")
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already on main", result.stdout)
        self.assertEqual(self._remote_ref("main"), before)

    def test_a_lost_race_is_retried_until_the_push_lands(self):
        result = self._run(refuse=2, message="! [remote rejected] main -> main (fetch first)")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self._main_has_the_baseline())
        self.assertEqual(self._gh_calls(), [])

    def test_a_push_that_never_lands_fails_without_a_pull_request(self):
        result = self._run(refuse=99, message="! [remote rejected] main -> main (fetch first)")
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::could not push", result.stdout)
        self.assertFalse(self._main_has_the_baseline())
        self.assertEqual(self._gh_calls(), [])

    def test_a_ruleset_refusal_opens_a_pull_request_instead(self):
        result = self._run(refuse=99, PR_TOKEN="pat")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self._main_has_the_baseline())
        branch = self._remote_ref("refs/heads/perf-baseline-0.2.0")
        self.assertIsNotNone(branch)
        self.assertIn("0.2.0.json", run("git", "show", "--stat", branch, cwd=self.remote))
        create = [call for call in self._gh_calls() if " pr create " in call]
        self.assertEqual(len(create), 1)
        self.assertIn("--base main --head perf-baseline-0.2.0", create[0])
        self.assertIn("--title chore(perf): baseline 0.2.0", create[0])
        self.assertTrue(any(" pr merge perf-baseline-0.2.0 --squash --auto" in call for call in self._gh_calls()))

    def test_a_ruleset_refusal_does_not_burn_the_retries(self):
        self._run(refuse=99, PR_TOKEN="pat")
        self.assertEqual(self.refusals.read_text().strip(), "98")

    def test_a_branch_protection_refusal_falls_back_the_same_way(self):
        result = self._run(refuse=99, message="remote: error: GH006: Protected branch update failed for refs/heads/main.")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(" pr create " in call for call in self._gh_calls()))

    def test_the_pull_request_uses_the_pat_when_there_is_one(self):
        self._run(refuse=99, PR_TOKEN="pat")
        self.assertTrue(all(call.startswith("GH_TOKEN=pat ") for call in self._gh_calls()))

    def test_the_pull_request_falls_back_to_the_workflow_token(self):
        self._run(refuse=99)
        self.assertTrue(all(call.startswith("GH_TOKEN=workflow-token ") for call in self._gh_calls()))

    def test_an_open_pull_request_is_not_opened_twice(self):
        result = self._run(refuse=99, FAKE_OPEN_PRS="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(" pr create " in call for call in self._gh_calls()))

    def test_a_repository_without_auto_merge_leaves_the_pull_request_open(self):
        result = self._run(refuse=99, FAKE_NO_AUTO_MERGE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::notice::perf-baseline-0.2.0 is open and needs merging by hand", result.stdout)


class PerfWorkflowUsesTheScriptTest(unittest.TestCase):
    def setUp(self):
        text = PERF.read_text()
        self.step = text[text.index("      - name: commit it to main"):]

    def test_the_step_runs_the_script_from_the_workflows_own_commit(self):
        self.assertIn('git show "${GITHUB_SHA}:scripts/commit-perf-baseline.sh"', self.step)
        self.assertRegex(self.step, r'bash "\$\{RUNNER_TEMP\}/commit-perf-baseline\.sh" "\$VERSION" "baseline-\$\{VERSION\}\.json"')

    def test_the_step_can_open_a_pull_request_as_the_pat(self):
        self.assertIn("PR_TOKEN: ${{ secrets.RELEASE_PLEASE_TOKEN }}", self.step)
        self.assertIn("GH_TOKEN: ${{ github.token }}", self.step)
        self.assertRegex(PERF.read_text(), r"permissions:\n      contents: write\n      pull-requests: write")

    def test_no_workflow_pushes_to_main_outside_the_script(self):
        for path in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
            with self.subTest(workflow=path.name):
                self.assertIsNone(re.search(r"git push[^\n]*(HEAD:main|origin main)", path.read_text()))


if __name__ == "__main__":
    unittest.main()
