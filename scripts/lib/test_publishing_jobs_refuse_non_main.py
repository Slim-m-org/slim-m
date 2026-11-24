# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A hand-run dispatch from a branch must never publish that branch; only main may.

main-builds and copr-catch-up can be dispatched on any ref. Branch test builds stay artifact-only,
so every job that pushes outside GitHub artifacts has to refuse a ref other than refs/heads/main.
"""
import re
import unittest
from pathlib import Path

from test_every_workflow_job_has_a_timeout import job_blocks

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
MAIN_REF = "github.ref == 'refs/heads/main'"
REFUSE = "github.ref != 'refs/heads/main'"
PUBLISHING = re.compile(
    r"packages: write"
    r"|uses: \./\.github/workflows/(?:web-image|copr-publish)\.yml"
    r"|uses: \./\.github/actions/release-ios-testflight"
    r"|secrets\.COPR_CONFIG"
)
CHECKED = ("main-builds", "copr-catch-up")


def job_if(lines: list[str]) -> str:
    for line in lines:
        m = re.match(r"^    if:[ \t]*(.*)$", line)
        if m:
            return m.group(1)
    return ""


def refuses_non_main(lines: list[str]) -> bool:
    if MAIN_REF in job_if(lines):
        return True
    body = "\n".join(lines)
    return REFUSE in body and "exit 1" in body


def unguarded_publishers(text: str) -> list[str]:
    return [n for n, lines in job_blocks(text).items() if PUBLISHING.search("\n".join(lines)) and not refuses_non_main(lines)]


class PublishingJobsRefuseNonMainTest(unittest.TestCase):
    def test_every_publishing_job_refuses_a_ref_other_than_main(self):
        for name in CHECKED:
            with self.subTest(workflow=name):
                self.assertEqual(unguarded_publishers((WORKFLOWS / f"{name}.yml").read_text()), [])

    def test_the_checked_workflows_have_publishing_jobs(self):
        for name in CHECKED:
            blocks = job_blocks((WORKFLOWS / f"{name}.yml").read_text())
            self.assertTrue(any(PUBLISHING.search("\n".join(b)) for b in blocks.values()), name)

    def test_the_gate_flags_a_publisher_without_the_guard(self):
        text = (
            "jobs:\n"
            "  ok:\n    if: github.ref == 'refs/heads/main'\n    permissions:\n      packages: write\n"
            "  bad:\n    permissions:\n      packages: write\n"
            "  artifact:\n    runs-on: x\n"
        )
        self.assertEqual(unguarded_publishers(text), ["bad"])


if __name__ == "__main__":
    unittest.main()
