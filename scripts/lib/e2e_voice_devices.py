# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Picking a microphone, mid-call, and the peer still hearing it.

Chrome's fake media exposes three audio inputs, so a choice is observable: the
published track's own deviceId and label (read off the RTCPeerConnection's
sender, not the settings screen) must change, and the listener's in-page probe
must never lose the voice for longer than a short gap while it does.
"""
import time

import e2e_audio_levels as lv
import e2e_audio
import e2e_labels as L
import e2e_voice_ui as ui
from e2e_voice import join_call
from e2e_voice_rejoin import _click_channel_row

MIC_ROW = "Microphone, currently"
DEFAULT_MIC = "System default"
# Reopening a capture is not instant; a second of silence is a lost word, more is a dropout.
MAX_GAP_SECONDS = 1.5
# Below this, against the unswitched voice, a window counts as the voice being gone.
GONE_BELOW_BASE_DB = 25.0
# A lost voice that never returns is a failure, not an unbounded wait.
RECOVER_TIMEOUT_SECONDS = 30


def _audio_sender(client):
    senders = [s for s in e2e_audio.AudioProbe(client).senders()
               if s["kind"] == "audio" and s["state"] == "live"]
    assert senders, f"{client.name}: no live audio sender"
    return senders[0]


def _wait_for_device(client, differs_from, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        sender = _audio_sender(client)
        if sender["settings"]["deviceId"] != differs_from:
            return sender
        time.sleep(0.5)
    raise AssertionError(
        f"{client.name}: the published track stayed on {differs_from!r}")


def _gap_until_audio_is_back(listener, stream, start, loud_db):
    """Read one continuous series from `start` until the voice is loud again.

    Returns the longest silence in it, trailing silence included, so a dropout
    longer than any single read still shows up as the gap.
    """
    deadline = time.time() + RECOVER_TIMEOUT_SECONDS
    while True:
        series = [(t, eff) for t, eff, _ in listener.series(stream, start)]
        recent = [lvl for t, lvl in series if t >= series[-1][0] - 1.0] if series else []
        if recent and max(recent) >= loud_db:
            return lv.longest_gap_seconds(series, loud_db, until=series[-1][0]), series
        if time.time() > deadline:
            gap = lv.longest_gap_seconds(series, loud_db, until=series[-1][0]) if series else 0
            raise AssertionError(
                f"the peer never heard bob again after the switch "
                f"(longest silence {gap:.1f}s within {RECOVER_TIMEOUT_SECONDS}s)")
        time.sleep(0.5)


def _wait_for_sender(client, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            return _audio_sender(client)
        except AssertionError:
            time.sleep(0.5)
    raise AssertionError(f"{client.name}: no live audio sender after rejoining")


def _rejoin(client):
    ui.leave_if_in_call(client)
    _click_channel_row(client, L.VOICE_CHANNEL)


def _pick_microphone(client, choice):
    if not client.find(MIC_ROW):
        client.click(L.PERSONAL_SETTINGS, settle=3)
        client.click(L.VOICE_PANE, settle=2)
    client.wheel_until("Microphone", MIC_ROW)
    client.click(MIC_ROW, settle=1.5)
    client.click(choice, settle=2)


def _back_to_call(client):
    client.click(L.BACK_TO_CHANNELS, settle=2)


def mic_choice_changes_the_published_track(a, b, room_id, bob_id):
    with e2e_audio.installed(a), e2e_audio.installed(b):
        _mic_choice_changes_the_published_track(a, b, room_id, bob_id)


def _mic_choice_changes_the_published_track(a, b, room_id, bob_id):
    join_call(a, b, room_id)
    listener = e2e_audio.AudioProbe(a)
    try:
        listener.wait_for_streams(1)
        stream = ui.stream_for(listener, room_id, bob_id)
        before = _audio_sender(b)
        base = e2e_audio.speech_level(listener.measure(stream, 4))
        print(f"  bob publishes {before['label']!r} "
              f"({before['settings']['deviceId'][:10]}), heard at {base:.1f} dB")
        assert base > -45, f"the peer hears nothing from the default mic: {base}"

        start = listener.now()
        _pick_microphone(b, "Fake Audio Input 1")
        after = _wait_for_device(b, before["settings"]["deviceId"])
        print(f"  bob switched mid-call to {after['label']!r} "
              f"({after['settings']['deviceId'][:10]})")
        assert after["label"] != before["label"], after
        loud = base - GONE_BELOW_BASE_DB
        gap, _ = _gap_until_audio_is_back(listener, stream, start, loud)
        tail = e2e_audio.speech_level(listener.measure(stream, 4))
        print(f"  the peer's longest silence across the switch: {gap:.2f}s; "
              f"heard afterwards at {tail:.1f} dB")
        assert gap <= MAX_GAP_SECONDS, \
            f"the peer lost bob for {gap:.2f}s while he switched microphones"
        assert tail > base - 10, \
            f"audio did not come back after the switch: {tail:.1f} against {base:.1f}"

        _back_to_call(b)
        _rejoin(b)
        again = _wait_for_sender(b)
        print(f"  after leaving and rejoining bob still publishes "
              f"{again['label']!r}")
        assert again["settings"]["deviceId"] == after["settings"]["deviceId"], \
            f"the chosen microphone was forgotten on rejoin: {again['label']!r}"

        _pick_microphone(b, DEFAULT_MIC)
        restored = _wait_for_device(b, after["settings"]["deviceId"])
        assert restored["settings"]["deviceId"] == "default", restored
        print("  and back to the system default")
        _back_to_call(b)
    finally:
        ui.leave_if_in_call(a, b)
