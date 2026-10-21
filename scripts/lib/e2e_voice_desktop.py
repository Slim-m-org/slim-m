# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The real Linux desktop client against a noisy microphone, judged by a listener in a browser.

A virtual PipeWire microphone plays speech mixed with noise (make_noise_bed.py) into the release client built with `--dart-define=SLIMM_VOICE_HARNESS=true`, which joins as `vqdesk` inside a nested compositor; a headless browser, `vqb`, records what arrives.
Four settings arms are recorded on every network profile and scored by voice_noise.py.
Opt in with E2E_ONLY="voice desktop"; E2E_DESKTOP_BUNDLE points at the build, E2E_DESKTOP_ARMS, E2E_DESKTOP_PROFILES and E2E_DESKTOP_SECONDS (default 60) narrow the run, and E2E_DESKTOP_VOICES lists corpus clip ids (or piper).
"""
import dataclasses
import json
import math
import os
import time

import desktop_audio as da
import e2e_api
import e2e_labels as L
import e2e_netem
import e2e_xp as xp
import make_noise_bed
import make_speech_clip as speech
import voice_corpus
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


def _voice_samples(voice):
    """The speech to send: a corpus clip cut into gapped phrases, else piper's sentences."""
    folder = voice_corpus.corpus_dir()
    if not voice or voice == "piper":
        return speech.build_gapped("A")
    assert folder, f"E2E_DESKTOP_VOICES names {voice} but E2E_VQ_CORPUS has no corpus"
    clip, _ = dsp.read_wav(os.path.join(folder, voice + ".wav"))
    return voice_corpus.gapped(clip, chunk_s=min(3.5, max(1.2, len(clip) / voice_corpus.RATE / 8)))


def _write_inputs(directory, voice=None):
    """Clean speech, the noisy mix and the event list; returns their paths."""
    samples, spans = _voice_samples(voice)
    noisy, events = make_noise_bed.mix(samples, spans)
    paths = {"clean": os.path.join(directory, "clean.wav"),
             "mix": os.path.join(directory, "mix.wav")}
    dsp.write_wav(paths["clean"], samples, speech.RATE)
    dsp.write_wav(paths["mix"], noisy, speech.RATE)
    with open(os.path.join(directory, "noise-spans.json"), "w") as fh:
        json.dump({"speech": spans, "events": events}, fh)
    return paths, spans, events


JOIN_FAILED = "SLIMM_HARNESS join-failed"


def is_join_failure(err):
    """A launch that never joined, or said its join failed: worth one retry."""
    return "never printed" in str(err) or JOIN_FAILED in str(err)


def _tokens(server, secret):
    got = e2e_api.Api(server).login(USER, secret, device="e2e-desktop")
    return {key: got[key] for key in ("user_id", "access_token", "refresh_token",
                                      "access_expires_at")}


LOOP_MARGIN_S = 8
MIN_RECORDED = 0.8
STRONG_MIN, STANDARD_MAX = 0.5, 0.1


def record_seconds(mix_seconds):
    """A recording must cover one full pass of the looped mix, or events beyond the window go unscored."""
    return max(SECONDS, math.ceil(mix_seconds) + LOOP_MARGIN_S)


def _listen(listener, profile, seconds):
    e2e_netem.apply(profile)
    xp.wait_remote_audio(listener, 90)
    time.sleep(WARMUP)
    xp.start_tap(listener, "rx", remote=True)
    time.sleep(seconds)
    return xp.finish_tap(listener, "rx")


@dataclasses.dataclass
class Stack:
    """What every arm shares: the listener, the inputs and where the run happens."""
    listener: object
    inputs: dict
    server: str
    secret: str
    channel: str
    compositor: str
    directory: str
    bundle: str
    feeder: object


def gate_problems(choice, gate):
    """Why the app's own gate log contradicts the arm it was asked to run."""
    if not gate["readings"]:
        return ["the app logged no gate readings"]
    strong = gate["strong"]
    if choice == "strong" and strong < STRONG_MIN:
        return [f"strong arm but rnnoise ran on only {strong:.0%} of readings"]
    if choice == "standard" and strong > STANDARD_MAX:
        return [f"standard arm but rnnoise ran on {strong:.0%} of readings"]
    return []


def recording_problems(samples, seconds):
    """Why a recording cannot be scored: far too short, or silent."""
    if len(samples) < MIN_RECORDED * seconds * 48000:
        return [f"recorded {len(samples) / 48000:.1f}s of the {seconds}s asked for"]
    if not any(abs(v) > 1e-4 for v in samples):
        return ["the recording is digital silence"]
    return []


def _arm(name, ctx):
    listener, inputs, server, secret = ctx.listener, ctx.inputs, ctx.server, ctx.secret
    directory = ctx.directory
    choice, threshold = ARMS[name]
    # Refresh tokens are single use, so every launch gets a pair nobody has spent.
    tokens = _tokens(server, secret)
    root = da.seed_profile(
        os.path.join(directory, f"xdg-{name}"), server, tokens,
        {"slimm.voice.noise_suppression": choice,
         "slimm.voice.input_threshold_db": threshold,
         "slimm.voice.input_threshold_auto": False,
         "slimm.voice.even_out_loud": True})
    app = da.Desktop(ctx.bundle, root, ctx.channel, os.path.join(directory, f"app-{name}.log"))
    clean, mix = (dsp.read_wav(inputs[k]) for k in ("clean", "mix"))
    seconds = record_seconds(len(mix[0]) / mix[1])
    rows = {}
    try:
        da.full_volume()
        app.start(ctx.compositor)
        app.wait_for("SLIMM_HARNESS joined", 150, fail_on=JOIN_FAILED)
        pids = app.app_pids()
        da.assert_isolated(pids)
        assert da.app_captures_mic(pids), "the app is not recording from the virtual microphone"
        for profile in [p for p in os.environ.get(
                "E2E_DESKTOP_PROFILES", "clean,loss5-jitter30,burst").split(",") if p]:
            da.full_volume()
            samples, _, dropped = _listen(listener, profile, seconds)
            xp.save_wav(os.path.join(directory, f"rx-{name}-{profile}.wav"), samples)
            assert app.proc.poll() is None and ctx.feeder.poll() is None, \
                f"the app or the microphone feeder died during {profile}"
            found = recording_problems(samples, seconds)
            assert not found, f"{name} {profile}: {'; '.join(found)}"
            rows[profile] = {"dropped_frames": dropped, "seconds": round(len(samples) / 48000, 1)}
            rows[profile]["noise"] = voice_noise.analyze(
                clean, mix, (samples, 48000), inputs["spans"], inputs["events"])
            print(f"  {name:18} {profile:15} {rows[profile]['noise']}")
        rows["gate_log"] = da.gate_summary(app.gate_lines())
        print(f"  {name:18} gate log {rows['gate_log']}")
        found = gate_problems(choice, rows["gate_log"])
        assert not found, f"{name}: {'; '.join(found)}"
    finally:
        e2e_netem.clear()
        app.stop()
    return rows


def a_noisy_desktop(server, secret, admin_api, sign_in, room_id):
    e2e_netem.ensure_image()
    bundle = os.path.abspath(os.environ.get("E2E_DESKTOP_BUNDLE") or BUNDLE)
    assert os.path.exists(os.path.join(bundle, "slimm_app")), f"no desktop build at {bundle}"
    xp.e2e_browsers.register(server, admin_api, USER, secret)
    channel = admin_api.channel_named(L.VOICE_CHANNEL)["id"]
    owner_before = da.default_devices()
    assert not any("slimm_vq" in line for line in owner_before), \
        f"a default device already points at a harness device: {owner_before}"
    try:
        for voice in [v for v in os.environ.get("E2E_DESKTOP_VOICES", "").split(",") if v] or [None]:
            _one_voice(voice, (server, secret, admin_api, sign_in), channel, bundle)
    finally:
        after = da.default_devices()
        assert after == owner_before, f"the owner's default audio devices changed: {after}"


def _one_voice(voice, stack, channel, bundle):
    server, secret, admin_api, sign_in = stack
    directory = xp.out_dir("desktop" + (f"-{voice}" if voice else ""))
    paths, spans, events = _write_inputs(directory, voice)
    inputs = {**paths, "spans": spans, "events": events}
    wanted = [a for a in os.environ.get("E2E_DESKTOP_ARMS", ",".join(ARMS)).split(",") if a]
    results = {}
    owner_devices = da.default_devices()
    with da.nested_compositor(os.path.join(directory, "kwin.log")) as compositor, \
            da.virtual_mic(paths["mix"]) as feeder:
        assert da.default_devices() == owner_devices, "starting the virtual devices moved a default"
        with xp.one_listener(server, secret, admin_api, sign_in, paths["clean"]) as listener:
            ctx = Stack(listener, inputs, server, secret, channel, compositor, directory,
                        bundle, feeder)
            for name in wanted:
                results[name] = _arm_with_retry(name, ctx)
                with open(os.path.join(directory, "desktop.json"), "w") as fh:
                    json.dump(results, fh, indent=1)


def _arm_with_retry(name, ctx):
    """A desktop launch that never joins the call is retried once; the second failure counts."""
    try:
        return _arm(name, ctx)
    except AssertionError as err:
        if not is_join_failure(err):
            raise
        print(f"  {name}: {err}; retrying once", flush=True)
        return _arm(name, ctx)


def run_if_selected(server, secret, admin_api, sign_in, room_id):
    if "voice desktop" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='voice desktop' to run it")
        return
    a_noisy_desktop(server, secret, admin_api, sign_in, room_id)
