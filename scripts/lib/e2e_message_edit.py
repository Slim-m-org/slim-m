# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Changing and taking back your own message, from its menu, on both clients.

Alice writes in the composer, then edits from the message menu: Escape leaves
the stored text alone, Enter saves it and the other client sees the new text
with the edited marker. Deleting asks first, and only the confirm removes the
row on both screens. Each step is read back from the server, since a row that
changed on screen but not in storage comes back on the next reload.
"""
import time

import e2e_input as I
import e2e_labels as L

TIMEOUT = 15
EDITED_MARKER = "Edited. View edit history"


def _wait_gone(client, text, timeout=TIMEOUT):
    deadline = time.time() + timeout
    while client.find(text):
        if time.time() >= deadline:
            client.shot("edit-still-shown")
            raise AssertionError(f"{client.name}: {text!r} is still on screen")
        time.sleep(0.25)


def _stored(api, channel_id, message_id):
    got = [m for m in api.messages(channel_id) if m["id"] == message_id]
    return got[0] if got else None


def _wait_stored(api, channel_id, message_id, satisfied, failure):
    deadline = time.time() + TIMEOUT
    while True:
        message = _stored(api, channel_id, message_id)
        if satisfied(message):
            return message
        assert time.time() < deadline, f"{failure}: {message}"
        time.sleep(0.25)


def _open_menu(client, text):
    row = client.wait_for(text)
    I.right_click(client, row["x"], row["y"])


def _confirm_delete(client):
    client.wait_for("Delete message?")
    button = next((n for n in client.nodes() if n["t"] == L.MENU_DELETE), None)
    assert button, f"{client.name}: the confirm dialog has no Delete button"
    client.tap(button["x"], button["y"])
    client.settle(1.5)


def edit_then_delete_own_message(a, b, admin):
    stamp = int(time.time())
    first = f"a first draft {stamp}"
    second = f"the reworked line {stamp}"
    abandoned = f"never saved {stamp}"
    for c in (a, b):
        c.click(L.TEXT_CHANNEL)
        c.wait_for(L.COMPOSER)
    a.type_into(L.COMPOSER, first)
    a.click(L.SEND, settle=2)
    b.wait_for(first)
    channel_id = admin.channel_named(L.TEXT_CHANNEL)["id"]
    message_id = admin.message_with(channel_id, first)["id"]

    try:
        _open_menu(a, first)
        a.click(L.MENU_EDIT, settle=1)
        I.clear_field(a)
        a.send("Input.insertText", {"text": abandoned})
        time.sleep(0.3)
        I.press(a, "Escape")
        a.wait_for(first)
        assert not a.find(abandoned), "Escape left the abandoned text on screen"
        assert _stored(admin, channel_id, message_id)["content"] == first
        print("  Escape abandons an edit and nothing reaches the server")

        _open_menu(a, first)
        a.click(L.MENU_EDIT, settle=1)
        I.clear_field(a)
        a.send("Input.insertText", {"text": second})
        time.sleep(0.3)
        I.press(a, "Enter")
        a.wait_for(second)
        b.wait_for(second)
        b.wait_for(EDITED_MARKER)
        assert not b.find(first), "bob still shows the old text beside the new"
        saved = _wait_stored(admin, channel_id, message_id,
                             lambda m: m and m["content"] == second,
                             "the server never took the edit")
        assert saved.get("edited_at"), f"the edit left no edited_at: {saved}"
        print("  Enter saves it: bob sees the new text and the marker, the server holds it")

        _open_menu(a, second)
        a.click(L.MENU_DELETE, settle=1)
        a.wait_for("Delete message?")
        a.dismiss_overlay()
        assert _stored(admin, channel_id, message_id), "cancelling the dialog deleted it"
        a.wait_for(second)
        print("  dismissing the confirm keeps the message")

        _open_menu(a, second)
        a.click(L.MENU_DELETE, settle=1)
        _confirm_delete(a)
        _wait_gone(a, second)
        _wait_gone(b, second)
        _wait_stored(admin, channel_id, message_id, lambda m: m is None,
                     "the server still lists the deleted message")
        print("  confirming removes it from both screens and from the server")
    finally:
        a.dismiss_overlay()
        if _stored(admin, channel_id, message_id):
            admin.delete_message(channel_id, message_id)
