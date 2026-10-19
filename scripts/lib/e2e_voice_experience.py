# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What a person waits for: joining a call, the speaking ring, and a network cut.

Join: a listener clicks the voice channel while the other person is already
talking; the page logs the click and then the first remote packet, the first
audible energy and the "in call" label. Speaking ring: a sender speaks after
long silences and the listener's semantics tree is watched for "<name>,
speaking". Cut: the SFU's egress drops everything for 10 s (netem loss 100%,
which is the downlink only; the uplink keeps flowing) and the listener's tap,
peer connection events and call state say how the call came back.
Opt in with E2E_ONLY="voice experience"; E2E_XP_JOINS (default 5) repeats the join.
"""
import json
import os
import time

import e2e_labels as L
import e2e_netem
import e2e_xp as xp
import make_speech_clip as speech
import voice_experience as ex

JOINS = int(os.environ.get("E2E_XP_JOINS", "5"))
CUT_SECONDS = 10
WATCH_AFTER = 40


def _write_clips(directory, kind):
    paths = []
    for who in "AB":
        path = os.path.join(directory, f"{kind}-{who}.wav")
        speech.write(path, who, kind)
        paths.append(path)
    return paths


def _leave(client):
    from e2e_voice import _tap_label
    _tap_label(client, L.LEAVE_CALL, settle=2)
    deadline = time.time() + 15
    while client.find(L.IN_CALL) and time.time() < deadline:
        time.sleep(0.3)


def joins(a, b):
    """Listener `b` joins `JOINS` times while `a` talks; one summary per join."""
    xp.join(a)
    b.ev(f"window.__xp.watchLabels([{json.dumps(L.IN_CALL)}]);")
    time.sleep(5)
    rows = []
    for i in range(JOINS):
        events = xp.timed_join(b)
        rows.append(ex.join_row(events, cold=i == 0))
        print(f"  join {i + 1}{' (cold)' if i == 0 else ''}: {rows[-1]}")
        if i + 1 < JOINS:
            _leave(b)
            time.sleep(3)
    return rows


def the_cut(a, b):
    """A 10 s outage of what the SFU sends; how and when `b` heard `a` again."""
    xp.start_tap(b, "remote", remote=True)
    b.ev("window.__xp.seen = {};")
    mark = b.ev("window.__xp.events.length")
    time.sleep(8)
    t_cut = e2e_netem.cut()
    time.sleep(CUT_SECONDS)
    t_back = e2e_netem.restore()
    time.sleep(WATCH_AFTER)
    pcs_after = b.ev("window.__e2eAudio.pcs.length")
    still_in_call = bool(b.find(L.IN_CALL))
    events = xp.ev_json(b, f"window.__xp.events.slice({mark})")
    series = xp.ev_json(b, "window.__xp.series")
    samples, start, dropped = xp.finish_tap(b, "remote")
    xp.save_wav(os.path.join(xp.out_dir("experience"), "cut-rx.wav"), samples)
    row = ex.cut_row(samples, start, events, series, t_cut, t_back)
    row.update(call_still_open=still_in_call, peer_connections=pcs_after,
               dropped_frames=dropped)
    return row


def speaking(a, b, profile):
    """Delay from `a` starting a phrase to `b`'s ring for her lighting up."""
    b.ev("window.__xp.watchLabels(['Vqa, speaking']);")
    mark = b.ev("window.__xp.events.length")
    xp.start_tap(a, "local", remote=False)
    time.sleep(int(os.environ.get("E2E_XP_SPEAK_SECONDS", "45")))
    samples, start, _ = xp.finish_tap(a, "local")
    events = xp.ev_json(b, f"window.__xp.events.slice({mark})")
    return ex.speaking_row(samples, start, events)


def a_timed_experience(server, secret, admin_api, sign_in, room_id):
    e2e_netem.ensure_image()
    directory = xp.out_dir("experience")
    results = {}
    speech_clips = _write_clips(directory, "speech")
    with xp.two_browsers(server, secret, admin_api, sign_in, speech_clips) as (a, b):
        results["joins"] = joins(a, b)
        try:
            results["cut"] = the_cut(a, b)
            print(f"  cut: {results['cut']}")
        finally:
            e2e_netem.clear()
    pulse_clips = _write_clips(directory, "pulse")
    profiles = [p for p in os.environ.get(
        "E2E_XP_PROFILES", "clean,loss5-jitter30,burst").split(",") if p]
    results["speaking"] = {}
    with xp.two_browsers(server, secret, admin_api, sign_in, pulse_clips) as (a, b):
        xp.join(a)
        xp.join(b)
        time.sleep(4)
        try:
            for profile in profiles:
                e2e_netem.apply(profile)
                time.sleep(4)
                results["speaking"][profile] = speaking(a, b, profile)
                print(f"  speaking {profile}: {results['speaking'][profile]}")
        finally:
            e2e_netem.clear()
    with open(os.path.join(directory, "experience.json"), "w") as fh:
        json.dump(results, fh, indent=1)
    cold = results["joins"][0]
    assert cold.get("first_packet_ms") is not None, f"no audio arrived after joining: {cold}"


def run_if_selected(server, secret, admin_api, sign_in, room_id):
    if "voice experience" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='voice experience' to run it")
        return
    a_timed_experience(server, secret, admin_api, sign_in, room_id)
