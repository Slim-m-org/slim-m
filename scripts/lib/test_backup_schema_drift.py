# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The backup fixture follows the real migrations, so a column rename is caught here."""
import argparse
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_fixtures as fixtures  # noqa: E402
import backup_lib  # noqa: E402
import restore_drill_lib  # noqa: E402

COLUMNS_READ = {
    "users": ("id", "username", "avatar_updated_at"),
    "attachments": ("sha256", "size"),
}


class BackupSchemaDriftTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def _renamed_migrations(self, old, new):
        copy = self.root / "migrations"
        shutil.copytree(fixtures.MIGRATIONS_DIR, copy)
        for migration in copy.glob("*.sql"):
            text = migration.read_text()
            if old in text:
                migration.write_text(text.replace(old, new))
        return copy

    def test_fixture_database_holds_every_column_the_backup_reads(self):
        fixtures.build_database(self.root / "live.db")
        conn = sqlite3.connect(self.root / "live.db")
        try:
            for table, columns in COLUMNS_READ.items():
                have = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
                self.assertLessEqual(set(columns), have, table)
        finally:
            conn.close()

    def test_a_renamed_avatar_column_fails_the_fixture_build(self):
        migrations = self._renamed_migrations("avatar_updated_at", "avatar_changed_at")
        with self.assertRaises(sqlite3.OperationalError):
            fixtures.build_database(self.root / "live.db", migrations_dir=migrations)

    def test_the_libraries_still_query_a_database_built_from_the_real_migrations(self):
        fixtures.build_database(self.root / "live.db")
        (self.root / "media").mkdir()
        args = argparse.Namespace(
            database_path=str(self.root / "live.db"),
            media_dir=str(self.root / "media"),
            backup_root=str(self.root / "bk"),
            keep=None,
        )
        self.assertEqual(backup_lib.run(args), 0)
        snapshot = restore_drill_lib.latest_snapshot(self.root / "bk")
        conn = sqlite3.connect(snapshot)
        try:
            conn.execute("SELECT sha256, size FROM attachments").fetchall()
            conn.execute("SELECT id, username FROM users WHERE avatar_updated_at IS NOT NULL").fetchall()
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main()
