# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""scripts/chrome-tests.sh gives each CI leg its own files, so together the legs run every listed file exactly once."""

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "chrome-tests.sh"
LIST = ROOT / "client" / "chrome-tests.txt"

# Records the package it ran in and the files it was handed, one line per file.
FAKE_FLUTTER = 'pkg=$(basename "$PWD"); shift 4; for f in "$@"; do echo "$pkg/$f" >> "$RAN"; done\n'


def run_leg(leg):
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = Path(tmp) / "bin"
        bin_dir.mkdir()
        flutter = bin_dir / "flutter"
        flutter.write_text("#!/usr/bin/env bash\n" + FAKE_FLUTTER)
        flutter.chmod(flutter.stat().st_mode | stat.S_IXUSR)
        ran = Path(tmp) / "ran"
        ran.write_text("")
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", RAN=str(ran))
        env.pop("CHROME_LEG", None)
        if leg is not None:
            env["CHROME_LEG"] = leg
        result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
        return result.returncode, ran.read_text().split()


class ChromeTestLegs(unittest.TestCase):
    def listed(self):
        return [line.strip() for line in LIST.read_text().splitlines() if line.strip()]

    def test_two_legs_run_every_file_once_and_split_it_evenly(self):
        code1, first = run_leg("1/2")
        code2, second = run_leg("2/2")
        self.assertEqual((code1, code2), (0, 0))
        self.assertFalse(set(first) & set(second))
        self.assertEqual(sorted(first + second), sorted(self.listed()))
        self.assertLessEqual(abs(len(first) - len(second)), 1)

    def test_no_leg_runs_the_whole_list(self):
        code, ran = run_leg(None)
        self.assertEqual(code, 0)
        self.assertEqual(sorted(ran), sorted(self.listed()))

    def test_a_malformed_or_out_of_range_leg_is_refused(self):
        for leg in ("0/2", "3/2", "2", "a/b", "1/0"):
            with self.subTest(leg=leg):
                self.assertEqual(run_leg(leg)[0], 2)


if __name__ == "__main__":
    unittest.main()
