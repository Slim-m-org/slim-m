# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The space banner and icon, profile banners, linked pictures and kept originals are backed up.

A backup that passed its drill once restored into a server answering 500 for
all of these, because only attachments and users' own avatars were mirrored.
"""
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
import backup_side_files  # noqa: E402
import restore_drill_lib  # noqa: E402


def _quiet(call, *args):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return call(*args)


class SideFilesTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.source_db = self.root / "source" / "slimm.db"
        self.media_dir = self.root / "media"
        self.backup_root = self.root / "backup"
        self.user = fixtures.new_user_id()
        self.user_name = str(uuid.UUID(bytes=self.user))
        self.original_of = fixtures.sha256_of(b"the compressed photo")

    def _execute(self, sql, parameters=()):
        conn = sqlite3.connect(str(self.source_db))
        try:
            conn.execute(sql, parameters)
            conn.commit()
        finally:
            conn.close()

    def _build(self, write_files=True):
        """A deployment with one of each side file; returns their names under the media root."""
        photo = b"the compressed photo"
        fixtures.build_database(
            self.source_db,
            attachments=[(self.original_of, len(photo), "image/jpeg")],
            avatar_users=[(self.user, "banner-owner")],
        )
        fixtures.write_attachment_file(self.media_dir, self.original_of, photo)
        fixtures.write_avatar_file(self.media_dir, self.user, b"avatar")
        self._execute("UPDATE space_settings SET banner_updated_at = 1, icon_updated_at = 1")
        self._execute("UPDATE users SET banner_updated_at = 1 WHERE id = ?", (self.user,))
        self._execute(
            "INSERT INTO linked_accounts (user_id, provider, external_id, username, linked_at, "
            "avatar_updated_at) VALUES (?, 'discord', '42', 'someone', 0, 1)",
            (self.user,),
        )
        self._execute(
            "UPDATE attachments SET original_size = ? WHERE sha256 = ?",
            (len(b"the original photo"), self.original_of),
        )
        names = {
            "avatars/space-banner": b"space banner",
            "avatars/space-icon": b"space icon",
            f"avatars/banner-{self.user_name}": b"profile banner",
            f"avatars/link-discord-{self.user_name}": b"linked picture",
            f"attachments/{self.original_of.hex()}.orig": b"the original photo",
        }
        if write_files:
            for name, data in names.items():
                path = self.media_dir / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
        return names

    def _args(self):
        return backup_lib.parse_args([
            "--database-path", str(self.source_db),
            "--media-dir", str(self.media_dir),
            "--backup-root", str(self.backup_root),
        ])

    def _drill(self):
        return _quiet(
            restore_drill_lib.run,
            restore_drill_lib.parse_args(["--backup-root", str(self.backup_root)]),
        )


class BackupMirrorsSideFilesTest(SideFilesTestCase):
    def test_a_backup_mirrors_every_side_file_byte_for_byte(self):
        names = self._build()

        code = _quiet(backup_lib.run, self._args())

        self.assertEqual(code, 0)
        for name, data in names.items():
            self.assertEqual((self.backup_root / name).read_bytes(), data, name)

    def test_the_drill_passes_on_that_backup(self):
        self._build()
        _quiet(backup_lib.run, self._args())

        self.assertEqual(self._drill(), 0)

    def test_a_side_file_missing_on_disk_is_a_warning_naming_it(self):
        names = self._build(write_files=False)

        code, warnings = _quiet(backup_lib.take_backup, self._args())

        self.assertEqual(code, backup_lib.EXIT_WARNINGS)
        self.assertIn(f"({len(names)})", warnings[0])

    def test_a_changed_banner_replaces_the_mirrored_one(self):
        self._build()
        _quiet(backup_lib.run, self._args())
        (self.media_dir / "avatars" / "space-banner").write_bytes(b"a newer banner")

        _quiet(backup_lib.run, self._args())

        mirrored = self.backup_root / "avatars" / "space-banner"
        self.assertEqual(mirrored.read_bytes(), b"a newer banner")

    def test_a_kept_original_already_mirrored_is_not_copied_again(self):
        self._build()
        _quiet(backup_lib.run, self._args())
        snapshot = restore_drill_lib.latest_snapshot(self.backup_root)

        again = backup_side_files.sync(snapshot, self.media_dir, self.backup_root)

        self.assertEqual(again["already_present"], 1)
        self.assertEqual(again["copied"], again["total"] - 1)


class DrillChecksSideFilesTest(SideFilesTestCase):
    def test_the_drill_fails_when_a_mirrored_side_file_is_gone(self):
        names = self._build()
        _quiet(backup_lib.run, self._args())

        for name in names:
            with self.subTest(name=name):
                path = self.backup_root / name
                kept = path.read_bytes()
                path.unlink()
                self.assertEqual(self._drill(), 1)
                path.write_bytes(kept)

    def test_a_truncated_kept_original_fails_the_drill(self):
        self._build()
        _quiet(backup_lib.run, self._args())
        original = self.backup_root / "attachments" / f"{self.original_of.hex()}.orig"
        original.write_bytes(b"cut")

        self.assertEqual(self._drill(), 1)


class OlderSchemaTest(SideFilesTestCase):
    def test_a_database_from_before_these_columns_expects_nothing(self):
        old = self.root / "old.db"
        conn = sqlite3.connect(str(old))
        conn.executescript(
            "CREATE TABLE users (id BLOB PRIMARY KEY, deleted_at INTEGER);"
            "CREATE TABLE attachments (sha256 BLOB PRIMARY KEY, size INTEGER);"
        )
        conn.close()

        self.assertEqual(backup_side_files.expected_files(old), ([], []))

    def test_an_unknown_provider_is_reported_and_never_a_file_name(self):
        self._build()
        conn = sqlite3.connect(str(self.source_db))
        conn.execute("PRAGMA ignore_check_constraints = ON")
        conn.execute("UPDATE linked_accounts SET provider = '../../etc'")
        conn.commit()
        conn.close()

        found, malformed = backup_side_files.expected_files(self.source_db)

        self.assertEqual(len(malformed), 1)
        self.assertFalse([name for _, name, _ in found if name.startswith("link-")])


if __name__ == "__main__":
    unittest.main()
