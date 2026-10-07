# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What a person does in a channel: talk, react, mention, attach, pin.

Each of these drives the UI the way a person would and then asks the server
whether it happened, because a chip that renders is not a row that was stored.
"""
import time

import e2e_labels as L


def send_and_receive(sender, receiver, channel, text, api):
    """One message, typed by one client and waited for on the other.

    Nothing is stubbed between them: it goes over REST, fans out through the
    hub, and arrives on the other socket. The receiver is never told to
    refresh, so a message that only appears on reconnect fails this.
    """
    for c in (sender, receiver):
        c.click(channel)
        c.wait_for(L.COMPOSER)
    sender.type_into(L.COMPOSER, text)
    sender.click(L.SEND, settle=2)

    sender.wait_for(text)
    receiver.wait_for(text)
    stored = api.message_with(api.channel_named(channel)['id'], text)
    assert stored['content'] == text, f"server stored {stored['content']!r}"
    print(f'  "{text[:34]}" reached {receiver.name} live, and the server has it')


def react(client, other, message_text, emoji_name, api, channel):
    """Add a reaction through the picker, and see it on the other client.

    The react affordance appears on hover and carries no label, so this is the
    one place a real pointer is used rather than the accessibility tree. The
    emoji inside the picker are labelled, so the emoji itself is picked by name.
    """
    row = client.wait_for(message_text)
    # The react affordance only exists while the pointer is over the message,
    # so this is one of the two places a real mouse is used rather than the
    # accessibility tree. It is labelled once shown, so the click is by name.
    client.gestures(True)
    try:
        client.hover(row['x'], row['y'])
    finally:
        client.gestures(False)
    client.click(L.ADD_REACTION, settle=2)
    client.wait_for(emoji_name)
    client.click(emoji_name, settle=2)

    channel_id = api.channel_named(channel)['id']
    deadline = time.time() + 30
    while time.time() < deadline:
        stored = api.message_with(channel_id, message_text)
        if stored.get('reactions'):
            break
        time.sleep(2)
    stored = api.message_with(channel_id, message_text)
    assert stored.get('reactions'), 'the server recorded no reaction'
    other.wait_for('reaction')
    client.shot('reaction-added')
    print(f'  reacted with {emoji_name}, and {other.name} sees it: '
          f'{stored["reactions"]}')


def mention(sender, receiver, channel, who, api):
    """A mention is ordinary message text the server has to keep verbatim."""
    text = f'@{who} take a look at this'
    sender.click(channel)
    sender.type_into(L.COMPOSER, text)
    sender.click(L.SEND, settle=2)
    receiver.wait_for(who)
    stored = api.message_with(api.channel_named(channel)['id'], f'@{who}')
    assert f'@{who}' in stored['content'], stored['content']
    print(f'  a mention of @{who} reached {receiver.name} intact')


def attach(client, other, channel, path, api):
    """Upload a file and check the server kept it, not just that a chip drew."""
    client.click(channel)
    channel_id = api.channel_named(channel)['id']
    already = {m['id'] for m in api.messages(channel_id) if m.get('attachments')}
    client.attach_file(L.ATTACH, path)
    client.wait_for(L.REMOVE_ATTACHMENT)
    client.click(L.SEND, settle=4)

    deadline = time.time() + 40
    found = None
    while time.time() < deadline and not found:
        for m in api.messages(channel_id):
            if m.get('attachments') and m['id'] not in already:
                found = m
                break
        if not found:
            time.sleep(2)
    assert found, 'the server stored no attachment'
    client.shot('attachment-sent')
    other.shot('attachment-received')
    print(f'  an attachment reached the server: {found["attachments"]}')
    return found
