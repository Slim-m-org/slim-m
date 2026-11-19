# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A file the server starts keeping cannot reach main with no backup behind it.

Banners, icons, linked pictures and kept originals each shipped with the
backup, its drill and every test green, because a column the backup does not
know is skipped by design. This reads the server's media module and fails on
any directory, file name, writer or picture column backup_coverage.py does not
list.
"""
import re
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import backup_coverage as coverage  # noqa: E402
import backup_fixtures as fixtures  # noqa: E402
import media_paths  # noqa: E402

_PICTURE_COLUMN = re.compile(r"(avatar|banner|icon|picture|image|photo|logo|cover)\w*_updated_at$")
_HOW = "mirror it in backup_lib.py or backup_side_files.py, then list it in backup_coverage.py"


class ServerMediaIsCoveredTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = media_paths.sources()

    def test_the_reader_still_finds_the_media_module(self):
        self.assertIn("mod.rs", self.server)
        self.assertIn(("avatar_path", "user_id"), media_paths.file_names(self.server))

    def test_every_directory_under_the_media_root_is_mirrored_or_excused(self):
        known = coverage.MIRRORED_DIRECTORIES | set(coverage.NOT_BACKED_UP_DIRECTORIES)
        self.assertEqual(media_paths.directories(self.server), known,
                         f"the server's media directories changed: {_HOW}")

    def test_every_file_name_the_server_builds_is_mirrored_or_excused(self):
        known = set(coverage.MIRRORED_NAMES) | set(coverage.NOT_BACKED_UP_NAMES)
        found = media_paths.file_names(self.server)
        self.assertEqual(found - known, set(), f"a new file name in the media module: {_HOW}")
        self.assertEqual(known - found, set(), "backup_coverage.py lists a name the server dropped")

    def test_every_writer_is_known(self):
        self.assertEqual(media_paths.writers(self.server), coverage.WRITERS,
                         f"Media gained or lost a write_* function: {_HOW}")

    def test_the_backup_spells_each_name_the_way_the_server_does(self):
        for name, ours in coverage.SERVER_CONSTANTS.items():
            self.assertEqual(media_paths.constant(self.server, name), ours, name)
        for (_, expression), prefix in coverage.SERVER_PREFIXES.items():
            self.assertIn(f'"{prefix}{{', expression)

    def test_every_picture_column_is_one_the_backup_reads(self):
        with tempfile.TemporaryDirectory() as tmp:
            database = Path(tmp, "live.db")
            fixtures.build_database(database)
            conn = sqlite3.connect(database)
            try:
                tables = [row[0] for row in conn.execute(
                    "SELECT name FROM sqlite_master WHERE type = 'table'")]
                found = {(table, row[1]) for table in tables
                         for row in conn.execute(f"PRAGMA table_info({table})")
                         if _PICTURE_COLUMN.search(row[1])}
            finally:
                conn.close()
        self.assertEqual(found, coverage.PICTURE_COLUMNS,
                         f"a picture column the backup does not read, or one that is gone: {_HOW}")


class MediaPathReaderTest(unittest.TestCase):
    def _names(self, source):
        return media_paths.file_names({"new.rs": media_paths.production_code(source)})

    def test_a_new_file_kind_is_found(self):
        source = 'fn p(&self, id: &str) -> PathBuf { self.avatars_dir.join(format!("sticker-{id}")) }'
        self.assertEqual(self._names(source), {("avatars_dir", 'format!("sticker-{id}")')})

    def test_a_new_use_of_a_path_builder_is_found_but_its_definition_is_not(self):
        source = ("fn avatar_path(&self, user_id: &str) -> PathBuf { PathBuf::new() }\n"
                  "fn q(&self) { write_atomic(self.avatar_path(SPACE_SPLASH_KEY), bytes) }")
        self.assertEqual(self._names(source), {("avatar_path", "SPACE_SPLASH_KEY")})

    def test_a_commented_out_name_is_not_found(self):
        source = ("// self.avatars_dir.join(\"old\")\n"
                  "/* self.attachments_dir.join(gone) */\n"
                  "/// Like `self.avatars_dir.join(name)`.\n")
        self.assertEqual(self._names(source), set())

    def test_a_slash_pair_inside_a_string_does_not_hide_the_code_after_it(self):
        source = 'let u = "https://x"; self.avatars_dir.join(real)'
        self.assertEqual(self._names(source), {("avatars_dir", "real")})

    def test_a_quote_character_literal_does_not_open_a_string(self):
        source = "matches!(c, '\"' | '/'); // self.avatars_dir.join(old)\nself.avatars_dir.join(real)"
        self.assertEqual(self._names(source), {("avatars_dir", "real")})

    def test_the_test_module_is_not_read(self):
        source = ("fn a() {}\n#[cfg(test)]\nmod tests {\n"
                  "    fn t(m: &Media) { m.attachments_dir.join(\".tmp-x\"); }\n}\n")
        self.assertEqual(self._names(source), set())

    def test_a_new_directory_and_writer_are_found(self):
        code = {"mod.rs": media_paths.production_code(
            'let stickers_dir = root.join("stickers");\n'
            "pub async fn write_sticker(&self, id: &str) {}\n")}
        self.assertEqual(media_paths.directories(code), {"stickers"})
        self.assertEqual(media_paths.writers(code), {"write_sticker"})


if __name__ == "__main__":
    unittest.main()
