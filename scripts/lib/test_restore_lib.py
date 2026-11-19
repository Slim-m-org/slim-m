# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A backup restores into a data directory holding everything its database references."""
import contextlib
import io
import sqlite3
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_fixtures as fixtures  # noqa: E402
import backup_lib  # noqa: E402
import restore_lib  # noqa: E402


def _quiet(call, *args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        return call(*args), out.getvalue()


class RestoreTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.live = self.root / "live"
        self.backup_root = self.root / "backup"
        self.data_dir = self.root / "restored"
        self.user = fixtures.new_user_id()
        self.photo = b"an attachment"
        self.sha = fixtures.sha256_of(self.photo)

    def _back_up(self):
        database = self.live / "slimm.db"
        media = self.live / "media"
        fixtures.build_database(
            database,
            attachments=[(self.sha, len(self.photo), "image/png")],
            avatar_users=[(self.user, "someone")],
        )
        fixtures.write_attachment_file(media, self.sha, self.photo)
        fixtures.write_avatar_file(media, self.user, b"avatar")
        conn = sqlite3.connect(str(database))
        conn.execute("UPDATE space_settings SET icon_updated_at = 1")
        conn.commit()
        conn.close()
        (media / "avatars" / "space-icon").write_bytes(b"icon")
        modules = self.live / "modules"
        modules.mkdir()
        module = sqlite3.connect(str(modules / "notes.db"))
        module.execute("CREATE TABLE kv (k TEXT)")
        module.commit()
        module.close()
        code, _ = _quiet(backup_lib.run, backup_lib.parse_args([
            "--database-path", str(database), "--media-dir", str(media),
            "--backup-root", str(self.backup_root),
        ]))
        self.assertEqual(code, 0)

    def _restore(self, *extra):
        args = restore_lib.parse_args([
            "--backup-root", str(self.backup_root), "--data-dir", str(self.data_dir), *extra,
        ])
        return _quiet(restore_lib.run, args)


class RestoreTest(RestoreTestCase):
    def test_a_restore_places_the_database_and_every_referenced_file(self):
        self._back_up()

        code, _ = self._restore()

        self.assertEqual(code, 0)
        media = self.data_dir / "media"
        self.assertEqual((media / "attachments" / self.sha.hex()).read_bytes(), self.photo)
        avatar = media / "avatars" / str(uuid.UUID(bytes=self.user))
        self.assertEqual(avatar.read_bytes(), b"avatar")
        self.assertEqual((media / "avatars" / "space-icon").read_bytes(), b"icon")
        self.assertTrue((self.data_dir / "modules" / "notes.db").is_file())
        conn = sqlite3.connect(str(self.data_dir / "slimm.db"))
        self.assertEqual(conn.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        self.assertEqual(conn.execute("SELECT count(*) FROM users").fetchone()[0], 1)
        conn.close()

    def test_a_file_the_mirror_kept_for_a_deleted_row_is_not_restored(self):
        self._back_up()
        stale = self.backup_root / "attachments" / ("ab" * 32)
        stale.write_bytes(b"deleted long ago")

        self._restore()

        self.assertFalse((self.data_dir / "media" / "attachments" / stale.name).exists())

    def test_an_existing_database_is_refused_and_left_alone(self):
        self._back_up()
        self.data_dir.mkdir()
        (self.data_dir / "slimm.db").write_bytes(b"the running deployment")

        code, output = self._restore()

        self.assertEqual(code, 1)
        self.assertIn("--force", output)
        self.assertEqual((self.data_dir / "slimm.db").read_bytes(), b"the running deployment")

    def test_force_moves_the_old_database_and_its_wal_aside(self):
        self._back_up()
        self.data_dir.mkdir()
        (self.data_dir / "slimm.db").write_bytes(b"the old database")
        (self.data_dir / "slimm.db-wal").write_bytes(b"its wal")

        code, _ = self._restore("--force")

        self.assertEqual(code, 0)
        kept = sorted(path.name for path in self.data_dir.glob("slimm.db.before-restore-*"))
        self.assertEqual(len(kept), 2)
        self.assertFalse((self.data_dir / "slimm.db-wal").exists())
        self.assertEqual(
            (self.data_dir / kept[0]).read_bytes(), b"the old database")

    def test_force_moves_an_old_module_file_and_its_wal_aside(self):
        self._back_up()
        modules = self.data_dir / "modules"
        modules.mkdir(parents=True)
        (self.data_dir / "slimm.db").write_bytes(b"the old database")
        (modules / "notes.db").write_bytes(b"the old notes")
        (modules / "notes.db-wal").write_bytes(b"pages written after the backup")

        code, _ = self._restore("--force")

        self.assertEqual(code, 0)
        self.assertFalse((modules / "notes.db-wal").exists())
        kept = sorted(path.name for path in modules.glob("notes.db.before-restore-*"))
        self.assertEqual(len(kept), 2)
        self.assertEqual((modules / kept[0]).read_bytes(), b"the old notes")
        restored = sqlite3.connect(str(modules / "notes.db"))
        self.assertEqual(restored.execute("PRAGMA integrity_check").fetchone()[0], "ok")
        restored.close()

    def test_a_backup_missing_a_referenced_file_restores_nothing(self):
        self._back_up()
        (self.backup_root / "attachments" / self.sha.hex()).unlink()

        code, output = self._restore()

        self.assertEqual(code, 1)
        self.assertIn("MISSING", output)
        self.assertFalse((self.data_dir / "slimm.db").exists())

    def test_a_read_only_backup_still_restores(self):
        self._back_up()
        directories = [self.backup_root, *(p for p in self.backup_root.rglob("*") if p.is_dir())]
        for directory in directories:
            directory.chmod(0o555)
            self.addCleanup(directory.chmod, 0o755)

        code, _ = self._restore()

        self.assertEqual(code, 0)
        self.assertFalse((self.data_dir / ".restore-check").exists())

    def test_the_key_file_lands_beside_the_database_owner_only(self):
        self._back_up()
        key = self.root / "my-key-copy"
        key.write_text("c2VjcmV0")

        code, output = self._restore("--data-key-file", str(key))

        self.assertEqual(code, 0)
        placed = self.data_dir / "slimm-data.key"
        self.assertEqual(placed.read_text(), "c2VjcmV0")
        self.assertEqual(placed.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("SLIMM_DATA_KEY", output)

    def test_a_restore_without_a_key_says_what_that_costs(self):
        self._back_up()

        _, output = self._restore()

        self.assertIn("SLIMM_DATA_KEY", output)

    def test_no_backup_is_a_plain_refusal(self):
        code, output = self._restore()

        self.assertEqual(code, 1)
        self.assertIn("no database snapshot", output)


if __name__ == "__main__":
    unittest.main()
