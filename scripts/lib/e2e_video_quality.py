# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Watching quality, changed from the call's share menu and kept.

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
_STORE_KEY = "flutter.slimm.voice.receive_video_quality"


def _stored_quality(client):
    return client.ev(
        f"JSON.parse(localStorage.getItem('{_STORE_KEY}') || 'null')")


def watching_quality_from_the_share_menu(client, room_id):
    client.click(L.VOICE_CHANNEL)
    client.wait_for(L.IN_CALL)
    try:
        before = _stored_quality(client)
        client.click(L.SHARE_OPTIONS, settle=2)
        client.wait_for(L.WATCHING_QUALITY)
        client.shot("quality-menu")
        client.click(L.DATA_SAVER, settle=2)
        stored = _stored_quality(client)
        assert stored == "dataSaver", \
            f"nothing durable recorded the choice: {before!r} -> {stored!r}"
        print("  Data saver was chosen from the share menu, and stored")
    finally:
        _tap_label(client, L.LEAVE_CALL, settle=4)

    client.click(L.PERSONAL_SETTINGS, settle=3)
    client.click(L.VOICE_PANE, settle=2)
    client.wait_for(L.WATCHING_QUALITY)
    client.shot("quality-in-voice-settings")
    picked = json.loads(client.ev(_SELECTED_SEGMENTS))
    rows = [p for p in picked if p in ("Auto", "Balanced", "Data saver",
                                       "High", "Smooth", "Crisp")]
    assert rows[:3] == ["Data saver", "Balanced", "Balanced"], \
        f"Voice settings does not show the menu's choice: {picked}"
    print("  Voice settings shows Watching on Data saver, the rest untouched")

    # Back to the default, so later calls in this run subscribe at full quality.
    client.click(L.AUTO_QUALITY, settle=1.5)
    assert _stored_quality(client) == "auto", _stored_quality(client)
