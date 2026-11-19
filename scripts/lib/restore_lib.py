# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Puts a scripts/backup.py backup back into a data directory a server can start on.

The backup is checked first, the way restore-drill.py checks it, and nothing
is written when it fails. Then the snapshot becomes `slimm.db`, and every file
that snapshot references is copied out of the mirror: attachments, avatars,
the banners, icons and kept originals of backup_side_files.py, and the module
data files. Files the mirror holds for rows since deleted are left behind.
restore_plan.py decides which files are copied, already there, or missing.

The server must be stopped. A data directory that already holds a database is
refused unless --force, which moves the old database aside instead of
deleting it. docs/OPERATING.md, Backups and restore, has the commands.
"""
import argparse
import os
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

import restore_drill_lib
import restore_plan

try:
    import fcntl
except ImportError:
    fcntl = None

# The uid and gid the server image runs as.
SERVER_OWNER = "65532:65532"
KEY_FILE = "slimm-data.key"
# The server's own leftover sweep removes this prefix, should a restore be cut off mid-copy.
PARTIAL_PREFIX = ".tmp-restore-"
# Where SQLite keeps its pending, reserved and shared locks: one byte each, then 510 shared.
SQLITE_LOCK_START, SQLITE_LOCK_LENGTH = 0x40000000, 512


def _owner(raw):
    try:
        uid, gid = (int(part) for part in raw.split(":"))
    except ValueError:
        raise argparse.ArgumentTypeError("must be UID:GID, for example 65532:65532") from None
    return uid, gid


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--backup-root", required=True, help="the root scripts/backup.py wrote into")
    parser.add_argument("--data-dir", required=True,
                        help="the server's data directory, /data in the compose deployment")
    parser.add_argument("--db-snapshot", default=None,
                        help="an explicit snapshot path; defaults to the newest under <backup-root>/db/")
    parser.add_argument("--data-key-file", default=None,
                        help=f"your copy of {KEY_FILE}, placed beside the database; "
                        "leave it out when the key is in SLIMM_DATA_KEY")
    parser.add_argument("--owner", type=_owner, default=_owner(SERVER_OWNER),
                        help=f"who owns the restored files when run as root (default {SERVER_OWNER}, "
                        "the user the server image runs as)")
    parser.add_argument("--force", action="store_true",
                        help="restore over an existing database, which is moved aside first")
    parser.add_argument("--allow-missing-files", action="store_true",
                        help="restore the database and every file the backup does hold, and list "
                        "the files it lacks, instead of refusing")
    return parser.parse_args(argv)


def _copy_into_place(source, dest, partial):
    """A cut-off copy never sits under the real name, and the file it replaces survives until the rename."""
    shutil.copy2(source, partial)
    os.replace(partial, dest)


def _copy_media(plan):
    for source, dest in plan.copies:
        dest.parent.mkdir(parents=True, exist_ok=True)
        _copy_into_place(source, dest, dest.with_name(PARTIAL_PREFIX + dest.name))
    return len(plan.copies)


def _move_aside(database, stamp):
    """Keeps a database being replaced, with its WAL, under a name nothing opens."""
    moved = []
    for suffix in ("", "-wal", "-shm"):
        current = Path(str(database) + suffix)
        if current.exists():
            kept = Path(f"{database}.before-restore-{stamp}{suffix}")
            current.rename(kept)
            moved.append(kept.name)
    return moved


def _copy_modules(plan, modules_dir, stamp):
    """Replaces each module data file, moving the old one aside with the WAL that would replay onto the new."""
    if plan.modules:
        modules_dir.mkdir(parents=True, exist_ok=True)
    moved = []
    for source in plan.modules:
        dest = modules_dir / source.name
        partial = modules_dir / f".{source.name}.restoring"
        shutil.copy2(source, partial)
        moved += _move_aside(dest, stamp)
        os.replace(partial, dest)
    return len(plan.modules), moved


def _place_key(key_file, data_dir):
    dest = Path(data_dir, KEY_FILE)
    shutil.copyfile(key_file, dest)
    dest.chmod(0o600)


def _give_to(owner, data_dir):
    if os.geteuid() != 0:
        return False
    uid, gid = owner
    os.chown(data_dir, uid, gid)
    for root, directories, files in os.walk(data_dir):
        for name in directories + files:
            os.chown(os.path.join(root, name), uid, gid, follow_symlinks=False)
    return True


def _open_elsewhere(database):
    """Whether another process has the database open, which a running server always does.

    Every connection in WAL mode keeps a shared lock on the file, and a server that crashed
    keeps none, so a WAL left by an unclean stop does not look like a running server.
    """
    if fcntl is None:
        return False
    try:
        handle = os.open(database, os.O_RDWR)
    except OSError:
        return False
    try:
        fcntl.lockf(handle, fcntl.LOCK_EX | fcntl.LOCK_NB, SQLITE_LOCK_LENGTH, SQLITE_LOCK_START)
    except OSError:
        return True
    finally:
        os.close(handle)
    return False


def _refusal(args, snapshot, database):
    if snapshot is None or not snapshot.is_file():
        return f"no database snapshot found under {args.backup_root}/db/"
    if args.data_key_file and not Path(args.data_key_file).is_file():
        return f"no key file at {args.data_key_file}"
    if database.exists() and not args.force:
        return (f"{database} already exists. Stop the server and restore into an empty data "
                "directory, or pass --force to move this database aside and replace it.")
    if database.exists() and _open_elsewhere(database):
        return (f"{database} is open in another process, so the server is still running and "
                "would keep writing to the database this moves aside. Run `docker compose down` "
                "first.")
    return None


def _backup_refusal(plan, allow_missing):
    """Why this backup cannot be restored; a damaged database is never restored, whatever was allowed."""
    if plan.integrity != "ok":
        return f"the snapshot failed its integrity check ({plan.integrity})"
    if plan.gaps and not allow_missing:
        return (f"the backup lacks {plan.gaps} file(s) its database references. Pass "
                "--allow-missing-files to restore the database and every file it does hold")
    return None


def _report_gaps(plan, restored):
    marker = "NOT RESTORED" if restored else "MISSING   "
    for name in plan.missing:
        print(f"  {marker}  {name}", file=sys.stderr)
    for reason in plan.malformed:
        print(f"  MALFORMED   {reason}", file=sys.stderr)


def run(args):
    backup_root, data_dir = Path(args.backup_root), Path(args.data_dir)
    snapshot = (Path(args.db_snapshot) if args.db_snapshot
                else restore_drill_lib.latest_snapshot(backup_root))
    database = data_dir / "slimm.db"
    refusal = _refusal(args, snapshot, database)
    if refusal:
        print(refusal, file=sys.stderr)
        return 1

    plan = restore_plan.build(snapshot, backup_root, data_dir)
    refusal = _backup_refusal(plan, args.allow_missing_files)
    if refusal:
        _report_gaps(plan, restored=False)
        print(f"{refusal}, so nothing was restored", file=sys.stderr)
        return 1

    data_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    moved = _move_aside(database, stamp)
    _copy_into_place(snapshot, database, data_dir / ".slimm.db.restoring")
    media = _copy_media(plan)
    modules, moved_modules = _copy_modules(plan, data_dir / "modules", stamp)
    if args.data_key_file:
        _place_key(args.data_key_file, data_dir)
    owned = _give_to(args.owner, data_dir)

    print(f"restored {snapshot.name} to {database}")
    print(f"media files: {media} copied, {plan.in_place} already in place; "
          f"module data files: {modules} copied")
    if plan.kept:
        print("not in the backup, so the copy already in the data directory was kept: "
              + ", ".join(plan.kept))
    if plan.gaps:
        print(f"{plan.gaps} file(s) the database references are in neither the backup nor "
              "the data directory:", file=sys.stderr)
        _report_gaps(plan, restored=True)
    if moved:
        print(f"the database that was here is kept as {', '.join(moved)}")
    if moved_modules:
        print(f"module data files that were here are kept in modules/ as {', '.join(moved_modules)}")
    if owned:
        print(f"owner set to {args.owner[0]}:{args.owner[1]}")
    if not args.data_key_file and not (data_dir / KEY_FILE).is_file():
        print(f"no {KEY_FILE} was restored: set SLIMM_DATA_KEY, or members with two-factor on "
              "cannot sign in until an administrator clears their factor")
    return 0
