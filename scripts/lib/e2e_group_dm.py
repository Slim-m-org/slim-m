# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A group message started from the rail reaches everyone in it, and leaving takes it away.

Alice starts a group with bob and a third member from the Direct messages
section's own button. Her first message has to reach bob's screen and the
third member's API, and the group has to stay invisible to the deployment's
other members. Bob then leaves from the group's member sheet, which must take
it off his rail and out of what the server lets him read, while the others
keep it.
"""
import time

import e2e_labels as L
import e2e_session
from e2e_api import Api

PASSWORD = "group-dm-pass-1"
TIMEOUT = 20


def _group_row(client, *names):
    """Bob's rail row for the group: a row naming every other member."""
    for node in client.nodes():
        if all(n in node["t"] for n in names) and "\n" not in node["t"]:
            return node
    return None


def _wait(predicate, what, timeout=TIMEOUT):
    deadline = time.time() + timeout
    while not predicate():
        assert time.time() < deadline, what
        time.sleep(0.25)


def group_message_reaches_everyone_and_leaving_ends_it(a, b, admin, member, server):
    username, display = e2e_session.register_member(server, admin, PASSWORD)
    third = Api(server)
    third.login(username, PASSWORD, device="e2e-group-third")
    outsider_name, _ = e2e_session.register_member(server, admin, PASSWORD)
    outsider = Api(server)
    outsider.login(outsider_name, PASSWORD, device="e2e-group-outsider")
    line = f"hello to the three of us {int(time.time())}"
    group_id = None
    try:
        a.click(L.TEXT_CHANNEL)
        a.click(L.NEW_GROUP_MESSAGE, settle=1.5)
        a.click("Bob", settle=0.5)
        # The list is capped in height, and every earlier scenario's fresh member sorts beside this one.
        a.type_into(L.SEARCH_PEOPLE, display)
        a.settle(0.8)
        a.click(display, settle=0.5)
        a.click(f"{L.START_GROUP_WITH}3 people", settle=3)
        group_id = a.ev("location.hash").split("/channels/")[-1].split("?")[0]
        a.wait_for(L.COMPOSER)
        a.type_into(L.COMPOSER, line)
        a.click(L.SEND, settle=2)

        _wait(lambda: any(line in (m.get("content") or "")
                          for m in third.messages(group_id)), "the third member never got it")
        assert outsider.status("GET", f"/channels/{group_id}/messages") in (403, 404), \
            "a member outside the group could read it"
        _wait(lambda: _group_row(b, "Alice", display) is not None, "bob's rail never showed the group")
        b.ev(f"location.hash = '#/channels/{group_id}'")
        b.wait_for(line)
        assert b.find(L.GROUP_INTRO), "the group's intro still talks to two people"
        b.shot("group-dm-received")
        print("  alice's group reaches bob's screen and the third member, and nobody else")

        b.click(L.GROUP_MEMBERS, settle=1.5)
        b.click(L.LEAVE_GROUP, settle=1)
        confirm = next(n for n in b.nodes() if n["t"].startswith("Leave ")
                       and n["t"] not in (L.LEAVE_GROUP, "Leave call"))
        b.tap(confirm["x"], confirm["y"])
        b.settle(2)
        _wait(lambda: _group_row(b, "Alice", display) is None, "bob's rail kept the group after he left")
        _wait(lambda: member.status("GET", f"/channels/{group_id}/messages") in (403, 404),
              "the server still served bob the group after he left")
        assert any(line in (m.get("content") or "") for m in third.messages(group_id)), \
            "leaving took the group from the others too"
        b.shot("group-dm-left")
        print("  bob leaves from the member sheet; it goes from his rail and the server, and the others keep it")
    finally:
        b.dismiss_overlay()
        if group_id:
            for api in (admin, third):
                api.status("POST", f"/dms/groups/{group_id}/leave")
