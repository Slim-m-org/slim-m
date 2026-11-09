# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit tests for scripts/lib/dart_source.py's comment scrubber."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dart_source import strip_block_comments  # noqa: E402


class StripBlockCommentsTest(unittest.TestCase):
    def test_a_line_comment_is_blanked_keeping_columns(self):
        out = strip_block_comments("a(); // note\nb();\n")
        self.assertEqual(out, "a(); " + " " * 7 + "\nb();\n")

    def test_a_block_comment_keeps_its_newlines(self):
        out = strip_block_comments("a /* x\ny */ b")
        self.assertEqual(out.count("\n"), 1)
        self.assertNotIn("x", out)

    def test_a_comment_marker_inside_a_string_is_left_alone(self):
        src = "final u = 'http://x';\n"
        self.assertEqual(strip_block_comments(src), src)

    def test_an_escaped_quote_does_not_close_a_string(self):
        src = "final a = 'it\\'s // fine';\n"
        self.assertEqual(strip_block_comments(src), src)

    def test_a_raw_string_ending_in_a_backslash_closes_at_its_quote(self):
        src = "final a = x.replaceAll(r'\\', '/');\n// MediaQuery.of(context)\nfinal b = 1;\n"
        out = strip_block_comments(src)
        self.assertNotIn("MediaQuery", out)
        self.assertIn("final b = 1;", out)

    def test_a_double_quoted_raw_string_behaves_the_same(self):
        src = 'final a = r"\\";\n// gone\nfinal b = 1;\n'
        self.assertNotIn("gone", strip_block_comments(src))

    def test_an_identifier_ending_in_r_is_not_a_raw_prefix(self):
        src = "final a = bar'x\\'y';\n// gone\n"
        self.assertNotIn("gone", strip_block_comments(src))


class TripleQuoteTest(unittest.TestCase):
    def test_an_apostrophe_inside_a_triple_quoted_string_does_not_flip_the_state(self):
        src = "final a = '''it's // fine''';\n// gone\nfinal b = 1;\n"
        out = strip_block_comments(src)
        self.assertIn("it's // fine", out)
        self.assertNotIn("gone", out)

    def test_a_double_quoted_triple_string_may_hold_quotes_and_line_breaks(self):
        src = 'final a = """say "hi"\n// kept\n""";\n// gone\n'
        out = strip_block_comments(src)
        self.assertIn("// kept", out)
        self.assertNotIn("gone", out)

    def test_a_raw_triple_quoted_pattern_balances_its_own_quotes(self):
        src = "final r = RegExp(r'''(token)([\"']?)\\s*''');\n// gone\n"
        self.assertNotIn("gone", strip_block_comments(src))

    def test_an_unterminated_single_line_string_ends_at_the_line_break(self):
        src = "final a = 'oops;\n// gone\nfinal b = 1;\n"
        out = strip_block_comments(src)
        self.assertNotIn("gone", out)
        self.assertIn("final b = 1;", out)


class InterpolationTest(unittest.TestCase):
    def test_a_quote_inside_an_interpolation_does_not_close_the_string(self):
        src = "final a = 'x ${m['k']} // kept';\n// gone\n"
        out = strip_block_comments(src)
        self.assertIn("// kept", out)
        self.assertNotIn("gone", out)

    def test_a_comment_inside_an_interpolation_is_blanked(self):
        out = strip_block_comments("final a = '${b /* gone */}';\n")
        self.assertNotIn("gone", out)


class BlankStringsTest(unittest.TestCase):
    def test_strings_are_kept_by_default(self):
        src = "testWidgets('pumpAndSettle hangs', (t) async {});\n"
        self.assertEqual(strip_block_comments(src), src)

    def test_a_test_title_naming_a_pattern_is_blanked_keeping_columns(self):
        src = "testWidgets('pumpAndSettle hangs', (t) async {});\n"
        out = strip_block_comments(src, blank_strings=True)
        self.assertNotIn("pumpAndSettle", out)
        self.assertEqual(len(out), len(src))
        self.assertTrue(out.startswith("testWidgets('"))

    def test_code_inside_an_interpolation_survives(self):
        src = "final a = '${MediaQuery.of(context).size}';\n"
        self.assertIn("MediaQuery.of(context)", strip_block_comments(src, blank_strings=True))

    def test_line_breaks_inside_a_triple_quoted_string_are_kept(self):
        src = "final a = '''one\ntwo\n''';\nfinal b = 1;\n"
        out = strip_block_comments(src, blank_strings=True)
        self.assertEqual(out.count("\n"), src.count("\n"))
        self.assertNotIn("two", out)
        self.assertIn("final b = 1;", out)

    def test_a_raw_string_is_blanked_without_reading_escapes(self):
        src = "final a = r'\\d+ // x';\nfinal b = 1;\n"
        out = strip_block_comments(src, blank_strings=True)
        self.assertNotIn("d+", out)
        self.assertIn("final b = 1;", out)


if __name__ == "__main__":
    unittest.main()
