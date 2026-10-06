#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Guard the two migration mistakes that only surface at deployment startup.

`main-builds.yml` moves the `latest` server image on every push to main, and
the live instance auto-updates from it, so a migration reaching main is a
migration reaching production within minutes. sqlx records an applied
migration by version number and validates it by a checksum over the file's
own bytes, which makes two edits fatal after the fact:

1. Two files claiming the same version. sqlx keys applied migrations by
   version, so the second one is silently never applied on a database that
   already ran the first, and a fresh database fails outright on the UNIQUE
   constraint. Three files landed on 0044 during the 2026-08-13 merge train.

2. Renaming or editing a migration already on main. The version number is
   the key and the content is the checksum, so changing either makes an
   already-deployed database refuse every later startup with "migration N
   was previously applied but has been modified". That is what took the live
   instance down for five hours on 2026-08-13, and no test could see it: the
   suite only ever builds fresh databases, where the renumbered file applies
   perfectly.

Both are checked against `origin/main` rather than against a recorded list,
so nothing here can go stale.
"""

import json
import pathlib
import subprocess
import sys

LOCKFILE = (
    pathlib.Path(__file__).resolve().parents[1]
    / "crates"
    / "slimm-server"
    / "migrations.lock.json"
)
MIGRATIONS = pathlib.Path("crates/slimm-server/migrations")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))

from migration_files import migration_files, version_of  # noqa: E402


def local_migrations() -> dict[int, tuple[str, str]]:
    found: dict[int, list[tuple[str, str]]] = {}
    for name, digest in migration_files(MIGRATIONS):
        found.setdefault(version_of(name), []).append((name, digest))

    failed = False
    resolved: dict[int, tuple[str, str]] = {}
    for version, entries in sorted(found.items()):
        if len(entries) > 1:
            names = ", ".join(name for name, _ in entries)
            print(
                f"::error::migration {version:04d} is claimed by {len(entries)} files: {names}"
                " - sqlx keys an applied migration by version, so only one of these can ever run"
            )
            failed = True
        resolved[version] = entries[0]
    if failed:
        sys.exit(1)
    return resolved


def published_migrations() -> dict[int, tuple[str, str]] | None:
    """What deployed databases have recorded, from the lockfile.

    This used to read `origin/main`, which has two holes that together took
    the live server down on 2026-08-30. Main can only catch a pull request
    that edits a migration: once a bad edit has MERGED, main is compared to
    itself and reports everything consistent. And main was never the real
    baseline anyway - a deployed database is, and it validates by a checksum
    recorded when the migration was applied, which no branch can restate.

    The relicense rewrote the SPDX header of all 54 migrations then on disk
    and was pushed straight to main with no pull request, so this gate never
    ran on it; afterwards it agreed with itself while every deployed database
    refused to start. The lockfile cannot drift that way: it records what
    each migration hashed to when it was introduced and only ever gains
    entries.
    """
    if not LOCKFILE.exists():
        return None

    published: dict[int, tuple[str, str]] = {}
    for name, digest in json.loads(LOCKFILE.read_text()).items():
        version = version_of(name)
        if version is not None:
            published[version] = (name, digest)
    return published


def main() -> int:
    if not MIGRATIONS.is_dir():
        print(f"::error::{MIGRATIONS} not found; run this from the repo root")
        return 1

    local = local_migrations()
    published = published_migrations()
    if published is None:
        print("migrations.lock.json missing; checked duplicate versions only")
        return 0

    failed = False
    for version, (name, digest) in sorted(published.items()):
        if version not in local:
            print(
                f"::error::migration {version:04d} ({name}) is locked and has been deleted"
                " - every deployed database has it applied and will refuse to start without it"
            )
            failed = True
            continue
        local_name, local_digest = local[version]
        if local_digest != digest:
            detail = (
                f"renamed to {local_name}" if local_name != name else "edited in place"
            )
            print(
                f"::error::migration {version:04d} ({name}) is locked and has been {detail}"
                " - a deployed database validates it by checksum and will refuse to start;"
                " add a new migration instead"
            )
            failed = True

    checked = len(published)
    print(f"migrations: {len(local)} local, {checked} locked, all consistent"
          if not failed else f"migrations: {checked} checked against the lockfile")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
