# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The canvas caps the client draws within are the server's, so nothing it sends is refused.

A client that exceeds a cap fails only in production with a 400 or a dropped
frame, and both sides are hand-written. Equal where the server rejects past a
number, at most the server's where the client keeps itself under it.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from dart_source import strip_block_comments  # noqa: E402
from test_client_perm_bits_match_server import strip_rust_comments  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SERVER = ROOT / "crates" / "slimm-server" / "src"
CLIENT = ROOT / "client" / "packages"

# (client file, client name, server file, server name, relation).
LIMITS = [
    ("voice_canvas/lib/src/canvas_stroke.dart", "worldLimit", "store/canvas/canvas_geometry.rs", "WORLD_LIMIT", "eq"),
    ("voice_canvas/lib/src/canvas_stroke.dart", "maxObjectExtent", "store/canvas/canvas_geometry.rs", "MAX_OBJECT_EXTENT", "eq"),
    ("app/lib/src/features/canvas/screens/canvas_ops_controller.dart", "maxRemoveIdsPerOp", "store/canvas/canvas_ops_write.rs", "MAX_REMOVE_IDS_PER_OP", "eq"),
    ("app/lib/src/features/canvas/screens/canvas_stroke_preview_relay.dart", "maxStrokePreviewPointsPerFrame", "http/ws/signals_canvas.rs", "MAX_STROKE_PREVIEW_POINTS", "le"),
]

NUMBER = r"[\d_.]+(?:\s*\*\s*[\d_]+)*"


def evaluate(text: str) -> float:
    product = 1.0
    for factor in text.split("*"):
        product *= float(factor.replace("_", "").strip())
    return product


def dart_value(source: str, name: str) -> float | None:
    found = re.search(rf"\bconst (?:int|double) {name} = ({NUMBER});", strip_block_comments(source))
    return evaluate(found.group(1)) if found else None


def rust_value(source: str, name: str) -> float | None:
    found = re.search(rf"\bconst {name}: (?:usize|f64) = ({NUMBER});", strip_rust_comments(source))
    return evaluate(found.group(1)) if found else None


def mismatches(read_client, read_server) -> list[str]:
    found = []
    for client_file, client_name, server_file, server_name, relation in LIMITS:
        client, server = read_client(client_file, client_name), read_server(server_file, server_name)
        if client is None or server is None:
            found.append(f"{client_name} or {server_name} is no longer a numeric constant")
        elif relation == "eq" and client != server:
            found.append(f"{client_name} is {client:g} but {server_name} is {server:g}")
        elif relation == "le" and client > server:
            found.append(f"{client_name} is {client:g}, over {server_name} at {server:g}")
    return found


def read_client(path: str, name: str) -> float | None:
    return dart_value((CLIENT / path).read_text(), name)


def read_server(path: str, name: str) -> float | None:
    return rust_value((SERVER / path).read_text(), name)


class ClientCanvasLimitsMatchServerTest(unittest.TestCase):
    def test_every_canvas_limit_agrees(self):
        self.assertEqual(mismatches(read_client, read_server), [])

    def test_a_moved_server_cap_is_caught(self):
        def moved(path, name):
            return 4096.0 if name == "MAX_OBJECT_EXTENT" else read_server(path, name)

        self.assertEqual(
            mismatches(read_client, moved),
            ["maxObjectExtent is 8192 but MAX_OBJECT_EXTENT is 4096"],
        )

    def test_a_client_cap_over_the_server_is_caught(self):
        def over(path, name):
            return 30.0 if name == "maxStrokePreviewPointsPerFrame" else read_client(path, name)

        self.assertEqual(
            mismatches(over, read_server),
            ["maxStrokePreviewPointsPerFrame is 30, over MAX_STROKE_PREVIEW_POINTS at 24"],
        )

    def test_a_commented_out_constant_is_not_read(self):
        self.assertEqual(rust_value("// const A: usize = 9;\nconst A: usize = 4 * 1024;\n", "A"), 4096.0)
        self.assertEqual(dart_value("// const int a = 9;\nconst int a = 3;\n", "a"), 3.0)


if __name__ == "__main__":
    unittest.main()
