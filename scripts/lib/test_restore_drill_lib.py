# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/lib/restore_drill_lib.py.

Same fixture module as test_backup_lib.py (backup_fixtures.py), so the
drill is checked against the same schema-faithful database shape a real
backup would produce.
"""
import contextlib
import io
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_fixtures as fixtures  # noqa: E402
import restore_drill_lib  # noqa: E402


class RestoreDrillTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.backup_root = self.root / "backup"
        self.db_dir = self.backup_root / "db"
        self.db_dir.mkdir(parents=True)

    def _write_snapshot(self, attachments=(), avatar_users=()):
        snapshot = self.db_dir / "slimm-20260101T000000Z.db"
        fixtures.build_database(snapshot, attachments=attachments, avatar_users=avatar_users)
        return snapshot


class CheckIntegrityTest(RestoreDrillTestCase):
    def test_a_valid_snapshot_passes(self):
        snapshot = self._write_snapshot()
        scratch = self.root / "scratch"
        scratch.mkdir()

        restored = restore_drill_lib.restore_database(snapshot, scratch)

        self.assertEqual(restore_drill_lib.check_integrity(restored), "ok")

    def test_restoring_copies_to_a_fresh_path_leaving_the_snapshot_untouched(self):
        snapshot = self._write_snapshot()
        scratch = self.root / "scratch"
        scratch.mkdir()

        restored = restore_drill_lib.restore_database(snapshot, scratch)

        self.assertNotEqual(restored, snapshot)
        self.assertTrue(restored.is_file())
        self.assertTrue(snapshot.is_file())


class CheckAttachmentsTest(RestoreDrillTestCase):
    def test_verifies_a_correctly_mirrored_attachment(self):
        data = b"correct, untouched bytes"
        sha = fixtures.sha256_of(data)
        snapshot = self._write_snapshot(attachments=[(sha, len(data), "text/plain")])
        fixtures.write_attachment_file(self.backup_root, sha, data)

        result = restore_drill_lib.check_attachments(snapshot, self.backup_root)

        self.assertEqual(result["verified"], 1)
        self.assertEqual(result["missing"], [])
        self.assertEqual(result["mismatched"], [])

    def test_catches_a_missing_attachment_file(self):
        data = b"referenced by the row, never written to the mirror"
        sha = fixtures.sha256_of(data)
        snapshot = self._write_snapshot(attachments=[(sha, len(data), "text/plain")])

        result = restore_drill_lib.check_attachments(snapshot, self.backup_root)

        self.assertEqual(result["missing"], [sha.hex()])
        self.assertEqual(result["verified"], 0)

    def test_catches_a_file_whose_bytes_do_not_hash_to_its_own_name(self):
        data = b"the real content this filename promises"
        sha = fixtures.sha256_of(data)
        snapshot = self._write_snapshot(attachments=[(sha, len(data), "text/plain")])
        # Named after the digest but holding different bytes: corruption, not absence.
        fixtures.write_attachment_file(self.backup_root, sha, b"corrupted, wrong content!!")

        result = restore_drill_lib.check_attachments(snapshot, self.backup_root)

        self.assertEqual(result["verified"], 0)
        self.assertEqual(len(result["mismatched"]), 1)
        expected, actual, expected_size, actual_size = result["mismatched"][0]
        self.assertEqual(expected, sha.hex())
        self.assertNotEqual(actual, expected)

    def test_a_malformed_sha256_is_reported_as_malformed_not_missing(self):
        snapshot = self._write_snapshot(attachments=[(b"not-a-real-digest", 17, "text/plain")])

        result = restore_drill_lib.check_attachments(snapshot, self.backup_root)

        self.assertEqual(len(result["malformed"]), 1)
        self.assertEqual(result["missing"], [])
        self.assertEqual(result["mismatched"], [])
        self.assertEqual(result["verified"], 0)


class CheckAvatarsTest(RestoreDrillTestCase):
    def test_verifies_a_present_avatar(self):
        user_id = fixtures.new_user_id()
        snapshot = self._write_snapshot(avatar_users=[(user_id, "alice")])
        fixtures.write_avatar_file(self.backup_root, user_id, b"avatar bytes")

        result = restore_drill_lib.check_avatars(snapshot, self.backup_root)

        self.assertEqual(result["verified"], 1)
        self.assertEqual(result["missing"], [])

    def test_catches_a_missing_avatar(self):
        user_id = fixtures.new_user_id()
        snapshot = self._write_snapshot(avatar_users=[(user_id, "bob")])

        result = restore_drill_lib.check_avatars(snapshot, self.backup_root)

        self.assertEqual(result["missing"], [(str(uuid.UUID(bytes=user_id)), "bob")])

    def test_a_malformed_user_id_is_reported_as_malformed_not_missing(self):
        snapshot = self._write_snapshot(avatar_users=[(b"too-short", "eve")])

        result = restore_drill_lib.check_avatars(snapshot, self.backup_root)

        self.assertEqual(len(result["malformed"]), 1)
        self.assertEqual(result["missing"], [])
        self.assertEqual(result["verified"], 0)


class LatestSnapshotTest(RestoreDrillTestCase):
    def test_picks_the_newest_timestamped_snapshot(self):
        (self.db_dir / "slimm-20260101T000000Z.db").write_bytes(b"")
        newest = self.db_dir / "slimm-20260601T120000Z.db"
        newest.write_bytes(b"")

        self.assertEqual(restore_drill_lib.latest_snapshot(self.backup_root), newest)

    def test_no_snapshots_returns_none(self):
        self.assertIsNone(restore_drill_lib.latest_snapshot(self.backup_root))


class RunTest(RestoreDrillTestCase):
    def _args(self):
        return restore_drill_lib.parse_args(["--backup-root", str(self.backup_root)])

    def test_a_fully_verified_backup_exits_zero(self):
        data = b"all good here"
        sha = fixtures.sha256_of(data)
        self._write_snapshot(attachments=[(sha, len(data), "text/plain")])
        fixtures.write_attachment_file(self.backup_root, sha, data)

        code = restore_drill_lib.run(self._args())

        self.assertEqual(code, 0)

    def test_a_missing_attachment_exits_non_zero(self):
        data = b"referenced but absent from the mirror"
        sha = fixtures.sha256_of(data)
        self._write_snapshot(attachments=[(sha, len(data), "text/plain")])

        code = restore_drill_lib.run(self._args())

        self.assertEqual(code, 1)

    def test_a_corrupted_attachment_exits_non_zero(self):
        data = b"the real content"
        sha = fixtures.sha256_of(data)
        self._write_snapshot(attachments=[(sha, len(data), "text/plain")])
        fixtures.write_attachment_file(self.backup_root, sha, b"tampered bytes, wrong hash")

        code = restore_drill_lib.run(self._args())

        self.assertEqual(code, 1)

    def test_no_snapshot_found_exits_non_zero(self):
        code = restore_drill_lib.run(self._args())

        self.assertEqual(code, 1)

    def test_a_malformed_attachment_id_exits_non_zero(self):
        self._write_snapshot(attachments=[(b"not-a-real-digest", 17, "text/plain")])

        code = restore_drill_lib.run(self._args())

        self.assertEqual(code, 1)

    def _scratch_copies(self):
        return list((self.backup_root / "restore-drill").rglob("slimm.db"))

    def test_a_corrupt_snapshot_fails_with_a_report_not_a_traceback(self):
        snapshot = self._write_snapshot()
        snapshot.write_bytes(snapshot.read_bytes()[: snapshot.stat().st_size // 2])

        with contextlib.redirect_stdout(io.StringIO()) as out, \
                contextlib.redirect_stderr(io.StringIO()):
            code = restore_drill_lib.run(self._args())

        self.assertEqual(code, 1)
        self.assertIn("FAIL", out.getvalue())
        self.assertIn("integrity_check", out.getvalue())

    def test_a_failed_integrity_check_skips_the_later_checks(self):
        self._write_snapshot()
        with mock.patch.object(restore_drill_lib, "check_integrity",
                               return_value="row 3 missing from index"), \
                mock.patch.object(restore_drill_lib, "check_attachments") as att, \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            code = restore_drill_lib.run(self._args())

        self.assertEqual(code, 1)
        att.assert_not_called()

    def test_the_default_scratch_copy_is_removed_afterwards(self):
        self._write_snapshot()

        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(restore_drill_lib.run(self._args()), 0)

        self.assertEqual(self._scratch_copies(), [])

    def test_keep_scratch_leaves_the_copy(self):
        self._write_snapshot()
        args = restore_drill_lib.parse_args(
            ["--backup-root", str(self.backup_root), "--keep-scratch"])

        with contextlib.redirect_stdout(io.StringIO()):
            restore_drill_lib.run(args)

        self.assertEqual(len(self._scratch_copies()), 1)

    def test_an_explicit_scratch_dir_is_the_callers_and_is_kept(self):
        self._write_snapshot()
        scratch = self.root / "mine"
        args = restore_drill_lib.parse_args(
            ["--backup-root", str(self.backup_root), "--scratch-dir", str(scratch)])

        with contextlib.redirect_stdout(io.StringIO()):
            restore_drill_lib.run(args)

        self.assertTrue((scratch / "slimm.db").is_file())


if __name__ == "__main__":
    unittest.main()
