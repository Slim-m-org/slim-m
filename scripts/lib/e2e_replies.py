# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A reply's quote, rendered live on both sides, and what an honest failure
looks like once its parent is gone.

'Reply' itself lives behind the same long-press/right-click context menu as
report and block, which e2e_input.py can open with a real right-click; the
reply is still sent through the API here, the substitution that module
already makes. Everything downstream - the
rendered quote, its tap target, and what a deleted parent looks like - is an
ordinary `Semantics` node with no menu behind it, so all of that is driven
and checked through the real UI.
"""
import time

import e2e_labels as L


def reply_and_a_deleted_parent(sender, receiver, channel, api):
    """Reply to a message, see the quote on both sides, then delete it.

    The quote must go from naming its parent to the honest "Message
    unavailable" placeholder live, with nobody refreshing anything: that is
    the property the reconciliation work this feature depends on exists to
    guarantee, and it is the one assertion here worth the most.
    """
    stamp = str(int(time.time()))
    parent_text = f"a parent message {stamp}"
    reply_text = f"a reply to it {stamp}"

    for c in (sender, receiver):
        c.click(channel)
        c.wait_for(L.COMPOSER)
    sender.type_into(L.COMPOSER, parent_text)
    sender.click(L.SEND, settle=2)
    receiver.wait_for(parent_text)

    channel_id = api.channel_named(channel)['id']
    parent = api.message_with(channel_id, parent_text)
    api.send_message(channel_id, reply_text, reply_to_id=parent['id'])

    quote = f'reply to {sender.name.capitalize()}'
    for c in (sender, receiver):
        c.wait_for(reply_text)
        c.wait_for(quote)
    stored = api.message_with(channel_id, reply_text)
    assert stored['reply_to_id'] == parent['id'], \
        f"the server did not keep reply_to_id: {stored}"
    print('  the quote named its parent on both clients, and the server '
          f'kept reply_to_id={stored["reply_to_id"]}')

    receiver.click(quote, settle=2)
    receiver.never_shows(L.JUMP_FAILED, 3)
    print('  tapping the quote reached its live parent with no failure notice')

    api.delete_message(channel_id, parent['id'])
    for c in (sender, receiver):
        c.wait_for(L.REPLY_UNAVAILABLE, timeout=20)
    print('  deleting the parent turned the quote into "Message unavailable" '
          'on both clients with nobody reloading anything')

    receiver.click(L.REPLY_UNAVAILABLE_QUOTE, settle=2)
    receiver.wait_for(L.JUMP_FAILED, timeout=20)
    receiver.shot('reply-parent-deleted')
    print('  and tapping it now shows the honest "not found" notice')
