# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Strong and the input gate in the browser, measured at the listener.

The web client runs the desktop capture chain (rnnoise, the gate and the
dynamics, compiled to wasm) in an AudioWorklet before the track is published.
Three senders capture the same speech-over-steady-noise WAV that
e2e_voice_noise.py uses: Standard with the gate wide open, Strong with the gate
wide open, and Strong with the gate at its default threshold. Alice's in-page
analyser measures each one after the SFU.

The thresholds carry the numbers they were set from, beside them below.
"""
import json
import time

import e2e_audio
import e2e_audio_levels as lv
import e2e_browsers
import e2e_labels as L
import e2e_voice_noise as noise
import e2e_voice_ui as ui
from e2e_voice import _tap_label

GATE_OFF_DB, GATE_ON_DB = -80.0, -50.0
ARMS = {
    "nsstandard": ("standard", GATE_OFF_DB),
    "nsstrong": ("strong", GATE_OFF_DB),
    "nsgated": ("strong", GATE_ON_DB),
}
STRONG_EXTRA_REDUCTION_MIN_DB = 12.0  # measured 26.3 dB: standard floor -49.8, strong -76.1
SPEECH_LOSS_MAX_DB = 3.0  # measured -0.5 dB: standard speech -16.3, strong -15.8
GATED_FLOOR_MAX_DB = -100.0  # measured -112.6 dB: silence between phrases
GATED_SPEECH_LOSS_MAX_DB = 3.0  # measured 0.1 dB against the ungated strong arm
MEASURE_SECONDS = 12


def prefs_script(choice, threshold_db):
    """Saved settings for one sender, written before the app reads them."""
    prefs = {
        "flutter.slimm.voice.noise_suppression": json.dumps(choice),
        "flutter.slimm.voice.input_threshold_db": json.dumps(threshold_db),
        "flutter.slimm.voice.input_threshold_auto": "false",
    }
    sets = "".join(f"localStorage.setItem({json.dumps(k)},{json.dumps(v)});"
                   for k, v in prefs.items())
    return f"try{{{sets}}}catch(e){{}}"


def _measure(probe, stream, start):
    return lv.floor_and_speech([s[1] for s in probe.series(stream, start)])


def strong_and_the_gate_run_in_the_browser(listener, server, secret, admin_api,
                                           sign_in, room_id):
    path = noise.fixture_path()
    from e2e_api import Api
    ids = {}
    for user in ARMS:
        e2e_browsers.register(server, admin_api, user, secret)
        api = Api(server)
        api.login(user, secret, device="e2e-noise-chain")
        ids[user] = api.me()["id"]

    # The browser names only pick reserved debugging ports; the users name the arms.
    with e2e_audio.installed(listener), \
            e2e_browsers.browser("noisy", path) as standard, \
            e2e_browsers.browser("raw", path) as strong, \
            e2e_browsers.browser("quiet", path) as gated:
        senders = {"nsstandard": standard, "nsstrong": strong, "nsgated": gated}
        for user, client in senders.items():
            e2e_audio.install(client, extra=prefs_script(*ARMS[user]))
            sign_in(client, server, user, secret)
        try:
            listener.click(L.VOICE_CHANNEL)
            listener.wait_for(L.IN_CALL)
            for client in senders.values():
                noise._join(client)
            probe = e2e_audio.AudioProbe(listener)
            probe.wait_for_streams(len(senders))
            streams = {u: ui.stream_for(probe, room_id, ids[u]) for u in senders}
            start = probe.now()
            time.sleep(MEASURE_SECONDS)
            levels = {u: _measure(probe, streams[u], start) for u in senders}
            for user, (floor, speech) in levels.items():
                print(f"  {user:11s} floor {floor:6.1f} dB  speech {speech:6.1f} dB")
            (std_floor, std_speech) = levels["nsstandard"]
            (strong_floor, strong_speech) = levels["nsstrong"]
            (gated_floor, gated_speech) = levels["nsgated"]
            extra = lv.noise_reduction_db(std_floor, strong_floor)
            loss = lv.speech_loss_db(std_speech, strong_speech)
            gated_loss = lv.speech_loss_db(strong_speech, gated_speech)
            print(f"  strong: floor {extra:.1f} dB under standard, speech {loss:.1f} dB quieter")
            print(f"  gate: floor {gated_floor:.1f} dB, speech {gated_loss:.1f} dB quieter than ungated")
            assert extra >= STRONG_EXTRA_REDUCTION_MIN_DB, \
                f"Strong only took {extra:.1f} dB more off the floor than Standard"
            assert loss <= SPEECH_LOSS_MAX_DB, f"Strong cost the speech {loss:.1f} dB"
            assert gated_floor <= GATED_FLOOR_MAX_DB, \
                f"the gate let the noise floor through at {gated_floor:.1f} dB"
            assert gated_loss <= GATED_SPEECH_LOSS_MAX_DB, \
                f"the gate cost the speech {gated_loss:.1f} dB"
        finally:
            for c in (listener, standard, strong, gated):
                if c.find(L.LEAVE_CALL):
                    _tap_label(c, L.LEAVE_CALL, settle=3)
