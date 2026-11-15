# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A private channel is invisible to anyone not added, and follows the add and the removal live.

Alice makes it private in the create sheet and adds bob from the channel's
permission grid, the way an admin would. What bob can do is read from both
sides: his rail on screen, and the server's own answer to his reads, since a
row hidden by the client while the server still serves it is no privacy.
Bob is sitting in the channel when he is removed, which is the case where a
stale screen would keep showing what he can no longer read.
"""
import time

import e2e_labels as L

TIMEOUT = 15
# The dialog's title bar ends here, and a row scrolled up behind it is covered.
HEADER = 130


def _row(client, name):
    return next((n for n in client.nodes() if n["t"].split(", ")[0] == name), None)


def _wait_row(client, name, present, timeout=TIMEOUT):
    deadline = time.time() + timeout
    while (_row(client, name) is not None) != present:
        if time.time() >= deadline:
            client.shot(f"private-{'missing' if present else 'still-shown'}")
            raise AssertionError(f"{client.name}: row {name!r} present={not present}, wanted {present}")
        time.sleep(0.25)


def _bob_reads(member, channel_id):
    return member.status("GET", f"/channels/{channel_id}/messages")


def _save_grid(client):
    """The grid's own Save, beside its Discard: it sits under the grid and is only built once scrolled near."""
    _scroll_to(client, L.DISCARD)
    time.sleep(0.5)
    deadline = time.time() + TIMEOUT
    while client.find(L.DISCARD):
        assert time.time() < deadline, "the grid's edit was never saved"
        save = max((n for n in client.nodes() if n["t"] == L.SAVE_CHANGES), key=lambda n: n["y"])
        client.tap(save["x"], save["y"])
        client.settle(1.5)


def _scroll_to(client, target, step=300, tries=10):
    """Wheels at the window's centre, inside the settings dialog, until [target] is on screen."""
    height = client.ev("window.innerHeight")
    width = client.ev("window.innerWidth")
    for _ in range(tries):
        n = client.find(target)
        if n and HEADER < n["y"] < height - 40:
            return n
        client.send("Input.dispatchMouseEvent", {"type": "mouseWheel", "x": width / 2,
                                                 "y": height / 2, "deltaX": 0, "deltaY": step})
        time.sleep(0.8)
    client.shot("private-unreachable")
    raise AssertionError(f"{client.name}: never scrolled {target!r} into view")


def _open_grid(client, name):
    client.click(f"{L.MANAGE_CHANNEL}{name}", settle=1)
    client.click(L.CHANNEL_SETTINGS, settle=2)
    _scroll_to(client, L.ADD_ROLE_OR_MEMBER)


def private_channel_follows_who_was_added(a, b, admin, member):
    name = f"e2e-private-{int(time.time()) % 100000}"
    secret_line = f"only for the people added {name}"
    channel_id = None
    try:
        a.click(L.TEXT_CHANNEL)
        a.click(f"{L.CREATE_CHANNEL_IN}Text", settle=1.5)
        a.type_into(L.CHANNEL_NAME, name)
        a.click(L.MAKE_PRIVATE, settle=1)
        a.click(L.CREATE_CHANNEL, settle=2)
        channel = admin.channel_named(name)
        channel_id = channel["id"]
        assert channel.get("restricted") is True, channel
        admin.send_message(channel_id, secret_line)
        time.sleep(2)
        assert _row(b, name) is None, "bob's rail shows a private channel he was never added to"
        assert name not in {c["name"] for c in member.channels()}, "the server lists it to bob"
        status = _bob_reads(member, channel_id)
        assert status in (403, 404), f"the server answered bob's read of a private channel with {status}"
        print("  made private in the create sheet; bob neither sees it nor can read it from the server")

        _open_grid(a, name)
        a.click(L.ADD_ROLE_OR_MEMBER, settle=1)
        a.click("Bob", settle=1)
        _scroll_to(a, f"{L.VIEW_CHANNELS}, Bob")
        a.click(f"{L.VIEW_CHANNELS}, Bob", settle=1)
        assert a.find(f"{L.VIEW_CHANNELS}, Bob: Allow"), "the cell did not turn to Allow"
        _save_grid(a)
        _wait_row(b, name, True)
        b.click(name, settle=2)
        b.wait_for(secret_line)
        assert _bob_reads(member, channel_id) == 200
        b.shot("private-added")
        print("  adding bob from the permission grid shows it on his rail live, and he reads it")

        _scroll_to(a, f"Remove Bob{L.FROM_THIS_GRID}", step=-300)
        a.click(f"Remove Bob{L.FROM_THIS_GRID}", settle=1)
        _save_grid(a)
        _wait_row(b, name, False)
        deadline = time.time() + TIMEOUT
        while b.find(secret_line):
            assert time.time() < deadline, "bob's open channel kept showing the message after removal"
            time.sleep(0.25)
        b.wait_for(f"no longer have access to #{name}", timeout=TIMEOUT)
        assert not b.find("was not found"), "bob got the not-found card instead of leaving the channel"
        status = _bob_reads(member, channel_id)
        assert status in (403, 404), f"after removal the server answered bob's read with {status}"
        b.shot("private-removed")
        print("  removing him, while he sits in it, takes him out with a notice and the server refuses him")
    finally:
        a.dismiss_overlay()
        if channel_id:
            admin.status("DELETE", f"/channels/{channel_id}")
