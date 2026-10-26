# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A listener's per-person volume slider, judged by what comes out of the speaker.

The widget saying 50% proves nothing about sound. Alice's page carries an
in-page probe (e2e_audio_js.PROBE) that measures each remote stream after the
app's own gain graph, so the slider is checked against the level a listener
would hear: halving it should cost about 6 dB, zero should be silent, and the
choice should still be there after leaving and rejoining.
"""
import time

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
# The top of the slider, where the web soft limiter must keep +6 dB from clipping.
BOOST_PERCENT = 200
# Keys step 5%, so the full range takes up to 40 presses.
KEY_TRIES = 100


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


def _set_and_hear_silence(a, probe, stream):
    """Move to 0% and report the loudest output of every window afterwards.

    Exactly 0% also stops the SFU forwarding the track, so the source itself
    may go quiet and there is nothing left to compare against: the output must
    be silent in every window, audible source or not.
    """
    shown = ui.set_slider(a, LABEL, 0)
    ui.dismiss_popover(a)
    return shown, loudest_output(probe, stream)


def loudest_output(probe, stream):
    """The loudest output over a measuring window, whatever the source did in it."""
    series = probe.measure(stream, MEASURE_SECONDS)
    assert series, "the stream stopped being measured"
    return max(eff for _, eff, _ in series)


def individual_volume_scales_the_sound(a, b, room_id, bob_id):
    with e2e_audio.installed(a):
        _individual_volume_scales_the_sound(a, b, room_id, bob_id)


def _individual_volume_scales_the_sound(a, b, room_id, bob_id):
    join_call(a, b, room_id)
    probe = e2e_audio.AudioProbe(a)
    try:
        probe.wait_for_streams(1)
        stream = ui.stream_for(probe, room_id, bob_id)
        gain, loudest, source = _heard(probe, stream)
        print(f"  bob at 100%: gain {gain:.1f} dB on a {source:.1f} dB voice")
        assert abs(gain) <= TOLERANCE_DB, f"untouched volume changed the level: {gain}"

        ui.open_volume_popover(a, "Bob")
        shown, gain, loudest, voice_db = _set_and_hear(a, probe, stream, 50)
        want = lv.volume_to_db(lv.slider_to_gain(shown / 100))
        print(f"  bob at {shown}%: gain {gain:.1f} dB against {want:.1f} expected")
        assert abs(gain - want) <= TOLERANCE_DB, \
            f"{shown}% should be about {want:.1f} dB, measured {gain:.1f} dB"
        assert any(e["graph"] for e in probe.listening()), \
            "the app never put a gain graph on bob's stream"

        _assert_boost_does_not_clip(a, probe, stream)

        assert voice_db > AUDIBLE_SOURCE_DB, "nothing to silence: bob was not speaking"
        ui.open_volume_popover(a, "Bob")
        shown, loudest = _set_and_hear_silence(a, probe, stream)
        print(f"  bob at {shown}%: loudest output {loudest:.1f} dB on a "
              f"{voice_db:.1f} dB voice")
        assert loudest <= lv.SILENCE_DB, \
            f"0% still let the voice through: {loudest:.1f} dB"

        left_at = probe.now()
        _rejoin(a, probe, room_id)
        stream = ui.stream_for(probe, room_id, bob_id)
        _assert_silent_from_the_first_window(probe, stream, left_at)

        ui.open_volume_popover(a, "Bob")
        shown = ui.slider_percent(a, LABEL)
        assert shown == 0, f"the slider forgot the choice and shows {shown}%"
        shown, gain, loudest, source = _set_and_hear(a, probe, stream, 100)
        print(f"  back at {shown}%: gain {gain:.1f} dB")
        assert abs(gain) <= TOLERANCE_DB, f"100% should be untouched, got {gain:.1f} dB"
    finally:
        ui.reset_volumes(a, "Bob", [LABEL])
        ui.leave_if_in_call(a, b)


def _assert_boost_does_not_clip(a, probe, stream):
    """At the top of the slider the output must stay under full scale."""
    ui.open_volume_popover(a, "Bob")
    shown = ui.set_slider(a, LABEL, BOOST_PERCENT, tries=KEY_TRIES)
    ui.dismiss_popover(a)
    start = probe.now()
    series = probe.measure(stream, MEASURE_SECONDS)
    out_peak, source_peak = probe.peaks(stream, start)
    boost = lv.slider_to_gain(shown / 100)
    print(f"  bob at {shown}%: output peak {out_peak:.3f} on a source peak "
          f"{source_peak:.3f}, unlimited would be {source_peak * boost:.3f}")
    assert source_peak > 0.01, "nothing to boost: bob was not speaking"
    assert lv.boost_is_limited(out_peak), (
        f"{shown}% clipped: output peak {out_peak:.3f} from a source peak "
        f"{source_peak:.3f} (gain {boost:.1f}, {len(series)} windows)")
    ui.open_volume_popover(a, "Bob")
    ui.set_slider(a, LABEL, 50, tries=KEY_TRIES)
    ui.dismiss_popover(a)


def _after_the_last_gap(series, gap=0.5):
    """The windows of the rejoined stream: the sampler is silent while out of the call."""
    start = 0
    for i in range(1, len(series)):
        if series[i][0] - series[i - 1][0] > gap:
            start = i
    return series[start:]


def _assert_silent_from_the_first_window(probe, stream, since):
    """The saved 0% must hold from the first window the stream plays, not after a delay.

    Reads from `since` (before leaving), so the windows right after the rejoin
    count, not only those after the scenario got round to measuring.
    """
    time.sleep(MEASURE_SECONDS)
    series = probe.series(stream, since)
    series = _after_the_last_gap(series)
    assert series, "the rejoined stream was never measured"
    # A saved 0% also stops the SFU forwarding, so every window counts, not just audible ones.
    first = series[0][0]
    leaks = [(t - first, eff) for t, eff, _ in series if eff > lv.SILENCE_DB]
    held = any(e["stream"] == stream and e["graph"] for e in probe.listening())
    print(f"  after rejoining: {len(series)} windows, gain graph {held}, "
          f"{len(leaks)} let sound through"
          + "".join(f" +{t:.2f}s:{e:.0f}dB" for t, e in leaks[:8]))
    assert held, "the rejoined stream was never put behind the saved gain"
    assert not leaks, (
        f"the 0% choice did not survive rejoining: {len(leaks)} of "
        f"{len(series)} windows leaked, first at +{leaks[0][0]:.2f}s "
        f"into the stream at {leaks[0][1]:.1f} dB, loudest "
        f"{max(e for _, e in leaks):.1f} dB")


def _rejoin(a, probe, room_id):
    ui.leave_if_in_call(a)
    _click_channel_row(a, L.VOICE_CHANNEL)
    probe.wait_for_streams(1)
    assert len(sfu_participants(room_id)) == 2, "alice did not rejoin the call"
