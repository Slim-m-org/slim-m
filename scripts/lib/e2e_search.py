# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Searching a channel from its header finds what the server's index holds.

The header's search opens the palette scoped to the channel by an in: chip,
and the query is typed into its field, so the result rows are what the
person sees. A row must follow the index, not the screen: after the
message is edited away from the word, the same search must find nothing, and
the server's search must agree on both sides. Another channel's message with
the same word must never turn up in this channel's results.
"""
import time
import urllib.parse

import e2e_input as I
import e2e_labels as L

TIMEOUT = 20
SEARCH_BUTTON = "Search messages"
SEARCH_FIELD = "Search messages"
NO_MATCHES = "No matches."


def _hits(client, word):
    return [n for n in client.nodes() if n["t"].startswith("Message from") and word in n["t"]]


def _wait_hits(client, word, count):
    deadline = time.time() + TIMEOUT
    while len(_hits(client, word)) != count:
        if time.time() >= deadline:
            client.shot("search-hits")
            raise AssertionError(
                f"{client.name}: {len(_hits(client, word))} result rows for {word!r}, wanted {count}")
        time.sleep(0.25)


def _server_hits(api, channel_id, word):
    got = api.call("GET", f"/channels/{channel_id}/messages/search?q={urllib.parse.quote(word)}")
    rows = got.get("messages", got) if isinstance(got, dict) else got
    return [m["id"] for m in rows]


def _wait_server_hits(api, channel_id, word, want):
    deadline = time.time() + TIMEOUT
    while True:
        ids = _server_hits(api, channel_id, word)
        if ids == want:
            return
        assert time.time() < deadline, f"the server's search for {word!r} gave {ids}, wanted {want}"
        time.sleep(0.25)


def search_follows_the_index(a, admin):
    stamp = int(time.time())
    word = f"searchable{stamp}"
    other = f"elsewhere{stamp}"
    channel_id = admin.channel_named(L.TEXT_CHANNEL)["id"]
    voice_id = admin.channel_named(L.VOICE_CHANNEL)["id"]
    mine = admin.send_message(channel_id, f"the {word} appears here")
    stray = admin.send_message(voice_id, f"the {word} appears there")
    a.click(L.TEXT_CHANNEL)
    a.wait_for(L.COMPOSER)
    try:
        a.click(SEARCH_BUTTON, settle=1)
        a.type_into(SEARCH_FIELD, word)
        _wait_hits(a, word, 1)
        a.shot("search-found")
        _wait_server_hits(admin, channel_id, word, [mine["id"]])
        print("  the header search lists this channel's one message, not the other channel's, matching the server")

        admin.edit_message(channel_id, mine["id"], f"now it says {other}")
        a.type_into(SEARCH_FIELD, "")
        I.clear_field(a)
        a.type_into(SEARCH_FIELD, word)
        # The empty state draws only once this query came back empty, unlike the bare list shown while it runs.
        a.wait_for(NO_MATCHES, timeout=TIMEOUT)
        rows = [n["t"] for n in a.nodes() if n["t"].startswith("Message from")]
        assert not rows, f"the search came back empty yet shows {rows}"
        _wait_server_hits(admin, channel_id, word, [])
        print("  after the message is edited away from the word, nothing is found")

        a.dismiss_overlay()
        assert not a.find(SEARCH_FIELD, field=True), "the search field stayed after closing"
        print("  closing the search removes the field")
    finally:
        a.dismiss_overlay()
        admin.delete_message(channel_id, mine["id"])
        admin.delete_message(voice_id, stray["id"])
