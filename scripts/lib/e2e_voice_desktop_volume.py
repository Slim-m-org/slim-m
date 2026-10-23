# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The Linux client's per-person volume slider, judged by the sound it plays.

A browser, `vqb`, sends a steady tone into the call; the release client built with `--dart-define=SLIMM_VOICE_HARNESS=true` joins as `vqdesk`, with `vqb` already set to a slider value in its saved preferences, inside the nested compositor.
The client's playback goes to a null sink, and that sink's monitor is recorded and measured.
Opt in with E2E_ONLY="volume slider on the desktop"; E2E_DESKTOP_BUNDLE points at the build and E2E_DESKTOP_SLIDERS lists the slider values, 0 to 2 (default 0,0.25,0.5,1,1.5,2).
"""
import array
import json
import math
import os
import subprocess
import time
import wave

import desktop_audio as da
import e2e_api
import e2e_labels as L
import e2e_voice_desktop as vd
import e2e_xp as xp
from e2e_voice import _tap_label as tap
from private_pulse import private_server

SLIDERS = "0,0.25,0.5,1,1.5,2"
RATE = 48000
WINDOW = RATE // 20
RECORD_SECONDS = 10
SETTLE_SECONDS = 8
USER = "vqdesk"


def tone_wav(path, seconds=30, level_db=-20.0):
    """A harmonic complex at a steady level, so a level change is the gain and not the speech."""
    peak = 10 ** (level_db / 20) * math.sqrt(2) / 1.6
    samples = array.array("h")
    for n in range(seconds * RATE):
        t = n / RATE
        value = sum(math.sin(2 * math.pi * 220 * k * t) / k for k in (1, 2, 3, 4)) * peak
        samples.append(int(max(-1.0, min(1.0, value)) * 32767))
    with wave.open(path, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(RATE)
        fh.writeframes(samples.tobytes())
    return path


def window_levels_db(raw):
    """The RMS of each 50 ms window of s16le mono audio, in dBFS."""
    samples = array.array("h")
    samples.frombytes(raw[: len(raw) // 2 * 2])
    levels = []
    for start in range(0, len(samples) - WINDOW, WINDOW):
        chunk = samples[start:start + WINDOW]
        mean = sum(v * v for v in chunk) / len(chunk)
        levels.append(10 * math.log10(mean / 32768 ** 2) if mean else -120.0)
    return levels


def heard_db(levels):
    """The level the listener hears: the 90th percentile window, ignoring gaps and fade-in."""
    if not levels:
        return -120.0
    ordered = sorted(levels)
    return ordered[int(len(ordered) * 0.9)]


def expected_db(slider):
    """The change from 100% the slider asks for: the cube below 100%, linear above."""
    gain = slider ** 3 if slider <= 1 else slider
    return 20 * math.log10(gain) if gain > 0 else -math.inf


TOLERANCE_DB = 1.5
SILENT_DB = -90.0
AUDIBLE_DB = -50.0


def problems(levels):
    """Why measured levels (dBFS by slider value, or by event name at 50%) contradict the slider."""
    reference = levels.get(1.0)
    if reference is None or reference < AUDIBLE_DB:
        return [f"the 100% reference is {reference}, so nothing was playing to measure against"]
    found = []
    for key, level in levels.items():
        want = expected_db(key) if isinstance(key, float) else expected_db(0.5)
        if want == -math.inf:
            if level > SILENT_DB:
                found.append(f"slider {key} should be silent but played at {level:.1f} dBFS")
        elif abs((level - reference) - want) > TOLERANCE_DB:
            found.append(f"{key}: {level - reference:+.1f} dB from 100%, wanted {want:+.1f}")
    return found


def _record(seconds):
    proc = subprocess.run(
        ["timeout", str(seconds), "parec", f"--device={da.OUT}.monitor", "--raw",
         "--format=s16le", f"--rate={RATE}", "--channels=1"],
        capture_output=True, check=False)
    return proc.stdout


def _one(slider, ctx):
    tokens = vd._tokens(ctx["server"], ctx["secret"])
    root = da.seed_profile(
        os.path.join(ctx["directory"], f"xdg-{slider}"), ctx["server"], tokens,
        {"slimm.voice.participant_volumes": json.dumps({ctx["sender"]: slider}),
         "slimm.voice.noise_suppression": "standard"})
    app = da.Desktop(ctx["bundle"], root, ctx["channel"],
                     os.path.join(ctx["directory"], f"app-{slider}.log"))
    try:
        app.start(ctx["compositor"])
        app.wait_for("SLIMM_HARNESS joined", 150, fail_on=vd.JOIN_FAILED)
        time.sleep(SETTLE_SECONDS)
        levels = window_levels_db(_record(RECORD_SECONDS))
    finally:
        app.stop()
    return heard_db(levels)


def _live(sliders, ctx):
    """One launch with the slider moved while the call runs, the way a listener drags it."""
    tokens = vd._tokens(ctx["server"], ctx["secret"])
    root = da.seed_profile(os.path.join(ctx["directory"], "xdg-live"), ctx["server"], tokens,
                           {"slimm.voice.noise_suppression": "standard"})
    control = os.path.join(ctx["directory"], "volume.txt")
    with open(control, "w") as fh:
        fh.write("1.0")
    app = da.Desktop(ctx["bundle"], root, ctx["channel"],
                     os.path.join(ctx["directory"], "app-live.log"),
                     extra_args=[f"--voice-harness-volume-file={control}"])
    results = {}
    try:
        app.start(ctx["compositor"])
        app.wait_for("SLIMM_HARNESS joined", 150, fail_on=vd.JOIN_FAILED)
        time.sleep(SETTLE_SECONDS)
        for slider in sliders:
            with open(control, "w") as fh:
                fh.write(str(slider))
            app.wait_for(f"SLIMM_HARNESS volume set {slider}", 20)
            time.sleep(SETTLE_SECONDS / 2)
            results[slider] = heard_db(window_levels_db(_record(RECORD_SECONDS)))
            print(f"  live slider {slider:4}: {results[slider]:7.1f} dBFS", flush=True)
        results.update(_after_events(app, control, ctx["sender_page"]))
    finally:
        app.stop()
    return results


def _hear(label):
    level = heard_db(window_levels_db(_record(RECORD_SECONDS)))
    print(f"  {label}: {level:7.1f} dBFS", flush=True)
    return level


def _after_events(app, control, sender):
    """The slider at 50%, then the sender mutes and unmutes, then leaves and rejoins."""
    with open(control, "w") as fh:
        fh.write("0.5")
    app.wait_for("SLIMM_HARNESS volume set 0.5", 20)
    time.sleep(SETTLE_SECONDS / 2)
    found = {"0.5 again": _hear("0.5 before the events")}
    tap(sender, L.MUTE, settle=4)
    tap(sender, L.UNMUTE, settle=SETTLE_SECONDS)
    found["0.5 after a mute and unmute"] = _hear("0.5 after the sender muted and unmuted")
    tap(sender, L.LEAVE_CALL, settle=4)
    xp.join(sender)
    time.sleep(SETTLE_SECONDS)
    found["0.5 after a rejoin"] = _hear("0.5 after the sender left and rejoined")
    return found


def a_desktop_slider_changes_the_loudness(server, secret, admin_api, sign_in):
    bundle = os.path.abspath(os.environ.get("E2E_DESKTOP_BUNDLE") or vd.BUNDLE)
    assert os.path.exists(os.path.join(bundle, "slimm_app")), f"no desktop build at {bundle}"
    sliders = [float(s) for s in os.environ.get("E2E_DESKTOP_SLIDERS", SLIDERS).split(",") if s]
    xp.e2e_browsers.register(server, admin_api, USER, secret)
    channel = admin_api.channel_named(L.VOICE_CHANNEL)["id"]
    directory = xp.out_dir("desktop-volume")
    wav = tone_wav(os.path.join(directory, "tone.wav"))
    silence = os.path.join(directory, "silence.wav")
    with wave.open(silence, "wb") as fh:
        fh.setnchannels(1)
        fh.setsampwidth(2)
        fh.setframerate(RATE)
        fh.writeframes(bytes(2 * RATE * 30))
    results = {}
    with private_server(), \
            da.nested_compositor(os.path.join(directory, "kwin.log")) as compositor, \
            da.virtual_mic(silence):
        # The sender's own playback must not land on the sink the client records from.
        da._pactl("load-module", "module-null-sink", "sink_name=slimm_vq_room")
        da._pactl("set-default-sink", "slimm_vq_room")
        with xp.one_listener(server, secret, admin_api, sign_in, wav) as _page:
            sender = e2e_api.Api(server).login("vqb", secret, device="e2e-volume")["user_id"]
            ctx = {"server": server, "secret": secret, "directory": directory,
                   "bundle": bundle, "channel": channel, "compositor": compositor,
                   "sender": sender, "sender_page": _page}
            if os.environ.get("E2E_DESKTOP_LIVE"):
                results = _live(sliders, ctx)
            else:
                for slider in sliders:
                    results[slider] = _one(slider, ctx)
                    print(f"  slider {slider:4}: {results[slider]:7.1f} dBFS", flush=True)
    reference = results.get(1.0)
    rows = {}
    for slider, level in results.items():
        rows[slider] = {"heard_db": round(level, 1),
                        "vs_100_db": None if reference is None else round(level - reference, 1),
                        "expected_vs_100_db": (round(expected_db(slider), 1) if isinstance(slider, float) else None)}
    print(json.dumps(rows, indent=1))
    found = problems(results)
    assert not found, "; ".join(found)
    with open(os.path.join(directory, "desktop-volume.json"), "w") as fh:
        json.dump(rows, fh, indent=1)
    return rows


def run_if_selected(server, secret, admin_api, sign_in):
    if "volume slider on the desktop" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='volume slider on the desktop' to run it")
        return
    a_desktop_slider_changes_the_loudness(server, secret, admin_api, sign_in)
