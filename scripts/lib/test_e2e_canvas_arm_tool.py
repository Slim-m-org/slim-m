# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""arm_tool presses the dock's own tool when the board shows an object of the same name.

With semantics on, every unselected board object is a tappable node named
after its kind, and a shape's name is exactly the Shape tool's. The real
click script runs under node against a small stand-in for Flutter's
semantics DOM, laid out the way the canvas pane is: the board surface comes
before the dock.
"""
import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import e2e_canvas  # noqa: E402
import e2e_client  # noqa: E402
import e2e_labels as L  # noqa: E402

_NODE = shutil.which("node")

_FAKE_DOM = r"""
var __clicked = [];
function El(spec, parent) {
  this.id = spec.id;
  this.tagName = (spec.tag || 'flt-semantics').toUpperCase();
  this.parentElement = parent || null;
  this.attrs = spec.attrs || {};
  this.text = spec.text || '';
  this.rect = spec.rect || [0, 0, 0, 0];
  var self = this;
  this.children = (spec.children || []).map(function (c) { return new El(c, self); });
}
El.prototype.getAttribute = function (n) { return n in this.attrs ? this.attrs[n] : null; };
El.prototype.hasAttribute = function (n) { return n in this.attrs; };
Object.defineProperty(El.prototype, 'textContent', {get: function () {
  return this.text + this.children.map(function (c) { return c.textContent; }).join('');
}});
El.prototype.all = function () {
  var out = [];
  this.children.forEach(function (c) { out.push(c); out.push.apply(out, c.all()); });
  return out;
};
function matching(root, sel) {
  var tags = sel.split(',');
  return root.all().filter(function (e) { return tags.indexOf(e.tagName.toLowerCase()) >= 0; });
}
El.prototype.querySelector = function (sel) { return matching(this, sel)[0] || null; };
El.prototype.contains = function (o) {
  for (var p = o; p; p = p.parentElement) if (p === this) return true;
  return false;
};
El.prototype.getBoundingClientRect = function () {
  var r = this.rect;
  return {x: r[0], y: r[1], width: r[2], height: r[3],
          left: r[0], top: r[1], right: r[0] + r[2], bottom: r[1] + r[3]};
};
El.prototype.click = function () { __clicked.push(this.id); };
var __root = new El({id: 'host', tag: 'flt-semantics-host', children: __SPEC__});
var document = {querySelectorAll: function (sel) { return matching(__root, sel); }};
"""


def _button(node_id, text, rect, **attrs):
    return {"id": node_id, "text": text, "rect": rect,
            "attrs": {"role": "button", "flt-tappable": "", **attrs}}


def _dock(*tools):
    """The dock's tools row, Pan first, every button level with the others."""
    return {"id": "dock", "rect": [80, 680, 400, 60], "children": [
        _button(f"dock-{name.lower()}", name, [100 + 48 * i, 692, 36, 36])
        for i, name in enumerate(tools)]}


def _board(*objects):
    return {"id": "board", "rect": [0, 0, 1280, 800], "children": list(objects)}


class DomClient(e2e_client.Client):
    """A client whose scripts run under node against [spec] and record what they clicked."""

    def __init__(self, spec):
        super().__init__("alice", 0)
        self.spec = spec
        self.clicked = []

    def ev(self, expr):
        script = (_FAKE_DOM.replace("__SPEC__", json.dumps(self.spec))
                  + f"\nvar __v = ({expr});\n"
                  "process.stdout.write(JSON.stringify({v: __v === undefined ? null : __v, c: __clicked}));")
        out = subprocess.run([_NODE, "-"], input=script, capture_output=True,
                             text=True, check=True, timeout=30).stdout
        result = json.loads(out)
        self.clicked += result["c"]
        return result["v"]

    def settle(self, *args, **kwargs):
        pass

    def shot(self, tag):
        pass

    def tap(self, x, y):
        self.clicked.append(("tap", x, y))


@unittest.skipUnless(_NODE, "node runs the browser-side click script")
class ArmToolTest(unittest.TestCase):
    TOOLS = (L.PAN_TOOL, L.PEN_TOOL, L.NOTE_TOOL, L.SHAPE_TOOL, L.ERASER_TOOL)

    def test_a_shape_on_the_board_does_not_take_the_shape_tools_press(self):
        client = DomClient([
            _board(_button("board-shape", "Shape", [600, 150, 120, 80])),
            _dock(*self.TOOLS)])
        e2e_canvas.arm_tool(client, L.SHAPE_TOOL)
        self.assertEqual(client.clicked, ["dock-pan", "dock-shape"])

    def test_a_note_on_the_board_does_not_take_the_note_tools_press(self):
        client = DomClient([
            _board(_button("board-note", "Note: ", [200, 300, 160, 120])),
            _dock(*self.TOOLS)])
        e2e_canvas.arm_tool(client, L.NOTE_TOOL)
        self.assertEqual(client.clicked, ["dock-pan", "dock-note"])

    def test_a_tool_the_dock_lacks_fails_rather_than_pressing_the_board(self):
        client = DomClient([
            _board(_button("board-shape", "Shape", [600, 150, 120, 80])),
            _dock(L.PAN_TOOL, L.PEN_TOOL, L.ERASER_TOOL)])
        with self.assertRaisesRegex(AssertionError, "Shape"):
            e2e_canvas.arm_tool(client, L.SHAPE_TOOL)
        self.assertEqual(client.clicked, ["dock-pan"])


if __name__ == "__main__":
    unittest.main()
