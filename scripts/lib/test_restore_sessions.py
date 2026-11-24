# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""restore_sessions opens only an existing database file, whatever the path looks like."""
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import restore_sessions  # noqa: E402


class RestoreSessionsOpenTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.root = Path(self.dir.name)

    def _database(self, name):
        path = self.root / name
        conn = sqlite3.connect(path)
        conn.execute("CREATE TABLE sessions (id INTEGER, revoked_at INTEGER)")
        conn.execute("INSERT INTO sessions VALUES (1, NULL)")
        conn.commit()
        conn.close()
        return path

    def test_a_missing_file_is_refused_and_not_created(self):
        missing = self.root / "absent.db"
        with self.assertRaises(FileNotFoundError):
            restore_sessions.revoke_all(missing)
        self.assertFalse(missing.exists())

    def test_a_directory_is_refused(self):
        with self.assertRaises(FileNotFoundError):
            restore_sessions.revoke_all(self.root)

    def test_uri_characters_in_the_path_stay_part_of_the_file_name(self):
        path = self._database("odd?mode=ro#name %.db")
        restore_sessions.revoke_all(path, now_ms=7)
        row = sqlite3.connect(path).execute("SELECT revoked_at FROM sessions").fetchone()
        self.assertEqual(row, (7,))


if __name__ == "__main__":
    unittest.main()
