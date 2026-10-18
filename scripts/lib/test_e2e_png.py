# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The stdlib PNG diff the canvas e2e checks count changed pixels with."""
import struct
import unittest
import zlib

import e2e_png


def _chunk(kind, body):
    crc = zlib.crc32(kind + body) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", crc)


def _png(width, height, pixel, filter_kind=0):
    """An RGB PNG whose pixel at (x, y) is pixel(x, y); sub-filtered if asked."""
    raw = b""
    for y in range(height):
        line = bytearray()
        for x in range(width):
            line += bytes(pixel(x, y))
        if filter_kind == 1:
            line = bytearray(
                (line[i] - (line[i - 3] if i >= 3 else 0)) & 255
                for i in range(len(line)))
        raw += bytes([filter_kind]) + bytes(line)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", header)
            + _chunk(b"IDAT", zlib.compress(raw)) + _chunk(b"IEND", b""))


class ChangedPixels(unittest.TestCase):
    def test_reports_only_pixels_above_the_threshold(self):
        base = _png(4, 3, lambda x, y: (10, 10, 10))
        edited = _png(4, 3, lambda x, y: (
            (200, 10, 10) if (x, y) == (2, 1)
            else (15, 10, 10) if (x, y) == (0, 0) else (10, 10, 10)))
        self.assertEqual(e2e_png.changed_pixels(base, edited, 24), [(2, 1)])

    def test_a_sub_filtered_image_decodes_the_same(self):
        plain = _png(5, 2, lambda x, y: (x * 40, y * 90, 7))
        filtered = _png(5, 2, lambda x, y: (x * 40, y * 90, 7), filter_kind=1)
        self.assertEqual(e2e_png.changed_pixels(plain, filtered, 0), [])

    def test_mismatched_sizes_are_an_error(self):
        with self.assertRaises(ValueError):
            e2e_png.changed_pixels(_png(2, 2, lambda x, y: (0, 0, 0)),
                                   _png(3, 2, lambda x, y: (0, 0, 0)), 0)


if __name__ == "__main__":
    unittest.main()
