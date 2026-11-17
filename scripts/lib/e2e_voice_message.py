# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A voice message recorded in the composer reaches the other member and plays.

Alice records from the browser's fake microphone, which feeds the run's
speech WAV, so the stored waveform must show speech rather than a flat line.
Bob plays it from his own row, and his page has to advance through the bytes.
A recording thrown away with Discard must never reach the channel.
"""
import json
import time

import e2e_labels as L
from e2e_soundboard import _SPY

RECORD_SECONDS = 3
PLAY_TIMEOUT = 10.0

_PLAYED = "JSON.stringify(window.__clipPlays || [])"


def _voice_messages(api, channel_id):
    return [(m, a) for m in api.messages(channel_id)
            for a in (m.get("attachments") or []) if a.get("voice")]


def _new_voice(api, channel_id, seen):
    return [a for _, a in _voice_messages(api, channel_id) if a["id"] not in seen]


def _levels(waveform):
    return list(bytes.fromhex(waveform)) if isinstance(waveform, str) else list(waveform)


def _record(client, seconds):
    client.wait_for("Record a voice message")
    time.sleep(0.8)
    client.click("Record a voice message", settle=0.5)
    client.wait_for("Send voice message")
    time.sleep(seconds)


def recorded_message_reaches_the_channel_and_plays(a, b, channel, admin):
    channel_id = admin.channel_named(channel)["id"]
    a.click(channel)
    b.click(channel)
    before = {a["id"] for _, a in _voice_messages(admin, channel_id)}

    _record(a, 1.5)
    a.click("Discard voice message", settle=1.5)
    a.wait_for("Record a voice message")
    assert not _new_voice(admin, channel_id, before), "a discarded recording was sent"
    print("  a discarded recording never reaches the channel")

    _record(a, RECORD_SECONDS)
    a.click("Send voice message", settle=3)
    deadline = time.monotonic() + 15
    while not _new_voice(admin, channel_id, before):
        assert time.monotonic() < deadline, "the voice message never arrived"
        time.sleep(0.5)
    (voice,) = _new_voice(admin, channel_id, before)
    levels = _levels(voice["waveform"])
    assert len(levels) == 64 and max(levels) - min(levels) > 16, \
        f"the waveform does not look like speech: {levels}"
    seconds = voice["duration_ms"] / 1000
    assert RECORD_SECONDS - 0.5 <= seconds <= RECORD_SECONDS + 3, voice
    assert voice["content_type"].startswith("audio/"), voice
    a.shot("voice-message-sent")
    print(f"  alice sent a {seconds:.1f} s voice message as {voice['content_type']}")

    assert b.ev(_SPY)
    play = b.wait_for("Play", exact=True)
    b.shot("voice-message-received")
    b.tap(play["x"], play["y"])
    deadline = time.monotonic() + PLAY_TIMEOUT
    while True:
        played = json.loads(b.ev(_PLAYED) or "[]")
        if played and played[-1]["advanced"]:
            break
        assert time.monotonic() < deadline, f"bob's player never advanced: {played}"
        time.sleep(0.3)
    assert not played[-1]["muted"], played
    b.shot("voice-message-playing")
    print("  bob played it from his row and his browser advanced through it")
    pause = b.wait_for("Pause", exact=True)
    b.tap(pause["x"], pause["y"])
    if channel != L.TEXT_CHANNEL:
        a.click(L.TEXT_CHANNEL)
