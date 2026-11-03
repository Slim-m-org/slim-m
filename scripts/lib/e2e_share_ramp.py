# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""How long a screen share takes to reach full resolution at a viewer after the sender clicks share.

Bob joins the call, then shares a heavy-motion 1920x1080 screen; both pages sample their peer connections once a second from the click.
The result is the sender's summed target bitrate and the viewer's frame size per second, and the first second the viewer saw 1080 lines.
E2E_SHARE_RAMP_SECONDS sets the window, E2E_SHARE_RAMP_OUT names a file the JSON is appended to, and E2E_SHARE_RAMP_UPLINK_MBIT polices the sender's uplink to measure a slow link (no assertion then).
"""
import json
import os
import time

import e2e_labels as L
import e2e_netem
import e2e_share_quality as sq
import e2e_share_quality_js as js
from e2e_voice import join_call, sfu_participants, tracks_of
import e2e_voice_ui as ui

WINDOW_SECONDS = int(os.environ.get("E2E_SHARE_RAMP_SECONDS", "20"))
FULL_HEIGHT = 1080
BUDGET_SECONDS = float(os.environ.get("E2E_SHARE_RAMP_BUDGET", "10"))


def first_full_second(heights, full=FULL_HEIGHT):
    """Index of the first sample whose frame height reached [full], or None."""
    for second, height in enumerate(heights):
        if height and height >= full:
            return second
    return None


def summed_target_mbps(layers):
    return round(sum(layer.get("targetBitrate") or 0 for layer in layers) / 1e6, 2)


def viewer_height(layers):
    return max([layer.get("frameHeight") or 0 for layer in layers] or [0])


def sample_series(viewer, sender, seconds):
    """One sample per second: (elapsed, sender target Mbps, bytes sent, viewer frame height)."""
    rows = []
    start = time.time()
    while time.time() - start < seconds:
        tick = time.time()
        out = sq._read(sender, "out")
        seen = sq._read(viewer, "in")
        rows.append({"t": round(tick - start, 1), "target_mbps": summed_target_mbps(out),
                     "sent_bytes": sum(layer.get("bytesSent") or 0 for layer in out),
                     "viewer_h": viewer_height(seen),
                     "viewer_lost": sum(layer.get("packetsLost") or 0 for layer in seen),
                     "viewer_freezes": sum(layer.get("freezeCount") or 0 for layer in seen)})
        time.sleep(max(0.0, 1.0 - (time.time() - tick)))
    return rows


def _install(client):
    client.send("Page.enable")
    script = ("window.__shareHeavy=true;" + sq._settings_script("1080p60", "", (1920, 1080)) + js.SHIM
              + os.environ.get("E2E_SHARE_RAMP_JS", ""))
    added = client.send("Page.addScriptToEvaluateOnNewDocument", {"source": script})
    client.send("Page.reload")
    sq._wait_probe(client, True)
    client.enable_semantics()
    return added["result"]["identifier"]


def measure_ramp(a, b, room_id):
    ids = [_install(c) for c in (a, b)]
    a.send("Emulation.setDeviceMetricsOverride", {"width": 1920, "height": 1080, "deviceScaleFactor": 1, "mobile": False})
    try:
        join_call(a, b, room_id)
        limit = float(os.environ.get("E2E_SHARE_RAMP_UPLINK_MBIT", "0"))
        if limit:
            e2e_netem.ensure_image()
            e2e_netem.limit_uplink(limit)
        b.click(L.SHARE_SCREEN, settle=0)
        rows = sample_series(a, b, WINDOW_SECONDS)
        if os.environ.get("E2E_SHARE_RAMP_JS"):
            print("ANSWERS", b.ev("JSON.stringify(window.__answers||null)"), b.ev("String(window.__answerErr)"), flush=True)
        return rows
    finally:
        if os.environ.get("E2E_SHARE_RAMP_UPLINK_MBIT"):
            e2e_netem.clear_uplink()
        a.send("Emulation.clearDeviceMetricsOverride")
        if b.find(L.STOP_SHARING):
            b.click(L.STOP_SHARING, settle=4)
        ui.leave_if_in_call(a, b)
        for c, i in zip((a, b), ids):
            try:
                sq._uninstall(c, i)
            except Exception:
                pass


def a_share_reaches_full_resolution_quickly(a, b, room_id):
    rows = measure_ramp(a, b, room_id)
    reached = first_full_second([r["viewer_h"] for r in rows])
    line = json.dumps({"rows": rows, "full_at": rows[reached]["t"] if reached is not None else None})
    print("SHARE-RAMP " + line, flush=True)
    out = os.environ.get("E2E_SHARE_RAMP_OUT")
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    assert reached is not None, f"the viewer never saw {FULL_HEIGHT} lines in {WINDOW_SECONDS} s"
    assert rows[reached]["t"] <= BUDGET_SECONDS, f"the viewer needed {rows[reached]['t']} s for {FULL_HEIGHT} lines"
