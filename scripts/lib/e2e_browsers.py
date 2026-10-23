# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Extra browsers and accounts for scenarios that need more than alice and bob.

e2e.sh starts two browsers on fixed ports. A scenario needing a third
participant, or a sender capturing a different WAV, starts its own here and
always kills it again, so a failing scenario cannot leave a Chrome behind to
hold a port or a microphone.
"""
import contextlib
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

from e2e_api import Api
from e2e_client import Client

# Offsets from E2E_CDP_BASE (9800); 1 and 2 are alice and bob, which e2e.sh owns and pkills by port.
EXTRA_OFFSETS = {"carol": 11, "noisy": 13, "raw": 14, "vqa": 15, "vqb": 16, "tabs": 17}


def cdp_base():
    """A second stack moves this so its browsers do not collide with the first's."""
    return int(os.environ.get("E2E_CDP_BASE", "9800"))


def extra_port(name):
    return cdp_base() + EXTRA_OFFSETS[name]


def _chrome():
    path = shutil.which("google-chrome-stable") or shutil.which("google-chrome")
    if not path:
        raise AssertionError("missing: google-chrome-stable")
    return path


def chrome_args(profile, port, wav):
    return [
        "--headless=new", f"--user-data-dir={profile}",
        f"--remote-debugging-port={port}", "--window-size=1280,900",
        "--no-first-run", "--no-default-browser-check",
        "--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream",
        f"--use-file-for-fake-audio-capture={wav}",
        "--autoplay-policy=no-user-gesture-required",
        "--enable-unsafe-swiftshader", "--mute-audio",
        "--auto-select-desktop-capture-source=Entire screen",
    ]


def _wait_for_debugger(port, timeout=40):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version")
            return
        except OSError:
            time.sleep(0.25)
    raise AssertionError(f"chrome on :{port} never opened its debugger")


def _wait_for_page(port, timeout=40):
    """The tab exists and has navigated to the app, not about:blank."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json") as r:
                tabs = json.load(r)
        except OSError:
            tabs = []
        if any(t.get("type") == "page" and t.get("url", "").startswith("http")
               for t in tabs):
            return
        time.sleep(0.25)
    raise AssertionError(f"chrome on :{port} never opened the app tab")


def _stop(proc, grace=15):
    """SIGTERM the browser's process group, SIGKILL it if it does not leave."""
    for sig, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 30)):
        with contextlib.suppress(ProcessLookupError):
            os.killpg(proc.pid, sig)
        try:
            proc.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue


def work_dir():
    """Where e2e.sh keeps its files; it exports E2E_WORK, so the fallback is for a lone import."""
    return os.environ.get("E2E_WORK") or os.path.join(tempfile.gettempdir(), "e2e")


@contextlib.contextmanager
def browser(name, wav, work=None):
    """A headless Chrome on the port reserved for `name`, killed on exit."""
    port = extra_port(name)
    work = work or work_dir()
    profile = os.path.join(work, f"chrome-{name}")
    shutil.rmtree(profile, ignore_errors=True)
    os.makedirs(profile)
    web = f"http://localhost:{os.environ.get('E2E_WEB_PORT', '8356')}"
    proc = None
    try:
        with open(os.path.join(work, f"chrome-{name}.log"), "wb") as log:
            proc = subprocess.Popen(
                [_chrome()] + chrome_args(profile, port, wav) + [web],
                stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                start_new_session=True)
        _wait_for_debugger(port)
        _wait_for_page(port)
        yield Client(name, port)
    finally:
        try:
            if proc is not None:
                _stop(proc)
        finally:
            shutil.rmtree(profile, ignore_errors=True)


def register(server, admin_api, username, secret):
    """A new member on an admin's invite; a name already taken is reused."""
    invite = admin_api.call("POST", "/invites", {})["code"]
    other = Api(server)
    try:
        other.call("POST", "/auth/register", {
            "username": username, "display_name": username.capitalize(),
            "password": secret, "device_name": f"e2e-{username}",
            "invite_code": invite})
    except urllib.error.HTTPError as err:
        if err.code != 409:
            raise
    return username


def dismiss_welcome(client, timeout=20):
    """A brand-new account opens under What's new and a welcome card."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        for label in ("Got it", "Skip", "Close"):
            if client.find(label):
                client.click(label, settle=1)
                break
        else:
            if client.find("lounge"):
                return
        time.sleep(0.25)
    client.shot("welcome-stuck")
