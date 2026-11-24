# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Forgets mirror files that no retained snapshot references, so deleted data leaves the backup.

A deleted file stays in the mirror until the last snapshot that references it is pruned, so
the snapshot window (--keep) is the delay before an erasure reaches the backup disk. Nothing
is removed unless the newest snapshot passes its integrity check and every retained
snapshot can be read. A file the newest snapshot names but the mirror lacks does not block it,
since pruning only removes files no retained snapshot names.
"""
import sqlite3
from pathlib import Path

import backup_side_files
import restore_drill_lib
import restore_plan

MIRRORED_DIRECTORIES = (backup_side_files.ATTACHMENTS, backup_side_files.AVATARS)


def _referenced(snapshots):
    names = set()
    for snapshot in snapshots:
        for directory, name, _ in restore_plan._referenced_files(snapshot):
            names.add((directory, name))
    return names


def prune(backup_root, snapshots):
    """Removes the mirror files nothing in `snapshots` names; returns them, or None when it refused."""
    snapshots = sorted(snapshots)
    if not snapshots or restore_drill_lib.check_integrity(snapshots[-1]) != "ok":
        return None
    try:
        keep = _referenced(snapshots)
    except (sqlite3.Error, OSError):
        return None
    removed = []
    for directory in MIRRORED_DIRECTORIES:
        for path in sorted(Path(backup_root, directory).glob("*")):
            if path.is_file() and (directory, path.name) not in keep:
                path.unlink(missing_ok=True)
                removed.append(f"{directory}/{path.name}")
    return removed
