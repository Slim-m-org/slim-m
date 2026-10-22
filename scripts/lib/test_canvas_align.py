# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The canvas alignment tool's pure parts: scene geometry, mapping and marker detection."""
import struct
import unittest
import zlib

import canvas_align_geometry as geo
import canvas_align_manifest as scene

try:
    import numpy as np
    import canvas_align_detect as detect
except ImportError:
    np = None

LETTERBOX = (24, 26, 32)


def _ids():
    counter = iter(range(100))
    return lambda: f"id-{next(counter)}"


def _manifest():
    return {"image_bg": list(scene.IMAGE_BG), "markers": scene.markers()}


def _render(width, height, frame, shifts=None):
    """A fake screenshot: a letterbox, the board's cream field and each marker as a solid box."""
    shifts = shifts or {}
    rgb = np.zeros((height, width, 3), np.uint8)
    rgb[:] = LETTERBOX
    left, top, board_w, board_h = frame
    x0, y0 = round(left), round(top)
    rgb[y0:y0 + round(board_h), x0:x0 + round(board_w)] = scene.IMAGE_BG
    scale_x, scale_y = board_w / scene.BOARD_W, board_h / scene.BOARD_H
    for marker in scene.markers():
        dx, dy = shifts.get(marker["name"], (0, 0))
        cx = left + marker["cx"] * scale_x + dx
        cy = top + marker["cy"] * scale_y + dy
        half_w, half_h = marker["w"] * scale_x / 2, marker["h"] * scale_y / 2
        top_y, bottom_y = round(cy - half_h), round(cy + half_h)
        left_x, right_x = round(cx - half_w), round(cx + half_w)
        rgb[top_y:bottom_y, left_x:right_x] = marker["colour"]
        if marker["style"] == "outline" and right_x - left_x > 12:
            rgb[top_y + 2:bottom_y - 2, left_x + 2:right_x - 2] = scene.IMAGE_BG
            faint = np.array(scene.IMAGE_BG) * 0.4 + np.array(marker["colour"]) * 0.6
            rgb[top_y:bottom_y, right_x - 2:right_x] = faint
            rgb[bottom_y - 2:bottom_y, left_x:right_x] = faint
    return rgb


class SceneTest(unittest.TestCase):
    def test_markers_stay_inside_the_board_and_are_named_once(self):
        found = scene.markers()
        self.assertEqual(len(found), len({m["name"] for m in found}))
        for marker in found:
            self.assertGreaterEqual(marker["cx"] - marker["w"] / 2, 0, marker["name"])
            self.assertLessEqual(marker["cx"] + marker["w"] / 2, scene.BOARD_W, marker["name"])
            self.assertGreaterEqual(marker["cy"] - marker["h"] / 2, 0, marker["name"])
            self.assertLessEqual(marker["cy"] + marker["h"] / 2, scene.BOARD_H, marker["name"])

    def test_the_small_square_is_ten_by_ten_at_the_board_centre(self):
        x, y, w, h = scene.DOT
        self.assertEqual((w, h), (10, 10))
        self.assertEqual((x + w / 2, y + h / 2), (scene.BOARD_W / 2, scene.BOARD_H / 2))

    def test_the_drawing_is_centred_inside_the_square(self):
        square = next(m for m in scene.markers() if m["name"] == "square")
        drawing = next(m for m in scene.markers() if m["name"] == "drawing")
        self.assertEqual((square["cx"], square["cy"]), (drawing["cx"], drawing["cy"]))
        self.assertLess(drawing["w"], square["w"])

    def test_the_stroke_diagonal_is_centred_on_its_marker(self):
        stroke = scene.placements({"id": "a", "content_type": "image/png"}, _ids())[2]
        points = stroke["props"]["points"]
        mid_x = stroke["x"] + (points[0] + points[2]) / 2
        mid_y = stroke["y"] + (points[1] + points[3]) / 2
        drawing = next(m for m in scene.markers() if m["name"] == "drawing")
        self.assertEqual((mid_x, mid_y), (drawing["cx"], drawing["cy"]))

    def test_placements_cover_the_board_with_the_image_first(self):
        placed = scene.placements({"id": "a", "content_type": "image/png"}, _ids())
        self.assertEqual([p["kind"] for p in placed], ["image", "shape", "stroke", "shape"])
        self.assertEqual((placed[0]["x"], placed[0]["y"], placed[0]["w"], placed[0]["h"]),
                         (0, 0, scene.BOARD_W, scene.BOARD_H))
        self.assertEqual(len({p["id"] for p in placed}), 4)

    def test_the_reference_png_is_a_valid_board_sized_image(self):
        data = scene.reference_png()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack(">II", data[16:24])
        self.assertEqual((width, height), (scene.BOARD_W, scene.BOARD_H))
        idat = data[data.index(b"IDAT") + 4:data.index(b"IEND") - 8]
        raw = zlib.decompress(idat)
        stride = 1 + scene.BOARD_W * 3

        def pixel(x, y):
            at = y * stride + 1 + x * 3
            return tuple(raw[at:at + 3])

        self.assertEqual(pixel(80, 80), (230, 0, 0))
        self.assertEqual(pixel(1840, 1000), (200, 0, 200))
        self.assertEqual(pixel(20, 20), scene.IMAGE_BG)

    def test_manifest_records_the_channel_and_objects(self):
        placed = scene.placements({"id": "a", "content_type": "image/png"}, _ids())
        manifest = scene.build_manifest("http://x", {"id": "chan", "name": "lounge"}, placed)
        self.assertEqual(manifest["channel_id"], "chan")
        self.assertEqual(manifest["channel_name"], "lounge")
        self.assertEqual(len(manifest["objects"]), 4)
        self.assertEqual(manifest["board"], {"w": 1920, "h": 1080})


class MappingTest(unittest.TestCase):
    def test_round_trip_through_a_letterboxed_frame(self):
        frame = geo.Frame(0, 100, 390, 390 * 1080 / 1920)
        px = frame.to_px(960, 540)
        self.assertAlmostEqual(px[0], 195)
        self.assertAlmostEqual(px[1], 100 + 219.375 / 2)
        board = frame.to_board(*px)
        self.assertAlmostEqual(board[0], 960)
        self.assertAlmostEqual(board[1], 540)

    def test_offset_reports_pixels_and_board_units(self):
        frame = geo.Frame(10, 20, 960, 540)
        result = geo.offset(frame, (100, 100), (10 + 50 + 1.0, 20 + 50 - 0.5))
        self.assertAlmostEqual(result["dx_px"], 1.0)
        self.assertAlmostEqual(result["dy_px"], -0.5)
        self.assertAlmostEqual(result["dx_board"], 2.0)
        self.assertAlmostEqual(result["dy_board"], -1.0)

    def test_tolerance_is_the_euclidean_distance(self):
        near = {"dx_px": 0.7, "dy_px": 0.7, "dx_board": 0, "dy_board": 0}
        far = {"dx_px": 0.8, "dy_px": 0.8, "dx_board": 0, "dy_board": 0}
        self.assertTrue(geo.within_tolerance(near))
        self.assertFalse(geo.within_tolerance(far))
        self.assertFalse(geo.within_tolerance(None))


@unittest.skipIf(np is None, "needs numpy")
class DetectTest(unittest.TestCase):
    def test_finds_the_board_and_every_marker_at_zero_offset(self):
        frame_px = (0, 120, 390, 220)
        rgb = _render(390, 460, frame_px)
        frame, _, _, rows = detect.measure(rgb, _manifest())
        self.assertEqual((frame.left, frame.top, frame.width), (0, 120, 390))
        self.assertEqual(len(rows), len(scene.markers()))
        for row in rows:
            self.assertIsNotNone(row["result"], row["name"])
            self.assertLess(geo.distance_px(row["result"]), 1.0, row["name"])

    def test_reports_a_shifted_marker_and_only_that_one(self):
        rgb = _render(1280, 720, (0, 0, 1280, 720), shifts={"dot-10x10": (5, -3)})
        _, _, _, rows = detect.measure(rgb, _manifest())
        by_name = {row["name"]: row["result"] for row in rows}
        self.assertAlmostEqual(by_name["dot-10x10"]["dx_px"], 5, delta=1.0)
        self.assertAlmostEqual(by_name["dot-10x10"]["dy_px"], -3, delta=1.0)
        self.assertAlmostEqual(by_name["dot-10x10"]["dx_board"], 7.5, delta=1.5)
        self.assertTrue(geo.within_tolerance(by_name["image-tl"]))

    def test_an_outline_is_centred_on_its_sides_not_their_weight(self):
        rgb = _render(1280, 720, (0, 0, 1280, 720))
        _, _, _, rows = detect.measure(rgb, _manifest())
        square = next(r for r in rows if r["name"] == "square")["result"]
        self.assertLess(geo.distance_px(square), 0.75)

    def test_ui_over_the_board_edge_moves_the_frame_to_the_image_corners(self):
        rgb = _render(1280, 720, (0, 0, 1280, 720))
        rgb[:, 0:2] = LETTERBOX
        rgb[:, 1278:] = LETTERBOX
        frame, source, _, rows = detect.measure(rgb, _manifest())
        self.assertEqual(source, "corners")
        self.assertAlmostEqual(frame.left, 0, delta=0.6)
        self.assertAlmostEqual(frame.width, 1280, delta=1.0)
        self.assertTrue(all(geo.within_tolerance(r["result"]) for r in rows))

    def test_a_board_cut_by_header_and_dock_is_reported_not_measured(self):
        rgb = _render(1280, 720, (0, 0, 1280, 720))
        rgb[:60] = LETTERBOX
        rgb[420:] = LETTERBOX
        frame, source, _, rows = detect.measure(rgb, _manifest())
        self.assertEqual(source, "cut")
        self.assertEqual(rows, [])
        self.assertLess(frame.height, 400)

    def test_a_marker_under_a_pill_is_marked_partly_showing(self):
        rgb = _render(1280, 720, (0, 0, 1280, 720))
        rgb[40:75, 20:100] = LETTERBOX
        _, _, _, rows = detect.measure(rgb, _manifest())
        corner = next(r for r in rows if r["name"] == "image-tl")
        self.assertLess(corner["visible"], 0.9)

    def test_a_clean_edge_is_trusted(self):
        rgb = _render(1280, 720, (0, 0, 1280, 720))
        _, source, _, _ = detect.measure(rgb, _manifest())
        self.assertEqual(source, "edge")

    def test_a_missing_marker_is_none(self):
        rgb = np.zeros((720, 1280, 3), np.uint8)
        rgb[:] = scene.IMAGE_BG
        frame, _, _, rows = detect.measure(rgb, _manifest())
        self.assertIsNotNone(frame)
        self.assertTrue(all(row["result"] is None for row in rows))

    def test_no_board_in_the_picture(self):
        rgb = np.zeros((200, 200, 3), np.uint8)
        frame, _, _, rows = detect.measure(rgb, _manifest())
        self.assertIsNone(frame)
        self.assertEqual(rows, [])


if __name__ == "__main__":
    unittest.main()
