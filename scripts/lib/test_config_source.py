# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit tests for scripts/lib/config_source.py's comment stripper."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from config_source import strip_comments  # noqa: E402


class StripCommentsTest(unittest.TestCase):
    def test_a_whole_line_comment_is_blanked_inside_a_continued_run(self) -> None:
        text = "RUN a \\\n    # && check \\\n    && b\n"
        self.assertNotIn("check", strip_comments(text))
        self.assertIn("&& b", strip_comments(text))

    def test_a_trailing_comment_goes_and_the_code_stays(self) -> None:
        self.assertEqual(strip_comments("key: value  # note"), "key: value")

    def test_a_hash_inside_quotes_is_kept(self) -> None:
        text = 'run: echo "a # b" # real comment'
        self.assertEqual(strip_comments(text), 'run: echo "a # b"')

    def test_a_hash_inside_a_word_is_kept(self) -> None:
        self.assertEqual(strip_comments("url: http://x/#frag"), "url: http://x/#frag")

    def test_a_commented_service_header_still_splits_like_code(self) -> None:
        self.assertEqual(strip_comments("  litestream:  # sidecar\n"), "  litestream:")


if __name__ == "__main__":
    unittest.main()
