# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Which migration a database snapshot is at, so a rollback can pick one the older server can open.

A server refuses a database holding a migration it does not know, and the
nightly backup keeps writing snapshots after an upgrade, so the newest
snapshot is often the wrong one to roll back to.
"""
import sqlite3
from pathlib import Path
from urllib.parse import quote


def schema_version(db_path):
    """The highest migration applied to this database, or None when it cannot be read."""
    uri = f"file:{quote(str(Path(db_path).resolve()), safe='/')}?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True)
    except sqlite3.Error:
        return None
    try:
        return conn.execute("SELECT max(version) FROM _sqlx_migrations WHERE success").fetchone()[0]
    except sqlite3.Error:
        return None
    finally:
        conn.close()


def snapshots(backup_root):
    """Every snapshot under the backup root with its schema version, oldest first."""
    found = sorted(Path(backup_root, "db").glob("slimm-*.db"))
    return [(snapshot, schema_version(snapshot)) for snapshot in found]


def newest_before(backup_root, migration):
    """The newest snapshot that holds no migration from `migration` on, or None."""
    older = [snapshot for snapshot, version in snapshots(backup_root)
             if version is not None and version < migration]
    return older[-1] if older else None


def describe(version):
    return f"migration {version}" if version is not None else "schema unknown"
