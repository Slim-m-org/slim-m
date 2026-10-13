# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Share resolution and frame rate, changed from the call's share menu and kept.

The same choice lives in Voice settings, written through one notifier, so a
change made mid-call must show there afterwards and survive in the browser's
own storage. One client is enough: nothing here depends on a second person.
"""
import json

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
    client.wait_for(L.SHARE_RESOLUTION_ROW)
    client.shot("quality-in-voice-settings")
    picked = json.loads(client.ev(_SELECTED_SEGMENTS))
    rows = [p for p in picked if p in ("Auto", "Balanced", "Data saver",
                                       "360p", "720p", "1080p", "1440p",
                                       "15 fps", "30 fps", "60 fps")]
    assert rows[-2:] == ["1440p", "60 fps"], \
        f"Voice settings does not show the menu's choice: {picked}"
    print("  Voice settings shows the share at 1440p and 60 fps")

    # Back to the default, so the share later in this run keeps its old cost.
    client.click(L.RES_1080P, settle=1.5)
    client.click(L.FPS_30, settle=1.5)
    assert _stored_quality(client) == "1080p30", _stored_quality(client)
