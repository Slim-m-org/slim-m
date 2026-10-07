# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Opening a thread, replying inside it, and the property most likely to
regress quietly: a thread channel must never show up beside the real ones.

The thread is opened the way a person opens one, from the message's own menu
("Reply in thread", reached with a right-click; see e2e_input.py). It used to
be opened at the API and entered by writing `#/thread/<id>` into the location,
because the menu looked unreachable.
That substitution also hid a real bug: a thread entered by an in-page hash
change came up with a composer that took text and sent nothing. The route
docked the thread in the same frame it navigated to the parent, so on the web
the composer focused an input the outgoing page owned. The sender now closes
the thread and comes back to it by a link before replying, so that path stays
covered.
The menu is also the path that carries what this scenario now checks: the
docked pane focuses its composer and shows the parent message first.

A thread has no rail row by design (docs/decisions/0005-threads.md). A
bystander only learns a thread's reply count on their next fetch of the parent
channel, never live, so the reply-count check below forces a real reload.

`L.THREAD_HEADER` is the header's leading-icon tooltip rather than the bar's own
title: an `AppBar` title produces no semantics leaf in Flutter web, and the
tooltip is a real leaf that appears exactly once, on this screen only. It reads
"Close thread" because at this harness's width the thread docks beside its
parent, whose leading control is a close, not a back button
(`thread_deeplink_dock_test.dart`).

Docking is also why `L.THREAD_COMPOSER` and `L.THREAD_SEND` exist: the parent
channel's own composer and send button are still on screen beside the thread's,
so the thread's copies carry their own names ("Thread composer", "Send reply").
"""
import time

import e2e_input as I
import e2e_labels as L


def _open_from_menu(client, text):
    """Right-click the message and choose "Reply in thread"."""
    row = client.wait_for(text)
    I.right_click(client, row["x"], row["y"])
    client.click(L.REPLY_IN_THREAD, settle=2)
    client.wait_for(L.THREAD_HEADER)


def _pane_nodes(client, text):
    """Nodes naming `text` in the docked thread pane, top to bottom."""
    pane_left = client.wait_for(L.THREAD_HEADER)["x"] - 60
    hits = [n for n in client.nodes() if text in n["t"] and n["x"] > pane_left]
    return sorted(hits, key=lambda n: n["y"])


def open_reply_and_stay_off_the_rail(sender, receiver, channel, admin_api,
                                      member_api):
    stamp = str(int(time.time()))
    root_text = f"a thread root {stamp}"
    thread_text = f"a reply inside the thread {stamp}"
    api = admin_api

    for c in (sender, receiver):
        c.click(channel)
        c.wait_for(L.COMPOSER)
    sender.type_into(L.COMPOSER, root_text)
    sender.click(L.SEND, settle=2)
    receiver.wait_for(root_text)

    channel_id = api.channel_named(channel)['id']
    root = api.message_with(channel_id, root_text)
    _open_from_menu(sender, root_text)
    thread = next(t for t in api.call('GET', f'/channels/{channel_id}/threads')
                  if t['parent_message_id'] == root['id'])
    thread_id = thread['id']
    print(f'  a thread was opened on the root message: {thread_id}')

    assert L.THREAD_COMPOSER in (I.focused_label(sender) or ''), \
        f"opening the thread did not focus its composer: " \
        f"{I.focused_label(sender)!r}"
    print('  the docked pane focused its own composer on open')

    for who, caller in (('the admin', admin_api), ('the member', member_api)):
        listed = {ch['id'] for ch in caller.channels()}
        assert thread_id not in listed, \
            f"the thread channel showed up in {who}'s channel list"
    print("  and it does not appear in either account's ordinary channel list")

    _open_from_menu(receiver, root_text)
    print('  the other client opened the same thread from its own menu')

    # Back in by a pasted link: docked mid-navigation, this composer once took text and sent nothing.
    sender.click(L.THREAD_HEADER, settle=1.5)
    sender.ev(f"location.hash = '#/thread/{thread_id}'")
    sender.wait_for(L.THREAD_HEADER)
    sender.wait_for(L.THREAD_COMPOSER)
    time.sleep(2)
    print('  the sender closed the thread and came back to it by a link')
    sender.type_into(L.THREAD_COMPOSER, thread_text)
    sender.click(L.THREAD_SEND, settle=2)
    receiver.wait_for(thread_text, timeout=30)
    print('  a reply sent inside the thread reached the other client live')

    parent_y = _pane_nodes(sender, root_text)[0]['y']
    reply_y = _pane_nodes(sender, thread_text)[0]['y']
    assert parent_y < reply_y, \
        f"the parent is not the pane's first item: {parent_y} vs {reply_y}"
    sender.shot('thread-pane')
    print('  and the pane shows the parent message above its first reply')

    stored = api.messages(thread_id)
    assert any(thread_text in (m.get('content') or '') for m in stored), \
        'the server does not hold the reply inside the thread channel'

    # Closing the dock is what returns the receiver to a screen the next scenario can find a channel row on.
    receiver.click(L.THREAD_HEADER, settle=1.5)

    # A fresh reload is a real returning visit, and the only way a bystander learns the reply count.
    origin = sender.ev("location.origin")
    sender.go_away()
    sender.come_back(f"{origin}/#/channels")
    sender.click(channel)
    sender.wait_for(L.COMPOSER)
    row = sender.wait_for(root_text)
    deadline = time.time() + 30
    summary = None
    while summary is None and time.time() < deadline:
        below = [n for n in sender.nodes()
                 if 'open thread.' in n['t'].lower() and n['y'] >= row['y']]
        summary = min(below, key=lambda n: n['y']) if below else None
        time.sleep(1)
    assert summary, 'the parent message shows no reply-count affordance'
    assert '1 repl' in summary['t'].lower(), \
        f'the reply-count affordance does not read 1 reply: {summary["t"]!r}'
    sender.shot('thread-reply-count')
    print(f'  the parent message now shows the reply-count affordance: '
          f'{summary["t"]!r}')
