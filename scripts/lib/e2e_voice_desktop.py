# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The real Linux desktop client against a noisy microphone, judged by a listener in a browser.

A virtual PipeWire microphone plays speech with fan hum, typing and a dog bark
mixed in (make_noise_bed.py). The release build of the Linux client, made with
`--dart-define=SLIMM_VOICE_HARNESS=true`, runs inside a nested compositor with
its own session and joins the e2e voice channel as `vqdesk` (the harness entry
point, client/packages/app/lib/src/diagnostics/voice_harness.dart). A headless
browser, `vqb`, is the listener and records what arrives. Four settings arms
(Strong on or off, the input gate on or off) are each recorded on every network
profile, and voice_noise.py scores floor, noise events, speech level and onsets.
Opt in with E2E_ONLY="voice desktop". E2E_DESKTOP_BUNDLE points at the build,
E2E_DESKTOP_ARMS and E2E_DESKTOP_PROFILES narrow the run, E2E_DESKTOP_SECONDS
sets each recording (default 60).
"""
import json
import os
import time

import desktop_audio as da
import e2e_api
import e2e_labels as L
import e2e_netem
import e2e_xp as xp
import make_noise_bed
import make_speech_clip as speech
import voice_noise
import voice_quality_dsp as dsp

SECONDS = int(os.environ.get("E2E_DESKTOP_SECONDS", "60"))
WARMUP = 12
USER = "vqdesk"
GATE_OFF, GATE_ON = -80.0, -50.0
ARMS = {
    "standard-gate-off": ("standard", GATE_OFF),
    "standard-gate-on": ("standard", GATE_ON),
    "strong-gate-off": ("strong", GATE_OFF),
    "strong-gate-on": ("strong", GATE_ON),
}
BUNDLE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "client", "packages", "app",
    "build", "linux", "x64", "release", "bundle")


def _write_inputs(directory):
    """Clean speech, the noisy mix and the event list; returns their paths."""
    samples, spans = speech.build_gapped("A")
    noisy, events = make_noise_bed.mix(samples, spans)
    paths = {"clean": os.path.join(directory, "clean.wav"),
             "mix": os.path.join(directory, "mix.wav")}
    dsp.write_wav(paths["clean"], samples, speech.RATE)
    dsp.write_wav(paths["mix"], noisy, speech.RATE)
    with open(os.path.join(directory, "noise-spans.json"), "w") as fh:
        json.dump({"speech": spans, "events": events}, fh)
    return paths, spans, events


def _tokens(server, secret):
    got = e2e_api.Api(server).login(USER, secret, device="e2e-desktop")
    return {key: got[key] for key in ("user_id", "access_token", "refresh_token",
                                      "access_expires_at")}


def _listen(listener, profile):
    e2e_netem.apply(profile)
    xp.wait_remote_audio(listener, 90)
    time.sleep(WARMUP)
    xp.start_tap(listener, "rx", remote=True)
    time.sleep(SECONDS)
    return xp.finish_tap(listener, "rx")


def _arm(name, listener, inputs, server, tokens, channel, compositor, directory, bundle):
    choice, threshold = ARMS[name]
    root = da.seed_profile(
        os.path.join(directory, f"xdg-{name}"), server, tokens,
        {"slimm.voice.noise_suppression": choice,
         "slimm.voice.input_threshold_db": threshold,
         "slimm.voice.input_threshold_auto": False,
         "slimm.voice.even_out_loud": True})
    app = da.Desktop(bundle, root, channel, os.path.join(directory, f"app-{name}.log"))
    clean, mix = (dsp.read_wav(inputs[k]) for k in ("clean", "mix"))
    rows = {}
    try:
        app.start(compositor)
        app.wait_for("SLIMM_HARNESS joined", 150)
        for pid in app.app_pids():
            assert not da.touches_owner_data(pid), f"pid {pid} holds the owner's app data"
        for profile in [p for p in os.environ.get(
                "E2E_DESKTOP_PROFILES", "clean,loss5-jitter30,burst").split(",") if p]:
            samples, _, dropped = _listen(listener, profile)
            xp.save_wav(os.path.join(directory, f"rx-{name}-{profile}.wav"), samples)
            rows[profile] = {"dropped_frames": dropped, "seconds": round(len(samples) / 48000, 1)}
            rows[profile]["noise"] = voice_noise.analyze(
                clean, mix, (samples, 48000), inputs["spans"], inputs["events"])
            print(f"  {name:18} {profile:15} {rows[profile]['noise']}")
        rows["gate_log"] = da.gate_summary(app.gate_lines())
    finally:
        e2e_netem.clear()
        app.stop()
    return rows


def a_noisy_desktop(server, secret, admin_api, sign_in, room_id):
    e2e_netem.ensure_image()
    bundle = os.path.abspath(os.environ.get("E2E_DESKTOP_BUNDLE") or BUNDLE)
    assert os.path.exists(os.path.join(bundle, "slimm_app")), f"no desktop build at {bundle}"
    directory = xp.out_dir("desktop")
    paths, spans, events = _write_inputs(directory)
    inputs = {**paths, "spans": spans, "events": events}
    xp.e2e_browsers.register(server, admin_api, USER, secret)
    tokens = _tokens(server, secret)
    channel = admin_api.channel_named(L.VOICE_CHANNEL)["id"]
    wanted = [a for a in os.environ.get("E2E_DESKTOP_ARMS", ",".join(ARMS)).split(",") if a]
    owner_before = da.default_devices()
    results = {}
    with da.nested_compositor(os.path.join(directory, "kwin.log")) as compositor, \
            da.virtual_mic(paths["mix"]):
        with xp.one_listener(server, secret, admin_api, sign_in, paths["clean"]) as listener:
            for name in wanted:
                results[name] = _arm(name, listener, inputs, server, tokens, channel,
                                     compositor, directory, bundle)
    assert da.default_devices() == owner_before, "the owner's default audio devices changed"
    with open(os.path.join(directory, "desktop.json"), "w") as fh:
        json.dump(results, fh, indent=1)


def run_if_selected(server, secret, admin_api, sign_in, room_id):
    if "voice desktop" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='voice desktop' to run it")
        return
    a_noisy_desktop(server, secret, admin_api, sign_in, room_id)
