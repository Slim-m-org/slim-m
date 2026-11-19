# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Puts a scripts/backup.py backup back into a data directory a server can start on.

The backup is checked first, the way restore-drill.py checks it, and nothing
is written when it fails. Then the snapshot becomes `slimm.db`, and every file
that snapshot references is copied out of the mirror: attachments, avatars,
the banners, icons and kept originals of backup_side_files.py, and the module
data files. Files the mirror holds for rows since deleted are left behind.

The server must be stopped. A data directory that already holds a database is
refused unless --force, which moves the old database aside instead of
deleting it. docs/OPERATING.md, Backups and restore, has the commands.
"""
import argparse
import contextlib
import io
import os
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

import backup_modules
import backup_side_files
import path_guard
import restore_drill_lib

# The uid and gid the server image runs as.
SERVER_OWNER = "65532:65532"
KEY_FILE = "slimm-data.key"


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
    return parser.parse_args(argv)


def verify_backup(snapshot, backup_root, data_dir):
    """What the restore drill says about this snapshot: its exit code and its report.

    The drill's scratch copy goes under the data directory, so the backup can be mounted read-only.
    """
    report = io.StringIO()
    scratch = Path(data_dir, ".restore-check")
    args = restore_drill_lib.parse_args([
        "--backup-root", str(backup_root), "--db-snapshot", str(snapshot),
        "--scratch-dir", str(scratch),
    ])
    try:
        with contextlib.redirect_stdout(report), contextlib.redirect_stderr(report):
            code = restore_drill_lib.run(args)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return code, report.getvalue()


def _referenced_files(snapshot):
    """Every media file the snapshot references, as (directory, name) under the mirror."""
    conn = sqlite3.connect(f"file:{snapshot}?mode=ro", uri=True)
    try:
        attachments = conn.execute("SELECT sha256 FROM attachments").fetchall()
        avatars = conn.execute(
            "SELECT id FROM users WHERE avatar_updated_at IS NOT NULL AND deleted_at IS NULL"
        ).fetchall()
    finally:
        conn.close()
    files = [("attachments", path_guard.sha256_hex(blob)) for (blob,) in attachments]
    files += [("avatars", path_guard.avatar_uuid(blob)) for (blob,) in avatars]
    side_files, _ = backup_side_files.expected_files(snapshot)
    files += [(directory, name) for directory, name, _ in side_files]
    return files


def _copy_media(snapshot, backup_root, media_dir):
    copied = 0
    for directory, name in _referenced_files(snapshot):
        source = path_guard.contained_path(Path(backup_root, directory), name)
        dest_dir = Path(media_dir, directory)
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = path_guard.contained_path(dest_dir, name)
        dest.unlink(missing_ok=True)
        shutil.copy2(source, dest)
        copied += 1
    return copied


def _copy_modules(backup_root, modules_dir):
    sources = backup_modules.module_files(Path(backup_root, "modules"))
    if sources:
        Path(modules_dir).mkdir(parents=True, exist_ok=True)
    for source in sources:
        shutil.copy2(source, Path(modules_dir, source.name))
    return len(sources)


def _move_aside(database, stamp):
    """Keeps the database being replaced, with its WAL, under a name no server opens."""
    moved = []
    for suffix in ("", "-wal", "-shm"):
        current = Path(str(database) + suffix)
        if current.exists():
            kept = Path(f"{database}.before-restore-{stamp}{suffix}")
            current.rename(kept)
            moved.append(kept.name)
    return moved


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


def _refusal(args, snapshot, database):
    if snapshot is None or not snapshot.is_file():
        return f"no database snapshot found under {args.backup_root}/db/"
    if args.data_key_file and not Path(args.data_key_file).is_file():
        return f"no key file at {args.data_key_file}"
    if database.exists() and not args.force:
        return (f"{database} already exists. Stop the server and restore into an empty data "
                "directory, or pass --force to move this database aside and replace it.")
    return None


def run(args):
    backup_root, data_dir = Path(args.backup_root), Path(args.data_dir)
    snapshot = (Path(args.db_snapshot) if args.db_snapshot
                else restore_drill_lib.latest_snapshot(backup_root))
    database = data_dir / "slimm.db"
    refusal = _refusal(args, snapshot, database)
    if refusal:
        print(refusal, file=sys.stderr)
        return 1

    data_dir.mkdir(parents=True, exist_ok=True)
    code, report = verify_backup(snapshot, backup_root, data_dir)
    if code != 0:
        print(report, file=sys.stderr, end="")
        print("the backup failed its check, so nothing was restored", file=sys.stderr)
        return 1

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    moved = _move_aside(database, stamp)
    partial = data_dir / ".slimm.db.restoring"
    shutil.copyfile(snapshot, partial)
    os.replace(partial, database)
    media = _copy_media(snapshot, backup_root, data_dir / "media")
    modules = _copy_modules(backup_root, data_dir / "modules")
    if args.data_key_file:
        _place_key(args.data_key_file, data_dir)
    owned = _give_to(args.owner, data_dir)

    print(f"restored {snapshot.name} to {database}")
    print(f"media files: {media} copied; module data files: {modules} copied")
    if moved:
        print(f"the database that was here is kept as {', '.join(moved)}")
    if owned:
        print(f"owner set to {args.owner[0]}:{args.owner[1]}")
    if not args.data_key_file and not (data_dir / KEY_FILE).is_file():
        print(f"no {KEY_FILE} was restored: set SLIMM_DATA_KEY, or members with two-factor on "
              "cannot sign in until an administrator clears their factor")
    return 0
