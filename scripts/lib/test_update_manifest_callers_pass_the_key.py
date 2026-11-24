# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A called workflow only sees secrets that are passed to it, so every caller of
update-manifest must pass UPDATE_SIGNING_KEY while it is a repository secret.
"""
import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
CALLEE = "./.github/workflows/update-manifest.yml"
KEY = "UPDATE_SIGNING_KEY"


def _jobs(text):
    """Maps each job name to its lines, cutting at the two-space-indented keys under `jobs:`."""
    jobs, current, in_jobs = {}, None, False
    for line in text.splitlines():
        if re.match(r"^jobs:\s*$", line):
            in_jobs = True
        elif in_jobs and re.match(r"^\S", line) and not line.startswith("#"):
            in_jobs = False
        elif in_jobs and (key := re.match(r"^  ([\w-]+):\s*$", line)):
            current = key.group(1)
            jobs[current] = []
        elif in_jobs and current:
            jobs[current].append(line)
    return jobs


def _passes_key(lines):
    """True when the job has a `secrets:` map at job level that lists the key."""
    for index, line in enumerate(lines):
        if re.match(r"^    secrets:\s*$", line):
            for entry in lines[index + 1:]:
                if re.match(r"^      \S", entry) and entry.strip().startswith(f"{KEY}:"):
                    return True
                if entry.strip() and not entry.startswith("      "):
                    break
    return False


class UpdateManifestCallersPassTheKey(unittest.TestCase):
    def test_callee_declares_the_secret(self):
        text = (WORKFLOWS / "update-manifest.yml").read_text()
        match = re.search(r"workflow_call:\n(?:(?:[ ]{4,}.*|\s*)\n)*?[ ]{4}secrets:\n[ ]{6}" + KEY + ":", text)
        self.assertIsNotNone(match)

    def test_every_caller_passes_it(self):
        callers = 0
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for name, lines in _jobs(path.read_text()).items():
                if not any(line.strip() == f"uses: {CALLEE}" for line in lines):
                    continue
                callers += 1
                self.assertTrue(_passes_key(lines), f"{path.name}:{name}")
        self.assertGreaterEqual(callers, 2)

    def test_the_parser_sees_a_missing_key(self):
        text = "jobs:\n  a:\n    uses: x\n    secrets:\n      OTHER: 1\n"
        self.assertFalse(_passes_key(_jobs(text)["a"]))


if __name__ == "__main__":
    unittest.main()
