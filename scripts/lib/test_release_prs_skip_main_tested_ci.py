# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A release-please PR is main plus a version bump, and main's push run already tested that code.

release-please rebases both release PRs onto every push to main, so each merge used to start
these workflows three times at once and fill the runner queue main's own run waited in.
The release gates read the release commit's push run, never the PR's, so the PR runs bought nothing.
Every job here must skip on a `release-please--` head branch, directly or through a job it needs.

One kind of test is not main-tested: a test that reads the version the release PR bumps.
`whats_new_freshness_test.dart` failed 47 release PR runs with main green, by design.
client-ci's `release-version-gates` job runs those on the client release PR, and a client
test that opens a `pubspec.yaml` must be listed there or named below as not reading the version.
"""
import re
import unittest
from pathlib import Path

from dart_source import strip_block_comments
from test_every_workflow_job_has_a_timeout import job_blocks

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
CLIENT = Path(__file__).resolve().parents[2] / "client"
GUARD = "!startsWith(github.head_ref, 'release-please--')"
CLIENT_RELEASE_PR = "startsWith(github.head_ref, 'release-please--') && endsWith(github.head_ref, '--components--client')"

# Open a pubspec.yaml for its asset list or to find the workspace root, or only name it in a message.
VERSION_BLIND = {
    "packages/rtc/test/desktop_dependency_floor_test.dart",
    "packages/app/test/audio/lounge_tracks_assets_test.dart",
    "packages/app/test/gates/presence_fragmentation_gate_test.dart",
}

HEAVY = {
    "android-ci": set(),
    "client-ci": {"update-golden-references", "release-version-gates"},
    "client-ios-ci": set(),
    "client-windows-ci": {"windows-tester-build"},
    "e2e": set(),
    "e2e-playwright": set(),
    "perf": {"baseline"},
    "publish-paths": set(),
    "server-ci": set(),
}


def job_if(lines: list[str]) -> str:
    for line in lines:
        m = re.match(r"^    if:[ \t]*(.*)$", line)
        if m:
            return m.group(1)
    return ""


def job_needs(lines: list[str]) -> list[str]:
    for line in lines:
        m = re.match(r"^    needs:[ \t]*(.*)$", line)
        if m:
            return re.findall(r"[A-Za-z0-9_-]+", m.group(1))
    return []


def unguarded_jobs(text: str, exempt: set[str]) -> list[str]:
    blocks = job_blocks(text)
    guarded: set[str] = set()
    changed = True
    while changed:
        changed = False
        for name, lines in blocks.items():
            if name in guarded:
                continue
            if GUARD in job_if(lines) or any(n in guarded for n in job_needs(lines)):
                guarded.add(name)
                changed = True
    return [n for n in blocks if n not in guarded and n not in exempt]


def tests_opening_a_pubspec(client: Path = CLIENT) -> set[str]:
    found = set()
    for path in client.glob("**/test/**/*.dart"):
        if "pubspec.yaml" in strip_block_comments(path.read_text()):
            found.add(path.relative_to(client).as_posix())
    return found


class ReleasePrsSkipMainTestedCiTest(unittest.TestCase):
    def test_version_reading_tests_still_run_on_the_client_release_pr(self):
        job = "\n".join(job_blocks((WORKFLOWS / "client-ci.yml").read_text())["release-version-gates"])
        self.assertIn(CLIENT_RELEASE_PR, job_if(job.splitlines()))
        for test in sorted(tests_opening_a_pubspec() - VERSION_BLIND):
            with self.subTest(test=test):
                self.assertTrue(test.startswith("packages/app/"), "the job runs in packages/app")
                self.assertIn(test.removeprefix("packages/app/"), job)

    def test_version_blind_names_real_tests(self):
        self.assertEqual(VERSION_BLIND - tests_opening_a_pubspec(), set())

    def test_every_heavy_job_skips_release_prs(self):
        for name, exempt in HEAVY.items():
            with self.subTest(workflow=name):
                text = (WORKFLOWS / f"{name}.yml").read_text()
                self.assertEqual(unguarded_jobs(text, exempt), [])

    def test_exemptions_name_real_jobs(self):
        for name, exempt in HEAVY.items():
            with self.subTest(workflow=name):
                jobs = job_blocks((WORKFLOWS / f"{name}.yml").read_text())
                self.assertEqual(exempt - set(jobs), set())

    def test_the_gate_follows_needs(self):
        text = (
            "jobs:\n"
            f"  a:\n    if: ${{{{ {GUARD} }}}}\n    runs-on: x\n"
            "  b:\n    needs: [a]\n    runs-on: x\n"
            "  c:\n    needs: b\n    runs-on: x\n"
            "  d:\n    runs-on: x\n"
        )
        self.assertEqual(unguarded_jobs(text, set()), ["d"])


if __name__ == "__main__":
    unittest.main()
