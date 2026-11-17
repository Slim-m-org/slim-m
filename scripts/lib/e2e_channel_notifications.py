# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A channel's notification choice, set from its row menu and kept by the server.

Bob right-clicks the channel in his rail, opens Notifications and mutes it.
The override must reach the server, survive a reload, and show as Muted when
the menu is next opened. A change made from another device must reach the open
menu without a reload, and choosing the same entry again must clear the
override, since the server holds an entry only for a channel that differs
from the default.
"""
import time

import e2e_input as I

TIMEOUT = 15


def _row(client, name):
    return next((n for n in client.nodes() if n["t"].split(", ")[0] == name), None)


def _tap_exact(client, label):
    deadline = time.time() + TIMEOUT
    while True:
        node = next((n for n in client.nodes() if n["t"] == label), None)
        if node:
            client.tap(node["x"], node["y"])
            client.settle(1.5)
            return
        if time.time() >= deadline:
            client.shot(f"notify-no-{label[:12].replace(' ', '-')}")
            raise AssertionError(f"{client.name}: no control labelled exactly {label!r}")
        time.sleep(0.25)


def _open_notifications(client, name):
    row = client.wait_for(name)
    I.right_click(client, row["x"], row["y"])
    client.click("Notifications", settle=1)


def _menu_state(client):
    """The trailing word of the Notifications row: Muted, Mentions, All or Default."""
    node = next(n for n in client.nodes() if n["t"].startswith("Notifications"))
    return node["t"]


def _server_choice(member, channel_id):
    entries = member.call("GET", "/notification-preferences/channels")
    return next((e["preference"] for e in entries if e["channel_id"] == channel_id), None)


def _wait_server(member, channel_id, want):
    deadline = time.time() + TIMEOUT
    while _server_choice(member, channel_id) != want:
        assert time.time() < deadline, \
            f"the server holds {_server_choice(member, channel_id)!r} for bob, wanted {want!r}"
        time.sleep(0.25)


def _wait_menu_word(client, name, word):
    deadline = time.time() + TIMEOUT
    while True:
        _open_notifications(client, name)
        label = _menu_state(client)
        client.dismiss_overlay()
        client.dismiss_overlay()
        if word in label:
            return
        if time.time() >= deadline:
            client.shot("notify-menu")
            raise AssertionError(f"{client.name}: Notifications row reads {label!r}, wanted {word!r}")
        time.sleep(0.5)


def mute_from_the_row_menu(b, admin, member):
    name = f"e2e-notify-{int(time.time())}"
    channel_id = admin.call("POST", "/channels", {"name": name, "kind": "text"})["id"]
    try:
        b.wait_for(name)
        assert _server_choice(member, channel_id) is None
        _open_notifications(b, name)
        _tap_exact(b, "Mute channel")
        _wait_server(member, channel_id, "nothing")
        print("  Mute channel in the row menu stores a nothing override on the server")

        home = b.ev("location.origin")
        b.go_away()
        b.come_back(f"{home}/#/channels")
        b.wait_for(name, timeout=45)
        _wait_menu_word(b, name, "Muted")
        print("  after a reload the menu still reads Muted")

        member.call("PUT", f"/notification-preferences/channels/{channel_id}",
                    {"preference": "mentions"})
        _wait_menu_word(b, name, "Mentions")
        print("  a change from another device reaches the open menu")

        _open_notifications(b, name)
        _tap_exact(b, "Mentions only")
        _wait_server(member, channel_id, None)
        _wait_menu_word(b, name, "Default")
        print("  choosing the active entry again clears the override")
    finally:
        b.dismiss_overlay()
        member.status("DELETE", f"/notification-preferences/channels/{channel_id}")
        admin.status("DELETE", f"/channels/{channel_id}")
