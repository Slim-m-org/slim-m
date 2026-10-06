# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""--keep handling and half-written snapshots in scripts/lib/backup_lib.py."""
import argparse
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_fixtures as fixtures  # noqa: E402
import backup_lib  # noqa: E402

TIMESTAMPS = ("20260101T000000Z", "20260102T000000Z", "20260103T000000Z")


class PruneTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.db_dir = self.root / "bk" / "db"
        self.db_dir.mkdir(parents=True)
        fixtures.build_database(self.root / "live.db")
        (self.root / "media").mkdir()

    def _args(self, keep):
        return argparse.Namespace(
            database_path=str(self.root / "live.db"),
            media_dir=str(self.root / "media"),
            backup_root=str(self.root / "bk"),
            keep=keep,
        )

    def _seed_old_snapshots(self):
        for ts in TIMESTAMPS:
            (self.db_dir / f"slimm-{ts}.db").write_bytes(b"x")
            (self.db_dir / f"slimm-{ts}.db.manifest.json").write_text("{}")

    def _snapshots(self):
        return sorted(p.name for p in self.db_dir.glob("slimm-*.db"))


class KeepValueTest(PruneTestCase):
    def test_keep_below_one_is_rejected_at_the_command_line(self):
        for bad in ("0", "-1"):
            with self.subTest(keep=bad), mock.patch("sys.stderr"):
                with self.assertRaises(SystemExit):
                    backup_lib.parse_args(["--backup-root", "/x", "--keep", bad])

    def test_keep_one_is_accepted(self):
        args = backup_lib.parse_args(["--backup-root", "/x", "--keep", "1"])
        self.assertEqual(args.keep, 1)

    def test_prune_refuses_a_keep_that_would_delete_everything(self):
        self._seed_old_snapshots()
        for bad in (0, -1):
            with self.subTest(keep=bad), self.assertRaises(ValueError):
                backup_lib.prune_snapshots(self.db_dir, bad)
        self.assertEqual(len(self._snapshots()), 3)


class PruneSnapshotsTest(PruneTestCase):
    def test_keeps_the_newest_n_and_drops_their_manifests(self):
        self._seed_old_snapshots()
        removed = backup_lib.prune_snapshots(self.db_dir, 2)
        self.assertEqual(removed, [f"slimm-{TIMESTAMPS[0]}.db"])
        self.assertEqual(self._snapshots(), [f"slimm-{ts}.db" for ts in TIMESTAMPS[1:]])
        self.assertFalse((self.db_dir / f"slimm-{TIMESTAMPS[0]}.db.manifest.json").exists())

    def test_fewer_snapshots_than_keep_removes_nothing(self):
        self._seed_old_snapshots()
        self.assertEqual(backup_lib.prune_snapshots(self.db_dir, 10), [])

    def test_none_keeps_everything(self):
        self._seed_old_snapshots()
        self.assertEqual(backup_lib.prune_snapshots(self.db_dir, None), [])
        self.assertEqual(len(self._snapshots()), 3)

    def test_run_with_keep_one_leaves_exactly_the_new_snapshot(self):
        self._seed_old_snapshots()
        self.assertEqual(backup_lib.run(self._args(1)), 0)
        snapshots = self._snapshots()
        self.assertEqual(len(snapshots), 1)
        self.assertGreater(snapshots[0], f"slimm-{TIMESTAMPS[-1]}.db")


class HalfWrittenSnapshotTest(PruneTestCase):
    def test_a_vacuum_that_dies_leaves_no_snapshot_named_file(self):
        def dying_vacuum(_source, dest):
            Path(dest).write_bytes(b"SQLite format 3\0truncated")
            raise OSError("disk full")

        with mock.patch.object(backup_lib, "vacuum_into", dying_vacuum):
            with self.assertRaises(OSError):
                backup_lib.run(self._args(None))
        self.assertEqual(self._snapshots(), [])
        self.assertEqual(list(self.db_dir.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
