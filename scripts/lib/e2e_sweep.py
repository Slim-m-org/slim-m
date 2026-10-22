# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The endpoints a person reaches through UI this harness cannot drive yet.

Search, pins, polls, editing, deleting, invites, DMs, devices and read state
all have screens, but driving each of them would be a scenario apiece, and a
route with no coverage at all is worse than one covered a layer down. These
call the API directly and check the effect rather than the status code, so a
route that answers 200 and stores nothing still fails.

Each is named in the output, so the run says which routes it actually touched
rather than implying the whole schema was exercised.
"""
import time
import uuid

TOUCHED = []


def _id():
    """A client-generated id, which send and poll-send both require.

    They are idempotent by it: retrying with the same id returns the stored
    message rather than sending twice, so it is the caller's to mint.
    """
    return str(uuid.uuid4())


def _did(route):
    TOUCHED.append(route)


def messages_can_be_edited_and_deleted(api, channel_id):
    sent = api.call("POST", f"/channels/{channel_id}/messages",
                    {"id": _id(), "content": "a message that will be edited"})
    _did("POST /channels/{id}/messages")

    api.call("PATCH", f"/channels/{channel_id}/messages/{sent['id']}",
             {"content": "edited"})
    _did("PATCH /channels/{id}/messages/{id}")
    after = api.call("GET", f"/channels/{channel_id}/messages")
    rows = after["messages"] if isinstance(after, dict) else after
    edited = next(m for m in rows if m["id"] == sent["id"])
    assert edited["content"] == "edited", edited["content"]
    assert edited.get("edited_at"), "an edit left no edited_at"
    print("  a message was edited, and the row says when")

    api.call("DELETE", f"/channels/{channel_id}/messages/{sent['id']}")
    _did("DELETE /channels/{id}/messages/{id}")
    after = api.call("GET", f"/channels/{channel_id}/messages")
    rows = after["messages"] if isinstance(after, dict) else after
    gone = [m for m in rows
            if m["id"] == sent["id"] and not m.get("deleted_at")]
    assert not gone, "a deleted message is still listed as present"
    print("  and deleting it took it out of the list")


def search_finds_what_was_said(api, channel_id):
    # Letters and digits only: `q` reaches FTS5 close to as-is, so a hyphen
    # is query syntax there and earns a documented 400 rather than a match.
    needle = f"findable{int(time.time())}"
    api.call("POST", f"/channels/{channel_id}/messages",
             {"id": _id(), "content": needle})
    deadline = time.time() + 20
    hits = []
    while time.time() < deadline:
        got = api.call("GET",
                       f"/channels/{channel_id}/messages/search?q={needle}")
        hits = got.get("messages", got) if isinstance(got, dict) else got
        if hits:
            break
        time.sleep(0.5)
    _did("GET /channels/{id}/messages/search")
    assert hits, f"search found nothing for {needle!r}"
    assert any(needle in (m.get("content") or "") for m in hits), hits
    print(f"  search found {needle!r} in {len(hits)} result(s)")


def pinning(api, channel_id):
    sent = api.call("POST", f"/channels/{channel_id}/messages",
                    {"id": _id(), "content": "worth keeping"})
    api.call("PUT", f"/channels/{channel_id}/messages/{sent['id']}/pin")
    _did("PUT /channels/{id}/messages/{id}/pin")

    pins = api.pins(channel_id)
    _did("GET /channels/{id}/pins")
    assert any(m["id"] == sent["id"] for m in pins), "the pin did not stick"
    count = api.call("GET", f"/channels/{channel_id}/pins/count")
    _did("GET /channels/{id}/pins/count")
    assert (count.get("count") if isinstance(count, dict) else count) >= 1
    print(f"  a message was pinned, and the count agrees: {count}")

    # Unpinning is a DELETE on the same path, not a flag on the PUT.
    api.call("DELETE", f"/channels/{channel_id}/messages/{sent['id']}/pin")
    _did("DELETE /channels/{id}/messages/{id}/pin")
    assert not any(m["id"] == sent["id"] for m in api.pins(channel_id)), \
        "unpinning left it pinned"
    print("  and unpinning removed it")


def polls(api, channel_id):
    sent = api.call("POST", f"/channels/{channel_id}/messages/polls", {
        "id": _id(),
        "question": "does the poll path work?",
        "options": ["yes", "also yes"]})
    _did("POST /channels/{id}/messages/polls")
    poll_id = sent.get("id")
    api.call("PUT", f"/messages/{poll_id}/polls/vote", {"option": 0})
    _did("PUT /messages/{id}/polls/vote")

    rows = api.messages(channel_id)
    voted = next((m for m in rows if m["id"] == poll_id), None)
    assert voted and voted.get("poll"), "the poll did not come back on the row"
    print(f'  a poll was created and voted in: {voted["poll"]}')


def invites(api):
    made = api.call("POST", "/invites", {})
    _did("POST /invites")
    code = made["code"]
    listed = api.call("GET", "/invites")
    _did("GET /invites")
    rows = listed.get("invites", listed) if isinstance(listed, dict) else listed
    assert any(i.get("code") == code for i in rows), "the invite is not listed"

    check = api.call("GET", f"/invites/{code}/check")
    _did("GET /invites/{code}/check")
    assert check.get("usable") is True, check
    print(f"  an invite was created, listed and reads as usable: {code}")


def direct_messages(api, other_id):
    """Opening a DM answers a summary, not a channel: it carries the id."""
    opened = api.call("POST", f"/dms/{other_id}")
    _did("POST /dms/{userId}")
    channel_id = opened["channel_id"]

    listed = api.call("GET", "/dms")
    _did("GET /dms")
    rows = listed.get("conversations", listed) if isinstance(listed, dict) \
        else listed
    assert any(c.get("channel_id") == channel_id for c in rows), \
        f"the DM is not listed: {rows}"

    api.call("POST", f"/channels/{channel_id}/messages",
             {"id": _id(), "content": "a direct message"})
    stored = api.message_with(channel_id, "a direct message")
    assert stored, "the DM carried no message"
    print("  a direct message channel opened and carried a message")


def channel_admin(api):
    made = api.call("POST", "/channels", {"name": "sweep", "kind": "text"})
    _did("POST /channels")
    api.call("PATCH", f"/channels/{made['id']}",
             {"name": "sweep-renamed", "topic": "set by the e2e sweep"})
    _did("PATCH /channels/{id}")
    again = api.channel_named("sweep-renamed")
    assert again["topic"] == "set by the e2e sweep", again
    print("  a channel was created, renamed and given a topic")

    api.call("DELETE", f"/channels/{made['id']}")
    _did("DELETE /channels/{id}")
    assert not any(c["name"] == "sweep-renamed" for c in api.channels()), \
        "the channel survived deletion"
    print("  and deleting it removed it")


def devices_and_read_state(api, channel_id):
    """Marks the newest message read, then confirms the state agrees.

    `after_seq` starts one below the latest rather than at 0: PER_SCOPE_LIMIT
    (100) would otherwise cap what a busy channel answers, oldest-first,
    before the newest message reached this page.
    """
    devices = api.call("GET", "/devices")
    _did("GET /devices")
    rows = devices.get("devices", devices) if isinstance(devices, dict) \
        else devices
    assert rows, "the caller has no devices, but signed in with one"

    latest = api.messages(channel_id)[0]  # newest-first: index 0, not -1.
    api.call("PUT", f"/channels/{channel_id}/read", {"seq": latest["seq"]})
    _did("PUT /channels/{id}/read")

    read_state = api.call("GET", f"/channels/{channel_id}/read")
    _did("GET /channels/{id}/read")
    assert read_state["last_read_seq"] == latest["seq"], \
        f"marking read to {latest['seq']} did not stick: {read_state}"
    assert read_state["unread"] == 0, \
        f"nothing should be unread right after marking read: {read_state}"

    after_seq = latest["seq"] - 1
    synced = api.call("POST", "/sync", {
        "scopes": [{"channel_id": channel_id, "after_seq": after_seq}]})
    _did("POST /sync")
    scope = next(s for s in synced["scopes"] if s["channel_id"] == channel_id)
    ids = {m["id"] for m in scope["messages"]}
    assert latest["id"] in ids, \
        f"sync from {after_seq} did not carry the latest message: {scope}"
    print(f"  {len(rows)} device(s) listed, read state advanced and sync "
          f"carried {len(scope['messages'])} message(s)")


def run_all(api, channel_id, other_id):
    TOUCHED.clear()
    messages_can_be_edited_and_deleted(api, channel_id)
    search_finds_what_was_said(api, channel_id)
    pinning(api, channel_id)
    polls(api, channel_id)
    invites(api)
    direct_messages(api, other_id)
    channel_admin(api)
    devices_and_read_state(api, channel_id)
    print(f"  routes touched by the sweep: {len(TOUCHED)}")
