# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A listener's per-person volume slider, judged by what comes out of the speaker.

The widget saying 50% proves nothing about sound. Alice's page carries an
in-page probe (e2e_audio_js.PROBE) that measures each remote stream after the
app's own gain graph, so the slider is checked against the level a listener
would hear: halving it should cost about 6 dB, zero should be silent, and the
choice should still be there after leaving and rejoining.
"""
import e2e_audio_levels as lv
import e2e_audio
import e2e_labels as L
import e2e_voice_ui as ui
from e2e_voice import join_call, sfu_participants
from e2e_voice_rejoin import _click_channel_row

LABEL = "Volume for you"
MEASURE_SECONDS = 3
# How far the heard gain may sit from the slider's: speech jitter between two analysers.
TOLERANCE_DB = 1.5
# The source must be this loud before a "silent" result means anything.
AUDIBLE_SOURCE_DB = -45.0


def _heard(probe, stream):
    """(applied gain dB, loudest output dB while audible, source speech dB)."""
    series = probe.measure(stream, MEASURE_SECONDS)
    gain = lv.applied_gain_db(series)
    assert gain is not None, "the source never became audible to measure against"
    return gain, e2e_audio.heard_while_audible(series), e2e_audio.speech_level(series, 2)


def _set_and_hear(a, probe, stream, percent):
    shown = ui.set_slider(a, LABEL, percent)
    ui.dismiss_popover(a)
    return (shown,) + _heard(probe, stream)


def individual_volume_scales_the_sound(a, b, room_id, bob_id):
    e2e_audio.install(a)
    join_call(a, b, room_id)
    probe = e2e_audio.AudioProbe(a)
    try:
        probe.wait_for_streams(1)
        stream = ui.stream_for(probe, room_id, bob_id)
        gain, loudest, source = _heard(probe, stream)
        print(f"  bob at 100%: gain {gain:.1f} dB on a {source:.1f} dB voice")
        assert abs(gain) <= TOLERANCE_DB, f"untouched volume changed the level: {gain}"

        ui.open_volume_popover(a, "Bob")
        shown, gain, loudest, source = _set_and_hear(a, probe, stream, 50)
        want = lv.volume_to_db(shown / 100)
        print(f"  bob at {shown}%: gain {gain:.1f} dB against {want:.1f} expected")
        assert abs(gain - want) <= TOLERANCE_DB, \
            f"{shown}% should be about {want:.1f} dB, measured {gain:.1f} dB"
        assert any(e["graph"] for e in probe.listening()), \
            "the app never put a gain graph on bob's stream"

        ui.open_volume_popover(a, "Bob")
        shown, gain, loudest, source = _set_and_hear(a, probe, stream, 0)
        print(f"  bob at {shown}%: gain {gain:.1f} dB on a {source:.1f} dB voice")
        assert source > AUDIBLE_SOURCE_DB, "nothing to silence: bob was not speaking"
        assert loudest <= lv.SILENCE_DB, \
            f"0% still let the voice through: {loudest:.1f} dB"

        _rejoin(a, probe, room_id)
        stream = ui.stream_for(probe, room_id, bob_id)
        gain, loudest, source = _heard(probe, stream)
        print(f"  after rejoining: gain {gain:.1f} dB on a {source:.1f} dB voice")
        assert loudest <= lv.SILENCE_DB, \
            f"the 0% choice did not survive rejoining: {loudest:.1f} dB leaked"

        ui.open_volume_popover(a, "Bob")
        shown = ui.slider_percent(a, LABEL)
        assert shown == 0, f"the slider forgot the choice and shows {shown}%"
        shown, gain, loudest, source = _set_and_hear(a, probe, stream, 100)
        print(f"  back at {shown}%: gain {gain:.1f} dB")
        assert abs(gain) <= TOLERANCE_DB, f"100% should be untouched, got {gain:.1f} dB"
    finally:
        ui.reset_volumes(a, "Bob", [LABEL])
        ui.leave_if_in_call(a, b)


def _rejoin(a, probe, room_id):
    ui.leave_if_in_call(a)
    _click_channel_row(a, L.VOICE_CHANNEL)
    probe.wait_for_streams(1)
    assert len(sfu_participants(room_id)) == 2, "alice did not rejoin the call"
