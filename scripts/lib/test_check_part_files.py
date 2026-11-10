# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-part-files.py.

The gate counts `part` directives in hand-written Dart and ratchets them down,
so what matters is what it counts (a directive in a comment or a string is not
one, a generated part is not one) and how the ceiling reads in both directions.
The end-to-end run over the real tree only ever sees the allowlisted files, so
the cases that make it fail are checked against fixtures here.
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-part-files.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("part_files", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HandWrittenPartsTest(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()

    def test_a_directive_is_counted_with_its_line(self):
        source = "library;\n\npart 'a.dart';\npart \"b.dart\";\n"
        self.assertEqual(self.mod.hand_written_parts(source), [3, 4])

    def test_generated_parts_are_not_counted(self):
        source = (
            "part 'x.g.dart';\n"
            "part 'x.freezed.dart';\n"
            "part 'x.mocks.dart';\n"
            "part 'x_helper.dart';\n"
        )
        self.assertEqual(self.mod.hand_written_parts(source), [4])

    def test_a_directive_in_a_comment_is_not_counted(self):
        source = "// part 'a.dart';\n/* part 'b.dart';\npart 'c.dart'; */\n/// part 'd.dart';\n"
        self.assertEqual(self.mod.hand_written_parts(source), [])

    def test_a_directive_inside_a_multiline_string_is_not_counted(self):
        source = "const fixture = '''\npart 'a.dart';\n''';\npart 'b.dart';\n"
        self.assertEqual(self.mod.hand_written_parts(source), [4])

    def test_part_of_is_not_a_directive_to_count(self):
        self.assertEqual(self.mod.hand_written_parts("part of 'a.dart';\n"), [])

    def test_an_identifier_that_starts_with_part_is_not_counted(self):
        source = "part_count('a.dart');\npartial 'b.dart';\n"
        self.assertEqual(self.mod.hand_written_parts(source), [])


class ProblemsTest(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()

    def test_an_unlisted_file_with_a_part_is_reported(self):
        problems = self.mod.problems_in({"a.dart": "part 'b.dart';\n"}, {})
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("a.dart:1:"))

    def test_a_listed_file_at_its_count_is_quiet(self):
        source = "part 'b.dart';\npart 'c.dart';\n"
        self.assertEqual(self.mod.problems_in({"a.dart": source}, {"a.dart": 2}), [])

    def test_the_part_past_the_ceiling_is_the_one_reported(self):
        source = "part 'b.dart';\npart 'c.dart';\n"
        problems = self.mod.problems_in({"a.dart": source}, {"a.dart": 1})
        self.assertEqual(len(problems), 1)
        self.assertTrue(problems[0].startswith("a.dart:2:"))

    def test_a_file_that_lost_parts_must_lower_its_entry(self):
        problems = self.mod.problems_in({"a.dart": "part 'b.dart';\n"}, {"a.dart": 3})
        self.assertEqual(len(problems), 1)
        self.assertIn("lower the entry", problems[0])

    def test_a_listed_file_with_no_parts_left_must_drop_its_entry(self):
        problems = self.mod.problems_in({"a.dart": "library;\n"}, {"a.dart": 1})
        self.assertEqual(len(problems), 1)
        self.assertIn("or drop it at 0", problems[0])

    def test_a_listed_path_that_is_gone_is_reported(self):
        problems = self.mod.problems_in({}, {"gone.dart": 1})
        self.assertEqual(len(problems), 1)
        self.assertIn("not a tracked Dart file", problems[0])

    def test_generated_parts_never_need_an_entry(self):
        self.assertEqual(self.mod.problems_in({"a.dart": "part 'a.g.dart';\n"}, {}), [])


class AllowlistTest(unittest.TestCase):
    def setUp(self):
        self.mod = _load_module()
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)

    def _allowlist(self, body: str) -> dict:
        path = Path(self._tmp.name) / "allow.txt"
        path.write_text(body)
        return self.mod.load_allowlist(path)

    def test_paths_and_counts_are_read_and_comments_skipped(self):
        self.assertEqual(
            self._allowlist("# header\n\na/b.dart 3 # why\nc.dart 1\n"),
            {"a/b.dart": 3, "c.dart": 1},
        )

    def test_a_line_with_no_count_is_rejected(self):
        with self.assertRaises(ValueError):
            self._allowlist("a/b.dart # why\n")

    def test_the_real_allowlist_parses_and_lists_only_real_files_with_a_count(self):
        allowed = self.mod.load_allowlist(self.mod.ALLOWLIST_PATH)
        root = SCRIPT.resolve().parents[1]
        for rel, count in allowed.items():
            with self.subTest(path=rel):
                self.assertTrue((root / rel).exists())
                self.assertGreaterEqual(count, 1)


if __name__ == "__main__":
    unittest.main()
