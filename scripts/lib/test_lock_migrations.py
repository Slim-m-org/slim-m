# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""lock-migrations.py is the only writer of migrations.lock.json: it appends
new migrations and refuses, leaving the lockfile alone, to rewrite a locked one."""
import contextlib
import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))

from migration_files import migration_files  # noqa: E402


def _load_script():
    spec = importlib.util.spec_from_file_location(
        "lock_migrations", LIB.parent / "lock-migrations.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LockMigrationsTest(unittest.TestCase):
    def setUp(self):
        root = Path(tempfile.mkdtemp(prefix="lock-migrations-test-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        self.migrations = root / "migrations"
        self.migrations.mkdir()
        self.lockfile = root / "migrations.lock.json"
        self.script = _load_script()

    def write(self, name, body):
        (self.migrations / name).write_text(body)

    def lock(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = self.script.main(self.migrations, self.lockfile)
        return code, out.getvalue(), err.getvalue()

    def locked(self):
        return json.loads(self.lockfile.read_text())

    def test_a_new_migration_is_appended_with_its_sha384(self):
        self.write("0001_init.sql", "create table a (id int);")
        code, out, _err = self.lock()
        self.assertEqual(code, 0)
        self.assertIn("locked 1 new migration(s)", out)
        self.assertEqual(self.locked(), dict(migration_files(self.migrations)))
        self.assertEqual(len(self.locked()["0001_init.sql"]), 96)

    def test_a_second_migration_adds_exactly_one_entry(self):
        self.write("0001_init.sql", "create table a (id int);")
        self.lock()
        before = self.locked()
        self.write("0002_more.sql", "create table b (id int);")
        code, out, _err = self.lock()
        self.assertEqual(code, 0)
        after = self.locked()
        self.assertEqual(sorted(set(after) - set(before)), ["0002_more.sql"])
        self.assertEqual({k: after[k] for k in before}, before)
        self.assertIn("0002_more.sql", out)

    def test_an_edited_locked_migration_is_refused_and_the_lockfile_untouched(self):
        self.write("0001_init.sql", "create table a (id int);")
        self.lock()
        before = self.lockfile.read_text()
        self.write("0001_init.sql", "create table a (id int, extra int);")
        self.write("0002_more.sql", "create table b (id int);")
        code, _out, err = self.lock()
        self.assertEqual(code, 1)
        self.assertIn("0001_init.sql", err)
        self.assertEqual(self.lockfile.read_text(), before)

    def test_a_rerun_with_nothing_new_changes_nothing(self):
        self.write("0001_init.sql", "create table a (id int);")
        self.lock()
        before = self.lockfile.read_text()
        code, out, _err = self.lock()
        self.assertEqual(code, 0)
        self.assertIn("none", out)
        self.assertEqual(self.lockfile.read_text(), before)

    def test_files_that_are_not_numbered_migrations_are_ignored(self):
        self.write("0001_init.sql", "create table a (id int);")
        self.write("notes.sql", "-- scratch")
        self.write("readme.md", "docs")
        self.lock()
        self.assertEqual(list(self.locked()), ["0001_init.sql"])


if __name__ == "__main__":
    unittest.main()
