# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Takes a consistent backup of the database and the attachment/avatar bytes
Litestream does not cover (see deploy/README.md's "Backups" section).

The database half is a `VACUUM INTO` snapshot: SQLite runs it inside its own
read transaction, so it is a point-in-time copy even while the server keeps
writing through it in WAL mode, and the result is a single ordinary file
with no `-wal`/`-shm` siblings of its own. It does not need the server
stopped, and it does not need write access to the source (opened
`mode=ro`).

The media half exploits content addressing: every attachment and custom
emoji is named after its own sha256, so a byte-identical file already
present in the backup mirror is provably already backed up and is never
re-copied. Avatars are not content-addressed (one mutable file per account),
so they are copied every run, which is cheap since they are capped and few.
Nothing is ever deleted from the media mirror by this script - it grows
by addition only, which is the safe direction for a backup to err in.

This module holds the logic; scripts/backup.py is the thin CLI entry point
that imports it (see that file for the command-line usage and the docker
one-liner for running this against a live volume).

What this backup does NOT cover, and why that is not an oversight:

- The server's Ed25519 identity secret (the `server_identity.secret_key`
  column, see crates/slimm-server/src/identity.rs) is an ordinary row in the
  same database this script copies. There is no separate identity file to
  additionally exclude or protect - the database snapshot IS the thing that
  needs to be handled with the same care as the live deployment, not put in
  a public bucket next to a checksum file.
- Nothing in `deploy/.env` (LiveKit keys, Litestream credentials, ACME
  email) is touched. Those are operator secrets that never reach the
  database or the media volume, and back them up by your own means.
- Litestream's own replica is untouched and unread; run both, see
  deploy/README.md.
"""
import argparse
import json
import os
import shutil
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

import path_guard


def _default(env_name, fallback):
    return os.environ.get(env_name, fallback)


def _keep_count(raw):
    count = int(raw)
    if count < 1:
        raise argparse.ArgumentTypeError("must be at least 1, or omit it to keep every snapshot")
    return count


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--database-path",
        default=_default("SLIMM_DATABASE_PATH", "data/slimm.db"),
        help="the live SQLite file (default: $SLIMM_DATABASE_PATH or data/slimm.db)",
    )
    parser.add_argument(
        "--media-dir",
        default=_default("SLIMM_ATTACHMENTS_DIR", "data/media"),
        help="the media root holding attachments/ and avatars/ "
        "(default: $SLIMM_ATTACHMENTS_DIR or data/media)",
    )
    parser.add_argument(
        "--backup-root", required=True, help="where snapshots and the media mirror live"
    )
    parser.add_argument(
        "--keep",
        type=_keep_count,
        default=None,
        help="prune database snapshots beyond this many, oldest first "
        "(default: keep every snapshot)",
    )
    return parser.parse_args(argv)


def vacuum_into(source_db, dest_db):
    resolved_source = Path(source_db).resolve()
    uri = f"file:{quote(str(resolved_source), safe='/')}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        conn.execute("VACUUM INTO ?", (str(dest_db),))
    finally:
        conn.close()


def sync_attachments(snapshot_db, source_media_dir, mirror_dir):
    source_dir = Path(source_media_dir, "attachments")
    dest_dir = Path(mirror_dir, "attachments")
    dest_dir.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(snapshot_db))
    rows = conn.execute("SELECT sha256, size FROM attachments").fetchall()
    conn.close()

    copied, already_present, missing_source, repaired, malformed = 0, 0, [], 0, []
    for blob, size in rows:
        try:
            digest = path_guard.sha256_hex(blob)
            dest = path_guard.contained_path(dest_dir, digest)
            src = path_guard.contained_path(source_dir, digest)
        except path_guard.PathValidationError as error:
            malformed.append(str(error))
            continue
        # A cheap size check, not a full hash: catches a truncated mirror file.
        if dest.is_file() and dest.stat().st_size == size:
            already_present += 1
            continue
        was_present = dest.is_file()
        if not src.is_file():
            missing_source.append(digest)
            continue
        if was_present:
            repaired += 1
        _independent_copy(src, dest)
        copied += 1
    return {
        "total": len(rows),
        "copied": copied,
        "repaired": repaired,
        "already_present": already_present,
        "missing_source": missing_source,
        "malformed": malformed,
    }


def sync_avatars(snapshot_db, source_media_dir, mirror_dir):
    source_dir = Path(source_media_dir, "avatars")
    dest_dir = Path(mirror_dir, "avatars")
    dest_dir.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(snapshot_db))
    rows = conn.execute(
        "SELECT id FROM users WHERE avatar_updated_at IS NOT NULL"
    ).fetchall()
    conn.close()

    copied, missing_source, malformed = 0, [], []
    for (blob,) in rows:
        try:
            name = path_guard.avatar_uuid(blob)
            src = path_guard.contained_path(source_dir, name)
            dest = path_guard.contained_path(dest_dir, name)
        except path_guard.PathValidationError as error:
            malformed.append(str(error))
            continue
        if not src.is_file():
            missing_source.append(name)
            continue
        _independent_copy(src, dest)
        copied += 1
    return {
        "total": len(rows),
        "copied": copied,
        "missing_source": missing_source,
        "malformed": malformed,
    }


def _independent_copy(src, dest):
    dest.unlink(missing_ok=True)
    shutil.copy2(src, dest)


def prune_snapshots(db_dir, keep):
    if keep is None:
        return []
    if keep < 1:
        raise ValueError(f"keep must be at least 1, got {keep}")
    snapshots = sorted(Path(db_dir).glob("slimm-*.db"))
    stale = snapshots[:-keep]
    removed = []
    for snap in stale:
        snap.unlink(missing_ok=True)
        Path(str(snap) + ".manifest.json").unlink(missing_ok=True)
        removed.append(snap.name)
    return removed


def run(args):
    source_db = Path(args.database_path)
    if not source_db.is_file():
        print(f"no database at {source_db}", file=sys.stderr)
        return 1

    backup_root = Path(args.backup_root)
    db_dir = backup_root / "db"
    db_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    dest_db = db_dir / f"slimm-{timestamp}.db"
    partial_db = db_dir / f".slimm-{timestamp}.db.partial"

    t0 = time.time()
    try:
        vacuum_into(source_db, partial_db)
        os.replace(partial_db, dest_db)
    finally:
        partial_db.unlink(missing_ok=True)
    vacuum_seconds = time.time() - t0
    snapshot_bytes = dest_db.stat().st_size

    attachments = sync_attachments(dest_db, args.media_dir, backup_root)
    avatars = sync_avatars(dest_db, args.media_dir, backup_root)
    removed = prune_snapshots(db_dir, args.keep)

    manifest = {
        "created_at": timestamp,
        "source_database": str(source_db),
        "source_media_dir": str(args.media_dir),
        "vacuum_seconds": round(vacuum_seconds, 3),
        "snapshot_bytes": snapshot_bytes,
        "attachments": attachments,
        "avatars": avatars,
        "pruned_snapshots": removed,
        "not_covered": [
            "operator secrets in deploy/.env (LiveKit, Litestream, ACME)",
        ],
    }
    Path(str(dest_db) + ".manifest.json").write_text(json.dumps(manifest, indent=2))

    print(f"snapshot: {dest_db} ({manifest['snapshot_bytes']} bytes, {vacuum_seconds:.3f}s)")
    print(
        f"attachments: {attachments['copied']} copied "
        f"({attachments['repaired']} repaired), "
        f"{attachments['already_present']} already present, "
        f"{len(attachments['missing_source'])} missing on disk"
    )
    for digest in attachments["missing_source"]:
        print(f"  MISSING SOURCE FILE  attachments/{digest}", file=sys.stderr)
    for reason in attachments["malformed"]:
        print(f"  MALFORMED ID  attachments: {reason}", file=sys.stderr)
    print(
        f"avatars: {avatars['copied']} copied, "
        f"{len(avatars['missing_source'])} missing on disk"
    )
    for name in avatars["missing_source"]:
        print(f"  MISSING SOURCE FILE  avatars/{name}", file=sys.stderr)
    for reason in avatars["malformed"]:
        print(f"  MALFORMED ID  avatars: {reason}", file=sys.stderr)
    if removed:
        print(f"pruned {len(removed)} older snapshot(s): {', '.join(removed)}")

    if attachments["missing_source"] or avatars["missing_source"]:
        print(
            "backup completed, but the LIVE deployment already has orphaned "
            "database rows with no file behind them; the restore drill will "
            "report the same gap",
            file=sys.stderr,
        )
        return 1
    if attachments["malformed"] or avatars["malformed"]:
        print(
            "backup completed, but the database holds a row whose id is not "
            "a well-formed reference; it was skipped rather than mirrored",
            file=sys.stderr,
        )
        return 1
    return 0
