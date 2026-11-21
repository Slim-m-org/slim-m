# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A release-please PR is main plus a version bump, and main's push run already tested that code.

release-please rebases both release PRs onto every push to main, so each merge used to start
these workflows three times at once and fill the runner queue main's own run waited in.
The release gates read the release commit's push run, never the PR's, so the PR runs bought nothing.
Every job here must skip on a `release-please--` head branch, directly or through a job it needs.
"""
import re
import unittest
from pathlib import Path

from test_every_workflow_job_has_a_timeout import job_blocks

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
GUARD = "!startsWith(github.head_ref, 'release-please--')"

HEAVY = {
    "android-ci": set(),
    "client-ci": {"update-golden-references"},
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


class ReleasePrsSkipMainTestedCiTest(unittest.TestCase):
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
