# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A channel's unread mark follows what bob has actually read, on screen and on the server.

Bob sits in another channel while alice writes, so the only thing that can
clear the mark is reading: opening the channel, reading it on his other
device, or the unread message going away before he ever saw it. Each is read
back from bob's rail row and from his read state on the server, which is what
his other devices and the app badge go by.
"""
import time

import e2e_labels as L

TIMEOUT = 15


def _row(client, name):
    """The rail row's spoken label: the name, then "unread" or "mentioned" when lit."""
    for node in client.nodes():
        if node["t"].split(", ")[0] == name:
            return node["t"]
    return None


def _row_reads(client, name, want, timeout=TIMEOUT):
    deadline = time.time() + timeout
    while True:
        got = _row(client, name)
        if got is not None and _state(got) == want:
            return got
        if time.time() >= deadline:
            client.shot(f"unread-{want or 'clear'}")
            raise AssertionError(f"{client.name}: row {name!r} reads {got!r}, wanted {want or 'clear'}")
        time.sleep(0.25)


def _state(label):
    parts = label.split(", ")[1:]
    return next((p for p in parts if p in ("unread", "mentioned")), None)


def _server_unread(member, channel_id, want, timeout=TIMEOUT):
    deadline = time.time() + timeout
    while True:
        state = member.call("GET", f"/channels/{channel_id}/read")
        if bool(state["unread"]) == want:
            return state
        assert time.time() < deadline, f"bob's read state never became unread={want}: {state}"
        time.sleep(0.25)


def unread_follows_what_was_read(b, admin, member):
    name = f"e2e-unread-{int(time.time())}"
    channel = admin.call("POST", "/channels", {"name": name, "kind": "text"})
    channel_id = channel["id"]
    try:
        b.click(L.TEXT_CHANNEL)
        _row_reads(b, name, None)

        admin.send_message(channel_id, "a plain message bob has not read")
        _row_reads(b, name, "unread")
        _server_unread(member, channel_id, True)
        admin.send_message(channel_id, "and now @bob by name")
        _row_reads(b, name, "mentioned")
        print("  bob's row lights for a message, and turns to a mention for @bob")

        b.click(name, settle=2)
        b.wait_for("by name")
        b.click(L.TEXT_CHANNEL)
        _row_reads(b, name, None)
        state = _server_unread(member, channel_id, False)
        newest = max(m["seq"] for m in admin.messages(channel_id))
        assert state["last_read_seq"] == newest, (state, newest)
        print("  opening the channel clears the row and moves his marker to the newest message")

        gone = admin.send_message(channel_id, "said and taken back")
        _row_reads(b, name, "unread")
        admin.delete_message(channel_id, gone["id"])
        _row_reads(b, name, None)
        _server_unread(member, channel_id, False)
        print("  a message deleted before bob read it leaves nothing unread behind")

        sent = admin.send_message(channel_id, "read on bob's other device")
        _row_reads(b, name, "unread")
        member.call("PUT", f"/channels/{channel_id}/read", {"seq": sent["seq"]})
        _row_reads(b, name, None)
        print("  reading it on his other device clears the row here without a click")
    finally:
        admin.status("DELETE", f"/channels/{channel_id}")
