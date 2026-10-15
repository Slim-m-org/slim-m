# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/lib/backup_lib.py.

No real server or network: a fixture SQLite database (backup_fixtures.py,
matching the real attachments/users columns) and a plain media directory
under a TemporaryDirectory stand in for a live deployment's volume.
addCleanup runs the directory's cleanup whether the test passes or fails,
so a failed assertion never leaves anything behind for the shared /tmp
tmpfs CLAUDE.md already warns about.
"""
import sqlite3
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_fixtures as fixtures  # noqa: E402
import backup_lib  # noqa: E402


class BackupTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.source_db = self.root / "source" / "slimm.db"
        self.media_dir = self.root / "media"
        self.backup_root = self.root / "backup"


class VacuumIntoTest(BackupTestCase):
    def test_snapshot_passes_integrity_check(self):
        fixtures.build_database(self.source_db)
        dest = self.root / "snap.db"

        backup_lib.vacuum_into(self.source_db, dest)

        conn = sqlite3.connect(f"file:{dest}?mode=ro", uri=True)
        try:
            result = conn.execute("PRAGMA integrity_check").fetchone()[0]
        finally:
            conn.close()
        self.assertEqual(result, "ok")

    def test_snapshot_carries_no_wal_or_shm_siblings(self):
        fixtures.build_database(self.source_db)
        dest = self.root / "snap.db"

        backup_lib.vacuum_into(self.source_db, dest)

        self.assertFalse(Path(str(dest) + "-wal").exists())
        self.assertFalse(Path(str(dest) + "-shm").exists())

    def test_a_database_path_holding_a_uri_special_character_still_works(self):
        # An unescaped "?" would start a URI query string mid-path instead.
        odd_db = self.root / "weird?name#dir" / "slimm.db"
        data = b"snapshot taken from an oddly named path"
        sha = fixtures.sha256_of(data)
        fixtures.build_database(odd_db, attachments=[(sha, len(data), "text/plain")])
        dest = self.root / "snap.db"

        backup_lib.vacuum_into(odd_db, dest)

        conn = sqlite3.connect(str(dest))
        try:
            rows = conn.execute("SELECT sha256, size FROM attachments").fetchall()
        finally:
            conn.close()
        self.assertEqual(rows, [(sha, len(data))])

    def test_snapshot_rows_match_the_live_source(self):
        data = b"hello"
        sha, size = fixtures.sha256_of(data), len(data)
        fixtures.build_database(self.source_db, attachments=[(sha, size, "text/plain")])
        dest = self.root / "snap.db"

        backup_lib.vacuum_into(self.source_db, dest)

        conn = sqlite3.connect(str(dest))
        try:
            rows = conn.execute("SELECT sha256, size FROM attachments").fetchall()
        finally:
            conn.close()
        self.assertEqual(rows, [(sha, size)])


class SyncAttachmentsTest(BackupTestCase):
    def test_mirrors_every_referenced_attachment(self):
        data_a, data_b = b"file A contents", b"a different file B"
        sha_a, sha_b = fixtures.sha256_of(data_a), fixtures.sha256_of(data_b)
        fixtures.build_database(
            self.source_db,
            attachments=[(sha_a, len(data_a), "text/plain"), (sha_b, len(data_b), "text/plain")],
        )
        fixtures.write_attachment_file(self.media_dir, sha_a, data_a)
        fixtures.write_attachment_file(self.media_dir, sha_b, data_b)

        result = backup_lib.sync_attachments(self.source_db, self.media_dir, self.backup_root)

        self.assertEqual(result["copied"], 2)
        self.assertEqual(result["missing_source"], [])
        mirror = self.backup_root / "attachments"
        self.assertEqual((mirror / sha_a.hex()).read_bytes(), data_a)
        self.assertEqual((mirror / sha_b.hex()).read_bytes(), data_b)

    def test_reports_a_missing_source_file_by_name(self):
        data = b"referenced by the database but never written to disk"
        sha = fixtures.sha256_of(data)
        fixtures.build_database(self.source_db, attachments=[(sha, len(data), "text/plain")])

        result = backup_lib.sync_attachments(self.source_db, self.media_dir, self.backup_root)

        self.assertEqual(result["copied"], 0)
        self.assertEqual(result["missing_source"], [sha.hex()])
        self.assertFalse((self.backup_root / "attachments" / sha.hex()).exists())

    def test_a_byte_identical_mirror_file_is_never_recopied(self):
        data = b"already backed up on a previous run"
        sha = fixtures.sha256_of(data)
        fixtures.build_database(self.source_db, attachments=[(sha, len(data), "text/plain")])
        fixtures.write_attachment_file(self.media_dir, sha, data)
        backup_lib.sync_attachments(self.source_db, self.media_dir, self.backup_root)

        result = backup_lib.sync_attachments(self.source_db, self.media_dir, self.backup_root)

        self.assertEqual(result["copied"], 0)
        self.assertEqual(result["already_present"], 1)

    def test_a_wrong_sized_mirror_file_is_repaired(self):
        data = b"the real, correctly sized attachment content"
        sha = fixtures.sha256_of(data)
        fixtures.build_database(self.source_db, attachments=[(sha, len(data), "text/plain")])
        fixtures.write_attachment_file(self.media_dir, sha, data)
        mirror_dir = self.backup_root / "attachments"
        mirror_dir.mkdir(parents=True)
        (mirror_dir / sha.hex()).write_bytes(b"short")

        result = backup_lib.sync_attachments(self.source_db, self.media_dir, self.backup_root)

        self.assertEqual(result["repaired"], 1)
        self.assertEqual(result["copied"], 1)
        self.assertEqual((mirror_dir / sha.hex()).read_bytes(), data)

    def test_a_malformed_sha256_is_reported_and_never_mirrored(self):
        fixtures.build_database(
            self.source_db, attachments=[(b"not-a-real-digest", 17, "text/plain")]
        )

        result = backup_lib.sync_attachments(self.source_db, self.media_dir, self.backup_root)

        self.assertEqual(len(result["malformed"]), 1)
        self.assertEqual(result["copied"], 0)
        self.assertEqual(result["missing_source"], [])
        mirror_dir = self.backup_root / "attachments"
        self.assertEqual(list(mirror_dir.iterdir()) if mirror_dir.is_dir() else [], [])


class SyncAvatarsTest(BackupTestCase):
    def test_mirrors_every_user_with_an_avatar(self):
        user_id = fixtures.new_user_id()
        data = b"avatar png bytes"
        fixtures.build_database(self.source_db, avatar_users=[(user_id, "alice")])
        fixtures.write_avatar_file(self.media_dir, user_id, data)

        result = backup_lib.sync_avatars(self.source_db, self.media_dir, self.backup_root)

        self.assertEqual(result["copied"], 1)
        self.assertEqual(result["missing_source"], [])
        name = str(uuid.UUID(bytes=user_id))
        self.assertEqual((self.backup_root / "avatars" / name).read_bytes(), data)

    def test_a_deleted_account_with_no_avatar_file_is_not_a_missing_source(self):
        user_id = fixtures.new_user_id()
        fixtures.build_database(self.source_db, deleted_avatar_users=[(user_id, "gone")])

        result = backup_lib.sync_avatars(self.source_db, self.media_dir, self.backup_root)

        self.assertEqual(result["missing_source"], [])
        self.assertEqual(result["total"], 0)

    def test_reports_a_missing_avatar_by_name(self):
        user_id = fixtures.new_user_id()
        fixtures.build_database(self.source_db, avatar_users=[(user_id, "bob")])

        result = backup_lib.sync_avatars(self.source_db, self.media_dir, self.backup_root)

        self.assertEqual(result["copied"], 0)
        self.assertEqual(result["missing_source"], [str(uuid.UUID(bytes=user_id))])

    def test_a_malformed_user_id_is_reported_and_never_mirrored(self):
        fixtures.build_database(self.source_db, avatar_users=[(b"too-short", "eve")])

        result = backup_lib.sync_avatars(self.source_db, self.media_dir, self.backup_root)

        self.assertEqual(len(result["malformed"]), 1)
        self.assertEqual(result["copied"], 0)
        self.assertEqual(result["missing_source"], [])
        mirror_dir = self.backup_root / "avatars"
        self.assertEqual(list(mirror_dir.iterdir()) if mirror_dir.is_dir() else [], [])


class MirrorIndependenceTest(BackupTestCase):
    """The original implementation mirrored with os.link, so truncating the
    backup's copy truncated the live server's own attachment - same inode.
    This is the test that would have caught it before it shipped."""

    def test_independent_copy_does_not_share_an_inode_with_its_source(self):
        src = self.root / "source_file"
        src.parent.mkdir(parents=True, exist_ok=True)
        src.write_bytes(b"the live server's own bytes")
        dest = self.root / "dest_file"

        backup_lib._independent_copy(src, dest)

        self.assertNotEqual(src.stat().st_ino, dest.stat().st_ino)

    def test_truncating_the_copy_leaves_the_source_intact(self):
        src = self.root / "source_file"
        src.parent.mkdir(parents=True, exist_ok=True)
        original = b"the live server's own bytes, must survive"
        src.write_bytes(original)
        dest = self.root / "dest_file"
        backup_lib._independent_copy(src, dest)

        with open(dest, "r+b") as handle:
            handle.truncate(4)

        self.assertEqual(src.read_bytes(), original)

    def test_sync_attachments_mirror_does_not_share_an_inode_with_its_source(self):
        data = b"the live server's own attachment"
        sha = fixtures.sha256_of(data)
        source_path = fixtures.write_attachment_file(self.media_dir, sha, data)
        fixtures.build_database(self.source_db, attachments=[(sha, len(data), "text/plain")])

        backup_lib.sync_attachments(self.source_db, self.media_dir, self.backup_root)

        mirror_path = self.backup_root / "attachments" / sha.hex()
        self.assertNotEqual(source_path.stat().st_ino, mirror_path.stat().st_ino)

    def test_truncating_the_synced_mirror_leaves_the_live_attachment_intact(self):
        data = b"the live server's own attachment, not to be corrupted"
        sha = fixtures.sha256_of(data)
        source_path = fixtures.write_attachment_file(self.media_dir, sha, data)
        fixtures.build_database(self.source_db, attachments=[(sha, len(data), "text/plain")])
        backup_lib.sync_attachments(self.source_db, self.media_dir, self.backup_root)
        mirror_path = self.backup_root / "attachments" / sha.hex()

        with open(mirror_path, "r+b") as handle:
            handle.truncate(4)

        self.assertEqual(source_path.read_bytes(), data)


class RunTest(BackupTestCase):
    def _args(self):
        return backup_lib.parse_args(
            [
                "--database-path",
                str(self.source_db),
                "--media-dir",
                str(self.media_dir),
                "--backup-root",
                str(self.backup_root),
            ]
        )

    def test_a_clean_backup_exits_zero_and_writes_a_manifest(self):
        data = b"clean run contents"
        sha = fixtures.sha256_of(data)
        fixtures.build_database(self.source_db, attachments=[(sha, len(data), "text/plain")])
        fixtures.write_attachment_file(self.media_dir, sha, data)

        code = backup_lib.run(self._args())

        self.assertEqual(code, 0)
        manifests = list((self.backup_root / "db").glob("*.manifest.json"))
        self.assertEqual(len(manifests), 1)

    def test_a_missing_source_file_exits_non_zero(self):
        data = b"referenced by the row but never written to disk"
        sha = fixtures.sha256_of(data)
        fixtures.build_database(self.source_db, attachments=[(sha, len(data), "text/plain")])

        code = backup_lib.run(self._args())

        self.assertEqual(code, 1)

    def test_no_source_database_exits_non_zero(self):
        code = backup_lib.run(self._args())

        self.assertEqual(code, 1)

    def test_a_malformed_attachment_id_exits_non_zero(self):
        fixtures.build_database(
            self.source_db, attachments=[(b"not-a-real-digest", 17, "text/plain")]
        )

        code = backup_lib.run(self._args())

        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
