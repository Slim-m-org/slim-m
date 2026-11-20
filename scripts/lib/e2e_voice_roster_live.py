# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Someone joining or leaving a call shows on every screen within a second.

Alice sits in the call and carol watches the rail from a text channel. Bob
joins and leaves twice, with his microphone on and then muted; alice's stage,
alice's rail and carol's rail must each follow him within SHOWN_WITHIN_SECONDS
of the SFU. Muted is the case that failed: LiveKit batches a participant who
publishes nothing for up to 3 s (docs/decisions/0032-voice-participant-webhooks.md).
"""
import os
import re
import time

import e2e_audio
import e2e_browsers
import e2e_labels as L
from e2e_voice import (_click_channel_row, _tap_label, channel_row_point,
                       sfu_participants)

SHOWN_WITHIN_SECONDS = 1.5
# Past the 60 s backstop poll, so a missed nudge still shows up as a number.
GIVE_UP_SECONDS = 75
RAIL_HANDLE = "Narrow channel list"
JOIN_MUTED = "Join the call muted"
# What only a call tile says after a name (call_participant_tiles.dart).
TILE_WORDS = re.compile(r", (microphone on|muted)\b")
SAMPLE_SECONDS = 0.05


def _rail_edge(nodes):
    """The x of the rail's resize handle, so a stage or member-list row is never read as the rail."""
    return next((n["x"] for n in nodes if n["t"] == RAIL_HANDLE), 0)


def _channel_row_y(nodes, edge):
    """The y of the voice channel's own rail row, or None while the rail has not drawn it."""
    wanted = L.VOICE_CHANNEL.lower()
    return next((n["y"] for n in nodes if n["x"] < edge and n["t"].lower().startswith(wanted)), None)


def _named(client, name, rail):
    """Whether `name` has a rail row under the voice channel (rail True) or a call tile (rail False)."""
    wanted = name.lower()
    nodes = client.nodes()
    edge = _rail_edge(nodes)
    # Below the channel's row only: a DM with the same person is a rail row named "Bob" too, above it.
    below = _channel_row_y(nodes, edge)
    for n in nodes:
        # A rail row reads "Bob\nBob" (avatar, then name); a tile "Bob, microphone on".
        for line in n["t"].lower().split("\n"):
            if rail and line == wanted and n["x"] < edge and below is not None and n["y"] > below:
                return True
            if not rail and line.startswith(wanted + ", ") and TILE_WORDS.search(line):
                return True
    return False


def _wait_named(client, name):
    deadline = time.time() + GIVE_UP_SECONDS
    while not _named(client, name, rail=True):
        if time.time() > deadline:
            client.shot(f"no-{name.lower()}-in-rail")
            nodes = client.nodes()
            rail = [n["t"] for n in nodes if n["x"] < _rail_edge(nodes)]
            raise AssertionError(f"{client.name}: {name} never showed in the rail: {rail}")
        time.sleep(0.25)


def _sfu_has(room_id, identity):
    return any(p.get("identity") == identity for p in sfu_participants(room_id))


def _watch(room_id, identity, present, probes):
    """Seconds from the SFU's own change to each probe agreeing with it, or None past GIVE_UP_SECONDS."""
    start = time.time()
    sfu_at = None
    seen = {}
    while time.time() - start < GIVE_UP_SECONDS:
        now = time.time()
        if sfu_at is None and _sfu_has(room_id, identity) == present:
            sfu_at = now
        for label, check in probes.items():
            if label not in seen and check() == present:
                seen[label] = now
        if sfu_at is not None and len(seen) == len(probes):
            break
        time.sleep(SAMPLE_SECONDS)
    assert sfu_at is not None, f"the SFU never {'listed' if present else 'dropped'} {identity}"
    return {label: (round(seen[label] - sfu_at, 2) if label in seen else None)
            for label in probes}


def _report(what, lags):
    late = []
    for label, lag in lags.items():
        shown = "never" if lag is None else f"{lag:+.2f} s"
        print(f"  {what}: {label} {shown} after the SFU")
        if lag is None or lag > SHOWN_WITHIN_SECONDS:
            late.append(f"{label} ({shown})")
    return late


def a_join_shows_everywhere_at_once(a, b, server, secret, admin_api, sign_in,
                                    room_id, bob_id):
    e2e_browsers.register(server, admin_api, "carol", secret)
    wav = os.path.join(e2e_browsers.work_dir(), "fake-voice.wav")
    channel = f"/channels/{room_id.removeprefix('channel-')}"
    with e2e_audio.installed(a), e2e_audio.installed(b), \
            e2e_browsers.browser("carol", wav) as c:
        sign_in(c, server, "carol", secret)
        e2e_browsers.dismiss_welcome(c)
        try:
            _measure(a, b, c, room_id, bob_id, lambda muted: admin_api.call(
                "PATCH", channel, {"join_muted": muted}))
        finally:
            admin_api.call("PATCH", channel, {"join_muted": False})


def _join_after_return(b):
    """Back within VoiceState.rejoinGuardWindow of leaving, the page offers Rejoin; later, it joins on arrival."""
    deadline = time.time() + GIVE_UP_SECONDS
    while time.time() < deadline:
        if b.find(L.IN_CALL):
            return
        if b.find(JOIN_MUTED):
            _tap_label(b, JOIN_MUTED, settle=0)
            return
        time.sleep(SAMPLE_SECONDS)
    b.shot("never-joined-muted")
    raise AssertionError(f"bob neither joined nor saw {JOIN_MUTED!r}")


def _measure(a, b, c, room_id, bob_id, join_muted):
    _click_channel_row(a, L.VOICE_CHANNEL)
    a.wait_for(L.IN_CALL)
    _wait_named(c, "Alice")
    probes = {
        "alice's stage": lambda: _named(a, "Bob", rail=False),
        "alice's rail": lambda: _named(a, "Bob", rail=True),
        "carol's rail": lambda: _named(c, "Bob", rail=True),
    }
    late = []
    # Muted, bob publishes nothing, which is what the SFU holds back.
    for how, muted in (("with the microphone on", False), ("muted", True)):
        join_muted(muted)
        # Off the channel just left, whose row would only reselect it.
        b.click(L.TEXT_CHANNEL, settle=1)
        b.tap(*channel_row_point(b, L.VOICE_CHANNEL))
        if muted:
            _join_after_return(b)
        late += _report(f"join {how}", _watch(room_id, bob_id, True, probes))
        b.wait_for(L.IN_CALL)
        _tap_label(b, L.LEAVE_CALL, settle=0)
        late += _report(f"leave {how}", _watch(room_id, bob_id, False, probes))
    _tap_label(a, L.LEAVE_CALL, settle=2)
    assert not late, f"shown later than {SHOWN_WITHIN_SECONDS} s: {', '.join(late)}"
