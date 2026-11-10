# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The pre-push hook tests only the client packages a push can affect."""
import re
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dart_source import strip_block_comments  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".githooks" / "affected-packages.py"
# A schema/openapi.yaml existsSync is only how a test finds the repo root, not a read of the schema.
OUTSIDE_READ = re.compile(
    r"(?:(?:\.\./){2,3}|\}/)((?:crates|docs|packaging|schema)/[\w./-]+\.\w+)(?![\w./-])(?!['\"]\)\.existsSync)"
)


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

    def test_the_schema_tests_the_api_package_but_not_its_dependents(self):
        self.assertEqual(affected("schema/openapi.yaml"), {"client/packages/api"})

    def test_a_shared_server_fixture_tests_the_app_package(self):
        self.assertEqual(affected("crates/slimm-server/tests/fixtures/hidden_chars.json"), {"client/packages/app"})

    def test_every_repo_file_a_client_test_reads_triggers_that_package(self):
        reads = []
        for test in sorted((ROOT / "client" / "packages").glob("*/test/**/*.dart")):
            for path in OUTSIDE_READ.findall(strip_block_comments(test.read_text())):
                reads.append((test.relative_to(ROOT).parts[2], path))
        self.assertTrue(reads, "the scan found no outside read, so its pattern is stale")
        for package, path in sorted(set(reads)):
            with self.subTest(package=package, path=path):
                self.assertIn(f"client/packages/{package}", affected(path))


if __name__ == "__main__":
    unittest.main()
