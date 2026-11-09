# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The hooks decide which suites a push runs from `matches`, so a long changed-file list must not read as untouched."""

import os
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]

LONG_LIST = (
    "files=(client/packages/app/lib/a.dart); "
    "for i in $(seq 1 5000); do files+=(\"crates/slimm-server/src/f$i.rs\"); done; "
)


def run(body):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k != "SLIMM_HOOK_ENV"}
    script = "set -o pipefail; . .githooks/lib.sh; " + LONG_LIST + body
    return subprocess.run(["bash", "-c", script], cwd=ROOT, env=env, capture_output=True, text=True)


class HookMatchesTest(unittest.TestCase):
    def test_an_early_entry_in_a_long_list_matches_every_time(self):
        result = run("for i in $(seq 1 20); do matches '^client/' files || { echo miss; exit 1; }; done")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_an_absent_pattern_does_not_match(self):
        result = run("matches '^schema/' files && exit 1; exit 0")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
