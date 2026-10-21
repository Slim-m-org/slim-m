# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Mouth-to-ear delay through a real call, per network profile.

Both browsers play the latency clip (make_speech_clip.py) and tap their microphone and the other's decoded track on one epoch clock (e2e_xp_js.py); the receiver's jitter buffer delay is reported beside it.
Opt in with E2E_ONLY="voice latency"; E2E_VQ_PROFILES and E2E_VQ_SECONDS apply as for the quality scenario.
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
RESULTS = "latency.json"
MIN_CLEAN_CHIRPS = 5


def problems(profile, row):
    """Why a profile's row cannot be trusted: a direction that sent or heard nothing."""
    found = []
    for name in ("vqa_to_vqb", "vqb_to_vqa"):
        d = row[name]
        if not d["sent"]:
            found.append(f"{profile} {name}: no chirp left the sender (dead tap or wrong stream)")
        elif not d["heard"]:
            found.append(f"{profile} {name}: {d['sent']} chirps sent, none heard")
        elif profile == "clean" and d["mouth_to_ear_ms"].get("n", 0) < MIN_CLEAN_CHIRPS:
            found.append(f"{profile} {name}: only {d['mouth_to_ear_ms'].get('n', 0)} chirps crossed")
    return found


def _direction(sender, receiver):
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


def a_timed_call(server, secret, admin_api, sign_in):
    e2e_netem.ensure_image()
    wanted = [p for p in os.environ.get(
        "E2E_VQ_PROFILES", ",".join(e2e_netem.PROFILES)).split(",") if p]
    directory = xp.out_dir("latency")
    unknown = [p for p in wanted if p not in e2e_netem.PROFILES]
    assert not unknown, f"unknown E2E_VQ_PROFILES {unknown}; known: {list(e2e_netem.PROFILES)}"
    if os.path.exists(os.path.join(directory, RESULTS)):
        os.remove(os.path.join(directory, RESULTS))
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
                row = {"vqa_to_vqb": _direction(taps["vqa"], taps["vqb"]),
                       "vqb_to_vqa": _direction(taps["vqb"], taps["vqa"]),
                       "stats": stats}
                results[profile] = row
                with open(os.path.join(directory, RESULTS), "w") as fh:
                    json.dump(results, fh, indent=1)
                for name, d in (("vqa->vqb", row["vqa_to_vqb"]), ("vqb->vqa", row["vqb_to_vqa"])):
                    print(f"  {profile:18} {name} sent {d['sent']} heard {d['heard']} "
                          f"{d['mouth_to_ear_ms']}")
        finally:
            e2e_netem.clear()
    found = [p for profile, row in results.items() for p in problems(profile, row)]
    assert results, "no profile was measured"
    assert not found, "; ".join(found)


def run_if_selected(server, secret, admin_api, sign_in):
    if "voice latency" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='voice latency' to run it")
        return
    a_timed_call(server, secret, admin_api, sign_in)
