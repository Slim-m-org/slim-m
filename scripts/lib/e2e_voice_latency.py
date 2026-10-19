# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Mouth-to-ear delay through a real call, per network profile.

Both browsers play the latency clip (a chirp every couple of seconds, see
make_speech_clip.py). Each taps its own microphone stream and the other's
decoded track with one shared epoch clock (e2e_xp_js.py); the gap between a
chirp leaving and arriving is the delay, and the receiver's jitter buffer
delay from getStats is reported beside it. Opt in with E2E_ONLY="voice latency";
E2E_VQ_PROFILES and E2E_VQ_SECONDS apply as for the quality scenario.
"""
import json
import os
import time

import e2e_netem
import e2e_xp as xp
import e2e_voice_quality as vq
import make_speech_clip as speech
import voice_latency as lat

SECONDS = int(os.environ.get("E2E_VQ_SECONDS", "45"))
SETTLE = 4


def _direction(sender, receiver, folder):
    """Delay stats for what `sender` said as `receiver` heard it."""
    tx, tx_start, _ = sender["local"]
    rx, rx_start, dropped = receiver["remote"]
    sent = lat.chirp_epochs_ms(tx, 48000, tx_start)
    heard = lat.chirp_epochs_ms(rx, 48000, rx_start)
    window = (rx_start, rx_start + len(rx) / 48.0)
    return {"sent": len(sent), "heard": len(heard), "dropped_frames": dropped,
            "answered": lat.heard_fraction(sent, heard, window),
            "mouth_to_ear_ms": lat.summary(lat.delays_ms(sent, heard)),
            "sent_ms": sent, "heard_ms": heard}


def _record(a, b, seconds):
    taps = {}
    for client, other in ((a, b), (b, a)):
        xp.start_tap(client, "local", remote=False)
        xp.start_tap(client, "remote", remote=True)
        client.ev("window.__vq.reset();")
    began = {c.name: c.ev("window.__vq.mark()") for c in (a, b)}
    time.sleep(seconds)
    for client in (a, b):
        taps[client.name] = {"local": xp.finish_tap(client, "local"),
                             "remote": xp.finish_tap(client, "remote")}
    stats = {c.name: vq.stats_summary(
        [r for r in xp.ev_json(c, "window.__vq.stats") if r["t"] >= began[c.name]])
        for c in (a, b)}
    return taps, stats


def a_timed_call(server, secret, admin_api, sign_in, room_id):
    e2e_netem.ensure_image()
    wanted = [p for p in os.environ.get(
        "E2E_VQ_PROFILES", ",".join(e2e_netem.PROFILES)).split(",") if p]
    directory = xp.out_dir("latency")
    clips = []
    for who in "AB":
        path = os.path.join(directory, f"latency-{who}.wav")
        speech.write(path, who, "latency")
        clips.append(path)
    results = {}
    with xp.two_browsers(server, secret, admin_api, sign_in, clips) as (a, b):
        for client in (a, b):
            xp.join(client)
        time.sleep(SETTLE)
        try:
            for profile in wanted:
                print(f"  profile {profile}: {e2e_netem.apply(profile)}")
                time.sleep(SETTLE)
                taps, stats = _record(a, b, SECONDS)
                row = {"vqa_to_vqb": _direction(taps["vqa"], taps["vqb"], directory),
                       "vqb_to_vqa": _direction(taps["vqb"], taps["vqa"], directory),
                       "stats": stats}
                results[profile] = row
                for name, d in (("vqa->vqb", row["vqa_to_vqb"]), ("vqb->vqa", row["vqb_to_vqa"])):
                    print(f"  {profile:18} {name} sent {d['sent']} heard {d['heard']} "
                          f"{d['mouth_to_ear_ms']}")
        finally:
            e2e_netem.clear()
    with open(os.path.join(directory, "latency.json"), "w") as fh:
        json.dump(results, fh, indent=1)
    clean = results.get("clean")
    if clean:
        got = clean["vqa_to_vqb"]["mouth_to_ear_ms"]
        assert got.get("n", 0) >= 5, f"too few chirps crossed the clean call: {got}"


def run_if_selected(server, secret, admin_api, sign_in, room_id):
    if "voice latency" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='voice latency' to run it")
        return
    a_timed_call(server, secret, admin_api, sign_in, room_id)
