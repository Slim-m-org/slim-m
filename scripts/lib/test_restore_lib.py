# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A backup restores into a data directory holding everything its database references."""
import contextlib
import io
import os
import shutil
import sqlite3
import sys
import tempfile
import unittest
import uuid
from unittest import mock
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
        self.assertIn("--allow-missing-files", output)
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


if __name__ == "__main__":
    unittest.main()
