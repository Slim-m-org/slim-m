# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A docs/ci.md row that puts work in a parallel <runner> job names a workflow that has one.

"Parallel" means beside another job on the same kind of runner, so the workflow
needs two of them. The client-ios-ci row kept "in a parallel macOS job" after
that job was folded back into a step of the XCTest job.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from config_source import strip_comments  # noqa: E402
from test_ci_docs_triggers import DOC, ROW, WORKFLOWS  # noqa: E402
from test_windows_builds_do_not_run_under_bash import jobs  # noqa: E402

PARALLEL = re.compile(r"\bin a parallel (macOS|Windows|ubuntu|Linux) job\b", re.I)
RUNNER = {"macos": "macos", "windows": "windows", "ubuntu": "ubuntu", "linux": "ubuntu"}


def jobs_on(workflow: str, runner: str) -> list[str]:
    """Names of the jobs in [workflow] whose `runs-on` names [runner]."""
    return [name for name, body in jobs(strip_comments(workflow)).items()
            if re.search(rf"^    runs-on:.*\b{runner}", body, re.M | re.I)]


def false_claims(doc: str, workflows: dict[str, str]) -> list[str]:
    """`<row>: <claim>` for each parallel job a row names that its workflow lacks."""
    bad = []
    for name, row in ROW.findall(doc):
        for claim in PARALLEL.finditer(row):
            runner = RUNNER[claim.group(1).lower()]
            if len(jobs_on(workflows.get(name, ""), runner)) < 2:
                bad.append(f"{name}: {claim.group(0)}")
    return bad


WORKFLOW = (
    "jobs:\n"
    "  tests:\n"
    "    runs-on: macos-latest\n"
    "  checks:\n"
    "    runs-on: ubuntu-24.04\n"
)
ROW_TEXT = "| `w` | pushes | the tests, and, in a parallel macOS job, a release build |\n"


class CiDocsParallelJobsTest(unittest.TestCase):
    def test_every_parallel_job_a_row_names_exists(self):
        workflows = {p.stem: p.read_text() for p in WORKFLOWS.glob("*.yml")}
        self.assertEqual(false_claims(DOC.read_text(), workflows), [])

    def test_a_step_described_as_a_parallel_job_is_caught(self):
        self.assertEqual(false_claims(ROW_TEXT, {"w": WORKFLOW}), ["w: in a parallel macOS job"])

    def test_a_second_job_on_that_runner_satisfies_it(self):
        two = WORKFLOW + "  release-build:\n    runs-on: macos-latest\n"
        self.assertEqual(false_claims(ROW_TEXT, {"w": two}), [])


if __name__ == "__main__":
    unittest.main()
