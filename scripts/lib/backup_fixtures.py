"""A SQLite database and media tree for the backup and restore-drill tests,
built by running the real migrations in crates/slimm-server/migrations in
order, so a renamed or retyped column that backup_lib.py or
restore_drill_lib.py reads (users.avatar_updated_at, attachments.sha256,
attachments.size) breaks these tests instead of the first real backup.

Rows are inserted only into the columns those two libraries read; every other
column takes its migration default.
"""
import hashlib
import sqlite3
import uuid
from pathlib import Path

MIGRATIONS_DIR = Path(__file__).resolve().parents[2] / "crates" / "slimm-server" / "migrations"


def apply_migrations(conn, migrations_dir=MIGRATIONS_DIR):
    for migration in sorted(Path(migrations_dir).glob("*.sql")):
        conn.executescript(migration.read_text())


def build_database(path, attachments=(), avatar_users=(), migrations_dir=MIGRATIONS_DIR):
    """attachments: (sha256_bytes, size, content_type) tuples.
    avatar_users: (user_id_bytes, username) tuples, each marked as having
    an avatar (avatar_updated_at set)."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path))
    try:
        apply_migrations(conn, migrations_dir)
        conn.executemany(
            "INSERT INTO attachments (sha256, size, content_type, created_at) "
            "VALUES (?, ?, ?, 0)",
            attachments,
        )
        conn.executemany(
            "INSERT INTO users (id, username, display_name, created_at, avatar_updated_at) "
            "VALUES (?, ?, ?, 0, 1)",
            [(user_id, username, username) for user_id, username in avatar_users],
        )
        conn.commit()
    finally:
        conn.close()


def sha256_of(data):
    return hashlib.sha256(data).digest()


def new_user_id():
    return uuid.uuid4().bytes


def write_attachment_file(media_dir, sha256_bytes, data):
    directory = Path(media_dir, "attachments")
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / sha256_bytes.hex()
    path.write_bytes(data)
    return path


def write_avatar_file(media_dir, user_id_bytes, data):
    directory = Path(media_dir, "avatars")
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / str(uuid.UUID(bytes=user_id_bytes))
    path.write_bytes(data)
    return path
