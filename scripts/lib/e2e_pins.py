# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Pinning a message from its menu, reading the pinned list, and unpinning.

Alice pins from the message menu and bob opens the pinned list from the
channel header; the server's own pin list is read at each step. Bob has no
Manage Pins, so his menu must not offer Pin at all. Unpinning from the list
leaves the message in the channel and takes it out of the list on both sides.
"""
import time

import e2e_input as I
import e2e_labels as L

TIMEOUT = 15
UNPIN_ROW = "Unpin this message"


def _tap_exact(client, label):
    """The control whose label is [label], or [label] then a hint; never a longer label that merely contains it."""
    deadline = time.time() + TIMEOUT
    while True:
        node = next((n for n in client.nodes() if n["t"] == label or n["t"].startswith(label + ",")), None)
        if node:
            client.tap(node["x"], node["y"])
            client.settle(1.5)
            return
        if time.time() >= deadline:
            client.shot(f"pins-no-{label[:12].replace(' ', '-')}")
            raise AssertionError(f"{client.name}: no control labelled exactly {label!r}")
        time.sleep(0.25)


def _pinned_ids(api, channel_id):
    return {m["id"] for m in api.pins(channel_id)}


def _wait_pinned(api, channel_id, message_id, want):
    deadline = time.time() + TIMEOUT
    while (message_id in _pinned_ids(api, channel_id)) != want:
        assert time.time() < deadline, f"the server's pin list never became pinned={want}"
        time.sleep(0.25)


def _wait_gone(client, text):
    deadline = time.time() + TIMEOUT
    while client.find(text):
        if time.time() >= deadline:
            client.shot("pins-still-listed")
            raise AssertionError(f"{client.name}: {text!r} is still on screen")
        time.sleep(0.25)


def _sheet_rows(client, text):
    """Nodes holding [text] under the open sheet's title; the header's own pin button sits above 100px."""
    nodes = client.nodes()
    titles = [n for n in nodes if n["t"] == L.PINNED_MESSAGES and n["y"] > 100]
    if not titles:
        return None
    return [n for n in nodes if text in n["t"] and n["y"] > titles[0]["y"]]


def _wait_sheet(client, text, listed):
    deadline = time.time() + TIMEOUT
    while True:
        rows = _sheet_rows(client, text)
        if rows is not None and bool(rows) == listed:
            return
        if time.time() >= deadline:
            client.shot("pins-sheet")
            raise AssertionError(f"{client.name}: pinned sheet open={rows is not None}, "
                                 f"lists {text!r}={bool(rows)}, wanted {listed}")
        time.sleep(0.25)


def _menu_on(client, text):
    row = client.wait_for(text)
    I.right_click(client, row["x"], row["y"])
    client.wait_for(L.MENU_COPY_TEXT)


def pin_list_and_unpin(a, b, admin, member):
    text = f"worth keeping {int(time.time())}"
    channel_id = admin.channel_named(L.TEXT_CHANNEL)["id"]
    for c in (a, b):
        c.click(L.TEXT_CHANNEL)
        c.wait_for(L.COMPOSER)
    message_id = member.send_message(channel_id, text)["id"]
    a.wait_for(text)
    b.wait_for(text)
    try:
        _menu_on(b, text)
        assert not any(n["t"] == L.MENU_PIN for n in b.nodes()), \
            "bob's menu offers Pin without Manage Pins"
        b.dismiss_overlay()
        print("  a member without Manage Pins is not offered Pin")

        _menu_on(a, text)
        _tap_exact(a, L.MENU_PIN)
        _wait_pinned(admin, channel_id, message_id, True)
        print("  alice pins it from the message menu and the server lists it")

        b.click(L.PINNED_MESSAGES, settle=2)
        _wait_sheet(b, text, True)
        b.shot("pins-listed")
        b.dismiss_overlay()
        print("  bob sees it in the channel's pinned list")

        a.click(L.PINNED_MESSAGES, settle=2)
        a.wait_for(UNPIN_ROW)
        unpin = a.wait_for(UNPIN_ROW)
        a.tap(unpin["x"], unpin["y"])
        a.settle(1.5)
        _wait_pinned(admin, channel_id, message_id, False)
        _wait_gone(a, UNPIN_ROW)
        a.dismiss_overlay()
        b.click(L.PINNED_MESSAGES, settle=2)
        _wait_sheet(b, text, False)
        b.dismiss_overlay()
        assert any(m["id"] == message_id for m in admin.messages(channel_id)), \
            "unpinning removed the message itself"
        a.wait_for(text)
        print("  unpinning from the list clears the server pin and leaves the message")
    finally:
        a.dismiss_overlay()
        b.dismiss_overlay()
        if message_id in _pinned_ids(admin, channel_id):
            admin.call("DELETE", f"/channels/{channel_id}/messages/{message_id}/pin")
        admin.delete_message(channel_id, message_id)
