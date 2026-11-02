# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What a person waits for: joining a call, the speaking ring, and a network cut.

Measures click to first remote packet and audible energy, the "<name>, speaking" semantics label after long silences, and how the call recovers from a 10 s egress drop (downlink only).
Opt in with E2E_ONLY="voice experience"; E2E_XP_JOINS (default 5, 0 skips) repeats the join.
The cut stage has its own call: E2E_XP_CUTS (default 3,10,30,60 seconds) and E2E_XP_CUT_REPEATS (default 3) shape it.
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
CUTS = os.environ.get("E2E_XP_CUTS", "3,10,30,60")
CUT_REPEATS = int(os.environ.get("E2E_XP_CUT_REPEATS", "3"))
# The ladder rides out a cut this long without a rejoin; longer ones may rejoin by design.
RECOVERABLE_CUT_S = 10
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
    while client.find(L.LEAVE_CALL) and time.time() < deadline:
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


def the_cut(b, cut_seconds):
    """An outage of what the SFU sends; how and when `b` heard `a` again."""
    xp.start_tap(b, "remote", remote=True)
    b.ev("window.__xp.seen = {};")
    mark = b.ev("window.__xp.events.length")
    pcs_before = b.ev("window.__e2eAudio.pcs.length")
    time.sleep(8)
    t_cut = e2e_netem.cut()
    time.sleep(cut_seconds)
    t_back = e2e_netem.restore()
    time.sleep(WATCH_AFTER)
    pcs_after = b.ev("window.__e2eAudio.pcs.length")
    still_in_call = bool(b.find(L.LEAVE_CALL))
    events = xp.ev_json(b, f"window.__xp.events.slice({mark})")
    series = xp.ev_json(b, "window.__xp.series")
    samples, start, dropped = xp.finish_tap(b, "remote")
    xp.save_wav(os.path.join(xp.out_dir("experience"), f"cut-{cut_seconds}s-rx.wav"), samples)
    row = ex.cut_row(samples, start, events, series, t_cut, t_back)
    row.update(cut_seconds=cut_seconds, call_still_open=still_in_call,
               new_peer_connections=pcs_after - pcs_before, dropped_frames=dropped)
    return row


def cuts(a, b):
    """Every planned cut, each from a call that is up (a long one drops both sides); rows grouped by outage length."""
    rows = {}
    for seconds, repeat in ex.cut_plan(CUTS, CUT_REPEATS):
        for client in (a, b):
            if not client.find(L.LEAVE_CALL):
                xp.timed_join(client)
        xp.wait_remote_audio(b)
        row = the_cut(b, seconds)
        rows.setdefault(f"{seconds}s", []).append(row)
        print(f"  cut {seconds}s #{repeat + 1}: {row}")
    return rows


def speaking(a, b):
    """Delay from `a` starting a phrase to `b`'s ring for her lighting up."""
    b.ev(f"window.__xp.watchLabels([{json.dumps('Vqa' + L.SPEAKING)}]);")
    mark = b.ev("window.__xp.events.length")
    xp.start_tap(a, "local", remote=False)
    time.sleep(int(os.environ.get("E2E_XP_SPEAK_SECONDS", "45")))
    samples, start, _ = xp.finish_tap(a, "local")
    events = xp.ev_json(b, f"window.__xp.events.slice({mark})")
    return ex.speaking_row(samples, start, events)


def _representative_cut(rows):
    """The first row of the longest cut the ladder should survive; what experience.json's `cut` reports."""
    fits = [int(k[:-1]) for k in rows if int(k[:-1]) <= RECOVERABLE_CUT_S]
    return rows[f"{max(fits)}s"][0] if fits else None


def problems(results):
    """Why a finished run measured nothing: no audio on join, no resumed packets, or an unlit ring."""
    found = []
    if results["joins"] and results["joins"][0].get("first_packet_ms") is None:
        found.append(f"no audio arrived after joining: {results['joins'][0]}")
    cut = results.get("cut")
    if cut is not None and cut.get("time_to_packets_ms") is None:
        found.append(f"no packets came back after the cut: {cut}")
    clean = results["speaking"].get("clean")
    if clean is not None and not (clean["onsets"] and clean["lit"]):
        found.append(f"the speaking ring never lit for a clean call: {clean}")
    return found


def a_timed_experience(server, secret, admin_api, sign_in):
    e2e_netem.ensure_image()
    directory = xp.out_dir("experience")
    results = {}
    speech_clips = _write_clips(directory, "speech")
    results["joins"] = []
    if JOINS > 0:
        with xp.two_browsers(server, secret, admin_api, sign_in, speech_clips) as (a, b):
            results["joins"] = joins(a, b)
    with xp.two_browsers(server, secret, admin_api, sign_in, speech_clips) as (a, b):
        xp.join(a)
        xp.join(b)
        time.sleep(5)
        try:
            results["cuts"] = cuts(a, b)
        finally:
            e2e_netem.clear()
    results["cut"] = _representative_cut(results["cuts"])
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
                results["speaking"][profile] = speaking(a, b)
                print(f"  speaking {profile}: {results['speaking'][profile]}")
        finally:
            e2e_netem.clear()
    with open(os.path.join(directory, "experience.json"), "w") as fh:
        json.dump(results, fh, indent=1)
    found = problems(results)
    assert not found, "; ".join(found)


def run_if_selected(server, secret, admin_api, sign_in):
    if "voice experience" not in os.environ.get("E2E_ONLY", ""):
        print("  skipped: set E2E_ONLY='voice experience' to run it")
        return
    a_timed_experience(server, secret, admin_api, sign_in)
