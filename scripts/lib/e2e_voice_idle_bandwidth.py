# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What the Linux client puts on the wire while silent behind a closed gate, silent with the gate open, and speaking.

The listener's inbound-rtp counters for the desktop client's track give bytes and packets per second over a steady window.
Each condition is its own launch, because the gate threshold is a saved setting and the microphone clip loops from a fixed start.
Opt in with E2E_ONLY="voice idle bandwidth"; E2E_DESKTOP_BUNDLE picks the build (the DTX comparison is two bundles), E2E_IDLE_LABEL names the output folder, E2E_IDLE_ARMS and E2E_IDLE_SECONDS narrow the run.
"""
import json
import os
import random
import time

import desktop_audio as da
import e2e_api
import e2e_labels as L
import e2e_netem
import e2e_voice_desktop as desktop
import e2e_xp as xp
import make_speech_clip as speech
import voice_quality_dsp as dsp

WINDOW_S = int(os.environ.get("E2E_IDLE_SECONDS", "60"))
ROOM_NOISE_DBFS = -66.0
ROOM_SECONDS = 90
# RTP 12, UDP 8, IPv4 20 and the SRTP tag 10: what each packet costs beyond its payload.
OVERHEAD_BYTES = 50

CONDITIONS = {
    "silent-gate-closed": ("room", desktop.GATE_ON),
    "silent-gate-open": ("room", desktop.GATE_OFF),
    "speaking": ("speech", desktop.GATE_ON),
}
CHOICES = ("standard", "strong")


def room_noise(seconds, dbfs, seed=7):
    """Seeded broadband noise at `dbfs` RMS, like a quiet room."""
    rng = random.Random(seed)
    amp = 10 ** (dbfs / 20)
    return [rng.gauss(0.0, amp) for _ in range(int(seconds * speech.RATE))]


def rate_between(rows, start_index):
    """Bytes, packets and seconds between the first row after `start_index` and the last; rows are one ssrc's samples."""
    window = rows[start_index:]
    first, last = window[0], window[-1]
    seconds = (last["t"] - first["t"]) / 1000.0
    payload = last["bytesReceived"] - first["bytesReceived"]
    packets = last["packetsReceived"] - first["packetsReceived"]
    return {"seconds": round(seconds, 1),
            "payload_bytes_per_s": round(payload / seconds, 1),
            "packets_per_s": round(packets / seconds, 1),
            "wire_kbps": round(8 * (payload + OVERHEAD_BYTES * packets) / seconds / 1000, 1)}


def measure(listener, seconds):
    """Rates over `seconds` of the listener's own counters for the one remote audio ssrc."""
    mark = xp.ev_json(listener, "window.__vq.stats.length")
    time.sleep(seconds)
    rows = xp.ev_json(listener, f"window.__vq.stats.slice({mark})")
    ssrcs = {r["ssrc"] for r in rows}
    assert len(ssrcs) == 1, f"expected one remote audio stream, saw {sorted(ssrcs)}"
    return rate_between(rows, 0)


def _inputs(directory):
    paths = {}
    room = room_noise(ROOM_SECONDS, ROOM_NOISE_DBFS)
    paths["room"] = os.path.join(directory, "room.wav")
    dsp.write_wav(paths["room"], room, speech.RATE)
    samples, _ = speech.build_gapped("A")
    paths["speech"] = os.path.join(directory, "speech.wav")
    dsp.write_wav(paths["speech"], samples, speech.RATE)
    return paths


def _launch(ctx, name, choice, threshold):
    tokens = desktop._tokens(ctx["server"], ctx["secret"])
    prefs = desktop.arm_prefs(choice, threshold)
    root = da.seed_profile(os.path.join(ctx["directory"], f"xdg-{name}"), ctx["server"], tokens, prefs)
    app = da.Desktop(ctx["bundle"], root, ctx["channel"], os.path.join(ctx["directory"], f"app-{name}.log"))
    app.start(ctx["compositor"])
    app.wait_for("SLIMM_HARNESS joined", 150, fail_on=desktop.JOIN_FAILED)
    da.assert_isolated(app.app_pids())
    return app


def _condition(name, choice, ctx):
    source, threshold = CONDITIONS[name]
    with da.virtual_mic(ctx["inputs"][source]) as feeder:
        app = _launch(ctx, f"{choice}-{name}", choice, threshold)
        try:
            xp.wait_remote_audio(ctx["listener"], 90)
            time.sleep(desktop.WARMUP)
            row = measure(ctx["listener"], WINDOW_S)
            assert app.proc.poll() is None and feeder.poll() is None, "the app or the feeder died"
            row["gate_log"] = da.gate_summary(app.gate_lines())
        finally:
            app.stop()
    print(f"  {choice:9} {name:20} {row}", flush=True)
    return row


def run(server, secret, admin_api, sign_in):
    e2e_netem.ensure_image()
    e2e_netem.clear()
    bundle = os.path.abspath(os.environ.get("E2E_DESKTOP_BUNDLE") or desktop.BUNDLE)
    assert os.path.exists(os.path.join(bundle, "slimm_app")), f"no desktop build at {bundle}"
    xp.e2e_browsers.register(server, admin_api, desktop.USER, secret)
    channel = admin_api.channel_named(L.VOICE_CHANNEL)["id"]
    directory = xp.out_dir("idle-" + os.environ.get("E2E_IDLE_LABEL", "run"))
    inputs = _inputs(directory)
    wanted = [a for a in os.environ.get("E2E_IDLE_ARMS", "").split(",") if a]
    results = {}
    with da.nested_compositor(os.path.join(directory, "kwin.log")) as compositor:
        with xp.one_listener(server, secret, admin_api, sign_in, inputs["speech"]) as listener:
            ctx = {"server": server, "secret": secret, "channel": channel, "bundle": bundle,
                   "directory": directory, "inputs": inputs, "listener": listener,
                   "compositor": compositor}
            for choice in CHOICES:
                for name in CONDITIONS:
                    if wanted and f"{choice}-{name}" not in wanted:
                        continue
                    results[f"{choice}-{name}"] = _condition(name, choice, ctx)
                    with open(os.path.join(directory, "idle-bandwidth.json"), "w") as fh:
                        json.dump(results, fh, indent=1)
    return results


def run_if_selected(server, secret, admin_api, sign_in):
    if "voice idle bandwidth" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='voice idle bandwidth' to run it")
        return
    run(server, secret, admin_api, sign_in)
