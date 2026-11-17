# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Someone coming online moves to Online in everyone's member list.

Alice watches the member list from a text channel while Carol, a member who
has never been online, signs in and joins a call, comes back while alice's
network is down, and stays through a server restart; then Bob closes and
reopens the app, once while alice's own app is still starting. Every step
compares alice's list with what the server says.
"""
import os
import subprocess
import time

import e2e_browsers
import e2e_labels as L
from e2e_voice import _click_channel_row

GIVE_UP_SECONDS = 60
SAMPLE_SECONDS = 0.1


class _Watch:
    def __init__(self, a, admin_api):
        self.a = a
        self.api = admin_api
        self.ids = {m["display_name"]: m["id"] for m in admin_api.members()}
        self.late = []

    def server_says(self, name):
        got = self.api.call("GET", f"/presence?ids={self.ids[name]}")
        rows = got if isinstance(got, list) else got.get("items", [])
        return rows[0]["status"] if rows else None

    def until(self, name, section, what):
        """Waits for alice's list to put `name` under `section`; records it as late otherwise."""
        start = time.time()
        while time.time() - start < GIVE_UP_SECONDS:
            if _section_of(self.a, name) == section:
                print(f"  {what}: {name} under {section} after "
                      f"{time.time() - start:+.2f} s (server: {self.server_says(name)})")
                return True
            time.sleep(SAMPLE_SECONDS)
        server = self.server_says(name)
        print(f"  {what}: {name} never moved to {section}; list "
              f"{_section_of(self.a, name)}, server {server}")
        # Only a list that disagrees with the server is the member list's fault.
        if (server == "offline") == (section == "offline"):
            self.a.shot(f"presence-{name.lower()}-not-{section}")
            self.late.append(what)
        return False


def _section_of(client, name):
    """`online`, `offline` or None: the member-list heading above `name`'s row."""
    nodes = client.nodes()
    headings = [n for n in nodes if n["t"].startswith(("Online · ", "Offline · "))]
    if not headings:
        return None
    pane_x = min(h["x"] for h in headings)
    for n in nodes:
        first = n["t"].split("\n")[0].split(",")[0].strip().lower()
        if first != name.lower() or n["x"] < pane_x - 40:
            continue
        above = [h for h in headings if h["y"] <= n["y"]]
        if above:
            return max(above, key=lambda h: h["y"])["t"].split(" ")[0].lower()
    return None


def _open_member_list(client):
    client.click(L.TEXT_CHANNEL, settle=1.5)
    if not client.find("Online · ") and not client.find("Offline · "):
        client.click(L.MEMBER_LIST, settle=1.5)


def _close(client):
    home = client.ev("location.href")
    client.ev("location.href = 'about:blank'")
    return home


def _reopen(client, home):
    client.ev(f"location.href = {home!r}")
    time.sleep(4)
    client.enable_semantics()


def _slow_network(client, latency_ms):
    client.send("Network.enable")
    client.send("Network.emulateNetworkConditions", {
        "offline": False, "latency": latency_ms,
        "downloadThroughput": -1, "uploadThroughput": -1})


def coming_online_shows(a, b, server, secret, admin_api, sign_in):
    e2e_browsers.register(server, admin_api, "carol", secret)
    _open_member_list(a)
    w = _Watch(a, admin_api)
    w.until("Carol", "offline", "before signing in")
    wav = os.path.join(e2e_browsers.work_dir(), "fake-voice.wav")
    with e2e_browsers.browser("carol", wav) as c:
        sign_in(c, server, "carol", secret)
        e2e_browsers.dismiss_welcome(c)
        w.until("Carol", "online", "carol signing in")
        _click_channel_row(c, L.VOICE_CHANNEL)
        c.wait_for(L.IN_CALL)
        w.until("Carol", "online", "carol joining a call")
        _while_alice_was_away(w, c)
        _through_a_server_restart(w)
    w.until("Carol", "offline", "carol closing the app")
    home = _close(b)
    w.until("Bob", "offline", "bob closing the app")
    _reopen(b, home)
    w.until("Bob", "online", "bob reopening the app")
    _while_alice_was_starting(w, b)
    assert not w.late, f"member list wrong: {', '.join(w.late)}"


def _while_alice_was_away(w, c):
    """Carol closes the app, and reopens it into the call while alice's network is down."""
    home = _close(c)
    w.until("Carol", "offline", "carol closing before alice drops")
    w.a.go_offline()
    _reopen(c, home)
    c.wait_for("Rejoin the call", timeout=60)
    c.click("Rejoin", settle=0)
    c.wait_for(L.IN_CALL)
    w.a.go_online()
    w.until("Carol", "online", "carol rejoining while alice was offline")


def _through_a_server_restart(w):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    subprocess.run(["bash", os.path.join(root, "e2e-stack.sh"), "restart-server"],
                   check=True, timeout=180)
    for name in ("Carol", "Bob"):
        w.until(name, "online", f"{name} after a server restart")


def _while_alice_was_starting(w, b):
    """Bob comes back between alice's app reading presence and its socket going live."""
    home = _close(b)
    w.until("Bob", "offline", "bob closing before alice restarts")
    _slow_network(w.a, 1500)
    w.a.ev("location.reload()")
    time.sleep(3)
    w.a.enable_semantics()
    w.until("Bob", "offline", "alice's restarted list shows bob")
    _reopen(b, home)
    w.a.go_online()
    w.until("Bob", "online", "bob back while alice was starting")
