# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""An edit and a delete that happen while one client is away.

This is the one thing the message op stream exists for, and the only scenario
in the harness where a client is deliberately not watching. Every other
scenario keeps both clients open, which is exactly why none of them could have
caught the debt this closes: with both sockets live, an edit arrives as a
frame and the local copy is corrected without any cursor being consulted.

The client goes away by navigating to a blank page rather than being killed,
so its browser profile and drift's IndexedDB survive. That is deliberate: the
local cache and its cursors have to still be there, holding the old text, for
the return trip to have anything to correct.
"""

import time

import e2e_labels as L


def survives_an_absence(away, watcher, channel, api):
    """Edits one message and deletes another while `away` is not looking.

    Asserts the returning client shows the new text and no longer shows the
    deleted message, without anyone telling it to refresh: the only thing that
    can produce that is catch-up applying the op stream.
    """
    edited_before = "before the edit"
    edited_after = "after the edit"
    doomed = "this one gets deleted"

    for c in (away, watcher):
        c.click(channel)
        c.wait_for(L.COMPOSER)

    away.type_into(L.COMPOSER, edited_before)
    away.click(L.SEND, settle=2)
    away.type_into(L.COMPOSER, doomed)
    away.click(L.SEND, settle=2)

    # Seen by the client that will leave, so its cache genuinely holds both.
    away.wait_for(edited_before)
    away.wait_for(doomed)

    channel_id = api.channel_named(channel)["id"]
    stored_edit = api.message_with(channel_id, edited_before)
    stored_delete = api.message_with(channel_id, doomed)

    home = away.go_away()
    print(f"  {away.name} is away; its cache still holds the old text")

    # Over the API: this is about reaching an absent client, not about who wrote.
    api.edit_message(channel_id, stored_edit["id"], edited_after)
    api.delete_message(channel_id, stored_delete["id"])
    time.sleep(2)

    away.come_back(home)
    away.click(channel)
    away.wait_for(L.COMPOSER)

    away.wait_for(edited_after)
    print(f"  {away.name} came back to the edited text")

    deadline = time.time() + 20
    while time.time() < deadline:
        if away.find(doomed) is None:
            print(f"  and the deleted message is gone from {away.name}")
            return
        time.sleep(0.25)
    away.shot("deleted-message-survived-absence")
    raise AssertionError(
        f"{away.name} still shows a message deleted while it was away")
