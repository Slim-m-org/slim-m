# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-migration-versions.py.

The script finds the lockfile relative to its own location and the migrations
relative to the working directory, so each test builds a small repo layout and
runs a copy of the script inside it.
"""
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent


def digest(body: str) -> str:
    return hashlib.sha384(body.encode()).hexdigest()


class CheckMigrationVersionsTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "scripts" / "lib").mkdir(parents=True)
        shutil.copy(SCRIPTS / "check-migration-versions.py", self.root / "scripts")
        shutil.copy(SCRIPTS / "lib" / "migration_files.py", self.root / "scripts" / "lib")
        self.server = self.root / "crates" / "slimm-server"
        self.migrations = self.server / "migrations"
        self.migrations.mkdir(parents=True)

    def _migration(self, name, body="select 1;"):
        (self.migrations / name).write_text(body)

    def _lock(self, **entries):
        (self.server / "migrations.lock.json").write_text(json.dumps(entries))

    def _run(self):
        return subprocess.run(
            [sys.executable, str(self.root / "scripts" / "check-migration-versions.py")],
            cwd=self.root, capture_output=True, text=True)

    def test_consistent_migrations_pass(self):
        self._migration("0001_init.sql", "a")
        self._migration("0002_more.sql", "b")
        self._lock(**{"0001_init.sql": digest("a")})
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("all consistent", result.stdout)

    def test_a_duplicate_version_fails(self):
        self._migration("0007_a.sql")
        self._migration("0007_b.sql")
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("migration 0007 is claimed by 2 files", result.stdout)

    def test_a_locked_migration_that_was_deleted_fails(self):
        self._migration("0002_more.sql", "b")
        self._lock(**{"0001_init.sql": digest("a")})
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("0001_init.sql) is locked and has been deleted", result.stdout)

    def test_a_locked_migration_edited_in_place_fails(self):
        self._migration("0001_init.sql", "changed")
        self._lock(**{"0001_init.sql": digest("a")})
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("edited in place", result.stdout)

    def test_a_locked_migration_that_was_renamed_fails(self):
        self._migration("0001_renamed.sql", "changed")
        self._lock(**{"0001_init.sql": digest("a")})
        result = self._run()
        self.assertEqual(result.returncode, 1)
        self.assertIn("renamed to 0001_renamed.sql", result.stdout)

    def test_a_rename_that_keeps_the_bytes_passes_because_sqlx_keys_on_them(self):
        self._migration("0001_renamed.sql", "a")
        self._lock(**{"0001_init.sql": digest("a")})
        self.assertEqual(self._run().returncode, 0)

    def test_a_missing_lockfile_still_checks_duplicates(self):
        self._migration("0001_init.sql")
        result = self._run()
        self.assertEqual(result.returncode, 0)
        self.assertIn("migrations.lock.json missing", result.stdout)

    def test_a_missing_migrations_directory_fails(self):
        shutil.rmtree(self.migrations)
        self.assertEqual(self._run().returncode, 1)


if __name__ == "__main__":
    unittest.main()
