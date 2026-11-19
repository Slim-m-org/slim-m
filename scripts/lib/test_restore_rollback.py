# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Rolling a deployment back: gaps in the backup, files already there, a running server, an upgrade since."""
import os
import shutil
import sqlite3
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_fixtures as fixtures  # noqa: E402
from test_restore_lib import RestoreTestCase  # noqa: E402

_HOLD_OPEN = """
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("SELECT count(*) FROM users").fetchall()
print("open", flush=True)
sys.stdin.read()
"""


class RestoreWithGapsTest(RestoreTestCase):
    """A backup that lacks a file is still the way back, when the gap is filled or accepted."""

    def _deployment_being_rolled_back(self):
        shutil.copytree(self.live, self.data_dir)

    def test_a_mirror_from_before_icons_were_backed_up_rolls_back_over_the_icon_still_there(self):
        self._back_up()
        (self.backup_root / "avatars" / "space-icon").unlink()
        self._deployment_being_rolled_back()

        code, output = self._restore("--force")

        self.assertEqual(code, 0, output)
        self.assertEqual((self.data_dir / "media" / "avatars" / "space-icon").read_bytes(), b"icon")
        self.assertIn("avatars/space-icon", output)
        self.assertNotIn("MISSING", output)

    def test_an_attachment_only_the_data_directory_holds_must_still_hash_to_its_name(self):
        self._back_up()
        (self.backup_root / "attachments" / self.sha.hex()).unlink()
        self._deployment_being_rolled_back()
        rotted = bytes(len(self.photo))
        (self.data_dir / "media" / "attachments" / self.sha.hex()).write_bytes(rotted)

        code, output = self._restore("--force")

        self.assertEqual(code, 1)
        self.assertRegex(output, rf"MISSING +attachments/{self.sha.hex()}")
        self.assertEqual((self.data_dir / "slimm.db").read_bytes(),
                         (self.live / "slimm.db").read_bytes())

    def test_allow_missing_files_restores_everything_else_and_names_what_it_skipped(self):
        self._back_up()
        (self.backup_root / "attachments" / self.sha.hex()).unlink()

        code, output = self._restore("--allow-missing-files")

        self.assertEqual(code, 0, output)
        self.assertTrue((self.data_dir / "slimm.db").is_file())
        self.assertEqual((self.data_dir / "media" / "avatars" / "space-icon").read_bytes(), b"icon")
        self.assertIn(f"NOT RESTORED  attachments/{self.sha.hex()}", output)

    def test_a_row_that_names_no_file_is_refused_then_skipped_when_allowed(self):
        self._back_up()
        snapshot = next((self.backup_root / "db").glob("slimm-*.db"))
        conn = sqlite3.connect(str(snapshot))
        conn.execute("INSERT INTO attachments (sha256, size, content_type, created_at) "
                     "VALUES (x'0102', 2, 'image/png', 0)")
        conn.commit()
        conn.close()

        refused, _ = self._restore()
        allowed, output = self._restore("--allow-missing-files")

        self.assertEqual((refused, allowed), (1, 0), output)
        self.assertIn("MALFORMED", output)

    def test_a_damaged_snapshot_is_refused_even_when_missing_files_are_allowed(self):
        self._back_up()
        snapshot = next((self.backup_root / "db").glob("slimm-*.db"))
        snapshot.write_bytes(b"not a database at all" * 64)

        code, output = self._restore("--allow-missing-files")

        self.assertEqual(code, 1)
        self.assertIn("integrity", output)
        self.assertFalse((self.data_dir / "slimm.db").exists())

    def test_a_damaged_module_file_is_a_gap_like_any_other(self):
        self._back_up()
        (self.backup_root / "modules" / "notes.db").write_bytes(b"torn" * 300)

        refused, _ = self._restore()
        allowed, output = self._restore("--allow-missing-files")

        self.assertEqual((refused, allowed), (1, 0), output)
        self.assertIn("NOT RESTORED  modules/notes.db", output)
        self.assertFalse((self.data_dir / "modules" / "notes.db").exists())


class RestoreInPlaceTest(RestoreTestCase):
    """A rollback rewrites only what differs, and never leaves a half-written file under a real name."""

    def test_an_attachment_already_in_the_data_directory_is_not_rewritten(self):
        self._back_up()
        shutil.copytree(self.live, self.data_dir)
        attachment = self.data_dir / "media" / "attachments" / self.sha.hex()
        before = attachment.stat().st_ino

        code, output = self._restore("--force")

        self.assertEqual(code, 0, output)
        self.assertEqual(attachment.stat().st_ino, before)
        self.assertIn("1 already in place", output)

    def test_an_attachment_of_the_wrong_size_is_replaced(self):
        self._back_up()
        shutil.copytree(self.live, self.data_dir)
        attachment = self.data_dir / "media" / "attachments" / self.sha.hex()
        attachment.write_bytes(b"cut short")

        code, _ = self._restore("--force")

        self.assertEqual(code, 0)
        self.assertEqual(attachment.read_bytes(), self.photo)

    def test_a_file_arrives_under_a_temporary_name_first(self):
        self._back_up()
        seen = []
        real_replace = os.replace

        def watching(source, dest):
            seen.append((Path(source).name, Path(dest).name))
            return real_replace(source, dest)

        with mock.patch("os.replace", watching):
            code, _ = self._restore()

        self.assertEqual(code, 0)
        self.assertIn((f".tmp-restore-{self.sha.hex()}", self.sha.hex()), seen)
        leftovers = [p.name for p in self.data_dir.rglob(".tmp-restore-*")]
        self.assertEqual(leftovers, [])


class RestoreUnderARunningServerTest(RestoreTestCase):
    def _server_holding(self, database):
        server = subprocess.Popen([sys.executable, "-c", _HOLD_OPEN, str(database)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.addCleanup(server.wait)
        self.addCleanup(server.stdout.close)
        self.addCleanup(server.stdin.close)
        server.stdout.readline()
        return server

    def test_force_is_refused_while_another_process_has_the_database_open(self):
        self._back_up()
        shutil.copytree(self.live, self.data_dir)
        self._server_holding(self.data_dir / "slimm.db")

        code, output = self._restore("--force")

        self.assertEqual(code, 1)
        self.assertIn("docker compose down", output)
        self.assertEqual(list(self.data_dir.glob("slimm.db.before-restore-*")), [])

    def test_a_wal_left_by_a_server_that_was_killed_does_not_block_the_rollback(self):
        self._back_up()
        shutil.copytree(self.live, self.data_dir)
        server = self._server_holding(self.data_dir / "slimm.db")
        server.kill()
        server.wait()
        self.assertTrue((self.data_dir / "slimm.db-wal").exists())

        code, output = self._restore("--force")

        self.assertEqual(code, 0, output)


class RestoreAcrossAnUpgradeTest(RestoreTestCase):
    """The nightly keeps writing snapshots after an upgrade, so the newest is not the way back."""

    def setUp(self):
        super().setUp()
        self._back_up()
        self.before = next((self.backup_root / "db").glob("slimm-*.db"))
        self.upgraded_to = fixtures.latest_migration() + 1
        self.after = self.before.with_name("slimm-29991231T030000Z.db")
        shutil.copyfile(self.before, self.after)
        conn = sqlite3.connect(str(self.after))
        conn.execute(
            "INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time) "
            "VALUES (?, 'the upgrade', 1, x'00', 0)", (self.upgraded_to,))
        conn.commit()
        conn.close()

    def _restored_version(self):
        conn = sqlite3.connect(str(self.data_dir / "slimm.db"))
        try:
            return conn.execute("SELECT max(version) FROM _sqlx_migrations").fetchone()[0]
        finally:
            conn.close()

    def test_list_names_every_snapshot_with_its_migration_and_restores_nothing(self):
        code, output = self._restore("--list")

        self.assertEqual(code, 0)
        self.assertRegex(output, rf"{self.before.name} +migration {self.upgraded_to - 1}\b")
        self.assertRegex(output, rf"{self.after.name} +migration {self.upgraded_to}\b")
        self.assertFalse(self.data_dir.exists())

    def test_before_migration_picks_the_newest_snapshot_the_older_server_can_open(self):
        code, output = self._restore("--before-migration", str(self.upgraded_to))

        self.assertEqual(code, 0, output)
        self.assertEqual(self._restored_version(), self.upgraded_to - 1)
        self.assertIn(f"migration {self.upgraded_to - 1}", output)

    def test_a_named_snapshot_from_after_the_upgrade_is_refused(self):
        code, output = self._restore("--before-migration", str(self.upgraded_to),
                                     "--db-snapshot", str(self.after))

        self.assertEqual(code, 1)
        self.assertIn(f"migration {self.upgraded_to}", output)
        self.assertFalse((self.data_dir / "slimm.db").exists())

    def test_no_snapshot_from_before_the_upgrade_is_a_refusal_that_lists_what_there_is(self):
        self.before.unlink()

        code, output = self._restore("--before-migration", str(self.upgraded_to))

        self.assertEqual(code, 1)
        self.assertIn(self.after.name, output)
        self.assertFalse((self.data_dir / "slimm.db").exists())

    def test_a_plain_restore_says_which_migration_it_restored(self):
        code, output = self._restore()

        self.assertEqual(code, 0)
        self.assertIn(f"migration {self.upgraded_to}", output)


if __name__ == "__main__":
    unittest.main()
