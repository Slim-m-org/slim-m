# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Three people, two screen shares at once, judged by decoded video.

Alice and bob share while carol, a third browser, only watches. Carol must see
both streams as decoded, non-black video; focusing one and returning to all
must work; and when one sharer stops the other must carry on. Each sharer
decodes their own preview and the other's share.

A video counts only if it is a share tile, decodes new frames across two
samples, and is not black: measured in the headless capture (2026-10-18,
960x540 on a 32x18 luminance grid) a live share has mean 100-104 and spread
16-25, a black frame has mean 0 and spread 0. The bars sit a fifth of the way
up, so a dim real share passes and a black or flat-filled tile does not.
"""
import os
import time

import e2e_audio
import e2e_browsers
import e2e_labels as L
import e2e_voice_ui as ui
from e2e_voice import join_call, sfu_participants, tracks_of

NOT_BLACK_MEAN = 20.0  # live share 100-104, black 0
MIN_SPREAD = 4.0  # live share 16-25, flat fill 0
FOCUS = "Focus this share"
SHOW_ALL = "Show all shares"
# A video must decode new frames across this long to count as live.
FRESH_SECONDS = 2.0
# Longer than the cull's 3s dwell plus LiveKit's 1.5s settings debounce.
HIDDEN_WINDOW_SECONDS = 4.0
HIDDEN_FRAMES_TOLERATED = 5


def _sharing(room_id):
    return [p["identity"] for p in sfu_participants(room_id)
            if tracks_of(p, "SCREEN_SHARE")]


def _share_sids(room_id):
    """{identity: SCREEN_SHARE track sid} as the SFU reports them."""
    return {p["identity"]: tracks_of(p, "SCREEN_SHARE")[0]["sid"]
            for p in sfu_participants(room_id) if tracks_of(p, "SCREEN_SHARE")}


def _wait_sharing(room_id, count, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if len(_sharing(room_id)) == count:
            return
        time.sleep(1)
    raise AssertionError(
        f"expected {count} sharer(s) at the SFU, saw {len(_sharing(room_id))}")


def share_tiles(videos, sids):
    """Only the share tiles: a remote track the SFU names as a known share (its msid), or a local capture."""
    return [v for v in videos
            if v.get("display") or any(sid in v.get("sfu", "") for sid in sids)]


def _decoding(v):
    return (v["width"] > 0 and v["frames"] > 0 and v["mean"] > NOT_BLACK_MEAN
            and v["spread"] > MIN_SPREAD)


def live_videos(probe, sids, fresh_seconds=FRESH_SECONDS):
    """Share tiles that decode non-black frames and keep decoding new ones.

    Two samples `fresh_seconds` apart: a frozen last frame has frames > 0 and
    a bright mean forever, so only an increasing decoded-frame count is alive.
    """
    first = {v["index"]: v for v in share_tiles(probe.videos(), sids)}
    time.sleep(fresh_seconds)
    live = []
    for v in share_tiles(probe.videos(), sids):
        was = first.get(v["index"])
        if _decoding(v) and was and v["frames"] > was["frames"] \
                and was["stream"] == v["stream"]:
            live.append(v)
    return live


def wait_for_videos(probe, sids, count, timeout=45):
    deadline = time.time() + timeout
    seen = []
    while time.time() < deadline:
        seen = live_videos(probe, sids)
        if len(seen) == count:
            streams = [v["stream"] for v in seen]
            assert len(set(streams)) == count, \
                f"{probe.client.name}: {count} tiles but streams {streams}: " \
                f"one stream rendered more than once"
            return seen
    raise AssertionError(
        f"{probe.client.name}: expected {count} live video(s), saw "
        f"{len(seen)} of {probe.videos()}")


def _area(video):
    return video["boxW"] * video["boxH"]


def _hidden_shares_stop_decoding(c, pc, every):
    """In a text channel nothing shows a share, so none is received or decoded."""
    c.click(L.TEXT_CHANNEL, settle=8)
    first = pc.inbound_frames()
    time.sleep(HIDDEN_WINDOW_SECONDS)
    grew = pc.inbound_frames() - first
    print(f"  carol in a text channel: {grew} frames decoded in "
          f"{HIDDEN_WINDOW_SECONDS:.0f}s")
    assert grew <= HIDDEN_FRAMES_TOLERATED, \
        f"hidden shares kept decoding: {grew} frames"
    c.click(L.VOICE_CHANNEL, settle=2)
    wait_for_videos(pc, every, 2)
    print("  and returning to the lounge decodes both again")


def two_shares_reach_a_third_viewer(a, b, server, secret, admin_api,
                                    sign_in, room_id, bob_id):
    e2e_browsers.register(server, admin_api, "carol", secret)
    wav = os.path.join(e2e_browsers.work_dir(), "fake-voice.wav")
    with e2e_audio.installed(a), e2e_audio.installed(b), \
            e2e_browsers.browser("carol", wav) as c:
        _three_way(a, b, c, server, secret, sign_in, room_id, bob_id)


def _three_way(a, b, c, server, secret, sign_in, room_id, bob_id):
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
        sids = _share_sids(room_id)
        every = list(sids.values())
        seen = wait_for_videos(pc, every, 2)
        print("  carol decodes both shares: "
              + ", ".join(f"{v['width']}x{v['height']} mean {v['mean']:.0f} "
                          f"spread {v['spread']:.0f} frames {v['frames']}"
                          for v in seen))
        c.wait_for("Alice's screen")
        c.wait_for("Bob's screen")
        mine = wait_for_videos(pa, every, 2)
        theirs = wait_for_videos(pb, every, 2)
        print(f"  alice and bob each decode {len(mine)} videos: their own "
              f"preview and the other's share ({len(theirs)})")

        before = max(_area(v) for v in share_tiles(pc.videos(), every))
        c.click(FOCUS, settle=2)
        c.wait_for(SHOW_ALL)
        after = max(_area(v) for v in share_tiles(pc.videos(), every))
        print(f"  focusing one share: largest video {before} -> {after} px")
        assert after > before * 1.1, "focusing a share did not enlarge it"
        c.click(SHOW_ALL, settle=2)
        c.wait_for(FOCUS)
        wait_for_videos(pc, every, 2)
        print("  and showing all shares puts both back")

        _hidden_shares_stop_decoding(c, pc, every)

        a.click(L.STOP_SHARING, settle=4)
        _wait_sharing(room_id, 1)
        left = wait_for_videos(pc, [sids[bob_id]], 1)
        print(f"  alice stopped: carol still decodes bob's share "
              f"(frames {left[0]['frames']})")
        assert _sharing(room_id) == [bob_id], _sharing(room_id)
    finally:
        for who in (a, b):
            if who.find(L.STOP_SHARING):
                who.click(L.STOP_SHARING, settle=3)
        ui.leave_if_in_call(a, b, c)
