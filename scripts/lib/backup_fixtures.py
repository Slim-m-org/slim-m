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
_images = {}


# The table sqlx keeps its applied migrations in, which the server creates on first start.
_SQLX_MIGRATIONS = """CREATE TABLE _sqlx_migrations (
    version BIGINT PRIMARY KEY, description TEXT NOT NULL,
    installed_on TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, success BOOLEAN NOT NULL,
    checksum BLOB NOT NULL, execution_time BIGINT NOT NULL)"""


def apply_migrations(conn, migrations_dir=MIGRATIONS_DIR):
    conn.execute(_SQLX_MIGRATIONS)
    for migration in sorted(Path(migrations_dir).glob("*.sql")):
        conn.executescript(migration.read_text())
        version, _, description = migration.stem.partition("_")
        conn.execute(
            "INSERT INTO _sqlx_migrations (version, description, success, checksum, execution_time) "
            "VALUES (?, ?, 1, x'00', 0)",
            (int(version), description),
        )
    conn.commit()


def latest_migration(migrations_dir=MIGRATIONS_DIR):
    return max(int(path.stem.partition("_")[0]) for path in Path(migrations_dir).glob("*.sql"))


def _migrations_digest(migrations_dir):
    digest = hashlib.sha256()
    for migration in sorted(Path(migrations_dir).glob("*.sql")):
        digest.update(migration.name.encode() + b"\0" + migration.read_bytes() + b"\0")
    return digest.hexdigest()


def _migrated_image(migrations_dir):
    """The database file image of every migration in migrations_dir applied
    in order, built once per distinct set of migration files."""
    key = _migrations_digest(migrations_dir)
    if key not in _images:
        template = sqlite3.connect(":memory:")
        try:
            apply_migrations(template, migrations_dir)
            _images[key] = template.serialize()
        finally:
            template.close()
    return _images[key]


def build_database(path, attachments=(), avatar_users=(), deleted_avatar_users=(),
                   migrations_dir=MIGRATIONS_DIR):
    """attachments: (sha256_bytes, size, content_type) tuples.
    avatar_users: (user_id_bytes, username) tuples, each marked as having
    an avatar (avatar_updated_at set).
    deleted_avatar_users: the same, for tombstoned accounts, whose
    avatar_updated_at survives deletion while the file does not."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    # Replaying every migration on disk cost about 16 s of fsync per test, so a migrated image is written instead.
    Path(path).write_bytes(_migrated_image(migrations_dir))
    conn = sqlite3.connect(str(path))
    try:
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
        conn.executemany(
            "INSERT INTO users (id, username, display_name, created_at, avatar_updated_at, deleted_at) "
            "VALUES (?, ?, ?, 0, 1, 2)",
            [(user_id, username, username) for user_id, username in deleted_avatar_users],
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
