# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import sqlite3
import tempfile
import unittest
from pathlib import Path

import sqlite_read_only


class ReadOnlyConnectTest(unittest.TestCase):
    def test_a_query_or_fragment_in_the_path_stays_part_of_the_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            odd = Path(tmp, "slimm?mode=rwc#x.db")
            setup = sqlite3.connect(odd)
            setup.execute("CREATE TABLE t (v)")
            setup.execute("INSERT INTO t VALUES (1)")
            setup.commit()
            setup.close()
            conn = sqlite_read_only.connect(odd)
            try:
                self.assertEqual(conn.execute("SELECT v FROM t").fetchone(), (1,))
                with self.assertRaises(sqlite3.OperationalError):
                    conn.execute("INSERT INTO t VALUES (2)")
            finally:
                conn.close()
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), [odd.name])

    def test_a_missing_file_is_not_created(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(sqlite3.OperationalError):
                sqlite_read_only.connect(Path(tmp, "absent.db")).execute("SELECT 1")
            self.assertEqual(list(Path(tmp).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
