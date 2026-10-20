# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A share nobody can see is not received, and is received again when seen.

Alice shares; bob watches. Hiding the stream, hiding the whole page, and
leaving for a text channel must each stop bob's decoder (the browser's own
inbound frame counter stops growing), and the reverse action must bring the
video back as decoded, non-black frames. The mini-player carries it while bob
is in the text channel and returns him to the call when tapped.
"""
import time

import e2e_audio
import e2e_labels as L
import e2e_voice_ui as ui
from e2e_voice import join_call
from e2e_voice_multishare import (
    HIDDEN_WINDOW_SECONDS, _share_sids, _wait_sharing, wait_for_videos)

# The cull's 3s dwell plus LiveKit's 1.5s settings debounce, with a margin.
DWELL_SECONDS = 6

_VISIBILITY = """
(function(visible){
  var state = visible ? 'visible' : 'hidden';
  Object.defineProperty(document, 'visibilityState',
                        {configurable: true, get: function(){ return state; }});
  Object.defineProperty(document, 'hidden',
                        {configurable: true, get: function(){ return !visible; }});
  document.dispatchEvent(new Event('visibilitychange'));
})(%s)"""


def _set_page_visible(client, visible):
    client.ev(_VISIBILITY % ("true" if visible else "false"))


def _decoding_now(probe, seconds=HIDDEN_WINDOW_SECONDS):
    """How many inbound videos decoded more than a stray frame over `seconds`."""
    first = probe.inbound_frames()
    time.sleep(seconds)
    after = probe.inbound_frames()
    return [k for k, n in after.items() if n - first.get(k, 0) > 5]


def _assert_nothing_decodes(probe, why, settle=0):
    """Nothing decodes after `settle` seconds, which outwaits the cull's dwell."""
    time.sleep(settle)
    growing = _decoding_now(probe)
    print(f"  {why}: {len(growing)} inbound video(s) still decoding")
    assert not growing, f"{why}: still receiving {growing}"


def hiding_and_showing_a_stream(a, b, room_id):
    with e2e_audio.installed(a), e2e_audio.installed(b):
        join_call(a, b, room_id)
        pb = e2e_audio.AudioProbe(b)
        try:
            _hide_show_and_unseen(a, b, pb, room_id)
        finally:
            _set_page_visible(b, True)
            if a.find(L.STOP_SHARING):
                a.click(L.STOP_SHARING, settle=3)
            ui.leave_if_in_call(a, b)


def _hide_show_and_unseen(a, b, pb, room_id):
    a.click(L.SHARE_SCREEN, settle=6)
    _wait_sharing(room_id, 1)
    sids = list(_share_sids(room_id).values())
    wait_for_videos(pb, sids, 1)
    print("  bob decodes alice's share")

    ui.open_tile_menu(b, "Alice")
    b.click(L.HIDE_STREAM, settle=3)
    _assert_nothing_decodes(pb, "hidden stream")

    ui.open_tile_menu(b, "Alice")
    b.wait_for(L.SHOW_STREAM)
    b.click(L.SHOW_STREAM, settle=3)
    wait_for_videos(pb, sids, 1)
    print("  Show stream from alice's menu brings the video back")

    _set_page_visible(b, False)
    _assert_nothing_decodes(pb, "page hidden", settle=DWELL_SECONDS)
    _set_page_visible(b, True)
    wait_for_videos(pb, sids, 1)
    print("  and showing the page again resumes it")

    b.click(L.TEXT_CHANNEL, settle=4)
    b.wait_for(L.RETURN_TO_CALL)
    wait_for_videos(pb, sids, 1)
    print("  the mini-player carries the share in a text channel")
    b.click(L.RETURN_TO_CALL, settle=3)
    b.wait_for(L.IN_CALL)
    wait_for_videos(pb, sids, 1)
    print("  tapping it returns to the call with the share still decoding")
