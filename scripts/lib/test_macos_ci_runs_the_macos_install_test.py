# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The macOS-only self-update test needs a macOS runner to ever run.

`macos_install_test.dart` skips its real `ditto`/`codesign` case everywhere but
macOS, and every ubuntu shard skips it. docs/ci.md says `client-macos-ci` runs
it, so this fails if that workflow stops doing so.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TEST = "test/desktop/self_update/macos_install_test.dart"
WORKFLOW = ROOT / ".github" / "workflows" / "client-macos-ci.yml"


def run_lines(text: str) -> list[str]:
    return re.findall(r"^\s+run:\s*(.+)$", text, re.M)


class MacosCiRunsTheMacosInstallTestTest(unittest.TestCase):
    def test_the_test_file_exists_and_skips_off_macos(self):
        source = (ROOT / "client/packages/app" / TEST).read_text()
        self.assertIn("Platform.isMacOS ? false", source)

    def test_the_macos_job_runs_it_from_the_app_package(self):
        text = WORKFLOW.read_text()
        step = re.search(r"- name: macos self-update install test\n((?:        .*\n)+)", text)
        self.assertIsNotNone(step, "client-macos-ci has no step running the macOS install test")
        self.assertIn("working-directory: client/packages/app", step.group(1))
        self.assertIn(f"flutter test {TEST}", run_lines(step.group(1)))


if __name__ == "__main__":
    unittest.main()
