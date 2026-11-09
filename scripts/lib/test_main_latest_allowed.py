# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/main-latest-allowed.sh.

Drives the real script through `bash` with a fake `gh` on PATH, including the
stale re-run that moved :latest backwards onto an older commit, and pins the
workflow wiring that makes main-builds ask the script before it tags.
"""
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "main-latest-allowed.sh"
MAIN_BUILDS = ROOT / ".github" / "workflows" / "main-builds.yml"

OLD, HELD, NEW = "a" * 40, "b" * 40, "c" * 40
IMAGE = "ghcr.io/slim-m-org/slim-m-server"

FAKE_GH = """#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_LOG"
case "$*" in
  *"/versions"*)
    if [ -n "${FAKE_VERSIONS_MISSING:-}" ] && [[ "$*" == *"$FAKE_VERSIONS_MISSING"* ]]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    if [ -n "${FAKE_VERSIONS_FAIL:-}" ]; then echo "gh: rate limit exceeded" >&2; exit 1; fi
    printf '%s' "${FAKE_LATEST_TAGS:-}" ;;
  *"/compare/"*)
    if [ -n "${FAKE_COMPARE_FAIL:-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    echo "${FAKE_COMPARE_STATUS:-ahead}" ;;
esac
"""


class MainLatestAllowedTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        tmp = Path(self._tmp.name)
        fake = tmp / "gh"
        fake.write_text(FAKE_GH)
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.log = tmp / "gh.log"
        self.log.touch()

    def _run(self, commit=NEW, **fake):
        env = {
            "PATH": f"{self._tmp.name}:/usr/bin:/bin",
            "GITHUB_REPOSITORY": "Slim-m-org/slim-m",
            "FAKE_GH_LOG": str(self.log),
            **{f"FAKE_{key.upper()}": value for key, value in fake.items()},
        }
        result = subprocess.run(
            ["bash", str(SCRIPT), IMAGE, commit], env=env, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip(), result.stderr

    def _calls(self):
        return self.log.read_text().splitlines()

    def test_a_commit_ahead_of_latest_may_move_it(self):
        answer, _ = self._run(latest_tags=f"sha-{HELD}\nlatest\nmain\n", compare_status="ahead")
        self.assertEqual(answer, "true")
        self.assertIn(f"repos/Slim-m-org/slim-m/compare/{HELD}...{NEW}", self._calls()[-1])

    def test_a_stale_re_run_behind_latest_is_refused(self):
        answer, err = self._run(commit=OLD, latest_tags=f"sha-{HELD}\nlatest\n", compare_status="behind")
        self.assertEqual(answer, "false")
        self.assertIn("::warning::", err)
        self.assertIn("behind", err)

    def test_a_diverged_commit_is_refused(self):
        answer, _ = self._run(latest_tags=f"sha-{HELD}\nlatest\n", compare_status="diverged")
        self.assertEqual(answer, "false")

    def test_the_commit_latest_already_holds_may_be_republished_without_a_compare(self):
        answer, _ = self._run(commit=HELD, latest_tags=f"sha-{HELD}\nlatest\n")
        self.assertEqual(answer, "true")
        self.assertFalse([call for call in self._calls() if "/compare/" in call])

    def test_an_identical_status_is_allowed(self):
        answer, _ = self._run(latest_tags=f"sha-{HELD}\nlatest\n", compare_status="identical")
        self.assertEqual(answer, "true")

    def test_only_the_version_tagged_latest_is_read(self):
        self._run(latest_tags=f"sha-{HELD}\nlatest\n")
        self.assertIn("select(.metadata.container.tags | index(\"latest\"))", self._calls()[0])

    def test_a_first_publish_with_nothing_tagged_latest_is_allowed(self):
        answer, _ = self._run(latest_tags="")
        self.assertEqual(answer, "true")
        self.assertFalse([call for call in self._calls() if "/compare/" in call])

    def test_a_latest_with_no_commit_tag_is_allowed(self):
        answer, _ = self._run(latest_tags="latest\nmain\n0.90.0\n")
        self.assertEqual(answer, "true")

    def test_an_unreadable_listing_fails_open_with_a_warning(self):
        answer, err = self._run(versions_fail="1")
        self.assertEqual(answer, "true")
        self.assertIn("::warning::could not list published tags", err)
        self.assertIn("rate limit exceeded", err)

    def test_a_user_owned_image_is_read_from_users_after_orgs_404s(self):
        answer, _ = self._run(
            commit=OLD, latest_tags=f"sha-{HELD}\nlatest\n", compare_status="behind", versions_missing="orgs/"
        )
        self.assertEqual(answer, "false")
        paths = [call.split()[2] for call in self._calls() if "/versions" in call]
        self.assertEqual(
            paths,
            ["orgs/slim-m-org/packages/container/slim-m-server/versions",
             "users/slim-m-org/packages/container/slim-m-server/versions"],
        )

    def test_a_failed_compare_fails_open_with_a_warning(self):
        answer, err = self._run(latest_tags=f"sha-{HELD}\nlatest\n", compare_fail="1")
        self.assertEqual(answer, "true")
        self.assertIn("::warning::could not compare", err)

    def test_a_malformed_sha_tag_is_not_taken_for_a_commit(self):
        answer, _ = self._run(latest_tags="sha-abc\nlatest\n", compare_status="behind")
        self.assertEqual(answer, "true")
        self.assertFalse([call for call in self._calls() if "/compare/" in call])


def server_image_job(text: str) -> str:
    match = re.search(r"^  server-image:\n(.*?)(?=^  [a-z-]+:\n)", text, re.M | re.S)
    assert match, "server-image job not found in main-builds.yml"
    return match.group(1)


class MainBuildsAsksBeforeTaggingTest(unittest.TestCase):
    def setUp(self):
        self.job = server_image_job(MAIN_BUILDS.read_text())

    def test_the_sha_tag_is_unconditional_and_main_and_latest_follow_the_script(self):
        tags = re.search(r"^\s+tags: \|\n((?:\s{12}.*\n)+)", self.job, re.M).group(1).splitlines()
        self.assertIn("sha-${{ github.sha }}", tags[0])
        self.assertNotIn("steps.", tags[0])
        for line, name in zip(tags[1:], ("main", "latest")):
            self.assertIn("steps.move.outputs.allowed == 'true'", line)
            self.assertIn(f":{name}'", line)
        self.assertEqual(len(tags), 3)

    def test_the_script_runs_before_the_build_pushes(self):
        self.assertLess(self.job.index("scripts/main-latest-allowed.sh"), self.job.index("docker/build-push-action"))
        self.assertIn("id: move", self.job)

    def test_a_ref_other_than_main_fails_the_job_before_anything_is_built(self):
        guard = self.job.index("github.ref != 'refs/heads/main'")
        self.assertLess(guard, self.job.index("actions/checkout"))
        self.assertIn("exit 1", self.job[guard : self.job.index("name: name the image")])


if __name__ == "__main__":
    unittest.main()
