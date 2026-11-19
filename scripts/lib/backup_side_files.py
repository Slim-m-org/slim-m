# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The media files that are neither an attachment nor a user's own avatar.

The server keeps five more kinds of file beside those two, each announced by
a column in the database: the space banner and icon, a member's profile
banner, the picture of a linked account, and the original kept beside a
compressed photo. backup_lib.py mirrors them and restore_drill_lib.py checks
them through this module, so the two can never disagree about what exists.

A column an older server has not created yet is skipped, never an error: the
scripts in a checkout can be newer than the image the deployment runs.
"""
import re
import shutil
import sqlite3
from pathlib import Path

import path_guard

AVATARS = "avatars"
ATTACHMENTS = "attachments"
ORIGINAL_SUFFIX = ".orig"

# The provider names the server accepts, so a stray value never becomes a file name.
_PROVIDER = re.compile(r"^[a-z]{1,16}$")


def _columns(conn, table):
    return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def _space_files(conn):
    have = _columns(conn, "space_settings")
    for column, name in (("banner_updated_at", "space-banner"), ("icon_updated_at", "space-icon")):
        if column not in have:
            continue
        row = conn.execute(f"SELECT {column} FROM space_settings WHERE id = 1").fetchone()
        if row and row[0] is not None:
            yield AVATARS, lambda name=name: name, None


def _user_banners(conn):
    if "banner_updated_at" not in _columns(conn, "users"):
        return
    rows = conn.execute(
        "SELECT id FROM users WHERE banner_updated_at IS NOT NULL AND deleted_at IS NULL"
    )
    for (blob,) in rows.fetchall():
        yield AVATARS, lambda blob=blob: f"banner-{path_guard.avatar_uuid(blob)}", None


def _linked_picture_name(provider, blob):
    if not isinstance(provider, str) or not _PROVIDER.fullmatch(provider):
        raise path_guard.PathValidationError(
            f"linked_accounts.provider is not a provider name: {provider!r}"
        )
    return f"link-{provider}-{path_guard.avatar_uuid(blob)}"


def _linked_pictures(conn):
    if "avatar_updated_at" not in _columns(conn, "linked_accounts"):
        return
    rows = conn.execute(
        "SELECT provider, user_id FROM linked_accounts WHERE avatar_updated_at IS NOT NULL"
    )
    for provider, blob in rows.fetchall():
        yield AVATARS, lambda p=provider, b=blob: _linked_picture_name(p, b), None


def _kept_originals(conn):
    if "original_size" not in _columns(conn, "attachments"):
        return
    rows = conn.execute("SELECT sha256, original_size FROM attachments WHERE original_size > 0")
    for blob, size in rows.fetchall():
        yield ATTACHMENTS, lambda blob=blob: path_guard.sha256_hex(blob) + ORIGINAL_SUFFIX, size


def expected_files(db_path):
    """Every side file the database says exists, as (directory, name, size or None).

    Returns them with the reasons for any row that could not be turned into a file name.
    """
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    found, malformed = [], []
    try:
        for kind in (_space_files, _user_banners, _linked_pictures, _kept_originals):
            for directory, name, size in kind(conn):
                try:
                    found.append((directory, name(), size))
                except path_guard.PathValidationError as error:
                    malformed.append(str(error))
    finally:
        conn.close()
    return found, malformed


def _is_present(path, size):
    if not path.is_file():
        return False
    actual = path.stat().st_size
    return actual == size if size is not None else actual > 0


def sync(snapshot_db, source_media_dir, mirror_dir):
    """Copies each side file into the mirror; a kept original already there at its size is left."""
    expected, malformed = expected_files(snapshot_db)
    copied, already_present, missing_source = 0, 0, []
    for directory, name, size in expected:
        dest_dir = Path(mirror_dir, directory)
        dest_dir.mkdir(parents=True, exist_ok=True)
        try:
            src = path_guard.contained_path(Path(source_media_dir, directory), name)
            dest = path_guard.contained_path(dest_dir, name)
        except path_guard.PathValidationError as error:
            malformed.append(str(error))
            continue
        if size is not None and _is_present(dest, size):
            already_present += 1
            continue
        if not src.is_file():
            missing_source.append(f"{directory}/{name}")
            continue
        dest.unlink(missing_ok=True)
        shutil.copy2(src, dest)
        copied += 1
    return {
        "total": len(expected),
        "copied": copied,
        "already_present": already_present,
        "missing_source": missing_source,
        "malformed": malformed,
    }


def check(restored_db, mirror_dir):
    """Which side files the mirror holds, by existence and, for a kept original, its size."""
    expected, malformed = expected_files(restored_db)
    missing, verified = [], 0
    for directory, name, size in expected:
        try:
            path = path_guard.contained_path(Path(mirror_dir, directory), name)
        except path_guard.PathValidationError as error:
            malformed.append(str(error))
            continue
        if _is_present(path, size):
            verified += 1
        else:
            missing.append(f"{directory}/{name}")
    return {
        "total": len(expected),
        "verified": verified,
        "missing": missing,
        "malformed": malformed,
    }
