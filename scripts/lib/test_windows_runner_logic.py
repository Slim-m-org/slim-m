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
    def test_every_runner_logic_test_passes(self):
        compiler = shutil.which("g++")
        if compiler is None:
            self.skipTest("no g++ on this machine")
        sources = sorted((RUNNER / "test").glob("*_test.cpp"))
        self.assertGreaterEqual(len(sources), 2)
        for source in sources:
            with self.subTest(source.name), tempfile.TemporaryDirectory() as scratch:
                binary = Path(scratch) / source.stem
                build = subprocess.run(
                    [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-o", str(binary), str(source)],
                    capture_output=True, text=True, timeout=120,
                )
                self.assertEqual(build.returncode, 0, build.stderr)
                run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
                self.assertEqual(run.returncode, 0, run.stderr)

if __name__ == "__main__":
    unittest.main()
