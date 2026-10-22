# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""An administrator giving another member a space-local name.

Driven from the member card, the way an administrator does it: the member list
row, Moderate, Rename. The nickname is then read where other people meet it,
the transcript's author line and the member list, and the account's own name is
checked to be untouched. It is removed at the end so every later scenario still
finds the member under the name the rest of the run uses.
"""
import time

import e2e_labels as L

NICKNAME = "Robert"


def _wait_for_member_row(client, name, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for node in client.nodes():
            if node["t"].startswith(f"{name}, ") and node["x"] > 1000:
                return node
        time.sleep(0.25)
    client.shot(f"missing-member-{name}")
    raise AssertionError(f"{client.name}: no member row for {name!r}")


def admin_renames_a_member(admin_client, channel, admin_api, member_api):
    """Rename Bob to Robert, see it in the list and transcript, then undo it."""
    channel_id = admin_api.channel_named(channel)["id"]
    text = f"said under a nickname {int(time.time())}"
    member_api.send_message(channel_id, text)
    admin_client.click(channel)
    admin_client.wait_for(text)
    if not admin_client.find("Online"):
        admin_client.click(L.MEMBER_LIST, settle=1.5)
    row = _wait_for_member_row(admin_client, "Bob")

    try:
        admin_client.click(row["t"], settle=2)
        admin_client.click(L.MODERATE, settle=2)
        admin_client.click(L.RENAME_MEMBER, settle=2)
        admin_client.type_into(L.NICKNAME_FIELD, NICKNAME)
        admin_client.click(L.SAVE_NAME, settle=3)

        _wait_for_member_row(admin_client, NICKNAME)
        admin_client.wait_for(f"{NICKNAME}, view profile")
        admin_client.shot("member-nickname")
        member = next(m for m in admin_api.members()
                      if m["id"] == member_api.me()["id"])
        assert member["display_name"] == NICKNAME, member
        assert member_api.me()["display_name"] == "Bob", \
            "the nickname rewrote the account's own name"
        print(f"  Bob was renamed {NICKNAME} from the member card: the "
              "member list, the transcript and /members all show it")
    finally:
        admin_api.call("DELETE", f"/members/{member_api.me()['id']}/nickname")
    assert next(m for m in admin_api.members()
                if m["id"] == member_api.me()["id"])["display_name"] == "Bob"
    print("  and removing the nickname gave the account's own name back")
