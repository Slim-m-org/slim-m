# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/lib/backup_modules.py and its use by the backup
and the restore drill."""
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_fixtures as fixtures  # noqa: E402
import backup_lib  # noqa: E402
import backup_modules  # noqa: E402
import restore_drill_lib  # noqa: E402


class ModulesTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.source_db = self.root / "data" / "slimm.db"
        self.modules_dir = self.root / "data" / "modules"
        self.backup_root = self.root / "backup"

    def make_module_file(self, name, rows=1, wal=False):
        self.modules_dir.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.modules_dir / name)
        if wal:
            conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE IF NOT EXISTS xp (user_id TEXT, points INTEGER)")
        for i in range(rows):
            conn.execute("INSERT INTO xp VALUES (?, ?)", (f"u{i}", i))
        conn.commit()
        return conn

    def mirrored_rows(self, name):
        conn = sqlite3.connect(self.backup_root / "modules" / name)
        try:
            return conn.execute("SELECT COUNT(*) FROM xp").fetchone()[0]
        finally:
            conn.close()


class BackupModulesTest(ModulesTestCase):
    def test_every_module_file_is_copied_with_its_rows(self):
        self.make_module_file("alpha.db", rows=3).close()
        self.make_module_file("beta-2.db", rows=1).close()

        result = backup_modules.backup_modules(self.modules_dir, self.backup_root)

        self.assertEqual(result["copied"], ["alpha.db", "beta-2.db"])
        self.assertEqual(result["failed"], [])
        self.assertEqual(self.mirrored_rows("alpha.db"), 3)

    def test_a_file_still_open_in_wal_mode_is_copied_whole(self):
        live = self.make_module_file("live.db", rows=5, wal=True)
        self.addCleanup(live.close)
        self.assertTrue((self.modules_dir / "live.db-wal").exists())

        backup_modules.backup_modules(self.modules_dir, self.backup_root)

        self.assertEqual(self.mirrored_rows("live.db"), 5)
        self.assertFalse((self.backup_root / "modules" / "live.db-wal").exists())

    def test_stray_files_and_journals_are_never_mirrored(self):
        self.make_module_file("ok.db").close()
        (self.modules_dir / "UPPER.db").write_bytes(b"x")
        (self.modules_dir / "notes.txt").write_bytes(b"x")
        (self.modules_dir / "ok.db-wal").write_bytes(b"x")

        result = backup_modules.backup_modules(self.modules_dir, self.backup_root)

        self.assertEqual(result["copied"], ["ok.db"])

    def test_a_missing_modules_directory_is_not_an_error(self):
        result = backup_modules.backup_modules(self.modules_dir, self.backup_root)

        self.assertEqual(result, {"total": 0, "copied": [], "failed": []})
        self.assertFalse((self.backup_root / "modules").exists())

    def test_a_second_run_replaces_the_mirror_with_the_current_rows(self):
        conn = self.make_module_file("grow.db", rows=1)
        backup_modules.backup_modules(self.modules_dir, self.backup_root)
        conn.execute("INSERT INTO xp VALUES ('more', 9)")
        conn.commit()
        conn.close()

        backup_modules.backup_modules(self.modules_dir, self.backup_root)

        self.assertEqual(self.mirrored_rows("grow.db"), 2)

    def test_an_unreadable_file_is_reported_not_raised(self):
        self.modules_dir.mkdir(parents=True)
        (self.modules_dir / "broken.db").write_bytes(b"this is not a database" * 100)

        result = backup_modules.backup_modules(self.modules_dir, self.backup_root)

        self.assertEqual(result["copied"], [])
        self.assertEqual(len(result["failed"]), 1)


class RunIncludesModulesTest(ModulesTestCase):
    def _backup_args(self, *extra):
        return backup_lib.parse_args(
            ["--database-path", str(self.source_db), "--media-dir", str(self.root / "media"),
             "--backup-root", str(self.backup_root), *extra]
        )

    def test_the_default_modules_directory_sits_beside_the_database(self):
        fixtures.build_database(self.source_db)
        self.make_module_file("alpha.db", rows=2).close()

        self.assertEqual(backup_lib.run(self._backup_args()), 0)

        self.assertEqual(self.mirrored_rows("alpha.db"), 2)

    def test_an_explicit_modules_directory_wins(self):
        fixtures.build_database(self.source_db)
        other = self.root / "elsewhere"
        self.modules_dir = other
        self.make_module_file("gamma.db", rows=4).close()

        self.assertEqual(backup_lib.run(self._backup_args("--modules-dir", str(other))), 0)

        self.assertEqual(self.mirrored_rows("gamma.db"), 4)

    def test_a_module_file_that_cannot_be_copied_fails_the_run(self):
        fixtures.build_database(self.source_db)
        self.modules_dir.mkdir(parents=True)
        (self.modules_dir / "broken.db").write_bytes(b"this is not a database" * 100)

        self.assertEqual(backup_lib.run(self._backup_args()), 1)


class RestoreDrillModulesTest(ModulesTestCase):
    def _drill(self):
        snapshot_dir = self.backup_root / "db"
        fixtures.build_database(snapshot_dir / "slimm-20260101T000000Z.db")
        args = restore_drill_lib.parse_args(["--backup-root", str(self.backup_root)])
        return restore_drill_lib.run(args)

    def test_a_healthy_mirror_passes(self):
        self.make_module_file("alpha.db").close()
        backup_modules.backup_modules(self.modules_dir, self.backup_root)

        self.assertEqual(self._drill(), 0)

    def test_a_corrupt_mirror_file_fails_the_drill(self):
        self.make_module_file("alpha.db").close()
        backup_modules.backup_modules(self.modules_dir, self.backup_root)
        (self.backup_root / "modules" / "alpha.db").write_bytes(b"garbage" * 1000)

        self.assertEqual(self._drill(), 1)

    def _install(self, module_id, data_schema, approved):
        snapshot = next((self.backup_root / "db").glob("slimm-*.db"))
        conn = sqlite3.connect(snapshot)
        values = {"id": module_id, "data_schema": data_schema, "approved_host_capabilities": approved}
        for _, name, kind, notnull, default, _pk in conn.execute("PRAGMA table_info(installed_modules)"):
            if name not in values and notnull and default is None:
                values[name] = 0 if kind.upper() == "INTEGER" else "x"
        columns = ", ".join(values)
        marks = ", ".join("?" for _ in values)
        conn.execute(
            f"INSERT INTO installed_modules ({columns}) VALUES ({marks})", tuple(values.values())
        )
        conn.commit()
        conn.close()

    def _drill_with(self, module_id, data_schema, approved):
        fixtures.build_database(self.backup_root / "db" / "slimm-20260101T000000Z.db")
        self._install(module_id, data_schema, approved)
        args = restore_drill_lib.parse_args(["--backup-root", str(self.backup_root)])
        return restore_drill_lib.run(args)

    def test_an_installed_module_with_data_but_no_mirrored_file_fails_the_drill(self):
        self.assertEqual(
            self._drill_with("scores", '{"tables":[]}', '["data.store"]'), 1
        )

    def test_a_module_with_no_data_section_passes_the_drill(self):
        self.assertEqual(self._drill_with("plain", "null", '["data.store"]'), 0)

    def test_a_module_whose_data_store_was_never_approved_passes_the_drill(self):
        self.assertEqual(self._drill_with("unapproved", '{"tables":[]}', "[]"), 0)

    def test_an_installed_module_with_data_and_its_mirrored_file_passes(self):
        self.make_module_file("scores.db").close()
        backup_modules.backup_modules(self.modules_dir, self.backup_root)
        self.assertEqual(
            self._drill_with("scores", '{"tables":[]}', '["data.store"]'), 0
        )

    def test_no_modules_mirror_is_fine(self):
        self.assertEqual(self._drill(), 0)


if __name__ == "__main__":
    unittest.main()
