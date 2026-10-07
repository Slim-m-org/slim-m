# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""scripts/check-no-emoji.sh must catch every emoji block and tolerate plain symbols."""
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check-no-emoji.sh"

EMOJI = {
    "rocket": "\U0001F680",
    "alarm": "⏰",
    "hourglass": "⌛",
    "watch": "⌚",
    "flag": "\U0001F1FA\U0001F1F8",
    "joker": "\U0001F0CF",
    "negative_squared_a": "\U0001F170",
    "heart": "❤",
    "variation_selector": "️",
    "zero_width_joiner": "‍",
}
PLAIN = {
    "return_symbol": "⏎",
    "arrow": "→",
    "check_mark": "✓",
    "copyright": "©",
    "bullet": "•",
}


def scan(glyph: str, suffix: str = "dart") -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / f"sample.{suffix}").write_text(f"// {glyph}\n", encoding="utf-8")
        return subprocess.run([str(SCRIPT), tmp], capture_output=True, text=True)


class CheckNoEmojiTest(unittest.TestCase):
    def test_every_emoji_block_is_caught(self):
        for name, glyph in EMOJI.items():
            with self.subTest(glyph=name):
                self.assertEqual(scan(glyph).returncode, 1)

    def test_plain_symbols_pass(self):
        for name, glyph in PLAIN.items():
            with self.subTest(glyph=name):
                self.assertEqual(scan(glyph).returncode, 0)

    def test_arb_and_yaml_sources_are_scanned(self):
        for suffix in ("arb", "yaml"):
            with self.subTest(suffix=suffix):
                self.assertEqual(scan(EMOJI["alarm"], suffix).returncode, 1)

    def test_a_scan_error_is_a_failure_not_a_pass(self):
        result = subprocess.run([str(SCRIPT), "/nonexistent-dir"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("scan itself failed", result.stdout)

    def test_the_client_tree_is_clean(self):
        result = subprocess.run([str(SCRIPT), str(SCRIPT.parents[1] / "client")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
