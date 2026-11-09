# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for the stale scratch sweep in scripts/lib/restore_drill_lib.py."""
import contextlib
import io
import os
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import restore_drill_lib  # noqa: E402
from test_restore_drill_lib import RestoreDrillTestCase  # noqa: E402


class SweepStaleScratchTest(RestoreDrillTestCase):
    def _scratch(self, name, age_s):
        path = self.backup_root / "restore-drill" / name
        path.mkdir(parents=True)
        (path / "slimm.db").write_bytes(b"left behind by a killed run")
        then = time.time() - age_s
        os.utime(path, (then, then))
        return path

    def _run(self, *extra):
        args = restore_drill_lib.parse_args(["--backup-root", str(self.backup_root), *extra])
        with contextlib.redirect_stdout(io.StringIO()):
            return restore_drill_lib.run(args)

    def _old(self):
        return restore_drill_lib.STALE_SCRATCH_AGE_S + 60

    def test_a_copy_a_killed_run_left_behind_is_removed_by_the_next_run(self):
        self._write_snapshot()
        stale = self._scratch("20260101T030000Z", self._old())

        self.assertEqual(self._run(), 0)

        self.assertFalse(stale.exists())

    def test_a_recent_copy_may_belong_to_a_running_drill_and_is_kept(self):
        self._write_snapshot()
        recent = self._scratch("20260101T030000Z", 60)

        self._run()

        self.assertTrue(recent.exists())

    def test_a_directory_that_is_not_a_drill_copy_is_never_touched(self):
        self._write_snapshot()
        other = self._scratch("notes-from-the-operator", self._old())

        self._run()

        self.assertTrue(other.exists())

    def test_keep_scratch_leaves_older_copies_alone(self):
        self._write_snapshot()
        stale = self._scratch("20260101T030000Z", self._old())

        self._run("--keep-scratch")

        self.assertTrue(stale.exists())

    def test_an_explicit_scratch_dir_leaves_older_copies_alone(self):
        self._write_snapshot()
        stale = self._scratch("20260101T030000Z", self._old())

        self._run("--scratch-dir", str(self.root / "mine"))

        self.assertTrue(stale.exists())


if __name__ == "__main__":
    unittest.main()
