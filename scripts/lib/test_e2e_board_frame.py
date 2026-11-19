# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How the canvas scenarios read the dock's share of the surface from the letterbox under the board."""
import unittest

import e2e_board_frame as bf

BOARD = (247, 248, 249)
GRID = (222, 226, 230)
EDGE = (217, 219, 224)
LETTERBOX = (235, 237, 239)


def _column(board_rows, letterbox):
    """A strip down the surface: board with a grid line every 76 rows, its edge, then [letterbox] rows."""
    board = [GRID if row % 76 == 0 else BOARD for row in range(board_rows)]
    return board + [EDGE] + letterbox


class LetterboxRows(unittest.TestCase):
    def test_a_flat_letterbox_is_counted_up_to_the_board(self):
        self.assertEqual(bf.letterbox_rows(_column(400, [LETTERBOX] * 51)), 51)

    def test_a_dock_shadow_over_the_letterbox_does_not_end_it_early(self):
        # Bob's 1100 px window: the two-row dock spans the pane and shades the strip by a level every few rows.
        shadow = [tuple(c - row // 8 for c in LETTERBOX) for row in range(90)]
        self.assertEqual(bf.letterbox_rows(_column(400, shadow)), 90)

    def test_no_letterbox_reads_zero(self):
        self.assertEqual(bf.letterbox_rows([BOARD] * 300), 0)


if __name__ == "__main__":
    unittest.main()
