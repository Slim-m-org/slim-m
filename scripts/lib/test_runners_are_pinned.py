# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""No workflow may name the floating `ubuntu-latest` runner label.

GitHub moves `ubuntu-latest` to Ubuntu 26 on 2026-10-19, which changes the
glibc floor of the Linux tarball and rpm built on the runner and splits the
amd64 legs from the arm64 ones pinned to `ubuntu-24.04-arm`. The label is
checked in `runs-on:` and in the `runner:` matrix values that feed it, so a
publishing workflow can never pick up a new image without a deliberate PR.
`macos-latest` is not covered: see `docs/ci.md`.
"""
import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"

FLOATING = re.compile(
    r"^\s*(?:-\s+)?(?:runs-on|runner):\s*\[?\s*[\"']?(?:ubuntu|windows)-latest\b", re.M
)


def floating_labels(text: str) -> list[str]:
    """Each `runs-on` or `runner` line that names `ubuntu-latest`."""
    return [m.group(0).strip() for m in FLOATING.finditer(text)]


class RunnersArePinnedTest(unittest.TestCase):
    def test_no_workflow_names_ubuntu_latest(self):
        paths = sorted(WORKFLOWS.glob("*.yml"))
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(workflow=path.name):
                self.assertEqual(floating_labels(path.read_text()), [])

    def test_a_floating_runs_on_is_seen(self):
        bad = "jobs:\n  build:\n    runs-on: ubuntu-latest\n"
        self.assertEqual(len(floating_labels(bad)), 1)

    def test_a_floating_matrix_runner_is_seen(self):
        bad = (
            "        include:\n"
            "          - arch: amd64\n"
            "            runner: ubuntu-latest\n"
            "          - arch: arm64\n"
            "            runner: ubuntu-24.04-arm\n"
        )
        self.assertEqual(len(floating_labels(bad)), 1)

    def test_a_floating_windows_runner_is_seen(self):
        bad = "    runs-on: windows-latest\n"
        self.assertEqual(len(floating_labels(bad)), 1)

    def test_a_list_form_is_seen(self):
        bad = "    runs-on: [ubuntu-latest]\n"
        self.assertEqual(len(floating_labels(bad)), 1)

    def test_pinned_labels_are_allowed(self):
        good = (
            "    runs-on: ubuntu-24.04\n"
            "    runs-on: ubuntu-24.04-arm\n"
            "    runs-on: windows-2025\n"
            "    runs-on: ${{ matrix.runner }}\n"
            "    # ubuntu-latest is mentioned only in a comment\n"
        )
        self.assertEqual(floating_labels(good), [])


if __name__ == "__main__":
    unittest.main()
