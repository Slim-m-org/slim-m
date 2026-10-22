# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Maps between a screenshot's pixels and board coordinates.

Pure arithmetic with no imaging dependency, so the mapping is testable anywhere.
A [Frame] is the fitted board as it appears in one screenshot.
"""
from dataclasses import dataclass

from canvas_align_manifest import BOARD_H, BOARD_W

TOLERANCE_PX = 1.0
# A solid marker showing less than this is covered by UI, so its offset says nothing.
VISIBLE_SHARE = 0.9


@dataclass(frozen=True)
class Frame:
    """The board's rectangle in screenshot pixels (edges, not pixel centres)."""
    left: float
    top: float
    width: float
    height: float

    @property
    def scale_x(self):
        return self.width / BOARD_W

    @property
    def scale_y(self):
        return self.height / BOARD_H

    def to_px(self, bx, by):
        return self.left + bx * self.scale_x, self.top + by * self.scale_y

    def to_board(self, px, py):
        return (px - self.left) / self.scale_x, (py - self.top) / self.scale_y


def offset(frame, expected_board, found_px):
    """How far a marker landed from where it should be.

    Returns the offset in pixels and in board units, found minus expected.
    """
    ex, ey = frame.to_px(*expected_board)
    dx, dy = found_px[0] - ex, found_px[1] - ey
    return {"dx_px": dx, "dy_px": dy,
            "dx_board": dx / frame.scale_x, "dy_board": dy / frame.scale_y}


def distance_px(result):
    return (result["dx_px"] ** 2 + result["dy_px"] ** 2) ** 0.5


def within_tolerance(result, tolerance=TOLERANCE_PX):
    return result is not None and distance_px(result) <= tolerance
