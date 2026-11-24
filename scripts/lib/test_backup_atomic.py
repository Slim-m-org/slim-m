# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Mirror copies replace the old file only once the new one is whole, and the mirror can forget."""
import argparse
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_fixtures as fixtures  # noqa: E402
import backup_lib  # noqa: E402
import backup_side_files  # noqa: E402


def quiet(call, *args):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return call(*args)


class AtomicCopyTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "src").mkdir()
        (self.root / "dest").mkdir()
        self.src = self.root / "src" / "f"
        self.dest = self.root / "dest" / "f"
        self.src.write_bytes(b"new bytes")
        self.dest.write_bytes(b"last good copy")

    def _cut_off_copy(self, *_):
        raise OSError("no space left on device")

    def test_an_interrupted_copy_leaves_the_previous_mirror_file_intact(self):
        with mock.patch("shutil.copy2", side_effect=self._cut_off_copy):
            with self.assertRaises(OSError):
                backup_lib._independent_copy(self.src, self.dest)

        self.assertEqual(self.dest.read_bytes(), b"last good copy")
        self.assertEqual([p.name for p in self.dest.parent.iterdir()], ["f"])

    def test_a_finished_copy_replaces_the_file_without_a_partial_left(self):
        backup_lib._independent_copy(self.src, self.dest)

        self.assertEqual(self.dest.read_bytes(), b"new bytes")
        self.assertEqual([p.name for p in self.dest.parent.iterdir()], ["f"])

    def test_a_side_file_copy_that_is_cut_off_keeps_the_previous_mirror_file(self):
        database = self.root / "live.db"
        fixtures.build_database(database)
        import sqlite3
        conn = sqlite3.connect(str(database))
        conn.execute("UPDATE space_settings SET icon_updated_at = 1")
        conn.commit()
        conn.close()
        media, mirror = self.root / "media", self.root / "mirror"
        (media / "avatars").mkdir(parents=True)
        (mirror / "avatars").mkdir(parents=True)
        (media / "avatars" / "space-icon").write_bytes(b"new icon")
        (mirror / "avatars" / "space-icon").write_bytes(b"old icon")

        with mock.patch("shutil.copy2", side_effect=self._cut_off_copy):
            with self.assertRaises(OSError):
                backup_side_files.sync(database, media, mirror)

        self.assertEqual((mirror / "avatars" / "space-icon").read_bytes(), b"old icon")


class PruneMirrorTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.media = self.root / "media"
        self.keep_data, self.gone_data = b"kept attachment", b"erased attachment"
        self.keep, self.gone = fixtures.sha256_of(self.keep_data), fixtures.sha256_of(self.gone_data)

    def _args(self, *, prune):
        return argparse.Namespace(
            database_path=str(self.root / "slimm.db"), media_dir=str(self.media),
            backup_root=str(self.root / "bk"), keep=None, prune_mirror=prune,
        )

    def _live(self, attachments):
        fixtures.build_database(self.root / "slimm.db", attachments=attachments)

    def _backup(self, *, prune):
        code, _ = quiet(backup_lib.take_backup, self._args(prune=prune))
        self.assertEqual(code, 0)
        self._date_newest_snapshot()

    def _date_newest_snapshot(self):
        """Snapshots are named to the second, so each run is moved to its own day."""
        db_dir = self.root / "bk" / "db"
        newest = sorted(db_dir.glob("slimm-*.db"))[-1]
        self.runs = getattr(self, "runs", 0) + 1
        dated = db_dir / f"slimm-2026010{self.runs}T000000Z.db"
        newest.rename(dated)
        Path(str(newest) + ".manifest.json").rename(Path(str(dated) + ".manifest.json"))

    def _mirror(self):
        return sorted(p.name for p in (self.root / "bk" / "attachments").iterdir())

    def _run_twice_with_a_deletion_between(self, *, prune):
        both = [(self.keep, len(self.keep_data), "image/png"),
                (self.gone, len(self.gone_data), "image/png")]
        fixtures.write_attachment_file(self.media, self.keep, self.keep_data)
        fixtures.write_attachment_file(self.media, self.gone, self.gone_data)
        self._live(both)
        self._backup(prune=prune)
        self._live(both[:1])
        (self.media / "attachments" / self.gone.hex()).unlink()

    def test_without_the_flag_a_deleted_attachment_stays_in_the_mirror(self):
        self._run_twice_with_a_deletion_between(prune=False)
        self._backup(prune=False)

        self.assertIn(self.gone.hex(), self._mirror())

    def test_a_file_a_retained_snapshot_still_references_is_kept(self):
        self._run_twice_with_a_deletion_between(prune=True)
        self._backup(prune=True)

        self.assertIn(self.gone.hex(), self._mirror())

    def test_a_file_no_retained_snapshot_references_is_removed(self):
        self._run_twice_with_a_deletion_between(prune=True)
        self._backup(prune=True)
        for snapshot in sorted((self.root / "bk" / "db").glob("slimm-*.db"))[:-1]:
            snapshot.unlink()
        self._backup(prune=True)

        self.assertEqual(self._mirror(), [self.keep.hex()])

    def _prune_after_the_older_snapshot_is_gone(self):
        self._run_twice_with_a_deletion_between(prune=True)
        self._backup(prune=True)
        for snapshot in sorted((self.root / "bk" / "db").glob("slimm-*.db"))[:-1]:
            snapshot.unlink()

    def test_a_dangling_row_does_not_stop_the_prune(self):
        self._prune_after_the_older_snapshot_is_gone()
        (self.root / "bk" / "attachments" / self.keep.hex()).unlink()
        (self.media / "attachments" / self.keep.hex()).unlink()

        quiet(backup_lib.take_backup, self._args(prune=True))

        self.assertNotIn(self.gone.hex(), self._mirror())

    def test_nothing_is_removed_when_the_newest_snapshot_fails_its_integrity_check(self):
        self._prune_after_the_older_snapshot_is_gone()

        with mock.patch("restore_drill_lib.check_integrity", return_value="bad"):
            _, warnings = quiet(backup_lib.take_backup, self._args(prune=True))

        self.assertIn(self.gone.hex(), self._mirror())
        self.assertTrue(any("not pruned" in w for w in warnings))


if __name__ == "__main__":
    unittest.main()
