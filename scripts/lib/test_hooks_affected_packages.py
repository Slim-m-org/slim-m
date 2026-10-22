# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The pre-push hook tests only the client packages a push can affect."""
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".githooks" / "affected-packages.py"


def affected(*changed):
    out = subprocess.run(
        [sys.executable, str(SCRIPT), str(ROOT)],
        input="\n".join(changed),
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return set(out.split())


class AffectedPackagesTest(unittest.TestCase):
    def test_an_app_change_tests_only_app(self):
        self.assertEqual(affected("client/packages/app/lib/x.dart"), {"client/packages/app"})

    def test_a_dependency_change_also_tests_its_dependents(self):
        got = affected("client/packages/voice_canvas/lib/x.dart")
        self.assertEqual(got, {"client/packages/voice_canvas", "client/packages/app"})

    def test_the_workspace_lockfile_tests_every_package(self):
        got = affected("client/pubspec.lock")
        self.assertIn("client/packages/api", got)
        self.assertIn("client/packages/app", got)

    def test_a_server_only_change_tests_no_client_package(self):
        self.assertEqual(affected("crates/slimm-server/src/lib.rs"), set())


if __name__ == "__main__":
    unittest.main()
