# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Which files count as migrations, and the sha384 sqlx validates each by.

One definition shared by the lockfile writer, the immutability test and the
version check, so they cannot disagree on what a migration is.
"""
import hashlib
import pathlib
import re

NAME = re.compile(r"^(\d+)_.*\.sql$")


def version_of(name: str) -> int | None:
    match = NAME.match(name)
    return int(match.group(1)) if match else None


def migration_files(directory: pathlib.Path) -> list[tuple[str, str]]:
    """`(file name, sha384 hex digest)` for every migration, sorted by name."""
    return [
        (path.name, hashlib.sha384(path.read_bytes()).hexdigest())
        for path in sorted(directory.glob("*.sql"))
        if NAME.match(path.name)
    ]
