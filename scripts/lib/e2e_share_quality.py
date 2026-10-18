# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What a viewer gets from a screen share, with the sender held back.

Bob shares a fake 4K screen to Alice through the real client and a real
LiveKit. Each config in the matrix sets the share tier, a CPU limit (cores
the sender's browser may use, plus Chrome's own CPU throttle), an uplink cap
and the codec, then measures the viewer's received size, frame rate, bitrate
and freezes, and the sender's own layers.

The uplink cap is applied as an encoder maxBitrate, since DevTools network
emulation does not touch RTP and a real shaper needs root. It shows what the
encoder does at that budget, not how bandwidth estimation gets there.

With no E2E_SHARE_MATRIX it runs one uncapped config as a smoke check;
with one, it only records, since a starved sender is the thing being measured.
E2E_SHARE_MATRIX is a JSON list of {name, quality, cores, throttle, cap_mbps,
codec, viewer_px}; E2E_SHARE_OUT names a file the JSON results are appended to.
"""
import contextlib
import json
import os
import subprocess
import time

import e2e_labels as L
import e2e_share_quality_js as js
from e2e_voice import join_call, sfu_participants, tracks_of
import e2e_voice_ui as ui

WARM_SECONDS = int(os.environ.get("E2E_SHARE_WARM", "15"))
MEASURE_SECONDS = int(os.environ.get("E2E_SHARE_MEASURE", "30"))
STEP_SECONDS = 2
QUALITY_KEY = "flutter.slimm.voice.screen_share_quality"
# A 1080p screen with the 2160p tier picked: nothing above 1080p may be published.
DEFAULT_MATRIX = [{"name": "1080p screen, 2160p tier", "quality": "2160p30",
                   "source": [1920, 1080]}]
FITTED_TOP_BITRATE = 5_000_000


def matrix():
    raw = os.environ.get("E2E_SHARE_MATRIX")
    return json.loads(raw) if raw else DEFAULT_MATRIX


def _settings_script(quality, codec, source):
    return (f"window.__shareCodec={json.dumps(codec)};"
            f"window.__shareSourceW={source[0]};window.__shareSourceH={source[1]};"
            f"try{{localStorage.setItem({json.dumps(QUALITY_KEY)},"
            f"JSON.stringify({json.dumps(quality)}));}}catch(e){{}}")


def _wait_probe(client, present, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if str(client.ev("!!window.__shareProbe")).lower() == str(present).lower():
            return
        time.sleep(0.25)
    raise AssertionError(f"{client.name}: share probe presence never became {present}")


def _install(client, quality, codec, source=(3840, 2160)):
    client.send("Page.enable")
    added = client.send("Page.addScriptToEvaluateOnNewDocument", {
        "source": _settings_script(quality, codec, source) + js.SHIM})
    client.send("Page.reload")
    _wait_probe(client, True)
    client.enable_semantics()
    return added["result"]["identifier"]


def _uninstall(client, identifier):
    client.ev(f"localStorage.setItem({json.dumps(QUALITY_KEY)}, '\"1080p30\"')")
    client.send("Page.removeScriptToEvaluateOnNewDocument",
                {"identifier": identifier})
    client.send("Page.reload")
    _wait_probe(client, False)
    client.enable_semantics()


def _chrome_pids(port):
    """The browser on `port` and every process under it."""
    root = subprocess.run(["pgrep", "-f", f"remote-debugging-port={port}"],
                          capture_output=True, text=True).stdout.split()
    table = subprocess.run(["ps", "-eo", "pid=,ppid="], capture_output=True,
                           text=True).stdout.split("\n")
    kids = {}
    for row in table:
        parts = row.split()
        if len(parts) == 2:
            kids.setdefault(parts[1], []).append(parts[0])
    seen, todo = set(), list(root)
    while todo:
        pid = todo.pop()
        if pid not in seen:
            seen.add(pid)
            todo.extend(kids.get(pid, []))
    return sorted(seen)


def _pin(port, cpus):
    for pid in _chrome_pids(port):
        subprocess.run(["taskset", "-a", "-cp", cpus, pid],
                       capture_output=True)


@contextlib.contextmanager
def _sender_limits(client, cfg):
    cores = cfg.get("cores")
    rate = cfg.get("throttle")
    if rate:
        client.send("Emulation.setCPUThrottlingRate", {"rate": rate})
    if cores:
        _pin(client.port, cores)
    try:
        yield
    finally:
        client.send("Emulation.setCPUThrottlingRate", {"rate": 1})
        _pin(client.port, f"0-{os.cpu_count() - 1}")


def _eval_async(client, expr):
    r = client.send("Runtime.evaluate", {"expression": expr,
                                         "awaitPromise": True,
                                         "returnByValue": True})
    return r.get("result", {}).get("result", {}).get("value")


def _read(client, kind):
    return json.loads(_eval_async(
        client, f"window.__shareStats({json.dumps(kind)})") or "[]")


def _delta(first, last, key):
    return (last.get(key) or 0) - (first.get(key) or 0)


def _summarise(series, key_fields):
    """First and last sample per layer to rates over the window."""
    out = {}
    for sample in series:
        for s in sample:
            out.setdefault(key_fields(s), []).append(s)
    rows = {}
    for key, rows_of in out.items():
        first, last = rows_of[0], rows_of[-1]
        seconds = max(((last["timestamp"] - first["timestamp"]) / 1000.0), 0.001)
        frames = "framesDecoded" if "framesDecoded" in last else "framesEncoded"
        bytes_key = "bytesReceived" if "bytesReceived" in last else "bytesSent"
        rows[key] = {
            "size": f"{last.get('frameWidth')}x{last.get('frameHeight')}",
            "fps": round(_delta(first, last, frames) / seconds, 1),
            "mbps": round(_delta(first, last, bytes_key) * 8 / seconds / 1e6, 2),
            "freezes": _delta(first, last, "freezeCount"),
            "freeze_s": round(_delta(first, last, "totalFreezesDuration"), 1),
            "dropped": _delta(first, last, "framesDropped"),
            "codec": last.get("codec"),
            "impl": last.get("encoderImplementation") or last.get("decoderImplementation"),
            "limit": last.get("qualityLimitationReason"),
            "limit_s": {k: round(v, 1) for k, v in (last.get("qualityLimitationDurations") or {}).items()},
            "active": last.get("active"),
            "ssrc": last.get("ssrc"),
            "target_mbps": round((last.get("targetBitrate") or 0) / 1e6, 2),
        }
    return rows


def measure(viewer, sender, cfg):
    cap = cfg.get("cap_mbps")
    inbound, outbound = [], []
    deadline = time.time() + MEASURE_SECONDS
    while time.time() < deadline:
        if cap:
            _eval_async(sender, f"window.__shareCap({int(cap * 1e6)})")
        inbound.append(_read(viewer, "in"))
        outbound.append(_read(sender, "out"))
        time.sleep(STEP_SECONDS)
    return {
        "viewer": _summarise(inbound, lambda s: "in"),
        "sender": _summarise(outbound, lambda s: s.get("rid") or "f"),
    }


def _one(a, b, room_id, bob_id, cfg):
    quality = cfg.get("quality", "1080p30")
    ids = []
    for c in (a, b):
        ids.append(_install(c, quality, cfg.get("codec", ""),
                            tuple(cfg.get("source", (3840, 2160)))))
    px = cfg.get("viewer_px", 2560)
    a.send("Emulation.setDeviceMetricsOverride", {
        "width": px, "height": px * 9 // 16, "deviceScaleFactor": 1,
        "mobile": False})
    try:
        join_call(a, b, room_id)
        with _sender_limits(b, cfg):
            b.click(L.SHARE_SCREEN, settle=6)
            deadline = time.time() + 45
            while time.time() < deadline and not any(
                    p["identity"] == bob_id and tracks_of(p, "SCREEN_SHARE")
                    for p in sfu_participants(room_id)):
                time.sleep(1)
            if cfg.get("cores"):
                _pin(b.port, cfg["cores"])
            time.sleep(WARM_SECONDS)
            result = measure(a, b, cfg)
        result["asked"] = b.ev("window.__shareProbe.asked")
        result["encodings"] = json.loads(b.ev("window.__shareParams()") or "[]")
        result["config"] = cfg
        return result
    finally:
        a.send("Emulation.clearDeviceMetricsOverride")
        if b.find(L.STOP_SHARING):
            b.click(L.STOP_SHARING, settle=4)
        ui.leave_if_in_call(a, b)
        for c, i in zip((a, b), ids):
            with contextlib.suppress(Exception):
                _uninstall(c, i)


def _assert_fitted(cfg, result):
    """The top layer is sized and budgeted for the screen, not for the tier."""
    source = cfg.get("source")
    if not source or source[1] >= 2160:
        return
    top = max(result["encodings"], key=lambda e: e["maxBitrate"] or 0)
    assert top["maxBitrate"] <= FITTED_TOP_BITRATE, \
        f"{cfg['name']}: top layer budget {top['maxBitrate']} for a {source[1]}p screen"
    sizes = [v["size"] for v in result["sender"].values()
             if v["active"] and "None" not in v["size"]]
    wide = [int(z.split("x")[0]) for z in sizes]
    assert wide and max(wide) <= source[0], \
        f"{cfg['name']}: published {sizes} from a {source[0]}-wide screen"


def share_quality_under_a_constrained_sender(a, b, room_id, bob_id):
    out = os.environ.get("E2E_SHARE_OUT")
    for cfg in matrix():
        print(f"  config {cfg}")
        result = _one(a, b, room_id, bob_id, cfg)
        line = json.dumps(result)
        print("SHARE-QUALITY " + line)
        if out:
            with open(out, "a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        if os.environ.get("E2E_SHARE_MATRIX"):
            continue
        seen = result["viewer"].get("in")
        assert seen, f"{cfg['name']}: the viewer never received share video"
        assert seen["fps"] > 0.5, f"{cfg['name']}: the viewer decoded {seen['fps']} fps"
        assert seen["mbps"] > 0.05, \
            f"{cfg['name']}: the viewer measured {seen['mbps']} Mbps"
        _assert_fitted(cfg, result)
        top = [v for v in result["sender"].values() if v["active"]]
        assert top, f"{cfg['name']}: no outgoing layer was sending"
