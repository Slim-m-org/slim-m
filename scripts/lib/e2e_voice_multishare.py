# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Three people, two screen shares at once, judged by decoded video.

Alice and bob share while carol, a third browser, only watches. Carol must see
both streams as decoded, non-black video; focusing one and returning to all
must work; and when one sharer stops the other must carry on. Each sharer
decodes their own preview and the other's share.
"""
import os
import time

import e2e_audio
import e2e_browsers
import e2e_labels as L
import e2e_voice_ui as ui
from e2e_voice import join_call, sfu_participants, tracks_of

# A frame whose mean luminance is below this is treated as black.
NOT_BLACK_MEAN = 4.0
FOCUS = "Focus this share"
SHOW_ALL = "Show all shares"


def _sharing(room_id):
    return [p["identity"] for p in sfu_participants(room_id)
            if tracks_of(p, "SCREEN_SHARE")]


def _wait_sharing(room_id, count, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if len(_sharing(room_id)) == count:
            return
        time.sleep(1)
    raise AssertionError(
        f"expected {count} sharer(s) at the SFU, saw {len(_sharing(room_id))}")


def live_videos(probe):
    """The page's decoded, non-black videos."""
    return [v for v in probe.videos()
            if v["width"] > 0 and v["frames"] > 0 and v["mean"] > NOT_BLACK_MEAN]


def wait_for_videos(probe, count, timeout=45):
    deadline = time.time() + timeout
    seen = []
    while time.time() < deadline:
        seen = live_videos(probe)
        if len(seen) == count:
            return seen
        time.sleep(1)
    raise AssertionError(
        f"{probe.client.name}: expected {count} live video(s), saw "
        f"{len(seen)} of {probe.videos()}")


def _area(video):
    return video["boxW"] * video["boxH"]


def two_shares_reach_a_third_viewer(a, b, server, secret, admin_api,
                                    sign_in, room_id, bob_id):
    e2e_browsers.register(server, admin_api, "carol", secret)
    wav = os.path.join(os.environ.get("E2E_WORK", "/tmp/e2e"), "fake-voice.wav")
    e2e_audio.install(a)
    e2e_audio.install(b)
    with e2e_browsers.browser("carol", wav) as c:
        e2e_audio.install(c)
        sign_in(c, server, "carol", secret)
        e2e_browsers.dismiss_welcome(c)
        join_call(a, b, room_id)
        c.click(L.VOICE_CHANNEL)
        c.wait_for("3 in call")
        pa, pb, pc = (e2e_audio.AudioProbe(x) for x in (a, b, c))
        try:
            a.click(L.SHARE_SCREEN, settle=6)
            b.click(L.SHARE_SCREEN, settle=6)
            _wait_sharing(room_id, 2)
            seen = wait_for_videos(pc, 2)
            print("  carol decodes both shares: "
                  + ", ".join(f"{v['width']}x{v['height']} mean {v['mean']:.0f}"
                              for v in seen))
            c.wait_for("Alice's screen")
            c.wait_for("Bob's screen")
            mine, theirs = wait_for_videos(pa, 2), wait_for_videos(pb, 2)
            print(f"  alice and bob each decode {len(mine)} videos: their own "
                  f"preview and the other's share ({len(theirs)})")

            before = max(_area(v) for v in pc.videos())
            c.click(FOCUS, settle=2)
            c.wait_for(SHOW_ALL)
            after = max(_area(v) for v in pc.videos())
            print(f"  focusing one share: largest video {before} -> {after} px")
            assert after > before * 1.1, "focusing a share did not enlarge it"
            c.click(SHOW_ALL, settle=2)
            c.wait_for(FOCUS)
            wait_for_videos(pc, 2)
            print("  and showing all shares puts both back")

            a.click(L.STOP_SHARING, settle=4)
            _wait_sharing(room_id, 1)
            left = wait_for_videos(pc, 1)
            print(f"  alice stopped: carol still decodes {len(left)} share "
                  f"(frames {left[0]['frames']})")
            assert _sharing(room_id) == [bob_id], _sharing(room_id)
        finally:
            for who in (a, b):
                if who.find(L.STOP_SHARING):
                    who.click(L.STOP_SHARING, settle=3)
            ui.leave_if_in_call(a, b, c)
