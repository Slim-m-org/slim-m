# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Decides what a restore copies, what the data directory already holds, and what nobody has.

Every file the snapshot references ends up in one of four places. The mirror
has a good copy and the data directory lacks it: copied. The data directory
already holds a file of the same size: left in place, since attachments are
named after their content. The mirror lacks it but the data directory being
rolled back still has it: kept, which is every banner and icon of a backup
taken before backup_side_files.py existed. Neither has it: missing, which
stops the restore unless the operator passes --allow-missing-files.
"""
from dataclasses import dataclass, field
from pathlib import Path

import backup_modules
import backup_side_files
import file_digest
import path_guard
import sqlite_read_only
import restore_drill_lib

ATTACHMENTS = backup_side_files.ATTACHMENTS
AVATARS = backup_side_files.AVATARS


@dataclass
class Plan:
    integrity: str
    copies: list = field(default_factory=list)
    modules: list = field(default_factory=list)
    in_place: int = 0
    kept: list = field(default_factory=list)
    missing: list = field(default_factory=list)
    malformed: list = field(default_factory=list)

    @property
    def gaps(self):
        return len(self.missing) + len(self.malformed)


def _referenced_files(snapshot):
    """Every media file the snapshot references, as (directory, name, size or None)."""
    conn = sqlite_read_only.connect(snapshot)
    try:
        attachments = conn.execute("SELECT sha256, size FROM attachments").fetchall()
        avatars = conn.execute(
            "SELECT id FROM users WHERE avatar_updated_at IS NOT NULL AND deleted_at IS NULL"
        ).fetchall()
    finally:
        conn.close()
    named = [(ATTACHMENTS, path_guard.sha256_hex, blob, size) for blob, size in attachments]
    named += [(AVATARS, path_guard.avatar_uuid, blob, None) for (blob,) in avatars]
    files = []
    for directory, name_of, blob, size in named:
        try:
            files.append((directory, name_of(blob), size))
        except path_guard.PathValidationError:
            continue
    side_files, _ = backup_side_files.expected_files(snapshot)
    return files + side_files


def _unusable_in_mirror(snapshot, backup_root):
    """The files the mirror lacks or holds damaged, with the rows that name no file at all."""
    attachments = restore_drill_lib.check_attachments(snapshot, backup_root)
    avatars = restore_drill_lib.check_avatars(snapshot, backup_root)
    side_files = backup_side_files.check(snapshot, backup_root)
    unusable = {f"{ATTACHMENTS}/{digest}" for digest in attachments["missing"]}
    unusable |= {f"{ATTACHMENTS}/{row[0]}" for row in attachments["mismatched"]}
    unusable |= {f"{AVATARS}/{name}" for name, _ in avatars["missing"]}
    unusable |= set(side_files["missing"])
    malformed = attachments["malformed"] + avatars["malformed"] + side_files["malformed"]
    return unusable, malformed


def _is_attachment(directory, name):
    return directory == ATTACHMENTS and not name.endswith(backup_side_files.ORIGINAL_SUFFIX)


def _data_directory_holds(dest, directory, name, size):
    if not backup_side_files.is_present(dest, size):
        return False
    return not _is_attachment(directory, name) or file_digest.sha256_of_file(dest)[0] == name


def _plan_media(plan, snapshot, backup_root, media_dir):
    unusable, plan.malformed = _unusable_in_mirror(snapshot, backup_root)
    for directory, name, size in _referenced_files(snapshot):
        label = f"{directory}/{name}"
        try:
            source = path_guard.contained_path(Path(backup_root, directory), name)
            dest = path_guard.contained_path(Path(media_dir, directory), name)
        except path_guard.PathValidationError as error:
            plan.malformed.append(str(error))
            continue
        if label in unusable:
            held = _data_directory_holds(dest, directory, name, size)
            (plan.kept if held else plan.missing).append(label)
        elif size is not None and backup_side_files.is_present(dest, size):
            plan.in_place += 1
        else:
            plan.copies.append((source, dest))


def _plan_modules(plan, snapshot, backup_root, modules_dir):
    checked = backup_modules.check_modules(backup_root, snapshot)
    broken = {name for name, _ in checked["broken"]}
    for source in backup_modules.module_files(Path(backup_root, "modules")):
        if source.name not in broken:
            plan.modules.append(source)
    for name in sorted(broken | set(checked["missing"])):
        held = Path(modules_dir, name).is_file()
        (plan.kept if held else plan.missing).append(f"modules/{name}")


def build(snapshot, backup_root, data_dir):
    """Checks the backup the way restore-drill.py does and returns the plan; nothing is written."""
    plan = Plan(integrity=restore_drill_lib.check_integrity(snapshot))
    if plan.integrity == "ok":
        _plan_media(plan, snapshot, backup_root, Path(data_dir, "media"))
        _plan_modules(plan, snapshot, backup_root, Path(data_dir, "modules"))
    return plan
