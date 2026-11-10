# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The Windows runner's pure logic, compiled and run with a plain C++ compiler.

The runner itself only builds on Windows, so the rules that need no Windows API
(which modifiers a hotkey chord accepts, how long a clipboard open is retried)
live in headers of their own and run here.
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[2] / "client/packages/app/windows/runner"


class WindowsRunnerLogicTest(unittest.TestCase):
    def test_the_runner_logic_tests_pass(self):
        compiler = shutil.which("g++")
        if compiler is None:
            self.skipTest("no g++ on this machine")
        with tempfile.TemporaryDirectory() as scratch:
            binary = Path(scratch) / "runner_logic_test"
            build = subprocess.run(
                [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-o", str(binary),
                 str(RUNNER / "test/runner_logic_test.cpp")],
                capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(build.returncode, 0, build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stderr)


if __name__ == "__main__":
    unittest.main()
