# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""An applied migration's bytes may never change, checked against a lockfile.

`check-migration-versions.py` already compares migrations to `origin/main`,
which catches a pull request that edits one. It cannot catch a change that is
already ON main, and it has no knowledge of what a deployed database actually
recorded - and the deployed database is the only baseline that matters, since
sqlx validates every applied migration by a sha384 over the file's bytes and
refuses to start the process when one differs.

That gap took the live server down on 2026-08-30. The PolyForm relicense
rewrote the SPDX comment at the top of all 54 migration files then on disk.
Every checksum changed, the image built and deployed on its own, and the
server bootlooped on `migration 1 was previously applied but has been
modified`. The relicense was pushed straight to main with no pull request, so
the existing gate never ran on it; and once it had merged, that gate compared
main to itself and reported everything consistent.

A lockfile is immune to both. It records what each migration hashed to when
it was introduced, so any later edit - by anyone, on any branch, merged or
not - fails here rather than in production. Adding a NEW migration adds a new
entry; that is the only edit to this file that is ever correct.
"""

import json
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from migration_files import migration_files  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = REPO_ROOT / "crates" / "slimm-server" / "migrations"
LOCKFILE = REPO_ROOT / "crates" / "slimm-server" / "migrations.lock.json"


def on_disk() -> dict[str, str]:
    return dict(migration_files(MIGRATIONS))


class MigrationsAreImmutableTest(unittest.TestCase):
    def test_no_applied_migration_changed(self):
        locked = json.loads(LOCKFILE.read_text())
        disk = on_disk()
        self.assertTrue(disk, "found no migrations; the check ran against nothing")
        changed = [
            name
            for name, digest in locked.items()
            if name in disk and disk[name] != digest
        ]
        self.assertEqual(
            changed,
            [],
            "these migrations were modified after being applied: "
            f"{changed}. A deployed database validates each by checksum and "
            "will refuse to start - this is what bootlooped production on "
            "2026-08-30. Revert the edit; fix mistakes with a NEW migration.",
        )

    def test_no_applied_migration_vanished(self):
        locked = json.loads(LOCKFILE.read_text())
        disk = on_disk()
        gone = sorted(set(locked) - set(disk))
        self.assertEqual(
            gone,
            [],
            f"these migrations were deleted or renamed: {gone}. A deployed "
            "database still has them recorded and will refuse to start.",
        )

    def test_every_migration_on_disk_is_locked(self):
        locked = json.loads(LOCKFILE.read_text())
        unlocked = sorted(set(on_disk()) - set(locked))
        self.assertEqual(
            unlocked,
            [],
            f"these migrations are not in the lockfile: {unlocked}. Add them "
            "with: python3 scripts/lock-migrations.py",
        )


if __name__ == "__main__":
    unittest.main()
