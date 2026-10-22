# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Shared plumbing for the latency and experience scenarios: two browsers in a call, taps, events."""
import base64
import contextlib
import json
import os
import struct
import time

import e2e_audio
import e2e_browsers
import e2e_labels as L
import e2e_voice_quality_js as vqjs
import e2e_xp_js
from e2e_voice import _tap_label

CHUNK = 1_500_000


def init_script():
    """Raw capture, the stats collector and the timing hooks, in one document script.

    Browser voice processing is off unless E2E_VQ_PROCESSING is set, as in the quality scenario.
    """
    raw = "" if os.environ.get("E2E_VQ_PROCESSING") else vqjs.RAW_CAPTURE_ALL
    return "window.__vqSdp = {};" + vqjs.SDP_TWEAK + raw + vqjs.COLLECT + e2e_xp_js.ALL


def now_ms():
    return time.time() * 1000.0


def ev_json(client, expr):
    return json.loads(client.ev(f"JSON.stringify({expr})") or "null")


@contextlib.contextmanager
def two_browsers(server, secret, admin_api, sign_in, wavs, names=("vqa", "vqb")):
    """Both browsers signed in with the hooks installed; the caller joins the call."""
    for user in names:
        e2e_browsers.register(server, admin_api, user, secret)
    script = init_script()
    with e2e_browsers.browser(names[0], wavs[0]) as one, \
            e2e_browsers.browser(names[1], wavs[1]) as two:
        for client, user in ((one, names[0]), (two, names[1])):
            e2e_audio.install(client, extra=script)
            sign_in(client, server, user, secret)
            e2e_browsers.dismiss_welcome(client)
        try:
            yield one, two
        finally:
            for client in (one, two):
                with contextlib.suppress(Exception):
                    if client.find(L.LEAVE_CALL):
                        _tap_label(client, L.LEAVE_CALL, settle=3)


@contextlib.contextmanager
def one_listener(server, secret, admin_api, sign_in, wav, name="vqb"):
    """One signed-in browser already in the voice channel, with the hooks installed."""
    e2e_browsers.register(server, admin_api, name, secret)
    with e2e_browsers.browser(name, wav) as client:
        e2e_audio.install(client, extra=init_script())
        sign_in(client, server, name, secret)
        e2e_browsers.dismiss_welcome(client)
        join(client)
        try:
            yield client
        finally:
            with contextlib.suppress(Exception):
                if client.find(L.LEAVE_CALL):
                    _tap_label(client, L.LEAVE_CALL, settle=3)


def join(client):
    client.click(L.VOICE_CHANNEL)
    client.wait_for(L.IN_CALL)


def timed_join(client):
    """Clicks the voice channel and returns the page's event log from the click on."""
    mark = client.ev("window.__xp.events.length")
    client.ev("window.__xp.seen = {};")
    client.wait_for(L.VOICE_CHANNEL)
    import e2e_js
    client.ev("window.__xp.log('click');" + e2e_js.click(json.dumps(L.VOICE_CHANNEL.lower())))
    deadline = time.time() + 30
    while time.time() < deadline:
        events = ev_json(client, f"window.__xp.events.slice({mark})")
        names = {e["n"] for e in events}
        labelled = any(e["n"] == "label" and e["on"] and e["text"] == L.IN_CALL
                       for e in events)
        if {"first-packet", "first-energy"} <= names and labelled:
            return events
        time.sleep(0.2)
    return ev_json(client, f"window.__xp.events.slice({mark})")


def wait_remote_audio(client, timeout=60):
    """Blocks until a live remote audio track is playing on the page."""
    probe = ("Array.prototype.some.call(document.querySelectorAll('audio'), function(e){"
             "return e.srcObject && e.srcObject.getAudioTracks().some(function(t){"
             "return t.readyState === 'live'; }); })")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if client.ev(probe):
            return
        time.sleep(0.25)
    raise AssertionError(f"{client.name}: no remote audio track came up")


def start_tap(client, name, remote):
    call = "tapRemote" if remote else "tapLocal"
    client.ev(f"window.__xp.{call}({json.dumps(name)});")
    deadline = time.time() + 15
    while time.time() < deadline:
        tap = ev_json(client, f"(window.__xp.taps[{json.dumps(name)}]"
                      "|| {ready: false, error: ''})")
        assert not tap["error"], f"{client.name}: tap {name}: {tap['error']}"
        if tap["ready"]:
            return
        time.sleep(0.2)
    raise AssertionError(f"{client.name}: tap {name} never came up")


def finish_tap(client, name):
    """`(float samples, start epoch ms, dropped frames)` for a tap started earlier."""
    quoted = json.dumps(name)
    info = ev_json(client, f"window.__xp.finish({quoted})")
    parts, at = [], 0
    while at < info["frames"]:
        count = min(CHUNK, info["frames"] - at)
        parts.append(base64.b64decode(client.ev(f"window.__xp.slice({quoted}, {at}, {count})")))
        at += count
    raw = b"".join(parts)
    ints = struct.unpack(f"<{len(raw) // 2}h", raw)
    dropped = info["missing"]
    return [v / 32768.0 for v in ints], info["startEpoch"], dropped


def save_wav(path, samples, rate=48000):
    import voice_quality_dsp as dsp
    dsp.write_wav(path, samples, rate)


def out_dir(name):
    root = os.environ.get("E2E_VQ_OUT") or os.path.join(e2e_browsers.work_dir(), "voice-quality")
    path = os.path.join(root, name)
    os.makedirs(path, exist_ok=True)
    return path
