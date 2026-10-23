# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A job with no `timeout-minutes` inherits GitHub's 360 minute default.

A hung apt mirror or a wedged simulator then holds a required check, a release or
a billed macOS runner for six hours. Every job in every workflow must say how long
it may run. A job that calls a reusable workflow (`uses:`) cannot carry the key:
the callee's own jobs do.
"""
import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


def job_blocks(text: str) -> dict[str, list[str]]:
    start = re.search(r"^jobs:[ \t]*\n", text, re.M)
    if not start:
        return {}
    blocks: dict[str, list[str]] = {}
    current = None
    for line in text[start.end():].splitlines():
        if line and not line[0].isspace() and not line.startswith("#"):
            break
        header = re.match(r"^  ([A-Za-z0-9_-]+):[ \t]*(#.*)?$", line)
        if header:
            current = header.group(1)
            blocks[current] = []
        elif current is not None:
            blocks[current].append(line)
    return blocks


def jobs_without_timeout(text: str) -> list[str]:
    missing = []
    for name, lines in job_blocks(text).items():
        body = "\n".join(lines)
        if re.search(r"^    uses:", body, re.M):
            continue
        if not re.search(r"^    timeout-minutes:[ \t]*\S", body, re.M):
            missing.append(name)
    return missing


class EveryWorkflowJobHasATimeoutTest(unittest.TestCase):
    def test_every_job(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            with self.subTest(workflow=path.name):
                self.assertEqual(jobs_without_timeout(path.read_text()), [])

    def test_the_gate_reads_jobs_correctly(self):
        text = (
            "name: x\njobs:\n"
            "  slow:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: timeout-minutes: 5\n"
            "  bounded:\n    runs-on: ubuntu-24.04\n    timeout-minutes: 10\n"
            "  reusable:\n    uses: ./.github/workflows/web-image.yml\n"
            "  # a comment between jobs\n"
            "  also-slow:\n    runs-on: ubuntu-24.04\n"
        )
        self.assertEqual(jobs_without_timeout(text), ["slow", "also-slow"])

    def test_a_step_level_timeout_does_not_count(self):
        text = "jobs:\n  a:\n    runs-on: x\n    steps:\n      - uses: y\n        timeout-minutes: 5\n"
        self.assertEqual(jobs_without_timeout(text), ["a"])


if __name__ == "__main__":
    unittest.main()
