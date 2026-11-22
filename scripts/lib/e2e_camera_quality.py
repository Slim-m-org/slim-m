# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What a published camera really sends, and what a mid-call quality change does to it.

Bob turns on his camera (Chrome's fake video device) at the default 720p, then picks 360p and 1080p from the camera menu while the call runs.
Per setting it reads Bob's own simulcast layers and Alice's decoded video from the peer connections: layer sizes, frame rate, freezes.
The gap after each change is the longest stretch Alice decoded nothing from the click on; it is recorded and bounded, never assumed.
E2E_CAMERA_SECONDS sets the measuring window per setting, E2E_CAMERA_GAP_MAX the gap bound in seconds, E2E_CAMERA_OUT a file the JSON is appended to.
"""
import json
import os
import time

import e2e_camera_quality_js as js
import e2e_labels as L
from e2e_voice import join_call, sfu_participants, tracks_of
import e2e_voice_ui as ui

MEASURE_SECONDS = float(os.environ.get("E2E_CAMERA_SECONDS", "10"))
GAP_MAX_SECONDS = float(os.environ.get("E2E_CAMERA_GAP_MAX", "10"))
STEP_SECONDS = 0.25
# The restart waits 700 ms to settle a burst of changes, then republishes.
CHANGE_SECONDS = 14
SETTLE_SECONDS = 5
# The 360p top layer is LiveKit's h360 preset, capped at 20 fps whatever the capture rate.
MIN_FPS = {"360p": 18.0, "720p": 25.0, "1080p": 25.0}
# A shared CI runner decodes in software and measured 22 fps on a healthy call; freezes catch stutter.
MIN_VIEWER_FPS = 15.0
# Layer heights each camera quality publishes: a 180p and a 360p below the top, or just the 180p under a 360p top.
EXPECTED_HEIGHTS = {"360p": [180, 360], "720p": [180, 360, 720], "1080p": [180, 360, 1080]}
CAMERA_ON = "Turn on camera"
CAMERA_OPTIONS = "Camera options"
# The call's default, so the first measurement needs no change.
RECEIVE_KEY = "flutter.slimm.voice.receive_video_quality"
ORDER = ["720p", "360p", "1080p"]


def _growth(samples, kind, key):
    """Per stream (ssrc) how far `key` moved from its first to its last sighting."""
    first, last = {}, {}
    for sample in samples:
        for s in sample[kind]:
            ssrc = s.get("ssrc")
            first.setdefault(ssrc, s)
            last[ssrc] = s
    return {ssrc: (first[ssrc], last[ssrc], (last[ssrc].get(key) or 0) - (first[ssrc].get(key) or 0))
            for ssrc in last}


def _span(samples):
    return max(samples[-1]["t"] - samples[0]["t"], 0.001)


def live_layers(samples):
    """Sender layers that encoded frames in the window, as sorted (rid, width, height)."""
    grown = _growth(samples, "out", "framesEncoded")
    rows = [(last.get("rid") or "f", last.get("frameWidth") or 0, last.get("frameHeight") or 0)
            for _, last, delta in grown.values() if delta > 0]
    return sorted(rows, key=lambda r: r[2])


def top_layer_fps(samples):
    grown = _growth(samples, "out", "framesEncoded")
    live = [(last.get("frameHeight") or 0, delta) for _, last, delta in grown.values() if delta > 0]
    return round(max(live)[1] / _span(samples), 1) if live else 0.0


def viewer_fps(samples):
    grown = _growth(samples, "in", "framesDecoded")
    return round(sum(delta for *_, delta in grown.values()) / _span(samples), 1)


def viewer_freezes(samples):
    return sum(delta for *_, delta in _growth(samples, "in", "freezeCount").values())


def _decoded_total(sample, seen):
    for s in sample["in"]:
        seen[s.get("ssrc")] = max(seen.get(s.get("ssrc"), 0), s.get("framesDecoded") or 0)
    return sum(seen.values())


def restart_gap(samples):
    """Longest time the viewer went without a newly decoded frame, over the samples given."""
    seen, total, last_frame_at, gap = {}, None, None, 0.0
    for sample in samples:
        now = _decoded_total(sample, seen)
        if total is None:
            total, last_frame_at = now, sample["t"]
            continue
        if now > total:
            gap = max(gap, sample["t"] - last_frame_at)
            total, last_frame_at = now, sample["t"]
    if last_frame_at is not None:
        gap = max(gap, samples[-1]["t"] - last_frame_at)
    return round(gap, 2)


def applied_after(samples, heights):
    """Seconds until the layers encoding over the last second were exactly `heights`, or None."""
    lag = round(1 / STEP_SECONDS)
    for i in range(lag, len(samples)):
        if [h for _, _, h in live_layers(samples[i - lag:i + 1])] == heights:
            return round(samples[i]["t"] - samples[0]["t"], 2)
    return None


def problems(quality, samples):
    """Why one setting's measurement fails, empty when it holds."""
    found = []
    heights = [h for _, _, h in live_layers(samples)]
    if heights != EXPECTED_HEIGHTS[quality]:
        found.append(f"{quality}: layers {heights}, expected {EXPECTED_HEIGHTS[quality]}")
    floor = MIN_FPS[quality]
    if top_layer_fps(samples) < floor:
        found.append(f"{quality}: top layer encoded {top_layer_fps(samples)} fps, under {floor}")
    if viewer_fps(samples) < MIN_VIEWER_FPS:
        found.append(f"{quality}: the viewer decoded {viewer_fps(samples)} fps, under {MIN_VIEWER_FPS}")
    if viewer_freezes(samples):
        found.append(f"{quality}: the viewer froze {viewer_freezes(samples)} times")
    return found


def sample_for(a, b, seconds):
    """Both pages' video stats every STEP_SECONDS, stamped from the first call."""
    rows, start = [], time.time()
    while time.time() - start < seconds:
        tick = time.time()
        rows.append({"t": round(tick - start, 3),
                     "out": json.loads(_stats(b, "out")), "in": json.loads(_stats(a, "in"))})
        time.sleep(max(0.0, STEP_SECONDS - (time.time() - tick)))
    return rows


def _stats(client, kind):
    r = client.send("Runtime.evaluate", {"expression": f"window.__camStats({json.dumps(kind)})",
                                         "awaitPromise": True, "returnByValue": True})
    return r.get("result", {}).get("result", {}).get("value") or "[]"


def _camera_published(room_id, bob_id, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if any(p["identity"] == bob_id and tracks_of(p, "CAMERA") for p in sfu_participants(room_id)):
            return
        time.sleep(0.25)
    raise AssertionError("bob's camera never reached the SFU")


def _measure(a, b, quality):
    time.sleep(SETTLE_SECONDS)
    samples = sample_for(a, b, MEASURE_SECONDS)
    layers = live_layers(samples)
    row = {"quality": quality, "layers": layers, "top_fps": top_layer_fps(samples),
           "viewer_fps": viewer_fps(samples), "freezes": viewer_freezes(samples),
           "capture": json.loads(b.ev("window.__camSettings()") or "[]"),
           "encodings": json.loads(b.ev("window.__camParams()") or "[]")}
    print("CAMERA-QUALITY " + json.dumps(row), flush=True)
    return row, samples


def _change_quality(a, b, quality):
    """Picks `quality` in bob's camera menu and samples from the click on."""
    b.click(CAMERA_OPTIONS, settle=1.5)
    b.wait_for(quality)
    b.click(quality, settle=0)
    samples = sample_for(a, b, CHANGE_SECONDS)
    b.dismiss_overlay()
    return samples


def _watch_at_max(client, value):
    """Alice asks for the sharpest layer, so the SFU keeps every one of Bob's layers encoding."""
    client.ev(f"localStorage.setItem({json.dumps(RECEIVE_KEY)}, {json.dumps(json.dumps(value))})")
    client.send("Page.reload")
    client.enable_semantics()


def a_camera_publishes_its_layers_and_changes_quality(a, b, room_id, bob_id):
    _watch_at_max(a, "max")
    for c in (a, b):
        c.ev(js.SHIM)
    rows, failures = [], []
    try:
        join_call(a, b, room_id)
        b.click(CAMERA_ON, settle=3)
        _camera_published(room_id, bob_id)
        row, samples = _measure(a, b, "720p")
        rows.append(row)
        failures += problems("720p", samples)
        for quality in ORDER[1:]:
            samples = _change_quality(a, b, quality)
            row = {"quality": quality, "gap_s": restart_gap(samples),
                   "applied_s": applied_after(samples, EXPECTED_HEIGHTS[quality])}
            print("CAMERA-RESTART " + json.dumps(row), flush=True)
            rows.append(row)
            settled, tail = _measure(a, b, quality)
            rows.append(settled)
            failures += problems(quality, tail)
            if row["applied_s"] is None:
                failures.append(f"{quality}: the layers never became {EXPECTED_HEIGHTS[quality]} after the change")
            if row["gap_s"] > GAP_MAX_SECONDS:
                failures.append(f"{quality}: the viewer went {row['gap_s']}s without a frame")
    finally:
        out = os.environ.get("E2E_CAMERA_OUT")
        if out:
            with open(out, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rows) + "\n")
        if b.find("Turn off camera"):
            b.click("Turn off camera", settle=2)
        ui.leave_if_in_call(a, b)
        for c in (a, b):
            c.ev(js.UNINSTALL)
        _watch_at_max(a, "auto")
    assert not failures, "; ".join(failures)
