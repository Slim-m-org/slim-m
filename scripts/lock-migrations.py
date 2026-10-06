# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Records a NEW migration's checksum in migrations.lock.json.

Only ever adds. It refuses to rewrite an entry that already exists, because
changing one is exactly the mistake the lockfile is there to catch: a
deployed database validates every applied migration by this checksum and
refuses to start when it differs.
"""

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))

from migration_files import migration_files  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MIGRATIONS = REPO_ROOT / "crates" / "slimm-server" / "migrations"
LOCKFILE = REPO_ROOT / "crates" / "slimm-server" / "migrations.lock.json"


def main(migrations: pathlib.Path = MIGRATIONS, lockfile: pathlib.Path = LOCKFILE) -> int:
    locked = json.loads(lockfile.read_text()) if lockfile.exists() else {}
    added, conflicts = [], []
    for name, digest in migration_files(migrations):
        if name in locked:
            if locked[name] != digest:
                conflicts.append(name)
            continue
        locked[name] = digest
        added.append(name)

    if conflicts:
        print(
            "refusing to rewrite an existing entry: "
            f"{conflicts}\nThose migrations were modified after being locked. "
            "A deployed database will refuse to start. Revert the edit and "
            "fix the mistake with a NEW migration instead.",
            file=sys.stderr,
        )
        return 1

    lockfile.write_text(json.dumps(locked, indent=2, sort_keys=True) + "\n")
    print(f"locked {len(added)} new migration(s): {added or 'none'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
