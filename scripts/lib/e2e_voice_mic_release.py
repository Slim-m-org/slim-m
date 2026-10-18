# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Muting hands the capture device back after a grace period, and unmuting
inside it costs nothing.

Measured on the page: the microphone track's `readyState` stays live through
the grace period, goes to ended after it, and a later unmute opens a fresh one
that the other side hears.
"""
import time

import e2e_audio
import e2e_labels as L
import e2e_voice_ui as ui
from e2e_voice import join_call

# kMicReleaseGrace in rtc/lib/src/mic_release.dart, plus slack for the timer.
GRACE_SECONDS = 15
RELEASE_WITHIN = GRACE_SECONDS + 6
HEARD_BYTES = 800


def _mic_state(probe):
    """The first audio sender's `(readyState, enabled)`, or None without one."""
    for sender in probe.senders():
        if sender["kind"] == "audio":
            return sender["state"], sender["enabled"]
    return None


def _wait_state(probe, state, timeout):
    started = time.monotonic()
    while time.monotonic() - started < timeout:
        if (_mic_state(probe) or ("", False))[0] == state:
            return time.monotonic() - started
        time.sleep(0.1)
    raise AssertionError(f"mic track never became {state}: {_mic_state(probe)}")


def muting_releases_the_capture_after_the_grace(a, b, room_id):
    with e2e_audio.installed(a), e2e_audio.installed(b):
        _muting_releases_the_capture_after_the_grace(a, b, room_id)


def _muting_releases_the_capture_after_the_grace(a, b, room_id):
    join_call(a, b, room_id)
    bob = e2e_audio.AudioProbe(b)
    alice = e2e_audio.AudioProbe(a)
    try:
        assert _mic_state(bob) == ("live", True), _mic_state(bob)

        b.click(L.MUTE, settle=1)
        state = _mic_state(bob)
        print(f"  muted: mic track is {state}")
        assert state == ("live", False), "the capture should still be open inside the grace"

        before = len(bob.getusermedia_calls())
        time.sleep(3)
        b.click(L.UNMUTE, settle=1)
        assert len(bob.getusermedia_calls()) == before, "an early unmute reopened the device"
        assert _mic_state(bob) == ("live", True), _mic_state(bob)
        print("  unmuted inside the grace: no reopen, track live")

        b.click(L.MUTE, settle=0)
        waited = _wait_state(bob, "ended", RELEASE_WITHIN)
        print(f"  muted: mic track ended {waited:.1f} s later")

        b.wait_for(L.UNMUTE)
        heard_before = alice.inbound()[0]
        started = time.monotonic()
        b.click(L.UNMUTE, settle=0)
        _wait_state(bob, "live", 10)
        live_ms = (time.monotonic() - started) * 1000
        while alice.inbound()[0] - heard_before < HEARD_BYTES:
            assert time.monotonic() - started < 10, "alice never heard bob after the reopen"
            time.sleep(0.02)
        heard_ms = (time.monotonic() - started) * 1000
        print(f"  unmuted after the release: track live in {live_ms:.0f} ms, "
              f"alice hears it {heard_ms:.0f} ms after the click")
        assert len(bob.getusermedia_calls()) > before, "the release never reopened the device"
    finally:
        if b.find(L.UNMUTE):
            b.click(L.UNMUTE, settle=1)
        ui.leave_if_in_call(a, b)
