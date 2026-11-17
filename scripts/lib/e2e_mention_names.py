# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A mention reads as the member's name in this space, and follows it live.

The message keeps `@bob` on the wire; only the reader's screen shows the name,
so this is read from bob's own screen and alice's: the nickname while it is
set, the account's name once it is removed, without reloading. A mention
inside a code span is code and stays as typed.
"""
import time

NICKNAME = "Robert"


def _row_holding(client, needle, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for node in client.nodes():
            if needle in node["t"]:
                return node["t"]
        time.sleep(0.25)
    client.shot(f"missing-{needle[:20].replace(' ', '-')}")
    raise AssertionError(f"{client.name}: no row holding {needle!r}")


def _wait_until(client, needle, holds, timeout=20):
    deadline = time.time() + timeout
    while True:
        text = _row_holding(client, needle)
        if holds in text:
            return text
        assert time.time() < deadline, f"{client.name}: {needle!r} never showed {holds!r}: {text!r}"
        time.sleep(0.25)


def mention_reads_the_name_in_this_space(a, b, channel, admin, member):
    channel_id = admin.channel_named(channel)["id"]
    bob_id = member.me()["id"]
    stamp = int(time.time())
    plain = f"about the mention names {stamp}"
    code = f"stays as typed {stamp}"
    a.click(channel)
    b.click(channel)
    admin.call("PUT", f"/members/{bob_id}/nickname", {"nickname": NICKNAME})
    try:
        admin.send_message(channel_id, f"ping @bob {plain}")
        admin.send_message(channel_id, f"`@bob` {code}")
        for c in (a, b):
            text = _wait_until(c, plain, f"@{NICKNAME}")
            assert "@bob" not in text, f"{c.name} still shows the username: {text!r}"
        assert "@bob" in _row_holding(a, code), "a mention inside code was rewritten"
        a.shot("mention-nickname")
        print(f"  both screens read @bob as @{NICKNAME}; the code span keeps @bob")

        admin.call("DELETE", f"/members/{bob_id}/nickname")
        for c in (a, b):
            _wait_until(c, plain, "@Bob")
        print("  removing the nickname turns the same mention into @Bob without a reload")
    finally:
        admin.status("DELETE", f"/members/{bob_id}/nickname")
