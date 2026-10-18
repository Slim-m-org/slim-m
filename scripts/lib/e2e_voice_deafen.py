# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Deafening silences what you hear and nothing of what you say.

Both halves are measured: bob's own probe must hear alice drop to silence and
return, and alice's must keep hearing bob throughout, because deafen is local
playback and independent of muting.
"""
import e2e_audio_levels as lv
import e2e_audio
import e2e_voice_ui as ui
from e2e_voice import join_call

MEASURE_SECONDS = 3
HEARD_ABOVE_DB = -45.0
SILENT_BELOW_DB = lv.SILENCE_DB


def _heard(probe, stream):
    series = probe.measure(stream, MEASURE_SECONDS)
    return (e2e_audio.speech_level(series, 1), lv.applied_gain_db(series))


def deafen_silences_playback_not_the_mic(a, b, room_id, alice_id, bob_id):
    with e2e_audio.installed(a), e2e_audio.installed(b):
        _deafen_silences_playback_not_the_mic(a, b, room_id, alice_id, bob_id)


def _deafen_silences_playback_not_the_mic(a, b, room_id, alice_id, bob_id):
    join_call(a, b, room_id)
    a_hears = e2e_audio.AudioProbe(a)
    b_hears = e2e_audio.AudioProbe(b)
    try:
        a_hears.wait_for_streams(1)
        b_hears.wait_for_streams(1)
        from_bob = ui.stream_for(a_hears, room_id, bob_id)
        from_alice = ui.stream_for(b_hears, room_id, alice_id)
        level, _ = _heard(b_hears, from_alice)
        print(f"  bob hears alice at {level:.1f} dB before deafening")
        assert level > HEARD_ABOVE_DB, f"bob never heard alice: {level}"

        b.click("Deafen", settle=2)
        level, _ = _heard(b_hears, from_alice)
        still, _ = _heard(a_hears, from_bob)
        print(f"  deafened: bob hears {level:.1f} dB, alice still hears bob at {still:.1f} dB")
        assert level <= SILENT_BELOW_DB, f"deafened bob still heard alice: {level:.1f} dB"
        assert still > HEARD_ABOVE_DB, \
            f"deafening bob also silenced his microphone: alice hears {still:.1f} dB"

        b.click("Undeafen", settle=2)
        level, _ = _heard(b_hears, from_alice)
        print(f"  undeafened: bob hears alice at {level:.1f} dB again")
        assert level > HEARD_ABOVE_DB, f"bob heard nothing after undeafening: {level}"
    finally:
        if b.find("Undeafen"):
            b.click("Undeafen", settle=1)
        ui.leave_if_in_call(a, b)
