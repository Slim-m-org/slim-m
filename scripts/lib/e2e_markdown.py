# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Formatting markers are a rendering choice, not something the wire carries.

The one property worth driving a real browser for: what the server stores and
what a person sees are deliberately different here. The raw text with its
markers goes over REST unchanged, and the client is the only thing that turns
it into weight and strikes. A test at either layer alone would pass while the
other half was broken.
"""

import e2e_labels as L


def formats_without_storing_the_markers(sender, receiver, channel, api):
    """Sends marked-up text, then checks each layer for the opposite thing.

    The server must hold the markers (or an edit would lose the formatting and
    a future client could not re-render it), and the accessibility tree must
    not (or nothing is being formatted and the markers are just being shown).
    """
    raw = "**bold** and *italic* and ~~struck~~"
    rendered = "bold and italic and struck"

    for c in (sender, receiver):
        c.click(channel)
        c.wait_for(L.COMPOSER)

    sender.type_into(L.COMPOSER, raw)
    sender.click(L.SEND, settle=2)

    receiver.wait_for(rendered)
    print(f'  {receiver.name} sees "{rendered}", with no markers in the tree')

    if receiver.find(raw) is not None:
        receiver.shot("markdown-markers-still-visible")
        raise AssertionError(
            "the formatting markers are being rendered rather than applied")

    stored = api.message_with(api.channel_named(channel)["id"], raw)
    assert stored["content"] == raw, (
        f"the server must keep the markers, stored {stored['content']!r}")
    print("  and the server stored the markers unchanged")


def a_spoiler_hides_its_text(sender, receiver, channel, api):
    """A spoiler's content must be absent from the tree, not merely dimmed.

    Asserting on opacity would pass for text a screen reader still reads out,
    which is the failure that matters: a spoiler nobody can see but everybody
    is told is not a spoiler.
    """
    secret = "the butler did it"
    raw = f"||{secret}||"

    sender.click(channel)
    sender.wait_for(L.COMPOSER)
    sender.type_into(L.COMPOSER, raw)
    sender.click(L.SEND, settle=2)

    api.message_with(api.channel_named(channel)["id"], raw)

    receiver.click(channel)
    receiver.wait_for(L.HIDDEN_SPOILER)
    if receiver.find(secret) is not None:
        receiver.shot("spoiler-text-was-readable")
        raise AssertionError("a spoiler must not publish its text to the tree")
    print(f"  {receiver.name} is not told what is under the spoiler")
