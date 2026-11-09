# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/lib/backup_nightly.py: the status file the server reads."""
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_fixtures as fixtures  # noqa: E402
import backup_nightly  # noqa: E402


class NightlyTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.source_db = root / "data" / "slimm.db"
        self.media = root / "data" / "media"
        self.backup_root = root / "backup"
        self.status_dir = root / "status"

    def _args(self):
        return backup_nightly.parse_args([
            "--database-path", str(self.source_db), "--media-dir", str(self.media),
            "--backup-root", str(self.backup_root), "--status-dir", str(self.status_dir),
        ])

    def _status(self):
        return json.loads((self.status_dir / "status.json").read_text())


class RunOnceTest(NightlyTestCase):
    def test_a_good_run_records_a_verified_backup(self):
        data = b"an attachment"
        sha = fixtures.sha256_of(data)
        fixtures.build_database(self.source_db, attachments=[(sha, len(data), "text/plain")])
        fixtures.write_attachment_file(self.media, sha, data)

        status = backup_nightly.run_once(self._args(), now_ms=1_000)

        self.assertTrue(status["ok"])
        self.assertIsNone(status["error"])
        self.assertEqual(self._status()["last_verified_at_ms"], 1_000)
        self.assertGreater(self._status()["last_verified_bytes"], 0)

    def test_a_missing_database_is_a_failed_backup_stage(self):
        status = backup_nightly.run_once(self._args(), now_ms=5)

        self.assertFalse(status["ok"])
        self.assertEqual(status["stage"], "backup")
        self.assertIn("no database", status["error"])
        self.assertIsNone(status["last_verified_at_ms"])

    def test_an_attachment_the_mirror_never_held_fails_the_drill_and_keeps_the_warning(self):
        sha = fixtures.sha256_of(b"gone")
        fixtures.build_database(self.source_db, attachments=[(sha, 4, "text/plain")])

        status = backup_nightly.run_once(self._args(), now_ms=5)

        self.assertFalse(status["ok"])
        self.assertEqual(status["stage"], "drill")
        self.assertIn(sha.hex(), status["error"])
        self.assertEqual(len(status["warnings"]), 1)

    def test_an_avatar_gone_from_the_live_volume_is_drilled_and_its_mirror_copy_verifies(self):
        user = fixtures.new_user_id()
        fixtures.build_database(self.source_db, avatar_users=[(user, "ada")])
        live = fixtures.write_avatar_file(self.media, user, b"avatar bytes")
        backup_nightly.run_once(self._args(), now_ms=1_000)
        live.unlink()

        status = backup_nightly.run_once(self._args(), now_ms=2_000)

        self.assertTrue(status["ok"])
        self.assertEqual(status["stage"], "drill")
        self.assertEqual(self._status()["last_verified_at_ms"], 2_000)
        self.assertEqual(len(status["warnings"]), 1)
        self.assertIn("orphaned database rows", status["warnings"][0])

    def test_a_clean_run_carries_no_warnings(self):
        fixtures.build_database(self.source_db)

        status = backup_nightly.run_once(self._args(), now_ms=1)

        self.assertEqual(status["warnings"], [])

    def test_a_module_file_that_cannot_be_copied_stays_a_backup_failure(self):
        fixtures.build_database(self.source_db)
        modules = self.source_db.parent / "modules"
        modules.mkdir()
        (modules / "broken.db").write_bytes(b"not a database" * 100)

        status = backup_nightly.run_once(self._args(), now_ms=1)

        self.assertFalse(status["ok"])
        self.assertEqual(status["stage"], "backup")

    def test_a_failure_keeps_the_last_verified_time(self):
        fixtures.build_database(self.source_db)
        backup_nightly.run_once(self._args(), now_ms=1_000)
        self.source_db.unlink()

        status = backup_nightly.run_once(self._args(), now_ms=9_000)

        self.assertFalse(status["ok"])
        self.assertEqual(status["finished_at_ms"], 9_000)
        self.assertEqual(status["last_verified_at_ms"], 1_000)
        self.assertGreater(status["last_verified_bytes"], 0)

    def test_a_corrupt_snapshot_fails_the_drill_stage(self):
        fixtures.build_database(self.source_db)
        args = self._args()
        backup_nightly.run_once(args, now_ms=1)
        newest = sorted((self.backup_root / "db").glob("slimm-*.db"))[-1]
        newest.write_bytes(b"not a database" * 100)
        original = backup_nightly._backup
        backup_nightly._backup = lambda _args: (True, "", [])
        self.addCleanup(setattr, backup_nightly, "_backup", original)

        status = backup_nightly.run_once(args, now_ms=2)

        self.assertFalse(status["ok"])
        self.assertEqual(status["stage"], "drill")

    def test_the_status_file_is_replaced_not_appended(self):
        fixtures.build_database(self.source_db)
        backup_nightly.run_once(self._args(), now_ms=1)
        backup_nightly.run_once(self._args(), now_ms=2)

        self.assertEqual(self._status()["finished_at_ms"], 2)
        self.assertEqual([p.name for p in self.status_dir.iterdir()], ["status.json"])


class ScheduleTest(unittest.TestCase):
    def test_the_next_run_is_the_coming_hour(self):
        now = datetime(2026, 11, 4, 1, 30, tzinfo=timezone.utc)
        self.assertEqual(backup_nightly.seconds_until(now, 3), 90 * 60)

    def test_after_the_hour_it_waits_for_tomorrow(self):
        now = datetime(2026, 11, 4, 3, 0, tzinfo=timezone.utc)
        self.assertEqual(backup_nightly.seconds_until(now, 3), 24 * 3600)


if __name__ == "__main__":
    unittest.main()
