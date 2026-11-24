# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A backup restores into a data directory holding everything its database references."""
import contextlib
import io
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

def quiet(call, *args):
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
        code, _ = quiet(backup_lib.run, backup_lib.parse_args([
            "--database-path", str(database), "--media-dir", str(media),
            "--backup-root", str(self.backup_root),
        ]))
        self.assertEqual(code, 0)

    def _restore(self, *extra):
        args = restore_lib.parse_args([
            "--backup-root", str(self.backup_root), "--data-dir", str(self.data_dir), *extra,
        ])
        return quiet(restore_lib.run, args)


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


if __name__ == "__main__":
    unittest.main()


class RestoreIntegrityTest(RestoreTestCase):
    def test_a_same_size_corrupt_attachment_is_replaced_from_the_mirror(self):
        self._back_up()
        damaged = self.data_dir / "media" / "attachments" / self.sha.hex()
        damaged.parent.mkdir(parents=True)
        damaged.write_bytes(b"X" * len(self.photo))

        code, _ = self._restore()

        self.assertEqual(code, 0)
        self.assertEqual(damaged.read_bytes(), self.photo)

    def test_an_intact_attachment_is_counted_in_place(self):
        self._back_up()
        kept = self.data_dir / "media" / "attachments" / self.sha.hex()
        kept.parent.mkdir(parents=True)
        kept.write_bytes(self.photo)

        _, out = self._restore()

        self.assertIn("1 already in place", out)


class RestoreSessionsTest(RestoreTestCase):
    def _sign_in(self):
        conn = sqlite3.connect(str(self.live / "slimm.db"))
        session = uuid.uuid4().bytes
        conn.execute("INSERT INTO sessions (id, user_id, device_id, created_at) VALUES (?, ?, ?, 1)",
                     (session, self.user, uuid.uuid4().bytes))
        conn.execute("INSERT INTO access_tokens (token_hash, session_id, user_id, device_id, issued_at, expires_at) VALUES ('tok', ?, ?, ?, 1, 99)",
                     (session, self.user, uuid.uuid4().bytes))
        conn.execute("INSERT INTO refresh_tokens (token_hash, session_id, family_id, issued_at, expires_at) "
                     "VALUES ('rt', ?, ?, 1, 99)", (session, uuid.uuid4().bytes))
        conn.execute("INSERT INTO dropped_refresh_tokens VALUES ('old', 'device_removed', 99)")
        conn.commit()
        conn.close()

    def _restored_rows(self, sql):
        conn = sqlite3.connect(str(self.data_dir / "slimm.db"))
        try:
            return conn.execute(sql).fetchall()
        finally:
            conn.close()

    def _back_up_signed_in(self):
        self._back_up()
        self._sign_in()
        code, _ = quiet(backup_lib.run, backup_lib.parse_args([
            "--database-path", str(self.live / "slimm.db"), "--media-dir", str(self.live / "media"),
            "--backup-root", str(self.backup_root),
        ]))
        self.assertEqual(code, 0)

    def _restore_over_existing(self, *extra):
        self.data_dir.mkdir()
        fixtures.build_database(self.data_dir / "slimm.db")
        return self._restore("--force", *extra)

    def test_a_forced_restore_leaves_no_session_that_can_authenticate(self):
        self._back_up_signed_in()

        code, out = self._restore_over_existing()

        self.assertEqual(code, 0)
        self.assertEqual(self._restored_rows("SELECT count(*) FROM sessions WHERE revoked_at IS NULL"), [(0,)])
        self.assertEqual(self._restored_rows("SELECT count(*) FROM access_tokens"), [(0,)])
        self.assertEqual(self._restored_rows("SELECT count(*) FROM refresh_tokens WHERE revoked_at IS NULL"), [(0,)])
        self.assertEqual(self._restored_rows("SELECT count(*) FROM dropped_refresh_tokens"), [(0,)])
        self.assertIn("re-run any account deletions", out)

    def test_a_forced_restore_names_the_bots_whose_tokens_ended(self):
        self._back_up_signed_in()
        conn = sqlite3.connect(str(self.live / "slimm.db"))
        session = conn.execute("SELECT id FROM sessions").fetchone()[0]
        conn.execute("INSERT INTO bot_tokens (token_hash, bot_user_id, session_id, name, created_at) "
                     "VALUES ('bt', ?, ?, 'greeter', 1)", (self.user, session))
        conn.commit()
        conn.close()
        code, _ = quiet(backup_lib.run, backup_lib.parse_args([
            "--database-path", str(self.live / "slimm.db"), "--media-dir", str(self.live / "media"),
            "--backup-root", str(self.backup_root),
        ]))
        self.assertEqual(code, 0)

        _, out = self._restore_over_existing()

        self.assertIn("need new tokens", out)
        self.assertIn("greeter", out)

    def test_opting_out_keeps_the_sessions(self):
        self._back_up_signed_in()

        self._restore_over_existing("--no-revoke-sessions")

        self.assertEqual(self._restored_rows("SELECT count(*) FROM sessions WHERE revoked_at IS NULL"), [(1,)])

    def test_a_restore_into_an_empty_directory_keeps_the_sessions_unless_asked(self):
        self._back_up_signed_in()

        self._restore()

        self.assertEqual(self._restored_rows("SELECT count(*) FROM sessions WHERE revoked_at IS NULL"), [(1,)])


class RestoreOwnershipTest(RestoreTestCase):
    def test_a_non_root_restore_names_the_chown_to_run(self):
        self._back_up()

        with mock.patch("os.geteuid", return_value=1000), mock.patch("os.getegid", return_value=1000):
            _, out = self._restore()

        self.assertIn(f"chown -R 65532:65532 {self.data_dir}", out)
