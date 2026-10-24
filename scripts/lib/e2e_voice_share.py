# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A shared screen's own volume, apart from the sharer's voice.

The sharer's capture is given a steady tone (e2e_audio_js.SHARE_TONE), because
a headless browser has no system audio to share. The viewer's probe then
measures the voice stream and the screen-audio stream separately: moving the
stream slider must scale only the screen, and the voice slider only the voice.
"""
import e2e_audio_levels as lv
import e2e_audio
import e2e_audio_js
import e2e_labels as L
import e2e_voice_ui as ui
from e2e_voice import join_call, sfu_participants, tracks_of
import time

from e2e_voice_volume import loudest_output

VOICE_LABEL = "Volume for you"
SCREEN_LABEL = "Stream volume"
MEASURE_SECONDS = 3
MEASURE_TRIES = 3
TOLERANCE_DB = 1.5


def _heard(probe, stream):
    """(applied gain dB, loudest output dB while the source was audible).

    A window can land on a quiet stretch of the shared clip, so a few are tried before calling it silent.
    """
    for _ in range(MEASURE_TRIES):
        series = probe.measure(stream, MEASURE_SECONDS)
        gain = lv.applied_gain_db(series)
        if gain is not None:
            return gain, e2e_audio.heard_while_audible(series)
    raise AssertionError("the stream never became audible to measure against")


_AUDIO_KEY = "flutter.slimm.voice.screen_share_include_audio"
_AUDIO_TOGGLE = "Share audio with a screen share"


def _stored_include_audio(client):
    return client.ev(f"JSON.parse(localStorage.getItem('{_AUDIO_KEY}') || 'false')")


def _share_audio_setting(client, want):
    """Turn "Share audio with a screen share" on or off in Voice settings.

    It is off by default, so a share carries no sound until someone asks for it.
    """
    if _stored_include_audio(client) == want:
        return
    client.click(L.PERSONAL_SETTINGS, settle=3)
    client.click(L.VOICE_PANE, settle=2)
    client.wheel_until("Microphone", _AUDIO_TOGGLE)
    client.click(_AUDIO_TOGGLE, settle=1.5)
    assert _stored_include_audio(client) == want, \
        f"the share-audio toggle never reached storage: {_stored_include_audio(client)}"
    client.click(L.BACK_TO_CHANNELS, settle=2)


def _wait_for_share_audio(room_id, bob_id, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        for p in sfu_participants(room_id):
            if p["identity"] == bob_id and tracks_of(p, "SCREEN_SHARE_AUDIO"):
                return
        time.sleep(0.25)
    raise AssertionError("the share's audio never reached the SFU")


def stream_volume_is_apart_from_the_voice(a, b, room_id, bob_id):
    with e2e_audio.installed(a), e2e_audio.installed(b, extra=e2e_audio_js.SHARE_TONE):
        _stream_volume_is_apart_from_the_voice(a, b, room_id, bob_id)


def _stream_volume_is_apart_from_the_voice(a, b, room_id, bob_id):
    _share_audio_setting(b, True)
    join_call(a, b, room_id)
    probe = e2e_audio.AudioProbe(a)
    try:
        voice = ui.stream_for(probe, room_id, bob_id)
        b.click(L.SHARE_SCREEN, settle=6)
        _wait_for_share_audio(room_id, bob_id)
        screen = ui.stream_for(probe, room_id, bob_id, source="SCREEN_SHARE_AUDIO")
        tone = e2e_audio.speech_level(probe.measure(screen, 3), 2)
        print(f"  bob's share carries audio, heard before any gain at {tone:.1f} dB")
        assert tone > -45, f"the share's audio is silent: {tone:.1f} dB"
        assert abs(_heard(probe, screen)[0]) <= TOLERANCE_DB

        ui.open_share_menu(a, "Bob's screen", SCREEN_LABEL)
        shown = ui.set_slider(a, SCREEN_LABEL, 50)
        ui.dismiss_popover(a)
        want = lv.volume_to_db(lv.slider_to_gain(shown / 100))
        screen_gain, _ = _heard(probe, screen)
        voice_gain, voice_loudest = _heard(probe, voice)
        print(f"  stream volume {shown}%: screen {screen_gain:.1f} dB "
              f"(expected {want:.1f}), voice {voice_gain:.1f} dB")
        assert abs(screen_gain - want) <= TOLERANCE_DB, \
            f"the stream slider at {shown}% moved the screen by {screen_gain:.1f} dB"
        assert abs(voice_gain) <= TOLERANCE_DB, \
            f"the stream slider also moved the voice: {voice_gain:.1f} dB"

        ui.open_volume_popover(a, "Bob")
        ui.set_slider(a, VOICE_LABEL, 0)
        ui.dismiss_popover(a)
        screen_gain, _ = _heard(probe, screen)
        voice_loudest = loudest_output(probe, voice)
        print(f"  voice at 0%: voice loudest {voice_loudest:.1f} dB, "
              f"screen still {screen_gain:.1f} dB")
        assert voice_loudest <= lv.SILENCE_DB, \
            f"the voice still leaked {voice_loudest:.1f} dB"
        assert abs(screen_gain - want) <= TOLERANCE_DB, \
            f"silencing the voice moved the screen to {screen_gain:.1f} dB"
    finally:
        ui.reset_volumes(a, "Bob", [VOICE_LABEL])
        ui.reset_share_volume(a, "Bob's screen", SCREEN_LABEL)
        if b.find(L.STOP_SHARING):
            b.click(L.STOP_SHARING, settle=4)
        ui.leave_if_in_call(a, b)
        _share_audio_setting(b, False)
