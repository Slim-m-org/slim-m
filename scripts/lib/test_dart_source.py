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


if __name__ == "__main__":
    unittest.main()
