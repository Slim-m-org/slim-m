# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What a person reaches by holding or right-clicking: who reacted, and the
message menu with its quick reactions and its More page.

Both are driven with real pointer input (see e2e_input.py), which is the only
way to reach them: neither has a label to activate. An earlier note in
docs/e2e.md said a synthetic pointer event cannot open the message menu while
the accessibility tree is on. That holds for a click dispatched at a semantics
element, and does not for a genuine browser event sent with the semantics layer
lifted, which is what these use.

The reactions are added through the API so the scenario starts from a known
tally; the part under test, reading and acting on it, is all UI.
"""
import time
import urllib.parse

import e2e_input as I
import e2e_labels as L

# Written as an escape so no emoji glyph sits in a source file.
THUMBS_UP = "\U0001F44D"


def _send_and_wait(sender, receiver, channel, text, api):
    for c in (sender, receiver):
        c.click(channel)
        c.wait_for(L.COMPOSER)
    sender.type_into(L.COMPOSER, text)
    sender.click(L.SEND, settle=2)
    receiver.wait_for(text)
    return api.message_with(api.channel_named(channel)["id"], text)


def _react(api, message_id, emoji):
    api.call("PUT", f"/messages/{message_id}/reactions/"
             f"{urllib.parse.quote(emoji)}")


def _chip_below(client, row, label):
    """The reaction chip belonging to `row`: the first one under its text."""
    deadline = time.time() + 20
    while time.time() < deadline:
        below = [n for n in client.nodes()
                 if label in n["t"] and n["y"] >= row["y"]]
        if below:
            return min(below, key=lambda n: n["y"])
        time.sleep(0.25)
    raise AssertionError(f"{client.name}: no {label!r} chip under the message")


def _rows_under(client, header, names):
    """The popover's person rows: named nodes just above the chip, right of it."""
    found = {}
    for node in client.nodes():
        near = header["y"] - 160 < node["y"] < header["y"]
        if node["t"] in names and near and node["x"] > header["x"]:
            found[node["t"]] = node["y"]
    return found


def who_reacted_lists_the_people(alice, bob, admin_api, member_api, channel):
    """Holding a chip, then right-clicking it, names who left the reaction.

    Alice reacts first and Bob second, so the list must read Alice then Bob:
    the server's order is oldest first, and a client that sorted by name or by
    arrival of the profile would swap them only by luck.
    """
    stamp = str(int(time.time()))
    text = f"who left this reaction {stamp}"
    message = _send_and_wait(alice, bob, channel, text, admin_api)
    _react(admin_api, message["id"], THUMBS_UP)
    time.sleep(1)
    _react(member_api, message["id"], THUMBS_UP)

    row = alice.wait_for(text)
    chip = _chip_below(alice, row, "reaction, 2")
    for how, gesture in (("a hold", I.hold), ("a right-click", I.right_click)):
        gesture(alice, chip["x"], chip["y"])
        rows = _rows_under(alice, chip, {"Alice", "Bob"})
        assert set(rows) == {"Alice", "Bob"}, \
            f"{how} on the chip did not list both people: {rows}"
        assert rows["Alice"] < rows["Bob"], \
            f"the list is not oldest reaction first: {rows}"
        alice.shot("who-reacted")
        alice.dismiss_overlay()
        assert not _rows_under(alice, chip, {"Alice", "Bob"}), \
            "the list stayed open after Escape"
        print(f"  {how} on a two-person reaction named Alice then Bob")

    listed = admin_api.call(
        "GET", f"/messages/{message['id']}/reactions/"
        f"{urllib.parse.quote(THUMBS_UP)}")["users"]
    ids = [u["user_id"] for u in listed]
    assert ids == [admin_api.me()["id"], member_api.me()["id"]], \
        f"the server's own list disagrees with what the UI showed: {ids}"
    print("  and the server's list agrees, in the same order")


def _menu_ys(client, labels):
    found = {}
    for node in client.nodes():
        if node["t"] in labels:
            found[node["t"]] = node["y"]
    return found


QUICK = L.QUICK_REACTIONS
VERBS = L.MENU_VERBS
SECOND_PAGE = L.MENU_SECOND_PAGE


def message_menu_quick_row_then_more(alice, bob, admin_api, member_api,
                                     channel):
    """The menu opens on quick reactions and verbs, and More swaps the page.

    Bob's message is the target because Alice, an administrator, can report
    and block its author, which is what More holds. Order is checked by
    position: the quick row above the verbs, Delete the last row, and Report
    and Block absent from the first page so Delete is the only red row there.
    """
    stamp = str(int(time.time()))
    text = f"menu target {stamp}"
    channel_id = admin_api.channel_named(channel)["id"]
    for c in (alice, bob):
        c.click(channel)
        c.wait_for(L.COMPOSER)
    member_api.send_message(channel_id, text)
    row = alice.wait_for(text)
    I.right_click(alice, row["x"], row["y"])

    first = _menu_ys(alice, set(QUICK) | set(VERBS) | {L.MENU_MORE, L.MENU_DELETE})
    missing = (set(QUICK) | set(VERBS) | {L.MENU_MORE, L.MENU_DELETE}) - set(first)
    assert not missing, f"the menu's first page lacks {sorted(missing)}"
    assert max(first[q] for q in QUICK) < min(first[v] for v in VERBS), \
        f"the quick reactions are not above the verbs: {first}"
    assert first[L.MENU_MORE] < first[L.MENU_DELETE] and \
        max(first[v] for v in VERBS) < first[L.MENU_MORE], \
        f"More and Delete do not close the list in that order: {first}"
    for hidden in SECOND_PAGE:
        assert not I.exact(alice, hidden), \
            f"{hidden!r} is on the first page, which More should hold"
    alice.shot("message-menu")
    print("  the menu opens on five quick reactions above the verbs, "
          "with More then Delete last")

    alice.click(L.MENU_MORE, settle=1.5)
    for label in SECOND_PAGE:
        I.wait_exact(alice, label)
    assert not I.exact(alice, L.MENU_DELETE), "Delete is still on the second page"
    assert not I.exact(alice, QUICK[0]), "the quick row is still showing"
    alice.shot("message-menu-more")
    print("  More swapped the page in place: Select, Report and Block")

    alice.click(L.MENU_BACK, settle=1.0)
    I.wait_exact(alice, L.MENU_COPY_TEXT)
    alice.click(QUICK[0], settle=2)
    deadline = time.time() + 20
    while time.time() < deadline:
        reactions = member_api.message_with(channel_id, text)["reactions"]
        if reactions:
            break
        time.sleep(0.25)
    assert [r["emoji"] for r in reactions] == [THUMBS_UP], \
        f"the quick reaction did not reach the server: {reactions}"
    print("  Back returned to the first page, and a quick reaction landed")
