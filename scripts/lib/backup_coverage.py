# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every way the server names a file under its media root, and what backs each one up.

test_backup_covers_every_media_file.py reads crates/slimm-server/src/media and
fails when the server names a directory, a file or a picture column that is
not in these tables. Adding a kind of file means mirroring it in backup_lib.py
or backup_side_files.py first, then listing it here; a file that is rebuilt or
short-lived goes in a not-backed-up table with the reason.
"""
import backup_side_files as side

_SYNC_ATTACHMENTS = "backup_lib.sync_attachments"

MIRRORED_DIRECTORIES = {side.ATTACHMENTS, side.AVATARS}
NOT_BACKED_UP_DIRECTORIES = {
    "previews": "derived from the attachment and rebuilt on demand",
    "uploads": "resumable uploads in flight, which finish as attachments",
    "exports": "archives a member downloads and the server expires",
}

# (the server's path builder, the name it is given) -> the function that mirrors that file.
MIRRORED_NAMES = {
    ("attachment_path", "sha256_hex"): _SYNC_ATTACHMENTS,
    ("attachments_dir", "sha256_hex"): _SYNC_ATTACHMENTS,
    ("attachments_dir", "hex_id"): _SYNC_ATTACHMENTS,
    ("attachments_dir", "&hex_id"): _SYNC_ATTACHMENTS,
    ("attachments_dir", 'format!("{sha256_hex}{ORIGINAL_SUFFIX}")'): "backup_side_files._kept_originals",
    ("avatar_path", "user_id"): "backup_lib.sync_avatars",
    ("avatars_dir", "user_id"): "backup_lib.sync_avatars",
    ("avatar_path", "SPACE_BANNER_KEY"): "backup_side_files._space_files",
    ("avatar_path", "SPACE_ICON_KEY"): "backup_side_files._space_files",
    ("avatar_path", '&format!("banner-{user_id}")'): "backup_side_files._user_banners",
    ("avatars_dir", 'format!("link-{provider}-{user_id}")'): "backup_side_files._linked_pictures",
}
NOT_BACKED_UP_NAMES = {
    ("attachments_dir", 'format!(".tmp-{}", Uuid::now_v7())'): "an upload still being written",
    ("attachments_dir", "name"): "remove_temp_file, which only deletes a .tmp- leftover",
    ("avatars_dir", "name"): "remove_profile_file, which only deletes an orphan the sweep found",
}

# Each `Media::write_*`, so a new one is noticed even when it reuses a known path builder.
WRITERS = {
    "write_attachment", "write_avatar", "write_user_banner", "write_space_banner",
    "write_space_icon", "write_linked_avatar", "write_original",
}

# The server constants and literals the mirrored names are built from, and their copy here.
SERVER_CONSTANTS = {
    "SPACE_BANNER_KEY": side.SPACE_BANNER,
    "SPACE_ICON_KEY": side.SPACE_ICON,
    "ORIGINAL_SUFFIX": side.ORIGINAL_SUFFIX,
}
SERVER_PREFIXES = {
    ("avatar_path", '&format!("banner-{user_id}")'): side.USER_BANNER_PREFIX,
    ("avatars_dir", 'format!("link-{provider}-{user_id}")'): side.LINKED_PICTURE_PREFIX,
}

# The columns that say a picture file exists, as (table, column).
PICTURE_COLUMNS = {
    ("users", "avatar_updated_at"),
    ("users", "banner_updated_at"),
    ("space_settings", "banner_updated_at"),
    ("space_settings", "icon_updated_at"),
    ("linked_accounts", "avatar_updated_at"),
}
