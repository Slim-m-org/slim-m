# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The canvas seeder's image fixtures are real PNGs of the sizes they claim."""
import random
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import seed_canvas_images as images  # noqa: E402


def png_size(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    return struct.unpack(">II", data[16:24])


class BuildTest(unittest.TestCase):
    def test_every_spec_yields_a_png_of_its_declared_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            built = images.build(tmp, random.Random(1))
        self.assertEqual(len(built), len(images._SPECS))
        for data, ctype, name, width, height in built:
            with self.subTest(name=name):
                self.assertEqual(ctype, "image/png")
                self.assertEqual(png_size(data), (width, height))

    def test_names_are_unique_and_sizes_vary(self):
        with tempfile.TemporaryDirectory() as tmp:
            built = images.build(tmp, random.Random(1))
        self.assertEqual(len({b[2] for b in built}), len(built))
        self.assertGreater(len({(b[3], b[4]) for b in built}), 4)

    def test_the_same_seed_gives_the_same_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            a = images.build(tmp, random.Random(5))
        with tempfile.TemporaryDirectory() as tmp:
            b = images.build(tmp, random.Random(5))
        self.assertEqual([x[0] for x in a], [x[0] for x in b])


if __name__ == "__main__":
    unittest.main()
