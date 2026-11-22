# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""File pickers, raw pointer gestures and the canvas surface for `Client`.

Split out of e2e_client.py to keep it under its file budget; `Client` mixes
this in, so every method is still called on a `Client`.
"""
import base64
import json
import os
import time

import e2e_js

_MOUSE = "Input.dispatchMouseEvent"
_DEFAULT_MIME = "image/png"


class PageInputMixin:
    def watch_for_file_input(self):
        """Catch the picker's <input> at the moment it is made.

        Flutter's web file picker builds the element, clicks it, and never puts
        it in the document, so there is nothing for CDP's own
        `DOM.setFileInputFiles` to find and nothing to query for afterwards.
        Wrapping `createElement` is what gets a handle on it.
        """
        self.ev(e2e_js.WATCH_FILES)

    def give_file(self, path, mime=_DEFAULT_MIME):
        """Hand the caught input a real file, as a person's picker would.

        `files` cannot be assigned a plain list, but it will take a
        `DataTransfer`'s, which is how a file arrives without a dialog nobody
        is there to answer.
        """
        with open(path, "rb") as fh:
            payload = base64.b64encode(fh.read()).decode()
        name = os.path.basename(path)
        ok = self.ev(e2e_js.give_file(
            json.dumps(payload), json.dumps(name), json.dumps(mime)))
        if ok != "ok":
            raise AssertionError(f"{self.name}: {ok}")
        time.sleep(3)

    def attach_file(self, open_label, path, mime=_DEFAULT_MIME, settle=2):
        """Open a picker and answer it, in the order those have to happen.

        A picker that sees the window refocus before a file arrives treats it
        as a cancel, so one opened after typing needs a short [settle].
        """
        self.watch_for_file_input()
        self.click(open_label, settle=settle)
        self.give_file(path, mime)

    def drag(self, points, hold=0.05):
        """A raw press, move through every point, release gesture.

        For the canvas surface only: a `CustomPainter` has no accessible
        element to click through, so [gestures] must be on first and this is
        the only way to draw, select, or drag a resize handle on it.
        """
        x0, y0 = points[0]
        self.send(_MOUSE, {"type": "mousePressed", "x": x0, "y": y0,
                           "button": "left", "clickCount": 1})
        time.sleep(hold)
        for x, y in points[1:]:
            self.send(_MOUSE, {"type": "mouseMoved", "x": x, "y": y,
                               "button": "left", "buttons": 1})
            time.sleep(hold)
        lx, ly = points[-1]
        self.send(_MOUSE, {"type": "mouseReleased", "x": lx, "y": ly,
                           "button": "left", "clickCount": 1})
        time.sleep(hold)

    def press(self, x, y):
        self.send(_MOUSE, {"type": "mousePressed", "x": x, "y": y,
                           "button": "left", "clickCount": 1})

    def move_held(self, points, hold=0.05):
        for x, y in points:
            self.send(_MOUSE, {"type": "mouseMoved", "x": x, "y": y,
                               "button": "left", "buttons": 1})
            time.sleep(hold)

    def release(self, x, y):
        self.send(_MOUSE, {"type": "mouseReleased", "x": x, "y": y,
                           "button": "left", "clickCount": 1})

    def region_png(self, rect):
        """The PNG bytes of [rect] (page pixels), for before/after comparison."""
        clip = {"x": rect["x"], "y": rect["y"], "width": rect["width"],
                "height": rect["height"], "scale": 1}
        r = self.send("Page.captureScreenshot",
                      {"format": "png", "clip": clip})
        data = (r.get("result", {}).get("result", {}).get("data")
                or r.get("result", {}).get("data"))
        return base64.b64decode(data or "")

    def canvas_rect(self):
        """The drawing surface's own bounding box; see e2e_js.canvas_rect."""
        raw = self.ev(e2e_js.canvas_rect())
        if not raw:
            raise AssertionError(f"{self.name}: canvas surface not found")
        return json.loads(raw)

    def paste_clipboard_image(self, path, mime=_DEFAULT_MIME):
        """Dispatches a real `paste` DOM event carrying [path]'s bytes."""
        with open(path, "rb") as fh:
            payload = base64.b64encode(fh.read()).decode()
        name = os.path.basename(path)
        ok = self.ev(e2e_js.paste_image(
            json.dumps(payload), json.dumps(name), json.dumps(mime)))
        if ok != "ok":
            raise AssertionError(f"{self.name}: {ok}")
        time.sleep(2)
