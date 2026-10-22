# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Starting a DM from the member list, then holding a call inside it.

There is no "+" affordance on the DM rail section (deliberately not built,
per CLAUDE.md); the only way to start a fresh DM is "Message" on a member's
own profile popover, reached from the member pane. Once the DM exists, a
call inside it is the same `VoiceScreen` a real voice channel uses (PR #306),
reached through the DM header's own "Call" button rather than a rail row,
and published to LiveKit under `channel-<dmChannelId>` - the same
`room_for_channel` scheme every channel kind already shares - so this reuses
e2e_voice's SFU checks rather than duplicating them.

Bob reaches the DM by its channel id rather than by clicking its rail row:
once alice has opened it, "Bob"/"Alice" name both a member-pane row and a
Direct-messages rail row with the identical text, and this harness's click()
picks whichever tappable match sorts first - not something worth resting a
scenario on when the server can just be asked for the id it already knows.

Alice's own first click needs the identical care, for a reason worth writing
down: the API sweep (`e2e_sweep.py`) opens a DM with Bob from alice's own
account as a side effect of exercising the DMs route, and once anything
prompts alice's client to refresh its channel list - a voice call's join or
leave already does - that DM gets a rail row too, before this scenario ever
runs. From there, "Bob" starts matching a rail row as well as the member
pane's, and once alice is already sitting on that DM channel (whichever
"Bob" click landed on it), "Message" (meant for the profile popover's own
button) no longer matches anything on screen - except the header's pin icon,
whose label, "Pinned messages", contains "message" as a substring. That
opened the pinned-messages sheet over the composer instead of ever finding
one, which reads as a missing composer with no clue that a sheet is why.
Checking the API for what alice's own account already has sidesteps the
whole ambiguity rather than trying to out-guess it with a choosier label.

Run after the shared 'lounge' voice scenarios rather than beside them, so a
call already open in one room can never collide with the other.

L.DM_CALL joins directly now, the same as a voice channel row (PR #354
removed the join lobby both used), so the click below is the join itself;
see e2e_voice.join_call's own doc comment for the fuller reasoning.
"""
import time

import e2e_labels as L
from e2e_voice import participants_with_mics, sfu_participants, tracks_of


def start_dm_and_call(a, b, admin_api, member_api):
    """Alice starts a DM with Bob, then both hold and leave a call in it."""
    existing = next(
        (c for c in admin_api.call('GET', '/dms')
         if c['user']['display_name'] == 'Bob'), None)
    if existing:
        a.ev(f"location.hash = '#/channels/{existing['channel_id']}'")
        a.wait_for(L.COMPOSER)
        opened = 'reached the DM the API sweep already opened, by its id'
    else:
        a.click('Bob', settle=2)
        a.click(L.START_DM, settle=3)
        a.wait_for(L.COMPOSER)
        opened = 'opened a DM with bob from the member list'
    text = f'hello over a fresh dm {int(time.time())}'
    a.type_into(L.COMPOSER, text)
    a.click(L.SEND, settle=2)
    a.wait_for(text)
    print(f"  alice {opened} and sent a message")

    deadline = time.time() + 20
    conversation = None
    while time.time() < deadline and conversation is None:
        rows = member_api.call('GET', '/dms')
        conversation = next(
            (c for c in rows if c['user']['display_name'] == 'Alice'), None)
        if conversation is None:
            time.sleep(0.25)
    assert conversation, "bob's own /dms never listed the conversation alice opened"
    channel_id = conversation['channel_id']
    print(f"  bob's own account already lists the DM: {channel_id}")

    b.ev(f"location.hash = '#/channels/{channel_id}'")
    b.wait_for(text, timeout=30)
    print("  and the message alice sent is live in it")

    room_id = f'channel-{channel_id}'
    for c in (a, b):
        c.click(L.DM_CALL, settle=2)
        c.wait_for(L.IN_CALL)
    for c in (a, b):
        c.wait_for('2 in call')
    a.shot('dm-in-call')
    print("  both clients joined the DM's own call")

    parts = participants_with_mics(room_id)
    assert len(parts) == 2, f"the DM's SFU room has {len(parts)}, expected 2"
    for p in parts:
        mics = tracks_of(p, 'MICROPHONE')
        assert p['state'] == 'ACTIVE', f'{p["identity"]} is {p["state"]}'
        assert mics, f'{p["identity"]} published no microphone track'
    print("  and the SFU room named after this DM's channel id has both, ACTIVE")

    a.click(L.LEAVE_CALL, settle=8)
    b.wait_for('1 in call')
    b.shot('dm-peer-left')
    print("  leaving dropped the other side to 1 in call")


def a_missed_call_shows_up_in_the_dm(a, b, admin_api, member_api):
    """Alice rings, nobody answers, and the DM tells Bob he missed it.

    The case the whole call record exists for. Every part of ringing used to
    be ephemeral - the ring lives in the server's memory and the sweep tears
    it down after `RING_TIMEOUT` - so a call nobody answered left no trace
    anywhere, and the person who missed it never found out.

    Drives the *timeout* rather than a decline. Declining is a click and
    proves the record and its rendering in two seconds; letting the ring lapse
    is the only thing that exercises `sweep_stale_call_rings`, the write site
    with no request behind it and the one a person actually hits. That is what
    the long wait below buys.

    Alice rings through the API rather than by clicking her own call button.
    Two earlier drafts failed on her UI state rather than on the product:
    leaving a call leaves you on that call's recap pane, and a second click on
    the call button while that pane is open closes the pane instead of ringing
    (`dm_call_button.dart`'s `_toggle`). Her ringing is setup here; what is
    under test is what Bob's transcript says afterwards, so the setup should
    be the part that cannot wobble.

    Bob is asserted in the UI because Bob is the one who missed the call.
    Alice's own "No answer" wording is `call_record_view_test.dart`'s job,
    which can ask directly instead of steering her out of a call pane.
    """
    conversation = next(
        (c for c in member_api.call('GET', '/dms')
         if c['user']['display_name'] == 'Alice'), None)
    assert conversation, "the DM the earlier scenario opened is gone"
    channel_id = conversation['channel_id']

    def call_records():
        return [m for m in member_api.call(
            'GET', f'/channels/{channel_id}/messages') if m.get('call')]

    # Leaving lands on the call's recap pane, not on the transcript.
    b.click(L.LEAVE_CALL, settle=4)
    b.click(L.DM_CALL_BACK, settle=2)
    b.wait_for(L.COMPOSER)
    print('  bob is out of the call and back on the transcript')
    before = len(call_records())

    ring = admin_api.call('POST', f'/channels/{channel_id}/voice/ring')
    assert ring and ring.get('ring_id'), f'alice never got a ring started: {ring}'
    print(f"  alice is ringing bob, who is not going to answer "
          f"({ring['timeout_ms']}ms to go)")

    # RING_TIMEOUT is 30s and the sweep ticks every 2s; the rest is slack.
    b.wait_for(L.MISSED_CALL, timeout=75)
    b.shot('dm-missed-call')
    print("  bob's transcript shows the missed call")

    after = call_records()
    assert len(after) == before + 1, (
        f'expected one new call record, went from {before} to {len(after)}')
    # By seq: /messages answers newest-first, so [-1] is the oldest.
    record = max(after, key=lambda m: m['seq'])['call']
    assert record['outcome'] == 'timed_out', record
    assert record['duration_ms'] is None, (
        f'nothing lasted any time when nobody picked up: {record}')
    print(f"  and the server stored it as {record['outcome']}, past a reload")
