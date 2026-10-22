# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Screenshots the web client's canvas at the five reference window sizes.

Drives a headless Chrome through chrome-devtools-axi in a session of its own,
so it never touches another browser. Controls are found by their accessible
names with the same scripts the e2e harness uses (e2e_js).
"""
import json
import os
import re
import subprocess
import sys
import time

import e2e_js
import e2e_labels as L
import safe_paths
from canvas_align_report import load_manifest

SIZES = [(1920, 1080), (1280, 720), (1024, 768), (390, 844), (844, 390)]
SESSION = "canvas-align"
_SETTLE_S = 3.0
_STEP_TIMEOUT_S = 40


def _axi_command():
    return os.environ.get("CANVAS_ALIGN_AXI", "npx -y chrome-devtools-axi").split()


class Browser:
    """One headless Chrome session behind chrome-devtools-axi."""

    def __init__(self):
        self.env = {**os.environ, "CHROME_DEVTOOLS_AXI_SESSION": SESSION}
        self.env.pop("CHROME_DEVTOOLS_AXI_HEADED", None)

    def axi(self, *args, check=True):
        done = subprocess.run(_axi_command() + [str(a) for a in args], env=self.env,
                              capture_output=True, text=True, timeout=120)
        if check and done.returncode != 0:
            raise RuntimeError(f"chrome-devtools-axi {args[0]} failed: {done.stdout}{done.stderr}")
        return done.stdout

    def ev(self, expression):
        """Evaluates a JS expression; returns its decoded value."""
        out = self.axi("eval", f"() => ({expression})")
        found = re.search(r"^result: (.*)$", out, re.M)
        if not found:
            return None
        # Live labels can carry newlines from real messages, so control characters are allowed inside strings.
        value = json.loads(json.loads(found.group(1)), strict=False)
        if not isinstance(value, str):
            return value
        try:
            return json.loads(value)
        except ValueError:
            return value

    def nodes(self):
        return self.ev(e2e_js.NODES) or []

    def find(self, label, field=False):
        wanted = label.lower()
        for node in self.nodes():
            if wanted in node["t"].lower() and node["field"] == field:
                return node
        return None

    def wait_for(self, label, field=False, timeout=_STEP_TIMEOUT_S):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.find(label, field):
                return
            time.sleep(1)
        raise RuntimeError(f"timed out waiting for {label!r} on screen")

    def click(self, label, settle=1.5):
        self.wait_for(label)
        if not self.ev(e2e_js.click(json.dumps(label.lower()))):
            raise RuntimeError(f"nothing to click for {label!r}")
        time.sleep(settle)

    def click_quietly(self, label):
        try:
            self.ev(e2e_js.click(json.dumps(label.lower())))
        except (RuntimeError, subprocess.SubprocessError):
            pass

    def type_into(self, label, text):
        if not self.find(label, field=True):
            self.click(label, settle=1.0)
        self.wait_for(label, field=True)
        if not self.ev(e2e_js.focus_field(json.dumps(label.lower()))):
            raise RuntimeError(f"could not focus {label!r}")
        time.sleep(0.4)
        self.axi("type", text)
        time.sleep(0.4)

    def enable_semantics(self):
        for _ in range(20):
            if self.ev("document.querySelectorAll('flt-semantics').length") or 0:
                return
            self.ev("(function(){var p=document.querySelector('flt-semantics-placeholder');"
                    "if(p){p.click();} return true;})()")
            time.sleep(2)
        raise RuntimeError("the accessibility tree never came up")

    def url(self):
        return self.ev("location.href") or ""


def _sign_in(browser, args, password):
    browser.axi("open", args.web_url)
    time.sleep(4)
    browser.enable_semantics()
    # A served client already knows its server and opens on sign-in; a bare one asks for a Space first.
    deadline = time.time() + _STEP_TIMEOUT_S
    while not (browser.find("Username", field=True) or browser.find("Connect to a Space")):
        if time.time() > deadline:
            raise RuntimeError("neither the sign-in nor the connect screen came up")
        time.sleep(1)
    if not browser.find("Username", field=True):
        browser.click("Connect to a Space")
        browser.type_into("Server address", args.base_url)
        browser.click("Continue")
        # A server with a trusted certificate confirms itself; only an unconfirmed one asks.
        deadline = time.time() + _STEP_TIMEOUT_S
        while not browser.find("Username", field=True):
            if browser.find("It matches"):
                browser.click("It matches")
                break
            if time.time() > deadline:
                raise RuntimeError("the sign-in form never came up after connecting")
            time.sleep(1)
    browser.type_into("Username", args.username)
    browser.type_into("Password", password)
    browser.click("Sign in", settle=6)
    deadline = time.time() + _STEP_TIMEOUT_S
    while "#/channels" not in browser.url():
        if time.time() > deadline:
            raise RuntimeError("signing in did not reach the channel list")
        time.sleep(1)
    if browser.find(L.SKIP_SETUP):
        browser.click(L.SKIP_SETUP)


def _open_canvas(browser, channel_name):
    browser.axi("resize", *SIZES[1])
    time.sleep(1)
    browser.click(channel_name, settle=3)
    browser.wait_for(L.IN_CALL)
    browser.click("Open canvas", settle=2)
    browser.wait_for(L.FIT_VIEW)
    if browser.find(L.MEMBER_PANE_HEADER):
        browser.click(L.MEMBER_LIST)


def capture_web(args, password):
    """Saves web-<width>x<height>.png for every size and returns the paths."""
    manifest = load_manifest(args.manifest)
    args.out_dir = safe_paths.home_or_cwd(args.out_dir)
    os.makedirs(args.out_dir, exist_ok=True)
    browser = Browser()
    paths = []
    try:
        _sign_in(browser, args, password)
        _open_canvas(browser, manifest["channel_name"])
        for width, height in SIZES:
            browser.axi("resize", width, height)
            time.sleep(_SETTLE_S)
            path = os.path.join(args.out_dir, f"web-{width}x{height}.png")
            browser.axi("screenshot", os.path.abspath(path))
            paths.append(path)
            print(f"captured {path}", file=sys.stderr)
    except RuntimeError as failure:
        _save_failure(browser, args.out_dir)
        raise SystemExit(f"capture-web failed: {failure}") from failure
    finally:
        browser.click_quietly(L.LEAVE_CALL)
        browser.axi("stop", check=False)
    return paths


def _save_failure(browser, out_dir):
    try:
        browser.axi("screenshot", os.path.abspath(os.path.join(out_dir, "capture-failed.png")))
    except (RuntimeError, subprocess.SubprocessError):
        pass
