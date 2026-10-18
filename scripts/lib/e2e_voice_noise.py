# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Mic noise suppression, measured at the listener rather than read off a toggle.

Two senders capture the same speech-over-steady-noise WAV and join a call that
alice listens to. One is the app untouched; the other has only the browser's
noise suppression refused (e2e_audio_js.RAW_CAPTURE), so everything else on
the path, including auto gain, is identical. Alice's in-page analyser then
measures what each sender sounds like after the SFU.

The web client has the browser's suppression only: the rnnoise "Strong" mode
is a native desktop capture chain and is measured separately.

The thresholds carry the numbers they were set from, beside them below.
"""
import os
import time

import e2e_audio_levels as lv
import e2e_audio
import e2e_audio_js
import e2e_browsers
import e2e_labels as L
import e2e_voice_ui as ui
import make_noisy_voice
from e2e_voice import _tap_label

NOISE_REDUCTION_MIN_DB = 10.0  # measured 18.5 dB: raw floor -34.0, app -52.5
SPEECH_LOSS_MAX_DB = 3.0  # measured 1.2 dB: raw speech -14.4, app -15.5
MEASURE_SECONDS = 12
# Speech must sit this far over the floor for either arm's numbers to mean anything.
MIN_SEPARATION_DB = 6.0


def fixture_path():
    work = os.environ.get("E2E_WORK", "/tmp/e2e")
    path = os.path.join(work, "noisy-voice.wav")
    make_noisy_voice.write(path)
    return path


def _join(sender, channel=L.VOICE_CHANNEL):
    e2e_browsers.dismiss_welcome(sender)
    sender.click(channel)
    sender.wait_for(L.IN_CALL)


def suppression_quiets_the_noise_floor(listener, server, secret, admin_api,
                                       sign_in, room_id):
    path = fixture_path()
    for user in ("noisy", "rawmic"):
        e2e_browsers.register(server, admin_api, user, secret)
    ids = {}
    from e2e_api import Api
    for user in ("noisy", "rawmic"):
        api = Api(server)
        api.login(user, secret, device="e2e-noise")
        ids[user] = api.me()["id"]

    with e2e_audio.installed(listener), \
            e2e_browsers.browser("noisy", path) as on, \
            e2e_browsers.browser("raw", path) as off:
        e2e_audio.install(on)
        e2e_audio.install(off, extra=e2e_audio_js.RAW_CAPTURE)
        sign_in(on, server, "noisy", secret)
        sign_in(off, server, "rawmic", secret)
        try:
            listener.click(L.VOICE_CHANNEL)
            listener.wait_for(L.IN_CALL)
            _join(on)
            _join(off)
            probe = e2e_audio.AudioProbe(listener)
            probe.wait_for_streams(2)
            on_stream = ui.stream_for(probe, room_id, ids["noisy"])
            off_stream = ui.stream_for(probe, room_id, ids["rawmic"])
            on_ns = [s["settings"].get("noiseSuppression")
                     for s in e2e_audio.AudioProbe(on).senders()
                     if s["kind"] == "audio"]
            off_ns = [s["settings"].get("noiseSuppression")
                      for s in e2e_audio.AudioProbe(off).senders()
                      if s["kind"] == "audio"]
            print(f"  published noiseSuppression: app={on_ns} control={off_ns}")
            assert on_ns and all(on_ns), \
                f"the app did not ask the browser for noise suppression: {on_ns}"
            assert off_ns and not any(off_ns), \
                f"the control arm still had suppression on: {off_ns}"

            start = probe.now()
            time.sleep(MEASURE_SECONDS)
            on_series = probe.series(on_stream, start)
            off_series = probe.series(off_stream, start)
            on_floor, on_speech = lv.floor_and_speech(
                [s[1] for s in on_series])
            off_floor, off_speech = lv.floor_and_speech(
                [s[1] for s in off_series])
            reduction = lv.noise_reduction_db(off_floor, on_floor)
            loss = lv.speech_loss_db(off_speech, on_speech)
            print(f"  raw    floor {off_floor:6.1f} dB  speech {off_speech:6.1f} dB")
            print(f"  app    floor {on_floor:6.1f} dB  speech {on_speech:6.1f} dB")
            print(f"  noise floor {reduction:.1f} dB quieter with suppression; "
                  f"speech {loss:.1f} dB quieter")
            assert off_speech - off_floor > MIN_SEPARATION_DB, \
                "the control arm never separated speech from noise: nothing to compare"
            assert on_speech - on_floor > MIN_SEPARATION_DB, \
                f"the app arm lost its speech under the floor: " \
                f"{on_speech - on_floor:.1f} dB apart"
            assert reduction >= NOISE_REDUCTION_MIN_DB, \
                f"suppression only took {reduction:.1f} dB off the noise floor"
            assert loss <= SPEECH_LOSS_MAX_DB, \
                f"suppression cost the speech {loss:.1f} dB"
        finally:
            for c in (listener, on, off):
                if c.find(L.LEAVE_CALL):
                    _tap_label(c, L.LEAVE_CALL, settle=3)
