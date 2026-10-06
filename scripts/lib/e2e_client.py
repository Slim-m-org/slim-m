# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Drive one Flutter web client over the Chrome DevTools Protocol.

Flutter paints to a canvas, so the app is unreachable from a script until its
accessibility tree is on; clicking the placeholder Flutter leaves in the DOM
turns every widget into an <flt-semantics> element with a real bounding box.
That is what makes this label-driven rather than pixel-driven, and so survives
a layout change.

Split out of the scenarios that use it, which live in e2e_*.py beside this.
"""
import base64
import json
import os
import tempfile
import time
import urllib.request

import e2e_js

TIMEOUT = 90
_MOUSE = "Input.dispatchMouseEvent"
_KEY = "Input.dispatchKeyEvent"
_DEFAULT_MIME = "image/png"
_shots_dir = None
# Enough to carry a launch's worth of failures without holding a whole run.
LOG_LINES = 200


def shots_dir():
    """Where screenshots and console logs go, created on first use.

    A private directory when E2E_SHOTS is unset, rather than a guessable
    shared one; resolved lazily so importing this module leaves nothing behind.
    """
    global _shots_dir
    if _shots_dir is None:
        _shots_dir = os.environ.get("E2E_SHOTS") or tempfile.mkdtemp(prefix="e2e-")
    os.makedirs(_shots_dir, mode=0o700, exist_ok=True)
    return _shots_dir


class Client:
    """One browser, addressed over the Chrome DevTools Protocol."""

    def __init__(self, name, port):
        self.name = name
        self.port = port
        self._ws = None
        self._id = 0
        self._log = []

    def _connect(self):
        from websocket import create_connection

        targets = json.load(urllib.request.urlopen(
            f"http://127.0.0.1:{self.port}/json/list"))
        page = next(t for t in targets if t["type"] == "page")
        self._ws = create_connection(page["webSocketDebuggerUrl"],
                                     suppress_origin=True, timeout=30)
        for domain in ("Log", "Runtime"):
            self.send(f"{domain}.enable")

    def send(self, method, params=None):
        if self._ws is None:
            self._connect()
        self._id += 1
        self._ws.send(json.dumps({"id": self._id, "method": method,
                                  "params": params or {}}))
        while True:
            msg = json.loads(self._ws.recv())
            if msg.get("id") == self._id:
                return msg
            self._note(msg)

    def _note(self, msg):
        """Keep whatever the browser said, for the moment a scenario gives up.

        A missing runtime asset is the case this exists for: the fetch fails,
        the app renders one generic sentence, and from the harness the only
        symptom is a label that never appears. The 404 lands here and nowhere
        else, so a failed run says what went wrong rather than only where.
        """
        method = msg.get("method")
        params = msg.get("params") or {}
        if method == "Log.entryAdded":
            entry = params.get("entry") or {}
            line = " ".join(str(entry.get(k) or "")
                            for k in ("level", "text", "url")).strip()
        elif method == "Runtime.consoleAPICalled":
            args = " ".join(str(a.get("value", a.get("description", "")))
                            for a in params.get("args") or [])
            line = f"{params.get('type')} {args}".strip()
        else:
            return
        self._log.append(line)
        del self._log[:-LOG_LINES]

    def _write_log(self, tag):
        if not self._log:
            return
        path = os.path.join(shots_dir(), f"{self.name}-{tag}.log")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(self._log) + "\n")
        print(f"    console {path}")

    def ev(self, expr):
        r = self.send("Runtime.evaluate",
                      {"expression": expr, "returnByValue": True})
        thrown = r.get("result", {}).get("exceptionDetails")
        if thrown:
            detail = (thrown.get("exception") or {}).get("description")
            raise AssertionError(
                f"{self.name}: the injected script threw: "
                f"{detail or thrown.get('text')}")
        return r.get("result", {}).get("result", {}).get("value")

    def enable_semantics(self):
        for _ in range(20):
            if (self.ev("document.querySelectorAll('flt-semantics').length") or 0) > 0:
                return
            self.ev("(function(){var p=document.querySelector("
                    "'flt-semantics-placeholder');if(p){p.click();}})()")
            time.sleep(2)
        raise AssertionError(f"{self.name}: accessibility tree never came up")

    def go_away(self):
        """Navigates to a blank page, which closes the app's socket.

        Returns the app's own URL so [come_back] can restore it, rather than
        needing the web origin plumbed in from the runner.

        This is how "the client was away" is expressed. It is not a kill: the
        browser profile and so drift's IndexedDB survive, which is the whole
        point - the local cache and its cursors are still there to be wrong.
        """
        home = self.ev("location.href")
        self.send("Page.navigate", {"url": "about:blank"})
        time.sleep(2)
        return home

    def come_back(self, home):
        """Reloads the app and waits for the accessibility tree again.

        Semantics are per document, so the placeholder has to be clicked once
        more; without this every later `find` sees an empty tree and the
        failure reads as a missing label rather than a missing handle.
        """
        self.send("Page.navigate", {"url": home})
        time.sleep(4)
        self.enable_semantics()

    def go_offline(self):
        """Cuts the page's network under it without navigating away.

        A reload would leave the call and prove the deliberate-rejoin path
        again; this is the transport vanishing under a page that never moved.
        """
        self.send("Network.enable")
        self.send("Network.emulateNetworkConditions", {
            "offline": True, "latency": 0,
            "downloadThroughput": -1, "uploadThroughput": -1})

    def go_online(self):
        self.send("Network.emulateNetworkConditions", {
            "offline": False, "latency": 0,
            "downloadThroughput": -1, "uploadThroughput": -1})

    def nodes(self):
        """Every leaf widget on screen, plus the fields.

        A text field's accessible name lands on the <input> Flutter creates for
        it, not on the wrapping semantics node, so both have to be collected or
        every field on every screen looks unlabelled.
        """
        raw = self.ev(e2e_js.NODES)
        return json.loads(raw or "[]")

    def find(self, label, field=None):
        for n in self.nodes():
            if field is not None and n.get("field") != field:
                continue
            if label.lower() in n["t"].lower():
                return n
        return None

    def wait_for(self, label, timeout=TIMEOUT, field=None):
        deadline = time.time() + timeout
        while time.time() < deadline:
            n = self.find(label, field=field)
            if n:
                return n
            time.sleep(1)
        self.shot(f"missing-{label[:20].replace(' ', '-')}")
        raise AssertionError(f"{self.name}: never saw {label!r}")

    def tap(self, x, y):
        for kind in ("mousePressed", "mouseReleased"):
            self.send(_MOUSE,
                      {"type": kind, "x": x, "y": y, "button": "left",
                       "clickCount": 1})
            time.sleep(0.06)

    def click(self, label, settle=1.5):
        """Activate a widget the way a screen reader would.

        Dispatching a mouse event at the widget's coordinates hits whatever
        Flutter has layered over the canvas there and silently does nothing on
        some screens; clicking the semantics element itself is what the
        framework listens for.
        """
        self.wait_for(label)
        hit = self.ev(e2e_js.click(json.dumps(label.lower())))
        if not hit:
            n = self.wait_for(label)
            self.tap(n["x"], n["y"])
        time.sleep(settle)

    def type_into(self, label, text):
        """Focus the field's own element rather than clicking where it looks.

        A click lands on whatever is topmost at that point, which on a dialog is
        sometimes the barrier; focusing the input Flutter already made cannot
        miss. Flutter only builds that input for the field holding focus, so a
        field that has never held it is clicked once to bring it into being.
        """
        if not self.find(label, field=True):
            self.click(label, settle=1.0)
        self.wait_for(label, field=True)
        focused = self.ev(
            e2e_js.focus_field(json.dumps(label.lower())))
        if not focused:
            n = self.wait_for(label, field=True)
            self.tap(n["x"], n["y"])
        time.sleep(0.4)
        self.send("Input.insertText", {"text": text})
        time.sleep(0.4)

    def gestures(self, on):
        """Let real pointer events through to the canvas, or take them back.

        With the accessibility tree on, Flutter's semantics elements sit over
        the canvas and swallow pointer events, so a hover or a right-click
        reaches nothing. Labelled controls are still clicked through the tree;
        this is only for the affordances that have no label to click, which are
        the ones a mouse is the only way to reach.
        """
        value = "none" if on else ""
        self.ev(e2e_js.set_gestures(json.dumps(value)))
        time.sleep(0.2)

    def dismiss_overlay(self, settle=0.4):
        """Escape, to close whatever modal the last scenario left open.

        A no-op with nothing open, which is why it is sent unconditionally
        rather than after looking for one: a barrier that is already gone
        cannot be detected any more cheaply than pressing the key.
        """
        for kind in ("keyDown", "keyUp"):
            self.send(_KEY, {"type": kind, "key": "Escape", "code": "Escape",
                             "windowsVirtualKeyCode": 27,
                             "nativeVirtualKeyCode": 27})
        time.sleep(settle)

    def hover(self, x, y, settle=1.2):
        self.send(_MOUSE,
                  {"type": "mouseMoved", "x": x, "y": y})
        time.sleep(settle)

    def mouse_click(self, x, y, button="left", hold=0.06):
        for kind in ("mousePressed", "mouseReleased"):
            self.send(_MOUSE,
                      {"type": kind, "x": x, "y": y, "button": button,
                       "clickCount": 1})
            time.sleep(hold)
        time.sleep(1.0)

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

    def attach_file(self, open_label, path, mime=_DEFAULT_MIME):
        """Open a picker and answer it, in the order those have to happen."""
        self.watch_for_file_input()
        self.click(open_label, settle=2)
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

    def wait_url(self, fragment, timeout=TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if fragment in (self.ev("location.href") or ""):
                return
            time.sleep(1)
        self.shot(f"stuck-at{fragment.replace('/', '-')}")
        raise AssertionError(
            f"{self.name}: never reached {fragment!r}, still at "
            f"{self.ev('location.href')}")

    def shot(self, tag):
        r = self.send("Page.captureScreenshot", {"format": "png"})
        self._write_log(tag)
        data = (r.get("result", {}).get("result", {}).get("data")
                or r.get("result", {}).get("data"))
        if not data:
            return
        path = os.path.join(shots_dir(), f"{self.name}-{tag}.png")
        with open(path, "wb") as fh:
            fh.write(base64.b64decode(data))
        print(f"    shot {path}")



