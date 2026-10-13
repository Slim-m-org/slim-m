# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Share resolution and frame rate, changed from the call's share menu and kept.

The same choice lives in Voice settings, written through one notifier, so a
change made mid-call must show there afterwards and survive in the browser's
own storage. One client is enough: nothing here depends on a second person.
"""
import json
import time

import e2e_labels as L
from e2e_voice import _tap_label

# The picked segment of each quality row, top to bottom: Flutter marks it aria-current.
_SELECTED_SEGMENTS = """
JSON.stringify(Array.from(document.querySelectorAll('flt-semantics'))
  .filter(function(e){return e.getAttribute('aria-current') === 'true';})
  .map(function(e){return [Math.round(e.getBoundingClientRect().y),
                           (e.getAttribute('aria-label') || e.textContent || '').trim()];})
  .sort(function(a, b){return a[0] - b[0];})
  .map(function(p){return p[1];}))"""
_STORE_KEY = "flutter.slimm.voice.screen_share_quality"


def _stored_quality(client):
    return client.ev(
        f"JSON.parse(localStorage.getItem('{_STORE_KEY}') || 'null')")


def _wheel_until(client, anchor, target, step=300, tries=6):
    """Scrolls the pane under `anchor` until `target` is on screen.

    Flutter web builds no semantics for a row scrolled out of view, so the
    frame rate row at the bottom of the card is invisible until it is reached.
    """
    at = client.wait_for(anchor)
    # The anchor can already have semantics below the fold, so wheel over the visible part of its pane.
    y = min(at["y"], client.ev("window.innerHeight") * 0.6)
    for _ in range(tries):
        if client.find(target):
            return
        client.send("Input.dispatchMouseEvent",
                    {"type": "mouseWheel", "x": at["x"], "y": y,
                     "deltaX": 0, "deltaY": step})
        time.sleep(0.8)
    client.wait_for(target)


def _tap_lowest(client, label, settle=1.5):
    """Taps the lowest exact `label` on screen: camera and share rows both offer 1080p, and the share row is last."""
    hits = [n for n in client.nodes() if n["t"].strip().lower() == label.lower()]
    assert hits, f"never saw {label!r}"
    lowest = max(hits, key=lambda n: n["y"])
    client.tap(lowest["x"], lowest["y"])
    time.sleep(settle)


def share_quality_from_the_share_menu(client, room_id):
    client.click(L.VOICE_CHANNEL)
    client.wait_for(L.IN_CALL)
    try:
        before = _stored_quality(client)
        client.click(L.SHARE_OPTIONS, settle=2)
        client.wait_for(L.SHARE_RESOLUTION_HEADING)
        client.shot("quality-menu")
        client.click(L.RES_1440P, settle=2)
        client.click(L.SHARE_OPTIONS, settle=2)
        client.click(L.FPS_60, settle=2)
        stored = _stored_quality(client)
        assert stored == "1440p60", \
            f"nothing durable recorded the choice: {before!r} -> {stored!r}"
        print("  1440p at 60 fps was chosen from the share menu, and stored")
    finally:
        _tap_label(client, L.LEAVE_CALL, settle=4)

    client.click(L.PERSONAL_SETTINGS, settle=3)
    client.click(L.VOICE_PANE, settle=2)
    _wheel_until(client, L.SHARE_RESOLUTION_ROW, L.FPS_60)
    client.shot("quality-in-voice-settings")
    picked = json.loads(client.ev(_SELECTED_SEGMENTS))
    rows = [p for p in picked if p in ("Auto", "Balanced", "Data saver",
                                       "360p", "720p", "1080p", "1440p",
                                       "15 fps", "30 fps", "60 fps")]
    assert rows[-2:] == ["1440p", "60 fps"], \
        f"Voice settings does not show the menu's choice: {picked}"
    print("  Voice settings shows the share at 1440p and 60 fps")

    # Back to the default, so the share later in this run keeps its old cost.
    _tap_lowest(client, L.RES_1080P)
    client.click(L.FPS_30, settle=1.5)
    assert _stored_quality(client) == "1080p30", _stored_quality(client)
